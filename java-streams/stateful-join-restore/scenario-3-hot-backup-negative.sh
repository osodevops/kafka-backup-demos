#!/bin/bash
# Scenario 3: Hot (non-quiesced) backup - the NEGATIVE demo
#
# Proves: a backup of a RUNNING stateful Streams app is NOT a consistent
# recovery point. Kafka has no cross-topic global snapshot primitive, so a hot
# backup captures orders, payments, changelogs and committed offsets at
# DIFFERENT logical moments. Restoring it produces measurably wrong state.
#
# This scenario PASSES when the anomaly is demonstrated: the restored state
# DIFFERS from the true final state, with the deltas quantified.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "================================================"
echo "   Scenario 3: Hot Backup Inconsistency (Negative Demo)"
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

print_step 4 "Starting the LIVE generator (orders lead payments by 5s)..."
BASE_TS=$(( ( $(date +%s) - 1800 ) * 1000 ))
mkdir -p "$EVIDENCE_DIR"
echo "$BASE_TS" > "$EVIDENCE_DIR/timestamp-base.txt"
start_live_generator "$BASE_TS"
print_info "Letting the pipeline run hot for 30 seconds..."
sleep 30

print_step 5 "Taking a HOT backup while app and producers are RUNNING..."
kbackup backup --config /config/backup-streams-hot.yaml
# Offset snapshot taken mid-flight too - following the same (otherwise
# correct) procedure as scenario 2. The procedure is fine; the hot cut isn't.
kbackup_snap offset-rollback snapshot --path /snapshots \
    --groups $APP_ID --bootstrap-servers kafka-broker-1:9092 \
    --description "Mid-flight snapshot during hot backup"
SNAPSHOT_ID=$(kbackup_snap offset-rollback list --path /snapshots --format text 2>/dev/null \
    | grep -o 'snap-[a-z0-9-]*' | head -1)
if [ -z "$SNAPSHOT_ID" ]; then
    print_error "Could not determine offset snapshot id"
    exit 1
fi
echo "$SNAPSHOT_ID" > "$EVIDENCE_DIR/snapshot-id.txt"
print_success "Hot backup completed (this is the mistake being demonstrated)"

print_step 6 "Analyzing the inconsistent cut..."
kbackup_s3 describe --path s3://kafka-backups/streams-join-demo/hot --backup-id streams-join-hot \
    --format json 2>/dev/null | json_only > "$EVIDENCE_DIR/hot-backup-manifest.json"
ORDERS_IN_BACKUP=$(jq '[.topics[] | select(.name=="orders") | .partitions[].segments[].record_count] | add // 0' "$EVIDENCE_DIR/hot-backup-manifest.json")
PAYMENTS_IN_BACKUP=$(jq '[.topics[] | select(.name=="payments") | .partitions[].segments[].record_count] | add // 0' "$EVIDENCE_DIR/hot-backup-manifest.json")
JOINS_IN_BACKUP=$(jq '[.topics[] | select(.name=="orders_with_payments") | .partitions[].segments[].record_count] | add // 0' "$EVIDENCE_DIR/hot-backup-manifest.json")

{
    echo "Hot backup cut analysis ($(date))"
    echo "-------------------------------------------"
    echo "orders records captured:               $ORDERS_IN_BACKUP"
    echo "payments records captured:             $PAYMENTS_IN_BACKUP"
    echo "orders_with_payments records captured: $JOINS_IN_BACKUP"
    echo ""
    echo "orders ahead of payments by:           $(( ORDERS_IN_BACKUP - PAYMENTS_IN_BACKUP )) records"
    echo ""
    echo "Each topic was cut at ITS OWN moment - there is no single point in"
    echo "time this backup represents. Orders exist whose payments were never"
    echo "captured; changelog state and committed offsets were captured at"
    echo "yet other moments."
} > "$EVIDENCE_DIR/hot-cut-analysis.txt"
cat "$EVIDENCE_DIR/hot-cut-analysis.txt"
echo ""

if [ "$(( ORDERS_IN_BACKUP - PAYMENTS_IN_BACKUP ))" -le 0 ]; then
    print_error "The hot cut happened to catch orders/payments in sync - rerun the"
    print_error "scenario (the generator skew window was missed)."
    exit 1
fi
print_success "Inconsistent cut confirmed: orders captured ahead of payments"

print_step 7 "Capturing the TRUE final state (generator stopped, app drained)..."
print_info "Letting the pipeline continue past the backup cut for 15 seconds -"
print_info "payments for orders already inside the backup arrive AFTER the cut,"
print_info "orphaning those orders forever in the restored world"
sleep 15
stop_live_generator
wait_for_zero_lag
capture_evidence "truth"
quiesce

print_step 8 "DISASTER: deleting ALL topics, consumer group and local state..."
kcli "
    for t in $INPUT_TOPICS $OUTPUT_TOPICS $INTERNAL_TOPICS; do
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic \$t 2>/dev/null || true
    done
"
delete_consumer_group
wipe_state_volume
print_success "Everything destroyed"

