#!/bin/bash
# Consumer Lag Monitoring Demo with Klag
# Demonstrates: alert-driven backup timing and restore recovery monitoring.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

export KLAG_VERSION="${KLAG_VERSION:-0.2.3}"
export KLAG_IMAGE="${KLAG_IMAGE:-ghcr.io/themoah/klag:${KLAG_VERSION}}"
export PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-quay.io/prometheus/prometheus:v2.54.1}"
export GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:11.1.4}"

echo "================================================"
echo "   Consumer Lag Monitoring Demo (Klag)"
echo "================================================"
echo ""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

print_step() {
    echo -e "${BLUE}[Step $1]${NC} $2"
    echo ""
}

print_info() {
    echo -e "${YELLOW}->${NC} $1"
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

port_is_available() {
    ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

choose_port() {
    local var_name="$1"
    local default_port="$2"
    local selected_port="${!var_name:-$default_port}"

    if [ -z "${!var_name:-}" ]; then
        while ! port_is_available "$selected_port"; do
            selected_port=$((selected_port + 1))
        done
        if [ "$selected_port" != "$default_port" ]; then
            print_info "Port ${default_port} is in use; using ${selected_port} for ${var_name}."
        fi
    fi

    export "${var_name}=${selected_port}"
}

choose_port KLAG_METRICS_PORT 8888
choose_port PROMETHEUS_PORT 9091
choose_port GRAFANA_PORT 3000

METRICS_URL="http://localhost:${KLAG_METRICS_PORT}/metrics"
PROMETHEUS_URL="http://localhost:${PROMETHEUS_PORT}"
TOPIC_NAME="lag-demo-topic"
CONSUMER_GROUP="lag-demo-consumers"

cleanup() {
    echo ""
    print_info "Cleaning up demo consumer container..."
    docker stop lag-demo-consumer >/dev/null 2>&1 || true
    docker rm lag-demo-consumer >/dev/null 2>&1 || true
    print_success "Cleanup complete"
}

trap cleanup EXIT

fetch_metrics() {
    curl -s "$METRICS_URL" 2>/dev/null || true
}

metric_sum() {
    local metric="$1"
    fetch_metrics | grep "^${metric}{" | grep "$CONSUMER_GROUP" | grep "$TOPIC_NAME" | awk '
        {sum += $2; found = 1}
        END {if (found) print sum}
    '
}

metric_sum_for_group() {
    local metric="$1"
    fetch_metrics | grep "^${metric}{" | grep "$CONSUMER_GROUP" | awk '
        {sum += $2; found = 1}
        END {if (found) print sum}
    '
}

metric_first() {
    local metric="$1"
    fetch_metrics | grep "^${metric}{" | grep "$CONSUMER_GROUP" | grep "$TOPIC_NAME" | awk 'NR == 1 {print $2}'
}

total_lag() {
    local aggregate
    aggregate=$(metric_sum_for_group "klag_consumer_lag_sum")
    if [ -n "$aggregate" ]; then
        echo "$aggregate"
        return
    fi
    metric_sum "klag_consumer_lag"
}

is_zero() {
    awk -v value="${1:-0}" 'BEGIN { exit ((value + 0) == 0 ? 0 : 1) }'
}

print_optional_metric() {
    local label="$1"
    local metric="$2"
    local suffix="${3:-}"
    local value
    value=$(metric_first "$metric")
    if [ -n "$value" ]; then
        print_metric "$label: $value$suffix"
    else
        print_metric "$label: not emitted yet"
    fi
}

prom_query() {
    local query="$1"
    curl -sG "${PROMETHEUS_URL}/api/v1/query" --data-urlencode "query=$query" 2>/dev/null || true
}

print_klag_snapshot() {
    local heading="$1"
    echo "$heading"
    echo "---"
    fetch_metrics | grep -E "^klag_consumer_(lag|group)" | grep "$CONSUMER_GROUP" | head -30 || true
    echo "---"
    echo ""
}

print_step 1 "Starting Docker services with monitoring profile..."
print_info "Starting core Kafka, MinIO, and topic setup services..."
docker compose up -d
print_info "Waiting for Kafka setup to settle (25 seconds)..."
sleep 25
print_info "Clearing previous lag-demo backup objects..."
docker compose run --rm --entrypoint /bin/sh minio-setup -c "
    mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null
    mc mb local/kafka-backups --ignore-existing >/dev/null 2>&1 || true
    mc rm --recursive --force local/kafka-backups/lag-demo >/dev/null 2>&1 || true
"

print_info "Starting monitoring services with ${KLAG_IMAGE}..."
docker compose --profile monitoring up -d
sleep 12
print_success "Services are running: klag, prometheus, grafana"

print_step 2 "Creating topic '$TOPIC_NAME' with 3 partitions..."
docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic $TOPIC_NAME 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic $TOPIC_NAME --partitions 3 --replication-factor 1
" 2>/dev/null || true
print_success "Topic '$TOPIC_NAME' is ready"

print_step 3 "Verifying Klag metrics endpoint..."
sleep 5
KLAG_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$METRICS_URL" 2>/dev/null || echo "000")
if [ "$KLAG_STATUS" = "200" ]; then
    print_success "Klag metrics endpoint is healthy (HTTP 200)"
else
    print_error "Klag metrics endpoint returned HTTP $KLAG_STATUS"
    print_info "Waiting additional 10 seconds for Klag to initialize..."
    sleep 10
fi

print_step 4 "Priming a paused consumer group..."
docker stop lag-demo-consumer >/dev/null 2>&1 || true
docker rm lag-demo-consumer >/dev/null 2>&1 || true
docker compose --profile tools run --rm kafka-cli bash -c "
    echo '{\"id\":0,\"data\":\"prime-consumer-group\"}' | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME

    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME \
        --group $CONSUMER_GROUP \
        --from-beginning \
        --max-messages 1 \
        --timeout-ms 15000 >/tmp/lag-demo-prime.out

    kafka-consumer-groups.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --describe \
        --group $CONSUMER_GROUP || true
"
sleep 5
print_success "Consumer group '$CONSUMER_GROUP' has a committed offset and is paused"

print_step 5 "Producing 500 messages while the consumer group is paused..."
docker compose --profile tools run --rm kafka-cli bash -c "
    for i in \$(seq 1 500); do
        echo \"{\\\"id\\\": \$i, \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\", \\\"data\\\": \\\"message-\$i\\\"}\"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME
"
print_success "Produced 500 messages to $TOPIC_NAME"

print_step 6 "Observing Klag metrics while lag builds..."
sleep 10
print_klag_snapshot "Klag metrics for '$CONSUMER_GROUP':"

TOTAL_LAG=$(total_lag)
TOTAL_LAG=${TOTAL_LAG:-0}
print_metric "Total lag: $TOTAL_LAG messages"
print_optional_metric "Lag velocity (positive = falling behind)" "klag_consumer_lag_velocity"
print_optional_metric "Time-based lag" "klag_consumer_lag_ms" " ms"
print_optional_metric "Retention used" "klag_consumer_lag_retention_percent" "%"
echo ""

print_step 7 "Querying Prometheus for Klag data..."
echo "Prometheus target health:"
prom_query 'up{job="klag"}' | head -c 500
echo ""
echo ""

echo "Aggregate lag by consumer_group:"
prom_query 'sum(klag_consumer_lag_sum) by (consumer_group)' | head -c 500
echo ""
echo ""

echo "Native lag velocity:"
prom_query "klag_consumer_lag_velocity{consumer_group=\"$CONSUMER_GROUP\"}" | head -c 500
echo ""
echo ""
print_success "Prometheus is scraping Klag"

print_step 8 "Taking a backup while retention-risk metrics are visible..."
RETENTION_PERCENT=$(metric_first "klag_consumer_lag_retention_percent")
if [ -n "$RETENTION_PERCENT" ]; then
    print_info "Current retention used for lag: ${RETENTION_PERCENT}%"
else
    print_info "Retention percent is not emitted yet in this short local run; in production alert on klag_consumer_lag_retention_percent > 80."
fi
print_info "Current lag before backup: $TOTAL_LAG messages"
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-lag-demo.yaml
print_success "Backup completed to s3://kafka-backups/lag-demo"

print_step 9 "Producing 200 additional messages while the consumer group remains paused..."
docker stop lag-demo-consumer >/dev/null 2>&1 || true
docker rm lag-demo-consumer >/dev/null 2>&1 || true
print_info "No active consumer is running"

docker compose --profile tools run --rm kafka-cli bash -c "
    for i in \$(seq 501 700); do
        echo \"{\\\"id\\\": \$i, \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\", \\\"data\\\": \\\"message-\$i\\\"}\"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME
"
print_success "Produced 200 additional messages (501-700)"

print_step 10 "Simulating data loss by deleting the consumer group and topic..."
docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 --delete --group $CONSUMER_GROUP 2>/dev/null || true
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic $TOPIC_NAME
"
sleep 12
if fetch_metrics | grep "$CONSUMER_GROUP" >/dev/null 2>&1; then
    print_info "Klag still has a recent sample for $CONSUMER_GROUP; it should disappear after stale-group cleanup."
else
    print_success "Klag stale-group cleanup removed metrics for $CONSUMER_GROUP"
fi

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
print_success "Data restored from backup"

print_step 12 "Restarting consumer and monitoring recovery ETA..."
docker compose --profile tools run --rm -d --name lag-demo-consumer kafka-cli bash -c "
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic $TOPIC_NAME \
        --group $CONSUMER_GROUP \
        --from-beginning \
        --timeout-ms 30000
" >/dev/null

for i in 1 2 3 4 5 6; do
    sleep 5
    LAG=$(total_lag)
    ETA=$(metric_first "klag_consumer_lag_time_to_close_seconds")
    VELOCITY=$(metric_first "klag_consumer_lag_velocity")
    if [ -n "$ETA" ]; then
        ETA_TEXT="${ETA}s"
    else
        ETA_TEXT="not emitted"
    fi
    print_metric "After ${i}x5 seconds: lag=${LAG:-0} messages, velocity=${VELOCITY:-not emitted}, time_to_close=${ETA_TEXT}"
done
echo ""

print_step 13 "Validating lag recovery and restored message count..."
sleep 5
FINAL_LAG=$(total_lag)
FINAL_LAG=${FINAL_LAG:-0}

if is_zero "$FINAL_LAG"; then
    print_success "VALIDATION PASSED: Consumer lag recovered to 0"
else
    print_info "Final lag: $FINAL_LAG messages; consumer may still be catching up"
fi

MSG_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic $TOPIC_NAME \
        --time -1 2>/dev/null | awk -F ':' '{sum += \$3} END {print sum}'
")
print_info "Total messages in restored topic: $MSG_COUNT"

docker stop lag-demo-consumer >/dev/null 2>&1 || true
docker rm lag-demo-consumer >/dev/null 2>&1 || true

print_step 14 "Demo Summary"

echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "What we demonstrated:"
echo "  1. Started Klag ${KLAG_VERSION}, Prometheus, and Grafana"
echo "  2. Created a lagging consumer group"
echo "  3. Observed raw lag, native aggregates, lag velocity, and optional DLP/time metrics"
echo "  4. Used retention-percent as the alert-driven backup trigger"
echo "  5. Took a kafka-backup backup while lag existed"
echo "  6. Simulated data loss and observed Klag stale-group cleanup"
echo "  7. Restored from backup and monitored recovery ETA"
echo ""
print_info "Monitoring Endpoints:"
echo "  Klag Metrics:  ${METRICS_URL}"
echo "  Prometheus:    ${PROMETHEUS_URL}"
echo "  Grafana:       http://localhost:${GRAFANA_PORT} (admin/admin)"
echo ""
print_info "Key Prometheus Queries:"
echo '  sum(klag_consumer_lag_sum) by (consumer_group)'
echo '  klag_consumer_lag_velocity{topic="lag-demo-topic"}'
echo '  klag_consumer_lag_ms{topic="lag-demo-topic"} / 1000 / 60'
echo '  klag_consumer_lag_time_to_close_seconds{topic="lag-demo-topic"}'
echo '  max by (consumer_group, topic) (klag_consumer_lag_retention_percent) > 80'
echo ""
print_info "Grafana dashboard:"
echo "  http://localhost:${GRAFANA_PORT}/dashboards"
echo ""
print_info "To stop monitoring services:"
echo "  docker compose --profile monitoring down"
echo ""
