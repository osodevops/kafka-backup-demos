# kafka-backup-demos

A collection of runnable demos for [OSO Kafka Backup](https://github.com/osodevops/kafka-backup) - a high-performance Kafka backup and restore tool with point-in-time recovery.

## Quick Start

```bash
# Start the demo environment
docker compose up -d

# Wait for services to be ready (~15 seconds)
docker compose logs kafka-setup

# Run any demo (see list below)
cd cli/backup-basic
./demo.sh
```

## Prerequisites

- Docker and Docker Compose v2+
- 4GB+ available RAM
- For Java demos: JDK 17+ and Maven
- For Python demo: Python 3.9+

## Demo Environment

The `docker-compose.yml` provides:

| Service | Description | Port |
|---------|-------------|------|
| kafka-broker-1 | Apache Kafka 3.7.1 (KRaft mode) | 9092 |
| minio | S3-compatible object storage | 9000 (API), 9001 (Console) |
| kafka-cli | Kafka CLI tools container | - |
| kafka-backup | OSO Kafka Backup CLI | - |

**Pre-configured topics:** `orders`, `payments`, `events`, `orders_enriched`, `large_messages`

**MinIO Console:** http://localhost:9001 (minioadmin/minioadmin)

## Demos

### CLI Demos

| Demo | Path | Feature | Difficulty |
|------|------|---------|------------|
| [Offset State Verification](cli/offset-testing/instructions.md) | `cli/offset-testing/` | Consumer offset snapshot & inspection | Beginner |
| [Basic Backup & Restore](cli/backup-basic/instructions.md) | `cli/backup-basic/` | Full backup/restore cycle to MinIO | Beginner |
| [Large Messages](cli/large-messages/instructions.md) | `cli/large-messages/` | Handling large payloads with compression | Intermediate |
| [Offset Mapping Report](cli/offset-report/instructions.md) | `cli/offset-report/` | JSON offset mapping & analysis | Intermediate |
| [PITR + Rollback](cli/pitr-rollback-e2e/instructions.md) | `cli/pitr-rollback-e2e/` | End-to-end point-in-time recovery | Advanced |

### Java Demos

| Demo | Path | Feature | Difficulty |
|------|------|---------|------------|
| [Kafka Streams PITR](java-streams/pitr-restore/instructions.md) | `java-streams/pitr-restore/` | Streams app point-in-time recovery | Intermediate |
| [Offset Reset Verify](java-streams/offset-reset-verify/instructions.md) | `java-streams/offset-reset-verify/` | Bulk offset reset correctness | Intermediate |

### Spring Boot Demos

| Demo | Path | Feature | Difficulty |
|------|------|---------|------------|
| [Backup & Restore Flow](springboot/backup-restore-flow/instructions.md) | `springboot/backup-restore-flow/` | E2E backup/restore with Spring Streams | Intermediate |
| [Producer/Consumer PITR](springboot/producer-consumer/instructions.md) | `springboot/producer-consumer/` | Microservice pair with PITR | Advanced |

### Python Demo

| Demo | Path | Feature | Difficulty |
|------|------|---------|------------|
| [Backup & Restore](python/backup-restore-py/instructions.md) | `python/backup-restore-py/` | Language-agnostic validation | Beginner |

## Running kafka-backup Commands

```bash
# Using docker compose
docker compose --profile tools run --rm kafka-backup backup --config /config/backup.yaml
docker compose --profile tools run --rm kafka-backup restore --config /config/restore.yaml

# Using kafka-cli for Kafka commands
docker compose --profile tools exec kafka-cli kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
docker compose --profile tools exec kafka-cli kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 --topic orders --from-beginning
```

## Core Features Demonstrated

1. **Topic Backup & Restore** - Full backup to S3/MinIO with restore validation
2. **Point-in-Time Recovery (PITR)** - Millisecond-precision time-window filtering
3. **Consumer Offset Management** - Snapshots, rollback, and bulk reset
4. **Offset Mapping** - JSON reports for migration planning
5. **Large Message Handling** - Compression (zstd, lz4, gzip) for large payloads
6. **Three-Phase Restore** - Solving the offset space discontinuity problem

## Cleanup

```bash
# Stop all services
docker compose down

# Remove all data (including MinIO storage)
docker compose down -v
```

## Documentation

- [Demo Index](docs/demo-index.md) - Complete demo reference
- [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions
- [Known Issues](docs/known-issues.md) - Current limitations

## Related

- [kafka-backup Repository](https://github.com/osodevops/kafka-backup)
- [kafka-backup Documentation](https://github.com/osodevops/kafka-backup/tree/main/docs)
