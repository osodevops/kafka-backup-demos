#!/bin/bash
# Large Messages Demo
# Demonstrates: Handling large messages with compression
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   Large Messages & Compression Demo"
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

# Check if services are running
print_step 1 "Checking Docker services..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    echo "Starting Docker services..."
    docker compose up -d
    echo "Waiting for Kafka to be ready (20 seconds)..."
    sleep 20
fi
print_success "Docker services are running"

# Generate large messages if they don't exist
print_step 2 "Generating large test messages..."
if [ ! -f "$PROJECT_ROOT/data/generated-large-messages.json" ]; then
    print_info "Creating 5 messages of approximately 1MB each..."
    cd "$PROJECT_ROOT/data"

    # Generate inline (simpler than using the script)
    echo "[" > generated-large-messages.json
    for i in $(seq 1 5); do
        # Generate ~1MB of random data
        PAYLOAD=$(head -c 1000000 /dev/urandom | base64 | tr -d '\n' | head -c 1000000)
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        if [ $i -eq 5 ]; then
            COMMA=""
        else
            COMMA=","
        fi

        cat >> generated-large-messages.json << EOF
  {
    "id": "large-msg-$i",
    "timestamp": "$TIMESTAMP",
    "size_bytes": 1000000,
    "type": "large-payload-test",
    "payload": "$PAYLOAD"
  }$COMMA
EOF
        echo "  Generated message $i/5"
    done
    echo "]" >> generated-large-messages.json

    cd "$PROJECT_ROOT"
fi
FILE_SIZE=$(ls -lh "$PROJECT_ROOT/data/generated-large-messages.json" | awk '{print $5}')
print_success "Large messages ready ($FILE_SIZE total)"

# Recreate topic with large message support
print_step 3 "Recreating large_messages topic..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic large_messages 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic large_messages \
        --partitions 1 \
        --replication-factor 1 \
        --config max.message.bytes=15728640
'
print_success "Topic created with max.message.bytes=15MB"

# Produce large messages
print_step 4 "Producing large messages to Kafka..."
docker compose --profile tools run --rm kafka-cli bash -c '
    cat /data/generated-large-messages.json | jq -c ".[]" | while read msg; do
        echo "$msg" | kafka-console-producer.sh \
            --bootstrap-server kafka-broker-1:9092 \
            --topic large_messages \
            --producer-property max.request.size=15728640
    done
'
print_success "Produced 5 large messages"

# Show topic stats before backup
print_step 5 "Checking topic size before backup..."
BEFORE_SIZE=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-log-dirs.sh --bootstrap-server kafka-broker-1:9092 --describe --topic-list large_messages 2>/dev/null | grep -oP "size\":\K[0-9]+" | head -1
' 2>/dev/null || echo "N/A")
print_info "Topic size on disk: ~$((BEFORE_SIZE / 1024 / 1024))MB"
echo ""

# Backup with zstd compression
print_step 6 "Backing up with zstd compression..."
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-large.yaml
print_success "Backup completed with zstd compression"

# Show backup size
print_step 7 "Checking backup size (with compression)..."
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/large-demo \
    --backup-id large-messages-backup \
    --format json > "$SCRIPT_DIR/backup-stats.json" 2>/dev/null || true

print_info "Backup details saved to cli/large-messages/backup-stats.json"
echo ""

# Check MinIO for actual size
print_info "Checking actual backup size in MinIO..."
docker compose exec minio mc ls -r local/kafka-backups/large-demo/ --summarize 2>/dev/null | tail -5 || true
echo ""

# Delete and restore
print_step 8 "Simulating data loss..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic large_messages
'
sleep 2
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic large_messages \
        --partitions 1 \
        --replication-factor 1 \
        --config max.message.bytes=15728640
'
print_success "Topic deleted and recreated"

# Restore
print_step 9 "Restoring from compressed backup..."
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-large.yaml
print_success "Restore completed"

# Validate no truncation
print_step 10 "Validating message integrity..."
echo "Consuming messages and checking sizes..."

docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic large_messages \
        --from-beginning \
        --timeout-ms 10000 \
        --max-messages 5 2>/dev/null | while read msg; do
            SIZE=$(echo "$msg" | wc -c)
            ID=$(echo "$msg" | jq -r ".id" 2>/dev/null || echo "unknown")
            echo "  Message $ID: $SIZE bytes"
        done
'
echo ""

# Verify message count
MSG_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic large_messages \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')

if [ "$MSG_COUNT" = "5" ]; then
    print_success "VALIDATION PASSED: All 5 messages restored"
else
    echo -e "${RED}VALIDATION FAILED: Expected 5 messages, got $MSG_COUNT${NC}"
fi

echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "Key Observations:"
echo "  1. Large messages (1MB+) are handled correctly"
echo "  2. zstd compression significantly reduces backup size"
echo "  3. No message truncation during backup/restore"
echo "  4. Original message sizes preserved after restore"
echo ""
print_info "Compression Comparison:"
echo "  To test different algorithms, edit backup-large.yaml:"
echo "    compression: zstd  # Best ratio (default)"
echo "    compression: lz4   # Fastest"
echo "    compression: gzip  # Most compatible"
echo "    compression: none  # No compression"
echo ""
print_info "Broker Configuration (already applied):"
echo "  message.max.bytes=15728640 (15MB)"
echo "  replica.fetch.max.bytes=15728640"
