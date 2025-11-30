# Demo Index

Complete reference for all kafka-backup demos.

## Quick Reference

| # | Demo | Path | Language | Core Feature | Difficulty |
|---|------|------|----------|--------------|------------|
| 1 | [Offset State Verification](#1-offset-state-verification) | `cli/offset-testing/` | Bash | Consumer offset snapshot | Beginner |
| 2 | [Basic Backup & Restore](#2-basic-backup--restore) | `cli/backup-basic/` | Bash | Full backup/restore cycle | Beginner |
| 3 | [Large Messages](#3-large-messages--compression) | `cli/large-messages/` | Bash | Large payloads + compression | Intermediate |
| 4 | [Offset Mapping Report](#4-offset-mapping-report) | `cli/offset-report/` | Bash/Python | JSON offset analysis | Intermediate |
| 5 | [PITR + Rollback](#5-pitr--rollback-end-to-end) | `cli/pitr-rollback-e2e/` | Bash | Complete PITR workflow | Advanced |
| 6 | [Kafka Streams PITR](#6-kafka-streams-pitr) | `java-streams/pitr-restore/` | Java | Streams app recovery | Intermediate |
| 7 | [Offset Reset Verify](#7-offset-reset-verification) | `java-streams/offset-reset-verify/` | Java | Bulk offset reset | Intermediate |
| 8 | [Spring Boot Streams](#8-spring-boot-streams) | `springboot/backup-restore-flow/` | Java | E2E with Spring Streams | Intermediate |
| 9 | [Spring Boot PITR](#9-spring-boot-producerconsumer-pitr) | `springboot/producer-consumer/` | Java | Microservice PITR | Advanced |
| 10 | [Python Backup/Restore](#10-python-backup--restore) | `python/backup-restore-py/` | Python | Language-agnostic | Beginner |
| 11 | [Benchmarks](#11-performance-benchmarks) | `benchmarks/` | Bash/Python | Performance testing | Intermediate |

---

## CLI Demos

### 1. Offset State Verification

**Path:** `cli/offset-testing/`
**Difficulty:** Beginner

Demonstrates consumer offset snapshot and inspection using `kafka-backup offset-rollback`.

**Key Commands:**
```bash
kafka-backup offset-rollback snapshot --groups orders-streams
kafka-backup offset-rollback show --snapshot-id <ID> --format json
kafka-backup offset-rollback rollback --snapshot-id <ID>
```

**What You'll Learn:**
- How to capture offset state
- Exporting offsets as JSON
- Comparing before/after restore states

---

### 2. Basic Backup & Restore

**Path:** `cli/backup-basic/`
**Difficulty:** Beginner

Full backup/restore cycle to MinIO (S3-compatible storage).

**Key Commands:**
```bash
kafka-backup backup --config backup-basic.yaml
kafka-backup list --path s3://kafka-backups/demo
kafka-backup restore --config restore-basic.yaml
```

**What You'll Learn:**
- Basic backup workflow
- MinIO/S3 storage integration
- Data validation after restore

---

### 3. Large Messages & Compression

**Path:** `cli/large-messages/`
**Difficulty:** Intermediate

Handling large message payloads (1-10MB) with compression.

**Key Commands:**
```bash
kafka-backup backup --config backup-large.yaml
kafka-backup describe --path s3://bucket --backup-id large-backup
```

**What You'll Learn:**
- Compression algorithms (zstd, lz4, gzip)
- Broker configuration for large messages
- Compression ratio comparisons

---

### 4. Offset Mapping Report

**Path:** `cli/offset-report/`
**Difficulty:** Intermediate

Generate and analyze JSON offset mapping reports.

**Key Commands:**
```bash
kafka-backup show-offset-mapping --path s3://bucket --backup-id ID --format json
jq '.topics | keys' offset-report.json
```

**What You'll Learn:**
- Multi-topic offset analysis
- Using jq for report queries
- Restore planning from reports

---

### 5. PITR + Rollback End-to-End

**Path:** `cli/pitr-rollback-e2e/`
**Difficulty:** Advanced

Complete point-in-time recovery workflow with rollback safety.

**Key Commands:**
```bash
kafka-backup offset-rollback snapshot --description "Pre-incident"
kafka-backup backup --config backup-pitr.yaml
kafka-backup restore --config restore-pitr.yaml --time-window-end $TIMESTAMP
kafka-backup offset-reset execute --groups payments-processor
kafka-backup offset-rollback rollback --snapshot-id <ID>
```

**What You'll Learn:**
- Full PITR workflow
- Offset snapshot/rollback
- Recovery verification

---

## Java Demos

### 6. Kafka Streams PITR

**Path:** `java-streams/pitr-restore/`
**Difficulty:** Intermediate

Kafka Streams application recovery after point-in-time restore.

**Build & Run:**
```bash
mvn clean package
java -jar target/kafka-streams-pitr-demo.jar localhost:9092
```

**What You'll Learn:**
- Streams app recovery patterns
- Filtering bad data in topology
- State store rebuilding

---

### 7. Offset Reset Verification

**Path:** `java-streams/offset-reset-verify/`
**Difficulty:** Intermediate

Verify bulk offset reset correctness with plain KafkaConsumer.

**Build & Run:**
```bash
mvn clean package
java -jar target/offset-reset-verify-demo.jar localhost:9092 50
```

**What You'll Learn:**
- Consumer offset tracking
- Verifying exact re-read count
- Offset reset validation

---

## Spring Boot Demos

### 8. Spring Boot Streams

**Path:** `springboot/backup-restore-flow/`
**Difficulty:** Intermediate

End-to-end backup/restore with Spring Kafka Streams aggregation.

**Build & Run:**
```bash
mvn spring-boot:run
curl http://localhost:8080/counts
```

**What You'll Learn:**
- Spring Kafka Streams integration
- State store recovery
- REST API for queries

---

### 9. Spring Boot Producer/Consumer PITR

**Path:** `springboot/producer-consumer/`
**Difficulty:** Advanced

Classic microservice pair with PITR recovery.

**Build & Run:**
```bash
mvn spring-boot:run
curl -X POST http://localhost:8080/producer/start
curl http://localhost:8080/consumer/status
curl -X POST http://localhost:8080/producer/inject-bad?count=10
```

**What You'll Learn:**
- Producer/consumer patterns
- REST-controlled demos
- Bad data injection and recovery

---

## Python Demo

### 10. Python Backup & Restore

**Path:** `python/backup-restore-py/`
**Difficulty:** Beginner

Language-agnostic backup/restore validation with Python.

**Run:**
```bash
pip install -r requirements.txt
python demo_backup_restore.py
```

**What You'll Learn:**
- Subprocess integration
- Cross-language validation
- Data integrity verification

---

## Benchmarks Demo

### 11. Performance Benchmarks

**Path:** `benchmarks/`
**Difficulty:** Intermediate

Comprehensive performance testing suite for kafka-backup.

**Quick Run:**
```bash
./benchmarks/run_quick_benchmark.sh
```

**Full Suite:**
```bash
./benchmarks/run_full_benchmark.sh
```

**Scenarios:**
- **Throughput** - Maximum backup/restore speed
- **Compression** - Algorithm comparison (zstd, lz4, none)
- **Latency** - Checkpoint and segment write latencies
- **Large Messages** - 100KB, 1MB, 5MB message handling
- **Concurrent Partitions** - Parallel partition scaling

**What You'll Learn:**
- Performance characteristics
- Tuning parameters
- Compression tradeoffs
- Scaling behavior

**Key Metrics:**
| Metric | Target |
|--------|--------|
| Backup throughput | >50 MB/s |
| Restore throughput | >40 MB/s |
| Checkpoint p99 latency | <100ms |
| Compression ratio (zstd) | >3x |

---

## Demo Progression

### Recommended Learning Path

**Beginner:**
1. Offset State Verification (understand offsets)
2. Basic Backup & Restore (core workflow)
3. Python Demo (language-agnostic concepts)

**Intermediate:**
4. Large Messages (compression, config)
5. Offset Mapping Report (analysis)
6. Kafka Streams PITR (Java patterns)
7. Spring Boot Streams (framework integration)

**Advanced:**
8. PITR + Rollback E2E (full workflow)
9. Offset Reset Verify (validation)
10. Spring Boot PITR (microservices)

---

## Feature Coverage Matrix

| Feature | CLI | Java | Spring | Python | Benchmarks |
|---------|-----|------|--------|--------|------------|
| Basic Backup | ✓ | - | - | ✓ | ✓ |
| Basic Restore | ✓ | - | - | ✓ | ✓ |
| PITR | ✓ | ✓ | ✓ | - | - |
| Offset Snapshot | ✓ | - | - | - | - |
| Offset Reset | ✓ | ✓ | - | - | - |
| Offset Rollback | ✓ | - | - | - | - |
| Large Messages | ✓ | - | - | - | ✓ |
| Compression | ✓ | - | - | - | ✓ |
| Streams Integration | - | ✓ | ✓ | - | - |
| REST API | - | - | ✓ | - | - |
| Performance Metrics | - | - | - | - | ✓ |

---

## Environment Requirements

| Demo Category | Requirements |
|---------------|--------------|
| CLI | Docker, Docker Compose |
| Java | JDK 17+, Maven 3.6+ |
| Spring Boot | JDK 17+, Maven 3.6+ |
| Python | Python 3.9+, pip |

All demos require the Docker environment:
```bash
docker compose up -d
```
