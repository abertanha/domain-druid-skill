# Bulk Scan (`/scan-bulk`)

A guided multi-phase workflow for scanning entire codebases or large modules
to produce business logic segments without interactive per-candidate prompts.
Designed for initial documentation of undocumented codebases.

## Overview

```
/scan-bulk <path>
    │
    ├── Phase 0 — Preliminary Analysis (low-cost dry run)
    ├── Phase 1 — Configuration Prompt (one-time per session)
    ├── Phase 2 — Feature Selection
    ├── Phase 3 — Per-Feature Processing
    │   └── For each feature: read → extract → dedup → write segment
    ├── Phase 4 — Token Budget Guard
    └── Phase 5 — Summary Report
```

## Phase 0 — Preliminary Analysis

Before asking the user anything, do a fast walk of the directory tree
using only file listing and `wc -l` (no file content reads yet):

### Step 0.1 — Discover files

```
find <path> -type f \( -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.rs' \) | sort
```

### Step 0.2 — Classify each file by path/name heuristics

| Pattern | Classification | Suggested skip? |
|---------|---------------|-----------------|
| `*.spec.ts`, `*.test.ts`, `__tests__/`, `test/` | Test | Yes (recommended) |
| `*Rules.ts`, `*Service.ts`, `*Business.ts`, `*Engine.ts` | High business logic density | No |
| `*Controller.ts`, `*Handler.ts`, `*Router.ts` | Medium — contains input validators | Skip validators (recommended) |
| `*.d.ts`, `types.ts`, `type.ts`, `interfaces.ts` | Type definitions only | Yes (recommended) |
| `config.ts`, `*.json`, `*.yaml`, `*.yml` | Configuration, no logic | Yes (recommended) |
| `*Middleware.ts`, `*Guard.ts` | Cross-cutting logic | No |
| `*Model.ts`, `*Schema.ts`, `*Entity.ts` | Schema/ORM definitions | Medium value |

### Step 0.3 — Quick line count

For each high/medium-density file, run `wc -l <file>` to estimate content
volume. Do NOT read file contents at this stage.

### Step 0.4 — Group by feature directory

Group files by their immediate parent directory (one level below the scan
root). Each group represents a feature/domain. For each feature, count:
- Total files
- High-density files (service, rules, business, engine)
- Test files
- Total lines (high-density files only — for token estimation)

### Step 0.5 — Check existing documentation

For each feature directory, check if a segment already exists:
- Look up the directory name in `SEGMENTS.md` Tags
- If documented, check `FINGERPRINTS.md` for the `.last-sync` timestamp
- Classify as: **New** (no segment), **Documented (synced)**, **Documented (stale — no recent scan)**

### Step 0.6 — Estimate tokens per mode

| Mode | What's included | Token formula |
|------|----------------|---------------|
| Standard (recommended) | High + medium files, skip tests, skip validators, skip comments, skip config | Sum of all target file lines × ~2 tokens/line × 0.5 (for code density) |
| Full | All files, all content | Sum of all file lines × ~2 tokens/line |
| Minimal | High-density only, code patterns only (no deep analysis) | Sum of high-density files × ~1 token/line |

Use `ceil(total_bytes / 3.5)` for final estimates. Pre-compute using
`wc -c` on target files (but only if already available — otherwise use
line-count heuristic: `lines × 35 bytes/line average`).

## Phase 1 — Configuration Prompt

Present a one-time configuration panel with concrete estimates from Phase 0:

```
/scan-bulk core/source/features/

Preliminary analysis complete — 312 files across 52 feature directories
17 already documented, 35 new

Estimated tokens by scan mode:
────────────────────────────────────────────────────────────────
* Standard (recommended)      ~18,000  — skip tests, validators,
                                          comments, configs
  Full                        ~52,000  — everything
  Minimal                     ~7,000   — code patterns only (guards,
                                          constants, enums)

Standard skips:
  ✓ Test files          (87 files, ~15,000 tokens saved)
  ✓ Controller input    (45 files, ~9,000 tokens saved)
    validators
  ✓ Comments/docstrings (~8,000 tokens saved)
  ✓ Config/type files   (22 files, ~2,000 tokens saved)

Proceed with Standard? [Y/n/custom]
```

