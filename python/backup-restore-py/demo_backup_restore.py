#!/usr/bin/env python3
"""
Python Backup & Restore Demo

Demonstrates language-agnostic backup/restore validation with Python:
1. Produce JSON payloads to 'orders' topic
2. Call kafka-backup via subprocess to perform backup
3. Delete and recreate topic
4. Run kafka-backup restore
5. Consume all records and compare with original list

Usage:
    pip install -r requirements.txt
    python demo_backup_restore.py [--bootstrap-servers localhost:9092]
"""

import argparse
import json
import subprocess
import sys
import time
from typing import List, Dict, Any
from confluent_kafka import Producer, Consumer, KafkaError

# Configuration
TOPIC = "orders"
BACKUP_ID = "python-backup"
BACKUP_PATH = "s3://kafka-backups/python-demo"
NUM_MESSAGES = 50


def print_step(step: int, message: str):
    """Print a formatted step message."""
    print(f"\n{'=' * 60}")
    print(f"  Step {step}: {message}")
    print(f"{'=' * 60}\n")


def print_success(message: str):
    """Print a success message."""
    print(f"✓ {message}")


def print_error(message: str):
    """Print an error message."""
    print(f"✗ {message}")


def create_producer(bootstrap_servers: str) -> Producer:
    """Create a Kafka producer."""
    return Producer({
        'bootstrap.servers': bootstrap_servers,
        'client.id': 'python-demo-producer'
    })


def create_consumer(bootstrap_servers: str, group_id: str) -> Consumer:
    """Create a Kafka consumer."""
    return Consumer({
        'bootstrap.servers': bootstrap_servers,
        'group.id': group_id,
        'auto.offset.reset': 'earliest',
        'enable.auto.commit': True
    })


def produce_messages(producer: Producer, messages: List[Dict[str, Any]]) -> None:
    """Produce messages to Kafka topic."""
    delivered = 0

    def delivery_callback(err, msg):
        nonlocal delivered
        if err:
            print_error(f"Delivery failed: {err}")
        else:
            delivered += 1

    for msg in messages:
        producer.produce(
            TOPIC,
            key=msg['order_id'],
            value=json.dumps(msg),
            callback=delivery_callback
        )

    # Wait for all messages to be delivered
    producer.flush(timeout=30)
    print_success(f"Produced {delivered} messages to '{TOPIC}'")


def consume_messages(consumer: Consumer, timeout: float = 30.0) -> List[Dict[str, Any]]:
    """Consume all messages from the topic."""
    consumer.subscribe([TOPIC])
    messages = []
    start_time = time.time()
    empty_polls = 0
    max_empty_polls = 10

    while empty_polls < max_empty_polls:
        if time.time() - start_time > timeout:
            print(f"  Timeout reached after {timeout}s")
            break

        msg = consumer.poll(1.0)

        if msg is None:
            empty_polls += 1
            continue

        if msg.error():
            if msg.error().code() == KafkaError._PARTITION_EOF:
                empty_polls += 1
                continue
            print_error(f"Consumer error: {msg.error()}")
            continue

        empty_polls = 0
        try:
            value = json.loads(msg.value().decode('utf-8'))
            messages.append(value)
        except json.JSONDecodeError:
            print(f"  Warning: Could not parse message as JSON")

    consumer.close()
    return messages


def run_kafka_backup_command(args: List[str], description: str) -> bool:
    """Run a kafka-backup command via docker compose."""
    cmd = [
        "docker", "compose", "--profile", "tools",
        "run", "--rm", "kafka-backup"
    ] + args

    print(f"Running: {' '.join(cmd)}")

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120
        )

        if result.returncode == 0:
            print_success(description)
            if result.stdout:
                print(result.stdout[:500])  # Limit output
            return True
        else:
            print_error(f"{description} failed")
            if result.stderr:
                print(result.stderr[:500])
            return False

    except subprocess.TimeoutExpired:
        print_error(f"Command timed out: {description}")
        return False
    except Exception as e:
        print_error(f"Error running command: {e}")
        return False


def run_kafka_cli_command(cmd: str, description: str) -> bool:
    """Run a Kafka CLI command via docker compose."""
    full_cmd = [
        "docker", "compose", "--profile", "tools",
        "run", "--rm", "kafka-cli",
        "bash", "-c", cmd
    ]

    try:
        result = subprocess.run(
            full_cmd,
            capture_output=True,
            text=True,
            timeout=60
        )

        if result.returncode == 0:
            print_success(description)
            return True
        else:
            print_error(f"{description} failed: {result.stderr}")
            return False

    except Exception as e:
        print_error(f"Error: {e}")
        return False


