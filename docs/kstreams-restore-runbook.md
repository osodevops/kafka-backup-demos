# Kafka Streams Backup & Restore: Capability Guide and Runbook

A practical guide to what is — and is not — possible when backing up and
restoring **stateful Kafka Streams applications** (joins, aggregations, state
stores) with [OSO Kafka Backup](https://github.com/osodevops/kafka-backup).

Every claim in this document is backed by a runnable demo in
[`java-streams/stateful-join-restore/`](../java-streams/stateful-join-restore/instructions.md),
using a deliberately non-trivial topology: two joined input topics, a windowed
stream-stream join, a re-keyed (repartitioned) aggregation, RocksDB state
stores, and four Kafka Streams internal topics.

## Executive summary

Kafka Streams state stores are **derived data**: they are projections of the
input topics and are continuously mirrored to changelog topics. That is what
makes restore possible — and it dictates the two valid recovery strategies:

- **Strategy A — Rebuild from inputs** (simplest, always correct): restore the
  input topics, reset the application, reprocess. State converges to values
  identical to pre-disaster. Recovery time grows with input history.
- **Strategy B — Changelog fast-restore** (fast, more moving parts): restore
  inputs + changelog topics + committed consumer offsets from one quiesced
  backup pass. State stores rebuild directly from the changelogs with **zero
  input reprocessing**. Recovery time is independent of input retention.

The one non-negotiable operational requirement for stateful restore points:
**quiesce the application before the backup**. Kafka has no cross-topic
snapshot primitive, so a backup of a running stateful pipeline is not a
consistent cut — demo scenario 3 shows exactly how that fails.

## Capability matrix

| Capability | Verdict | Evidence |
|---|---|---|
| Rebuild a stateful app (joins + aggregations) from restored input topics, with state identical to pre-disaster | **Possible** | Scenario 1: join results, per-customer aggregates and RocksDB store contents byte-identical after disaster + rebuild |
| Record timestamps (CreateTime) preserved through backup/restore, so windowed join replay is semantically equivalent | **Possible** (verified) | Scenario 1 step 10: timestamped topic dumps before/after restore are byte-identical |
| Fast recovery via changelog restore, without reprocessing input history | **Possible with caveats** | Scenario 2: state rebuilt from 286 restored changelog records with 0 input records reprocessed; requires the caveats below |
| Restore committed consumer group offsets alongside topics | **Possible with caveats** | Scenario 2: `offset-rollback snapshot` at backup time + `offset-rollback rollback` after restore, with built-in verification |
| Consistent backup of a **running** stateful Streams pipeline | **Not possible** | Scenario 3: each topic is cut at its own moment — quantified result: duplicate join emissions, orders orphaned without their payments, aggregates diverging from the true state |
| Exactly-once (EOS) guarantees surviving a restore | **Not possible** | Transactional markers and producer epochs are cluster-local; the restore boundary is at-least-once. Design downstream consumers to be idempotent |
| Undoing effects already consumed downstream | **Not possible** | Restoring topics does not un-consume data that external systems already read; plan restore scope per pipeline, not per topic |
| Backing up local RocksDB state directories | **Not needed (by design)** | The changelog topics are the durable source of truth; local state is a disposable cache rebuilt on restart |

### Caveats for Strategy B (changelog fast-restore)

1. **Single quiesced pass.** Inputs, changelogs, repartition topics and the
   offset snapshot must be captured together while the app is stopped.
   Anything else re-introduces the scenario-3 inconsistency.
2. **Clean state directories.** Always delete local state before restarting
   into restored changelogs. Stale `.checkpoint` files reference the old
   offset space; a clean state dir forces a full changelog scan, which is
   exactly why shifted changelog offsets are safe.
3. **Literal internal topic names.** Backup configs enumerate topics by name.
   Pin your store names in code (`Materialized.as`, `StreamJoined.withStoreName`,
   `Grouped.as`) so internal topic names are stable, and verify with
   `kafka-topics.sh --list | grep '^<application.id>-'` (the demo scripts
   assert this automatically).
4. **Repartition topics restore empty — that is correct.** Kafka Streams
   actively purges repartition records after processing them. Their content
   already lives in the changelogs; a stale committed offset on an empty
   restored repartition topic simply resets to earliest harmlessly.
5. **Offset restore validity.** Rolling back committed offsets to their
   absolute pre-disaster values is valid when the restored input topics are
   byte-identical from offset 0 (the normal full-restore case). If your source
   topics had a non-zero log start (retention/compaction had already trimmed
   them), use the offset mapping produced by the restore (`show-offset-mapping`,
   `offset-reset plan`) instead of absolute values.

## Choosing a strategy

```
Is the state store corrupted by a logic bug (bad deploy, poison data)?
├─ YES -> Strategy A (rebuild). Optionally PITR-filter the inputs to
│         cut the poison data out of history first.
└─ NO: infrastructure loss / cluster rebuild / migration
   ├─ Input retention still covers full history AND
   │  reprocessing time fits your RTO?         -> Strategy A (simpler)
   └─ Large state, tight RTO, or inputs already
      trimmed by retention?                    -> Strategy B (fast-restore)
```

Rule of thumb: **drill Strategy A first** — it is the recovery path with the
fewest assumptions. Add Strategy B where measured reprocessing time exceeds
your RTO.

## Runbook A — Rebuild from inputs

*Demo: `java-streams/stateful-join-restore/scenario-1-rebuild.sh`*

1. **Quiesce.** Wait for consumer lag 0 on all input and repartition topics,
   then stop every application instance cleanly.
   ```bash
   kafka-consumer-groups.sh --bootstrap-server <broker> --describe --group <app-id>
   ```
2. **Snapshot backup of the input topics.**
   ```yaml
   backup:
     stop_at_current_offsets: true   # snapshot mode: capture HWMs, exit when caught up
     include_offset_headers: true
   ```
   ```bash
   kafka-backup backup --config backup-inputs.yaml
   kafka-backup validate --path <storage-path> --backup-id <id>
   ```
3. **(Disaster happens.)**
4. **Recreate topics and restore the inputs.**
   ```bash
   kafka-backup restore --config restore-inputs.yaml
   ```
5. **Verify timestamps** (spot-check — kafka-backup preserves CreateTime):
   ```bash
   kafka-console-consumer.sh ... --property print.timestamp=true --max-messages 5
   ```
6. **Reset the application.**
   ```bash
   kafka-streams-application-reset --bootstrap-server <broker> \
       --application-id <app-id> --input-topics <t1>,<t2> --force
   ```
   This resets input offsets to earliest and deletes internal topics. It does
   **not** delete local state:
   ```bash
   rm -rf <state.dir>   # on every instance
   ```
7. **Restart and drain.** The app reprocesses the restored inputs and rebuilds
   all state. Verify aggregates/outputs against pre-disaster evidence.

**Expected result** (proven by scenario 1): join results, aggregates and state
store contents identical to pre-disaster. Only wall-clock-derived fields (e.g.
`processed_at` enrichment) will differ — keep such fields out of any
correctness comparison, and out of business-critical state.

## Runbook B — Changelog fast-restore

*Demo: `java-streams/stateful-join-restore/scenario-2-changelog-restore.sh`*

1. **Enumerate the app's internal topics** and put them in the backup config:
   ```bash
   kafka-topics.sh --bootstrap-server <broker> --list | grep "^<app-id>-"
   ```
2. **Quiesce** (as in Runbook A).
3. **One backup pass for everything** — inputs, changelogs, repartition
   topics, output topics — plus an offset snapshot:
   ```bash
   kafka-backup backup --config backup-full.yaml
   kafka-backup offset-rollback snapshot --path <snapshot-path> \
       --groups <app-id> --bootstrap-servers <broker> --description "quiesced DR point"
   ```
4. **(Disaster happens.)**
5. **Recreate topics with Streams-compatible configs** (compacted changelogs
   for key-value stores, retention-based for windowed stores — copy the
   configs from a healthy environment), then restore:
   ```bash
   kafka-backup restore --config restore-full.yaml
   kafka-backup offset-rollback rollback --path <snapshot-path> \
       --snapshot-id <snap-id> --bootstrap-servers <broker>
   ```
6. **Delete local state dirs on every instance** (mandatory — see caveat 2).
7. **Restart without any application reset.** The app rebuilds its stores by
   scanning the restored changelogs and resumes at the restored committed
   offsets — lag is 0 immediately, no input history is re-read.

**Expected result** (proven by scenario 2): state store contents identical,
`consumed_orders == 0`, `restored_changelog_records > 0`, and new events
process correctly on top of the restored state.

## What a backup cannot fix — the sharp edges

*Demo: `java-streams/stateful-join-restore/scenario-3-hot-backup-negative.sh`*

- **No global snapshot of a running pipeline.** A hot backup cuts each
  topic-partition at its own moment. In the demo run: orders were captured 10
  records ahead of payments, producing permanently orphaned orders, 11
  duplicate join emissions at the restore seam, and aggregates diverging from
  the true state by 30 matched orders. The restore *procedure* was identical
  to the working scenario 2 — the hot cut itself is the flaw.
- **The restore boundary is at-least-once.** Even with EOS enabled in the
  app, transactional state does not survive a restore. Expect (and design
  for) duplicates at the seam: idempotent downstream consumers or dedup keys.
- **Replay nondeterminism at the margins.** Reprocessing reproduces windowed
  results when timestamps are preserved, but records at window/grace
  boundaries, wall-clock punctuators and `suppress()` operators can behave
  differently on replay. Keep wall-clock values out of state.
- **Downstream systems.** If corrupted output was already consumed by
  downstream services before the restore, restoring the topics does not undo
  it. Restore scope must be planned end-to-end per pipeline.
- **PITR and joined topics.** Point-in-time filtering applies per topic. For
  a stateful app, PITR-restore the *inputs* and rebuild (Strategy A); do not
  PITR-filter changelogs.

## Backup policy recommendations

1. **Scheduled quiesced snapshots.** Use snapshot mode
   (`stop_at_current_offsets: true`) during a maintenance window or a
   blue/green switchover; the backup bounds itself and exits cleanly (ideal
   for CronJobs).
2. **Validate every backup**: `kafka-backup validate [--deep]` +
   `describe --format json` as audit evidence.
3. **Drill restores regularly.** The three demo scenarios are designed to be
   run as recurring DR drills; each ends with an explicit PASS/FAIL verdict.
4. **Pin store names in application code** so internal topic names never
   change under you during upgrades.
5. **Measure Strategy A reprocessing time** against your RTO now, not during
   an incident — it determines whether you need Strategy B at all.

## Operational notes observed while building the demos

- Stopped Kafka Streams instances remain group members until the session
  timeout expires (Streams intentionally does not leave the group on close).
  Group deletion and offset resets right after a shutdown may need to wait or
  retry; `kafka-streams-application-reset --force` clears lingering members.
- `offset-rollback` in the current CLI version expects a filesystem-style
  path for its snapshot store (mount a shared volume in containerized
  environments); S3 URLs for offset snapshots land on the local filesystem.
- Restore config keys for consumer-group strategies exist in the YAML schema;
  in the tool version used here the reliable offset restore mechanism is the
  `offset-rollback` snapshot/rollback CLI flow (with `--verify`), which is
  what the demos use.
