# Apicurio Registry v3 Backup Demo

## Overview

Back up all groups, artifacts, versions, content, references, and rules from Apicurio Registry v3. Captures both the native export ZIP and a structured artefact-by-artefact backup.

**Difficulty:** Beginner
**Time:** 5 minutes
**Enterprise feature:** `schema_registry`

## Prerequisites

- Docker and Docker Compose
- Enterprise services running: `docker compose --profile enterprise up -d`

## Quick Start (Automated)

```bash
bash cli/apicurio-registry-backup/demo.sh
```

## Manual Walkthrough

### 1. Start enterprise services

```bash
docker compose --profile enterprise up -d
```

This starts Kafka, MinIO, Apicurio Registry (with PostgreSQL), and registers test data:
- Groups: `payments`, `orders`, `common`
- Artifacts: PaymentEvent (Avro), OrderCreated (Protobuf), Address (Avro)
- Global COMPATIBILITY rule

### 2. Verify Apicurio is ready

```bash
# Health check
curl -s http://localhost:8085/q/health | python3 -m json.tool

# List groups
curl -s http://localhost:8085/apis/registry/v3/groups | python3 -m json.tool
```

### 3. Run Apicurio backup

```bash
docker compose --profile enterprise run --rm kafka-backup-enterprise \
    backup --config /config/backup-apicurio.yaml --schema-only
```

### 4. Browse backup in MinIO

Open http://localhost:9001 (minioadmin/minioadmin) and browse `kafka-backups/apicurio-demo/`.

You'll see:
```
apicurio-demo-backup/apicurio-registry/
  _manifest.json           # Backup stats and dependency order
  _export.zip              # Native Apicurio export (for disaster recovery)
  _global_rules.json       # Global COMPATIBILITY rule
  groups/
    payments/_metadata.json # Group metadata + group rules
    payments/artifacts/PaymentEvent/
      _metadata.json        # Artifact metadata + artifact rules
      versions/1.json       # Version metadata (globalId, contentId)
      versions/1.content    # Raw Avro schema bytes
    orders/...
    common/...
```

## Key Observations

- The export ZIP is the **primary** backup artifact — a single file for full disaster recovery
- The artefact-by-artefact backup provides structured, inspectable data
- All 9 Apicurio artifact types are supported (Avro, Protobuf, JSON Schema, OpenAPI, AsyncAPI, GraphQL, KCONNECT, WSDL, XSD)
- Rules are captured at all 3 scopes: global, group, and artifact
- References are topologically sorted for correct restore order
- Both Confluent SR and Apicurio can be configured in the same config

## Config Used

```yaml
enterprise:
  apicurio_registry:
    url: "http://apicurio-registry:8080"
    backup:
      groups: ["*"]
      artifacts: ["*"]
      include_export: true
      include_versions: all
      include_references: true
```

## Cleanup

```bash
docker compose --profile enterprise down -v
```

## Next Steps

- [Schema Registry Backup](../schema-registry-backup/instructions.md)
- [Full Enterprise Backup](../enterprise-full-backup/instructions.md)
