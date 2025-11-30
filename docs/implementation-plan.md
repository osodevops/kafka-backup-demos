# Implementation Plan: kafka-backup-demos

**Based on:** `docs/demos-prd.md`
**Date:** 2025-11-30

---

## Overview

This plan implements 10 demos showcasing OSO Kafka Backup's OSS core features. The demos span CLI, Java Kafka Streams, Spring Boot, and Python, all using a shared `docker-compose.yml` environment.

---

## Phase 1: Foundation Setup

### 1.1 Copy docker-compose.yml from kafka-backup repo

**Source:** `/Users/sionsmith/development/oso/com.github.osodevops/kafka-backup/docker-compose.yml`

The existing docker-compose includes:
- Kafka broker (KRaft mode, no Zookeeper)
- MinIO for S3-compatible storage
- Pre-configured topics: `test-topic`, `orders`, `payments`
- kafka-backup service

**Required modifications:**
- Add `events` topic to kafka-setup service
- Add consumer groups: `orders-streams`, `payments-processor`, `demo-consumer`
- Ensure `large_messages` topic can be created with custom `message.max.bytes`

### 1.2 Create root README.md

- One-liner description
- Quick start: `docker compose up -d`
- Links to all 10 demos with brief descriptions
- Prerequisites (Docker, Docker Compose)

### 1.3 Create sample data files

**`data/orders.csv`:**
```csv
order_id,customer_id,amount,timestamp
1001,C001,250.00,2025-01-15T10:00:00Z
...
```

**`data/sample-large-messages.json`:**
- Generate 5-10 JSON objects ranging 1MB-10MB
- Use nested structures with realistic data

---

## Phase 2: CLI Demos (4 demos)

### 2.1 CLI - Offset State Verification (`cli/offset-testing/`)

**Core feature:** Consumer offset snapshot & inspection

**Implementation:**
1. `demo.sh`:
   ```bash
   # Create topic, produce 100 messages
   kafka-topics.sh --create --topic orders --partitions 3
   for i in {1..100}; do echo "order-$i" | kafka-console-producer.sh --topic orders; done

   # Start console consumer to commit offsets
   kafka-console-consumer.sh --topic orders --group orders-streams --from-beginning --max-messages 50

   # Use kafka-consumer-groups to show current offsets
   kafka-consumer-groups.sh --describe --group orders-streams

   # Create offset snapshot using kafka-backup
   kafka-backup offset-rollback snapshot --path s3://kafka-backups/demo \
     --groups orders-streams --bootstrap-servers kafka:9092 --description "Demo snapshot"

   # Show snapshot details as JSON
   kafka-backup offset-rollback show --path s3://kafka-backups/demo \
     --snapshot-id <SNAPSHOT_ID> --format json > offsets.json
   ```

2. `instructions.md`:
   - Prerequisites
   - Step-by-step commands with expected output
   - JSON schema explanation
   - Use case: comparing before/after restore states

### 2.2 CLI - Basic Topic Backup & Restore (`cli/backup-basic/`)

**Core feature:** Full backup/restore cycle to MinIO

**Implementation:**
1. `demo.sh`:
   ```bash
   # Produce sample data from CSV
   cat /data/orders.csv | kafka-console-producer.sh --topic orders

   # Count messages before backup
   kafka-run-class.sh kafka.tools.GetOffsetShell --topic orders

   # Run backup to MinIO
   kafka-backup backup --config /config/backup-basic.yaml

   # Delete topic
   kafka-topics.sh --delete --topic orders

   # Recreate topic
   kafka-topics.sh --create --topic orders --partitions 3

   # Restore from backup
   kafka-backup restore --config /config/restore-basic.yaml

   # Validate message count matches
   kafka-run-class.sh kafka.tools.GetOffsetShell --topic orders
   ```

2. Config files: `backup-basic.yaml`, `restore-basic.yaml`

3. `instructions.md`:
   - MinIO vs AWS S3 configuration differences
   - Validation steps

### 2.3 CLI - Large Messages & Compression (`cli/large-messages/`)

**Core feature:** Handling large messages with compression

**Implementation:**
1. `demo.sh`:
   ```bash
   # Create topic with increased message size limit
   kafka-topics.sh --create --topic large_messages --partitions 1 \
     --config max.message.bytes=15728640

   # Produce large JSON messages
   cat /data/sample-large-messages.json | jq -c '.[]' | \
     kafka-console-producer.sh --topic large_messages

   # Backup with zstd compression
   kafka-backup backup --config /config/backup-large.yaml

   # Show backup size vs original
   kafka-backup describe --path s3://kafka-backups/large-demo --backup-id large-backup

   # Restore and validate no truncation
   kafka-backup restore --config /config/restore-large.yaml

   # Consume and verify message sizes
   kafka-console-consumer.sh --topic large_messages --from-beginning | wc -c
   ```

