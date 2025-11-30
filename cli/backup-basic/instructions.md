# CLI Demo: Basic Topic Backup & Restore

**Core Feature:** Full backup/restore cycle to S3/MinIO

## Overview

This demo demonstrates the fundamental backup and restore workflow:
1. Produce data to a Kafka topic
2. Backup the topic to S3-compatible storage (MinIO)
3. Simulate data loss by deleting the topic
4. Restore from backup
5. Validate data integrity

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
cd cli/backup-basic
chmod +x demo.sh
./demo.sh
```

## Manual Walkthrough

### Step 1: Produce Sample Data

```bash
# Produce data from the sample CSV file
docker compose --profile tools run --rm kafka-cli bash -c '
    tail -n +2 /data/orders.csv | while IFS=, read -r order_id customer_id product amount currency timestamp; do
        echo "{\"order_id\": \"$order_id\", \"customer_id\": \"$customer_id\", \"product\": \"$product\", \"amount\": $amount, \"currency\": \"$currency\", \"timestamp\": \"$timestamp\"}"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders
'
```

### Step 2: Verify Message Count

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic orders
'
```

Expected output:
```
orders:0:33
orders:1:34
orders:2:33
```

### Step 3: Run Backup

```bash
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-basic.yaml
```

The backup configuration (`config/backup-basic.yaml`):
```yaml
mode: backup
backup_id: "basic-backup"

source:
  bootstrap_servers:
    - kafka-broker-1:9092
  topics:
    include:
      - orders

storage:
  backend: s3
  bucket: kafka-backups
  region: us-east-1
  prefix: basic-demo
  endpoint: http://minio:9000    # MinIO endpoint
  path_style: true               # Required for MinIO
  access_key_id: minioadmin
  secret_access_key: minioadmin

backup:
  compression: zstd
  continuous: false
  segment_max_records: 10000
  segment_max_bytes: 10485760
  max_concurrent_partitions: 3
```

### Step 4: Verify Backup

List available backups:
```bash
docker compose --profile tools run --rm kafka-backup \
    list \
    --path s3://kafka-backups/basic-demo
```

Describe backup details:
```bash
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/basic-demo \
    --backup-id basic-backup \
    --format json
```

### Step 5: Simulate Data Loss

```bash
# Delete the topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --delete \
        --topic orders
'
```

### Step 6: Recreate Empty Topic

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --create \
        --topic orders \
        --partitions 3 \
        --replication-factor 1
'
```

### Step 7: Restore from Backup

```bash
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-basic.yaml
```

### Step 8: Validate Restoration

```bash
# Count messages
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list kafka-broker-1:9092 \
        --topic orders
'

# Sample content
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic orders \
        --from-beginning \
        --max-messages 5
'
```

## Storage Layout

After backup, the MinIO bucket contains:
```
kafka-backups/
└── basic-demo/
    └── basic-backup/
        ├── manifest.json           # Backup metadata
        ├── state/
        │   └── offsets.db         # Checkpoint database
        └── topics/
            └── orders/
                ├── partition=0/
                │   └── segment-0001.zst
                ├── partition=1/
                │   └── segment-0001.zst
                └── partition=2/
                    └── segment-0001.zst
```

## Viewing in MinIO Console

1. Open http://localhost:9001
2. Login: `minioadmin` / `minioadmin`
3. Navigate to `kafka-backups` bucket
4. Browse the backup structure

## Adapting to AWS S3

Modify `config/backup-basic.yaml`:

```yaml
storage:
  backend: s3
  bucket: your-bucket-name
  region: us-east-1
  prefix: kafka-backups
  # Remove 'endpoint' and 'path_style' for real S3
  # Use environment variables for credentials:
  # access_key_id: ${AWS_ACCESS_KEY_ID}
  # secret_access_key: ${AWS_SECRET_ACCESS_KEY}
```

Or use IAM roles if running on EC2/EKS.

## Key Observations

1. **Compression**: zstd provides excellent compression ratios (3-5x typical)
2. **Parallel Processing**: Multiple partitions are backed up concurrently
3. **Segmentation**: Large topics are split into manageable segments
4. **Metadata Preservation**: Original offsets are stored in message headers

## Cleanup

```bash
# Remove the backup from MinIO
docker compose --profile tools exec minio mc rm --recursive --force local/kafka-backups/basic-demo/
```

## Next Steps

- Try the [Large Messages](../large-messages/instructions.md) demo
- Explore [PITR + Rollback](../pitr-rollback-e2e/instructions.md) for point-in-time recovery
