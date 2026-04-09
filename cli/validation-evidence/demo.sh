#!/bin/bash
# Validation & Compliance Evidence Demo
# Demonstrates: backup validation with deep integrity checks and compliance evidence reports
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "   Validation & Compliance Evidence Demo"
echo "================================================"
echo ""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[Step $1]${NC} $2"; echo ""; }
print_info() { echo -e "${YELLOW}-->${NC} $1"; }
print_success() { echo -e "${GREEN}OK${NC} $1"; echo ""; }

# Check services
print_step 1 "Checking Docker services..."
if ! docker compose ps | grep -q "kafka-broker-1.*running"; then
    echo "Starting Docker services..."
    docker compose up -d
    echo "Waiting for Kafka to be ready (20 seconds)..."
    sleep 20
fi
print_success "Docker services are running"

# Prepare topic and data
print_step 2 "Preparing orders topic with sample data..."
docker compose --profile tools run --rm kafka-cli bash -c '
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --delete --topic orders 2>/dev/null || true
    sleep 2
    kafka-topics.sh --bootstrap-server kafka-broker-1:9092 --create --topic orders --partitions 3 --replication-factor 1
' 2>/dev/null || true

docker compose --profile tools run --rm kafka-cli bash -c '
    tail -n +2 /data/orders.csv | while IFS=, read -r order_id customer_id product amount currency timestamp; do
        echo "{\"order_id\": \"$order_id\", \"customer_id\": \"$customer_id\", \"product\": \"$product\", \"amount\": $amount, \"currency\": \"$currency\", \"timestamp\": \"$timestamp\"}"
    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic orders
'
print_success "Produced sample data from orders.csv"

# Run backup
print_step 3 "Running backup..."
docker compose --profile tools run --rm kafka-backup \
    backup \
    --config /config/backup-basic.yaml
print_success "Backup completed"

# Quick validation
print_step 4 "Running quick validation..."
print_info "Quick validation checks manifest integrity and segment existence."
echo ""
docker compose --profile tools run --rm kafka-backup \
    validate \
    --path s3://kafka-backups/basic-demo \
    --backup-id basic-backup
print_success "Quick validation passed"

# Deep validation
print_step 5 "Running deep validation..."
print_info "Deep validation decompresses and verifies every record in every segment."
echo ""
docker compose --profile tools run --rm kafka-backup \
    validate \
    --path s3://kafka-backups/basic-demo \
    --backup-id basic-backup \
    --deep
print_success "Deep validation passed"

# Describe backup (JSON format for audit trail)
print_step 6 "Generating backup description (JSON)..."
docker compose --profile tools run --rm kafka-backup \
    describe \
    --path s3://kafka-backups/basic-demo \
    --backup-id basic-backup \
    --format json
echo ""
print_success "Backup description generated"

echo ""
echo "================================================"
echo "   Demo Complete!"
echo "================================================"
echo ""
print_info "What was demonstrated:"
echo "  1. Quick validation  - manifest and segment existence checks"
echo "  2. Deep validation   - decompresses and verifies every record"
echo "  3. JSON output       - machine-readable for compliance pipelines"
echo ""
print_info "Compliance use cases:"
echo "  - SOX:  Prove backup integrity for financial data"
echo "  - CMMC: Evidence of backup validation for DoD contracts"
echo "  - GDPR: Demonstrate data recovery capability"
echo ""
print_info "Automate in CI/CD:"
echo "  kafka-backup validate --path s3://... --backup-id ... --deep"
echo "  Exit code 0 = all checks passed"