If the user enters `custom`, present per-category toggles with individual
savings:

```
Custom configuration:
  Test files:                    Read or Skip? [Skip (recommended)]
  Controller validators:         Read or Skip? [Skip (recommended)]
  Comments/docstrings:           Read or Skip? [Skip (recommended)]
  Type definition files:         Read or Skip? [Skip (recommended)]
  Config files (JSON/YAML):      Read or Skip? [Skip (recommended)]
  Cross-cutting (middleware):    Read or Skip? [Read]

Estimated tokens with this config: ~22,000
Proceed? [Y/n]
```

### Configuration rules

1. **One-time only** — once set, the config applies to ALL features in this
   scan session. Do NOT ask again per feature.
2. **Show token impact** — every toggle shows how many tokens it saves vs full.
3. **Recommendation always visible** — the recommended option is always labeled
   with `(recommended)` and a brief rationale.
4. **Summary after confirm** — after the user confirms, print the config summary:

```
Configuration locked for this session:
  ✓ Skip tests
  ✓ Skip validators
  ✓ Skip comments
  ✓ Skip config/type files
  ✓ Read cross-cutting files
  → Estimated total: ~22,000 tokens

Starting bulk scan...
```

## Phase 2 — Feature Selection

After configuration, present the list of features detected in Phase 0:

```
35 undocumented features detected.

Feature                    Files  Est. tokens  Complexity
─────────────────────────  ─────  ───────────  ──────────
Customer/                   10       4,500     High
Averbacao/                   8       3,200     High
Pricing/                     6       2,800     Medium
Cellphone/                   4       1,200     Low
...

Options:
  [all]      — process all 35 features
  [1-10]     — process features 1 through 10
  [1,3,5]    — process specific features by number
  [q]        — quit

Selection: all
```

### Selection rules

1. Present the table in order of decreasing estimated tokens (largest first)
   so the user sees the high-cost items upfront.
2. Only show **undocumented** features. Documented features are listed
   separately with a note: "17 already documented — use `/validate-bl` to check for drift."
3. Mark features with a `(stale)` indicator if their segment exists but
   `.last-sync` is older than 7 days.

### After selection — confirmation

```
Selected 35 features (~22,000 tokens estimated).

Processing order:
  1. Customer/            (4,500 tokens)
  2. Averbacao/           (3,200 tokens)
  3. Pricing/             (2,800 tokens)
  4. Cellphone/           (1,200 tokens)
  ... (31 more)

Proceed? [Y/n]
```

## Phase 3 — Per-Feature Processing

For each selected feature, in order:

### Step 3.1 — Read files

Read all applicable files in the feature directory, applying the user's
Phase 1 configuration:

- **Skip test files** — do not read `.spec.ts`, `.test.ts`, `__tests__/`
- **Skip validators** — for controller files, only read handler method
  signatures and business logic branches; skip input validation blocks
  (Joi/Zod schemas, `if !field` checks, `validate()` calls at the top
  of handler methods)
- **Skip comments** — when reading file content, strip comment lines
  before analysis (single-line `//`, block `/* */`), JSDoc/docstrings
- **Skip config/type** — do not read `*.d.ts`, `types.ts`, `*.json`

### Step 3.2 — Extract business logic

For each file read, identify:

| Pattern | Extract as | Notes |
|---------|-----------|-------|
| Validation guard | Rule | Skip if in controller input validator (unless user chose "Read validators") |
| Threshold constant | Limit | Always extract |
| Conditional branch (role-based) | Rule | Extract only if branches represent domain rules, not UI state |
| Enum variant | Definition | Group all enums from the feature together |
| DB constraint | Invariant | Extract from model/schema files if read |
| Error message | Rule | Only if the message encodes domain logic |
| Service method | Rule | The method's core business logic, not CRUD boilerplate |
| Exports/composition | Definition | Class/service structure, module boundaries |

