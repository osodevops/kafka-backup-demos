#!/bin/bash
# Quick Benchmark Runner
# Runs a fast smoke test of all scenarios (~2 minutes)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

./run_benchmarks.sh all quick
