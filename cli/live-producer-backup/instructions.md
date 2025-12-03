# CLI Demo: Live Producer Backup & Restore

**Core Feature:** Backup and restore while producers are actively producing

**Answers the question:** "Wouldn't you need the producers not to produce when you do it?"

## Overview

This demo answers a common question about Kafka backup tools: **Do producers need to stop during backup or restore operations?**

### The Short Answer

| Operation | Producer Status | Safe? | Notes |
|-----------|-----------------|-------|-------|
| **Backup** | Running | YES | Backup captures a consistent snapshot at a point in time |
| **Restore to different topic** | Running | YES | No conflict with active producers |
| **Restore to same topic** | Running | RISKY | May cause duplicates or interleaved data |
| **Restore to same topic** | Stopped | YES | Clean restore without conflicts |

### What This Demo Proves

1. **Backup is non-disruptive** - You can run backups at any time without stopping producers
2. **Backup captures a consistent snapshot** - Messages produced during backup are handled correctly
3. **Restore destination matters** - Restoring to the same topic with active producers can cause issues
4. **Best practice for restore** - Stop producers, restore, then resume

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
cd cli/live-producer-backup
chmod +x demo.sh
./demo.sh
```

## Manual Walkthrough

### Step 1: Setup - Create a Fresh Topic

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic live-test 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic live-test --partitions 3 --replication-factor 1
'
```

### Step 2: Start a Continuous Producer

Start a producer that sends messages every second:

```bash
# Run this in a separate terminal
docker compose --profile tools run --rm kafka-cli bash -c '
    i=0
    while true; do
        i=$((i + 1))
        echo "{\"seq\": $i, \"timestamp\": \"$(date -Iseconds)\", \"data\": \"message-$i\"}"
        sleep 1
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic live-test
'
```

### Step 3: Let Messages Accumulate

Wait 10-15 seconds for messages to build up:

```bash
# Check message count
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic live-test --time -1
'
```

### Step 4: Run Backup While Producer is Running

**This is the key demonstration** - backup works fine with active producers:

```bash
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-live-producer.yaml
```

Note: The backup captures all messages up to the point when it started reading each partition.

### Step 5: Check What Was Backed Up

```bash
# List backup contents
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/live-producer-demo \
    --backup-id live-producer-backup
```

### Step 6: Observe Producer Still Running

The producer is still running! Check the current count vs. backup count:

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic live-test --time -1
'
```

You'll see more messages than the backup contains - that's expected and correct!

### Step 7: Restore Scenario A - To a Different Topic (SAFE)

Restoring to a different topic is always safe, even with producers running:

```bash
# Create destination topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic live-test-restored --partitions 3 --replication-factor 1 2>/dev/null || true
'

# Restore to different topic
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-live-producer-safe.yaml
```

### Step 8: Restore Scenario B - To Same Topic (RISKY)

If you restore to the same topic where producers are still writing, you get duplicates:

```bash
# Stop the producer first (Ctrl+C in the producer terminal)

# Then restore to the same topic
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-live-producer.yaml
```

## Key Observations

### 1. Backup is Non-Blocking

The backup tool:
- Uses Kafka consumer protocol to read messages
- Takes a snapshot at the current high-water mark
- Does NOT lock topics or prevent writes
- Messages arriving during backup are NOT included (consistent point-in-time snapshot)

### 2. Backup Consistency

Each partition is backed up independently:
- Partition 0 might be backed up at offset 100
- Partition 1 might be backed up at offset 95
- This is still consistent - each partition has its full history up to a point

### 3. Restore Considerations

| Scenario | Recommendation |
|----------|----------------|
| Disaster recovery to new cluster | Just restore, no coordination needed |
| Point-in-time recovery on same cluster | Stop producers, delete topic, restore, reset offsets, restart producers |
| Testing/validation | Restore to different topic name |

### 4. Production Best Practice

For production restore operations:
1. **Stop producers** (via feature flags, deployment pause, etc.)
2. **Wait for in-flight messages** to be acknowledged
3. **Delete corrupted/target topic**
4. **Recreate topic** with correct settings
5. **Restore from backup**
6. **Reset consumer offsets** if needed
7. **Resume producers**

## Why Backup Doesn't Need Producer Coordination

The backup tool works at the Kafka protocol level:
- It reads committed messages from topic partitions
- Kafka handles concurrent access natively
- Producers and the backup tool are just consumers/producers to Kafka
- No locks, no coordination, no downtime

This is similar to how you can run multiple consumers on the same topic simultaneously.

## Storage Layout

After backup:
```
kafka-backups/
└── live-producer-demo/
    └── live-producer-backup/
        ├── manifest.json
        └── topics/
            └── live-test/
                ├── partition=0/
                ├── partition=1/
                └── partition=2/
```

## Cleanup

```bash
# Stop the producer (Ctrl+C)

# Remove test topics
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic live-test
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic live-test-restored
'

# Remove backup
docker compose --profile tools exec minio mc rm --recursive --force local/kafka-backups/live-producer-demo/
```

## Summary

**Q: Wouldn't you need the producers not to produce when you do it?**

**A: For backup - NO. For restore - IT DEPENDS.**

- **Backup**: Run anytime. The tool takes a consistent snapshot without stopping producers.
- **Restore to different location**: Safe with producers running.
- **Restore to same topic**: Stop producers first to avoid duplicates/conflicts.

## Next Steps

- Try the [PITR + Rollback](../pitr-rollback-e2e/instructions.md) demo for point-in-time recovery
- Explore [Offset Testing](../offset-testing/instructions.md) for consumer offset management
