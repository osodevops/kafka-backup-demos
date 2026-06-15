# Kubernetes Operator Demos

Focused demos for recent operator changes in the related repositories:

| Demo | Path | What it proves |
|------|------|----------------|
| kafka-backup-operator retention behavior | `kafka-backup-operator-retention/` | `KafkaBackup` data retention is external today; use object-store lifecycle or a cleanup CronJob |
| Strimzi backup operator safety controls | `strimzi-backup-operator-safety/` | Recent CRD fields for host aliases, schedule suspend, restore topic selection, per-CR service accounts, and retry limits |

The scripts default to local static validation against the checked-out operator repositories. They do not apply resources to the current Kubernetes context unless you explicitly opt in from a safe local cluster.
