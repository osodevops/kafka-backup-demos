#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_REPO="${KAFKA_BACKUP_OPERATOR_REPO:-/Users/sionsmith/development/kafka-backup-operator}"
CRD_FILE="${OPERATOR_REPO}/deploy/crds/all.yaml"

echo "kafka-backup-operator retention behavior demo"
echo "Operator repo: ${OPERATOR_REPO}"
echo ""

python3 - "$SCRIPT_DIR" "$CRD_FILE" <<'PY'
import sys
from pathlib import Path

import yaml

script_dir = Path(sys.argv[1])
crd_file = Path(sys.argv[2])

if not crd_file.exists():
    raise SystemExit(f"CRD file not found: {crd_file}")

manifest_dir = script_dir / "manifests"
docs = []
for path in sorted(manifest_dir.glob("*.yaml")):
    with path.open() as handle:
        loaded = [doc for doc in yaml.safe_load_all(handle) if doc]
    docs.extend((path.name, doc) for doc in loaded)

backup = next(doc for name, doc in docs if doc.get("kind") == "KafkaBackup")
if "retention" in backup.get("spec", {}):
    raise SystemExit("KafkaBackup manifest must not include unsupported spec.retention")

cronjob = next(doc for name, doc in docs if doc.get("kind") == "CronJob")
if cronjob.get("apiVersion") != "batch/v1":
    raise SystemExit("External retention example must be a batch/v1 CronJob")

crds = [doc for doc in yaml.safe_load_all(crd_file.read_text()) if doc]
kafka_backup_crd = next(
    doc for doc in crds
    if doc.get("kind") == "CustomResourceDefinition"
    and doc.get("spec", {}).get("names", {}).get("kind") == "KafkaBackup"
)
version = next(v for v in kafka_backup_crd["spec"]["versions"] if v.get("served"))
spec_props = (
    version["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]
)

if "retention" in spec_props:
    raise SystemExit("Unexpected KafkaBackup spec.retention field found in kafka-backup-operator CRD")

if "schedule" not in spec_props:
    raise SystemExit("Expected KafkaBackup spec.schedule field was not found")

print("Validated manifests parse as YAML")
print("Validated KafkaBackup manifest omits unsupported spec.retention")
print("Validated checked-out KafkaBackup CRD has no spec.retention field")
print("Validated external retention pattern is a Kubernetes CronJob")
PY

echo ""
echo "Demo complete: backup data retention remains external for kafka-backup-operator."
