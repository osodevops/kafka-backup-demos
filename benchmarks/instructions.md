# Benchmarks Demo Instructions

This guide walks you through running performance benchmarks for the OSO Kafka Backup tool.

## Prerequisites

- Docker and Docker Compose installed
- At least 4GB RAM available for Docker
- 10GB+ free disk space for benchmark data
- `bc` and `python3` installed on the host

## Quick Start

### 1. Start the Environment

```bash
cd kafka-backup-demos
docker compose up -d
```

Wait for all services to be healthy:

```bash
docker compose ps
```

### 2. Run Quick Benchmark

For a fast smoke test (~2-3 minutes):

```bash
./benchmarks/run_quick_benchmark.sh
```

This runs a minimal throughput test with 100MB of data.

### 3. Run Full Benchmark Suite

For comprehensive performance testing (~15-30 minutes):

```bash
./benchmarks/run_full_benchmark.sh
```

Or with custom parameters:

```bash
./benchmarks/run_benchmarks.sh --profile standard --data-size 500
```

## Benchmark Scenarios

### Throughput (`scenarios/throughput/`)

Measures maximum backup and restore speed.

**What it tests:**
- Backup throughput (MB/s)
- Restore throughput (MB/s)
- End-to-end data integrity

**Expected results:**
- Backup: 50-150 MB/s (depends on storage backend)
- Restore: 40-120 MB/s

### Compression (`scenarios/compression/`)

Compares compression algorithms: zstd, lz4, none.

**What it tests:**
- Compression ratio
- Compression/decompression speed impact
- Storage space savings

**Expected results:**
- zstd: 3-5x compression ratio, slight CPU overhead
- lz4: 2-3x compression ratio, minimal CPU impact
- none: 1x ratio, fastest throughput

### Latency (`scenarios/latency/`)

Measures checkpoint and segment write latencies.

**What it tests:**
- Checkpoint latency percentiles (p50, p95, p99, max)
- Segment write latency percentiles
- Tail latency characteristics

**Expected results:**
- Checkpoint p99: <100ms
- Segment write p99: <50ms

### Large Messages (`scenarios/large-messages/`)

Tests performance with varying message sizes.

**What it tests:**
- 100KB messages
- 1MB messages
- 5MB messages

**Expected results:**
- Throughput scales with message size
- No message corruption or truncation

### Concurrent Partitions (`scenarios/concurrent-partitions/`)

Tests scaling with parallel partition processing.

**What it tests:**
- 1 partition (baseline)
- 4 partitions
- 8 partitions

**Expected results:**
- Near-linear scaling up to available CPU cores
- 4 partitions: ~3-4x baseline
- 8 partitions: ~6-8x baseline

## Understanding Results

### Output Files

After running benchmarks, results are saved to:

```
benchmarks/results/
├── benchmark-results-YYYYMMDD-HHMMSS.json  # Raw data
├── benchmark-report-YYYYMMDD-HHMMSS.md     # Human-readable report
└── prometheus-metrics-*.json               # Detailed metrics (if collected)
```

### Key Metrics

| Metric | Description | Target |
|--------|-------------|--------|
| `backup_mbps` | Backup throughput | >50 MB/s |
| `restore_mbps` | Restore throughput | >40 MB/s |
| `checkpoint_p99_ms` | 99th percentile checkpoint latency | <100ms |
| `compression_ratio` | Data size reduction | >2x |
| `scaling_factor` | Multi-partition speedup | >0.8x linear |

### Sample Report Output

```
# Kafka Backup Benchmark Report
Generated: 2024-01-15 10:30:00

## Environment
- Profile: standard
- Data Size: 500MB
- Partitions: 3

## Results Summary

### Throughput
- Backup: 85.2 MB/s
- Restore: 72.4 MB/s

### Compression (zstd)
- Ratio: 3.8x
- Compressed Size: 131.6 MB

### Latency
- Checkpoint p99: 45ms
- Segment Write p99: 22ms
```

## Running Individual Scenarios

You can run scenarios independently:

```bash
# Set up environment variables
export BENCHMARK_DATA_SIZE=100
export BENCHMARK_RESULTS_FILE="./benchmarks/results/my-test.json"

# Initialize results file
echo '{"scenarios": {}}' > $BENCHMARK_RESULTS_FILE

# Generate test data first
./benchmarks/tools/generate_data.sh 100 10000

# Run specific scenario
./benchmarks/scenarios/throughput/run.sh
./benchmarks/scenarios/compression/run.sh
./benchmarks/scenarios/latency/run.sh
```

## Customization

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BENCHMARK_PROFILE` | quick | Test profile (quick/standard/full) |
| `BENCHMARK_DATA_SIZE` | 100 | Test data size in MB |
| `BENCHMARK_MESSAGE_COUNT` | 10000 | Number of test messages |
| `BENCHMARK_ITERATIONS` | 1 | Repeat count for averaging |
| `BENCHMARK_RESULTS_FILE` | auto-generated | Output file path |

### Custom Test Data

Generate specific amounts of test data:

```bash
# Generate 1GB of data with 100,000 messages
./benchmarks/tools/generate_data.sh 1000 100000
```

### Prometheus Metrics Collection

The kafka-backup tool exposes Prometheus metrics on port 9090:

```bash
# Collect metrics during benchmark
./benchmarks/tools/collect_metrics.sh &
COLLECTOR_PID=$!

# Run benchmark
./benchmarks/scenarios/throughput/run.sh

# Stop collector
kill $COLLECTOR_PID
```

Available metrics:
- `kafka_backup_records_processed_total`
- `kafka_backup_bytes_processed_total`
- `kafka_backup_checkpoint_duration_seconds`
- `kafka_backup_segment_write_duration_seconds`
- `kafka_backup_compression_ratio`

## Troubleshooting

### Benchmark hangs or times out

```bash
# Check container status
docker compose ps

# View kafka-backup logs
docker compose logs kafka-backup

# Restart environment
docker compose down -v
docker compose up -d
```

### Low throughput results

1. Ensure Docker has sufficient resources (4GB+ RAM)
2. Check for competing workloads on the host
3. Verify MinIO is healthy: `docker compose exec minio mc admin info local`

### Missing results

```bash
# Verify results directory exists
mkdir -p benchmarks/results

# Check file permissions
ls -la benchmarks/results/
```

### Out of disk space

```bash
# Clean up old backups
docker compose exec minio mc rm --recursive --force local/kafka-backups/

# Clean up Kafka data
docker compose down -v
docker compose up -d
```

## CI/CD Integration

Example GitHub Actions workflow:

```yaml
jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Start environment
        run: docker compose up -d

      - name: Wait for services
        run: sleep 30

      - name: Run quick benchmark
        run: ./benchmarks/run_quick_benchmark.sh

      - name: Upload results
        uses: actions/upload-artifact@v3
        with:
          name: benchmark-results
          path: benchmarks/results/
```

## Performance Tuning Tips

1. **Increase partitions** for higher throughput (up to CPU count)
2. **Use zstd compression** for best space/speed tradeoff
3. **Tune segment_max_bytes** based on your message patterns
4. **Adjust checkpoint_interval_ms** for latency vs durability tradeoff
5. **Use local storage** for maximum throughput (vs network storage)
