# Snapshot Backup Demo

Demonstrates **snapshot backup mode** (`stop_at_current_offsets: true`) for consistent point-in-time backups.

## What This Demo Shows

1. Produces messages to a topic
2. Runs a **snapshot backup** — captures high watermarks at start, backs up to those offsets, then exits
3. Produces more messages *after* the snapshot started
4. Verifies the backup only contains messages from the snapshot point (not the later ones)

## Key Concept

Unlike continuous mode (`continuous: true`) which runs forever, snapshot mode:

- Captures high watermarks for all partitions at startup
- Backs up data until each partition reaches its target offset
- Exits cleanly with exit code 0

This makes it ideal for **Kubernetes CronJobs** and **scheduled DR backups**.

## Configuration

```yaml
backup:
  stop_at_current_offsets: true  # Snapshot mode
  include_offset_headers: true   # For offset recovery on restore
```

> **Note:** `stop_at_current_offsets` is incompatible with `continuous: true`. Use snapshot mode for scheduled backups and continuous mode for streaming replication.

## Run

```bash
# Start the demo environment
docker compose up -d
sleep 15

# Run the demo
./cli/snapshot-backup/demo.sh
```

## Related

- [Basic Backup & Restore](../backup-basic/instructions.md) — One-shot backup (similar but without snapshot semantics)
- [PITR + Rollback](../pitr-rollback-e2e/instructions.md) — Time-window restore from backups