2. `instructions.md`:
   - Broker config tweaks for large messages
   - Compression comparison (zstd vs gzip vs lz4)

### 2.4 CLI - Offset Mapping Report (`cli/offset-report/`)

**Core feature:** JSON offset mapping generation and analysis

**Implementation:**
1. `demo.sh`:
   ```bash
   # Run workloads with multiple consumer groups
   kafka-console-consumer.sh --topic orders --group orders-streams --max-messages 30 &
   kafka-console-consumer.sh --topic orders --group payments-processor --max-messages 20 &
   kafka-console-consumer.sh --topic payments --group demo-consumer --max-messages 50 &
   wait

   # Create backup (generates offset mapping)
   kafka-backup backup --config /config/backup-report.yaml

   # Generate offset report
   kafka-backup show-offset-mapping --path s3://kafka-backups/report-demo \
     --backup-id report-backup --format json > offset-report.json

   # Analyze with jq
   jq '.consumer_groups | keys' offset-report.json
   jq '.consumer_groups["orders-streams"].partitions' offset-report.json
   ```

2. `analyze_offsets.py`:
   ```python
   # Parse offset-report.json
   # Calculate lag per group
   # Generate summary table
   ```

3. `instructions.md`:
   - Example jq queries
   - How reports help plan restores

### 2.5 CLI - Automated PITR + Rollback (`cli/pitr-rollback-e2e/`)

**Core feature:** Complete PITR workflow with rollback safety

**Implementation:**
1. `demo.sh`:
   ```bash
   # Phase 1: Normal traffic
   for i in {1..50}; do echo "payment-$i,100.00" | kafka-console-producer.sh --topic payments; done

   # Record timestamp T
   T=$(date +%s000)

   # Phase 2: Take offset snapshot
   kafka-backup offset-rollback snapshot --path s3://kafka-backups/pitr-demo \
     --groups payments-processor --bootstrap-servers kafka:9092

   # Phase 3: Inject corrupted data
   for i in {51..100}; do echo "CORRUPTED-$i" | kafka-console-producer.sh --topic payments; done

   # Phase 4: PITR restore to time T
   kafka-backup restore --config /config/restore-pitr.yaml \
     --time-window-end $T

   # Phase 5: Reset offsets
   kafka-backup offset-reset execute --path s3://kafka-backups/pitr-demo \
     --backup-id pitr-backup --groups payments-processor \
     --bootstrap-servers kafka:9092

   # Phase 6: Verify clean state
   kafka-console-consumer.sh --topic payments --group payments-processor \
     --from-beginning | grep -c "CORRUPTED" # Should be 0

   # If verification fails, rollback
   kafka-backup offset-rollback rollback --path s3://kafka-backups/pitr-demo \
     --snapshot-id <SNAPSHOT_ID> --bootstrap-servers kafka:9092
   ```

---

## Phase 3: Java Demos (2 demos)

### 3.1 Java Kafka Streams - PITR Restore (`java-streams/pitr-restore/`)

**Core feature:** Point-in-time restore with Kafka Streams app

**Implementation:**
1. Project structure:
   ```
   pitr-restore/
   ├── pom.xml (or build.gradle)
   ├── src/main/java/com/osodevops/demo/
   │   └── DemoKafkaStreamsPITR.java
   └── instructions.md
   ```

2. `DemoKafkaStreamsPITR.java`:
   ```java
   // Topology: orders → filter(valid) → map(enrich) → orders_enriched
   StreamsBuilder builder = new StreamsBuilder();
   builder.stream("orders")
       .filter((k, v) -> !v.contains("BAD"))
       .mapValues(v -> v + ",enriched=" + System.currentTimeMillis())
       .to("orders_enriched");
   ```

3. `pom.xml`:
   - kafka-streams 3.7.x
   - slf4j for logging
   - Maven exec plugin for easy running

4. `instructions.md`:
   - Build: `mvn clean package`
   - Run: `java -jar target/pitr-restore.jar`
   - Timing diagram showing:
     1. App processes good data
     2. Bad data injected
     3. PITR restore to timestamp
     4. App resumes from restored offsets

### 3.2 Java - Offset Reset Verification (`java-streams/offset-reset-verify/`)

**Core feature:** Bulk offset reset correctness verification

