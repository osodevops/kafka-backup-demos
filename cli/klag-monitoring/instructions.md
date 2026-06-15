# CLI Demo: Consumer Lag Monitoring with Klag

**Core Feature:** Monitor consumer lag during backup/restore operations using Klag, Prometheus, and Grafana.

## Overview

This demo integrates [Klag](https://github.com/themoah/klag), a Kafka consumer lag exporter, with kafka-backup to demonstrate alert-driven backup timing and restore recovery monitoring.

The demo script defaults to Klag `0.2.3`, which includes the `0.2.2` features this demo depends on. To reproduce the original issue target exactly, set `KLAG_VERSION=0.2.2` when running the script, or set `KLAG_IMAGE=ghcr.io/themoah/klag:0.2.2` when starting Compose directly.

Key Klag metrics used here:

| Metric | Why it matters |
|--------|----------------|
| `klag_consumer_lag` | Current lag per partition |
| `klag_consumer_lag_sum` / `max` / `min` | Native aggregate lag series |
| `klag_consumer_lag_velocity` | Native lag change rate; positive means falling behind, negative means catching up |
| `klag_consumer_lag_ms` | Time-based lag from Kafka log timestamps |
| `klag_consumer_lag_time_to_close_seconds` | Recovery ETA while a consumer catches up |
| `klag_consumer_lag_retention_percent` | Data-loss-prevention signal; lag as a percentage of retained log data |
| `klag_consumer_group_state` | Consumer group health state |

Klag Prometheus labels use `consumer_group`, `topic`, and `partition` where applicable.

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
cd cli/klag-monitoring
chmod +x demo.sh
./demo.sh
```

Use an explicit Klag version when needed:

```bash
KLAG_VERSION=0.2.2 ./demo.sh
```

For manual Compose runs, override the image directly:

```bash
KLAG_IMAGE=ghcr.io/themoah/klag:0.2.2 docker compose --profile monitoring up -d
```

## Manual Walkthrough

### Step 1: Start Services with Monitoring Profile

```bash
# Start core Kafka services
docker compose up -d

# Start monitoring stack: klag, prometheus, grafana
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
curl http://localhost:8888/metrics
curl -s http://localhost:8888/metrics | grep klag_
```

### Step 4: Start a Slow Consumer

Start a rate-limited consumer that processes messages slowly to create lag:

```bash
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

### Step 5: Produce Faster Than the Consumer

```bash
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
curl -s http://localhost:8888/metrics | grep klag_consumer_lag

# Example output:
# klag_consumer_lag{consumer_group="lag-demo-consumers",topic="lag-demo-topic",partition="0"} 150
# klag_consumer_lag_sum{consumer_group="lag-demo-consumers"} 450
# klag_consumer_lag_velocity{consumer_group="lag-demo-consumers",topic="lag-demo-topic"} 8.4
# klag_consumer_lag_ms{consumer_group="lag-demo-consumers",topic="lag-demo-topic"} 240000
```

### Step 7: Query Prometheus

```bash
# Check Prometheus targets
curl http://localhost:9091/api/v1/targets

# Raw lag
curl 'http://localhost:9091/api/v1/query?query=klag_consumer_lag'

# Native aggregate lag per consumer group
curl 'http://localhost:9091/api/v1/query?query=sum(klag_consumer_lag_sum)%20by%20(consumer_group)'

# Lag velocity; positive means falling behind, negative means catching up
curl 'http://localhost:9091/api/v1/query?query=klag_consumer_lag_velocity'
```

Do not use `rate(klag_consumer_lag[1m])`: lag is a gauge, so Prometheus `rate()` is not meaningful for it. Use Klag's native `klag_consumer_lag_velocity` instead.

### Step 8: Take Backup When Retention Risk Appears

Klag's data-loss-prevention metric shows how much of the retained log window is already consumed by lag. In production this can drive an alert that says "back up now, unconsumed data is close to falling off the log."

```promql
# Page when any group/topic has consumed more than 80% of available retention
max by (consumer_group, topic) (
  klag_consumer_lag_retention_percent{topic="lag-demo-topic"}
) > 80
```

Run a backup while lag still exists:

```bash
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-lag-demo.yaml
```

### Step 9: Simulate Data Loss

```bash
# Stop the consumer first.

docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --delete --group lag-demo-consumers
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --delete --topic lag-demo-topic
'
```

Klag cleans up stale groups. After the consumer group and topic are deleted, the group's metrics should disappear rather than flatline at the last lag value.

### Step 10: Restore and Monitor Recovery ETA

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --create --topic lag-demo-topic \
        --partitions 3 --replication-factor 1
'

docker compose --profile tools run --rm kafka-backup \
    restore \
    --config /config/restore-lag-demo.yaml

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
# Watch lag and recovery ETA
watch -n 2 'curl -s http://localhost:8888/metrics | grep -E "klag_consumer_lag(_sum|_velocity|_time_to_close_seconds)?"'
```

`klag_consumer_lag_time_to_close_seconds` estimates when a catching-up consumer reaches zero lag. It is most useful after restore, when you need an RTO countdown rather than only a raw lag number.

## Grafana Dashboard

Grafana is provisioned automatically with:

- Prometheus datasource: `http://prometheus:9090`
- Klag dashboard: [klag-dashboard.json](klag-dashboard.json), copied from upstream `dashboard/demo-dashboard.json`

Open http://localhost:3000 and sign in with `admin/admin`. The dashboard appears under the `Kafka Backup` folder as `Klag - Kafka Lag Monitoring`.

If port `3000` is already in use, the demo script chooses the next available port and prints the actual Grafana URL. For manual runs, set `GRAFANA_PORT`, `PROMETHEUS_PORT`, or `KLAG_METRICS_PORT` before starting Compose.

## MCP Endpoint

Klag ships an opt-in read-only MCP endpoint for AI/SRE agents. The demo keeps it disabled by default.

```bash
KLAG_MCP_ENABLED=true \
KLAG_MCP_AUTH_TOKEN=demo-token \
docker compose --profile monitoring up -d klag
```

When enabled, the endpoint is exposed by Klag at `http://localhost:8888/mcp`. Use `Authorization: Bearer demo-token` when `KLAG_MCP_AUTH_TOKEN` is set.

## Helm Chart

Klag also ships an official Helm chart in the upstream repository:

```bash
git clone https://github.com/themoah/klag.git
helm install klag ./klag/charts/klag --set kafka.bootstrapServers="kafka-broker:9092"
```

## Monitoring Endpoints

| Service | URL | Credentials |
|---------|-----|-------------|
| Klag Metrics | http://localhost:8888/metrics | - |
| Prometheus | http://localhost:9091 | - |
| Grafana | http://localhost:3000 | admin/admin |

The default host ports can be overridden with `KLAG_METRICS_PORT`, `PROMETHEUS_PORT`, and `GRAFANA_PORT`.

## Sample Prometheus Queries

```promql
# Total lag per consumer group
sum(klag_consumer_lag_sum) by (consumer_group)

# Lag per topic and partition
klag_consumer_lag{topic="lag-demo-topic"}

# Lag velocity: positive = falling behind, negative = catching up
klag_consumer_lag_velocity{topic="lag-demo-topic"}

# Consumer groups with lag > 100
sum(klag_consumer_lag_sum) by (consumer_group) > 100

# Time-based lag in minutes
klag_consumer_lag_ms{topic="lag-demo-topic"} / 1000 / 60

# Recovery ETA in seconds
klag_consumer_lag_time_to_close_seconds{topic="lag-demo-topic"}

# Data-loss-prevention alert threshold
max by (consumer_group, topic) (klag_consumer_lag_retention_percent) > 80
```

## Architecture

```text
Kafka Broker -> Klag exporter -> Prometheus -> Grafana
      |              |
      |              +-> /metrics:8888 and optional /mcp
      |
      +-> kafka-backup backup/restore workflow
```

## Key Observations

1. **Lag Visibility**: Klag provides instant visibility into consumer group health.
2. **Backup Timing**: Retention-percent alerts can trigger an immediate backup before unconsumed data ages out.
3. **Recovery Monitoring**: Time-to-close gives an ETA after restore, not just a shrinking lag number.
4. **Gauge Semantics**: Use `klag_consumer_lag_velocity` for lag movement; do not apply `rate()` to `klag_consumer_lag`.
5. **Stale Cleanup**: Deleted consumer groups disappear from Klag metrics instead of flatlining.

## Cleanup

```bash
docker compose --profile monitoring down

docker compose run --rm --entrypoint /bin/sh minio-setup -c \
  'mc alias set local http://minio:9000 minioadmin minioadmin && mc rm --recursive --force local/kafka-backups/lag-demo/'

docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --delete --topic lag-demo-topic
'
```

## Next Steps

- Try the [Basic Backup & Restore](../backup-basic/instructions.md) demo.
- Explore [PITR + Rollback](../pitr-rollback-e2e/instructions.md) for point-in-time recovery.
- Check the [Benchmarks](../../benchmarks/instructions.md) for performance testing.
