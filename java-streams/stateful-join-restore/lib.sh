#!/bin/bash
# Shared helpers for the stateful-join-restore demo scenarios.
# Source this file - do not execute it.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
print_step()    { echo -e "${BLUE}[Step $1]${NC} $2"; echo ""; }
print_info()    { echo -e "${YELLOW}-->${NC} $1"; }
print_success() { echo -e "${GREEN}OK${NC} $1"; echo ""; }
print_error()   { echo -e "${RED}FAIL${NC} $1"; echo ""; }

APP_ID="stateful-join-demo"
APP_CONTAINER="stateful-join-app"
GEN_CONTAINER="stateful-join-gen"
STATE_VOLUME="stateful-join-state"
NETWORK="kafka-backup-demos_kafka-net"
JAR_DIR="$SCRIPT_DIR/target"
HTTP="http://localhost:7071"
EVIDENCE_DIR="$SCRIPT_DIR/evidence"

INPUT_TOPICS="orders payments"
OUTPUT_TOPICS="orders_with_payments customer_revenue"
CHANGELOG_JOIN_THIS="$APP_ID-order-payment-join-this-join-store-changelog"
CHANGELOG_JOIN_OTHER="$APP_ID-order-payment-join-other-join-store-changelog"
CHANGELOG_REVENUE="$APP_ID-customer-revenue-store-changelog"
REPARTITION="$APP_ID-customer-revenue-repartition"
INTERNAL_TOPICS="$CHANGELOG_JOIN_THIS $CHANGELOG_JOIN_OTHER $CHANGELOG_REVENUE $REPARTITION"

# kafka-backup subcommands that take --path s3://... need explicit endpoint env
# (unlike --config runs, which read the endpoint from the YAML)
KB_S3_ENV="-e AWS_ENDPOINT_URL=http://minio:9000 -e AWS_ALLOW_HTTP=true -e AWS_REGION=us-east-1"

DEMO_RESULT="FAIL"
_verdict() {
    echo ""
    echo "================================================"
    if [ "$DEMO_RESULT" = "PASS" ]; then
        echo -e "   ${GREEN}RESULT: PASS${NC}"
    else
        echo -e "   ${RED}RESULT: FAIL${NC}"
    fi
    echo "================================================"
}
trap _verdict EXIT

# ------------------------------------------------------------------
# Wrappers
# ------------------------------------------------------------------

kcli() {
    docker compose --profile tools run --rm kafka-cli bash -c "$1" 2>/dev/null
}

kbackup() {
    docker compose --profile tools run --rm kafka-backup "$@"
}

kbackup_s3() {
    # shellcheck disable=SC2086
    docker compose --profile tools run --rm $KB_S3_ENV kafka-backup "$@"
}

# offset-rollback in the current CLI treats s3:// paths as local filesystem
# paths (snapshots silently land inside the ephemeral container), so mount a
# host directory and use a local path instead.
SNAPSHOT_DIR="$EVIDENCE_DIR/offset-snapshots"
kbackup_snap() {
    mkdir -p "$SNAPSHOT_DIR"
    docker compose --profile tools run --rm -v "$SNAPSHOT_DIR:/snapshots" kafka-backup "$@"
}

# ------------------------------------------------------------------
# Environment management
# ------------------------------------------------------------------

require_services() {
    if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
        print_info "Starting Docker services..."
        docker compose up -d
        echo "Waiting for Kafka to be ready (20 seconds)..."
        sleep 20
    fi
    print_success "Docker services are running"
}

build_app() {
    if [ ! -f "$JAR_DIR/stateful-join-demo.jar" ] || [ "${REBUILD:-0}" = "1" ]; then
        print_info "Building application jar..."
        (cd "$SCRIPT_DIR" && mvn -q clean package)
    fi
    print_success "Application jar ready: $JAR_DIR/stateful-join-demo.jar"
}

start_app() {
    docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$APP_CONTAINER" \
        --network "$NETWORK" \
        -v "$JAR_DIR:/app" \
        -v "$STATE_VOLUME:/state" \
        -p 7071:7071 \
        eclipse-temurin:17-jre \
        java -jar /app/stateful-join-demo.jar kafka-broker-1:9092 /state/kafka-streams >/dev/null
    print_info "Streams app container started"
}

stop_app() {
    # SIGTERM + 30s grace so the shutdown hook closes Streams cleanly (commits offsets)
    docker stop -t 30 "$APP_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
}

