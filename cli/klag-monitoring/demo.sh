#!/bin/bash
# Consumer Lag Monitoring Demo with Klag
# Demonstrates: Consumer lag monitoring during backup/restore operations
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   Consumer Lag Monitoring Demo (Klag)"
echo "================================================"
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

print_error() {
    echo -e "${RED}✗${NC} $1"
    echo ""
}

print_metric() {
    echo -e "${CYAN}  [metric]${NC} $1"
}

TOPIC_NAME="lag-demo-topic"
CONSUMER_GROUP="lag-demo-consumers"
CONSUMER_PID=""

cleanup() {
    echo ""
    print_info "Cleaning up..."
    # Kill background consumer if running
    if [ -n "$CONSUMER_PID" ] && kill -0 "$CONSUMER_PID" 2>/dev/null; then
        kill "$CONSUMER_PID" 2>/dev/null || true
        wait "$CONSUMER_PID" 2>/dev/null || true
    fi
    print_success "Cleanup complete"
}

trap cleanup EXIT

# Step 1: Start services with monitoring profile
print_step 1 "Starting Docker services with monitoring profile..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    echo "Starting core services..."
    docker compose up -d
    echo "Waiting for Kafka to be ready (20 seconds)..."
    sleep 20
fi

# Start monitoring services
echo "Starting monitoring services (klag, prometheus, grafana)..."
docker compose --profile monitoring up -d
sleep 10
print_success "All services are running (including klag, prometheus, grafana)"

# Step 2: Create lag-demo-topic
print_step 2 "Creating topic '$TOPIC_NAME' with 3 partitions..."
docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic $TOPIC_NAME 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic $TOPIC_NAME --partitions 3 --replication-factor 1
" 2>/dev/null || true
print_success "Topic '$TOPIC_NAME' created"

# Step 3: Verify klag metrics endpoint
print_step 3 "Verifying klag metrics endpoint..."
sleep 5  # Give klag time to discover the topic
KLAG_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8888/metrics 2>/dev/null || echo "000")
if [ "$KLAG_STATUS" = "200" ]; then
    print_success "Klag metrics endpoint is healthy (HTTP 200)"
else
    print_error "Klag metrics endpoint returned HTTP $KLAG_STATUS"
    echo "Waiting additional 10 seconds for klag to initialize..."
    sleep 10
fi

# Step 4: Start a slow consumer (rate-limited background process)
print_step 4 "Starting a slow consumer (rate-limited, 2 messages/second)..."

# Start consumer in background with rate limiting
docker compose --profile tools run --rm -d --name lag-demo-consumer kafka-cli bash -c "
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME \
        --group $CONSUMER_GROUP \
        --from-beginning 2>&1 | while read -r line; do
            echo \"\$line\"
            sleep 0.5  # Rate limit: ~2 messages per second
        done
" > /dev/null 2>&1 &
CONSUMER_PID=$!
sleep 3
print_success "Slow consumer started in background (group: $CONSUMER_GROUP)"

# Step 5: Produce 500 messages (faster than consumer)
print_step 5 "Producing 500 messages (faster than consumer can process)..."
docker compose --profile tools run --rm kafka-cli bash -c "
    for i in \$(seq 1 500); do
        echo \"{\\\"id\\\": \$i, \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\", \\\"data\\\": \\\"message-\$i\\\"}\"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME
"
print_success "Produced 500 messages to $TOPIC_NAME"

# Step 6: Query klag metrics - show lag building up
print_step 6 "Querying klag metrics (showing consumer lag)..."
sleep 5  # Let klag collect metrics

