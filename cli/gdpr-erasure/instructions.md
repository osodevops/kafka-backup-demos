# GDPR Right-to-Erasure Demo (Enterprise)

**Requires:** kafka-backup Enterprise **0.4.0+** (`osodevops/kafka-backup-enterprise`).
The 14-day auto-trial built into the binary unlocks the `erasure` feature, so no
licence file is needed to run this demo.

## The problem

A compacted topic is a common deletion mechanism: publish a tombstone for the key
and compaction removes the data. But a backup taken **before** the tombstone still
holds the personal data, and a restore reinstates it.

The position regulators accept (ICO right-to-erasure guidance on backups: data may
stay in a passive, time-bounded backup that is "put beyond use"; EDPB 2025/26
coordinated enforcement on Art. 17) is: bounded retention **plus erasure re-applied
on restore**. This demo shows the second half.

## What the demo proves

| Step | Proof point for a DPO / auditor |
|------|----------------------------------|
| 2–3 | Personal data (U1, U2, U3) is backed up; the backup contains U2 |
| 4 | An Art. 17 request is recorded in an **erasure list**; its **SHA-256** is printed |
| 5 | Restore of the compacted `customers` topic with `on_match: tombstone`: U2 comes back only as tombstones (`U2:null`), U1/U3 intact; output reports `Records suppressed: 2 … sha256=<digest>` |
| 6 | Restore of the plain `orders` topic with `on_match: drop`: U2's 3 orders are absent, 6 of 9 records restored, `Records suppressed: 3 (3 dropped …)` |
| 7 | **Fail-loud:** the list is configured but missing → exit ≠ 0, *no topic created*, nothing restored |
| 8 | **Licence gate:** auto-trial disabled + no licence → `Feature 'erasure' is not licensed`, exit ≠ 0 |
| 9 | `validate-restore` shows the suppression summary (entries, SHA-256, match, on_match, topics) |

## Run it

```bash
# from the repo root
docker compose up -d
cd cli/gdpr-erasure && ./demo.sh
```

To run against a locally built image:

```bash
KAFKA_BACKUP_ENTERPRISE_IMAGE=kafka-backup-enterprise:local \
KAFKA_BACKUP_ENTERPRISE_PLATFORM=linux/arm64 ./cli/gdpr-erasure/demo.sh
```

The script is idempotent: it wipes the `gdpr-demo` backup prefix in MinIO and
recreates the topics on every run. It exits non-zero if any proof point fails.

## Configuration reference

```yaml
enterprise:
  erasure:
    suppression:
      keys_file: /data/gdpr/suppressed-keys.txt   # absolute path, or a key inside the backup storage
      topics: ["customers", "customer-*"]          # source topics (globs); default: all
      match: exact                                 # exact | prefix | regex
      on_match: tombstone                          # tombstone | drop
```

Keys file format — one entry per line:

```text
# comments and blank lines are ignored
U2                       # plain key
base64:AAEC/w==          # binary key
orders<TAB>U9            # entry scoped to one source topic
```

Records with a **null key never match**.

### tombstone vs drop

- **`tombstone`** (default) — the record is produced with its key and a null value.
  Use it for **compacted** topics: compaction retires every earlier copy of the key,
  and source→target offsets stay aligned one-to-one.
- **`drop`** — the record is not produced at all. Use it for **non-compacted** topics
  where the record must not exist on the target. Consumer-group offset mapping stays
  exact (each dropped source offset maps to the next surviving record's target offset).

Pairing them the other way round leaves data behind: `drop` on a compacted topic keeps
older values of the key; `tombstone` on a plain topic leaves the earlier records intact.

## Verification checklist (what to look for)

- Step 5 output contains `Records suppressed: 2 (0 dropped, 2 tombstoned; … sha256=<digest>)`
  and `<digest>` equals the SHA-256 printed in step 4.
- `customers-restored` contains `U2:null` twice and no `U2:{…}` line.
- `orders-restored` contains no `U2:` line and three each of `U1:` / `U3:`.
- Step 7: non-zero exit, `Suppression keys file not found`, and `customers-failloud`
  is **not** in `kafka-topics.sh --list`.
- Step 8: non-zero exit and `Feature 'erasure' is not licensed`.
- Step 9: an `Erasure Suppression (enterprise)` block with `Entries: 1` and the digest.

## Production notes

- **Never silently skipped.** If the feature is unlicensed, or the keys file is missing,
  unreadable, or malformed (bad `base64:`, invalid regex — the error names the line),
  the restore is refused **before any partition starts**. `validate-restore` fails the
  same way, so a broken list is caught in the dry run.
- **Resume.** The list's digest and the match configuration are folded into the restore
  checkpoint; resuming with a changed list warns and restarts rather than mixing lists.
- **Dry run.** `validate-restore` loads and reports the list but does not evaluate records;
  the suppressed counts appear on the real restore.
- **Audit.** Keep the erasure list under version control and record the printed SHA-256
  with the restore ticket. The `validate-restore --format json` output carries the same
  summary under `enterprise.erasure_suppression`.
- **Retention.** Erasure-on-restore is one half of the posture; the other is bounded
  retention of the backup itself — see the [Retention & Prune](../retention-prune/instructions.md)
  demo (`kafka-backup prune`, `backup.retention`).