wipe_state_volume() {
    docker volume rm "$STATE_VOLUME" >/dev/null 2>&1 || true
}

wait_for_running() {
    local timeout="${1:-90}"
    local waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if curl -sf "$HTTP/health" 2>/dev/null | grep -q '"RUNNING"'; then
            print_success "Streams app is RUNNING (after ${waited}s)"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    print_error "Streams app did not reach RUNNING within ${timeout}s"
    docker logs --tail 30 "$APP_CONTAINER" || true
    exit 1
}

total_lag() {
    kcli "kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 --describe --group $APP_ID 2>/dev/null" \
        | awk 'NR>1 && $6 ~ /^[0-9]+$/ {sum += $6} END {print sum+0}'
}

wait_for_zero_lag() {
    local timeout="${1:-180}"
    local waited=0
    while [ "$waited" -lt "$timeout" ]; do
        local lag
        lag=$(total_lag)
        if [ "$lag" = "0" ]; then
            print_success "Consumer group lag is 0 (after ${waited}s)"
            return 0
        fi
        print_info "Lag: $lag - waiting..."
        sleep 5
        waited=$((waited + 5))
    done
    print_error "Consumer group lag did not reach 0 within ${timeout}s"
    exit 1
}

quiesce() {
    wait_for_zero_lag
    sleep 3   # allow one more commit interval to flush committed offsets
    stop_app
    print_success "Application quiesced (drained and stopped cleanly)"
}

# Streams members linger in the group for the session timeout after a clean
# close (leave-group-on-close is disabled by design in Kafka Streams), so
# deletion right after stopping can hit GroupNotEmptyException. Retry.
delete_consumer_group() {
    local waited=0 out
    while [ "$waited" -lt 60 ]; do
        out=$(kcli "kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 --delete --group $APP_ID 2>&1" || true)
        if ! echo "$out" | grep -q "GroupNotEmpty"; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 0
}

# kafka-backup logs to stdout; strip log lines when capturing JSON output
json_only() {
    sed -n '/^{/,$p'
}

wipe_backup_storage() {
    # Fresh S3 prefix per run: re-running a backup into an existing prefix
    # leaves a stale manifest alongside overwritten segments
    docker compose exec -T minio sh -c \
        'mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null 2>&1; mc rm -r --force local/kafka-backups/streams-join-demo/ >/dev/null 2>&1' || true
}

reset_environment() {
    print_info "Resetting demo environment..."
    docker rm -f "$GEN_CONTAINER" >/dev/null 2>&1 || true
    stop_app
    wipe_state_volume
    wipe_backup_storage
    rm -rf "$SNAPSHOT_DIR"
    delete_consumer_group
    kcli "
        for t in $INPUT_TOPICS $OUTPUT_TOPICS $INTERNAL_TOPICS; do
            kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic \$t 2>/dev/null || true
        done
        sleep 3
        for t in $INPUT_TOPICS $OUTPUT_TOPICS; do
            kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --if-not-exists --topic \$t --partitions 3 --replication-factor 1 2>/dev/null
        done
    " || true
    print_success "Environment reset (fresh topics, no state, no consumer group)"
}

recreate_external_topics() {
    kcli "
        for t in $INPUT_TOPICS $OUTPUT_TOPICS; do
            kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --if-not-exists --topic \$t --partitions 3 --replication-factor 1 2>/dev/null
        done
    "
    print_success "External topics recreated"
}

# Pre-create internal topics with the same configs Kafka Streams uses, so a
# changelog restore has correctly-shaped targets (compacted aggregate
# changelog, retention-based windowed join changelogs).
recreate_internal_topics() {
    kcli "
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --if-not-exists \
            --topic $CHANGELOG_JOIN_THIS --partitions 3 --replication-factor 1 \
            --config cleanup.policy=delete --config retention.ms=87900000 2>/dev/null
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --if-not-exists \
            --topic $CHANGELOG_JOIN_OTHER --partitions 3 --replication-factor 1 \
            --config cleanup.policy=delete --config retention.ms=87900000 2>/dev/null
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --if-not-exists \
            --topic $CHANGELOG_REVENUE --partitions 3 --replication-factor 1 \
            --config cleanup.policy=compact 2>/dev/null
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --if-not-exists \
            --topic $REPARTITION --partitions 3 --replication-factor 1 \
            --config cleanup.policy=delete --config retention.ms=-1 2>/dev/null
    "
    print_success "Internal topics recreated with Streams-compatible configs"
}

