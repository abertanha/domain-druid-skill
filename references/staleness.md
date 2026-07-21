# Staleness Check (`/check-staleness`)

Detects when source code has changed since the last domain documentation scan, and flags the affected segments for re-review. Prevents documentation decay in large codebases.

## The problem

In repos with 50+ segments, source code changes constantly. Without a staleness signal:
- A developer rewrites `AppForgeRules.ts` — segment `10-forged-app.md` is now inaccurate
- Nobody notices until a compliance audit or bug
- The safety net is "remember to update docs" — which is unreliable

## Architecture

```
Manifest (old) ──┐
                 ├── diff ──→ file list ──→ SOURCE_MAP.md ──→ affected segments ──→ PENDING.md ⚠️
Manifest (new) ──┘     │
                     changed files
```

Three data sources:

1. **MANIFEST** — file content hashes from `/init-manifest` / `/refresh-manifest`
2. **SOURCE_MAP.md** — inverse index of source file → segments (from `/build-source-map`)
3. **.last-sync** — timestamp of last documentation scan

## Command

### `/check-staleness`

**Workflow:**

```
Step 1 — Load manifest
  If no manifest exists, suggest `/init-manifest` first

Step 2 — Compute current hashes
  Run generate-manifest.sh silently to temp file
  Diff against stored manifest
  Extract: new, modified, deleted files

Step 3 — Load SOURCE_MAP.md
  If missing, suggest `/build-source-map` first
  For each changed file, look up its segments

Step 4 — Classify staleness

  | Change type | Impact | Action |
  |-------------|--------|--------|
  | Existing file modified | Segment may be stale | ⚠️ Flag segment for review |
  | New file created | No segment yet | 🆕 Suggest gap scan |
  | File deleted | Segment references may be broken | ❌ Flag Code: entries as broken |
  | Segment code ref unchanged | No action needed | ✅ |

Step 5 — Report

  STALENESS REPORT — nexus — 2026-07-17
  =========================================
  Files changed since last sync: 3

  ⚠️ STALE (2 segments):
    - split/10-forged-app.md
      Source: features/auth/AppForge/AppForgeRules.ts (modified)
      Last sync: 2026-07-06
      → Recommend: review and update segment

    - split/17-mobile-device-auth.md
      Source: middlewares/MobileDeviceHashMiddle.ts (modified)
      Last sync: 2026-07-17
      → Recent: verify still accurate

  🆕 UNMAPPED (1 file):
    - services/NewFeatureService.ts (new)
    → No segment covers this file. Run /gap-scan.

Step 6 — Update PENDING.md
  Append staleness entries as ⚠️-prefixed proposals for batch review
```

## Auto-suggest on session start

When a session starts, if `.last-sync` is older than a threshold (default: 1 day) and a manifest exists, the agent may suggest:

```
"📋 Source files changed since last documentation sync (N files).
 Run /check-staleness to review affected segments?"
```

This replaces the current git-log-based auto-detection for repos that have a manifest.

## Repairing broken Code: entries

When a file is deleted or renamed:
1. Segment references that file with a `Code:` entry at a specific line
2. The staleness check detects the file no longer exists
3. On `/fix-refs`, the agent:
   - Removes broken Code entries (if file deleted)
   - Verifies remaining Code entries still resolve
   - If a file was renamed, searches for the new path and proposes update

## Token impact

Loaded only during `/check-staleness` execution (~300t). Not loaded in normal sessions.
