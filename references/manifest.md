# Source MANIFEST (`/init-manifest`, `/refresh-manifest`)

A file-content hash manifest that tracks which source files have changed between scans. Enables incremental scanning — only process files whose content actually changed.

## Manifest File

Each repo with a Domain Druid setup can have a `.domain-druid/manifest.json` file:

```
.business-logic/<repo>/.domain-druid/manifest.json
```

Format:

```json
{
  "source/features/Email/EmailRules.ts": "sha256hexhash...",
  "source/models/User/UserSchema.ts": "sha256hexhash...",
  ...
  "_meta": {
    "generated": "2026-07-17T12:00:00Z",
    "source_root": "/home/user/project/source",
    "file_count": 142,
    "version": 1
  }
}
```

Note: `.tsx` and `.jsx` files are automatically included when present in the source directory. No configuration needed.

## Commands

### `/init-manifest`

Generate the initial manifest for the current repo's source directory.

**Workflow:**
1. Read the source directory from the BL repo's context (default: `<workspace>/<repo>/source`)
2. Run `scripts/generate-manifest.sh <source-dir> <bl-dir>/.domain-druid/manifest.json`
3. Create `.last-sync` timestamp
4. Report file count

### `/refresh-manifest`

Recompute file hashes and compare against previous manifest.

**Workflow:**
1. Load existing manifest
2. Run `scripts/generate-manifest.sh` to new temp file
3. Diff old vs new using `diff`
4. Report:
   - Unchanged: N files
   - New: N files (list)
   - Modified: N files (list)
   - Deleted: N files (list)
5. On confirmation, replace old manifest with new one
6. Update `.last-sync`

### Usage in other workflows

The manifest is consumed by:
- **Staleness check** (`/check-staleness`) — compares manifest against segment Code entries
- **Gap Agent** (`/gap-scan`) — skips unchanged files, focuses on new/modified
- **Parallel Scan** (`/scan-parallel`) — distributes only new/modified files across Task agents

## Token impact

The manifest JSON is **never loaded into context**. It is read by scripts and Task subagents only. The manifest reference doc (this file) is loaded on demand when the agent is about to execute a manifest command (~200t).

## Benefits

| Before | After |
|--------|-------|
| Every scan re-reads all source files (200+ files, 5+ min) | Only changed/new files are scanned |
| No way to know if a segment is stale | Manifest diff shows what changed since last sync |
| Manual tracking of "what did I last scan?" | `.last-sync` + manifest hash history |
