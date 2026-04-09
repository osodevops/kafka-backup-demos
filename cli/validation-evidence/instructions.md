# Validation & Compliance Evidence Demo

Demonstrates **backup validation** with deep integrity checks and compliance evidence generation.

## What This Demo Shows

1. Creates a backup of sample order data
2. Runs **quick validation** (manifest + segment existence)
3. Runs **deep validation** (decompresses and verifies every record)
4. Generates JSON output suitable for compliance audit trails

## Validation Levels

| Level | What It Checks | Speed |
|-------|---------------|-------|
| Quick (default) | Manifest exists, segments exist, metadata consistency | Fast |
| Deep (`--deep`) | All of quick + decompresses every segment, verifies record count, checks offset continuity | Slower |

## Compliance Use Cases

- **SOX** - Prove backup integrity for financial data with signed evidence
- **CMMC** - Evidence of backup validation for DoD contracts
- **GDPR** - Demonstrate data recovery capability for right-to-erasure compliance

## Run

```bash
# Start the demo environment
docker compose up -d
sleep 15

# Run the demo
./cli/validation-evidence/demo.sh
```

## Automate in CI/CD

```bash
# Validate after every backup — exit code 0 means all checks passed
kafka-backup validate \
  --path s3://my-backups \
  --backup-id daily-backup \
  --deep
```

## Related

- [Basic Backup & Restore](../backup-basic/instructions.md) — Backup/restore cycle
- [Snapshot Backup](../snapshot-backup/instructions.md) — Consistent point-in-time backups
