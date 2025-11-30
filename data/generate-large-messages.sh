#!/bin/bash
# Generate large JSON messages for testing
# Usage: ./generate-large-messages.sh [size_mb] [count]
# Example: ./generate-large-messages.sh 1 5  # Generate 5 messages of ~1MB each

SIZE_MB=${1:-1}
COUNT=${2:-5}
OUTPUT_FILE="sample-large-messages.json"

echo "Generating $COUNT messages of approximately ${SIZE_MB}MB each..."

# Calculate approximate character count (1MB = ~1048576 chars)
CHARS_PER_MB=1048576
TARGET_CHARS=$((SIZE_MB * CHARS_PER_MB))

# Create output file
echo "[" > "$OUTPUT_FILE"

for i in $(seq 1 $COUNT); do
    # Generate a base64-encoded random payload
    # We use a slightly smaller size to account for JSON overhead
    PAYLOAD_SIZE=$((TARGET_CHARS - 500))

    # Generate random data
    PAYLOAD=$(head -c $PAYLOAD_SIZE /dev/urandom | base64 | tr -d '\n')

    # Create JSON object
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [ $i -eq $COUNT ]; then
        COMMA=""
    else
        COMMA=","
    fi

    cat >> "$OUTPUT_FILE" << EOF
  {
    "id": "large-msg-$i",
    "timestamp": "$TIMESTAMP",
    "size_mb": $SIZE_MB,
    "type": "large-payload-test",
    "metadata": {
      "generated_by": "kafka-backup-demos",
      "purpose": "compression and large message handling test"
    },
    "payload": "$PAYLOAD"
  }$COMMA
EOF

    echo "Generated message $i of $COUNT"
done

echo "]" >> "$OUTPUT_FILE"

# Show file size
ls -lh "$OUTPUT_FILE"
echo "Done! Generated $OUTPUT_FILE"
