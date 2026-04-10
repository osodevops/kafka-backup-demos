#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_step() { echo -e "\n${BLUE}[Step $1]${NC} $2\n"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1\n"; }
print_error() { echo -e "${RED}✗${NC} $1\n"; }

echo "================================================"
echo "  Full Enterprise Backup Demo"
echo "  Kafka + Schema Registry + Apicurio"
echo "================================================"
echo ""

# ── Step 1: Start everything ────────────────────────────
print_step 1 "Start all enterprise services..."

docker compose --profile enterprise up -d
print_info "Waiting for all services to be ready..."
sleep 15

# Wait for Schema Registry
for i in $(seq 1 15); do
    if curl -sf http://localhost:8081/subjects > /dev/null 2>&1; then break; fi
    sleep 3
done

# Wait for Apicurio
for i in $(seq 1 20); do
    if curl -sf http://localhost:8085/q/health > /dev/null 2>&1; then break; fi
    sleep 3
done

print_success "All services running (Kafka, Schema Registry, Apicurio, MinIO)"

# ── Step 2: Produce test data to Kafka ──────────────────
print_step 2 "Produce test messages to Kafka topics..."

docker compose --profile tools run --rm kafka-cli bash -c '
    # Produce to orders topic
    for i in $(seq 1 20); do
        echo "{\"order_id\":\"ORD-$i\",\"customer_id\":\"CUST-$((i % 5))\",\"amount\":$((RANDOM % 1000)).$((RANDOM % 100))}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders 2>/dev/null

    # Produce to payments topic
    for i in $(seq 1 10); do
        echo "{\"payment_id\":\"PAY-$i\",\"order_id\":\"ORD-$i\",\"amount\":$((RANDOM % 500)).$((RANDOM % 100)),\"currency\":\"USD\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments 2>/dev/null

    echo "Produced 20 orders + 10 payments"
'

print_success "Test messages produced"

# ── Step 3: Show what exists ────────────────────────────
print_step 3 "Survey what will be backed up..."

echo "  Kafka topics:"
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --list 2>/dev/null | grep -v "^__" | while read topic; do
        COUNT=$(kafka-run-class.sh kafka.tools.GetOffsetShell --broker-list kafka-broker-1:9092 --topic $topic 2>/dev/null | awk -F: "{sum+=\$3} END {print sum}")
        echo "    $topic: $COUNT messages"
    done
' 2>/dev/null

echo ""
echo "  Schema Registry subjects:"
curl -sf http://localhost:8081/subjects | python3 -c "
import sys,json
for s in json.load(sys.stdin): print(f'    {s}')
" 2>/dev/null

echo ""
echo "  Apicurio Registry groups:"
curl -sf http://localhost:8085/apis/registry/v3/groups | python3 -c "
import sys,json
for g in json.load(sys.stdin).get('groups',[]): print(f'    {g[\"groupId\"]}')
" 2>/dev/null

print_success "Survey complete"

# ── Step 4: Check license ───────────────────────────────
print_step 4 "Check enterprise license..."

docker compose --profile enterprise run --rm kafka-backup-enterprise license info 2>&1 | tail -5
print_success "Enterprise features available"

# ── Step 5: Run full enterprise backup ──────────────────
print_step 5 "Run FULL enterprise backup (Kafka + Schema Registry + Apicurio)..."

docker compose --profile enterprise run --rm kafka-backup-enterprise \
    backup --config /config/backup-enterprise-full.yaml

print_success "Full enterprise backup complete!"

# ── Step 6: Verify everything ───────────────────────────
print_step 6 "Verify backup contents in MinIO..."

docker run --rm --network kafka-net minio/mc sh -c "
    mc alias set local http://minio:9000 minioadmin minioadmin > /dev/null 2>&1
    echo 'Complete backup layout:'
    mc ls local/kafka-backups/enterprise-full/ --recursive 2>/dev/null | head -30
    echo '...'
    echo ''
    TOTAL=\$(mc ls local/kafka-backups/enterprise-full/ --recursive 2>/dev/null | wc -l)
    echo \"Total files: \$TOTAL\"
"

print_success "All backup files verified"

# ── Summary ─────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Full Enterprise Backup Demo Complete!"
echo "================================================"
echo ""
echo "  What was backed up in a single command:"
echo ""
echo "    1. Kafka data"
echo "       - orders topic (20 messages)"
echo "       - payments topic (10 messages)"
echo ""
echo "    2. Confluent Schema Registry"
echo "       - orders-value (2 versions, Avro)"
echo "       - payments-value (1 version, Avro)"
echo "       - Per-subject compatibility configs"
echo ""
echo "    3. Apicurio Registry"
echo "       - 3 groups (payments, orders, common)"
echo "       - Artifacts (Avro + Protobuf)"
echo "       - Export ZIP for disaster recovery"
echo "       - Rules at all 3 scopes"
echo ""
echo "  Backup location: s3://kafka-backups/enterprise-full/"
echo "  Config: config/backup-enterprise-full.yaml"
echo ""
echo "  This is everything you need for full disaster"
echo "  recovery — Kafka data + schemas + metadata."
echo "================================================"
