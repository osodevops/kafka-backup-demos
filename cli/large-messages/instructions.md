# CLI Demo: Large Messages & Compression

**Core Feature:** Handling large payloads with compression

## Overview

This demo shows how `kafka-backup` handles large messages (1MB-10MB) with various compression algorithms. Key capabilities:

- Backup/restore of large message payloads without truncation
- Compression algorithms: zstd, lz4, gzip, snappy
- Proper broker configuration for large messages

## Prerequisites

```bash
# Start the demo environment
docker compose up -d

# Wait for services to be ready
docker compose logs -f kafka-setup
```

## Quick Start

```bash
cd cli/large-messages
chmod +x demo.sh
./demo.sh
```

## Manual Walkthrough

### Step 1: Generate Large Messages

The demo includes a generator script:

```bash
cd data
./generate-large-messages.sh 1 5   # 5 messages of ~1MB each
./generate-large-messages.sh 5 3   # 3 messages of ~5MB each
```

Or generate inline:
```bash
# Generate a single 1MB message
python3 -c "
import json
import base64
import os

msg = {
    'id': 'large-msg-1',
    'timestamp': '2025-01-15T10:00:00Z',
    'size_bytes': 1000000,
    'payload': base64.b64encode(os.urandom(750000)).decode('utf-8')
}
print(json.dumps(msg))
" > large-message.json
```

### Step 2: Configure Topic for Large Messages

The topic must support large messages:

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic large_messages \
        --partitions 1 \
        --replication-factor 1 \
        --config max.message.bytes=15728640
'
```

Broker settings (already configured in docker-compose.yml):
```yaml
KAFKA_MESSAGE_MAX_BYTES: 15728640       # 15MB
KAFKA_REPLICA_FETCH_MAX_BYTES: 15728640
```

### Step 3: Produce Large Messages

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    cat /data/generated-large-messages.json | jq -c ".[]" | \
    kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic large_messages \
        --producer-property max.request.size=15728640
'
```

### Step 4: Backup with Compression

```bash
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-large.yaml
```

The configuration (`config/backup-large.yaml`):
```yaml
backup:
  compression: zstd                    # Best compression ratio
  segment_max_bytes: 52428800          # 50MB per segment
  fetch_max_bytes: 15728640           # Match broker max message size
```

### Step 5: Check Compression Effectiveness

```bash
# View backup size
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/large-demo \
    --backup-id large-messages-backup

# Check actual MinIO storage
docker compose exec minio mc ls -r local/kafka-backups/large-demo/ --summarize
```

### Step 6: Restore and Validate

```bash
# Delete topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic large_messages
'

# Recreate with proper settings
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic large_messages --partitions 1 --replication-factor 1 \
        --config max.message.bytes=15728640
'

# Restore
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-large.yaml
```

### Step 7: Validate No Truncation

```bash
# Check message sizes
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic large_messages \
        --from-beginning \
        --max-messages 5 | while read msg; do
            echo "Size: $(echo "$msg" | wc -c) bytes"
        done
'
```

## Compression Algorithm Comparison

| Algorithm | Ratio | Speed | Use Case |
|-----------|-------|-------|----------|
| zstd | Best (3-5x) | Fast | Default choice, production backups |
| lz4 | Good (2-3x) | Fastest | High-throughput, low latency |
| gzip | Good (3-4x) | Moderate | Compatibility with other tools |
| snappy | Moderate (2x) | Very Fast | Real-time processing |
| none | 1x | N/A | Already compressed data |

## Testing Different Compression

Edit `config/backup-large.yaml`:
```yaml
backup:
  compression: lz4   # Try: zstd, lz4, gzip, snappy, none
```

Then run backup again to compare sizes.

## Key Configuration Options

### Backup Configuration
```yaml
backup:
  compression: zstd
  segment_max_bytes: 52428800     # 50MB per segment file
  segment_max_records: 100        # Max records per segment
  fetch_max_bytes: 15728640       # Must match broker max message size
  max_concurrent_partitions: 1    # Serialize for predictable ordering
```

### Broker Configuration
```yaml
# docker-compose.yml
KAFKA_MESSAGE_MAX_BYTES: 15728640
KAFKA_REPLICA_FETCH_MAX_BYTES: 15728640
```

### Producer Configuration
```bash
--producer-property max.request.size=15728640
```

## Troubleshooting

### "Message too large" Error
- Check `max.message.bytes` on the topic
- Check `message.max.bytes` on the broker
- Ensure `max.request.size` on the producer matches

### Slow Backup Performance
- Reduce compression level for faster backups
- Use `lz4` instead of `zstd` for speed
- Increase `max_concurrent_partitions` for parallel processing

### Memory Issues
- Large messages require more memory
- Monitor container memory usage
- Consider splitting very large payloads

## Cleanup

```bash
# Remove generated test files
rm -f data/generated-large-messages.json

# Clear backup
docker compose exec minio mc rm --recursive --force local/kafka-backups/large-demo/
```

## Next Steps

- Explore [Offset Mapping Report](../offset-report/instructions.md) for multi-group analysis
- Try [PITR + Rollback](../pitr-rollback-e2e/instructions.md) for point-in-time recovery
