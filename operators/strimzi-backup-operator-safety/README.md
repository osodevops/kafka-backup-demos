# Strimzi Backup Operator Safety Controls Demo

This demo shows recent `strimzi-backup-operator` features worth demonstrating:

- `spec.template.pod.hostAliases` for backup/restore job pods.
- `spec.schedule.suspend` propagating to generated backup CronJobs.
- `KafkaRestore.spec.topics.include/exclude` for selective restore.
- Per-CR `spec.template.pod.serviceAccountName` overrides.
- `spec.backoffLimit`, with restore jobs defaulting to a single attempt unless explicitly changed.

## Run

```bash
./demo.sh
```

The script performs local static validation against `/Users/sionsmith/development/strimzi-backup-operator/deploy/crds/` and checks the demo manifests contain the expected fields. It does not apply anything to the active Kubernetes context.

To point it at another checkout:

```bash
STRIMZI_BACKUP_OPERATOR_REPO=/path/to/strimzi-backup-operator ./demo.sh
```

## Manifests

- `manifests/kafkabackup-suspended.yaml` demonstrates a suspended schedule, host aliases, a per-CR service account, retention, and `backoffLimit`.
- `manifests/kafkarestore-selected-topics.yaml` demonstrates selective restore, dry-run restore options, host aliases, a per-CR service account, and `backoffLimit: 0`.
