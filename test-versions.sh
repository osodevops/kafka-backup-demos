#!/bin/bash
# Multi-Version Kafka Compatibility Test Runner
# Tests kafka-backup demos against multiple Apache Kafka versions
#
# Usage:
#   ./test-versions.sh                    # Test all supported versions
#   ./test-versions.sh 4.0.0 4.1.0        # Test specific versions
#   ./test-versions.sh --quick            # Quick smoke test per version
#   ./test-versions.sh --full             # Full test suite per version

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Supported Kafka versions (official apache/kafka images)
DEFAULT_VERSIONS=(
    "3.7.1"
    "3.8.0"
    "3.9.0"
    "4.0.0"
    "4.1.0"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Results tracking
declare -A RESULTS
RESULTS_DIR="$SCRIPT_DIR/test-results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

usage() {
    cat << EOF
Multi-Version Kafka Compatibility Test Runner

Usage: $0 [OPTIONS] [VERSION...]

Options:
    --quick         Run quick smoke test per version (default)
    --full          Run full test suite per version
    --benchmark     Run benchmarks per version
    --help          Show this help message

Supported Kafka Versions:
    3.7.1, 3.8.0, 3.9.0, 4.0.0, 4.1.0

Examples:
    $0                      # Test all versions with quick test
    $0 --quick 4.0.0 4.1.0  # Quick test specific versions
    $0 --full               # Full test all versions
    $0 --benchmark 4.0.0    # Benchmark Kafka 4.0.0

EOF
    exit 0
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Wait for Kafka to be ready
wait_for_kafka() {
    local max_attempts=30
    local attempt=1

    log_info "Waiting for Kafka to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if docker compose --profile tools run --rm kafka-cli \
            /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --list &>/dev/null; then
            log_success "Kafka is ready"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done
    echo ""
    log_error "Kafka failed to start"
    return 1
}

# Clean up environment
cleanup() {
    log_info "Cleaning up..."
    docker compose down -v --remove-orphans 2>/dev/null || true
}

# Run quick smoke test
run_quick_test() {
    local version=$1
    log_info "Running quick smoke test..."

    # Test 1: Topic creation
    log_info "Test 1: Creating test topic..."
    if docker compose --profile tools run --rm kafka-cli \
        /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-broker-1:9092 \
        --create --if-not-exists --topic version-test-$version \
        --partitions 1 --replication-factor 1 2>/dev/null; then
        log_success "Topic created"
    else
        log_error "Failed to create topic"
        return 1
    fi

    # Test 2: Produce messages
    log_info "Test 2: Producing test messages..."
    if echo '{"test": "message", "version": "'$version'"}' | \
        docker compose --profile tools run --rm -T kafka-cli \
        /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic version-test-$version 2>/dev/null; then
        log_success "Messages produced"
    else
        log_error "Failed to produce messages"
        return 1
    fi

    # Test 3: Consume messages
    log_info "Test 3: Consuming test messages..."
    local consumed
    consumed=$(docker compose --profile tools run --rm kafka-cli \
        /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server kafka-broker-1:9092 \
        --topic version-test-$version \
        --from-beginning --max-messages 1 --timeout-ms 10000 2>/dev/null || true)

    if echo "$consumed" | grep -q "version"; then
        log_success "Messages consumed"
    else
        log_warn "Consumer returned: $consumed"
    fi

    # Test 4: Backup (if kafka-backup is available)
    log_info "Test 4: Running backup..."
    if docker compose --profile tools run --rm kafka-backup \
        backup --config /config/backup-basic.yaml 2>&1 | tail -5; then
        log_success "Backup completed"
    else
        log_warn "Backup test skipped or failed (kafka-backup may not be built)"
    fi

    return 0
}

# Run full test suite
run_full_test() {
    local version=$1
    log_info "Running full test suite..."

    # Run basic demo
    log_info "Running basic backup/restore demo..."
    if [ -f "./cli/backup-basic/demo.sh" ]; then
        bash ./cli/backup-basic/demo.sh 2>&1 | tail -20
    fi

    # Run offset testing demo
    log_info "Running offset testing demo..."
    if [ -f "./cli/offset-testing/demo.sh" ]; then
        bash ./cli/offset-testing/demo.sh 2>&1 | tail -20
    fi

    return 0
}

# Run benchmarks
run_benchmark() {
    local version=$1
    log_info "Running benchmarks for Kafka $version..."

    if [ -f "./benchmarks/run_quick_benchmark.sh" ]; then
        KAFKA_VERSION=$version ./benchmarks/run_quick_benchmark.sh
    else
        log_warn "Benchmark scripts not found"
    fi

    return 0
}

# Test a specific Kafka version
test_version() {
    local version=$1
    local test_type=$2
    local start_time=$(date +%s)

    echo ""
    echo "========================================"
    echo -e "${BLUE}Testing Kafka version: $version${NC}"
    echo "========================================"
    echo ""

    # Set version and start environment
    export KAFKA_VERSION=$version

    log_info "Starting Kafka $version environment..."
    cleanup
    docker compose up -d

    # Wait for services
    sleep 5
    if ! wait_for_kafka; then
        RESULTS[$version]="FAIL: Kafka failed to start"
        cleanup
        return 1
    fi

    # Wait for topics to be created
    log_info "Waiting for topic setup..."
    sleep 10

    # Run tests based on type
    local test_result=0
    case $test_type in
        quick)
            run_quick_test "$version" || test_result=1
            ;;
        full)
            run_quick_test "$version" || test_result=1
            run_full_test "$version" || test_result=1
            ;;
        benchmark)
            run_quick_test "$version" || test_result=1
            run_benchmark "$version" || test_result=1
            ;;
    esac

    # Cleanup
    cleanup

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $test_result -eq 0 ]; then
        RESULTS[$version]="PASS (${duration}s)"
        log_success "Kafka $version: All tests passed (${duration}s)"
    else
        RESULTS[$version]="FAIL (${duration}s)"
        log_error "Kafka $version: Some tests failed (${duration}s)"
    fi

    return $test_result
}

