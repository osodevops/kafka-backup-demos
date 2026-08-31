#!/bin/bash
# Retention & Prune Demo
# Demonstrates: safe retention for incremental backup sets (kafka-backup 0.21+)
#   backup -> age -> prune (plan) -> prune --execute -> validate/describe -> restore
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   Retention & Prune Demo (issue #169)"
echo "================================================"
echo ""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_step()    { echo -e "${BLUE}[Step $1]${NC} $2"; echo ""; }
print_info()    { echo -e "${YELLOW}→${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; echo ""; }

kb() { docker compose --profile tools run --rm kafka-backup "$@"; }

print_step 1 "Checking Docker services..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    docker compose up -d
    echo "Waiting for Kafka to be ready (20 seconds)..."; sleep 20
fi
print_success "Docker services are running"

print_step 2 "Preparing the orders topic with two batches of data..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic orders --partitions 3 --replication-factor 1
' 2>/dev/null || true
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 60); do echo "{\"order_id\": \"old-$i\", \"batch\": \"old\"}"; done | \
      kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
print_success "Produced 60 'old' records"

print_step 3 "First incremental backup (writes several small segments)..."
kb backup --config /config/backup-retention.yaml
print_success "First backup complete"

print_step 4 "Waiting past the demo retention window (35s), producing new data..."
sleep 35
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 30); do echo "{\"order_id\": \"new-$i\", \"batch\": \"new\"}"; done | \
      kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
print_success "Produced 30 'new' records"

print_step 5 "Prune PLAN (dry run — nothing deleted)..."
kb prune --path s3://kafka-backups --backup-id retention-demo --older-than 30s
print_info "Note the plan lists only a contiguous oldest-first prefix per partition."
print_success "Plan reviewed"

print_step 6 "Prune --execute (manifest rewritten first, then objects deleted)..."
kb prune --path s3://kafka-backups --backup-id retention-demo --older-than 30s --execute
print_success "Aged segments pruned"

print_step 7 "The archive is still VALID — pruned ranges are recorded, not data loss..."
kb validate --path s3://kafka-backups --backup-id retention-demo
kb describe --path s3://kafka-backups --backup-id retention-demo | grep -E "PRUNED|Pruned|Total Segments" || true
print_success "validate passes and describe shows the PRUNED ranges"

print_step 8 "Second incremental backup — pruned segments are NOT resurrected..."
kb backup --config /config/backup-retention.yaml
kb describe --path s3://kafka-backups --backup-id retention-demo | grep -E "PRUNED|Total Segments" || true
print_success "Incremental resume works; pruned ranges survive the merge"

print_step 9 "Restore the surviving window to orders-restored..."
cat > /tmp/retention-restore.yaml <<'RESTORE'
mode: restore
backup_id: "retention-demo"
target:
  bootstrap_servers:
    - kafka-broker-1:9092
  topics:
    include:
      - orders
storage:
  backend: s3
  bucket: kafka-backups
  endpoint: http://minio:9000
  path_style: true
  allow_http: true
  access_key: minioadmin
  secret_key: minioadmin
restore:
  create_topics: true
  topic_mapping:
    orders: orders-restored
RESTORE
docker compose --profile tools run --rm -v /tmp/retention-restore.yaml:/config/retention-restore.yaml kafka-backup \
  restore --config /config/retention-restore.yaml
COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
  kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
    --topic orders-restored --from-beginning --timeout-ms 10000 2>/dev/null | wc -l' | tr -d "[:space:]")
print_info "Restored record count: $COUNT (the pruned window is gone by design)"
print_success "Restore of the surviving window works"

echo "================================================"
echo "   Demo complete."
echo "   Key takeaways:"
echo "   - prune is plan-only by default; --execute deletes"
echo "   - manifest is rewritten before objects are deleted"
echo "   - pruned ranges are recorded, validate stays green"
echo "   - never use bucket lifecycle rules on incremental sets"
echo "================================================"
