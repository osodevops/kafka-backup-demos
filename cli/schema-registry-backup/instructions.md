# Confluent Schema Registry Backup Demo

## Overview

Back up all Confluent Schema Registry subjects, schema versions, and compatibility configurations. This is an enterprise feature of kafka-backup.

**Difficulty:** Beginner
**Time:** 5 minutes
**Enterprise feature:** `schema_registry`

## Prerequisites

- Docker and Docker Compose
- Enterprise services running: `docker compose --profile enterprise up -d`

## Quick Start (Automated)

```bash
bash cli/schema-registry-backup/demo.sh
```

## Manual Walkthrough

### 1. Start enterprise services

```bash
docker compose --profile enterprise up -d
```

This starts Kafka, MinIO, Schema Registry, and registers test schemas (orders-value, payments-value, users-value).

### 2. Verify schemas exist

```bash
curl -s http://localhost:8081/subjects | python3 -m json.tool
```

### 3. Check enterprise trial

```bash
docker compose --profile enterprise run --rm kafka-backup-enterprise license info
```

### 4. Run schema-only backup

```bash
docker compose --profile enterprise run --rm kafka-backup-enterprise \
    backup --config /config/backup-schema-registry.yaml --schema-only
```

### 5. Verify backup in MinIO

Open http://localhost:9001 (minioadmin/minioadmin) and browse `kafka-backups/sr-demo/`.

## Key Observations

- Schema Registry backup runs after Kafka data backup (or standalone with `--schema-only`)
- All schema versions are captured (not just latest)
- Per-subject compatibility configs are preserved
- Schema references are resolved and topologically sorted for correct restore order
- The backup is stored alongside Kafka data in the same storage backend

## Config Used

```yaml
enterprise:
  schema_registry:
    url: "http://schema-registry:8081"
    backup:
      subjects: ["*"]
      include_versions: all
      include_references: true
```

## Cleanup

```bash
docker compose --profile enterprise down -v
```

## Next Steps

- [Apicurio Registry Backup](../apicurio-registry-backup/instructions.md)
- [Full Enterprise Backup](../enterprise-full-backup/instructions.md)
