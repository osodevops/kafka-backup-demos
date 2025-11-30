# CLI Demo: PITR + Rollback End-to-End

**Core Feature:** Complete point-in-time recovery workflow with rollback safety

## Overview

This advanced demo showcases the full disaster recovery workflow:

1. Normal operations with data production
2. Offset snapshot for safety checkpoint
3. Incident simulation (corrupted data injection)
4. Point-in-time restore to before the incident
5. Consumer offset reset
6. Verification and optional rollback

## Prerequisites

```bash
# Start the demo environment
docker compose up -d

# Wait for services to be ready
docker compose logs -f kafka-setup
```

## Quick Start

```bash
cd cli/pitr-rollback-e2e
chmod +x demo.sh
./demo.sh
```

## Scenario Overview

```
Timeline:
─────────────────────────────────────────────────────────────────────►

[T0]          [T1]           [T2]              [T3]           [T4]
 │             │              │                 │              │
 │  Normal     │   Snapshot   │   Bad data      │   PITR       │   Verify
 │  traffic    │   + Backup   │   injected      │   restore    │   + Resume
 │             │              │                 │              │
 └─────────────┴──────────────┴─────────────────┴──────────────┘
     GOOD DATA    CHECKPOINT      CORRUPTED         RECOVERY
```

## Manual Walkthrough

### Step 1: Normal Operations

```bash
# Produce valid payment data
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 50); do
        echo "{\"payment_id\": \"PAY-$i\", \"amount\": $((100 + RANDOM % 900)), \"status\": \"valid\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments
'

# Consumer processes some messages
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --group payments-processor --from-beginning \
        --max-messages 30 --timeout-ms 10000 > /dev/null
'
```

### Step 2: Record PITR Timestamp

```bash
# Record the current timestamp (in milliseconds)
PITR_TIMESTAMP=$(date +%s000)
echo "PITR timestamp: $PITR_TIMESTAMP"

# Verify consumer group state
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --group payments-processor
'
```

### Step 3: Create Offset Snapshot

This is your safety checkpoint:

```bash
docker compose --profile tools run --rm kafka-backup \
    offset-rollback snapshot \
    --path s3://kafka-backups/pitr-demo \
    --groups payments-processor \
    --bootstrap-servers kafka-broker-1:9092 \
    --description "Pre-incident safety checkpoint"
```

### Step 4: Create Backup

```bash
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-pitr.yaml
```

### Step 5: Simulate Incident (Bad Data Injection)

```bash
# This simulates a deployment bug, data corruption, or malicious activity
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 51 100); do
        echo "{\"payment_id\": \"CORRUPTED-$i\", \"amount\": -999, \"status\": \"INVALID\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments
'

# Consumer unknowingly processes corrupted data
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --group payments-processor \
        --max-messages 20 --timeout-ms 10000 > /dev/null
'
```

### Step 6: Detect the Problem

```bash
# Check for corrupted data
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --from-beginning \
        --timeout-ms 10000 | grep "CORRUPTED" | wc -l
'
```

### Step 7: PITR Restore

```bash
# Delete the corrupted topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic payments
'

# Recreate empty topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic payments --partitions 3 --replication-factor 1
'

# Restore with time window filter
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-pitr.yaml \
    --time-window-end $PITR_TIMESTAMP
```

### Step 8: Reset Consumer Offsets

```bash
# Option A: Using kafka-backup offset-reset
docker compose --profile tools run --rm kafka-backup \
    offset-reset execute \
    --path s3://kafka-backups/pitr-demo \
    --backup-id pitr-backup \
    --groups payments-processor \
    --bootstrap-servers kafka-broker-1:9092

# Option B: Using kafka-consumer-groups (alternative)
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group payments-processor --topic payments \
        --reset-offsets --to-earliest --execute
'
```

### Step 9: Verify Clean State

```bash
# Count corrupted messages (should be 0)
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --from-beginning \
        --timeout-ms 10000 2>/dev/null | grep -c "CORRUPTED" || echo "0"
'

# Verify consumer group can resume
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --group payments-processor
'
```

### Step 10: Rollback (If Verification Fails)

```bash
# Get snapshot ID
SNAPSHOT_ID=$(cat snapshot-id.txt)

# Rollback to snapshot
docker compose --profile tools run --rm kafka-backup \
    offset-rollback rollback \
    --path s3://kafka-backups/pitr-demo \
    --snapshot-id "$SNAPSHOT_ID" \
    --bootstrap-servers kafka-broker-1:9092 \
    --verify true
```

## Configuration Details

### backup-pitr.yaml
```yaml
mode: backup
backup_id: "pitr-backup"

source:
  bootstrap_servers:
    - kafka-broker-1:9092
  topics:
    include:
      - payments

storage:
  backend: s3
  bucket: kafka-backups
  prefix: pitr-demo
  endpoint: http://minio:9000
```

### restore-pitr.yaml
```yaml
mode: restore
backup_id: "pitr-backup"

restore:
  # Time window for PITR
  # time_window_end: <SET_AT_RUNTIME>

  # Offset handling
  consumer_group_strategy: header-based
  consumer_groups:
    - payments-processor
  reset_consumer_offsets: true
```

## Key Concepts

### Offset Snapshots
- Capture consumer group committed offsets at a point in time
- Stored in S3/MinIO alongside backups
- Can be used for rollback if restore fails

### PITR Time Window
- `time_window_start`: Include records after this timestamp
- `time_window_end`: Include records before this timestamp
- Precision: Milliseconds

### Offset Reset Strategies
| Strategy | Description |
|----------|-------------|
| `skip` | No offset changes |
| `header-based` | Use original offset from headers |
| `timestamp-based` | Calculate from record timestamps |
| `cluster-scan` | Match offsets in target cluster |
| `manual` | Generate report only |

## Troubleshooting

### PITR Didn't Remove All Bad Data
- Verify timestamp is before bad data injection
- Check that `time_window_end` is correctly set
- Some messages may have timestamps outside expected range

### Consumer Offsets Not Reset
- Ensure consumer group has no active consumers
- Try `--force` flag if available
- Manually reset using `kafka-consumer-groups.sh`

### Rollback Failed
- Verify snapshot exists: `kafka-backup offset-rollback list`
- Check snapshot isn't corrupted: `kafka-backup offset-rollback verify`
- Ensure target group exists and is inactive

## Cleanup

```bash
rm -f pitr-timestamp.txt snapshot-id.txt
docker compose exec minio mc rm --recursive --force local/kafka-backups/pitr-demo/
```

## Next Steps

- Try the [Java Streams PITR](../../java-streams/pitr-restore/instructions.md) demo
- Explore [Spring Boot Producer/Consumer PITR](../../springboot/producer-consumer/instructions.md)
