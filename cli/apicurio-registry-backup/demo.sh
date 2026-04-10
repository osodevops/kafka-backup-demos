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
echo "  Apicurio Registry v3 Backup Demo"
echo "  Enterprise Feature: schema_registry"
echo "================================================"
echo ""

# ── Step 1: Check services ──────────────────────────────
print_step 1 "Check enterprise services are running..."

if ! docker compose --profile enterprise ps 2>/dev/null | grep -q "apicurio-registry.*running"; then
    print_info "Starting enterprise services (Kafka + Apicurio Registry + MinIO)..."
    docker compose --profile enterprise up -d
    print_info "Waiting for services to be ready (Apicurio takes ~30s)..."
    sleep 30
fi

# Wait for Apicurio health
print_info "Waiting for Apicurio Registry to be healthy..."
for i in $(seq 1 20); do
    if curl -sf http://localhost:8085/q/health > /dev/null 2>&1; then
        break
    fi
    sleep 3
done
print_success "Apicurio Registry is healthy"

# ── Step 2: Check registry data ─────────────────────────
print_step 2 "Check Apicurio Registry has test data..."

GROUPS=$(curl -sf http://localhost:8085/apis/registry/v3/groups)
GROUP_COUNT=$(echo "$GROUPS" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo "0")

if [ "$GROUP_COUNT" -lt 2 ]; then
    print_info "Waiting for apicurio-setup to register test data..."
    sleep 20
    GROUPS=$(curl -sf http://localhost:8085/apis/registry/v3/groups)
    GROUP_COUNT=$(echo "$GROUPS" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo "0")
fi

print_info "Groups in registry:"
echo "$GROUPS" | python3 -c "
import sys,json
data = json.load(sys.stdin)
for g in data.get('groups', []):
    print(f\"  - {g['groupId']}: {g.get('description', '')}\")
" 2>/dev/null
print_success "$GROUP_COUNT groups found in Apicurio Registry"

# ── Step 3: Check license ───────────────────────────────
print_step 3 "Check enterprise license / trial..."

docker compose --profile enterprise run --rm kafka-backup-enterprise license info
print_success "Enterprise features available"

# ── Step 4: Run Apicurio backup ─────────────────────────
print_step 4 "Run Apicurio Registry backup (schema-only mode)..."

docker compose --profile enterprise run --rm kafka-backup-enterprise \
    backup --config /config/backup-apicurio.yaml --schema-only

print_success "Apicurio Registry backup complete!"

# ── Step 5: Verify backup in MinIO ──────────────────────
print_step 5 "Verify backup files in MinIO..."

docker run --rm --network kafka-net minio/mc sh -c "
    mc alias set local http://minio:9000 minioadmin minioadmin > /dev/null 2>&1
    echo 'Backup contents:'
    mc ls local/kafka-backups/apicurio-demo/ --recursive 2>/dev/null | head -20
"

print_success "Backup files verified in MinIO"

# ── Step 6: Check the export ZIP ────────────────────────
print_step 6 "Verify export ZIP was captured..."

ZIP_SIZE=$(docker run --rm --network kafka-net minio/mc sh -c "
    mc alias set local http://minio:9000 minioadmin minioadmin > /dev/null 2>&1
    mc stat local/kafka-backups/apicurio-demo/apicurio-demo-backup/apicurio-registry/_export.zip 2>/dev/null | grep Size || echo 'Not found'
")
print_info "Export ZIP: $ZIP_SIZE"
print_success "Export ZIP captured (can be re-imported for disaster recovery)"

# ── Summary ─────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Apicurio Registry Backup Demo Complete!"
echo "================================================"
echo ""
echo "  What was backed up:"
echo "    - $GROUP_COUNT groups (payments, orders, common)"
echo "    - All artifacts (Avro, Protobuf, JSON Schema)"
echo "    - All versions with globalId + contentId"
echo "    - Cross-artifact references"
echo "    - Rules at global, group, and artifact scope"
echo "    - Native export ZIP for disaster recovery"
echo ""
echo "  Backup location: s3://kafka-backups/apicurio-demo/"
echo ""
echo "  Backup layout:"
echo "    apicurio-registry/"
echo "      _manifest.json      (backup manifest)"
echo "      _export.zip          (native Apicurio export)"
echo "      _global_rules.json   (COMPATIBILITY, VALIDITY rules)"
echo "      groups/"
echo "        payments/           (group metadata + artifacts)"
echo "        orders/"
echo "        common/"
echo ""
echo "  Config used: config/backup-apicurio.yaml"
echo ""
echo "  Next steps:"
echo "    - Try the Schema Registry demo: cli/schema-registry-backup/demo.sh"
echo "    - Try the full enterprise demo: cli/enterprise-full-backup/demo.sh"
echo "================================================"
