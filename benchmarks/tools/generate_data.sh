#!/bin/bash
# Generate test data for benchmarks
# Usage: ./generate_data.sh [message_count] [size_mb]
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MESSAGE_COUNT=${1:-10000}
SIZE_MB=${2:-100}

# Calculate message size to achieve target total size
# Total size = message_count * avg_message_size
# avg_message_size = (SIZE_MB * 1024 * 1024) / MESSAGE_COUNT
AVG_MSG_SIZE=$(( (SIZE_MB * 1024 * 1024) / MESSAGE_COUNT ))

echo "Generating $MESSAGE_COUNT messages (~${SIZE_MB}MB total)"
echo "Average message size: ~${AVG_MSG_SIZE} bytes"

# Create benchmark topic if needed
docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic benchmark-data 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic benchmark-data \
        --partitions 3 \
        --replication-factor 1
" 2>/dev/null

# Generate and produce messages
# Using a batch approach for efficiency
BATCH_SIZE=1000
BATCHES=$(( MESSAGE_COUNT / BATCH_SIZE ))

echo "Producing messages in $BATCHES batches of $BATCH_SIZE..."

for batch in $(seq 1 $BATCHES); do
    # Generate a batch of messages
    docker compose --profile tools run --rm kafka-cli bash -c "
        for i in \$(seq 1 $BATCH_SIZE); do
            MSG_ID=\"MSG-\$(printf '%08d' \$((($batch - 1) * $BATCH_SIZE + \$i)))\"
            # Create a JSON payload with padding to reach target size
            PADDING=\$(head -c $((AVG_MSG_SIZE - 150)) /dev/urandom | base64 | tr -d '\n' | head -c $((AVG_MSG_SIZE - 150)))
            echo \"{\\\"id\\\": \\\"\$MSG_ID\\\", \\\"batch\\\": $batch, \\\"timestamp\\\": \\\"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\\\", \\\"data\\\": \\\"\$PADDING\\\"}\"
        done | kafka-console-producer.sh \
            --bootstrap-server kafka-broker-1:9092 \
            --topic benchmark-data \
            --producer-property linger.ms=100 \
            --producer-property batch.size=65536
    " 2>/dev/null

    echo -ne "  Progress: $batch/$BATCHES batches\r"
done

echo ""
echo "Data generation complete"

# Verify message count
ACTUAL_COUNT=$(docker compose --profile tools run --rm kafka-cli bash -c "
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic benchmark-data \
        --time -1 2>/dev/null | awk -F ':' '{sum += \$3} END {print sum}'
")

echo "Verified: $ACTUAL_COUNT messages in benchmark-data topic"
