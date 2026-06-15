#!/bin/bash
# Pipelined Segment Flush Benchmark Scenario
# Demonstrates the v0.15.8 backup improvement that overlaps segment flush
# compression/upload with continued Kafka fetching.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_ROOT/.." && pwd)"

PROFILE=${BENCHMARK_PROFILE:-"quick"}
DATA_SIZE=${BENCHMARK_DATA_SIZE:-100}
MESSAGE_COUNT=${BENCHMARK_MESSAGE_COUNT:-10000}
ITERATIONS=${BENCHMARK_ITERATIONS:-1}
RESULTS_FILE=${BENCHMARK_RESULTS_FILE:-"$BENCHMARK_ROOT/results/pipelined-flush.json"}
CURRENT_IMAGE=${KAFKA_BACKUP_IMAGE:-"osodevops/kafka-backup:latest"}
BASELINE_IMAGE=${KAFKA_BACKUP_BASELINE_IMAGE:-""}
SEGMENT_MAX_BYTES=${PIPELINED_SEGMENT_MAX_BYTES:-8388608}

echo "Running Pipelined Segment Flush Benchmark"
echo "  Profile: $PROFILE"
echo "  Data size: ${DATA_SIZE}MB"
echo "  Messages: $MESSAGE_COUNT"
echo "  Iterations: $ITERATIONS"
echo "  Segment max bytes: $SEGMENT_MAX_BYTES"
echo "  Current image: $CURRENT_IMAGE"
if [ -n "$BASELINE_IMAGE" ]; then
    echo "  Baseline image: $BASELINE_IMAGE"
fi
echo ""

cd "$PROJECT_ROOT"

sanitize_label() {
    echo "$1" | tr '/:@' '---' | tr -cd '[:alnum:]_.-'
}

clear_prefix() {
    local prefix="$1"
    docker compose run --rm --entrypoint /bin/sh minio-setup -c "
        mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null
        mc mb local/kafka-backups --ignore-existing >/dev/null 2>&1 || true
        mc rm --recursive --force local/kafka-backups/${prefix} >/dev/null 2>&1 || true
    " >/dev/null
}

average() {
    awk -v values="$*" 'BEGIN {
        split(values, parts, " ");
        for (i in parts) {
            if (parts[i] != "") {
                sum += parts[i];
                count++;
            }
        }
        if (count == 0) {
            print "0";
        } else {
            printf "%.3f", sum / count;
        }
    }'
}

run_image() {
    local label="$1"
    local image="$2"
    local safe_label
    safe_label=$(sanitize_label "$label")
    local times=()
    local mbps_values=()
    local records="0"
    local segments="0"

    for iter in $(seq 1 "$ITERATIONS"); do
        local prefix="benchmark-pipelined-flush-${safe_label}-${iter}"
        local backup_id="pipelined-flush-${safe_label}-${iter}"
        local config_file="/tmp/${backup_id}.yaml"
        local output_file="/tmp/${backup_id}.log"

        echo "[$label] Iteration $iter of $ITERATIONS"
        clear_prefix "$prefix"

        cat > "$config_file" << EOF
mode: backup
backup_id: "$backup_id"

source:
  bootstrap_servers:
    - kafka-broker-1:9092
  topics:
    include:
      - benchmark-data

storage:
  backend: s3
  bucket: kafka-backups
  region: us-east-1
  prefix: $prefix
  endpoint: http://minio:9000
  path_style: true
  allow_http: true
  access_key_id: minioadmin
  secret_access_key: minioadmin

backup:
  compression: zstd
  continuous: false
  segment_max_bytes: $SEGMENT_MAX_BYTES
  segment_max_records: 1000000
  max_concurrent_partitions: 3
EOF

        local start_time
        local end_time
        local elapsed
        local mbps
        start_time=$(date +%s.%N)
        KAFKA_BACKUP_IMAGE="$image" docker compose --profile tools run --rm \
            -v /tmp:/tmp \
            kafka-backup backup --config "$config_file" 2>&1 | tee "$output_file" | tail -20
        end_time=$(date +%s.%N)

        elapsed=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN { printf "%.3f", end - start }')
        mbps=$(awk -v size="$DATA_SIZE" -v elapsed="$elapsed" 'BEGIN { if (elapsed > 0) printf "%.2f", size / elapsed; else print "0.00" }')
        records=$(awk -F': ' '/Records processed:/ {print $2}' "$output_file" | tail -1)
        segments=$(awk -F': ' '/Segments written:/ {print $2}' "$output_file" | tail -1)

        times+=("$elapsed")
        mbps_values+=("$mbps")
        echo "  ${label}: ${elapsed}s (${mbps} MB/s), records=${records:-0}, segments=${segments:-0}"
        echo ""
    done

    local avg_time
    local avg_mbps
    avg_time=$(average "${times[@]}")
    avg_mbps=$(average "${mbps_values[@]}")

    echo "${avg_time}|${avg_mbps}|${records:-0}|${segments:-0}"
}

