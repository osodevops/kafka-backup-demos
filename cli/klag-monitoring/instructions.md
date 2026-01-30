# CLI Demo: Consumer Lag Monitoring with Klag

**Core Feature:** Monitor consumer lag during backup/restore operations using Klag + Prometheus

## Overview

This demo integrates [Klag](https://github.com/themoah/klag) (Kafka Consumer Lag Exporter) with kafka-backup to demonstrate real-time consumer lag monitoring during backup and restore operations.

**Klag** is a lightweight Kafka consumer lag exporter that exposes Prometheus metrics including:
- `klag_consumer_lag` - Current lag per partition
- `klag_consumer_lag_velocity` - Rate of lag change
- `klag_consumer_group_state` - Consumer group health state

## Prerequisites

```bash
# Start the demo environment with monitoring services
docker compose --profile monitoring up -d

# Wait for services to be ready
docker compose logs -f kafka-setup
# Wait until you see "All demo topics created successfully"
```

## Quick Start

```bash
# Run the automated demo
cd cli/klag-monitoring
chmod +x demo.sh
./demo.sh
```

## Manual Walkthrough

### Step 1: Start Services with Monitoring Profile

```bash
# Start core Kafka services
docker compose up -d

# Start monitoring stack (klag, prometheus, grafana)
docker compose --profile monitoring up -d
```

### Step 2: Create Demo Topic

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --create --topic lag-demo-topic \
        --partitions 3 --replication-factor 1
'
```

### Step 3: Verify Klag Metrics Endpoint

```bash
# Check klag is responding
curl http://localhost:8888/metrics

# Look for klag metrics
curl -s http://localhost:8888/metrics | grep klag_
```

### Step 4: Start a Slow Consumer

Start a rate-limited consumer that processes messages slowly to create lag:

```bash
# In a separate terminal - consume slowly (2 msg/sec)
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic lag-demo-topic \
        --group lag-demo-consumers \
        --from-beginning 2>&1 | while read -r line; do
            echo "$line"
            sleep 0.5
        done
'
```

### Step 5: Produce Messages Faster Than Consumer

```bash
# Produce 500 messages quickly
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 500); do
        echo "{\"id\": $i, \"timestamp\": \"$(date -Iseconds)\", \"data\": \"message-$i\"}"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic lag-demo-topic
'
```

### Step 6: Observe Lag Building Up

```bash
# Query klag metrics directly
curl -s http://localhost:8888/metrics | grep klag_consumer_lag

# Example output:
# klag_consumer_lag{group="lag-demo-consumers",topic="lag-demo-topic",partition="0"} 150
# klag_consumer_lag{group="lag-demo-consumers",topic="lag-demo-topic",partition="1"} 148
# klag_consumer_lag{group="lag-demo-consumers",topic="lag-demo-topic",partition="2"} 152
```

### Step 7: Query Prometheus

```bash
# Check Prometheus targets
curl http://localhost:9091/api/v1/targets

# Query consumer lag
curl 'http://localhost:9091/api/v1/query?query=klag_consumer_lag'

# Total lag across all partitions
curl 'http://localhost:9091/api/v1/query?query=sum(klag_consumer_lag)%20by%20(group)'
```

### Step 8: Take Backup While Lag Exists

```bash
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-lag-demo.yaml
```

### Step 9: Simulate Data Loss

```bash
# Stop the consumer (Ctrl+C in consumer terminal)

# Delete consumer group and topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --delete --group lag-demo-consumers
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --delete --topic lag-demo-topic
'
```

### Step 10: Restore and Monitor Recovery

```bash
# Recreate topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --create --topic lag-demo-topic \
        --partitions 3 --replication-factor 1
'

# Restore from backup
docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-lag-demo.yaml

# Restart consumer and watch lag recover
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic lag-demo-topic \
        --group lag-demo-consumers \
        --from-beginning
'
```

### Step 11: Verify Lag Recovery

```bash
# Watch lag decrease to 0
watch -n 2 'curl -s http://localhost:8888/metrics | grep klag_consumer_lag'
```

## Monitoring Endpoints

| Service | URL | Credentials |
|---------|-----|-------------|
| Klag Metrics | http://localhost:8888/metrics | - |
| Prometheus | http://localhost:9091 | - |
| Grafana | http://localhost:3000 | admin/admin |

## Key Klag Metrics

| Metric | Description |
|--------|-------------|
| `klag_consumer_lag` | Current lag per partition |
| `klag_consumer_lag_velocity` | Rate of lag change (messages/sec) |
| `klag_consumer_group_state` | Consumer group state (0=Unknown, 1=PreparingRebalance, 2=CompletingRebalance, 3=Stable, 4=Dead, 5=Empty) |

## Sample Prometheus Queries

```promql
# Total lag per consumer group
sum(klag_consumer_lag) by (group)

# Lag per topic and partition
klag_consumer_lag{topic="lag-demo-topic"}

# Rate of lag change over 1 minute
rate(klag_consumer_lag[1m])

# Consumer groups with lag > 100
sum(klag_consumer_lag) by (group) > 100

# Lag velocity (are we catching up or falling behind?)
klag_consumer_lag_velocity
```

## Creating Grafana Dashboards

1. Open Grafana at http://localhost:3000
2. Login with admin/admin
3. Add Prometheus data source:
   - URL: http://prometheus:9090
4. Create dashboard with panels:
   - Consumer Lag (gauge): `sum(klag_consumer_lag) by (group)`
   - Lag Over Time (graph): `klag_consumer_lag`
   - Consumer Group State (stat): `klag_consumer_group_state`

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│                 │     │                 │     │                 │
│  Kafka Broker   │────▶│      Klag       │────▶│   Prometheus    │
│                 │     │   (exporter)    │     │                 │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
        │                       │                        │
        │                       │                        ▼
        ▼                       ▼                ┌─────────────────┐
┌─────────────────┐     ┌─────────────────┐     │                 │
│  kafka-backup   │     │  /metrics:8888  │     │    Grafana      │
│                 │     │                 │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

## Key Observations

1. **Lag Visibility**: Klag provides instant visibility into consumer group health
2. **Backup Timing**: You can monitor lag before deciding to take a backup
3. **Recovery Monitoring**: Watch lag recover to 0 after restore completes
4. **Alerting Ready**: Prometheus metrics can drive alerts for lag thresholds

## Cleanup

```bash
# Stop monitoring services
docker compose --profile monitoring down

# Remove backup from MinIO
docker compose --profile tools exec minio mc rm --recursive --force local/kafka-backups/lag-demo/

# Delete topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --delete --topic lag-demo-topic
'
```

## Next Steps

- Try the [Basic Backup & Restore](../backup-basic/instructions.md) demo
- Explore [PITR + Rollback](../pitr-rollback-e2e/instructions.md) for point-in-time recovery
- Check the [Benchmarks](../../benchmarks/instructions.md) for performance testing