### Step 3.3 — Generate segment content

For each feature, produce one segment file using the format from
[format.md](format.md). The segment should cover:

- **Feature overview** — what the feature does
- **Rules** — business rules (validation guards, conditional branches)
- **Limits** — thresholds, caps, boundaries
- **Definitions** — domain terms, enums, types
- **Decisions** — architecture/product choices visible in the code
- **Code references** — file:line pointers for each entry

### Step 3.4 — Dedup against FINGERPRINTS.md

For every extracted candidate:

1. Compute fingerprint (see [format.md](format.md) — Fingerprint section)
2. Check against `FINGERPRINTS.md`
3. Three outcomes:

| Outcome | Action |
|---------|--------|
| **Synced + fingerprint match** | Auto-skip. Entry is already documented and up-to-date. Do NOT modify. |
| **Synced + fingerprint mismatch** | Flag as **drift**. The code has changed since the entry was documented. Append to a drift report (returned in Phase 5). Do NOT auto-update. |
| **Not found in FINGERPRINTS.md** | New rule. Include in the generated segment. Add fingerprint to `FINGERPRINTS.md`. |

### Step 3.5 — Write segment

1. **Estimate pre-write** — use `ceil(content_bytes / 3.5)`. If > 1000 tokens,
   split the segment into sub-segments (see [split.md](split.md)).
2. **Write** to `.business-logic/<repo>/split/<NN>-<feature-name>.md`
   - File name is `<NN>-<kebab-case-feature-name>.md`
   - NN is the next available two-digit number in the `split/` directory
3. **Verify post-write** — `wc -c` → `ceil(bytes / 3.5)`. If > 1000, revert
   and split further.
4. **Update FINGERPRINTS.md** — append new fingerprints
5. **Update SEGMENTS.md** — add entry for the new segment
6. **Update CHANGELOG.md** — log the new segment

### Step 3.6 — Report per-feature

After each feature, print a one-line summary:

```
✅ Customer/ (4,500t) — 8 rules, 3 definitions, 2 limits → 01-customer.md
```

If drift was detected in a documented feature:

```
⚠️ Pricing/ (drift) — 2 fingerprints changed since last sync. See summary.
```

## Phase 4 — Token Budget Guard

Before processing each feature, check remaining estimated tokens against
a cumulative budget.

### Budget calculation

```
remaining = initial_estimate - sum(processed_feature_estimates)
```

### Guard trigger

If processing the NEXT feature would push the cumulative total past
**80% of the initial estimate**, pause and alert:

```
Token budget at 82% — 3 features remain (~4,500 tokens estimated).
Enter: [c]ontinue  [p]ause and resume later  [s]witch to Minimal mode
```

| Action | Behavior |
|--------|----------|
| `c` / `continue` | Continue processing remaining features (ignore budget) |
| `p` / `pause` | Stop processing. Note the resume point in a session file. |
| `s` / `switch` | Switch to **Minimal** mode for remaining features — extract only code patterns (guards, constants, enums) without deep analysis. Save the user's choice. |

If the user chooses `switch`, the Minimal mode applies to ALL remaining
features. Do NOT ask again per feature.

### Defining the budget

The token budget is the **initial estimate** from Phase 1 (what the user
agreed to). For example, if the Standard mode estimated ~18,000 tokens,
the guard fires at ~14,400 tokens (80%).

The budget is an **estimate** based on line counts, not actual token
consumption. If actual consumption is consistently below estimates,
the agent may note this but should not adjust the budget mid-scan.

## Phase 5 — Summary Report

After all features are processed (or the scan is paused), print:

