# Java Demo: Offset Reset Verification

**Core Feature:** Bulk offset reset correctness verification

## Overview

This demo verifies that bulk offset reset operations work correctly. It demonstrates:

1. Consuming messages and recording processed offsets
2. Performing a bulk offset reset
3. Verifying that exactly the expected messages are re-read

## Scenario

```
Before Reset:
─────────────────────────────────────────────────────────────────────►
                                                    ▲
                                                    │ Committed
                                                    │ Offset: 50
┌──────────────────────────────────────────────────────────────────┐
│ Messages: 0   10   20   30   40   50   60   70   80   90   100   │
│           [──────────── Processed ─────────────][── Not read ──] │
└──────────────────────────────────────────────────────────────────┘

After Reset (shift by -20):
─────────────────────────────────────────────────────────────────────►
                              ▲
                              │ Reset
                              │ Offset: 30
┌──────────────────────────────────────────────────────────────────┐
│ Messages: 0   10   20   30   40   50   60   70   80   90   100   │
│           [── Already ──][────── Will Re-read ─────────────────] │
└──────────────────────────────────────────────────────────────────┘

Expected: Consumer re-reads exactly 20 messages (offsets 30-49)
```

## Prerequisites

- Java 17+
- Maven 3.6+
- Docker environment running (`docker compose up -d`)

## Building

```bash
cd java-streams/offset-reset-verify
mvn clean package
```

## Demo Walkthrough

### Step 1: Produce Test Messages

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 100); do
        echo "{\"payment_id\": \"PAY-$i\", \"amount\": $((RANDOM % 1000))}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments
'
```

### Step 2: Run Initial Consumption

```bash
cd java-streams/offset-reset-verify

# Consume 50 messages
mvn exec:java -Dexec.args="localhost:9092 50"
```

Expected output:
```
==============================================
   Offset Reset Verification Demo
==============================================
Bootstrap servers: localhost:9092
Topic: payments
Consumer group: payments-processor
Target count: 50

Phase 1: Initial consumption up to 50 messages
──────────────────────────────────────────────────
Processed: partition=0, offset=0, value={"payment_id": "PAY-1", "amount": ...
Processed: partition=1, offset=0, value={"payment_id": "PAY-2", "amount": ...
...
Processed: partition=2, offset=16, value={"payment_id": "PAY-50", "amount": ...
Committed offsets

Phase 1 Complete!
──────────────────────────────────────────────────
Processed 50 messages
Last offset per partition:
  Partition 0: offset 16
  Partition 1: offset 17
  Partition 2: offset 16

Offsets saved to: processed-offsets.txt
```

### Step 3: Check Current Offsets

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --group payments-processor
'
```

### Step 4: Perform Bulk Offset Reset

Option A: Using kafka-backup:
```bash
docker compose --profile tools run --rm kafka-backup \
    offset-reset execute \
    --path s3://kafka-backups/demo \
    --backup-id <BACKUP_ID> \
    --groups payments-processor \
    --bootstrap-servers kafka-broker-1:9092
```

Option B: Using kafka-consumer-groups (shift back 20 offsets):
```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group payments-processor --topic payments \
        --reset-offsets --shift-by -20 --execute
'
```

### Step 5: Verify New Offsets

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --group payments-processor
'
```

Expected: Offsets shifted back by 20 per partition

### Step 6: Run Consumer Again

```bash
# Backup the first run's offsets
cp processed-offsets.txt processed-offsets-before.txt

# Run consumer again (only consume 20 - the re-read amount)
mvn exec:java -Dexec.args="localhost:9092 20"

# Compare
diff processed-offsets-before.txt processed-offsets.txt
```

### Step 7: Verify Re-Read Messages

The second run should show:
- Exactly 20 messages consumed
- Starting from offset (original - 20)
- Same messages that were previously processed (offsets 30-49 from original run)

```bash
# Extract offsets from both files
echo "Before reset, last 20 offsets:"
tail -20 processed-offsets-before.txt | cut -d',' -f1,2

echo "After reset, all offsets:"
tail -20 processed-offsets.txt | cut -d',' -f1,2
```

## Verification Script

Create `verify-reset.sh`:
```bash
#!/bin/bash

BEFORE_FILE="processed-offsets-before.txt"
AFTER_FILE="processed-offsets.txt"

echo "Verification Report"
echo "==================="

# Count records
BEFORE_COUNT=$(grep -v "^#" "$BEFORE_FILE" | grep -v "^$" | wc -l)
AFTER_COUNT=$(grep -v "^#" "$AFTER_FILE" | grep -v "^$" | wc -l)

echo "Records before reset: $BEFORE_COUNT"
echo "Records after reset: $AFTER_COUNT"
echo "Expected re-read: 20"
echo ""

if [ "$AFTER_COUNT" -eq 20 ]; then
    echo "✓ Correct number of messages re-read"
else
    echo "✗ Unexpected message count"
fi

# Check if after matches last 20 of before
echo ""
echo "Offset comparison:"
tail -20 "$BEFORE_FILE" | cut -d',' -f1,2 | sort > /tmp/before_last_20.txt
grep -v "^#" "$AFTER_FILE" | grep -v "^$" | cut -d',' -f1,2 | sort > /tmp/after_all.txt

if diff /tmp/before_last_20.txt /tmp/after_all.txt > /dev/null; then
    echo "✓ Re-read messages match expected offsets"
else
    echo "✗ Re-read messages don't match"
    diff /tmp/before_last_20.txt /tmp/after_all.txt
fi
```

## Expected Log Excerpts

### Before Reset
```
Processed: partition=0, offset=0, value={"payment_id":"PAY-1"...
Processed: partition=0, offset=1, value={"payment_id":"PAY-4"...
...
Processed: partition=2, offset=16, value={"payment_id":"PAY-50"...
Committed offsets

Last offset per partition:
  Partition 0: offset 16
  Partition 1: offset 17
  Partition 2: offset 16
```

### After Reset
```
Processed: partition=0, offset=-4, value={"payment_id":"PAY-31"...  # After shift -20
Processed: partition=1, offset=-3, value={"payment_id":"PAY-32"...
...
Processed: partition=2, offset=16, value={"payment_id":"PAY-50"...
Committed offsets

Last offset per partition:
  Partition 0: offset 16  # Back to same position
  Partition 1: offset 17
  Partition 2: offset 16
```

## Key Observations

1. **Exact Re-read**: After reset, consumer re-reads exactly the number of shifted messages
2. **No Duplicates**: Messages aren't processed twice if consumer runs continuously
3. **Partition Distribution**: Reset applies to all partitions proportionally
4. **Idempotency**: Multiple resets to same offset produce same result

## Application Code Highlights

### Consumer Configuration
```java
props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "true");
props.put(ConsumerConfig.AUTO_COMMIT_INTERVAL_MS_CONFIG, "1000");
props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
```

### Recording Processed Offsets
```java
for (ConsumerRecord<String, String> record : records) {
    ProcessedRecord pr = new ProcessedRecord(
        record.partition(),
        record.offset(),
        record.key(),
        record.value(),
        record.timestamp()
    );
    processed.add(pr);
    log.info("Processed: partition={}, offset={}",
        record.partition(), record.offset());
}
```

## Cleanup

```bash
rm -f processed-offsets.txt processed-offsets-before.txt

docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group payments-processor --delete
'
```

## Next Steps

- Try [Spring Boot Backup & Restore](../../springboot/backup-restore-flow/instructions.md)
- Explore [PITR + Rollback](../../cli/pitr-rollback-e2e/instructions.md) for complete recovery workflow
