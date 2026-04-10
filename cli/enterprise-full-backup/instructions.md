# Full Enterprise Backup Demo

## Overview

Back up Kafka data, Confluent Schema Registry, and Apicurio Registry in a single command. This demonstrates the complete enterprise disaster recovery workflow.

**Difficulty:** Intermediate
**Time:** 10 minutes
**Enterprise features:** `schema_registry` (covers both Confluent SR and Apicurio)

## What Gets Backed Up

| Component | Data |
|-----------|------|
| **Kafka** | Topics (orders, payments), all partitions, all messages |
| **Confluent Schema Registry** | Subjects, versions, schemas (Avro, JSON Schema), compatibility configs |
| **Apicurio Registry** | Groups, artifacts, versions, content, rules, export ZIP |

## Prerequisites

- Docker and Docker Compose
- ~2GB free disk space (for all containers)

## Quick Start (Automated)

```bash
bash cli/enterprise-full-backup/demo.sh
```

## Manual Walkthrough

### 1. Start all enterprise services

```bash
docker compose --profile enterprise up -d
```

Wait ~30 seconds for Apicurio Registry to be ready.

### 2. Produce test data

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 20); do
        echo "{\"order_id\":\"ORD-$i\",\"amount\":$((RANDOM % 1000))}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
```

### 3. Run full enterprise backup

```bash
docker compose --profile enterprise run --rm kafka-backup-enterprise \
    backup --config /config/backup-enterprise-full.yaml
```

This runs in order:
1. Kafka data backup (orders + payments topics)
2. Schema Registry backup (orders-value, payments-value subjects)
3. Apicurio Registry backup (3 groups, export ZIP, rules)

### 4. Browse the backup

Open MinIO at http://localhost:9001 (minioadmin/minioadmin):

```
kafka-backups/enterprise-full/enterprise-full-backup/
  topics/                           # Kafka data
    orders/partition=0/segment-*.zst
    payments/partition=0/segment-*.zst
  schema-registry/                  # Confluent SR
    _manifest.json
    _global_config.json
    subjects/orders-value/v1.json
    subjects/orders-value/v2.json
    subjects/payments-value/v1.json
  apicurio-registry/                # Apicurio
    _manifest.json
    _export.zip
    _global_rules.json
    groups/payments/...
    groups/orders/...
    groups/common/...
```

## Config Used

```yaml
enterprise:
  schema_registry:
    url: "http://schema-registry:8081"
    backup:
      subjects: ["orders-*", "payments-*"]

  apicurio_registry:
    url: "http://apicurio-registry:8080"
    backup:
      groups: ["payments", "orders", "common"]
      include_export: true
```

Both registries run in the same backup — Confluent SR first, then Apicurio.

## Cleanup

```bash
docker compose --profile enterprise down -v
```

## Next Steps

- [Basic Backup](../backup-basic/instructions.md) — OSS Kafka backup
- [PITR Rollback](../pitr-rollback-e2e/instructions.md) — Point-in-time recovery