def generate_test_messages(count: int) -> List[Dict[str, Any]]:
    """Generate test order messages."""
    import random
    messages = []

    for i in range(1, count + 1):
        messages.append({
            'order_id': f'PY-ORD-{i:04d}',
            'customer_id': f'CUST-{random.randint(1, 100):03d}',
            'product': random.choice(['Widget', 'Gadget', 'Device', 'Tool']),
            'amount': round(random.uniform(10.0, 1000.0), 2),
            'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        })

    return messages


def compare_messages(original: List[Dict], restored: List[Dict]) -> bool:
    """Compare original and restored messages."""
    if len(original) != len(restored):
        print_error(f"Message count mismatch: {len(original)} vs {len(restored)}")
        return False

    # Sort by order_id for comparison
    original_sorted = sorted(original, key=lambda x: x['order_id'])
    restored_sorted = sorted(restored, key=lambda x: x['order_id'])

    mismatches = 0
    for orig, rest in zip(original_sorted, restored_sorted):
        # Compare key fields
        if orig['order_id'] != rest['order_id']:
            print(f"  Mismatch: {orig['order_id']} != {rest['order_id']}")
            mismatches += 1
        elif orig['amount'] != rest['amount']:
            print(f"  Amount mismatch for {orig['order_id']}")
            mismatches += 1

    if mismatches == 0:
        print_success(f"All {len(original)} messages match!")
        return True
    else:
        print_error(f"{mismatches} mismatches found")
        return False


def main():
    parser = argparse.ArgumentParser(description='Python Kafka Backup/Restore Demo')
    parser.add_argument('--bootstrap-servers', default='localhost:9092',
                        help='Kafka bootstrap servers')
    parser.add_argument('--messages', type=int, default=NUM_MESSAGES,
                        help='Number of messages to produce')
    args = parser.parse_args()

    print("=" * 60)
    print("  Python Backup & Restore Demo")
    print("=" * 60)
    print(f"  Bootstrap servers: {args.bootstrap_servers}")
    print(f"  Topic: {TOPIC}")
    print(f"  Message count: {args.messages}")
    print()

    # Step 1: Generate test messages
    print_step(1, "Generating test messages")
    original_messages = generate_test_messages(args.messages)
    print_success(f"Generated {len(original_messages)} test messages")
    print(f"  Sample: {original_messages[0]}")

    # Step 2: Produce messages
    print_step(2, "Producing messages to Kafka")
    producer = create_producer(args.bootstrap_servers)
    produce_messages(producer, original_messages)

    # Step 3: Run backup
    print_step(3, "Running kafka-backup")

    # Create backup config
    backup_config = f"""
mode: backup
backup_id: "{BACKUP_ID}"

source:
  bootstrap_servers:
    - kafka-broker-1:9092
  topics:
    include:
      - {TOPIC}

storage:
  backend: s3
  bucket: kafka-backups
  region: us-east-1
  prefix: python-demo
  endpoint: http://minio:9000
  path_style: true
  access_key_id: minioadmin
  secret_access_key: minioadmin

backup:
  compression: zstd
"""

    # Write config to temp file and mount it
    with open('/tmp/python-backup.yaml', 'w') as f:
        f.write(backup_config)

    success = run_kafka_backup_command(
        ['backup', '--config', '/config/backup-basic.yaml'],
        "Backup completed"
    )

    if not success:
        print_error("Backup failed, exiting")
        sys.exit(1)

    # Step 4: Delete topic
    print_step(4, "Deleting topic (simulating data loss)")
    run_kafka_cli_command(
        f"kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic {TOPIC}",
        "Topic deleted"
    )
    time.sleep(3)

    # Step 5: Recreate topic
    print_step(5, "Recreating empty topic")
    run_kafka_cli_command(
        f"kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic {TOPIC} --partitions 3 --replication-factor 1",
        "Topic recreated"
    )
    time.sleep(2)

    # Step 6: Restore
    print_step(6, "Restoring from backup")
    success = run_kafka_backup_command(
        ['restore', '--config', '/config/restore-basic.yaml'],
        "Restore completed"
    )

    if not success:
        print_error("Restore failed, exiting")
        sys.exit(1)

    time.sleep(2)

    # Step 7: Consume and compare
    print_step(7, "Consuming and comparing messages")
    consumer = create_consumer(args.bootstrap_servers, 'python-verify-group')
    restored_messages = consume_messages(consumer)
    print(f"  Consumed {len(restored_messages)} messages")

    # Step 8: Validate
    print_step(8, "Validating restored data")
    success = compare_messages(original_messages, restored_messages)

    # Summary
    print("\n" + "=" * 60)
    print("  Demo Complete!")
    print("=" * 60)

    if success:
        print("\n✓ SUCCESS: All messages restored correctly!")
        print(f"  Original count: {len(original_messages)}")
        print(f"  Restored count: {len(restored_messages)}")
    else:
        print("\n✗ FAILURE: Message validation failed")
        sys.exit(1)

    print("""
Key Takeaways:
  1. kafka-backup is language-agnostic
  2. Python clients can integrate via subprocess
  3. Data integrity is preserved through backup/restore
  4. JSON payloads are fully restored
""")


if __name__ == '__main__':
    main()
