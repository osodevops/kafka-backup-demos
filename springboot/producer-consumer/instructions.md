# Spring Boot Demo: Producer/Consumer PITR

**Core Feature:** Classic microservice pair with PITR recovery

## Overview

This demo shows PITR recovery with a classic producer/consumer architecture:

- **Producer**: Generates order events with timestamps and IDs
- **Consumer**: Processes orders, validates amounts, tracks IDs
- **PITR**: Recovers from "bad" data injection

## Architecture

```
┌─────────────────┐       ┌─────────────┐       ┌─────────────────┐
│    Producer     │       │    Kafka    │       │    Consumer     │
│                 │──────►│   orders    │──────►│                 │
│ /producer/*     │       │   topic     │       │ /consumer/*     │
│                 │       │             │       │                 │
│ - start/stop    │       │             │       │ - status        │
│ - inject-bad    │       │             │       │ - processed     │
│ - order         │       │             │       │ - invalid       │
└─────────────────┘       └─────────────┘       └─────────────────┘
```

## Prerequisites

- Java 17+
- Maven 3.6+
- Docker environment running (`docker compose up -d`)

## Building

```bash
cd springboot/producer-consumer
mvn clean package -DskipTests
```

## Running

### All-in-one (default)
```bash
mvn spring-boot:run
```

### Separate services
```bash
# Terminal 1: Producer only
mvn spring-boot:run -Dspring-boot.run.arguments="--app.consumer.enabled=false --server.port=8081"

# Terminal 2: Consumer only
mvn spring-boot:run -Dspring-boot.run.arguments="--app.producer.enabled=false --server.port=8082"
```

## Demo Walkthrough

### Step 1: Start the Application

```bash
cd springboot/producer-consumer
mvn spring-boot:run
```

### Step 2: Start Producing Orders

```bash
# Enable scheduled production
curl -X POST http://localhost:8080/producer/start

# Check producer status
curl http://localhost:8080/producer/status
```

### Step 3: Monitor Consumer

```bash
# Check consumer status
curl http://localhost:8080/consumer/status

# See recent orders
curl http://localhost:8080/consumer/recent

# List processed order IDs
curl http://localhost:8080/consumer/processed
```

### Step 4: Record PITR Timestamp

```bash
# Note the current time for PITR
PITR_TIMESTAMP=$(date +%s000)
echo "PITR timestamp: $PITR_TIMESTAMP"

# Check current state
curl http://localhost:8080/consumer/status
# {"totalProcessed":20,"validOrders":20,"invalidOrders":0,"invalidRate":"0.00%"}
```

### Step 5: Create Backup

```bash
# Stop producer first
curl -X POST http://localhost:8080/producer/stop

# Create backup
docker compose --profile tools run --rm kafka-backup \
    backup --config /config/backup-basic.yaml
```

### Step 6: Inject Bad Orders

```bash
# Inject 20 bad orders (negative amounts)
curl -X POST "http://localhost:8080/producer/inject-bad?count=20"

# Check consumer - should show invalid orders
curl http://localhost:8080/consumer/status
# {"totalProcessed":40,"validOrders":20,"invalidOrders":20,"invalidRate":"50.00%"}

# See invalid order IDs
curl http://localhost:8080/consumer/invalid
```

### Step 7: Stop Application

Press `Ctrl+C` to stop the application.

### Step 8: PITR Restore

```bash
# Delete topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic orders --partitions 3 --replication-factor 1
'

# Restore with time window
docker compose --profile tools run --rm kafka-backup \
    restore --config /config/restore-basic.yaml

# Reset consumer group
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group demo-consumer --topic orders \
        --reset-offsets --to-earliest --execute
'
```

### Step 9: Restart Application

```bash
mvn spring-boot:run
```

### Step 10: Verify Clean State

```bash
# Clear local tracking (to see fresh reprocessing)
curl http://localhost:8080/consumer/clear

# Wait for reprocessing, then check
curl http://localhost:8080/consumer/status
# {"totalProcessed":20,"validOrders":20,"invalidOrders":0,"invalidRate":"0.00%"}

# Verify no invalid orders
curl http://localhost:8080/consumer/invalid
# {"count":0,"ids":[]}
```

## REST API Reference

### Producer Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/producer/start` | POST | Start scheduled production |
| `/producer/stop` | POST | Stop scheduled production |
| `/producer/status` | GET | Get producer status |
| `/producer/order` | POST | Produce single order |
| `/producer/inject-bad?count=N` | POST | Inject N bad orders |

### Consumer Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/consumer/status` | GET | Get processing statistics |
| `/consumer/processed` | GET | List processed order IDs |
| `/consumer/invalid` | GET | List invalid order IDs |
| `/consumer/recent` | GET | List recent orders |
| `/consumer/clear` | GET | Clear tracking data |

### Example API Usage

```bash
# Produce a specific order
curl -X POST http://localhost:8080/producer/order \
    -H "Content-Type: application/json" \
    -d '{"order_id": "CUSTOM-001", "amount": 500.00, "customer_id": "VIP-001"}'

# Get detailed status
curl http://localhost:8080/consumer/status | jq .

# Recent orders with formatting
curl http://localhost:8080/consumer/recent | jq '.[] | {id: .orderId, amount: .amount, valid: .valid}'
```

## Timeline Diagram

```
Timeline:
─────────────────────────────────────────────────────────────────────►

[T0]              [T1]           [T2]                 [T3]
 │                 │              │                    │
 │  Normal orders  │   Backup     │   Bad orders       │   PITR
 │  (20 valid)     │              │   (20 invalid)     │   restore
 │                 │              │                    │
 └─────────────────┴──────────────┴────────────────────┘

After restore at T3:
- Only orders from T0-T1 exist
- Consumer reprocesses 20 valid orders
- No invalid orders in system
```

## Key Observations

1. **REST Control**: Producer can be started/stopped via API
2. **Invalid Detection**: Consumer tracks and reports invalid orders
3. **PITR Recovery**: Bad data can be completely removed
4. **Stateless Consumer**: Consumer can be restarted and reprocess

## Configuration

### application.yml
```yaml
app:
  topic: orders
  producer:
    enabled: true
    rate-ms: 1000  # Produce every 1 second
  consumer:
    enabled: true
```

### Environment Variables
- `KAFKA_BOOTSTRAP_SERVERS`: Kafka broker address
- `PRODUCER_ENABLED`: Enable/disable producer (true/false)
- `CONSUMER_ENABLED`: Enable/disable consumer (true/false)
- `SERVER_PORT`: HTTP server port

## Cleanup

```bash
# Reset consumer group
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group demo-consumer --delete
'

# Clear backup
docker compose exec minio mc rm --recursive --force local/kafka-backups/
```

## Next Steps

- Try the [Python Demo](../../python/backup-restore-py/instructions.md)
- Review the [CLI PITR Rollback](../../cli/pitr-rollback-e2e/instructions.md) for more control
