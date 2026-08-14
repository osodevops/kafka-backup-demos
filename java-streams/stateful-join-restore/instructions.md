# Java Kafka Streams Demo: Stateful Join Restore

**Core Feature:** Backup and restore of a stateful Kafka Streams application
with multiple joined input topics — the three DR strategies, proven end-to-end.

Companion document: [Kafka Streams Restore Runbook](../../docs/kstreams-restore-runbook.md)
(customer-facing capability matrix and runbooks backed by these demos).

## Overview

Most Streams backup demos use stateless or single-topic topologies. Real
services are not like that. This demo uses a deliberately non-trivial topology:

```
orders (key=order_id)  ──┐
                         ├── inner windowed join (10 min window, 5 min grace)
payments (key=order_id)──┘         │
                                   ├──> orders_with_payments
                                   │
                                   └──> groupBy customer_id   [repartition topic]
                                        aggregate revenue     [customer-revenue-store]
                                        └──> customer_revenue
```

Internal topics created by the app (`application.id = stateful-join-demo`):

| Topic | Kind |
|---|---|
| `stateful-join-demo-order-payment-join-this-join-store-changelog` | join window store changelog |
| `stateful-join-demo-order-payment-join-other-join-store-changelog` | join window store changelog |
| `stateful-join-demo-customer-revenue-store-changelog` | aggregate store changelog (compacted) |
| `stateful-join-demo-customer-revenue-repartition` | repartition topic (purged by Streams) |

Store names are pinned in code (`StreamJoined.withStoreName`, `Grouped.as`,
`Materialized.as`) so these names are stable — backup configs must enumerate
internal topics literally, and every scenario asserts the names match before
backing up.

The app exposes verification endpoints on port 7071:

| Endpoint | Purpose |
|---|---|
| `GET /health` | Streams state (scripts wait for `RUNNING`) |
| `GET /state` | Sorted dump of `customer-revenue-store` |
| `GET /counters` | `consumed_orders`, `consumed_payments`, `joined`, `aggregate_updates`, `restored_changelog_records` |

Determinism: every output field is a pure function of the input records (no
wall-clock values), timestamps are explicit `CreateTime` set by the generator,
and the join grace period exceeds the dataset's time span — so a replay of the
same inputs produces identical results, and "expected vs actual" is a plain
`diff`.

## Prerequisites

- Java 17+, Maven 3.6+
- Docker environment running (`docker compose up -d` from the repo root)
- `jq` on the host

## The three scenarios

Each script is self-contained (resets the environment, builds if needed),
writes evidence files to `evidence/`, and ends with an explicit
`RESULT: PASS` / `RESULT: FAIL` and matching exit code.

### Scenario 1 — Rebuild from inputs (Strategy A)

```bash
./scenario-1-rebuild.sh
```

```
[app processes 100 orders + 100 payments -> 86 joins, 14 late payments filtered by the window]
        │
   quiesce ── snapshot backup (inputs only) ── validate
        │
   DISASTER: all topics + internal topics + local RocksDB destroyed
        │
   restore inputs ── verify CreateTime timestamps preserved (byte-identical dumps)
        │
   kafka-streams-application-reset ── restart ── full reprocess
        │
   PROOF: join results, per-customer aggregates and state store contents
          IDENTICAL to pre-disaster
```

### Scenario 2 — Changelog fast-restore (Strategy B)

```bash
./scenario-2-changelog-restore.sh
```

```
[same data, same quiesce]
        │
   ONE backup pass: inputs + 4 internal topics + outputs
   + offset-rollback snapshot of committed group offsets
        │
   DISASTER: everything destroyed (topics, consumer group, local state)
        │
   recreate topics (correct configs) ── restore all 8 topics
   ── offset-rollback rollback (verified)
        │
   restart with CLEAN state dir, NO application reset
        │
   PROOF: lag 0 immediately; state IDENTICAL; consumed_orders == 0;
          restored_changelog_records > 0; new events process correctly
          on top of the restored state
```

