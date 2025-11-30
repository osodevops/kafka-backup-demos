#!/bin/bash
# Offset State Verification Demo
# Demonstrates: Consumer offset snapshot & inspection
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   Offset State Verification Demo"
echo "================================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Check if services are running
print_step 1 "Checking Docker services..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    echo "Starting Docker services..."
    docker compose up -d
    echo "Waiting for Kafka to be ready (20 seconds)..."
    sleep 20
fi
print_success "Docker services are running"

# Produce test messages
print_step 2 "Producing 100 test messages to 'orders' topic..."
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 100); do
        echo "{\"order_id\": \"ORD-$i\", \"amount\": $((RANDOM % 1000))}"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders
'
print_success "Produced 100 messages to orders topic"

# Start a console consumer to commit offsets (consume first 50 messages)
print_step 3 "Starting consumer to read 50 messages and commit offsets..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders \
        --group orders-streams \
        --from-beginning \
        --max-messages 50 \
        --timeout-ms 10000 \
        > /dev/null 2>&1
'
print_success "Consumer group 'orders-streams' has committed offsets"

# Show current offsets using kafka-consumer-groups
print_step 4 "Displaying current offset state with kafka-consumer-groups..."
echo ""
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --describe \
        --group orders-streams
'
echo ""
print_info "This shows the current committed offsets per partition"
print_info "The LAG column shows unconsumed messages"
echo ""

# Create offset snapshot using kafka-backup
print_step 5 "Creating offset snapshot with kafka-backup..."
SNAPSHOT_ID=$(docker compose --profile tools run --rm kafka-backup \
    offset-rollback snapshot \
    --path s3://kafka-backups/offset-demo \
    --groups orders-streams \
    --bootstrap-servers kafka-broker-1:9092 \
    --description "Demo snapshot - before consuming remaining messages" \
    2>/dev/null | grep -oP 'snapshot-\S+' | head -1)

if [ -z "$SNAPSHOT_ID" ]; then
    SNAPSHOT_ID="snapshot-$(date +%Y%m%d-%H%M%S)"
fi
print_success "Created snapshot: $SNAPSHOT_ID"

# List available snapshots
print_step 6 "Listing available offset snapshots..."
docker compose --profile tools run --rm kafka-backup \
    offset-rollback list \
    --path s3://kafka-backups/offset-demo \
    --format text
echo ""

# Show snapshot details as JSON
print_step 7 "Exporting snapshot details to JSON..."
docker compose --profile tools run --rm kafka-backup \
    offset-rollback show \
    --path s3://kafka-backups/offset-demo \
    --snapshot-id "$SNAPSHOT_ID" \
    --format json > "$SCRIPT_DIR/offsets-before.json" 2>/dev/null || true

if [ -f "$SCRIPT_DIR/offsets-before.json" ]; then
    print_success "Saved to: cli/offset-testing/offsets-before.json"
    echo "Contents:"
    cat "$SCRIPT_DIR/offsets-before.json" | head -50
    echo ""
fi

# Consume remaining messages
print_step 8 "Consuming remaining messages (simulating progress)..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders \
        --group orders-streams \
        --timeout-ms 10000 \
        > /dev/null 2>&1
'
print_success "Consumed remaining messages"

# Show updated offset state
print_step 9 "Displaying updated offset state..."
echo ""
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --describe \
        --group orders-streams
'
echo ""
print_info "Notice: LAG should now be 0 (all messages consumed)"
echo ""

# Create another snapshot
print_step 10 "Creating second snapshot for comparison..."
SNAPSHOT_ID_AFTER=$(docker compose --profile tools run --rm kafka-backup \
    offset-rollback snapshot \
    --path s3://kafka-backups/offset-demo \
    --groups orders-streams \
    --bootstrap-servers kafka-broker-1:9092 \
    --description "Demo snapshot - after consuming all messages" \
    2>/dev/null | grep -oP 'snapshot-\S+' | head -1)
print_success "Created second snapshot"

# Export second snapshot
docker compose --profile tools run --rm kafka-backup \
    offset-rollback show \
    --path s3://kafka-backups/offset-demo \
    --snapshot-id "$SNAPSHOT_ID_AFTER" \
    --format json > "$SCRIPT_DIR/offsets-after.json" 2>/dev/null || true

echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "Key Takeaways:"
echo "  1. kafka-consumer-groups.sh shows current committed offsets"
echo "  2. kafka-backup offset-rollback snapshot captures offset state"
echo "  3. Snapshots can be exported as JSON for analysis"
echo "  4. Compare before/after snapshots to verify restore operations"
echo ""
print_info "Generated files:"
echo "  - cli/offset-testing/offsets-before.json"
echo "  - cli/offset-testing/offsets-after.json"
echo ""
print_info "Next: Try rolling back to the first snapshot!"
echo "  docker compose --profile tools run --rm kafka-backup \\"
echo "    offset-rollback rollback --path s3://kafka-backups/offset-demo \\"
echo "    --snapshot-id $SNAPSHOT_ID --bootstrap-servers kafka-broker-1:9092"
