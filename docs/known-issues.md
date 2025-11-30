# Known Issues

Current limitations and known issues with the kafka-backup demos.

## Demo Environment

### Docker Resource Requirements

**Issue:** Demos may fail on systems with limited resources.

**Minimum Requirements:**
- 4GB RAM allocated to Docker
- 10GB free disk space
- 2+ CPU cores

**Workaround:** Reduce parallelism in backup/restore configs:
```yaml
backup:
  max_concurrent_partitions: 1
```

---

### First Startup Delay

**Issue:** First `docker compose up` can take 2-3 minutes as images are pulled and built.

**Workaround:** Pre-pull images:
```bash
docker compose pull
docker compose build
```

---

### MinIO Bucket Creation Race

**Issue:** If `kafka-backup` runs before `minio-setup` completes, S3 errors occur.

**Workaround:** Wait for setup to complete:
```bash
docker compose up -d
docker compose logs -f minio-setup  # Wait for "Bucket created"
```

---

## kafka-backup Tool

### Offset Rollback Snapshot Format

**Issue:** The exact JSON format for offset snapshots may vary between kafka-backup versions.

**Workaround:** Use `--format json` to get structured output, and validate schema before parsing.

---

### Time Window Precision

**Issue:** PITR `time_window_end` requires milliseconds, not seconds.

**Correct:**
```bash
TIMESTAMP=$(date +%s000)  # 13 digits
```

**Incorrect:**
```bash
TIMESTAMP=$(date +%s)     # 10 digits - will be interpreted as year ~1970
```

---

### Large Message Backup Performance

**Issue:** Backing up topics with messages >1MB can be slow due to segment creation overhead.

**Workaround:** Increase segment size:
```yaml
backup:
  segment_max_bytes: 104857600  # 100MB
```

---

## Kafka CLI

### kafka-run-class Deprecated

**Issue:** Some demo scripts use `kafka-run-class.sh` which may show deprecation warnings.

**Alternative:**
```bash
# Instead of:
kafka-run-class.sh kafka.tools.GetOffsetShell

# Use:
kafka-get-offsets.sh  # If available
```

---

### Consumer Group Reset Requires Stop

**Issue:** Cannot reset offsets while consumers are active.

**Workaround:** Stop all applications before running offset reset commands.

---

## Java Demos

### State Directory Permissions

**Issue:** On some systems, `/tmp/kafka-streams-*` directories may have permission issues.

**Workaround:**
```bash
sudo rm -rf /tmp/kafka-streams-*
# Or change state.dir in config to user-writable location
```

---

### Maven Shade Plugin Warnings

**Issue:** Building with shade plugin shows "Duplicate class" warnings.

**Status:** These are benign warnings from Kafka client dependencies. The JAR works correctly.

---

## Spring Boot Demos

### Actuator Endpoints Not Exposed

**Issue:** Health endpoints return 404 without proper configuration.

**Fix:** Ensure application.yml includes:
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics
```

---

### State Store Not Immediately Available

**Issue:** `/counts` endpoint returns empty immediately after startup.

**Explanation:** Kafka Streams needs time to rebalance and restore state. Wait 10-30 seconds after startup.

---

## Python Demo

### librdkafka Compatibility

**Issue:** `confluent-kafka` requires matching librdkafka version.

**Workaround:** Use the version specified in requirements.txt or switch to `kafka-python`.

---

### Subprocess Timeout

**Issue:** `kafka-backup` commands may timeout in slow environments.

**Workaround:** Increase timeout in demo script:
```python
subprocess.run(cmd, timeout=300)  # 5 minutes
```

---

## Network Issues

### Host vs Container Networking

**Issue:** Demo scripts use different bootstrap servers depending on context.

| Context | Bootstrap Server |
|---------|------------------|
| Inside Docker (docker compose run) | `kafka-broker-1:9092` |
| From host machine | `localhost:9092` |

**Fix:** Use correct address for your context.

---

### Port Conflicts

**Issue:** Demo ports (8080, 9000, 9001, 9092) may conflict with other services.

**Workaround:** Change ports in docker-compose.yml or application configs.

---

## Reporting New Issues

If you encounter an issue not listed here:

1. Check the [troubleshooting guide](troubleshooting.md)
2. Review kafka-backup logs: `RUST_LOG=debug`
3. Check Kafka broker logs: `docker compose logs kafka-broker-1`
4. Open an issue at: https://github.com/osodevops/kafka-backup/issues

Include:
- Demo name and step where failure occurred
- Error messages (full output)
- Docker/Java/Python versions
- OS and architecture
