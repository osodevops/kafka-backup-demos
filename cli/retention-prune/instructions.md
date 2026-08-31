# Retention & Prune Demo

Safe retention for **incremental backup sets** (kafka-backup **0.21.0+**),
demonstrating `kafka-backup prune` and `backup.retention` — and why bucket
lifecycle rules must never be pointed at an incremental set.

## The problem this solves

An incremental set (stable `backup_id` + `offset_storage`) appends segments
under one prefix and rewrites `manifest.json`/`offsets.db` every run. An
age-based lifecycle rule therefore deletes segments the manifest still
references (restores fail partway; `validate` reports INVALID) and never
expires the manifest itself. `prune` does it safely: manifest first, objects
second, every removal recorded as a `pruned` range.

## Run it

```bash
# from the repo root — requires kafka-backup >= 0.21.0
KAFKA_BACKUP_IMAGE=osodevops/kafka-backup:v0.21.0 docker compose up -d
cd cli/retention-prune
./demo.sh
```

## What the demo does

| Step | What happens | What to look at |
|------|--------------|-----------------|
| 2–3 | 60 records → first incremental backup (tiny segments) | MinIO console (http://localhost:9001): `kafka-backups/retention-demo/` |
| 4 | wait past the 30s demo retention window, produce 30 more | |
| 5 | `prune … --older-than 30s` (no `--execute`) | plan output: contiguous oldest-first prefix per partition; nothing deleted |
| 6 | `prune … --execute` | "Pruned N segment(s)… Manifest rewritten first" |
| 7 | `validate` + `describe` | Result: **VALID**; `PRUNED offsets a..b` lines — deliberate deletion, not data loss |
| 8 | second incremental backup | pruned segments are **not** resurrected by the manifest merge |
| 9 | restore to `orders-restored` | only the surviving window comes back, by design |

## End-to-end verification checklist (what "works" means)

1. Step 5 output lists a plan and ends with `Dry run — nothing deleted`.
2. After step 6, the MinIO bucket no longer contains the oldest
   `segment-…bin.zst` objects, and `manifest.json` no longer references them
   (`describe` segment count dropped).
3. Step 7: `validate` exits 0 with `Pruned Ranges: ≥ 1`; a lifecycle-deleted
   segment would instead exit 1 with `Missing segment:`.
4. Step 8: `describe` shows the same `PRUNED` ranges after the next backup —
   the merge fix in 0.21 keeps them.
5. Step 9: consumer count equals the records in the surviving window.
6. `validate-restore` on this set passes; delete a referenced segment by
   hand in the MinIO console and it fails with a "deleted by a bucket
   lifecycle rule?" error — that's the new dry-run canary.

## Production notes

- Use production-sized windows (`--older-than 30d`, `retention.max_age: 30d`).
- `prune` refuses while a backup run looks live (offset checkpoint < 2 min);
  `--force` overrides.
- `--max-total-bytes` caps the set size (compressed bytes), oldest first.
- Lifecycle rules remain fine for **per-run backup IDs** (a unique prefix per
  scheduled run) — expiring a whole self-contained run is safe.
