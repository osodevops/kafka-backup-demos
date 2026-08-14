#!/bin/bash
# Scenario 2: Changelog fast-restore (Strategy B - no reprocessing)
#
# Proves: a stateful Kafka Streams app can be restored WITHOUT reprocessing
# its input history, by restoring the complete quiesced topic set (inputs +
# changelogs + repartition + outputs) and re-anchoring the committed consumer
# offsets via header-based offset mapping. State stores rebuild from the
# restored changelogs; the inputs are never re-read.
#
# The smoking gun: after restart, consumed_orders == 0 and
# restored_changelog_records > 0, while the state store contents are
# IDENTICAL to pre-disaster.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "================================================"
echo "   Scenario 2: Changelog Fast-Restore"
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
generate_batch "$BASE_TS"

print_step 5 "Draining and capturing the EXPECTED state..."
wait_for_zero_lag
capture_evidence "expected"
JOINED=$(counter expected joined)
if [ "$JOINED" != "86" ]; then
    print_error "Sanity check failed: expected 86 joined records, got $JOINED"
    exit 1
fi

print_step 6 "Quiescing the application (single consistent cut for ALL topics)..."
quiesce

print_step 7 "Full backup: inputs + changelogs + repartition + outputs + offsets..."
kbackup backup --config /config/backup-streams-full.yaml
kbackup_snap offset-rollback snapshot --path /snapshots \
    --groups $APP_ID --bootstrap-servers kafka-broker-1:9092 \
    --description "Quiesced snapshot for changelog fast-restore"
SNAPSHOT_ID=$(kbackup_snap offset-rollback list --path /snapshots --format text 2>/dev/null \
    | grep -o 'snap-[a-z0-9-]*' | head -1)
if [ -z "$SNAPSHOT_ID" ]; then
    print_error "Could not determine offset snapshot id"
    exit 1
fi
echo "$SNAPSHOT_ID" > "$EVIDENCE_DIR/snapshot-id.txt"
print_info "Offset snapshot: $SNAPSHOT_ID"
kbackup_s3 describe --path s3://kafka-backups/streams-join-demo/full --backup-id streams-join-full \
    --format json 2>/dev/null | json_only > "$EVIDENCE_DIR/backup-manifest.json" || true
print_success "Full backup completed (see evidence/backup-manifest.json)"

print_step 8 "DISASTER: deleting ALL topics, consumer group and local state..."
kcli "
    for t in $INPUT_TOPICS $OUTPUT_TOPICS $INTERNAL_TOPICS; do
        kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic \$t 2>/dev/null || true
    done
"
delete_consumer_group
wipe_state_volume
print_success "Everything destroyed - topics, committed offsets, local RocksDB"

print_step 9 "Recreating topics with Streams-compatible configs..."
recreate_external_topics
recreate_internal_topics

print_step 10 "Restoring ALL topics, then re-anchoring committed offsets..."
kbackup restore --config /config/restore-streams-full.yaml
# The restored input topics are byte-identical from offset 0, so the committed
# offsets captured at quiesce time are valid absolute positions again. (The
# repartition topic restores empty - Streams had already purged its consumed
# records - so its old committed offset lands out-of-range and harmlessly
# resets to earliest: that data already lives in the restored changelogs.)
kbackup_snap offset-rollback rollback --path /snapshots \
    --snapshot-id "$(cat "$EVIDENCE_DIR/snapshot-id.txt")" \
    --bootstrap-servers kafka-broker-1:9092
print_success "Topics restored and consumer group offsets rolled back to the quiesced snapshot"

print_step 11 "Verifying committed offsets were re-anchored..."
kcli "kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 --describe --group $APP_ID 2>/dev/null" \
    | awk 'NR>1 && $2 != "" {print $2, $3, $4}' | sort > "$EVIDENCE_DIR/restored_group_offsets.txt"
assert_files_equal "$EVIDENCE_DIR/expected/group_offsets.txt" "$EVIDENCE_DIR/restored_group_offsets.txt" \
    "committed consumer group offsets (restored = pre-disaster)"

print_step 12 "Restarting the app with a CLEAN state dir and NO application reset..."
# Clean state dir is critical: no stale .checkpoint files, so Streams rebuilds
# every store by scanning the restored changelogs start-to-end. That full scan
# is exactly why shifted changelog offsets are safe to restore.
start_app
wait_for_running

