#!/bin/bash
# Collect metrics from kafka-backup Prometheus endpoint
# Usage: ./collect_metrics.sh [output_file] [label]
set -e

OUTPUT_FILE=${1:-"metrics.txt"}
LABEL=${2:-"snapshot"}

# kafka-backup exposes metrics on port 9090
METRICS_URL="http://localhost:9090/metrics"

echo "Collecting metrics (label: $LABEL)..."

# Try to collect metrics, fall back to empty if not available
if curl -s --connect-timeout 5 "$METRICS_URL" > /dev/null 2>&1; then
    curl -s "$METRICS_URL" | grep "^kafka_backup_" > "${OUTPUT_FILE}.${LABEL}" 2>/dev/null || true
    echo "Metrics saved to: ${OUTPUT_FILE}.${LABEL}"
else
    echo "# Metrics endpoint not available" > "${OUTPUT_FILE}.${LABEL}"
    echo "Warning: Could not connect to metrics endpoint"
fi

# Extract key metrics if available
if [ -f "${OUTPUT_FILE}.${LABEL}" ]; then
    echo ""
    echo "Key Metrics:"

    # Throughput
    THROUGHPUT=$(grep "kafka_backup_throughput_mbps" "${OUTPUT_FILE}.${LABEL}" 2>/dev/null | awk '{print $2}' | tail -1)
    [ -n "$THROUGHPUT" ] && echo "  Throughput: ${THROUGHPUT} MB/s"

    # Records per second
    RPS=$(grep "kafka_backup_records_per_second" "${OUTPUT_FILE}.${LABEL}" 2>/dev/null | awk '{print $2}' | tail -1)
    [ -n "$RPS" ] && echo "  Records/sec: $RPS"

    # Compression ratio
    RATIO=$(grep "kafka_backup_compression_ratio" "${OUTPUT_FILE}.${LABEL}" 2>/dev/null | awk '{print $2}' | tail -1)
    [ -n "$RATIO" ] && echo "  Compression: ${RATIO}x"

    # Checkpoint latency p99
    CKPT_P99=$(grep "kafka_backup_checkpoint_latency_ms.*quantile=\"0.99\"" "${OUTPUT_FILE}.${LABEL}" 2>/dev/null | awk '{print $2}' | tail -1)
    [ -n "$CKPT_P99" ] && echo "  Checkpoint p99: ${CKPT_P99}ms"
fi
