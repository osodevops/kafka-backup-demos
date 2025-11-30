# kafka-backup-demos: OSS Demos PRD

**Date:** 2025-11-30  
**Version:** 1.0  
**Scope:** Demos for OSO Kafka Backup OSS core features using CLI, Java, Spring Boot, and Python.

---

## 1. Goals

- Showcase each **OSS core capability** of OSO Kafka Backup with a focused demo.
- Use a **consistent environment** via a shared `docker-compose.yml` (copied from the main repo).
- Provide **copy‑paste runnable** examples for:
  - Kafka CLI tools
  - Java Kafka Streams
  - Spring Boot (Streams + producer/consumer)
  - Python Kafka client
- Avoid duplication: each demo highlights a distinct use case.

---

## 2. Repository Structure
kafka-backup-demos/
├── docker-compose.yml # from osodevops/kafka-backup
├── README.md # overview + quickstart
├── cli/
│ ├── offset-testing/
│ │ ├── demo.sh
│ │ └── instructions.md
│ └── backup-basic/
│ ├── demo.sh
│ └── instructions.md
├── java-streams/
│ ├── pitr-restore/
│ │ ├── src/main/java/.../DemoKafkaStreamsPITR.java
│ │ └── instructions.md
│ └── offset-reset-verify/
│ ├── src/main/java/.../DemoOffsetReset.java
│ └── instructions.md
├── springboot/
│ ├── backup-restore-flow/
│ │ ├── src/main/java/.../BackupRestoreApplication.java
│ │ └── instructions.md
│ └── producer-consumer/
│ ├── src/main/java/.../ProducerApplication.java
│ ├── src/main/java/.../ConsumerApplication.java
│ └── instructions.md
├── python/
│ └── backup-restore-py/
│ ├── demo_backup_restore.py
│ └── instructions.md
├── data/
│ ├── sample-large-messages.json
│ └── orders.csv
└── docs/
├── demo-index.md
├── troubleshooting.md
└── known-issues.md


`docker-compose.yml` is taken directly from:  
`https://github.com/osodevops/kafka-backup/blob/main/docker-compose.yml`

---

## 3. Common Environment

- Single‑broker Kafka cluster + Zookeeper.
- Optional MinIO/S3 service for cloud‑storage backup demos.
- `kafka-backup` container built from the OSS repo.
- Default topics:
  - `orders`
  - `payments`
  - `events`
- Default consumer groups used across demos:
  - `orders-streams`
  - `payments-processor`
  - `demo-consumer`

Each demo’s `instructions.md` includes:

1. Prerequisites (`docker compose up -d`).
2. Commands to create topics / produce seed data.
3. Exact `kafka-backup` CLI commands.
4. How to validate the outcome.

---

## 4. Demo Specifications

### 4.1 CLI – Offset State Verification

**Path:** `cli/offset-testing/`  
**Core feature:** Consumer offset snapshot & inspection.

**Scenario:**

- Use `kafka-consumer-groups` to show current offsets for `orders-streams`.
- Run `kafka-backup offset-report` (or equivalent) to export offsets as JSON.
- Show how the JSON can be used to:
  - Verify committed offsets per partition.
  - Compare “before vs after” states when testing restores.

**Artifacts:**

- `demo.sh`:
  - Creates topic, produces 100 messages.
  - Starts a console consumer to commit offsets.
  - Exports offset mapping to `offsets.json`.
- `instructions.md`:
  - Includes commands, screenshots examples, and expected JSON keys.

---

### 4.2 CLI – Basic Topic Backup & Restore

**Path:** `cli/backup-basic/`  
**Core feature:** Backup & restore of a topic to S3/MinIO.

**Scenario:**

- Produce sample data to `orders` (CSV or JSON from `data/orders.csv`).
- Run `kafka-backup backup` to MinIO.
- Delete `orders` topic.
- Recreate topic and run `kafka-backup restore`.
- Validate that message count and payloads match.

**Artifacts:**

- `demo.sh`:
  - Uses `kafka-topics` and `kafka-console-producer`.
  - Calls `kafka-backup` with minimal config.
- `instructions.md`:
  - Step‑by‑step, plus “how to adapt to AWS S3”.

---

### 4.3 Java Kafka Streams – Point-in-Time Restore (PITR)

**Path:** `java-streams/pitr-restore/`  
**Core feature:** Point‑in‑time restore + clean resume of a Kafka Streams app.

**Scenario:**

1. Java Kafka Streams app consumes `orders` and writes to `orders_enriched`.
2. Continuous backup runs in the background.
3. A bug is simulated by producing bad messages after time `T`.
4. Run `kafka-backup restore` with `--timestamp T` to roll cluster back.
5. Restart Streams app; it resumes from the restored offsets and only processes good data.

**Artifacts:**

- `DemoKafkaStreamsPITR.java`:
  - Simple topology: `orders` → filter/map → `orders_enriched`.
- `instructions.md`:
  - Includes:
    - How to build/run the JAR with Maven/Gradle.
    - Timing diagram and expected counts before/after PITR.

---

### 4.4 Java – Offset Reset Verification

**Path:** `java-streams/offset-reset-verify/`  
**Core feature:** Bulk offset reset correctness.

**Scenario:**

