#!/bin/bash
# GDPR Right-to-Erasure Demo (kafka-backup Enterprise 0.4+)
# Demonstrates: an erasure request arriving AFTER a backup was taken, and the
# backup being restored with the erasure re-applied — the regulator-accepted
# "erasure on restore" posture (ICO "put beyond use", EDPB Art. 17 guidance).
#   produce PII -> backup -> Art. 17 request -> tombstone restore -> drop restore
#   -> fail-loud (missing list) -> licence gate (unlicensed) -> validate-restore
set -eo pipefail   # pipefail: `cmd | tee` must report cmd's exit status (steps 5-8)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   GDPR Right-to-Erasure Demo (Enterprise)"
echo "================================================"
echo ""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
print_step()    { echo -e "${BLUE}[Step $1]${NC} $2"; echo ""; }
print_info()    { echo -e "${YELLOW}→${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; echo ""; }
print_error()   { echo -e "${RED}✗${NC} $1"; }

# Enterprise binary (osodevops/kafka-backup-enterprise; override with KAFKA_BACKUP_ENTERPRISE_IMAGE)
kbe()  { docker compose --profile enterprise run --rm kafka-backup-enterprise "$@"; }
# Kafka CLI tools
kcli() { docker compose --profile tools run --rm kafka-cli bash -c "$1"; }
consume() {  # consume <topic> → "key:value" lines, null values printed as "null"
  kcli "kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 --topic $1 \
        --from-beginning --timeout-ms 10000 --property print.key=true --property key.separator=: 2>/dev/null" \
    | grep -E '^U[0-9]+:' || true
}
fail() { print_error "$1"; exit 1; }

print_step 1 "Checking Docker services..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    docker compose up -d
    echo "Waiting for Kafka to be ready (20 seconds)..."; sleep 20
fi
print_success "Docker services are running"

print_step 2 "Producing customer PII to a compacted topic and orders to a plain topic..."
# Idempotent: wipe any previous demo backup set and topics so counts are predictable.
docker compose run --rm --entrypoint /bin/sh minio-setup -c '
    mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null &&
    mc rm --recursive --force local/kafka-backups/gdpr-demo 2>/dev/null || true' >/dev/null 2>&1 || true
kcli '
    for t in customers orders customers-restored orders-restored customers-failloud; do
      kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic $t 2>/dev/null || true
    done
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic customers --partitions 3 --replication-factor 1 \
      --config cleanup.policy=compact
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic orders --partitions 3 --replication-factor 1
' 2>/dev/null || true
kcli '
    printf "%s\n" \
      "U1:{\"name\":\"Alice Adams\",\"email\":\"alice@example.com\",\"city\":\"Vienna\"}" \
      "U2:{\"name\":\"Bruno Berger\",\"email\":\"bruno@example.com\",\"city\":\"Graz\"}" \
      "U3:{\"name\":\"Carla Conti\",\"email\":\"carla@example.com\",\"city\":\"Linz\"}" \
      "U2:{\"name\":\"Bruno Berger\",\"email\":\"bruno.berger@example.com\",\"city\":\"Graz\"}" \
    | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic customers \
        --property parse.key=true --property key.separator=:
    for u in U1 U2 U3; do for i in 1 2 3; do echo "$u:{\"order\":\"$u-$i\",\"amount\":$((i*10))}"; done; done \
    | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders \
        --property parse.key=true --property key.separator=:
'
print_info "customers: U1, U2 (two versions), U3 — orders: 3 per customer"
print_success "Personal data produced (Bruno = U2 will ask to be forgotten)"

print_step 3 "Enterprise backup — taken BEFORE the erasure request..."
kbe backup --config /config/backup-gdpr-demo.yaml
print_success "Backup 'gdpr-demo' complete (it still contains U2's data — that is the problem)"

print_step 4 "Art. 17 request arrives for U2 — recording it in the erasure list..."
mkdir -p data/gdpr
cat > data/gdpr/suppressed-keys.txt <<'KEYS'
# Erasure register — one record key per line. Lines starting with # are ignored.
# Request 2026-09-01: data subject U2 (Bruno Berger) — right to erasure, Art. 17 GDPR
U2
KEYS
KEYS_SHA=$( (shasum -a 256 data/gdpr/suppressed-keys.txt 2>/dev/null || sha256sum data/gdpr/suppressed-keys.txt) | cut -d' ' -f1)
print_info "Erasure list SHA-256: $KEYS_SHA"
print_info "This digest must reappear in every restore that applied the list — it is the audit anchor."
print_success "Erasure list written to data/gdpr/suppressed-keys.txt"

print_step 5 "Restore 'customers' with the list re-applied (on_match: tombstone)..."
OUT=$(kbe restore --config /config/restore-gdpr-erasure.yaml 2>&1 | tee /dev/stderr) || fail "restore failed"
echo "$OUT" | grep -q "Records suppressed: 2 (0 dropped, 2 tombstoned" || fail "expected 'Records suppressed: 2 (0 dropped, 2 tombstoned' in the restore output"
echo "$OUT" | grep -q "sha256=$KEYS_SHA" || fail "restore output did not report the erasure list digest $KEYS_SHA"
RESTORED=$(consume customers-restored)
echo "$RESTORED"
[ "$(echo "$RESTORED" | grep -c '^U2:null$')" -eq 2 ] || fail "expected both U2 records to be tombstones (U2:null)"
[ "$(echo "$RESTORED" | grep -c '^U2:{')" -eq 0 ]    || fail "a U2 value leaked into customers-restored"
[ "$(echo "$RESTORED" | grep -c '^U1:{')" -eq 1 ]    || fail "U1 should be restored intact"
[ "$(echo "$RESTORED" | grep -c '^U3:{')" -eq 1 ]    || fail "U3 should be restored intact"
print_info "U2's records came back as tombstones (key kept, value null); compaction will remove them entirely."
print_success "Erasure re-applied on restore: U2's PII never reached customers-restored"

print_step 6 "Restore 'orders' with the list re-applied (on_match: drop)..."
OUT=$(kbe restore --config /config/restore-gdpr-orders.yaml 2>&1 | tee /dev/stderr) || fail "restore failed"
echo "$OUT" | grep -q "Records suppressed: 3 (3 dropped, 0 tombstoned" || fail "expected 'Records suppressed: 3 (3 dropped, 0 tombstoned'"
RESTORED=$(consume orders-restored)
echo "$RESTORED"
[ "$(echo "$RESTORED" | grep -c '^U2:')" -eq 0 ] || fail "U2 orders leaked into orders-restored"
[ "$(echo "$RESTORED" | grep -c '^U1:')" -eq 3 ] || fail "expected 3 U1 orders"
[ "$(echo "$RESTORED" | grep -c '^U3:')" -eq 3 ] || fail "expected 3 U3 orders"
print_success "U2's orders were dropped; U1/U3 restored in full (6 of 9 records)"

print_step 7 "Fail-loud: the erasure list is configured but MISSING..."
if kbe restore --config /config/restore-gdpr-missing-keys.yaml 2>&1 | tee /tmp/gdpr-failloud.log; then
    fail "restore should have been refused"
fi
grep -q "Suppression keys file not found" /tmp/gdpr-failloud.log || fail "expected 'Suppression keys file not found'"
[ "$(kcli 'kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --list 2>/dev/null' | grep -c '^customers-failloud$')" -eq 0 ] \
    || fail "customers-failloud was created — the refusal came too late"
print_info "Exit code non-zero, no topic created: nothing was restored without the list."
print_success "An unreadable erasure list refuses the restore — it never silently proceeds"

print_step 8 "Licence gate: the same restore with the auto-trial disabled and no licence..."
if docker compose --profile enterprise run --rm -e KAFKA_BACKUP_NO_TRIAL=1 kafka-backup-enterprise \
     restore --config /config/restore-gdpr-erasure.yaml 2>&1 | tee /tmp/gdpr-unlicensed.log; then
    fail "restore should have been refused without a licence"
fi
grep -q "Feature 'erasure' is not licensed" /tmp/gdpr-unlicensed.log || fail "expected \"Feature 'erasure' is not licensed\""
print_info "Compare with step 5, which ran under the 14-day auto-trial (all enterprise features)."
print_success "Unlicensed erasure config is refused loudly — never degraded to a plain restore"

print_step 9 "validate-restore shows what WOULD be applied (dry run, no records evaluated)..."
kbe validate-restore --config /config/restore-gdpr-erasure.yaml 2>/dev/null | sed -n '/Restore Validation/,$p'
print_success "The suppression summary (entries, SHA-256, match, on_match, topics) is part of validation"

echo "================================================"
echo "   Demo complete."
echo "   Key takeaways:"
echo "   - backups taken before an erasure still hold the data; erasure is"
echo "     re-applied at restore time (tombstone for compacted, drop for plain)"
echo "   - the list's SHA-256 and the suppressed counts are in the restore output"
echo "   - missing list  -> restore refused (exit != 0), nothing touched"
echo "   - no licence    -> restore refused (exit != 0), nothing touched"
echo "   - erasure list digest applied: $KEYS_SHA"
echo "================================================"
