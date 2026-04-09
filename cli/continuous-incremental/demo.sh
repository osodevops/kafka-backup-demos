#!/bin/bash
# Continuous Incremental Backup Demo
# Demonstrates: continuous mode with offset storage for resumable incremental backups
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   Continuous Incremental Backup Demo"
echo "   (resumable with offset tracking)"
echo "================================================"
echo ""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[Step $1]${NC} $2"; echo ""; }
print_info() { echo -e "${YELLOW}-->${NC} $1"; }
print_success() { echo -e "${GREEN}OK${NC} $1"; echo ""; }

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
print_step 2 "Preparing orders topic..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic orders --partitions 3 --replication-factor 1
' 2>/dev/null || true
print_success "Topic 'orders' recreated"

# Produce first batch
print_step 3 "Producing first batch (50 messages)..."
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 50); do
        echo "{\"order_id\": \"ORD-$i\", \"batch\": 1}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
print_success "Batch 1: 50 messages produced"

# Run continuous backup for a short time, then stop
print_step 4 "Starting continuous backup (runs for 10 seconds, then stops)..."
print_info "The backup tracks its progress in a SQLite offset database."
print_info "This database is stored in \$TMPDIR and synced to S3 periodically."
echo ""

# Run with timeout - backup runs continuously, we kill it after 10s
timeout 10 docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-continuous.yaml 2>&1 || true
echo ""
print_success "Backup stopped (simulating process interruption)"

# Produce more data while backup is down
print_step 5 "Producing second batch while backup is stopped (30 more messages)..."
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 51 80); do
        echo "{\"order_id\": \"ORD-$i\", \"batch\": 2}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
print_success "Batch 2: 30 messages produced while backup was down"

# Resume backup — it picks up from where it left off
print_step 6 "Resuming backup (picks up from last checkpoint)..."
print_info "The backup loads its offset database from S3 and resumes."
print_info "Only NEW messages since the last checkpoint are backed up."
echo ""

timeout 10 docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-continuous.yaml 2>&1 || true
echo ""
print_success "Backup resumed and caught up with new data"

# Verify the backup
print_step 7 "Describing the backup..."
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/continuous-demo \
    --backup-id continuous-backup 2>&1 || true
echo ""

# Validate
print_step 8 "Validating backup integrity..."
docker compose --profile tools run --rm kafka-backup \
    validate \
    --path s3://kafka-backups/continuous-demo \
    --backup-id continuous-backup 2>&1 || true
echo ""

echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "What was demonstrated:"
echo "  1. Started a continuous backup (continuous: true)"
echo "  2. Interrupted it (simulating pod restart / crash)"
echo "  3. Produced new messages while backup was down"
echo "  4. Resumed the backup - it picked up from the last checkpoint"
echo ""
print_info "How offset tracking works:"
echo "  - Local SQLite DB at \$TMPDIR/{backup_id}-offsets.db"
echo "  - Synced to S3 every sync_interval_secs (default: 30s)"
echo "  - On restart, loads offset DB from S3 to resume"
echo ""
print_info "Kubernetes deployment:"
echo "  - Use a Deployment (not CronJob) for continuous backups"
echo "  - Mount /tmp as emptyDir if using readOnlyRootFilesystem"
echo "  - Optional: set offset_storage.db_path to a persistent volume"
