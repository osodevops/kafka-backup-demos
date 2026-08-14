#!/bin/bash
# Scenario 1: Rebuild-from-inputs (Strategy A - the gold standard)
#
# Proves: a stateful Kafka Streams app (windowed join over two input topics +
# repartitioned aggregation) restored from an input-topic backup and fully
# reprocessed converges to state IDENTICAL to the pre-disaster state.
#
# Flow: run app -> deterministic data -> quiesce -> snapshot backup of inputs
#       -> disaster (topics + state wiped) -> restore inputs -> verify record
#       timestamps preserved -> kafka-streams-application-reset -> restart ->
#       reprocess -> prove identical join results, aggregates and store state.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "================================================"
echo "   Scenario 1: Rebuild From Inputs"
echo "================================================"
echo ""

print_step 1 "Checking Docker services and building the app..."
require_services
build_app

print_step 2 "Resetting the demo environment..."
reset_environment

print_step 3 "Starting the Streams application..."
start_app
wait_for_running
assert_internal_topics

print_step 4 "Producing deterministic order/payment data..."
BASE_TS=$(( ( $(date +%s) - 1800 ) * 1000 ))
mkdir -p "$EVIDENCE_DIR"
echo "$BASE_TS" > "$EVIDENCE_DIR/timestamp-base.txt"
print_info "Timestamp base: $BASE_TS (saved to evidence/timestamp-base.txt)"
generate_batch "$BASE_TS"

print_step 5 "Draining and capturing the EXPECTED state..."
wait_for_zero_lag
capture_evidence "expected"

JOINED=$(counter expected joined)
if [ "$JOINED" != "86" ]; then
    print_error "Sanity check failed: expected 86 joined records, got $JOINED"
    exit 1
fi
print_success "Sanity check: 86 joined (14 late payments correctly outside the join window)"

print_step 6 "Quiescing the application (the consistent-cut requirement)..."
quiesce

print_step 7 "Snapshot backup of the input topics..."
kbackup backup --config /config/backup-streams-inputs.yaml
kbackup_s3 validate --path s3://kafka-backups/streams-join-demo/inputs --backup-id streams-join-inputs
print_success "Backup completed and validated"

print_step 8 "DISASTER: deleting all topics and local state..."
kcli "
    for t in $INPUT_TOPICS $OUTPUT_TOPICS $INTERNAL_TOPICS; do
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic \$t 2>/dev/null || true
    done
"
wipe_state_volume
print_success "Topics and local RocksDB state destroyed"

print_step 9 "Restoring input topics from backup..."
recreate_external_topics
kbackup restore --config /config/restore-streams-inputs.yaml
print_success "Input topics restored"

print_step 10 "Verifying record timestamps survived the restore..."
# Windowed join semantics depend on record time. The generator sets explicit
# CreateTime timestamps, so restored dumps must be byte-identical.
mkdir -p "$EVIDENCE_DIR/post-restore"
dump_topic_with_timestamps "orders"   > "$EVIDENCE_DIR/post-restore/orders_ts.txt"
dump_topic_with_timestamps "payments" > "$EVIDENCE_DIR/post-restore/payments_ts.txt"
if ! diff -q "$EVIDENCE_DIR/expected/orders_ts.txt" "$EVIDENCE_DIR/post-restore/orders_ts.txt" >/dev/null 2>&1; then
    print_error "PRODUCT FINDING: restore did not preserve record timestamps."
    print_error "Windowed join replay would NOT be equivalent. Aborting."
    diff -u "$EVIDENCE_DIR/expected/orders_ts.txt" "$EVIDENCE_DIR/post-restore/orders_ts.txt" | head -10 || true
    exit 1
fi
assert_files_equal "$EVIDENCE_DIR/expected/payments_ts.txt" "$EVIDENCE_DIR/post-restore/payments_ts.txt" \
    "payment record timestamps preserved through backup/restore"
print_success "CreateTime timestamps preserved - windowed join replay is equivalent"

print_step 11 "Resetting the Streams application (offsets + internal topics)..."
kcli "kafka-streams-application-reset --bootstrap-server kafka-broker-1:9092 \
    --application-id $APP_ID --input-topics orders,payments --force" || true
print_success "Application reset complete (local state was already wiped with the volume)"

print_step 12 "Restarting the app - full reprocessing from restored inputs..."
start_app
wait_for_running
wait_for_zero_lag
capture_evidence "actual"
quiesce

print_step 13 "Verifying rebuilt state is IDENTICAL to pre-disaster state..."
assert_files_equal "$EVIDENCE_DIR/expected/join_output.txt"  "$EVIDENCE_DIR/actual/join_output.txt"  "join results (orders_with_payments)"
assert_files_equal "$EVIDENCE_DIR/expected/revenue_final.txt" "$EVIDENCE_DIR/actual/revenue_final.txt" "final aggregates per customer (customer_revenue)"
assert_files_equal "$EVIDENCE_DIR/expected/state.json"        "$EVIDENCE_DIR/actual/state.json"        "state store contents (customer-revenue-store)"

JOINED_ACTUAL=$(counter actual joined)
if [ "$JOINED_ACTUAL" != "86" ]; then
    print_error "Sanity check failed: rebuild produced $JOINED_ACTUAL joins, expected 86"
    exit 1
fi

DEMO_RESULT="PASS"

echo ""
echo "================================================"
echo "   Scenario 1 Complete"
echo "================================================"
print_info "What was demonstrated:"
echo "  1. A quiesced snapshot backup of only the INPUT topics is sufficient"
echo "     to recover a stateful Streams app with joins and aggregations"
echo "  2. kafka-backup preserves record timestamps (CreateTime), so windowed"
echo "     join replay is semantically equivalent"
echo "  3. kafka-streams-application-reset + clean state dir + restart"
echo "     rebuilds ALL state (join windows, aggregates, RocksDB) to values"
echo "     IDENTICAL to pre-disaster"
echo ""
print_info "Key takeaway: state stores are derived data - restore the inputs,"
print_info "reset the app, and the state converges deterministically."
