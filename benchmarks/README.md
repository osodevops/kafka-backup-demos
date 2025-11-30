# kafka-backup Benchmarks

Performance benchmarks for OSO Kafka Backup demonstrating throughput, latency, and compression capabilities.

## Quick Start

```bash
# Run quick benchmark (~2 minutes)
./run_quick_benchmark.sh

# Run full benchmark suite (~15 minutes)
./run_benchmarks.sh all standard
```

## Performance Targets

| Metric | Target | Description |
|--------|--------|-------------|
| Throughput | 100+ MB/s | Per partition with 3+ partitions |
| Checkpoint p99 | <100ms | Offset checkpoint latency |
| Compression Ratio | 3-5x | With zstd level 3 |
| Memory | <500MB | For 4 concurrent partitions |

## Benchmark Scenarios

| Scenario | Description | Duration |
|----------|-------------|----------|
| [Throughput](scenarios/throughput/) | Maximum backup/restore speed | 2-5 min |
| [Compression](scenarios/compression/) | Algorithm comparison | 3-5 min |
| [Latency](scenarios/latency/) | Checkpoint & segment latencies | 2-3 min |
| [Large Messages](scenarios/large-messages/) | 100KB-5MB message handling | 2-3 min |
| [Scaling](scenarios/concurrent-partitions/) | Partition count scaling | 5-10 min |

## Running Benchmarks

### Quick Benchmark (Smoke Test)
```bash
./run_quick_benchmark.sh
```
- Uses 100MB of test data
- Single iteration per scenario
- ~2 minutes total

### Standard Benchmark
```bash
./run_benchmarks.sh all standard
```
- Uses 500MB of test data
- 3 iterations per scenario
- ~10 minutes total

### Full Benchmark
```bash
./run_benchmarks.sh all full
```
- Uses 1GB of test data
- 5 iterations per scenario
- ~20 minutes total

### Individual Scenarios
```bash
./run_benchmarks.sh throughput quick
./run_benchmarks.sh compression standard
./run_benchmarks.sh latency full
```

## Results

Results are saved to `results/` directory:
- `results/benchmark-YYYYMMDD-HHMMSS.json` - Raw metrics
- `results/benchmark-YYYYMMDD-HHMMSS.md` - Markdown report

### Sample Results

```
============================================================
  kafka-backup Benchmark Results
============================================================
  Profile: quick (100MB, 1 iteration)
  Date: 2025-01-15 12:00:00

  THROUGHPUT
  ──────────────────────────────────────
  Backup:  125.3 MB/s (3 partitions)
  Restore: 142.7 MB/s (3 partitions)

  COMPRESSION (zstd-3)
  ──────────────────────────────────────
  Ratio: 3.8x
  Size:  26.3 MB (from 100 MB)

  LATENCY PERCENTILES
  ──────────────────────────────────────
  Checkpoint: p50=12ms p95=28ms p99=45ms
  Segment:    p50=8ms  p95=15ms p99=22ms

  STATUS: ✓ ALL TARGETS MET
============================================================
```

## Metrics Collected

### Throughput Metrics
- MB/s (megabytes per second)
- Records/second
- Total time elapsed

### Latency Metrics
- Checkpoint latency (p50, p95, p99, max)
- Segment write latency (p50, p95, p99, max)
- Fetch latency (p50, p95, p99, max)

### Compression Metrics
- Compression ratio (uncompressed/compressed)
- Compressed size
- Compression time overhead

### Resource Metrics
- Memory usage (if available)
- Error counts

## Prerequisites

- Docker environment running: `docker compose up -d`
- At least 2GB free disk space
- Python 3.8+ (for report generation)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Benchmark Runner                          │
│  run_benchmarks.sh                                          │
│    ├── generate_data.sh    (create test data)               │
│    ├── scenario/run.sh     (execute benchmark)              │
│    ├── collect_metrics.sh  (capture Prometheus metrics)     │
│    └── generate_report.py  (create markdown report)         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Docker Environment                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────────┐  │
│  │  Kafka   │  │  MinIO   │  │     kafka-backup         │  │
│  │  :9092   │  │  :9000   │  │  (Prometheus :9090)      │  │
│  └──────────┘  └──────────┘  └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Interpreting Results

### Throughput
- **Good**: >100 MB/s with 3+ partitions
- **Acceptable**: 50-100 MB/s
- **Needs Investigation**: <50 MB/s

### Compression Ratio
- **Excellent**: >4x (highly compressible data)
- **Good**: 3-4x (typical JSON/Avro)
- **Expected for binary**: 1.5-2x

### Latency
- **Excellent**: p99 <50ms
- **Good**: p99 <100ms
- **Needs Investigation**: p99 >100ms

## Troubleshooting

### Benchmark hangs
```bash
# Check Kafka is ready
docker compose logs kafka-broker-1 | tail -20

# Restart environment
docker compose down && docker compose up -d
```

### Low throughput
- Check available disk space
- Ensure no other processes competing for I/O
- Try reducing `max_concurrent_partitions`

### High latency
- Check MinIO connectivity
- Verify network isn't saturated
- Monitor Docker resource limits

## See Also

- [Detailed Instructions](instructions.md)
- [Troubleshooting Guide](../docs/troubleshooting.md)
- [kafka-backup Performance PRD](https://github.com/osodevops/kafka-backup/blob/main/docs/performance-prd.md)