**Implementation:**
1. `DemoOffsetReset.java`:
   ```java
   // Plain KafkaConsumer (not Streams)
   // Read payments up to offset N, log each processed offset
   // Store processed offsets to file
   // After reset to N-20, verify re-reading exactly 20 records

   Properties props = new Properties();
   props.put(ConsumerConfig.GROUP_ID_CONFIG, "payments-processor");
   props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "true");

   try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props)) {
       consumer.subscribe(Collections.singletonList("payments"));
       int count = 0;
       while (count < TARGET_COUNT) {
           ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
           for (ConsumerRecord<String, String> record : records) {
               System.out.printf("Processed: partition=%d, offset=%d%n",
                   record.partition(), record.offset());
               count++;
           }
       }
   }
   ```

2. `instructions.md`:
   - Expected log output before reset
   - kafka-backup offset-reset command
   - Expected log output after reset (re-reading last 20)

---

## Phase 4: Spring Boot Demos (2 demos)

### 4.1 Spring Boot Streams - Backup + Restore Flow (`springboot/backup-restore-flow/`)

**Core feature:** E2E backup/restore with Spring Kafka Streams

**Implementation:**
1. Project structure:
   ```
   backup-restore-flow/
   ├── pom.xml
   ├── src/main/java/com/osodevops/demo/
   │   ├── BackupRestoreApplication.java
   │   └── config/KafkaStreamsConfig.java
   ├── src/main/resources/
   │   └── application.yml
   └── instructions.md
   ```

2. `BackupRestoreApplication.java`:
   ```java
   @SpringBootApplication
   @EnableKafkaStreams
   public class BackupRestoreApplication {
       @Bean
       public KStream<String, String> eventsStream(StreamsBuilder builder) {
           return builder.stream("events")
               .groupByKey()
               .count(Materialized.as("events-count-store"))
               .toStream()
               .peek((k, v) -> log.info("Event count for {}: {}", k, v))
               .mapValues(Object::toString);
       }
   }
   ```

3. `application.yml`:
   ```yaml
   spring:
     kafka:
       bootstrap-servers: kafka:9092
       streams:
         application-id: events-aggregator
         properties:
           default.key.serde: org.apache.kafka.common.serialization.Serdes$StringSerde
           default.value.serde: org.apache.kafka.common.serialization.Serdes$StringSerde
   ```

4. `instructions.md`:
   - Maven commands: `mvn spring-boot:run`
   - Produce events, observe aggregation logs
   - Trigger backup
   - Simulate cluster wipe (delete topics, restart)
   - Restore and restart app
   - Verify aggregates recompute correctly

### 4.2 Spring Boot Producer/Consumer - PITR Demo (`springboot/producer-consumer/`)

**Core feature:** Classic microservice pair with PITR recovery

**Implementation:**
1. Project structure:
   ```
   producer-consumer/
   ├── pom.xml
   ├── src/main/java/com/osodevops/demo/
   │   ├── ProducerApplication.java
   │   ├── ConsumerApplication.java
   │   └── model/OrderEvent.java
   └── instructions.md
   ```

2. `ProducerApplication.java`:
   ```java
   @Scheduled(fixedRate = 1000)
   public void produceOrder() {
       OrderEvent event = new OrderEvent(
           UUID.randomUUID().toString(),
           random.nextDouble() * 1000,
           Instant.now()
       );
       kafkaTemplate.send("orders", event.getId(), event);
       log.info("Produced order: {}", event.getId());
   }
   ```

3. `ConsumerApplication.java`:
   ```java
   @KafkaListener(topics = "orders", groupId = "demo-consumer")
   public void consume(OrderEvent event) {
       if (event.getAmount() < 0) {
           log.error("Invalid order detected: {}", event.getId());
       } else {
           log.info("Processed order: {}", event.getId());
           processedIds.add(event.getId());
       }
   }
   ```

4. `instructions.md`:
   - Run producer, observe IDs being generated
   - Run consumer, observe IDs being processed
   - Inject bad events (negative amounts)
   - PITR restore to before bad events
   - Restart consumer, verify only valid events exist

---

## Phase 5: Python Demo (1 demo)

### 5.1 Python - Backup & Restore Flow (`python/backup-restore-py/`)

**Core feature:** Language-agnostic backup/restore validation

**Implementation:**
1. `requirements.txt`:
   ```
   confluent-kafka==2.3.0
   ```