- Plain Java consumer reads from `payments` up to offset N, writing processed offsets to stdout/file.
- `kafka-backup` performs a bulk offset reset for the consumer group to `N-20`.
- Java consumer restarts and should re‑read the last 20 records exactly once.

**Artifacts:**

- `DemoOffsetReset.java`
- `instructions.md` with expected log excerpts (before reset, after reset).

---

### 4.5 Spring Boot Streams – Backup + Restore Flow

**Path:** `springboot/backup-restore-flow/`  
**Core feature:** End‑to‑end backup + restore integrated with a Spring Kafka Streams app.

**Scenario:**

- Spring Boot app defines a Kafka Streams topology from `events` → `events_agg`.
- Produce events; app aggregates counts in memory and logs them.
- Trigger backup of the `events` topic.
- Simulate cluster wipe (delete topics, restart containers).
- Restore from backup; restart app.
- Verify that aggregates recompute correctly from restored data.

**Artifacts:**

- `BackupRestoreApplication.java` (simple Streams topology).
- `application.yml` with Kafka + topic config.
- `instructions.md` with Maven commands and curl snippets if actuator endpoints are used.

---

### 4.6 Spring Boot Producer/Consumer – PITR Demo

**Path:** `springboot/producer-consumer/`  
**Core feature:** PITR plus consumer offset recovery in a classic microservice pair.

**Scenario:**

- `ProducerApplication` publishes order events with timestamps and IDs.
- `ConsumerApplication` consumes and logs processed order IDs.
- After some time, inject “bad” events (e.g. negative amounts).
- Use `kafka-backup` to restore topic and offsets to just before the bad events.
- Restart consumer, verifying only valid events exist and offsets match.

**Artifacts:**

- `ProducerApplication.java`, `ConsumerApplication.java`.
- `instructions.md` with:
  - How to watch logs.
  - Expected ID ranges before/after restore.

---

### 4.7 Python – Backup & Restore Flow

**Path:** `python/backup-restore-py/`  
**Core feature:** Language‑agnostic backup/restore, validated with Python client.

**Scenario:**

- Python script produces JSON payloads to `orders`.
- Call `kafka-backup` via `subprocess.run()` to perform a backup.
- Delete and recreate topic.
- Run `kafka-backup restore`.
- Python script consumes all records and compares with original list in memory or on disk.

**Artifacts:**

- `demo_backup_restore.py` using `confluent-kafka` or `kafka-python`.
- `instructions.md` including `pip install` requirements.

---

### 4.8 Large Messages – Cloud Backup

**Path:** `cli/large-messages/` (or reuse `cli/backup-basic` with different data)  
**Core feature:** Handling of large messages and compression.

**Scenario:**

- Load `data/sample-large-messages.json` with 1MB–10MB JSON blobs.
- Produce these to `large_messages` topic.
- Backup to MinIO using zstd or gzip compression.
- Restore and verify:
  - No truncation.
  - Compression+decompression metrics (optionally logged).

**Artifacts:**

- `demo.sh` to produce large messages and call backup/restore.
- `instructions.md` describing any broker config tweaks (e.g. `message.max.bytes`).

---

### 4.9 Offset Mapping Report Demo

**Path:** `cli/offset-report/`  
**Core feature:** JSON offset mapping report generation and analysis.

**Scenario:**

- Run workloads with multiple consumer groups.
- Generate offset mapping JSON using `kafka-backup offset-report`.
- Use `jq` or a tiny Python script to:
  - List groups and partitions.
  - Find lag for each group relative to topic end offsets.
- Explain how these reports help plan restores and audits.

**Artifacts:**

- `demo.sh` to generate `offset-report.json`.
- `analyze_offsets.py` or simple `jq` examples.
- `instructions.md` with example queries.

---

### 4.10 Automated PITR + Rollback Demo

**Path:** `cli/pitr-rollback-e2e/`  
**Core feature:** Combine snapshot, PITR, offset reset, and rollback.

**Scenario:**

1. Produce normal traffic to `payments`.
2. Take an offset snapshot (via backup tool’s snapshot mechanism).
3. Inject corrupted data or simulate a faulty deployment.
4. Perform PITR restore + offset reset.
5. If verification script detects anomalies, run rollback:
   - Restore offsets from snapshot.
6. Re‑run verification to confirm clean state.

**Artifacts:**

- `demo.sh` orchestrating:
  - Snapshot
  - PITR restore
  - Verification (a simple consumer or script)
  - Rollback on failure
- `instructions.md` showing before/after state.

---

## 5. README & Docs

### 5.1 Root README Quickstart

- One‑liner: “A collection of runnable demos for OSO Kafka Backup.”
- `docker compose up -d`
- Links to each demo:
  - `cli/offset-testing` – “Inspect and snapshot consumer offsets”
  - `java-streams/pitr-restore` – “Kafka Streams point‑in‑time recovery”
  - etc.

### 5.2 `docs/demo-index.md`

- Table summarising each demo:
  - Name, path, language, feature, difficulty (Beginner/Intermediate/Advanced).

---

## 6. Acceptance Criteria

- All 10 demos run successfully using the shared `docker-compose.yml`.
- Each demo is focused on a **distinct OSS core capability** (no redundant overlaps).
- Instructions for each demo are clear enough for a new Kafka user to follow.
- The repo structure mirrors the clarity of `conduktor-gateway-demos`, but tailored to backup/restore + offsets use cases.
