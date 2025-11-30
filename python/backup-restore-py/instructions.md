# Python Demo: Backup & Restore

**Core Feature:** Language-agnostic backup/restore validation with Python

## Overview

This demo shows that `kafka-backup` works regardless of the client language:

1. Python script produces JSON payloads to Kafka
2. Calls `kafka-backup` via subprocess
3. Validates data integrity after restore

## Prerequisites

- Python 3.9+
- pip
- Docker environment running (`docker compose up -d`)

## Setup

```bash
cd python/backup-restore-py

# Create virtual environment (recommended)
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

## Running the Demo

### Automated
```bash
python demo_backup_restore.py
```

### With custom options
```bash
python demo_backup_restore.py \
    --bootstrap-servers localhost:9092 \
    --messages 100
```

### Expected Output
```
============================================================
  Python Backup & Restore Demo
============================================================
  Bootstrap servers: localhost:9092
  Topic: orders
  Message count: 50

============================================================
  Step 1: Generating test messages
============================================================

✓ Generated 50 test messages
  Sample: {'order_id': 'PY-ORD-0001', 'customer_id': 'CUST-042', ...}

============================================================
  Step 2: Producing messages to Kafka
============================================================

✓ Produced 50 messages to 'orders'

============================================================
  Step 3: Running kafka-backup
============================================================

Running: docker compose --profile tools run --rm kafka-backup backup ...
✓ Backup completed

...

============================================================
  Demo Complete!
============================================================

✓ SUCCESS: All messages restored correctly!
  Original count: 50
  Restored count: 50
```

## Manual Walkthrough

### Step 1: Produce Messages

```python
from confluent_kafka import Producer
import json

producer = Producer({'bootstrap.servers': 'localhost:9092'})

for i in range(50):
    msg = {
        'order_id': f'PY-ORD-{i:04d}',
        'customer_id': f'CUST-{i % 100:03d}',
        'amount': 100.0 + i * 10
    }
    producer.produce('orders', json.dumps(msg))

producer.flush()
```

### Step 2: Run Backup

```bash
docker compose --profile tools run --rm kafka-backup \
    backup --config /config/backup-basic.yaml
```

### Step 3: Delete Topic

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders
'
```

### Step 4: Restore

```bash
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic orders --partitions 3 --replication-factor 1
'

docker compose --profile tools run --rm kafka-backup \
    restore --config /config/restore-basic.yaml
```

### Step 5: Consume and Validate

```python
from confluent_kafka import Consumer
import json

consumer = Consumer({
    'bootstrap.servers': 'localhost:9092',
    'group.id': 'python-verify',
    'auto.offset.reset': 'earliest'
})

consumer.subscribe(['orders'])
messages = []

while True:
    msg = consumer.poll(1.0)
    if msg is None:
        break
    if msg.error():
        continue
    messages.append(json.loads(msg.value()))

print(f"Restored {len(messages)} messages")
```

## Code Structure

```python
# Main components

def produce_messages(producer, messages):
    """Send messages to Kafka topic."""
    for msg in messages:
        producer.produce(TOPIC, json.dumps(msg))
    producer.flush()

def run_kafka_backup_command(args, description):
    """Execute kafka-backup via subprocess."""
    cmd = ["docker", "compose", "--profile", "tools",
           "run", "--rm", "kafka-backup"] + args
    subprocess.run(cmd)

def consume_messages(consumer):
    """Read all messages from topic."""
    messages = []
    while True:
        msg = consumer.poll(1.0)
        if msg is None:
            break
        messages.append(json.loads(msg.value()))
    return messages

def compare_messages(original, restored):
    """Validate data integrity."""
    original_sorted = sorted(original, key=lambda x: x['order_id'])
    restored_sorted = sorted(restored, key=lambda x: x['order_id'])
    return original_sorted == restored_sorted
```

## Using Different Python Kafka Libraries

### confluent-kafka (recommended)
```python
from confluent_kafka import Producer, Consumer
# High performance, native librdkafka bindings
```

### kafka-python
```python
from kafka import KafkaProducer, KafkaConsumer
# Pure Python implementation
```

### Example with kafka-python
```python
from kafka import KafkaProducer, KafkaConsumer
import json

# Producer
producer = KafkaProducer(
    bootstrap_servers='localhost:9092',
    value_serializer=lambda v: json.dumps(v).encode('utf-8')
)

producer.send('orders', {'order_id': 'TEST-001', 'amount': 100.0})
producer.flush()

# Consumer
consumer = KafkaConsumer(
    'orders',
    bootstrap_servers='localhost:9092',
    auto_offset_reset='earliest',
    value_deserializer=lambda m: json.loads(m.decode('utf-8'))
)

for msg in consumer:
    print(msg.value)
```

## Integration Patterns

### Subprocess Integration
```python
import subprocess

def backup_topic(topic, backup_id):
    result = subprocess.run([
        'kafka-backup', 'backup',
        '--config', '/path/to/backup.yaml'
    ], capture_output=True)
    return result.returncode == 0

def restore_topic(backup_id):
    result = subprocess.run([
        'kafka-backup', 'restore',
        '--config', '/path/to/restore.yaml'
    ], capture_output=True)
    return result.returncode == 0
```

### Docker Compose Integration
```python
def run_in_docker(command):
    return subprocess.run([
        'docker', 'compose', '--profile', 'tools',
        'run', '--rm', 'kafka-backup'
    ] + command)
```

## Key Observations

1. **Language Agnostic**: kafka-backup works with any Kafka client
2. **Data Integrity**: JSON payloads preserved exactly
3. **Subprocess Integration**: Easy to call from scripts
4. **Validation**: Compare original/restored data programmatically

## Cleanup

```bash
# Deactivate virtual environment
deactivate

# Remove virtual environment
rm -rf venv

# Reset consumer group
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group python-verify-group --delete
'
```

## Troubleshooting

### "No module named 'confluent_kafka'"
```bash
pip install confluent-kafka
```

### Connection refused
```bash
# Ensure Kafka is running
docker compose up -d
docker compose logs kafka-broker-1
```

### Messages not appearing
```bash
# Check topic exists
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --list
'
```

## Next Steps

- Explore the [CLI demos](../../cli/backup-basic/instructions.md) for more control
- Try [Java Streams PITR](../../java-streams/pitr-restore/instructions.md) for advanced patterns
