# CLI Demo: Offset Mapping Report

**Core Feature:** JSON offset mapping report generation and analysis

## Overview

This demo shows how to generate and analyze offset mapping reports from `kafka-backup`. These reports are essential for:

- Understanding data distribution across topics and partitions
- Planning restore operations
- Tracking consumer group progress
- Auditing offset states before/after migrations

## Prerequisites

```bash
# Start the demo environment
docker compose up -d

# Wait for services to be ready
docker compose logs -f kafka-setup
```

## Quick Start

```bash
cd cli/offset-report
chmod +x demo.sh
./demo.sh
```

## Manual Walkthrough

### Step 1: Set Up Test Workloads

Produce messages to multiple topics:

```bash
# Orders: 50 messages
for i in $(seq 1 50); do
    echo "{\"order_id\": \"ORD-$i\"}"
done | docker compose --profile tools run --rm kafka-cli \
    kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders

# Payments: 30 messages
for i in $(seq 1 30); do
    echo "{\"payment_id\": \"PAY-$i\"}"
done | docker compose --profile tools run --rm kafka-cli \
    kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments

# Events: 100 messages
for i in $(seq 1 100); do
    echo "{\"event_id\": \"EVT-$i\"}"
done | docker compose --profile tools run --rm kafka-cli \
    kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic events
```

### Step 2: Create Consumer Groups with Different Progress

```bash
# orders-streams: partial consumption (30/50)
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic orders --group orders-streams --from-beginning \
        --max-messages 30 --timeout-ms 10000 > /dev/null
'

# payments-processor: complete consumption
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic payments --group payments-processor --from-beginning \
        --timeout-ms 10000 > /dev/null
'

# demo-consumer: partial consumption (50/100)
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic events --group demo-consumer --from-beginning \
        --max-messages 50 --timeout-ms 10000 > /dev/null
'
```

### Step 3: Create Multi-Topic Backup

```bash
docker compose --profile tools run --rm kafka-backup backup --config /config/backup-report.yaml
```

With configuration:
```yaml
source:
  topics:
    include:
      - orders
      - payments
      - events
```

### Step 4: Generate Offset Mapping Report

```bash
docker compose --profile tools run --rm kafka-backup \
    show-offset-mapping \
    --path s3://kafka-backups/report-demo \
    --backup-id report-backup \
    --format json > offset-report.json
```

### Step 5: Analyze with jq

**List all topics:**
```bash
jq '.topics | keys' offset-report.json
# Output: ["orders", "payments", "events"]
```

**Get partition count per topic:**
```bash
jq '.topics | to_entries | .[] | {topic: .key, partitions: (.value.partitions | length)}' offset-report.json
```

**Calculate total messages per topic:**
```bash
jq '.topics.orders.partitions | to_entries | map(.value.end_offset) | add' offset-report.json
# Output: 50
```

**Find highest offset across all partitions:**
```bash
jq '[.topics[].partitions[].end_offset] | max' offset-report.json
```

**Get consumer group lag:**
```bash
jq '.consumer_groups | to_entries | .[] | {
    group: .key,
    total_lag: ([.value.partitions[].lag] | add)
}' offset-report.json
```

## Report Schema

```json
{
  "backup_id": "report-backup",
  "generated_at": "2025-01-15T12:00:00Z",
  "source_cluster": "kafka-broker-1:9092",
  "topics": {
    "orders": {
      "partitions": {
        "0": {
          "start_offset": 0,
          "end_offset": 17,
          "message_count": 17
        },
        "1": {
          "start_offset": 0,
          "end_offset": 16,
          "message_count": 16
        },
        "2": {
          "start_offset": 0,
          "end_offset": 17,
          "message_count": 17
        }
      }
    }
  },
  "consumer_groups": {
    "orders-streams": {
      "partitions": {
        "orders-0": {
          "offset": 10,
          "lag": 7
        },
        "orders-1": {
          "offset": 10,
          "lag": 6
        },
        "orders-2": {
          "offset": 10,
          "lag": 7
        }
      }
    }
  }
}
```

## Python Analysis Script

The demo creates `analyze_offsets.py`:

```python
#!/usr/bin/env python3
import json
import sys

def analyze(report_path):
    with open(report_path) as f:
        report = json.load(f)

    print(f"Backup: {report.get('backup_id')}")

    # Topic summary
    for topic, data in report.get('topics', {}).items():
        partitions = data.get('partitions', {})
        total = sum(p.get('end_offset', 0) for p in partitions.values())
        print(f"  {topic}: {len(partitions)} partitions, {total} messages")

    # Consumer group lag
    for group, group_data in report.get('consumer_groups', {}).items():
        total_lag = sum(
            p.get('lag', 0)
            for p in group_data.get('partitions', {}).values()
        )
        print(f"  {group}: total lag = {total_lag}")

if __name__ == '__main__':
    analyze(sys.argv[1] if len(sys.argv) > 1 else 'offset-report.json')
```

Usage:
```bash
python3 analyze_offsets.py offset-report.json
```

## Use Cases

### 1. Pre-Restore Planning
Understand the scope of a restore operation:
```bash
# Total messages to restore
jq '[.topics[].partitions[].message_count] | add' offset-report.json

# Estimated restore time (at 10,000 msg/sec)
jq '([.topics[].partitions[].message_count] | add) / 10000 | "Estimated: \(.) seconds"' offset-report.json
```

### 2. Migration Validation
Compare source and target clusters:
```bash
# After migration, generate reports from both clusters
diff <(jq '.topics' source-report.json) <(jq '.topics' target-report.json)
```

### 3. Consumer Group Audit
Track which groups are behind:
```bash
jq '.consumer_groups | to_entries | .[] | select(.value | [.partitions[].lag] | add > 0) | .key' offset-report.json
```

### 4. Partition Rebalancing Analysis
Check distribution across partitions:
```bash
jq '.topics.orders.partitions | to_entries | .[] | {partition: .key, messages: .value.message_count}' offset-report.json
```

## Output Formats

The `show-offset-mapping` command supports multiple formats:

```bash
# JSON (default) - machine readable
kafka-backup show-offset-mapping --format json

# CSV - spreadsheet compatible
kafka-backup show-offset-mapping --format csv

# Text - human readable
kafka-backup show-offset-mapping --format text
```

## Cleanup

```bash
rm -f offset-report.json
docker compose exec minio mc rm --recursive --force local/kafka-backups/report-demo/
```

## Next Steps

- Try [PITR + Rollback](../pitr-rollback-e2e/instructions.md) for point-in-time recovery
- Explore [Java Streams PITR](../../java-streams/pitr-restore/instructions.md) demo