print_step 9 "Restoring the HOT backup with the same procedure as scenario 2..."
recreate_external_topics
recreate_internal_topics
kbackup restore --config /config/restore-streams-hot.yaml
kbackup_snap offset-rollback rollback --path /snapshots \
    --snapshot-id "$(cat "$EVIDENCE_DIR/snapshot-id.txt")" \
    --bootstrap-servers kafka-broker-1:9092
start_app
wait_for_running
wait_for_zero_lag
sleep 5
capture_evidence "actual"
quiesce

print_step 10 "Comparing restored state against the true final state..."
TRUTH_JOINS=$(wc -l < "$EVIDENCE_DIR/truth/join_output.txt" | tr -d ' ')
ACTUAL_JOINS_RAW=$(wc -l < "$EVIDENCE_DIR/actual/join_output.txt" | tr -d ' ')
ACTUAL_JOINS_UNIQUE=$(sort -u "$EVIDENCE_DIR/actual/join_output.txt" | wc -l | tr -d ' ')
DUPLICATES=$(( ACTUAL_JOINS_RAW - ACTUAL_JOINS_UNIQUE ))
TRUTH_REVENUE=$(jq '[.[] | .total_revenue] | add // 0' "$EVIDENCE_DIR/truth/state.json")
ACTUAL_REVENUE=$(jq '[.[] | .total_revenue] | add // 0' "$EVIDENCE_DIR/actual/state.json")
TRUTH_MATCHED=$(jq '[.[] | .matched_orders] | add // 0' "$EVIDENCE_DIR/truth/state.json")
ACTUAL_MATCHED=$(jq '[.[] | .matched_orders] | add // 0' "$EVIDENCE_DIR/actual/state.json")

STATE_DIFFERS="no"
if ! diff -q "$EVIDENCE_DIR/truth/state.json" "$EVIDENCE_DIR/actual/state.json" >/dev/null 2>&1; then
    STATE_DIFFERS="yes"
fi

{
    echo "Quantified anomaly (true final state vs hot-backup restore)"
    echo "------------------------------------------------------------"
    printf "%-34s %12s %12s %10s\n" "metric" "truth" "restored" "delta"
    printf "%-34s %12s %12s %10s\n" "join results (raw lines)" "$TRUTH_JOINS" "$ACTUAL_JOINS_RAW" "$(( TRUTH_JOINS - ACTUAL_JOINS_RAW ))"
    printf "%-34s %12s %12s %10s\n" "join results (unique)" "$TRUTH_JOINS" "$ACTUAL_JOINS_UNIQUE" "$(( TRUTH_JOINS - ACTUAL_JOINS_UNIQUE ))"
    printf "%-34s %12s %12s %10s\n" "total revenue" "$TRUTH_REVENUE" "$ACTUAL_REVENUE" "$(( TRUTH_REVENUE - ACTUAL_REVENUE ))"
    printf "%-34s %12s %12s %10s\n" "matched orders" "$TRUTH_MATCHED" "$ACTUAL_MATCHED" "$(( TRUTH_MATCHED - ACTUAL_MATCHED ))"
    echo ""
    echo "duplicate join emissions at the restore seam: $DUPLICATES"
    echo "orders captured without their payments:       $(( ORDERS_IN_BACKUP - PAYMENTS_IN_BACKUP ))"
    echo "state store differs from true final state:    $STATE_DIFFERS"
} > "$EVIDENCE_DIR/anomaly-report.txt"
cat "$EVIDENCE_DIR/anomaly-report.txt"
echo ""

# The scenario PASSES when inconsistency is demonstrated. Which anomaly
# materializes depends on where each topic's cut landed relative to the
# commit cycle, so accept any of the definitive signals:
ANOMALY="no"
if [ "$DUPLICATES" -gt 0 ]; then
    print_success "ANOMALY: $DUPLICATES duplicate join results in the restored output topic"
    ANOMALY="yes"
fi
if [ "$STATE_DIFFERS" = "yes" ]; then
    print_success "ANOMALY: restored state store differs from the true final state"
    ANOMALY="yes"
fi
if [ "$ACTUAL_JOINS_UNIQUE" -lt "$TRUTH_JOINS" ]; then
    print_success "ANOMALY: $(( TRUTH_JOINS - ACTUAL_JOINS_UNIQUE )) join results missing (orders orphaned by the cut)"
    ANOMALY="yes"
fi
if [ "$ANOMALY" != "yes" ]; then
    print_error "No inconsistency demonstrated - the hot cut happened to land clean."
    print_error "Rerun the scenario (the generator skew window was missed)."
    exit 1
fi

DEMO_RESULT="PASS"

echo ""
echo "================================================"
echo "   Scenario 3 Complete (anomaly demonstrated)"
echo "================================================"
print_info "What was demonstrated:"
echo "  1. Kafka has NO cross-topic snapshot primitive: a hot backup cuts"
echo "     each topic at its own moment"
echo "  2. Orders were captured whose payments never made the backup -"
echo "     their joins and revenue are permanently missing after restore"
echo "  3. Changelog state and committed offsets represent yet other moments,"
echo "     so restored state disagrees with restored inputs"
echo ""
print_info "Key takeaway: stateful Streams DR backups MUST be taken quiesced."
print_info "A hot backup of joined topics + offsets is not a consistent cut."
