# Continuous Incremental Backup Demo

Demonstrates **continuous backup mode** with offset tracking for resumable incremental backups.

## What This Demo Shows

1. Starts a continuous backup (`continuous: true`)
2. Interrupts it (simulating a pod restart or crash)
3. Produces new messages while the backup is stopped
4. Resumes the backup — it picks up from the last checkpoint, only backing up new data

## Key Concept

Continuous backups track progress in a **local SQLite offset database**:

- Stored at `$TMPDIR/{backup_id}-offsets.db` by default (configurable via `offset_storage.db_path`)
- Periodically synced to remote storage (S3/GCS/Azure) for durability
- On restart, the offset DB is loaded from remote storage to resume from the last checkpoint

This means you get **exactly-once backup semantics** even across process restarts.

## Configuration

```yaml
backup:
  continuous: true           # Run forever
  start_offset: earliest     # Start from beginning on first run
  checkpoint_interval_secs: 5
  sync_interval_secs: 10
  poll_interval_ms: 500

# Optional: custom offset database path
# offset_storage:
#   db_path: /data/offsets.db
```

## Kubernetes Deployment

For Kubernetes with `readOnlyRootFilesystem: true`, mount `/tmp` as an emptyDir:

```yaml
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir: {}
```

See [Kubernetes Deployment](https://kafkabackup.com/deployment/kubernetes) for full examples.

## Run

```bash
# Start the demo environment
docker compose up -d
sleep 15

# Run the demo
./cli/continuous-incremental/demo.sh
```

## Related

- [Snapshot Backup](../snapshot-backup/instructions.md) — One-time consistent backups (exits when done)
- [Basic Backup & Restore](../backup-basic/instructions.md) — Simple one-shot backup
- [Live Producer Backup](../live-producer-backup/instructions.md) — Backup while producers are active
