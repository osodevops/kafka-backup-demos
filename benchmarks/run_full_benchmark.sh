#!/bin/bash
# Full Benchmark Runner
# Runs comprehensive benchmark suite (~20 minutes)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

./run_benchmarks.sh all full
