# Spring Boot Demo: Backup & Restore Flow

**Core Feature:** End-to-end backup/restore with Spring Kafka Streams

## Overview

This demo shows how a Spring Boot Kafka Streams application handles backup and restore:

1. Consumes events from `events` topic
2. Aggregates counts by event key
3. Writes aggregated results to `events_agg` topic
4. Exposes REST endpoints to query current counts

The demo shows how aggregates recompute correctly after a backup/restore cycle.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Spring Boot Application                       │
│                                                                 │
│   events         ┌──────────────┐      events_agg              │
│   ─────────────► │  GroupByKey  │ ─────────────────────►       │
│                  │    Count     │                               │
│                  └──────────────┘                               │
│                         │                                       │
│                         ▼                                       │
│                  ┌──────────────┐                               │
│                  │ State Store  │                               │
│                  │ (RocksDB)    │                               │
│                  └──────────────┘                               │
│                         │                                       │
│                         ▼                                       │
│                  ┌──────────────┐                               │
│                  │ REST API     │                               │
│                  │ /counts      │                               │
│                  └──────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Java 17+
- Maven 3.6+
- Docker environment running (`docker compose up -d`)

## Building

```bash
cd springboot/backup-restore-flow
mvn clean package -DskipTests
```

## Running

### Option 1: Maven
```bash
mvn spring-boot:run
```

### Option 2: JAR
```bash
java -jar target/springboot-backup-restore-demo-1.0-SNAPSHOT.jar
```

### Option 3: With custom Kafka
```bash
java -jar target/springboot-backup-restore-demo-1.0-SNAPSHOT.jar \
    --spring.kafka.bootstrap-servers=kafka-broker-1:9092
```

## Demo Walkthrough

### Step 1: Start the Application

```bash
cd springboot/backup-restore-flow
mvn spring-boot:run
```

Watch for:
```
Spring Boot Backup/Restore Demo
Building Kafka Streams topology:
  Input topic: events
  Output topic: events_agg
  State store: events-count-store
```

### Step 2: Produce Events

```bash
# In another terminal, produce events with different keys
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 30); do
        KEY="event-type-$((i % 3))"
        echo "$KEY:{\"event_id\": \"EVT-$i\", \"type\": \"$KEY\"}"
    done | kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic events \
        --property "parse.key=true" \
        --property "key.separator=:"
'
```

### Step 3: Check Aggregated Counts

Watch the application logs for count updates:
```
Event count updated: key=event-type-0, count=10
Event count updated: key=event-type-1, count=10
Event count updated: key=event-type-2, count=10
```

Or query via REST:
```bash
# Get all counts
curl http://localhost:8080/counts

# Get specific key count
curl http://localhost:8080/counts/event-type-0
```

### Step 4: Create Backup

Stop the application (Ctrl+C), then:

```bash
# Create backup config
cat > /tmp/backup-events.yaml << 'EOF'
mode: backup
backup_id: "events-backup"

source:
  bootstrap_servers:
    - kafka-broker-1:9092
  topics:
    include:
      - events

storage:
  backend: s3
  bucket: kafka-backups
  region: us-east-1
  prefix: spring-demo
  endpoint: http://minio:9000
  path_style: true
  access_key_id: minioadmin
  secret_access_key: minioadmin

backup:
  compression: zstd
EOF

# Run backup
docker compose --profile tools run --rm -v /tmp:/tmp kafka-backup \
    backup --config /tmp/backup-events.yaml
```

### Step 5: Simulate Cluster Wipe

```bash
# Delete all topics
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic events
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic events_agg
'

# Recreate topics
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic events --partitions 3 --replication-factor 1
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic events_agg --partitions 3 --replication-factor 1
'
```

### Step 6: Restore from Backup

```bash
# Create restore config
cat > /tmp/restore-events.yaml << 'EOF'
mode: restore
backup_id: "events-backup"

target:
  bootstrap_servers:
    - kafka-broker-1:9092
  topics:
    include:
      - events

storage:
  backend: s3
  bucket: kafka-backups
  region: us-east-1
  prefix: spring-demo
  endpoint: http://minio:9000
  path_style: true
  access_key_id: minioadmin
  secret_access_key: minioadmin

restore:
  dry_run: false
EOF

# Run restore
docker compose --profile tools run --rm -v /tmp:/tmp kafka-backup \
    restore --config /tmp/restore-events.yaml
```

### Step 7: Clear Application State

```bash
# Clear local state store
rm -rf /tmp/kafka-streams-spring-demo

# Reset consumer group (optional)
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group events-aggregator --delete
'
```

### Step 8: Restart Application

```bash
mvn spring-boot:run
```

### Step 9: Verify Recomputation

Watch the logs - you should see the aggregates being recomputed:
```
Event count updated: key=event-type-0, count=1
Event count updated: key=event-type-0, count=2
...
Event count updated: key=event-type-0, count=10
```

Query the counts:
```bash
curl http://localhost:8080/counts
# Should show: {"event-type-0":10,"event-type-1":10,"event-type-2":10}
```

## REST API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/counts` | GET | Get all event counts |
| `/counts/{key}` | GET | Get count for specific key |
| `/actuator/health` | GET | Application health status |

Example responses:

```bash
# All counts
curl http://localhost:8080/counts
# {"event-type-0":10,"event-type-1":10,"event-type-2":10}

# Specific key
curl http://localhost:8080/counts/event-type-0
# {"key":"event-type-0","count":10}

# Health check
curl http://localhost:8080/actuator/health
# {"status":"UP"}
```

## Key Observations

1. **State Recovery**: After restore, the Streams app reprocesses all events
2. **Aggregates Recompute**: Counts match the original values after recomputation
3. **Exactly-Once Semantics**: No duplicates in the output topic
4. **State Store Rebuild**: RocksDB state is rebuilt from the changelog

## Configuration Reference

### application.yml
```yaml
spring:
  kafka:
    streams:
      application-id: events-aggregator
      properties:
        commit.interval.ms: 1000
        state.dir: /tmp/kafka-streams-spring-demo
```

### Environment Variables
- `KAFKA_BOOTSTRAP_SERVERS`: Kafka broker address (default: localhost:9092)

## Cleanup

```bash
rm -rf /tmp/kafka-streams-spring-demo
docker compose exec minio mc rm --recursive --force local/kafka-backups/spring-demo/
```

## Next Steps

- Try [Producer/Consumer PITR Demo](../producer-consumer/instructions.md)
- Explore [Python Demo](../../python/backup-restore-py/instructions.md)
