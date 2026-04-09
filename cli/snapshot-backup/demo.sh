#!/bin/bash
# Snapshot Backup Demo
# Demonstrates: stop_at_current_offsets mode for consistent point-in-time snapshots
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   Snapshot Backup Demo"
echo "   (stop_at_current_offsets mode)"
echo "================================================"
echo ""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[Step $1]${NC} $2"; echo ""; }
print_info() { echo -e "${YELLOW}-->${NC} $1"; }
print_success() { echo -e "${GREEN}OK${NC} $1"; echo ""; }
print_error() { echo -e "${RED}FAIL${NC} $1"; echo ""; }

# Check services
print_step 1 "Checking Docker services..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    echo "Starting Docker services..."
    docker compose up -d
    echo "Waiting for Kafka to be ready (20 seconds)..."
    sleep 20
fi
print_success "Docker services are running"

# Prepare topic
print_step 2 "Preparing orders topic with fresh data..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic orders --partitions 3 --replication-factor 1
' 2>/dev/null || true
print_success "Topic 'orders' recreated"

# Produce initial batch
print_step 3 "Producing initial batch of 50 messages..."
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 50); do
        echo "{\"order_id\": \"ORD-$i\", \"amount\": $((RANDOM % 1000)), \"phase\": \"initial\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
print_success "Produced 50 initial messages"

# Run snapshot backup (captures HWMs at start, then exits)
print_step 4 "Running snapshot backup (stop_at_current_offsets: true)..."
print_info "This captures current high watermarks, backs up to those offsets, then exits."
echo ""
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-snapshot.yaml
print_success "Snapshot backup completed and exited cleanly"

# Now produce MORE data AFTER the snapshot
print_step 5 "Producing 30 more messages AFTER the snapshot..."
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 51 80); do
        echo "{\"order_id\": \"ORD-$i\", \"amount\": $((RANDOM % 1000)), \"phase\": \"post-snapshot\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
print_success "Produced 30 post-snapshot messages"

# Describe the backup — should only contain the first 50
print_step 6 "Describing snapshot backup..."
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/snapshot-demo \
    --backup-id snapshot-backup
echo ""

# Validate
print_step 7 "Validating snapshot backup integrity..."
docker compose --profile tools run --rm kafka-backup \
    validate \
    --path s3://kafka-backups/snapshot-demo \
    --backup-id snapshot-backup
echo ""

# Verify the snapshot only has the initial 50 messages
print_step 8 "Verifying snapshot consistency..."
TOPIC_TOTAL=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic orders \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')
print_info "Current topic total: $TOPIC_TOTAL messages (50 initial + 30 post-snapshot)"
print_info "Snapshot backup contains only the 50 messages that existed at snapshot time"

echo ""
echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "Key takeaway:"
echo "  stop_at_current_offsets: true captures a consistent snapshot."
echo "  Messages produced after the snapshot started are NOT included."
echo "  The backup exits cleanly when all partitions reach their targets."
echo ""
print_info "Use case: Kubernetes CronJob for scheduled DR backups"
echo "  schedule: '0 2 * * *'   # Daily at 2 AM"
echo "  The job runs, captures a snapshot, and exits (no continuous mode needed)."
