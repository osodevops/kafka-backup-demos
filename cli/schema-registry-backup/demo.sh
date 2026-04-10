#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_step() { echo -e "\n${BLUE}[Step $1]${NC} $2\n"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1\n"; }
print_error() { echo -e "${RED}✗${NC} $1\n"; }

echo "================================================"
echo "  Confluent Schema Registry Backup Demo"
echo "  Enterprise Feature: schema_registry"
echo "================================================"
echo ""

# ── Step 1: Check services ──────────────────────────────
print_step 1 "Check enterprise services are running..."

if ! docker compose --profile enterprise ps 2>/dev/null | grep -q "schema-registry.*running"; then
    print_info "Starting enterprise services (Kafka + Schema Registry + MinIO)..."
    docker compose --profile enterprise up -d
    print_info "Waiting for services to be ready..."
    sleep 20

    # Wait for Schema Registry
    for i in $(seq 1 15); do
        if curl -sf http://localhost:8081/subjects > /dev/null 2>&1; then
            break
        fi
        sleep 3
    done
fi
print_success "Enterprise services running"

# ── Step 2: Check schemas exist ─────────────────────────
print_step 2 "Check Schema Registry has test schemas..."

SUBJECTS=$(curl -sf http://localhost:8081/subjects)
echo "$SUBJECTS" | python3 -m json.tool 2>/dev/null || echo "$SUBJECTS"
SUBJECT_COUNT=$(echo "$SUBJECTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$SUBJECT_COUNT" -lt 2 ]; then
    print_info "Waiting for schema-setup to register test schemas..."
    sleep 15
    SUBJECTS=$(curl -sf http://localhost:8081/subjects)
    SUBJECT_COUNT=$(echo "$SUBJECTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
fi

print_success "$SUBJECT_COUNT subjects found in Schema Registry"

# ── Step 3: Check license ───────────────────────────────
print_step 3 "Check enterprise license / trial..."

docker compose --profile enterprise run --rm kafka-backup-enterprise license info
print_success "Enterprise features available"

# ── Step 4: Run schema-only backup ──────────────────────
print_step 4 "Run Schema Registry backup (schema-only mode)..."

docker compose --profile enterprise run --rm kafka-backup-enterprise \
    backup --config /config/backup-schema-registry.yaml --schema-only

print_success "Schema Registry backup complete!"

# ── Step 5: Verify backup in MinIO ──────────────────────
print_step 5 "Verify backup files in MinIO..."

docker compose --profile tools run --rm minio-mc bash -c "
    mc alias set local http://minio:9000 minioadmin minioadmin > /dev/null 2>&1
    echo 'Backup contents:'
    mc ls local/kafka-backups/sr-demo/ --recursive
" 2>/dev/null || {
    # Fallback: use mc from minio-setup
    print_info "Listing backup via MinIO API..."
    docker run --rm --network kafka-net minio/mc sh -c "
        mc alias set local http://minio:9000 minioadmin minioadmin > /dev/null 2>&1
        mc ls local/kafka-backups/sr-demo/ --recursive
    "
}

print_success "Backup files verified in MinIO"

# ── Step 6: Describe backup ─────────────────────────────
print_step 6 "Describe the backup..."

docker compose --profile enterprise run --rm kafka-backup-enterprise \
    describe --path s3://kafka-backups --backup-id sr-demo-backup \
    2>/dev/null || print_info "(describe command output above)"

# ── Summary ─────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Schema Registry Backup Demo Complete!"
echo "================================================"
echo ""
echo "  What was backed up:"
echo "    - $SUBJECT_COUNT Schema Registry subjects"
echo "    - All schema versions (Avro, JSON Schema)"
echo "    - Global + per-subject compatibility configs"
echo "    - Schema references and dependency order"
echo ""
echo "  Backup location: s3://kafka-backups/sr-demo/"
echo ""
echo "  Config used: config/backup-schema-registry.yaml"
echo ""
echo "  Next steps:"
echo "    - Try the Apicurio demo: cli/apicurio-registry-backup/demo.sh"
echo "    - Try the full enterprise demo: cli/enterprise-full-backup/demo.sh"
echo "================================================"