2. `demo_backup_restore.py`:
   ```python
   from confluent_kafka import Producer, Consumer
   import subprocess
   import json

   # Produce JSON payloads
   original_messages = []
   producer = Producer({'bootstrap.servers': 'kafka:9092'})
   for i in range(100):
       msg = {'id': i, 'value': f'message-{i}'}
       original_messages.append(msg)
       producer.produce('orders', json.dumps(msg).encode())
   producer.flush()

   # Backup via subprocess
   subprocess.run([
       'kafka-backup', 'backup', '--config', '/config/backup-python.yaml'
   ], check=True)

   # Delete and recreate topic
   subprocess.run(['kafka-topics.sh', '--delete', '--topic', 'orders'])
   subprocess.run(['kafka-topics.sh', '--create', '--topic', 'orders', '--partitions', '3'])

   # Restore
   subprocess.run([
       'kafka-backup', 'restore', '--config', '/config/restore-python.yaml'
   ], check=True)

   # Consume and compare
   consumer = Consumer({
       'bootstrap.servers': 'kafka:9092',
       'group.id': 'python-verify',
       'auto.offset.reset': 'earliest'
   })
   consumer.subscribe(['orders'])

   restored_messages = []
   while len(restored_messages) < len(original_messages):
       msg = consumer.poll(1.0)
       if msg and not msg.error():
           restored_messages.append(json.loads(msg.value()))

   # Validate
   assert len(restored_messages) == len(original_messages)
   for orig, restored in zip(
       sorted(original_messages, key=lambda x: x['id']),
       sorted(restored_messages, key=lambda x: x['id'])
   ):
       assert orig == restored

   print("SUCCESS: All messages restored correctly!")
   ```

3. `instructions.md`:
   - `pip install -r requirements.txt`
   - `python demo_backup_restore.py`
   - Expected output

---

## Phase 6: Documentation

### 6.1 `docs/demo-index.md`

| Demo | Path | Language | Feature | Difficulty |
|------|------|----------|---------|------------|
| Offset State Verification | `cli/offset-testing/` | Bash | Consumer offset snapshot | Beginner |
| Basic Backup & Restore | `cli/backup-basic/` | Bash | Full backup/restore | Beginner |
| Large Messages | `cli/large-messages/` | Bash | Compression & large payloads | Intermediate |
| Offset Mapping Report | `cli/offset-report/` | Bash/Python | Offset analysis | Intermediate |
| PITR + Rollback | `cli/pitr-rollback-e2e/` | Bash | End-to-end PITR | Advanced |
| Kafka Streams PITR | `java-streams/pitr-restore/` | Java | Streams PITR recovery | Intermediate |
| Offset Reset Verify | `java-streams/offset-reset-verify/` | Java | Bulk offset reset | Intermediate |
| Spring Boot Streams | `springboot/backup-restore-flow/` | Java | E2E backup/restore | Intermediate |
| Spring Boot PITR | `springboot/producer-consumer/` | Java | Microservice PITR | Advanced |
| Python Backup/Restore | `python/backup-restore-py/` | Python | Language-agnostic | Beginner |

### 6.2 `docs/troubleshooting.md`

Common issues and solutions:
- Container startup order issues
- MinIO connection errors
- Topic not found after restore
- Offset reset failures
- Memory issues with large messages

### 6.3 `docs/known-issues.md`

- Document any limitations discovered during implementation

---

## Implementation Order

1. **Foundation** (1.1-1.3): docker-compose, README, sample data
2. **CLI demos** (2.1-2.5): Start with simplest to build confidence
3. **Java demos** (3.1-3.2): Leverage CLI knowledge
4. **Spring Boot demos** (4.1-4.2): Build on Java foundation
5. **Python demo** (5.1): Final validation of language-agnostic approach
6. **Documentation** (6.1-6.3): Polish and finalize

---

## Key Commands Reference (kafka-backup)

```bash
# Backup
kafka-backup backup --config backup.yaml

# Restore
kafka-backup restore --config restore.yaml

# List backups
kafka-backup list --path s3://bucket/prefix

# Describe backup
kafka-backup describe --path s3://bucket --backup-id ID --format json

# Offset snapshot
kafka-backup offset-rollback snapshot --path s3://bucket \
  --groups group1 --bootstrap-servers kafka:9092

# Offset reset (execute)
kafka-backup offset-reset execute --path s3://bucket --backup-id ID \
  --groups group1 --bootstrap-servers kafka:9092

# Show offset mapping
kafka-backup show-offset-mapping --path s3://bucket --backup-id ID --format json
```

---

## Success Criteria

- [ ] All 10 demos run successfully with `docker compose up -d`
- [ ] Each demo highlights a distinct OSS core capability
- [ ] Instructions are clear enough for Kafka beginners
- [ ] No redundant overlaps between demos
- [ ] Repository structure matches PRD specification
