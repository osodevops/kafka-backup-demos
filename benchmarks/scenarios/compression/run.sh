#!/bin/bash
# Compression Benchmark Scenario
# Compares compression algorithms: zstd, lz4, none
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_ROOT/.." && pwd)"

PROFILE=${BENCHMARK_PROFILE:-"quick"}
DATA_SIZE=${BENCHMARK_DATA_SIZE:-100}
RESULTS_FILE=${BENCHMARK_RESULTS_FILE:-"$BENCHMARK_ROOT/results/compression.json"}

echo "Running Compression Benchmark"
echo "  Data size: ${DATA_SIZE}MB"
echo ""

cd "$PROJECT_ROOT"

declare -A COMPRESSION_RESULTS

for algo in zstd lz4 none; do
    echo "Testing compression: $algo"

    # Clean up
    docker compose exec minio mc rm --recursive --force local/kafka-backups/benchmark-compression-$algo/ 2>/dev/null || true

    # Create config for this algorithm
    cat > /tmp/benchmark-compression-$algo.yaml << EOF
mode: backup
backup_id: "benchmark-compression-$algo"

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
  prefix: benchmark-compression-$algo
  endpoint: http://minio:9000
  path_style: true
  access_key_id: minioadmin
  secret_access_key: minioadmin

backup:
  compression: $algo
  segment_max_records: 50000
  segment_max_bytes: 134217728
  max_concurrent_partitions: 3
EOF

    # Run backup
    START_TIME=$(date +%s.%N)

    docker compose --profile tools run --rm \
        -v /tmp:/tmp \
        kafka-backup backup --config /tmp/benchmark-compression-$algo.yaml 2>&1 | tail -3

    END_TIME=$(date +%s.%N)
    DURATION=$(echo "$END_TIME - $START_TIME" | bc)

    # Get compressed size from MinIO
    COMPRESSED_SIZE=$(docker compose exec minio mc du local/kafka-backups/benchmark-compression-$algo/ 2>/dev/null | awk '{print $1}' | head -1)

    # Parse size (handle K, M, G suffixes)
    if [[ $COMPRESSED_SIZE == *"MiB"* ]]; then
        SIZE_MB=$(echo "$COMPRESSED_SIZE" | sed 's/MiB//')
    elif [[ $COMPRESSED_SIZE == *"KiB"* ]]; then
        SIZE_KB=$(echo "$COMPRESSED_SIZE" | sed 's/KiB//')
        SIZE_MB=$(echo "scale=2; $SIZE_KB / 1024" | bc)
    elif [[ $COMPRESSED_SIZE == *"GiB"* ]]; then
        SIZE_GB=$(echo "$COMPRESSED_SIZE" | sed 's/GiB//')
        SIZE_MB=$(echo "scale=2; $SIZE_GB * 1024" | bc)
    else
        SIZE_MB=$DATA_SIZE
    fi

    # Calculate ratio
    if [ -n "$SIZE_MB" ] && [ "$SIZE_MB" != "0" ]; then
        RATIO=$(echo "scale=2; $DATA_SIZE / $SIZE_MB" | bc 2>/dev/null || echo "1.0")
    else
        RATIO="1.0"
        SIZE_MB=$DATA_SIZE
    fi

    echo "  Duration: ${DURATION}s"
    echo "  Compressed size: ${SIZE_MB}MB"
    echo "  Ratio: ${RATIO}x"
    echo ""

    # Store results
    COMPRESSION_RESULTS["${algo}_duration"]=$DURATION
    COMPRESSION_RESULTS["${algo}_size"]=$SIZE_MB
    COMPRESSION_RESULTS["${algo}_ratio"]=$RATIO

    # Cleanup
    rm -f /tmp/benchmark-compression-$algo.yaml
done

# Update results JSON
if [ -f "$RESULTS_FILE" ]; then
    python3 << EOF
import json
with open("$RESULTS_FILE", "r") as f:
    results = json.load(f)
results["scenarios"]["compression"] = {
    "zstd": {
        "duration_s": ${COMPRESSION_RESULTS[zstd_duration]:-0},
        "compressed_mb": ${COMPRESSION_RESULTS[zstd_size]:-0},
        "ratio": ${COMPRESSION_RESULTS[zstd_ratio]:-1.0}
    },
    "lz4": {
        "duration_s": ${COMPRESSION_RESULTS[lz4_duration]:-0},
        "compressed_mb": ${COMPRESSION_RESULTS[lz4_size]:-0},
        "ratio": ${COMPRESSION_RESULTS[lz4_ratio]:-1.0}
    },
    "none": {
        "duration_s": ${COMPRESSION_RESULTS[none_duration]:-0},
        "compressed_mb": ${COMPRESSION_RESULTS[none_size]:-0},
        "ratio": ${COMPRESSION_RESULTS[none_ratio]:-1.0}
    }
}
with open("$RESULTS_FILE", "w") as f:
    json.dump(results, f, indent=2)
EOF
fi

echo "Compression benchmark complete"
