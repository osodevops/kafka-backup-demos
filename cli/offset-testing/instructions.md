# CLI Demo: Offset State Verification

**Core Feature:** Consumer offset snapshot & inspection

## Overview

This demo shows how to capture, inspect, and compare consumer group offset states using `kafka-backup`. This is essential for:

- Verifying committed offsets before/after restore operations
- Auditing consumer progress
- Planning migrations or disaster recovery

## Prerequisites

```bash
# Start the demo environment
docker compose up -d

# Wait for services to be ready
docker compose logs -f kafka-setup
# Wait until you see "All demo topics created successfully"
```

## Quick Start

```bash
# Run the automated demo
cd cli/offset-testing
chmod +x demo.sh
./demo.sh
```

## Manual Walkthrough

### Step 1: Produce Test Messages

```bash
# Produce 100 messages to the orders topic
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 100); do
        echo "{\"order_id\": \"ORD-$i\", \"amount\": $((RANDOM % 1000))}"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders
'
```

### Step 2: Consume Some Messages

Start a consumer that reads partial messages to establish committed offsets:

```bash
# Consume 50 messages with consumer group 'orders-streams'
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders \
        --group orders-streams \
        --from-beginning \
        --max-messages 50
'
```

### Step 3: View Current Offset State

Use the standard Kafka CLI to see committed offsets:

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --describe \
        --group orders-streams
'
```

Expected output:
```
GROUP           TOPIC     PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
orders-streams  orders    0          17              33              16
orders-streams  orders    1          16              33              17
orders-streams  orders    2          17              34              17
```

### Step 4: Create Offset Snapshot

Use `kafka-backup` to capture the offset state:

```bash
docker compose --profile tools run --rm kafka-backup \
    offset-rollback snapshot \
    --path s3://kafka-backups/offset-demo \
    --groups orders-streams \
    --bootstrap-servers kafka-broker-1:9092 \
    --description "Before consuming remaining messages"
```

### Step 5: List Available Snapshots

```bash
docker compose --profile tools run --rm kafka-backup \
    offset-rollback list \
    --path s3://kafka-backups/offset-demo
```

### Step 6: Export Snapshot as JSON

```bash
# Get the snapshot ID from the list command, then:
docker compose --profile tools run --rm kafka-backup \
    offset-rollback show \
    --path s3://kafka-backups/offset-demo \
    --snapshot-id <SNAPSHOT_ID> \
    --format json
```

Example JSON output:
```json
{
  "snapshot_id": "snapshot-2025-01-15T10:30:00Z",
  "description": "Before consuming remaining messages",
  "created_at": "2025-01-15T10:30:00Z",
  "consumer_groups": {
    "orders-streams": {
      "partitions": {
        "orders-0": {
          "offset": 17,
          "metadata": ""
        },
        "orders-1": {
          "offset": 16,
          "metadata": ""
        },
        "orders-2": {
          "offset": 17,
          "metadata": ""
        }
      }
    }
  }
}
```

### Step 7: Compare Before/After States

After consuming more messages, create another snapshot and compare:

```bash
# Consume remaining messages
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders \
        --group orders-streams \
        --timeout-ms 5000
'

# Create another snapshot
docker compose --profile tools run --rm kafka-backup \
    offset-rollback snapshot \
    --path s3://kafka-backups/offset-demo \
    --groups orders-streams \
    --bootstrap-servers kafka-broker-1:9092 \
    --description "After consuming all messages"
```

Compare using `jq`:
```bash
# Show offset differences
diff <(jq '.consumer_groups' offsets-before.json) \
     <(jq '.consumer_groups' offsets-after.json)
```

### Step 8: Rollback to Previous State (Optional)

```bash
docker compose --profile tools run --rm kafka-backup \
    offset-rollback rollback \
    --path s3://kafka-backups/offset-demo \
    --snapshot-id <SNAPSHOT_ID> \
    --bootstrap-servers kafka-broker-1:9092 \
    --verify true
```

## Key Observations

1. **Offset Tracking**: The snapshot captures committed offsets for each partition
2. **JSON Export**: Enables programmatic analysis and comparison
3. **Audit Trail**: Snapshots have timestamps and descriptions for tracking
4. **Rollback Capability**: Offsets can be restored to any previous snapshot

## Use Cases

- **Pre-restore verification**: Capture state before any restore operation
- **Post-restore verification**: Compare restored offsets with expected values
- **Migration planning**: Export offset mappings for cross-cluster migrations
- **Debugging**: Track down when/where message processing stopped

## Cleanup

```bash
# Reset consumer group offsets to earliest
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --group orders-streams \
        --topic orders \
        --reset-offsets \
        --to-earliest \
        --execute
'
```

## Next Steps

- Try the [Basic Backup & Restore](../backup-basic/instructions.md) demo
- Explore [Offset Mapping Report](../offset-report/instructions.md) for multi-group analysis