### Scenario 3 — Hot backup inconsistency (negative demo)

```bash
./scenario-3-hot-backup-negative.sh
```

```
[app running, live generator: orders lead payments by 5s]
        │
   HOT backup taken mid-flight (nothing quiesced)
   -> cut analysis: orders captured AHEAD of payments
        │
   pipeline continues (true state keeps advancing) ── then stop + drain
   -> capture TRUE final state
        │
   DISASTER ── restore hot backup with the SAME procedure as scenario 2
        │
   PROOF (inverted): restored world is measurably inconsistent -
     duplicate join emissions at the seam, orders orphaned without their
     payments, aggregates diverging from the true state
   -> quantified in evidence/anomaly-report.txt
```

This scenario passes when the anomaly is demonstrated. It is the
expectation-management demo: the restore procedure is identical to the one
that works in scenario 2 — the non-quiesced backup itself is the flaw.

## Evidence files

Each run writes to `evidence/` (gitignored):

| File | Content |
|---|---|
| `expected/`, `actual/`, `truth/` | Per-phase captures: `state.json`, `counters.json`, `join_output.txt` (sorted), `revenue_final.txt` (last value per key), `group_offsets.txt`, timestamped input dumps |
| `backup-manifest.json` | `kafka-backup describe` output (per-partition offsets, timestamps, sizes) |
| `hot-cut-analysis.txt` | Scenario 3: per-topic capture counts showing the skewed cut |
| `anomaly-report.txt` | Scenario 3: quantified truth-vs-restored deltas |
| `snapshot-id.txt`, `timestamp-base.txt` | Run parameters for reproducibility |

## Running the app manually

```bash
mvn clean package

# In the compose network (recommended - matches the scripts):
docker run --rm -it --network kafka-backup-demos_kafka-net \
    -v "$(pwd)/target:/app" -v stateful-join-state:/state -p 7071:7071 \
    eclipse-temurin:17-jre \
    java -jar /app/stateful-join-demo.jar kafka-broker-1:9092 /state/kafka-streams

# From the host (requires "127.0.0.1 kafka-broker-1" in /etc/hosts, because
# the broker advertises kafka-broker-1:9092 on the external listener):
java -jar target/stateful-join-demo.jar localhost:9092 /tmp/kafka-streams-stateful-join-demo
```

Deterministic data generator:

```bash
docker run --rm --network kafka-backup-demos_kafka-net -v "$(pwd)/target:/app" \
    eclipse-temurin:17-jre \
    java -cp /app/stateful-join-demo.jar com.osodevops.demo.DataGenerator \
    kafka-broker-1:9092 batch <base_ts_ms>
```

## Configuration files

| Config | Used by | Purpose |
|---|---|---|
| `config/backup-streams-inputs.yaml` | Scenario 1 | Quiesced snapshot of `orders` + `payments` |
| `config/restore-streams-inputs.yaml` | Scenario 1 | Restore inputs (offsets handled by application reset) |
| `config/backup-streams-full.yaml` | Scenario 2 | All 8 topics in one quiesced pass |
| `config/restore-streams-full.yaml` | Scenario 2 | Restore all 8 topics (offsets via offset-rollback) |
| `config/backup-streams-hot.yaml` | Scenario 3 | Same topic set, taken hot (the mistake) |
| `config/restore-streams-hot.yaml` | Scenario 3 | Restore of the hot backup |

## Cleanup

```bash
docker rm -f stateful-join-app stateful-join-gen 2>/dev/null
docker volume rm stateful-join-state 2>/dev/null
rm -rf evidence/
```

## Next Steps

- Read the [Kafka Streams Restore Runbook](../../docs/kstreams-restore-runbook.md)
- Try [Kafka Streams PITR](../pitr-restore/instructions.md) (stateless PITR flow)
- Explore [PITR + Rollback](../../cli/pitr-rollback-e2e/instructions.md)