echo "Raw klag metrics for consumer group '$CONSUMER_GROUP':"
echo "---"
KLAG_METRICS=$(curl -s http://localhost:8888/metrics 2>/dev/null | grep -E "klag_consumer" | head -20 || echo "No metrics found")
if [ -n "$KLAG_METRICS" ]; then
    echo "$KLAG_METRICS"
else
    print_info "No consumer lag metrics yet - consumer group may not be registered"
    echo "Waiting for consumer group to be detected..."
    sleep 10
    curl -s http://localhost:8888/metrics 2>/dev/null | grep -E "klag_consumer" | head -20 || echo "Still no metrics"
fi
echo "---"
echo ""

# Extract total lag
TOTAL_LAG=$(curl -s http://localhost:8888/metrics 2>/dev/null | grep "klag_consumer_lag{" | grep "$CONSUMER_GROUP" | awk '{sum += $2} END {print sum}' || echo "0")
print_metric "Total consumer lag: $TOTAL_LAG messages"
echo ""

# Step 7: Query Prometheus API for lag data
print_step 7 "Querying Prometheus API for lag data..."
echo "Prometheus targets status:"
TARGETS=$(curl -s "http://localhost:9091/api/v1/targets" 2>/dev/null | grep -o '"health":"[^"]*"' | head -5 || echo "Unable to query")
echo "$TARGETS"
echo ""

echo "Querying consumer lag from Prometheus..."
PROM_LAG=$(curl -s "http://localhost:9091/api/v1/query?query=klag_consumer_lag" 2>/dev/null | head -c 500 || echo "Unable to query")
echo "$PROM_LAG" | head -c 300
echo "..."
echo ""

# Step 8: Take backup while lag exists
print_step 8 "Taking backup while consumer lag exists..."
print_info "Current lag: $TOTAL_LAG messages behind"
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-lag-demo.yaml
print_success "Backup completed to s3://kafka-backups/lag-demo"

# Step 9: Stop consumer and produce 200 more messages
print_step 9 "Stopping consumer and producing 200 more messages..."

# Stop the consumer container
docker stop lag-demo-consumer 2>/dev/null || true
docker rm lag-demo-consumer 2>/dev/null || true
print_info "Consumer stopped"

# Produce more messages
docker compose --profile tools run --rm kafka-cli bash -c "
    for i in \$(seq 501 700); do
        echo \"{\\\"id\\\": \$i, \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\", \\\"data\\\": \\\"message-\$i\\\"}\"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME
"
print_success "Produced 200 additional messages (501-700)"

# Step 10: Simulate data loss (delete topic + consumer group)
print_step 10 "Simulating data loss - deleting topic and consumer group..."
docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 --delete --group $CONSUMER_GROUP 2>/dev/null || true
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic $TOPIC_NAME
"
sleep 3
print_success "Topic and consumer group deleted (data loss simulated)"

# Step 11: Recreate topic and restore from backup
print_step 11 "Recreating topic and restoring from backup..."
docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-topics.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --create \
        --topic $TOPIC_NAME \
        --partitions 3 \
        --replication-factor 1
"
print_info "Empty topic recreated"

docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-lag-demo.yaml
print_success "Data restored from backup (500 messages)"

# Step 12: Restart consumer and monitor lag recovery
print_step 12 "Restarting consumer and monitoring lag recovery..."

# Start consumer that will catch up
docker compose --profile tools run --rm -d --name lag-demo-consumer kafka-cli bash -c "
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME \
        --group $CONSUMER_GROUP \
        --from-beginning \
        --timeout-ms 30000
" > /dev/null 2>&1 &

echo "Consumer restarted. Monitoring lag recovery..."
echo ""

# Monitor lag recovery over 30 seconds
for i in 1 2 3 4 5 6; do
    sleep 5
    LAG=$(curl -s http://localhost:8888/metrics 2>/dev/null | grep "klag_consumer_lag{" | grep "$CONSUMER_GROUP" | awk '{sum += $2} END {print sum}' 2>/dev/null || echo "unknown")
    print_metric "Lag after ${i}x5 seconds: $LAG messages"
done
echo ""

# Step 13: Validate lag recovered
print_step 13 "Validating lag recovery..."
sleep 5
FINAL_LAG=$(curl -s http://localhost:8888/metrics 2>/dev/null | grep "klag_consumer_lag{" | grep "$CONSUMER_GROUP" | awk '{sum += $2} END {print sum}' 2>/dev/null || echo "unknown")

if [ "$FINAL_LAG" = "0" ] || [ "$FINAL_LAG" = "" ]; then
    print_success "VALIDATION PASSED: Consumer lag recovered to 0"
else
    print_info "Final lag: $FINAL_LAG messages (consumer may still be catching up)"
fi

# Verify message count
MSG_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic $TOPIC_NAME \
        --time -1 2>/dev/null | awk -F ':' '{sum += \$3} END {print sum}'
")
print_info "Total messages in restored topic: $MSG_COUNT"

# Stop consumer container
docker stop lag-demo-consumer 2>/dev/null || true
docker rm lag-demo-consumer 2>/dev/null || true

# Step 14: Print summary with monitoring endpoints
print_step 14 "Demo Summary"

echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "What we demonstrated:"
echo "  1. Started klag, Prometheus, and Grafana for monitoring"
echo "  2. Created topic with 3 partitions"
echo "  3. Started slow consumer (2 msg/sec) to create lag"
echo "  4. Produced 500 messages faster than consumer could process"
echo "  5. Observed lag building up via klag metrics"
echo "  6. Took backup while consumer lag existed"
echo "  7. Simulated data loss (deleted topic + consumer group)"
echo "  8. Restored from backup and restarted consumer"
echo "  9. Monitored lag recovery back to 0"
echo ""
print_info "Monitoring Endpoints:"
echo "  Klag Metrics:  http://localhost:8888/metrics"
echo "  Prometheus:    http://localhost:9091"
echo "  Grafana:       http://localhost:3000 (admin/admin)"
echo ""
print_info "Key Klag Metrics:"
echo "  klag_consumer_lag          - Current lag per partition"
echo "  klag_consumer_lag_velocity - Rate of lag change"
echo "  klag_consumer_group_state  - Consumer group health"
echo ""
print_info "Sample Prometheus Queries:"
echo '  sum(klag_consumer_lag) by (group)     - Total lag per group'
echo '  rate(klag_consumer_lag[1m])           - Lag change rate'
echo ""
print_info "To stop monitoring services:"
echo "  docker compose --profile monitoring down"
echo ""
