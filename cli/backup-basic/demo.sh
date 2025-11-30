#!/bin/bash
# Basic Topic Backup & Restore Demo
# Demonstrates: Full backup/restore cycle to MinIO
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   Basic Topic Backup & Restore Demo"
echo "================================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_step() {
    echo -e "${BLUE}[Step $1]${NC} $2"
    echo ""
}

print_info() {
    echo -e "${YELLOW}→${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
    echo ""
}

print_error() {
    echo -e "${RED}✗${NC} $1"
    echo ""
}

# Check if services are running
print_step 1 "Checking Docker services..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    echo "Starting Docker services..."
    docker compose up -d
    echo "Waiting for Kafka to be ready (20 seconds)..."
    sleep 20
fi
print_success "Docker services are running"

# Delete existing topic if it exists and recreate
print_step 2 "Preparing orders topic..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic orders --partitions 3 --replication-factor 1
' 2>/dev/null || true
print_success "Topic 'orders' is ready"

# Produce sample data from CSV
print_step 3 "Producing sample data from orders.csv..."
docker compose --profile tools run --rm kafka-cli bash -c '
    # Skip header line and produce each record
    tail -n +2 /data/orders.csv | while IFS=, read -r order_id customer_id product amount currency timestamp; do
        echo "{\"order_id\": \"$order_id\", \"customer_id\": \"$customer_id\", \"product\": \"$product\", \"amount\": $amount, \"currency\": \"$currency\", \"timestamp\": \"$timestamp\"}"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders
'
print_success "Produced 100 messages from orders.csv"

# Count messages before backup
print_step 4 "Counting messages in topic before backup..."
BEFORE_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic orders \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')
print_info "Message count before backup: $BEFORE_COUNT"
echo ""

# Run backup to MinIO
print_step 5 "Running kafka-backup to MinIO..."
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-basic.yaml
print_success "Backup completed to s3://kafka-backups/basic-demo"

# List backup contents
print_step 6 "Listing backup contents..."
docker compose --profile tools run --rm kafka-backup \
    list \
    --path s3://kafka-backups/basic-demo
echo ""

# Describe the backup
print_step 7 "Describing backup details..."
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/basic-demo \
    --backup-id basic-backup
echo ""

# Delete the topic (simulating data loss)
print_step 8 "Simulating data loss - deleting 'orders' topic..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --delete \
        --topic orders
'
sleep 3
print_success "Topic deleted (data loss simulated)"

# Verify topic is gone
print_info "Verifying topic is deleted..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --list
' | grep -q "^orders$" && print_error "Topic still exists!" || print_success "Topic confirmed deleted"

# Recreate the topic
print_step 9 "Recreating empty 'orders' topic..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --create \
        --topic orders \
        --partitions 3 \
        --replication-factor 1
'
print_success "Empty topic created"

# Restore from backup
print_step 10 "Restoring data from backup..."
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-basic.yaml
print_success "Restore completed"

# Count messages after restore
print_step 11 "Validating restored data..."
sleep 2
AFTER_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic orders \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')
print_info "Message count after restore: $AFTER_COUNT"
echo ""

# Compare counts
if [ "$BEFORE_COUNT" = "$AFTER_COUNT" ]; then
    print_success "VALIDATION PASSED: Message counts match ($BEFORE_COUNT = $AFTER_COUNT)"
else
    print_error "VALIDATION FAILED: Message counts don't match ($BEFORE_COUNT != $AFTER_COUNT)"
fi

# Sample some messages to verify content
print_step 12 "Sampling restored messages..."
echo "First 5 restored messages:"
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders \
        --from-beginning \
        --max-messages 5 \
        --timeout-ms 5000
'
echo ""

echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "Summary:"
echo "  1. Produced $BEFORE_COUNT messages from orders.csv"
echo "  2. Backed up to MinIO (S3-compatible)"
echo "  3. Simulated data loss by deleting topic"
echo "  4. Restored $AFTER_COUNT messages from backup"
echo ""
print_info "MinIO Console:"
echo "  URL: http://localhost:9001"
echo "  Username: minioadmin"
echo "  Password: minioadmin"
echo "  Bucket: kafka-backups/basic-demo/"
echo ""
print_info "Adapting to AWS S3:"
echo "  Edit config/backup-basic.yaml:"
echo "    - Remove 'endpoint' and 'path_style' settings"
echo "    - Set 'region' to your AWS region"
echo "    - Use environment variables for credentials"
