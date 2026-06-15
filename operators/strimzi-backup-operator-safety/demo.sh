#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_REPO="${STRIMZI_BACKUP_OPERATOR_REPO:-/Users/sionsmith/development/strimzi-backup-operator}"
BACKUP_CRD="${OPERATOR_REPO}/deploy/crds/kafkabackups.yaml"
RESTORE_CRD="${OPERATOR_REPO}/deploy/crds/kafkarestores.yaml"

echo "strimzi-backup-operator safety controls demo"
echo "Operator repo: ${OPERATOR_REPO}"
echo ""

python3 - "$SCRIPT_DIR" "$BACKUP_CRD" "$RESTORE_CRD" <<'PY'
import sys
from pathlib import Path

import yaml

script_dir = Path(sys.argv[1])
backup_crd = Path(sys.argv[2])
restore_crd = Path(sys.argv[3])

for path in (backup_crd, restore_crd):
    if not path.exists():
        raise SystemExit(f"CRD file not found: {path}")

docs = []
for path in sorted((script_dir / "manifests").glob("*.yaml")):
    with path.open() as handle:
        docs.extend(doc for doc in yaml.safe_load_all(handle) if doc)

backup = next(doc for doc in docs if doc.get("kind") == "KafkaBackup")
restore = next(doc for doc in docs if doc.get("kind") == "KafkaRestore")

backup_spec = backup["spec"]
restore_spec = restore["spec"]

checks = [
    (backup_spec["schedule"]["suspend"] is True, "backup schedule is suspended"),
    (backup_spec["template"]["pod"]["serviceAccountName"] == "kafka-backup-jobs", "backup per-CR service account"),
    (len(backup_spec["template"]["pod"]["hostAliases"]) == 1, "backup hostAliases"),
    (backup_spec["backoffLimit"] == 1, "backup backoffLimit"),
    ("include" in backup_spec["topics"] and "exclude" in backup_spec["topics"], "backup topic selection"),
    (restore_spec["topics"]["include"] == ["orders-*", "payments-*"], "restore include topic selection"),
    (restore_spec["topics"]["exclude"] == ["payments-test-*"], "restore exclude topic selection"),
    (restore_spec["template"]["pod"]["serviceAccountName"] == "kafka-restore-jobs", "restore per-CR service account"),
    (len(restore_spec["template"]["pod"]["hostAliases"]) == 1, "restore hostAliases"),
    (restore_spec["backoffLimit"] == 0, "restore backoffLimit is single attempt"),
    (restore_spec["restore"]["dryRun"] is True, "restore dryRun safety"),
]

for passed, label in checks:
    if not passed:
        raise SystemExit(f"Manifest check failed: {label}")

def crd_spec_props(path):
    crd = yaml.safe_load(path.read_text())
    version = next(v for v in crd["spec"]["versions"] if v.get("served"))
    return version["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]

def require_path(props, dotted_path):
    node = props
    for part in dotted_path.split("."):
        if part == "items":
            node = node["items"]
            continue
        if part not in node:
            raise SystemExit(f"CRD is missing field path: {dotted_path}")
        node = node[part]
        if "properties" in node:
            node = node["properties"]
    return True

backup_props = crd_spec_props(backup_crd)
restore_props = crd_spec_props(restore_crd)

for field in [
    "backoffLimit",
    "schedule.suspend",
    "template.pod.hostAliases",
    "template.pod.serviceAccountName",
    "topics.include",
    "topics.exclude",
]:
    require_path(backup_props, field)

for field in [
    "backoffLimit",
    "template.pod.hostAliases",
    "template.pod.serviceAccountName",
    "topics.include",
    "topics.exclude",
]:
    require_path(restore_props, field)

print("Validated manifests parse as YAML")
print("Validated backup schedule suspend, hostAliases, serviceAccountName, topic selection, and backoffLimit")
print("Validated restore topic selection, dryRun, hostAliases, serviceAccountName, and backoffLimit")
print("Validated checked-out Strimzi backup/restore CRDs expose the expected fields")
PY

echo ""
echo "Demo complete: Strimzi operator safety controls are represented in the demo manifests and CRDs."
