# Troubleshooting Guide

Common issues and solutions for kafka-backup demos.

## Docker & Environment Issues

### Services not starting

**Symptom:** `docker compose up -d` fails or services crash

**Solutions:**
```bash
# Check available resources
docker system df

# Remove old containers and volumes
docker compose down -v
docker system prune -f

# Rebuild from scratch
docker compose build --no-cache
docker compose up -d
```

### Kafka broker not ready

**Symptom:** "Connection refused" or "Leader not available" errors

**Solutions:**
```bash
# Wait for broker to be ready
docker compose logs kafka-broker-1 | tail -20

# Check if broker is healthy
docker compose exec kafka-broker-1 /opt/kafka/bin/kafka-broker-api-versions.sh \
    --bootstrap-server localhost:9092

# Restart if needed
docker compose restart kafka-broker-1
sleep 30
```

### MinIO not accessible

**Symptom:** S3 connection errors

**Solutions:**
```bash
# Check MinIO is running
docker compose logs minio | tail -10

# Verify bucket exists
docker compose exec minio mc ls local/kafka-backups

# Recreate bucket if needed
docker compose exec minio mc mb local/kafka-backups --ignore-existing
```

---

## Kafka Issues

### Topic not found

**Symptom:** "Unknown topic or partition" error

**Solutions:**
```bash
# List existing topics
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --list
'

# Create missing topic
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create \
        --topic orders --partitions 3 --replication-factor 1
'
```

### Consumer group has active members

**Symptom:** Cannot reset offsets - "Consumer group has active members"

**Solutions:**
```bash
# Stop all consumers first
# Then reset
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group my-group --describe
'

# If group shows members, stop applications, then:
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group my-group --topic orders \
        --reset-offsets --to-earliest --execute
'
```

### Message too large

**Symptom:** "MessageSizeTooLargeException"

**Solutions:**
```bash
# Check topic config
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --topic large_messages
'

# Update topic config
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-configs.sh --bootstrap-server kafka-broker-1:9092 \
        --entity-type topics --entity-name large_messages \
        --alter --add-config max.message.bytes=15728640
'
```

---

## kafka-backup Issues

### Backup fails with permission error

**Symptom:** "Access Denied" or "Permission denied" for S3

**Solutions:**
```yaml
# Verify credentials in config
storage:
  access_key_id: minioadmin
  secret_access_key: minioadmin
  endpoint: http://minio:9000
  path_style: true  # Required for MinIO
```

### Restore produces no messages

**Symptom:** Restore completes but topic is empty

**Solutions:**
```bash
# Verify backup exists
docker compose --profile tools run --rm kafka-backup \
    list --path s3://kafka-backups/demo

# Check backup has data
docker compose --profile tools run --rm kafka-backup \
    describe --path s3://kafka-backups/demo --backup-id my-backup

# Verify topic config matches
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --topic orders
'
```

### PITR timestamp not working

**Symptom:** Restore includes data after the timestamp

**Solutions:**
```bash
# Verify timestamp format (milliseconds since epoch)
date +%s000  # Should be 13 digits

# Check messages have timestamps
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-console-consumer.sh --bootstrap-server kafka-broker-1:9092 \
        --topic orders --from-beginning --max-messages 5 \
        --property print.timestamp=true
'
```

### Offset reset not taking effect

**Symptom:** Consumer doesn't re-read expected messages

**Solutions:**
```bash
# Verify offsets were actually reset
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --group my-group
'

# Check consumer auto.offset.reset setting
# Should be 'earliest' for new groups, or offsets should be committed

# Clear consumer group entirely
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --group my-group --delete
'
```

---

## Java Demo Issues

### Maven build fails

**Symptom:** Dependency resolution errors

**Solutions:**
```bash
# Clear Maven cache
rm -rf ~/.m2/repository/org/apache/kafka

# Force update dependencies
mvn clean install -U

# Check Java version
java -version  # Should be 17+
```

### Streams app stuck in REBALANCING

**Symptom:** Application doesn't process messages

**Solutions:**
```bash
# Check for other instances
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \
        --describe --group orders-streams
'

# Clear state directory
rm -rf /tmp/kafka-streams-*

# Restart application
```

### ClassNotFoundException

**Symptom:** Missing class at runtime

**Solutions:**
```bash
# Ensure JAR has all dependencies
mvn clean package shade:shade

# Or run with classpath
mvn exec:java -Dexec.mainClass="com.osodevops.demo.DemoClass"
```

---

## Spring Boot Issues

### Application won't start

**Symptom:** Port already in use or Kafka connection error

**Solutions:**
```bash
# Change port
mvn spring-boot:run -Dspring-boot.run.arguments="--server.port=8081"

# Check Kafka connectivity
curl http://localhost:8080/actuator/health
```

### REST endpoints not responding

**Symptom:** 404 or connection refused

**Solutions:**
```bash
# Check application started
curl http://localhost:8080/actuator/health

# Verify endpoint paths
curl http://localhost:8080/counts  # Not /api/counts
```

---

## Python Demo Issues

### confluent-kafka install fails

**Symptom:** Build errors during pip install

**Solutions:**
```bash
# On macOS
brew install librdkafka
pip install confluent-kafka

# On Ubuntu/Debian
sudo apt-get install librdkafka-dev
pip install confluent-kafka

# Alternative: use kafka-python
pip install kafka-python
```

### Connection timeout

**Symptom:** Python script hangs on connect

**Solutions:**
```python
# Use correct bootstrap servers
# Inside Docker network: kafka-broker-1:9092
# From host: localhost:9092

# Add timeout to consumer
consumer = Consumer({
    'bootstrap.servers': 'localhost:9092',
    'session.timeout.ms': 6000,
    'socket.timeout.ms': 3000
})
```

---

## General Tips

### Enable debug logging

**kafka-backup:**
```bash
RUST_LOG=debug docker compose --profile tools run --rm kafka-backup ...
```

**Java:**
```bash
mvn exec:java -Dorg.slf4j.simpleLogger.defaultLogLevel=debug
```

**Spring Boot:**
```yaml
logging:
  level:
    org.apache.kafka: DEBUG
```

### Reset everything

```bash
# Nuclear option - reset entire demo environment
docker compose down -v
rm -rf /tmp/kafka-streams-*
docker compose up -d
sleep 30  # Wait for services
```

### Check resource usage

```bash
# Monitor Docker resources
docker stats

# Check disk space
df -h

# Kafka log size
docker compose exec kafka-broker-1 du -sh /tmp/kafka-logs
```
