#!/usr/bin/env python3
"""
Generate markdown benchmark report from results JSON.
Usage: python generate_report.py results.json > report.md
"""

import json
import sys
from datetime import datetime
from pathlib import Path


def load_results(filepath: str) -> dict:
    """Load benchmark results from JSON file."""
    with open(filepath, 'r') as f:
        return json.load(f)


def format_duration(seconds: float) -> str:
    """Format duration in human-readable format."""
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes = int(seconds // 60)
    secs = seconds % 60
    return f"{minutes}m {secs:.1f}s"


def format_size(mb: float) -> str:
    """Format size in appropriate units."""
    if mb >= 1024:
        return f"{mb/1024:.2f} GB"
    return f"{mb:.1f} MB"


def check_target(value: float, target: float, higher_is_better: bool = True) -> str:
    """Check if value meets target and return status emoji."""
    if higher_is_better:
        return "✓ PASS" if value >= target else "✗ FAIL"
    else:
        return "✓ PASS" if value <= target else "✗ FAIL"


def generate_report(results: dict) -> str:
    """Generate markdown report from results."""
    lines = []

    # Header
    lines.append("# kafka-backup Benchmark Results")
    lines.append("")
    lines.append(f"**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"**Profile:** {results.get('profile', 'unknown')} ({results.get('data_size_mb', 0)}MB, {results.get('iterations', 1)} iterations)")
    lines.append("")

    # Summary table
    lines.append("## Summary")
    lines.append("")
    lines.append("| Metric | Result | Target | Status |")
    lines.append("|--------|--------|--------|--------|")

    scenarios = results.get('scenarios', {})

    # Throughput
    throughput = scenarios.get('throughput', {})
    if throughput:
        backup_mbps = throughput.get('backup_mbps', 0)
        lines.append(f"| Throughput (Backup) | {backup_mbps:.1f} MB/s | 100 MB/s | {check_target(backup_mbps, 100)} |")

    # Compression
    compression = scenarios.get('compression', {})
    if compression:
        zstd = compression.get('zstd', {})
        ratio = zstd.get('ratio', 0)
        lines.append(f"| Compression Ratio | {ratio:.1f}x | 3-5x | {check_target(ratio, 3)} |")

    # Latency
    latency = scenarios.get('latency', {})
    if latency:
        checkpoint_p99 = latency.get('checkpoint_p99_ms', 0)
        lines.append(f"| Checkpoint p99 | {checkpoint_p99:.0f}ms | <100ms | {check_target(checkpoint_p99, 100, False)} |")

    lines.append("")

    # Throughput details
    if throughput:
        lines.append("## Throughput Results")
        lines.append("")
        lines.append("| Partitions | Backup MB/s | Restore MB/s | Duration |")
        lines.append("|------------|-------------|--------------|----------|")

        for partitions in [1, 3, 8]:
            key = f"partitions_{partitions}"
            if key in throughput:
                data = throughput[key]
                lines.append(f"| {partitions} | {data.get('backup_mbps', 0):.1f} | {data.get('restore_mbps', 0):.1f} | {format_duration(data.get('duration_s', 0))} |")

        # Use main results if partition breakdown not available
        if 'partitions_1' not in throughput:
            lines.append(f"| 3 | {throughput.get('backup_mbps', 0):.1f} | {throughput.get('restore_mbps', 0):.1f} | {format_duration(throughput.get('duration_s', 0))} |")

        lines.append("")

    # Compression details
    if compression:
        lines.append("## Compression Comparison")
        lines.append("")
        lines.append("| Algorithm | Ratio | Backup Time | Compressed Size |")
        lines.append("|-----------|-------|-------------|-----------------|")

        for algo in ['zstd', 'lz4', 'none']:
            if algo in compression:
                data = compression[algo]
                ratio = data.get('ratio', 1.0)
                duration = format_duration(data.get('duration_s', 0))
                size = format_size(data.get('compressed_mb', 0))
                lines.append(f"| {algo} | {ratio:.1f}x | {duration} | {size} |")

        lines.append("")

    # Latency details
    if latency:
        lines.append("## Latency Percentiles")
        lines.append("")
        lines.append("| Operation | p50 | p95 | p99 | max |")
        lines.append("|-----------|-----|-----|-----|-----|")

        for op in ['checkpoint', 'segment_write', 'fetch']:
            if f'{op}_p50_ms' in latency:
                p50 = latency.get(f'{op}_p50_ms', 0)
                p95 = latency.get(f'{op}_p95_ms', 0)
                p99 = latency.get(f'{op}_p99_ms', 0)
                max_val = latency.get(f'{op}_max_ms', 0)
                lines.append(f"| {op.replace('_', ' ').title()} | {p50:.0f}ms | {p95:.0f}ms | {p99:.0f}ms | {max_val:.0f}ms |")

        lines.append("")

    # Large messages
    large = scenarios.get('large-messages', {})
    if large:
        lines.append("## Large Message Performance")
        lines.append("")
        lines.append("| Message Size | Count | Backup MB/s | Restore MB/s |")
        lines.append("|--------------|-------|-------------|--------------|")

        for size in ['100kb', '1mb', '5mb']:
            if size in large:
                data = large[size]
                lines.append(f"| {size.upper()} | {data.get('count', 0)} | {data.get('backup_mbps', 0):.1f} | {data.get('restore_mbps', 0):.1f} |")

        lines.append("")

    # Scaling
    scaling = scenarios.get('concurrent-partitions', {})
    if scaling:
        lines.append("## Partition Scaling")
        lines.append("")
        lines.append("| Partitions | Throughput | Scaling Factor |")
        lines.append("|------------|------------|----------------|")

        baseline = scaling.get('1', {}).get('backup_mbps', 1)
        for p in ['1', '4', '8']:
            if p in scaling:
                mbps = scaling[p].get('backup_mbps', 0)
                factor = mbps / baseline if baseline > 0 else 0
                lines.append(f"| {p} | {mbps:.1f} MB/s | {factor:.1f}x |")

        lines.append("")

    # Footer
    lines.append("---")
    lines.append("")
    lines.append("*Generated by kafka-backup-demos benchmark suite*")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print("Usage: python generate_report.py results.json", file=sys.stderr)
        sys.exit(1)

    results_file = sys.argv[1]

    if not Path(results_file).exists():
        # Create empty results for now
        results = {
            "profile": "quick",
            "data_size_mb": 100,
            "iterations": 1,
            "scenarios": {
                "throughput": {"backup_mbps": 0, "restore_mbps": 0, "duration_s": 0},
                "compression": {},
                "latency": {},
            }
        }
    else:
        results = load_results(results_file)

    print(generate_report(results))


if __name__ == '__main__':
    main()
