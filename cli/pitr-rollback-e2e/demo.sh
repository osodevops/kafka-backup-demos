#!/bin/bash
# PITR + Rollback End-to-End Demo
# Demonstrates: Complete point-in-time recovery workflow
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   PITR + Rollback End-to-End Demo"
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

print_warning() {
    echo -e "${RED}!${NC} $1"
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

# Reset environment
print_step 2 "Resetting environment..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic payments 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic payments --partitions 3 --replication-factor 1
'
# Reset consumer group
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 --group payments-processor --delete 2>/dev/null || true
'
print_success "Environment reset"

# Phase 1: Normal traffic
print_step 3 "Phase 1: Producing normal traffic..."
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 50); do
        echo "{\"payment_id\": \"PAY-$i\", \"amount\": $((100 + RANDOM % 900)), \"status\": \"valid\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments
'
print_success "Produced 50 valid payment messages"

# Start a consumer to establish offsets
print_info "Starting consumer to process messages..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --group payments-processor --from-beginning \
        --max-messages 30 --timeout-ms 10000 > /dev/null 2>&1
'
print_success "Consumer processed 30 messages"

# Record timestamp BEFORE injecting bad data
print_step 4 "Recording timestamp for PITR..."
# Get current timestamp in milliseconds
PITR_TIMESTAMP=$(date +%s000)
print_info "PITR timestamp: $PITR_TIMESTAMP"
print_info "Human readable: $(date -r $((PITR_TIMESTAMP / 1000)))"
echo "$PITR_TIMESTAMP" > "$SCRIPT_DIR/pitr-timestamp.txt"
sleep 2  # Ensure some time passes
echo ""

# Phase 2: Take offset snapshot BEFORE bad data
print_step 5 "Phase 2: Creating offset snapshot..."
docker compose --profile tools run --rm kafka-backup \
    offset-rollback snapshot \
    --path s3://kafka-backups/pitr-demo \
    --groups payments-processor \
    --bootstrap-servers kafka-broker-1:9092 \
    --description "Pre-corruption snapshot"

SNAPSHOT_ID=$(docker compose --profile tools run --rm kafka-backup \
    offset-rollback list \
    --path s3://kafka-backups/pitr-demo \
    --format text 2>/dev/null | grep "snapshot-" | head -1 | awk '{print $1}')

if [ -n "$SNAPSHOT_ID" ]; then
    print_success "Created snapshot: $SNAPSHOT_ID"
    echo "$SNAPSHOT_ID" > "$SCRIPT_DIR/snapshot-id.txt"
else
    SNAPSHOT_ID="snapshot-$(date +%Y%m%d-%H%M%S)"
    echo "$SNAPSHOT_ID" > "$SCRIPT_DIR/snapshot-id.txt"
    print_info "Snapshot ID recorded as: $SNAPSHOT_ID"
fi

# Create backup with timestamp
print_step 6 "Creating backup of current state..."
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-pitr.yaml
print_success "Backup completed"

# Phase 3: Inject corrupted/bad data
print_step 7 "Phase 3: Injecting corrupted data (simulating incident)..."
print_warning "This simulates a deployment bug or data corruption"
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 51 100); do
        echo "{\"payment_id\": \"CORRUPTED-$i\", \"amount\": -999, \"status\": \"INVALID\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments
'
print_success "Injected 50 corrupted messages"

# Show current state
print_step 8 "Current topic state (with corrupted data)..."
echo "Total messages in topic:"
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic payments --time -1 2>/dev/null
'
echo ""
echo "Sample of corrupted messages:"
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --from-beginning \
        --max-messages 100 --timeout-ms 5000 2>/dev/null | grep "CORRUPTED" | head -5
'
echo ""

# Consumer processes some bad data (to show the problem)
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --group payments-processor \
        --max-messages 20 --timeout-ms 10000 > /dev/null 2>&1
'
print_warning "Consumer has now processed some corrupted messages!"

# Show consumer group state
echo "Consumer group current state:"
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --group payments-processor 2>/dev/null
'
echo ""

# Phase 4: PITR Restore
print_step 9 "Phase 4: Performing PITR restore to timestamp..."
print_info "Restoring to: $PITR_TIMESTAMP"

# Delete corrupted topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic payments
'
sleep 2

# Recreate topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic payments --partitions 3 --replication-factor 1
'

# Restore with PITR time window
# Note: Using the config file and passing timestamp
docker compose --profile tools run --rm -e PITR_TIMESTAMP="$PITR_TIMESTAMP" kafka-backup \
    restore \
    --config /config/restore-pitr.yaml
print_success "PITR restore completed"

# Phase 5: Reset consumer offsets
print_step 10 "Phase 5: Resetting consumer offsets..."
docker compose --profile tools run --rm kafka-backup \
    offset-reset execute \
    --path s3://kafka-backups/pitr-demo \
    --backup-id pitr-backup \
    --groups payments-processor \
    --bootstrap-servers kafka-broker-1:9092 2>/dev/null || \
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group payments-processor --topic payments \
        --reset-offsets --to-earliest --execute
'
print_success "Consumer offsets reset"

# Phase 6: Verification
print_step 11 "Phase 6: Verifying clean state..."
echo "Messages after PITR restore:"
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic payments --time -1 2>/dev/null
'
echo ""

echo "Checking for corrupted messages (should be 0):"
CORRUPT_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --from-beginning \
        --timeout-ms 10000 2>/dev/null | grep -c "CORRUPTED" || echo "0"
')
echo "Found $CORRUPT_COUNT corrupted messages"
echo ""

if [ "$CORRUPT_COUNT" = "0" ]; then
    print_success "VERIFICATION PASSED: No corrupted data found!"
else
    print_warning "Verification found corrupted data - may need rollback"

    # Phase 7: Rollback if needed
    print_step 12 "Phase 7: Rollback to snapshot..."
    if [ -n "$SNAPSHOT_ID" ]; then
        docker compose --profile tools run --rm kafka-backup \
            offset-rollback rollback \
            --path s3://kafka-backups/pitr-demo \
            --snapshot-id "$SNAPSHOT_ID" \
            --bootstrap-servers kafka-broker-1:9092 \
            --verify true
        print_success "Rolled back to snapshot: $SNAPSHOT_ID"
    fi
fi

echo "Consumer group state after recovery:"
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --group payments-processor 2>/dev/null
'
echo ""

echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "PITR Workflow Summary:"
echo "  1. Normal operations: Produce valid data"
echo "  2. Create offset snapshot (safety checkpoint)"
echo "  3. Create backup"
echo "  4. Incident: Bad data injected"
echo "  5. Consumer processes bad data (problem detected)"
echo "  6. PITR restore to timestamp before incident"
echo "  7. Reset consumer offsets"
echo "  8. Verify clean state"
echo "  9. Rollback to snapshot if verification fails"
echo ""
print_info "Key Files Created:"
echo "  - cli/pitr-rollback-e2e/pitr-timestamp.txt"
echo "  - cli/pitr-rollback-e2e/snapshot-id.txt"
echo ""
print_info "Key Commands Used:"
echo "  kafka-backup offset-rollback snapshot  # Create checkpoint"
echo "  kafka-backup backup                    # Backup data"
echo "  kafka-backup restore                   # PITR restore"
echo "  kafka-backup offset-reset execute      # Reset offsets"
echo "  kafka-backup offset-rollback rollback  # Emergency rollback"
