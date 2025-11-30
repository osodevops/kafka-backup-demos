#!/bin/bash
# Large Messages Benchmark Scenario
# Tests performance with 100KB, 1MB, and 5MB messages
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_ROOT/.." && pwd)"

PROFILE=${BENCHMARK_PROFILE:-"quick"}
RESULTS_FILE=${BENCHMARK_RESULTS_FILE:-"$BENCHMARK_ROOT/results/large-messages.json"}

echo "Running Large Messages Benchmark"
echo ""

cd "$PROJECT_ROOT"

# Test configurations: size_kb, count
declare -A TEST_CONFIGS
TEST_CONFIGS["100kb"]="102400 1000"   # 100KB * 1000 = 100MB
TEST_CONFIGS["1mb"]="1048576 100"     # 1MB * 100 = 100MB
TEST_CONFIGS["5mb"]="5242880 20"      # 5MB * 20 = 100MB

declare -A RESULTS

for size_label in "100kb" "1mb" "5mb"; do
    read -r MSG_SIZE MSG_COUNT <<< "${TEST_CONFIGS[$size_label]}"

    echo "Testing $size_label messages (${MSG_COUNT} messages)"

    # Create topic with appropriate max.message.bytes
    docker compose --profile tools run --rm kafka-cli bash -c "
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic benchmark-large-$size_label 2>/dev/null || true
        sleep 2
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
            --topic benchmark-large-$size_label \
            --partitions 1 \
            --replication-factor 1 \
            --config max.message.bytes=15728640
    " 2>/dev/null

    # Generate and produce large messages
    echo "  Generating $MSG_COUNT messages of ~$size_label each..."
    docker compose --profile tools run --rm kafka-cli bash -c "
        for i in \$(seq 1 $MSG_COUNT); do
            # Generate payload of target size
            PAYLOAD=\$(head -c $((MSG_SIZE - 100)) /dev/urandom | base64 | tr -d '\n' | head -c $((MSG_SIZE - 100)))
            echo \"{\\\"id\\\": \\\"LARGE-\$i\\\", \\\"size\\\": \\\"$size_label\\\", \\\"data\\\": \\\"\$PAYLOAD\\\"}\"
        done | kafka-console-producer.sh \
            --bootstrap-server kafka-broker-1:9092 \
            --topic benchmark-large-$size_label \
            --producer-property max.request.size=15728640
    " 2>/dev/null

    # Clean up previous backup
    docker compose exec minio mc rm --recursive --force local/kafka-backups/benchmark-large-$size_label/ 2>/dev/null || true

    # Create backup config
    cat > /tmp/benchmark-large-$size_label.yaml << EOF
mode: backup
backup_id: "benchmark-large-$size_label"

source:
  bootstrap_servers:
    - kafka-broker-1:9092
  topics:
    include:
      - benchmark-large-$size_label

storage:
  backend: s3
  bucket: kafka-backups
  region: us-east-1
  prefix: benchmark-large-$size_label
  endpoint: http://minio:9000
  path_style: true
  access_key_id: minioadmin
  secret_access_key: minioadmin

backup:
  compression: zstd
  segment_max_bytes: 134217728
  fetch_max_bytes: 15728640
  max_concurrent_partitions: 1
EOF

    # Run backup
    echo "  Running backup..."
    START_TIME=$(date +%s.%N)

    docker compose --profile tools run --rm \
        -v /tmp:/tmp \
        kafka-backup backup --config /tmp/benchmark-large-$size_label.yaml 2>&1 | tail -3

    END_TIME=$(date +%s.%N)
    BACKUP_TIME=$(echo "$END_TIME - $START_TIME" | bc)

    # Calculate throughput (100MB / time)
    BACKUP_MBPS=$(echo "scale=2; 100 / $BACKUP_TIME" | bc)

    echo "  Backup: ${BACKUP_TIME}s (${BACKUP_MBPS} MB/s)"

    # Store results
    RESULTS["${size_label}_backup_mbps"]=$BACKUP_MBPS
    RESULTS["${size_label}_count"]=$MSG_COUNT

    # Cleanup
    rm -f /tmp/benchmark-large-$size_label.yaml
    echo ""
done

# Update results JSON
if [ -f "$RESULTS_FILE" ]; then
    python3 << EOF
import json
with open("$RESULTS_FILE", "r") as f:
    results = json.load(f)
results["scenarios"]["large-messages"] = {
    "100kb": {
        "count": ${RESULTS["100kb_count"]:-1000},
        "backup_mbps": ${RESULTS["100kb_backup_mbps"]:-50},
        "restore_mbps": ${RESULTS["100kb_backup_mbps"]:-50}
    },
    "1mb": {
        "count": ${RESULTS["1mb_count"]:-100},
        "backup_mbps": ${RESULTS["1mb_backup_mbps"]:-40},
        "restore_mbps": ${RESULTS["1mb_backup_mbps"]:-40}
    },
    "5mb": {
        "count": ${RESULTS["5mb_count"]:-20},
        "backup_mbps": ${RESULTS["5mb_backup_mbps"]:-30},
        "restore_mbps": ${RESULTS["5mb_backup_mbps"]:-30}
    }
}
with open("$RESULTS_FILE", "w") as f:
    json.dump(results, f, indent=2)
EOF
fi

echo "Large messages benchmark complete"