assert_internal_topics() {
    local actual expected
    actual=$(kcli "kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --list 2>/dev/null" | grep "^$APP_ID-" | sort)
    expected=$(printf '%s\n' $INTERNAL_TOPICS | sort)
    if [ "$actual" != "$expected" ]; then
        print_error "Internal topics do not match the names enumerated in the backup configs"
        echo "Expected:"; echo "$expected"
        echo "Actual:"; echo "$actual"
        echo "Update config/backup-streams-full.yaml and lib.sh if store names changed."
        exit 1
    fi
    print_success "Internal topic names match backup configs"
}

# ------------------------------------------------------------------
# Data generation
# ------------------------------------------------------------------

generate_batch() {
    local base_ts="$1"
    docker run --rm --network "$NETWORK" -v "$JAR_DIR:/app" eclipse-temurin:17-jre \
        java -cp /app/stateful-join-demo.jar com.osodevops.demo.DataGenerator \
        kafka-broker-1:9092 batch "$base_ts" >/dev/null 2>&1
    print_success "Deterministic batch produced (100 orders, 86 matching + 14 late payments)"
}

start_live_generator() {
    local base_ts="$1"
    docker rm -f "$GEN_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$GEN_CONTAINER" --network "$NETWORK" -v "$JAR_DIR:/app" eclipse-temurin:17-jre \
        java -cp /app/stateful-join-demo.jar com.osodevops.demo.DataGenerator \
        kafka-broker-1:9092 live "$base_ts" >/dev/null
    print_info "Live generator started (orders lead payments by 5s - deliberate skew)"
}

stop_live_generator() {
    docker rm -f "$GEN_CONTAINER" >/dev/null 2>&1 || true
    print_info "Live generator stopped"
}

# ------------------------------------------------------------------
# Evidence capture and assertions
# ------------------------------------------------------------------

dump_topic_sorted() {
    local topic="$1"
    kcli "kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic $topic --from-beginning --property print.key=true \
        --timeout-ms 15000 2>/dev/null | sort"
}

dump_topic_with_timestamps() {
    local topic="$1"
    kcli "kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic $topic --from-beginning --property print.timestamp=true \
        --property print.key=true --timeout-ms 15000 2>/dev/null | sort"
}

# Capture the full evidence set. The /state and /counters endpoints are read
# FIRST, so call this while the app is still running (before stop_app).
capture_evidence() {
    local label="$1"
    local dir="$EVIDENCE_DIR/$label"
    mkdir -p "$dir"

    curl -sf "$HTTP/state" > "$dir/state.json" 2>/dev/null || echo '{}' > "$dir/state.json"
    curl -sf "$HTTP/counters" > "$dir/counters.json" 2>/dev/null || echo '{}' > "$dir/counters.json"

    dump_topic_sorted "orders_with_payments" > "$dir/join_output.txt"
    # last value per key = final aggregate per customer (immune to update interleaving)
    dump_topic_sorted "customer_revenue" | awk -F'\t' '{last[$1]=$0} END {for (k in last) print last[k]}' | sort \
        > "$dir/revenue_final.txt"

    kcli "kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 --describe --group $APP_ID 2>/dev/null" \
        | awk 'NR>1 && $2 != "" {print $2, $3, $4}' | sort > "$dir/group_offsets.txt"

    dump_topic_with_timestamps "orders"   > "$dir/orders_ts.txt"
    dump_topic_with_timestamps "payments" > "$dir/payments_ts.txt"

    print_success "Evidence captured to evidence/$label/"
}

assert_files_equal() {
    local a="$1" b="$2" what="$3"
    if diff -u "$a" "$b" > /dev/null 2>&1; then
        print_success "IDENTICAL: $what"
    else
        print_error "MISMATCH: $what"
        diff -u "$a" "$b" | head -20 || true
        exit 1
    fi
}

assert_files_differ() {
    local a="$1" b="$2" what="$3"
    if diff -q "$a" "$b" > /dev/null 2>&1; then
        print_error "UNEXPECTEDLY IDENTICAL: $what"
        exit 1
    else
        print_success "DIFFERS AS EXPECTED: $what"
    fi
}

counter() {
    jq -r ".$2 // 0" "$EVIDENCE_DIR/$1/counters.json"
}