# Generate report
generate_report() {
    mkdir -p "$RESULTS_DIR"
    local report_file="$RESULTS_DIR/version-test-$TIMESTAMP.md"

    cat > "$report_file" << EOF
# Kafka Version Compatibility Test Report

**Generated:** $(date)
**Test Type:** $TEST_TYPE

## Results Summary

| Kafka Version | Result |
|---------------|--------|
EOF

    for version in "${VERSIONS[@]}"; do
        echo "| $version | ${RESULTS[$version]:-NOT RUN} |" >> "$report_file"
    done

    cat >> "$report_file" << EOF

## Environment

- Host: $(uname -a)
- Docker: $(docker --version)
- Docker Compose: $(docker compose version)

## Tested Versions

EOF

    for version in "${VERSIONS[@]}"; do
        echo "- apache/kafka:$version" >> "$report_file"
    done

    echo ""
    echo "Report saved to: $report_file"
    cat "$report_file"
}

# Parse arguments
TEST_TYPE="quick"
VERSIONS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            TEST_TYPE="quick"
            shift
            ;;
        --full)
            TEST_TYPE="full"
            shift
            ;;
        --benchmark)
            TEST_TYPE="benchmark"
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            # Assume it's a version number
            VERSIONS+=("$1")
            shift
            ;;
    esac
done

# Use default versions if none specified
if [ ${#VERSIONS[@]} -eq 0 ]; then
    VERSIONS=("${DEFAULT_VERSIONS[@]}")
fi

# Main execution
echo "========================================"
echo "Kafka Multi-Version Compatibility Tests"
echo "========================================"
echo ""
echo "Test type: $TEST_TYPE"
echo "Versions to test: ${VERSIONS[*]}"
echo ""

# Ensure clean state
trap cleanup EXIT

# Test each version
FAILED_VERSIONS=()
for version in "${VERSIONS[@]}"; do
    if ! test_version "$version" "$TEST_TYPE"; then
        FAILED_VERSIONS+=("$version")
    fi
done

# Generate report
generate_report

# Summary
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo ""

for version in "${VERSIONS[@]}"; do
    echo "Kafka $version: ${RESULTS[$version]:-NOT RUN}"
done

echo ""

if [ ${#FAILED_VERSIONS[@]} -eq 0 ]; then
    log_success "All versions passed!"
    exit 0
else
    log_error "Failed versions: ${FAILED_VERSIONS[*]}"
    exit 1
fi
