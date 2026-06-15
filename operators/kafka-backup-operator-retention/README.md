# kafka-backup-operator Retention Behavior Demo

This demo captures the current `kafka-backup-operator` retention behavior fixed in the recent documentation work:

- `KafkaBackup` does not delete backup segment objects, manifests, offset stores, or consumer group snapshots.
- There is no supported `spec.retention` block on `kafka.oso.sh/v1alpha1` `KafkaBackup`.
- `retentionDays` belongs to `KafkaBackupValidation` evidence retention, not backup data retention.
- Backup data retention should be handled by object storage lifecycle policy or an external cleanup job.

## Run

```bash
./demo.sh
```

The script parses the local manifests and checks the checked-out operator CRD at `/Users/sionsmith/development/kafka-backup-operator/deploy/crds/all.yaml`.

To point it at another checkout:

```bash
KAFKA_BACKUP_OPERATOR_REPO=/path/to/kafka-backup-operator ./demo.sh
```

## Manifests

- `manifests/kafkabackup-no-retention.yaml` shows a valid scheduled backup with no unsupported retention block.
- `manifests/external-retention-cronjob.yaml` shows the Kubernetes-side cleanup pattern for filesystem/PVC backups.
- For S3/MinIO/Azure/GCS, prefer bucket/container lifecycle policies scoped to the backup prefix.