```
Scan complete.
────────────────────────────────────────────────────
  Documented:      28 new segments
  Skipped (dup):   3  (already synced)
  Drift flagged:   2  (code changed since doc)
  Remaining:       0

Drift details:
  ⚠️ Pricing/ → BR-012 (max_commission_rate changed from 0.15 to 0.20)
  ⚠️ Master/ → BR-045 (allowed_levels expanded)

Token usage: 18,400 / 18,000 estimated (102%)
Features processed: 28 / 35 selected
```

If paused (Phase 4), the summary includes:

```
Scan paused at feature 12/35.
Resume with: /scan-bulk --resume core/source/features/
Resume info stored in: .business-logic/core/.bulk-scan-resume.json
```

The resume file contains:
```json
{
  "scan_path": "core/source/features/",
  "config": { "skip_tests": true, "skip_validators": true, "skip_comments": true },
  "processed": ["Customer", "Averbacao", "Pricing"],
  "remaining": ["Cellphone", "...", "..."],
  "next_index": 4,
  "total_estimate": 22000,
  "consumed_estimate": 14500
}
```

## Drift Detection (Detailed)

When a documented feature has fingerprint mismatches (Synced + code changed):

1. Identify which fingerprints differ between FINGERPRINTS.md and the
   current code.
2. Read the affected entries from the existing segment file.
3. Compare the documented code references against the actual code.
4. Flag each mismatch:

```
Drift: "Max commission rate"
  Documented: src/features/Pricing/PricingRules.ts:42 (const MAX_COMMISSION = 0.15)
  Actual:     src/features/Pricing/PricingRules.ts:44 (const MAX_COMMISSION = 0.20)
  Severity:   Low (limit was relaxed)
  Action:     Run /sync-bl to update or edit manually.
```

5. Do NOT auto-update drifted entries. The user must explicitly update them.
6. Append all drift items to the summary report.

## Edge Cases

### Empty directory

If the path contains no code files, inform the user and exit:

```
No code files found at <path>. Ensure the path contains .ts, .js, .py, or .rs files.
```

### Single file path

If the path is a single file, not a directory, fall through to `/scan-bl`
behavior (interactive scan) with a note:

```
<path> is a single file. Use /scan-bl for interactive scanning.
Falling through to /scan-bl <path>...
```

### Already fully documented

If all features at the path are already documented (no new features, no drift):

```
All features at <path> are already documented and in sync.
Run /validate-bl for a compliance audit.
```

### Token estimate wildly wrong

If actual token consumption exceeds the Phase 1 estimate by more than 50%,
pause and ask:

```
Actual token consumption (27,000) exceeds estimate (18,000) by 50%.
The remaining 10 features may consume significantly more than expected.
Options:
  [c]ontinue anyway
  [s]witch to Minimal mode (recommended)
  [p]ause
```

## Summary of Outputs

| What | Where | When |
|------|-------|------|
| Segment files | `.business-logic/<repo>/split/<NN>-<name>.md` | Per feature |
| FINGERPRINTS.md updates | `.business-logic/<repo>/FINGERPRINTS.md` | Per feature (new entries) |
| SEGMENTS.md updates | `.business-logic/<repo>/SEGMENTS.md` | Per feature |
| CHANGELOG.md updates | `.business-logic/<repo>/CHANGELOG.md` | Per feature |
| Drift report | Inline summary (Phase 5) | End of scan |
| Resume file | `.business-logic/<repo>/.bulk-scan-resume.json` | If paused |

## Relationship to Other Commands

| Command | vs `/scan-bulk` |
|---------|-----------------|
| `/scan-bl <path>` | Interactive per-candidate. Use for targeted file/module analysis. `/scan-bulk` on a single file falls through to this. |
| `/sync-bl` | Full sync from git log + specs + tests. Broader but shallower than bulk-scan's deep per-feature analysis. |
| `/validate-bl` | Cross-reference existing docs vs code. `/scan-bulk` produces drift flags but does NOT run full validation. |
| `/review-bl` | Batch review of PENDING.md. `/scan-bulk` writes directly to segments (skips PENDING.md). |
