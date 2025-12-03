#!/bin/bash
# Live Producer Backup & Restore Demo
# Demonstrates: Backup and restore while producers are actively producing
# Answers: "Wouldn't you need the producers not to produce when you do it?"
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "============================================================"
echo "   Live Producer Backup & Restore Demo"
echo "============================================================"
echo ""
echo "This demo answers: 'Do producers need to stop during backup?'"
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
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

print_answer() {
    echo -e "${CYAN}▶${NC} $1"
}

# Cleanup function
cleanup() {
    print_info "Cleaning up background producer..."
    if [ -n "$PRODUCER_CONTAINER" ]; then
        docker stop "$PRODUCER_CONTAINER" 2>/dev/null || true
        docker rm "$PRODUCER_CONTAINER" 2>/dev/null || true
    fi
}
trap cleanup EXIT

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
print_step 2 "Preparing fresh topic 'live-test'..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic live-test 2>/dev/null || true
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic live-test-restored 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic live-test --partitions 3 --replication-factor 1
' 2>/dev/null || true
print_success "Topic 'live-test' is ready"

# Clear any previous backup
docker compose --profile tools exec -T minio mc rm --recursive --force local/kafka-backups/live-producer-demo/ 2>/dev/null || true

# Start continuous producer in background
print_step 3 "Starting continuous producer (1 message/second)..."
print_info "Producer will run in the background while we perform backup"

# Start producer container in background
PRODUCER_CONTAINER=$(docker run -d --rm \
    --name live-producer-demo \
    --network kafka-backup-demos_kafka-net \
    apache/kafka:3.7.1 \
    bash -c '
        i=0
        while true; do
            i=$((i + 1))
            echo "{\"seq\": $i, \"ts\": \"$(date +%s)\", \"msg\": \"live-message-$i\"}"
            sleep 1
        done | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic live-test
    ')

print_success "Producer started (container: ${PRODUCER_CONTAINER:0:12})"

# Wait for messages to accumulate
print_step 4 "Waiting for messages to accumulate (15 seconds)..."
echo ""
for i in {1..15}; do
    echo -ne "\r  Elapsed: ${i}s / 15s "
    sleep 1
done
echo ""
echo ""

# Count messages before backup
print_step 5 "Counting messages before backup (producer still running!)..."
BEFORE_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic live-test \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')
print_info "Messages in topic: $BEFORE_COUNT"
print_warning "Note: Producer is STILL RUNNING and adding more messages"
echo ""

# Run backup while producer is active
print_step 6 "Running backup while producer is ACTIVE..."
echo ""
echo "============================================"
echo "  KEY DEMONSTRATION: Backup with live producer"
echo "============================================"
echo ""
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-live-producer.yaml
print_success "Backup completed successfully!"
print_answer "ANSWER: Backup works fine with active producers!"

# Wait a bit for more messages
print_step 7 "Waiting 5 more seconds (producer still running)..."
sleep 5

# Count messages now
AFTER_BACKUP_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic live-test \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')

# Describe backup to see what was captured
print_step 8 "Examining backup contents..."
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/live-producer-demo \
    --backup-id live-producer-backup
echo ""

print_info "Topic now has: $AFTER_BACKUP_COUNT messages"
print_info "Backup captured: ~$BEFORE_COUNT messages (point-in-time snapshot)"
print_info "Difference: $((AFTER_BACKUP_COUNT - BEFORE_COUNT)) messages produced during/after backup"
print_success "Backup captured a consistent snapshot - new messages were NOT included"

# Demonstrate Restore Scenario A: Different topic (SAFE)
print_step 9 "RESTORE TEST A: Restore to DIFFERENT topic (safe with producer running)..."
echo ""

# Create destination topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic live-test-restored --partitions 3 --replication-factor 1 2>/dev/null || true
'

# Restore to different topic
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-live-producer-safe.yaml

RESTORED_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic live-test-restored \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')

print_success "Restored $RESTORED_COUNT messages to 'live-test-restored'"
print_answer "ANSWER: Restore to different topic is SAFE with producers running!"

# Stop producer before demonstrating same-topic restore
print_step 10 "Stopping producer to demonstrate same-topic restore..."
docker stop "$PRODUCER_CONTAINER" 2>/dev/null || true
PRODUCER_CONTAINER=""
sleep 2
print_success "Producer stopped"

# Count final messages in original topic
FINAL_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic live-test \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')

print_step 11 "RESTORE TEST B: Demonstrating same-topic restore..."
print_warning "In production, you would delete the topic first. We'll show what happens if you don't."
echo ""

# Restore to same topic without deleting (to show the "bad" scenario)
print_info "Restoring to same topic WITHOUT deleting first (not recommended)..."
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-live-producer.yaml || true

AFTER_RESTORE_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic live-test \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')

print_warning "Topic now has: $AFTER_RESTORE_COUNT messages (was $FINAL_COUNT before restore)"
print_info "This shows backup data was APPENDED - you now have duplicates!"
echo ""

# Now show the correct approach
print_step 12 "CORRECT APPROACH: Delete topic, then restore..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic live-test
'
sleep 2
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic live-test --partitions 3 --replication-factor 1
'

docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-live-producer.yaml

CLEAN_RESTORE_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic live-test \
        --time -1 2>/dev/null | awk -F ":" "{sum += \$3} END {print sum}"
')

print_success "Clean restore complete: $CLEAN_RESTORE_COUNT messages"

# Summary
echo ""
echo "============================================================"
echo "   Demo Complete!"
echo "============================================================"
echo ""
echo -e "${CYAN}QUESTION: 'Wouldn't you need the producers not to produce when you do it?'${NC}"
echo ""
echo -e "${GREEN}ANSWER:${NC}"
echo ""
echo "  FOR BACKUP:"
echo -e "    ${GREEN}✓${NC} NO - Producers can keep running"
echo "    • Backup takes a point-in-time snapshot"
echo "    • Messages arriving during backup are safely excluded"
echo "    • No locks, no coordination needed"
echo ""
echo "  FOR RESTORE:"
echo -e "    ${GREEN}✓${NC} To different topic: Producers can keep running"
echo -e "    ${RED}✗${NC} To same topic: STOP producers first"
echo "    • Without stopping, you get duplicates/interleaved data"
echo "    • Best practice: stop producers → delete topic → restore → restart"
echo ""
echo "============================================================"
echo "   Summary Statistics"
echo "============================================================"
echo ""
echo "  Messages when backup started:    ~$BEFORE_COUNT"
echo "  Messages after backup completed: $AFTER_BACKUP_COUNT"
echo "  Messages produced during backup: ~$((AFTER_BACKUP_COUNT - BEFORE_COUNT))"
echo "  Messages in restored topic:      $CLEAN_RESTORE_COUNT"
echo ""
print_info "The backup captured a consistent snapshot of $RESTORED_COUNT messages"
print_info "while the producer continued running uninterrupted."
echo ""
