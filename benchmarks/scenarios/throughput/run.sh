#!/bin/bash
# Throughput Benchmark Scenario
# Measures maximum backup/restore throughput
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_ROOT/.." && pwd)"

# Environment variables from parent
PROFILE=${BENCHMARK_PROFILE:-"quick"}
DATA_SIZE=${BENCHMARK_DATA_SIZE:-100}
MESSAGE_COUNT=${BENCHMARK_MESSAGE_COUNT:-10000}
ITERATIONS=${BENCHMARK_ITERATIONS:-1}
RESULTS_FILE=${BENCHMARK_RESULTS_FILE:-"$BENCHMARK_ROOT/results/throughput.json"}

echo "Running Throughput Benchmark"
echo "  Data size: ${DATA_SIZE}MB"
echo "  Messages: $MESSAGE_COUNT"
echo "  Iterations: $ITERATIONS"
echo ""

cd "$PROJECT_ROOT"

# Initialize results
BACKUP_TIMES=()
RESTORE_TIMES=()

for iter in $(seq 1 $ITERATIONS); do
    echo "Iteration $iter of $ITERATIONS"

    # Clean up previous backup
    docker compose exec minio mc rm --recursive --force local/kafka-backups/benchmark-throughput/ 2>/dev/null || true

    # Backup
    echo "  Running backup..."
    START_TIME=$(date +%s.%N)

    docker compose --profile tools run --rm kafka-backup \
        backup \
        --config /config/benchmark-throughput.yaml 2>&1 | tail -5

    END_TIME=$(date +%s.%N)
    BACKUP_TIME=$(echo "$END_TIME - $START_TIME" | bc)
    BACKUP_TIMES+=($BACKUP_TIME)
    echo "  Backup completed in ${BACKUP_TIME}s"

    # Delete topic for restore test
    docker compose --profile tools run --rm kafka-cli bash -c '
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic benchmark-data 2>/dev/null || true
        sleep 2
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
            --topic benchmark-data --partitions 3 --replication-factor 1
    ' 2>/dev/null

    # Restore
    echo "  Running restore..."
    START_TIME=$(date +%s.%N)

    docker compose --profile tools run --rm kafka-backup \
        restore \
        --config /config/benchmark-throughput-restore.yaml 2>&1 | tail -5

    END_TIME=$(date +%s.%N)
    RESTORE_TIME=$(echo "$END_TIME - $START_TIME" | bc)
    RESTORE_TIMES+=($RESTORE_TIME)
    echo "  Restore completed in ${RESTORE_TIME}s"
    echo ""
done

# Calculate averages
TOTAL_BACKUP=0
TOTAL_RESTORE=0
for t in "${BACKUP_TIMES[@]}"; do TOTAL_BACKUP=$(echo "$TOTAL_BACKUP + $t" | bc); done
for t in "${RESTORE_TIMES[@]}"; do TOTAL_RESTORE=$(echo "$TOTAL_RESTORE + $t" | bc); done

AVG_BACKUP=$(echo "scale=2; $TOTAL_BACKUP / $ITERATIONS" | bc)
AVG_RESTORE=$(echo "scale=2; $TOTAL_RESTORE / $ITERATIONS" | bc)

BACKUP_MBPS=$(echo "scale=2; $DATA_SIZE / $AVG_BACKUP" | bc)
RESTORE_MBPS=$(echo "scale=2; $DATA_SIZE / $AVG_RESTORE" | bc)

echo "Results:"
echo "  Avg Backup Time: ${AVG_BACKUP}s"
echo "  Avg Restore Time: ${AVG_RESTORE}s"
echo "  Backup Throughput: ${BACKUP_MBPS} MB/s"
echo "  Restore Throughput: ${RESTORE_MBPS} MB/s"

# Update results JSON
if [ -f "$RESULTS_FILE" ]; then
    # Use Python to update JSON since jq might not be available
    python3 << EOF
import json
with open("$RESULTS_FILE", "r") as f:
    results = json.load(f)
results["scenarios"]["throughput"] = {
    "backup_mbps": $BACKUP_MBPS,
    "restore_mbps": $RESTORE_MBPS,
    "backup_time_s": $AVG_BACKUP,
    "restore_time_s": $AVG_RESTORE,
    "duration_s": $AVG_BACKUP,
    "data_size_mb": $DATA_SIZE,
    "iterations": $ITERATIONS
}
with open("$RESULTS_FILE", "w") as f:
    json.dump(results, f, indent=2)
EOF
fi

echo "Throughput benchmark complete"
