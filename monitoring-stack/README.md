# Kafka Backup Monitoring Stack

Docker Compose stack for monitoring OSO Kafka Backup with Prometheus, Grafana, and Mimir.

## Quick Start

```bash
# Start the monitoring stack
docker-compose -f docker-compose.metrics.yml up -d

# View logs
docker-compose -f docker-compose.metrics.yml logs -f
```

## Services

| Service | URL | Description |
|---------|-----|-------------|
| **Prometheus** | http://localhost:9090 | Metrics collection and querying |
| **Grafana** | http://localhost:3000 | Visualization dashboards (admin/admin) |
| **Mimir** | http://localhost:9009 | Long-term metrics storage |

## Prerequisites

1. OSO Kafka Backup running with metrics enabled:

```yaml
# backup.yaml
metrics:
  enabled: true
  port: 8080
```

2. Run your backup:

```bash
kafka-backup backup --config backup.yaml
```

## Grafana Dashboard

A pre-configured dashboard is automatically provisioned with panels for:

- Total Records / Total Bytes
- Compression Ratio
- Consumer Lag (total and per partition)
- Storage Write Latency (p50/p99)
- Storage I/O throughput

## Configuration

### Prometheus

Edit `prometheus/prometheus.yml` to change scrape targets:

```yaml
scrape_configs:
  - job_name: 'kafka-backup'
    static_configs:
      - targets: ['host.docker.internal:8080']  # Change this
```

### Grafana

- Datasources: `grafana/provisioning/datasources/datasources.yml`
- Dashboards: `grafana/provisioning/dashboards/`

## Stop the Stack

```bash
docker-compose -f docker-compose.metrics.yml down

# Remove volumes too
docker-compose -f docker-compose.metrics.yml down -v
```

## Documentation

See the full [Monitoring Setup Guide](https://osodevops.github.io/kafka-backup-docs/docs/guides/monitoring-setup) for detailed instructions.
