# Java Kafka Streams Demo: Point-in-Time Restore

**Core Feature:** Point-in-time restore with clean Kafka Streams app resume

## Overview

This demo shows how a Kafka Streams application can cleanly resume after a point-in-time restore. The application:

1. Consumes orders from the `orders` topic
2. Filters out invalid/bad orders
3. Enriches valid orders with processing metadata
4. Writes to `orders_enriched` topic

## Scenario

```
Timeline:
─────────────────────────────────────────────────────────────────────►

[T0]           [T1]              [T2]              [T3]           [T4]
 │              │                 │                 │              │
 │  Streams app │   Bug deployed  │   PITR restore  │   Streams    │
 │  processing  │   bad data sent │   to T1         │   resumes    │
 │  good data   │                 │                 │              │
 └──────────────┴─────────────────┴─────────────────┴──────────────┘
    GOOD DATA      CORRUPTED DATA    RECOVERY         CLEAN RESUME
```

## Prerequisites

- Java 17+
- Maven 3.6+
- Docker environment running (`docker compose up -d`)

## Building

```bash
cd java-streams/pitr-restore
mvn clean package
```

## Running

### Option 1: Using Maven
```bash
mvn exec:java -Dexec.args="localhost:9092"
```

### Option 2: Using JAR
```bash
java -jar target/kafka-streams-pitr-demo.jar localhost:9092
```

### Option 3: In Docker network
```bash
docker run --rm -it --network kafka-backup-demos_kafka-net \
    -v $(pwd)/target:/app \
    eclipse-temurin:17-jre \
    java -jar /app/kafka-streams-pitr-demo.jar kafka-broker-1:9092
```

## Demo Walkthrough

### Step 1: Start the Streams Application

```bash
# In terminal 1
cd java-streams/pitr-restore
mvn exec:java -Dexec.args="localhost:9092"
```

You should see:
```
==============================================
   Kafka Streams PITR Demo
==============================================
Bootstrap servers: localhost:9092
Input topic: orders
Output topic: orders_enriched

Streams application started. Press Ctrl+C to stop.
```

### Step 2: Produce Good Orders

```bash
# In terminal 2
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 1 20); do
        echo "{\"order_id\": \"ORD-$i\", \"amount\": $((100 + RANDOM % 900)), \"product\": \"Widget\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
```

Watch terminal 1 - you should see enriched orders being processed:
```
Enriched order: {"order_id":"ORD-1","amount":523,"product":"Widget","enriched":true,"processed_at":"2025-01-15T12:00:00Z","processor":"orders-streams"}
```

### Step 3: Record PITR Timestamp

```bash
PITR_TIMESTAMP=$(date +%s000)
echo "PITR timestamp: $PITR_TIMESTAMP"
```

### Step 4: Create Backup

```bash
# Stop the streams app (Ctrl+C in terminal 1)

# Create backup
docker compose --profile tools run --rm kafka-backup \
    backup --config /config/backup-basic.yaml
```

### Step 5: Simulate Bug - Inject Bad Data

```bash
# Restart streams app in terminal 1
mvn exec:java -Dexec.args="localhost:9092"

# In terminal 2, inject bad data
docker compose --profile tools run --rm kafka-cli bash -c '
    for i in $(seq 21 40); do
        echo "{\"order_id\": \"BAD-$i\", \"amount\": -999, \"status\": \"CORRUPTED\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
```

Watch terminal 1 - you'll see filtered warnings:
```
Filtered BAD order: {"order_id":"BAD-21","amount":-999,"status":"CORRUPTED"}
```

### Step 6: Stop the Streams App

Press `Ctrl+C` in terminal 1. Note the counters:
```
==============================================
   Shutting Down
==============================================
Total processed: 40
Filtered (bad):  20
Enriched:        20
```

### Step 7: PITR Restore

```bash
# Delete topics
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders_enriched
'

# Recreate topics
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic orders --partitions 3 --replication-factor 1
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic orders_enriched --partitions 3 --replication-factor 1
'

# Restore with PITR
docker compose --profile tools run --rm kafka-backup \
    restore --config /config/restore-basic.yaml
```

### Step 8: Reset Streams App State

```bash
# Clean local state directory
rm -rf /tmp/kafka-streams-pitr-demo

# Reset consumer group offsets
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group orders-streams --topic orders \
        --reset-offsets --to-earliest --execute
'
```

### Step 9: Restart Streams App

```bash
mvn exec:java -Dexec.args="localhost:9092"
```

The app will now reprocess only the good data from before the incident.

### Step 10: Verify

Check that only good orders are in the enriched topic:

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic orders_enriched --from-beginning \
        --timeout-ms 10000 | grep -c "BAD"
'
# Should output: 0
```

## Application Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kafka Streams Topology                    │
│                                                             │
│   orders     ┌─────────┐   ┌─────────┐   orders_enriched   │
│   ─────────► │ Filter  │ ─►│ Enrich  │ ─────────────────►  │
│              │ (valid) │   │ (+meta) │                      │
│              └─────────┘   └─────────┘                      │
│                   │                                         │
│                   ▼                                         │
│              [Filtered]                                     │
│              Bad orders                                     │
│              logged                                         │
└─────────────────────────────────────────────────────────────┘
```

## Key Code Points

### Filtering Invalid Orders
```java
.filter((key, value) -> {
    boolean isValid = isValidOrder(value);
    // Rejects orders containing "BAD", "CORRUPTED", "INVALID"
    return isValid;
})
```

### Enrichment
```java
.mapValues(value -> {
    // Adds: enriched=true, processed_at, processor
    return enrichOrder(value);
})
```

### Processing Guarantees
```java
props.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG,
          StreamsConfig.AT_LEAST_ONCE);
```

## Timing Diagram

```
Messages in 'orders' topic:
┌──────────────────────────────────────────────────────────┐
│ offset 0-19: Good orders (ORD-1 to ORD-20)               │
├──────────────────────────────────────────────────────────┤
│ offset 20-39: Bad orders (BAD-21 to BAD-40)  [REMOVED]   │
└──────────────────────────────────────────────────────────┘
                           │
                    PITR Restore
                           │
                           ▼
┌──────────────────────────────────────────────────────────┐
│ offset 0-19: Good orders (ORD-1 to ORD-20)               │
└──────────────────────────────────────────────────────────┘

Streams app resumes from offset 0, reprocesses only good data
```

## Cleanup

```bash
# Remove local state
rm -rf /tmp/kafka-streams-pitr-demo

# Delete consumer group
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group orders-streams --delete
'
```

## Next Steps

- Try [Offset Reset Verification](../offset-reset-verify/instructions.md)
- Explore [Spring Boot Streams Demo](../../springboot/backup-restore-flow/instructions.md)