CURRENT_RESULT=$(run_image "current" "$CURRENT_IMAGE" | tee /tmp/pipelined-current.out | tail -1)
CURRENT_TIME=$(echo "$CURRENT_RESULT" | cut -d'|' -f1)
CURRENT_MBPS=$(echo "$CURRENT_RESULT" | cut -d'|' -f2)
CURRENT_RECORDS=$(echo "$CURRENT_RESULT" | cut -d'|' -f3)
CURRENT_SEGMENTS=$(echo "$CURRENT_RESULT" | cut -d'|' -f4)

BASELINE_TIME=""
BASELINE_MBPS=""
BASELINE_RECORDS=""
BASELINE_SEGMENTS=""
SPEEDUP_PCT=""

if [ -n "$BASELINE_IMAGE" ]; then
    BASELINE_RESULT=$(run_image "baseline" "$BASELINE_IMAGE" | tee /tmp/pipelined-baseline.out | tail -1)
    BASELINE_TIME=$(echo "$BASELINE_RESULT" | cut -d'|' -f1)
    BASELINE_MBPS=$(echo "$BASELINE_RESULT" | cut -d'|' -f2)
    BASELINE_RECORDS=$(echo "$BASELINE_RESULT" | cut -d'|' -f3)
    BASELINE_SEGMENTS=$(echo "$BASELINE_RESULT" | cut -d'|' -f4)
    SPEEDUP_PCT=$(awk -v base="$BASELINE_TIME" -v current="$CURRENT_TIME" 'BEGIN {
        if (base > 0 && current > 0) printf "%.1f", ((base - current) / base) * 100;
        else print "";
    }')
fi

echo "Pipelined Flush Results:"
echo "  Current: ${CURRENT_TIME}s (${CURRENT_MBPS} MB/s), records=${CURRENT_RECORDS:-0}, segments=${CURRENT_SEGMENTS:-0}"
if [ -n "$BASELINE_IMAGE" ]; then
    echo "  Baseline: ${BASELINE_TIME}s (${BASELINE_MBPS} MB/s), records=${BASELINE_RECORDS:-0}, segments=${BASELINE_SEGMENTS:-0}"
    echo "  Wall-time speedup: ${SPEEDUP_PCT}%"
else
    echo "  Baseline comparison skipped. Set KAFKA_BACKUP_BASELINE_IMAGE to compare tags."
fi

if [ -f "$RESULTS_FILE" ]; then
    python3 << EOF
import json

with open("$RESULTS_FILE", "r") as f:
    results = json.load(f)

scenario = {
    "current_image": "$CURRENT_IMAGE",
    "current_backup_mbps": float("$CURRENT_MBPS" or 0),
    "current_time_s": float("$CURRENT_TIME" or 0),
    "current_records": int(float("$CURRENT_RECORDS" or 0)),
    "current_segments": int(float("$CURRENT_SEGMENTS" or 0)),
    "segment_max_bytes": int("$SEGMENT_MAX_BYTES"),
    "data_size_mb": int("$DATA_SIZE"),
    "iterations": int("$ITERATIONS"),
}

if "$BASELINE_IMAGE":
    scenario.update({
        "baseline_image": "$BASELINE_IMAGE",
        "baseline_backup_mbps": float("$BASELINE_MBPS" or 0),
        "baseline_time_s": float("$BASELINE_TIME" or 0),
        "baseline_records": int(float("$BASELINE_RECORDS" or 0)),
        "baseline_segments": int(float("$BASELINE_SEGMENTS" or 0)),
        "speedup_pct": float("$SPEEDUP_PCT" or 0),
    })

results.setdefault("scenarios", {})["pipelined-flush"] = scenario

with open("$RESULTS_FILE", "w") as f:
    json.dump(results, f, indent=2)
EOF
fi

echo "Pipelined segment flush benchmark complete"