LAG=$(total_lag)
if [ "$LAG" != "0" ]; then
    print_error "Expected zero lag after offset restore (nothing to reprocess), got $LAG"
    exit 1
fi
print_success "Consumer lag is 0 immediately - no input reprocessing required"

sleep 5
capture_evidence "actual"

print_step 13 "Verifying state was rebuilt from CHANGELOGS, not from inputs..."
assert_files_equal "$EVIDENCE_DIR/expected/state.json" "$EVIDENCE_DIR/actual/state.json" \
    "state store contents (customer-revenue-store)"
assert_files_equal "$EVIDENCE_DIR/expected/revenue_final.txt" "$EVIDENCE_DIR/actual/revenue_final.txt" \
    "final aggregates per customer"
assert_files_equal "$EVIDENCE_DIR/expected/join_output.txt" "$EVIDENCE_DIR/actual/join_output.txt" \
    "join output topic (restored, not re-emitted)"

CONSUMED_ORDERS=$(counter actual consumed_orders)
CONSUMED_PAYMENTS=$(counter actual consumed_payments)
RESTORED=$(counter actual restored_changelog_records)
print_info "consumed_orders=$CONSUMED_ORDERS consumed_payments=$CONSUMED_PAYMENTS restored_changelog_records=$RESTORED"
if [ "$CONSUMED_ORDERS" != "0" ] || [ "$CONSUMED_PAYMENTS" != "0" ]; then
    print_error "App reprocessed input records - this was supposed to be a changelog-only restore"
    exit 1
fi
if [ "$RESTORED" -le 0 ]; then
    print_error "No changelog records were restored into the state stores"
    exit 1
fi
print_success "State rebuilt from $RESTORED changelog records with ZERO input records reprocessed"

print_step 14 "Bonus: proving the restored app is live and consistent..."
NOW_TS=$(( $(date +%s) * 1000 ))
kcli "
    printf '%s\n' \
      'ORD-B001:{\"type\":\"order\",\"order_id\":\"ORD-B001\",\"customer_id\":\"CUST-BONUS\",\"amount\":100,\"event_time\":$NOW_TS}' \
      'ORD-B002:{\"type\":\"order\",\"order_id\":\"ORD-B002\",\"customer_id\":\"CUST-BONUS\",\"amount\":200,\"event_time\":$NOW_TS}' \
    | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders \
        --property parse.key=true --property key.separator=: 2>/dev/null
    printf '%s\n' \
      'ORD-B001:{\"type\":\"payment\",\"payment_id\":\"PAY-B001\",\"order_id\":\"ORD-B001\",\"amount\":100,\"event_time\":$(( NOW_TS + 30000 ))}' \
      'ORD-B002:{\"type\":\"payment\",\"payment_id\":\"PAY-B002\",\"order_id\":\"ORD-B002\",\"amount\":200,\"event_time\":$(( NOW_TS + 30000 ))}' \
    | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments \
        --property parse.key=true --property key.separator=: 2>/dev/null
"
wait_for_zero_lag 60
sleep 3
BONUS=$(curl -sf "$HTTP/state" | jq -r '.["CUST-BONUS"].total_revenue // 0')
if [ "$BONUS" != "300" ]; then
    print_error "New events not aggregated correctly on top of restored state (CUST-BONUS revenue=$BONUS, expected 300)"
    exit 1
fi
print_success "New events aggregate correctly on top of restored state (CUST-BONUS revenue=300)"
quiesce

DEMO_RESULT="PASS"

echo ""
echo "================================================"
echo "   Scenario 2 Complete"
echo "================================================"
print_info "What was demonstrated:"
echo "  1. A quiesced single-pass backup of inputs + changelogs + repartition"
echo "     + committed offsets is a CONSISTENT recovery point"
echo "  2. Header-based offset mapping re-anchors the consumer group even"
echo "     though restored topics have different offsets"
echo "  3. The app rebuilds state stores from restored changelogs WITHOUT"
echo "     reprocessing any input history (RTO independent of retention)"
echo "  4. The restored app continues processing new events correctly"
echo ""
print_info "Key takeaway: changelog restore is the fast-recovery path - valid"
print_info "ONLY when everything was captured in one quiesced pass."
