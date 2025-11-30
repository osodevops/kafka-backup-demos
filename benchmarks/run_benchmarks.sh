#!/bin/bash
# Main Benchmark Orchestrator for kafka-backup
# Usage: ./run_benchmarks.sh [scenario] [profile]
#   scenario: all, throughput, compression, latency, large, scaling
#   profile:  quick, standard, full
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Configuration
SCENARIO=${1:-"all"}
PROFILE=${2:-"quick"}
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/results"
RESULTS_FILE="$RESULTS_DIR/benchmark-$TIMESTAMP"

# Profile settings
case $PROFILE in
    quick)
        DATA_SIZE_MB=100
        MESSAGE_COUNT=10000
        ITERATIONS=1
        ;;
    standard)
        DATA_SIZE_MB=500
        MESSAGE_COUNT=50000
        ITERATIONS=3
        ;;
    full)
        DATA_SIZE_MB=1000
        MESSAGE_COUNT=100000
        ITERATIONS=5
        ;;
    *)
        echo "Unknown profile: $PROFILE"
        echo "Use: quick, standard, or full"
        exit 1
        ;;
esac

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

print_step() {
    echo -e "${YELLOW}▶${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Initialize results
mkdir -p "$RESULTS_DIR"
cat > "${RESULTS_FILE}.json" << EOF
{
  "timestamp": "$TIMESTAMP",
  "profile": "$PROFILE",
  "data_size_mb": $DATA_SIZE_MB,
  "message_count": $MESSAGE_COUNT,
  "iterations": $ITERATIONS,
  "scenarios": {}
}
EOF

print_header "kafka-backup Benchmark Suite"
echo "  Profile:    $PROFILE"
echo "  Data Size:  ${DATA_SIZE_MB}MB"
echo "  Messages:   $MESSAGE_COUNT"
echo "  Iterations: $ITERATIONS"
echo "  Scenario:   $SCENARIO"
echo ""

# Check Docker environment
print_step "Checking Docker environment..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    print_error "Kafka not running. Starting environment..."
    docker compose up -d
    echo "Waiting for Kafka to be ready (30 seconds)..."
    sleep 30
fi
print_success "Docker environment ready"

# Generate test data
print_step "Generating test data (${DATA_SIZE_MB}MB)..."
"$SCRIPT_DIR/tools/generate_data.sh" "$MESSAGE_COUNT" "$DATA_SIZE_MB"
print_success "Test data generated"

# Run scenarios
run_scenario() {
    local scenario_name=$1
    local scenario_dir="$SCRIPT_DIR/scenarios/$scenario_name"

    if [ ! -f "$scenario_dir/run.sh" ]; then
        print_error "Scenario not found: $scenario_name"
        return 1
    fi

    print_header "Running: $scenario_name"

    # Run the scenario
    BENCHMARK_PROFILE="$PROFILE" \
    BENCHMARK_DATA_SIZE="$DATA_SIZE_MB" \
    BENCHMARK_MESSAGE_COUNT="$MESSAGE_COUNT" \
    BENCHMARK_ITERATIONS="$ITERATIONS" \
    BENCHMARK_RESULTS_FILE="${RESULTS_FILE}.json" \
    "$scenario_dir/run.sh"

    print_success "Completed: $scenario_name"
}

case $SCENARIO in
    all)
        run_scenario "throughput"
        run_scenario "compression"
        run_scenario "latency"
        run_scenario "large-messages"
        run_scenario "concurrent-partitions"
        ;;
    throughput|compression|latency|large|large-messages|scaling|concurrent-partitions)
        # Normalize scenario name
        case $SCENARIO in
            large) SCENARIO="large-messages" ;;
            scaling) SCENARIO="concurrent-partitions" ;;
        esac
        run_scenario "$SCENARIO"
        ;;
    *)
        echo "Unknown scenario: $SCENARIO"
        echo "Use: all, throughput, compression, latency, large, scaling"
        exit 1
        ;;
esac

# Generate report
print_header "Generating Report"
python3 "$SCRIPT_DIR/tools/generate_report.py" "${RESULTS_FILE}.json" > "${RESULTS_FILE}.md"
print_success "Report saved to: ${RESULTS_FILE}.md"

# Print summary
print_header "Benchmark Complete"
echo ""
cat "${RESULTS_FILE}.md"
echo ""
echo "Results saved to:"
echo "  JSON: ${RESULTS_FILE}.json"
echo "  Report: ${RESULTS_FILE}.md"
