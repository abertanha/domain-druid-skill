---
name: domain-druid
description: Continuously ingests, maintains, and validates living business logic documentation. Auto-detects rules from code changes, specs, tests, and conversations. Proposes updates, asks for validation, self-organizes via auto-splitting, and audits new code against existing rules via the Rule Druid compliance checker. Use when building features, fixing bugs, defining domain limits, reviewing PRs, or whenever business logic needs to be captured and kept in sync with the codebase.
allowed-tools: Read, Bash, Grep, Glob, Write, Edit
---

# Domain Druid

Maintains a living, versioned business logic document (`.business-logic/<repo>/LOGIC.md`)
that stays in sync with the codebase. Think of it as the **domain model's persistent
memory** — the "why" behind every rule, invariant, limit, and decision.

## Multi-Repo Workspace Structure

The `.business-logic/` directory sits at the workspace root and contains
one subdirectory per repository. `<repo>` is the repository directory name
(e.g., `repo1`, `api-gateway`, `mobile-app`).

```
.workspace-root/
├── repo1/
│   └── src/
├── repo2/
│   └── src/
└── .business-logic/
    ├── repo1/
    │   ├── LOGIC.md
    │   ├── INDEX.md
    │   ├── FINGERPRINTS.md
    │   ├── SOURCE_MAP.md
    │   ├── COMPILER_REPORT.md
    │   ├── PENDING.md
    │   ├── CHANGELOG.md
    │   ├── .domain-druid/
    │   │   └── manifest.json
│   ├── split/
│   │   ├── 01-domain-a.md
│   │   └── 02-domain-b.md
│   ├── proposals/            ← auto-generated stubs (unverified, not compiled)
│   ├── archive/
│   └── reviews/
    └── repo2/
        ├── LOGIC.md
        ├── INDEX.md
        ├── FINGERPRINTS.md
        ├── SOURCE_MAP.md
        ├── COMPILER_REPORT.md
        ├── PENDING.md
        ├── CHANGELOG.md
        ├── .domain-druid/
        │   └── manifest.json
        ├── split/
        ├── archive/
        └── reviews/
```

The agent detects the current repo from the working directory. All commands
and references use `.business-logic/<repo>/` as the active root for the
current repository.

## Quick Start

```
User:   "build business-logic"
Agent:  1. Detects current repo name from working directory
         2. Creates .business-logic/<repo>/ directory
         3. Writes LOGIC.md (template), PENDING.md, CHANGELOG.md, .last-sync
         4. Offers git post-commit hook for auto-detection
         5. Outputs: "Ready. Business logic for <repo> set up."
```

### Segment Format

All segments use YAML frontmatter with validated schema. Required fields:

```yaml
---
id: 01-auth-roles-a
type: segment
domain: auth
confidence: high
fingerprints:
  - tesseractx-auth-roles
tags:
  - auth
  - roles
established: "2026-07-21"
source_refs: 1
description: Auth and roles rules for the AGX corporate domain
---
```

Run `scripts/migrate-frontmatter.py <split-dir>` to add frontmatter to legacy segments.
Use `--clean` to remove `.bak` backup files after verifying the migration was successful.
Compilation runs autonomously after every write. To trigger manually:
`scripts/compile-segments.py <bl-root> --rebuild`.

## Trigger Modes

### Auto (session-based)

| Event | What happens |
|-------|-------------|
| New spec/PRD introduced | Extracts rules, proposals go to PENDING.md |
| Tests discussed or changed | Extracts invariants from assertions |
| Code diff analyzed | Detects validation logic, new limits, changed behavior |
| Bug fix described | Captures discovered invariants |
| User explicitly states a rule | "Remember: X can never be Y" → classified and proposed |
| Session end | Final diff of PENDING.md against segments |

### Auto (git-based)

If a post-commit hook was installed during onboarding, `.business-logic/<repo>/.last-sync`
is touched on each commit. When the skill starts a session, it checks the
recency of `.last-sync`. If `now - last-sync > threshold` (default: 1 hour),
it runs a git log scan:
- `git diff HEAD~5..HEAD` — analyzes recent changes for business logic signals
- Updates `.last-sync` when done

### Commands

Old names still work as backward-compatible aliases.

#### Scan

| Command | Action |
|---------|--------|
| `scan <path>` | Scan a file, module, or diff for business rule signals. Interactive — presents candidates one at a time for confirm/edit/reject. Writes approved entries to PENDING.md. (Old alias: `/scan-bl <path>`) |
| `re-scan` | Autonomous re-scan — detects changes since last scan, auto-proposes high-confidence entries, consolidates by domain, compiles with `--fix --rebuild`. Presents summary only, no interactive loop. |

#### Approval

| Command | Action |
|---------|--------|
| `review` | Show PENDING.md for batch review. (Old alias: `/review-bl`) |
| `approve [--all]` | Accept proposals from `proposals/` into `split/`. `--all` consolidates by domain (merges entries, deduplicates by fingerprint, sub-splits by token budget). (Old alias: `/accept-proposals`) |

#### Validation

| Command | Action |
|---------|--------|
| `audit <path>` | Rule Druid — check code against active business rules. Understands middleware stacks, delegation boundaries, compound rules. (Old alias: `/check-bl <path>`) |
| `validate` | Cross-reference rules against codebase: forward/backward traceability, drift, contradictions, stale entries. (Old alias: `/validate-bl`) |

#### Support

| Command | Action |
|---------|--------|
| `history` | Load CHANGELOG.md. (Old alias: `/history-bl`) |
| `archive <id>` | Deprecate a rule and move it to archive/, regenerate INDEX.md. (Old alias: `/archive-bl`) |
| `coverage` | Map source directories against documented segments. Shows coverage % per directory, flags uncovered areas. |
| `review-pr` | Peer review of a PR branch — 4-pass review: compliance, detection, cross-ref, suggestions. |

#### Specialized (rarely used directly)

| Command | Action |
|---------|--------|
| `scan-from-registry <src> --patterns-dir <dir>` | Technology-agnostic scan using pattern registry YAML files. For cross-language or custom patterns. (Old alias: `/scan-from-registry`) |
| `hill-climb <src> <bl> <patterns>` | Auto-iterate to fill all gaps — runs `scan → propose → accept → compile` until plateau. Normally invoked by `re-scan` or autonomous background, but can be triggered manually. |

## Autonomous Behaviors

These run without a manual command. The skill self-evaluates and self-improves.

### Grade Layer (compilation)

After every segment write or proposal accept, the skill automatically runs:

```
validate frontmatter schema (id format, required fields, types)
cross-reference fingerprints against FINGERPRINTS.md
reconcile source_refs count vs actual Code: entries
detect weak fingerprint -ref suffix
rebuild INDEX.md, FINGERPRINTS.md, SOURCE_MAP.md
write COMPILER_REPORT.md
```

Errors block the write. Warnings are logged to COMPILER_REPORT.md but don't block. The `--fix` auto-correction (rename `auto-*` files, correct `source_refs`, strip `-ref` suffix) runs automatically when applicable.

### Proposals → Consolidation

When proposals are accepted (`approve --all`), the skill groups them by `domain:` frontmatter field, merges entries, deduplicates by fingerprint, sub-splits at 1000 tokens, and counts `source_refs` from actual code refs. No manual staging steps needed.

### Auto-Sync

At session start, if `.last-sync` is stale (>1 hour), the skill runs a git log scan (`HEAD~5..HEAD`) for recent changes and updates `.last-sync`. No command needed.

### Hill-Climb (background)

If gap count is persistently high or the user runs `re-scan`, the skill may run hill-climb iterations in background: scan → propose → accept → compile → re-measure → repeat until plateau at 0 gaps. Only high-confidence signals are auto-proposed; anything below a threshold waits for `Approval` flow.

### Meta-Analysis

Every operation is logged to `meta/operations.ndjson`. Every N operations (default 3), the skill self-analyzes for patterns: duration outliers, zero-delta ops, failure clusters, repetitive tool chains. If actionable suggestions are found, the skill presents them. (Old `/meta-suggest` command still available as manual trigger.)

## Common Workflows

### "I just wrote code — did I follow our rules?"
```
audit src/my-file.ts   → compliance report per rule
```

### "I'm about to commit — did I miss anything?"
```
re-scan                 → auto-gap-fill + compile (summary only)
```

### "I want to explicitly scan a new module for rules"
```
scan src/services/      → interactive candidates (y/n/edit per rule)
review                  → see what's pending
approve --all           → accept and consolidate
```

### "End of sprint — make sure everything is documented"
```
re-scan                 → auto-detects, proposes, consolidates, compiles
review                  → review any remaining low-confidence proposals
validate                → cross-reference rules vs codebase
```

### "Some rules feel stale or wrong"
```
validate                → drift detection
review                  → review flagged items
```

### "A rule is no longer relevant"
```
archive billing-rule-02 → move to archive/, regenerate index
```

## Scan & Suggest

The skill can explicitly scan code for potential business rules. Every detection
goes through an interactive confirmation loop before anything is written.

### Triggers

| Trigger | Mode | Behavior |
|---------|------|----------|
| `scan <path>` | Explicit | Scan file, module, or full repo. Present candidates one at a time. |
| Agent reads code during session | Auto | Scan file on read. If patterns found, present immediately. |
| Git diff at session start | Auto | Queue candidates for batch review on first `review`. |

### What it looks for

| Pattern | Code example | Business logic type |
|---------|-------------|-------------------|
| Validation guard | `if balance > 0 { return Err(...) }` | Rule |
| Threshold constant | `MAX_ACTIVE_SUBS = 5` | Limit |
| Conditional branch | `if user.role == "admin"` | Rule (role-based) |
| Enum variant | `Status::Active`, `Status::Suspended` | Definition |
| DB constraint | `UNIQUE(email)` | Invariant |
| Error message | `"cannot delete account with balance > 0"` | Rule |
| Config toggle | `feature_flag("new_pricing")` | Decision |

### Output format

```
Scan Results: src/domain/billing.rs

Found 3 candidates (1 already mapped, 2 new):

### ⬜ Already mapped — "Max 5 active subscriptions"
  See BL-RULE-012 (code annotation at line 150)

### 🆕 Rule — "Cannot delete account with balance > 0"
  Code: src/domain/billing.rs:88-92 (fn: delete_account)
  Construct: if account.balance > 0 { return Err("has balance") }

  Draft:
  ## Rule: Cannot delete account with positive balance
  An account with a positive balance cannot be deleted...

  Add this rule? (y/n/edit)
```

### Dedup during scan

Before presenting, the agent computes the fingerprint of the candidate and
checks FINGERPRINTS.md. If a match is found, the candidate is marked as
"already mapped" and shown with the existing Trace ID for reference.

## Rule Druid

A read-only compliance auditor that checks new or modified code against
active business rules. Unlike naive keyword matching, the Druid understands
middleware stacks, delegation boundaries, compound rules, and cross-domain
code.

### Triggers

| Trigger | Mode | Behavior |
|---------|------|----------|
| `audit <path>` | Explicit | Audit a specific file or module |
| `audit` (in PR context) | Explicit | Audit files changed in the current diff |
| Agent detects new endpoint during session | Auto-suggest | "I see a new refund endpoint. Run audit?" |

### Algorithm overview

```
SYMBOL SCAN → DOMAIN RESOLUTION → LIGHTWEIGHT RULE LOAD → PER-RULE EVALUATION → REPORT
```

1. **Symbol scan** — read file once, extract middleware, models, function calls, guards
2. **Domain resolution** — match symbols against SEGMENTS.md Tags (transitive loading for cross-domain code)
3. **Lightweight load** — load only id + description + enforcement_points for matched domains (deep load on violation only)
4. **Per-rule evaluation** — check each rule by its enforcement_type:
   - `inline` → grep construct at file:line
   - `middleware` → check router/middleware stack wrapping the handler
   - `decorator` → check annotation on handler function
   - `delegation` → check manifest (trusted black box), then shallow LLM check, then deep on demand
   - `gateway` → trust infra level, always satisfied
   - `compound` → evaluate each invariant independently, report partial
5. **Report** — per-rule status with reasoning and suggestions

See [references/rule-druid.md](references/rule-druid.md) for the full algorithm
and edge case handling.

### Example output

```
🔍 RULE DRUID AUDIT: /api/v2/refund.ts

Domains Touched: Billing, Inventory
Deep Scan: False

✅ BR-01 (Auth): Satisfied via router-level authMiddleware.
✅ BR-04 (Restock): Satisfied via delegated call to restockItems().
⚠️ BR-09 (High Value Refunds): Partially enforced.
   Manager approval found at L42.
   ❌ Mandatory 'reason' string validation missing.
❌ BR-12 (Refund Timeframe): Not enforced.
   No date check found.

Actionable suggestions:
1. Add `reason` validation before processRefund() to satisfy BR-09.
2. Add orderDate check matching BR-12 or update if logic changed.
```

### Read-only guarantee

Rule Druid NEVER creates or modifies entries in LOGIC.md, PENDING.md, or
any other business logic file. It only reads existing rules and compares
against the provided code.

## Context Loading Strategy

See [references/context.md](references/context.md) for the full budget table.
High-level rules:

1. **INDEX.md** (if split exists) → always loaded (~200t)
2. **SEGMENTS.md** (if split exists) → always loaded (~300t)
3. **FINGERPRINTS.md** → always loaded (~200t)
4. **PENDING.md** → always loaded (~200t)
5. **Concerns** (footer of LOGIC.md or standalone) → always loaded (~200t)
6. **Segment files** (e.g. `split/01-billing.md`) → on demand, driven by SEGMENTS.md tag lookup
7. **LOGIC.md** (if no split) → always loaded (≤1000t)
8. **RELATIONS.md** → only on `validate` or impact analysis
9. **CHANGELOG.md** → only on `history`
10. **Archive/** → never loaded unless explicitly referenced
11. **Coverage** → generated on demand via `coverage` command (~200t)
12. **`scripts/detect-gaps.sh`** → only on scan/re-scan (~300t)
13. **`scripts/propose-entries.sh`** → only on scan/re-scan (~200t)
14. **`scripts/verify-work.py`** → only on verify or re-scan (~200t)
15. **`scripts/compile-segments.py`** → autonomous after every write (~200t)
16. **`scripts/scan-from-registry.py`** → only on scan-from-registry (~200t)
17. **`scripts/rebuild-fingerprints.sh`** → autonomous on compile (~150t)
18. **`scripts/merge-parallel-results.sh`** → autonomous on multi-scan (~200t)
19. **`patterns/*.yaml`** → only on tech-agnostic scan (~200t)
20. **`COMPILER_REPORT.md`** → autonomous after every write (~100t)
21. **`scripts/meta-record.sh`** → after each operation (~100t)
22. **`scripts/meta-analyze.sh`** → every N operations or on meta (~200t)
23. **`scripts/meta-suggest.sh`** → only on meta (~50t)

Total active budget: **≤2000 tokens** of business logic at any time.

## Hallucination Guardrails

Three rules that MUST be followed in every session:

1. **Never invent a rule without code.** A rule presented as active MUST have
   at least one verified `Code:` entry pointing to a real file:line:function
   in the codebase. Conversation alone produces **proposed** rules (developer
   intent), never active ones.

2. **Always verify before write.** Every `Code:` entry is checked against the
   actual filesystem before being saved to LOGIC.md. If the file:line doesn't
   exist, the write is blocked and the user is asked to resolve.

Every candidate is classified as **active** (has verified Code entries) or
**proposed** (developer intent, no Code entries). This classification is
visible in the presentation and determines the entry's Status.

3. **Always verify token budget before and after every write.** No file
   (LOGIC.md or any segment) may exceed 1000 tokens. The agent MUST:
   - **Pre-write estimation**: before writing a LOGIC.md or segment file,
     estimate its token count using the formula `ceil(bytes / 3.5)`.
     If the estimate exceeds 1000, do NOT write a single file — instead,
     plan the split structure and write directly to segments.
   - **Post-write verification**: immediately after writing every file,
     re-estimate its token count. If it exceeds 1000, this is a violation:
     revert the write, run the split procedure, and re-verify all resulting
     segments. Continue recursively until every file is ≤ 1000 tokens.
   - **Segment guard**: after any split, verify each new segment file.
     If a segment exceeds 1000 tokens, recurse the split within that
     segment's domain.
   - **No deferral**: do not defer size enforcement to a later step.
     Verify immediately. "Check size later" is a violation of this guardrail.

## Token Estimation Formula

Use this deterministic formula for all token estimates:

```
estimated_tokens = ceil(byte_count / 3.5)
```

Where `byte_count` is the file size in bytes (`wc -c` on Linux/macOS).
The divisor 3.5 is a conservative average (Portuguese/English mix with
code snippets). This is a floor value — actual tokenizers may produce
slightly fewer tokens, but overestimation is safer than underestimation.

Always report token estimates in the format:
```
File: ~XXX tokens (YYY bytes / 3.5)
```

For split plans, show the estimate for every resulting file and flag
any that approach the limit (≥ 800 tokens).

## Presenting Choices with Trade-offs

Whenever the user is presented with multiple options that have technical
trade-offs, the best option MUST be labeled with:

```
(recommended — reason: <why this is best given the goal> | trade-offs: <what the user gives up by choosing this>)
```

This applies everywhere the agent offers a choice: cross-layer drift
resolution, contradiction resolution, blocked-write overrides, and any
future multi-option prompt. If options have no meaningful trade-offs
(e.g., simple y/n confirmation), omit the label.

The agent MUST evaluate the options from the user's perspective — what
preserves correctness, minimizes risk, and requires the least effort.
The recommended option is always the one that balances these three.

## Workflow

### 1. Ingestion Loop

```
DETECT → ANALYZE → VERIFY → FINGERPRINT → DEDUP → PRESENT → Confirm/Edit → PROPOSE
```

1. **DETECT** — raw delta from any trigger (git diff, conversation, spec, test, `scan`)
2. **ANALYZE** — extract business logic implications (see [references/analyze.md](references/analyze.md))
3. **VERIFY** — run deterministic source verification on all Code entries:
   file exists, line is valid, function and construct match (see [references/auto-detect.md](references/auto-detect.md) — section 8)
4. **FINGERPRINT** — normalize constraint into canonical fingerprint string
5. **DEDUP** — check fingerprint against FINGERPRINTS.md; if match found, propose as enforcement point on existing rule instead of new rule
6. **PRESENT** — show draft with verification status badge and classification
   (active vs proposed). Must wait for user confirmation (y/n/edit) before proceeding
7. **Confirm/Edit** — user approves, rejects, or refines the draft
8. **PROPOSE** — only after user confirmation, write to PENDING.md

### 2. Validation

See [references/validate.md](references/validate.md) for detailed flows.

- **Inline** — critical contradictions, breaking changes, ambiguous logic → ask immediately
- **Batch** — routine additions, clarifications, extensions → accumulate in PENDING.md
- **Drift detection** — `validate` cross-references LOGIC.md against actual code

### 3. Apply — Token-Budget-Gated

**⚠️ MANDATORY: Every Apply cycle MUST execute Step 0 (pre-write) and
Step 5 (post-write). Skipping either is a violation of the size guardrail.**

On approval:

**Step 0 — Pre-write size estimate**
Before writing any file, estimate the token count of the target file
(LOGIC.md or segment) including the new entry. Use `ceil(bytes / 3.5)`.
- If the estimate exceeds 1000 tokens: do NOT write to that file.
  Instead, plan a split (or re-split) and write the new entry into the
  appropriate segment directly.
- If the estimate is ≤ 1000 tokens: proceed to Step 1.
- Document the estimate in the operation log.

**Step 1 — Re-verify** — run source verification on all Code entries again
   (file may have changed between detection and write). If any entry fails:
   - Block the write
   - Present the failure: `⛔ Write blocked: path:line no longer verifiable`
   - Options:
       (a) Correct the path  — (recommended — reason: preserves the rule with accurate traceability | trade-offs: you must locate the correct location)
       (b) Remove the entry  — (reason: eliminates stale rules cleanly | trade-offs: rule is lost and must be re-detected later)
       (c) Force with override — (reason: fastest path | trade-offs: breaks traceability, future audits always flag this entry)

**Step 2 — Determine target segment** — lookup entry Tags in SEGMENTS.md to find
   the right segment file (see [references/auto-detect.md](references/auto-detect.md) — section 7).
   If LOGIC.md is still unsplit, write directly to LOGIC.md (subject to Step 0).

**Step 3 — Update** LOGIC.md or the matched segment file with the correct Status
   (active if it has Code entries, proposed if it doesn't)

**Step 4 — Log** change in CHANGELOG.md

**Step 5 — Post-write size verification** (MANDATORY, never skip)
   Immediately after writing, estimate the token count of the modified file
   using `ceil(bytes / 3.5)`.
   - If ≤ 1000 tokens: ✅ OK. Proceed to Step 6.
   - If > 1000 tokens: ❌ VIOLATION. Immediately:
     a. Revert the write (restore previous state)
     b. Run the split procedure (see [references/split.md](references/split.md))
     c. Re-write the new entry into the correct segment
     d. Re-verify every resulting segment file is ≤ 1000 tokens
     e. If any segment still > 1000, recurse split within that segment
   - If any segment approaches the limit (≥ 800 tokens), note this in
     LOGIC.md Concerns as `📏 Segment "<name>" at ~XXX tokens — near limit`

**Step 6 — Refresh** RELATIONS.md and SEGMENTS.md
**Step 7 — Update** Concerns section
**Step 8 — Clear** approved proposals from PENDING.md

### 4. Archive

When a rule is deprecated:
1. Add `- Status: deprecated | archived` to the entry
2. Move file to `.business-logic/<repo>/archive/YYYY-MM_slug.md`
3. Regenerate INDEX.md, SEGMENTS.md, RELATIONS.md, Concerns
4. Log in CHANGELOG.md

### 5. PR Review

See [references/review-pr.md](references/review-pr.md) for the full interactive flow.

When the user runs `/review-pr`, the agent walks through four interactive
steps (scope → domain mapping → new intent → four-pass review):

```
Pass 1 — Compliance:  Rule Druid on every changed file
Pass 2 — Detection:   Extract new rules from diff → verify → dedup → y/n/edit → PENDING.md
Pass 3 — Cross-ref:   Contradiction, drift, gap, clarification, supersession
Pass 4 — Suggestions: Edge cases, enforcement gaps, layering, annotations
```

Output goes to both chat and `.business-logic/<repo>/reviews/YYYY-MM-DD_<branch>.md`.
The `reviews/` directory is auto-created on first execution.

New rules found during Pass 2 are proposed to PENDING.md via the standard
Ingestion Loop (y/n/edit per candidate), exactly like `scan`.

## Large Codebases (500+ files)

These scripts power the autonomous behaviors. The skill invokes them internally — you don't need to call them manually.

| Script | Purpose | When |
|--------|---------|------|
| `scripts/detect-gaps.sh` | Scan source for rule signals, cross-ref against Code: entries | On scan / re-scan |
| `scripts/propose-entries.sh` | Generate draft segment entries from 🆕 gaps | After gap detection |
| `scripts/accept-proposals.sh` + `consolidate-proposals.py` | Stage proposals into split/ with domain-grouped merge | On approve |
| `scripts/verify-work.py` | Post-implementation check: path matching | On re-scan |
| `scripts/compile-segments.py` | Validate frontmatter, rebuild indexes | After every write |
| `scripts/scan-from-registry.py` | Technology-agnostic pattern scanning | On scan-from-registry |
| `scripts/rebuild-fingerprints.sh` | Rebuild FINGERPRINTS.md from segments | On compile |
| `scripts/merge-parallel-results.sh` | Merge parallel scan reports | Autonomous on multi-scan |
| `scripts/hill-climb.sh` | Iterative gap-fill until plateau | Autonomous background |
| `scripts/meta-suggest.sh` | Analyze operation history for patterns | Periodic autonomous |

### Gap Detection Pipeline

```
scan / re-scan
  └── detect-gaps.sh ──→ Phase 1-3: scan for signals
                      └── Phase 4: cross-ref against known Code: entries
                           ├── ✅ mapped (file already referenced)
                           └── 🆕 new (no segment references this file)
                                │
auto-propose              ←───┘
  └── propose-entries.sh ──→ generate draft segment entries
                           ├── interactive (on scan)
                           └── auto (on re-scan)
```

### Self-Verification Loop

```
re-scan
  └── verify-work.py (auto)
       ├── exit 0 → ✅ all changes covered → compile
       └── exit 1 → 🔶 undocumented files found
            │
            ├── detect → propose → consolidate → compile
            │   (internal, no user interaction)
            │
            └── present summary: "N files re-scanned,
                 M proposals consolidated, 0 issues"
```

### Technology-Agnostic Scanning

```
scan-from-registry <src> <pattern-dir> --patterns-dir <dir>
  └── scan-from-registry.py
       ├── Loads pattern YAML files from patterns/
       │   (generic, typescript, react, redux, backend)
       ├── Matches file patterns + content regex
       ├── Cross-references against known fingerprints
       └── Outputs: ✅ mapped / 🆕 new per signal
```

### Hill-Climb (Autonomous Background)

The skill runs hill-climb internally during `re-scan` or when gap count is
persistently high. It iterates: detect gaps → propose → accept → compile →
re-measure → repeat until plateau at 0 gaps.

```
hill-climb (internal)
  └── hill-climb.sh
       ├── Generate manifest baseline
       ├── Loop:
       │    ├── verify-work → detect files without segment code refs
       │    ├── If 0 gaps → plateau → stop
       │    ├── Take first N → propose-entries.sh --auto → proposals/
       │    ├── Validate frontmatter → rollback on failure
       │    ├── compile-segments.py --rebuild
       │    └── Re-check against new SOURCE_MAP
       │
       ├── approve --all to stage into split/
       └── Output: initial gaps → final gaps, proposals written, rollbacks
```

The metric is **binary gap count**: how many source files have zero segment
references. Each iteration fills up to `--batch` gaps. Plateau at 0 means
every source file is traced to at least one business logic segment.

Baseline manifest is stored at `.domain-druid/manifest.baseline.json` — a
snapshot of the source tree. Each iteration replaces the manifest with an
empty `{}` so `verify-work.py` classifies every source file as "new" and
compares it against the current SOURCE_MAP. This allows incremental evaluation
without requiring actual file changes between iterations.

### Meta Hill-Climb (Skill Self-Evaluation)

The skill instruments its own operations to collect performance data and
surface data-grounded improvement suggestions.

**Data collected per operation:**

| Field | Description |
|-------|-------------|
| `op` | Operation name (`verify-work`, `hill-climb`, `compile`, `propose-entries`, etc.) |
| `duration_s` | Wall-clock duration in seconds |
| `success` | Whether the operation produced the expected result |
| `exit_code` | Process exit code |
| `files.scanned` | Source files examined during this op |
| `files.total` | Total source files in the repository |
| `loc_scanned` | Lines of code examined |
| `gaps.before` | Gaps before the operation |
| `gaps.after` | Gaps after the operation |
| `gaps.resolved` | Auto-computed: `before - after` (clamped to 0) |
| `segments.before` | Segments before the operation |
| `segments.after` | Segments after the operation |
| `segments.added` | Auto-computed: `after - before` (clamped to 0) |
| `script_calls` | Number of sub-scripts invoked during this op |
| `tool_calls.*` | Per-tool counts: `read`, `write`, `edit`, `bash`, `grep`, `glob`, `task`, `total` |
| `tokens.in` | Input tokens consumed |
| `tokens.out` | Output tokens produced |
| `output_chars` | Output character count |
| `decision` | Why this approach was chosen (brief string) |
| `error` | Error message if the operation failed |

Records use a nested JSON format. Example:
```json
{
  "op": "verify-work", "duration_s": 2.1, "files": {"scanned": 470, "total": 470},
  "gaps": {"before": 28, "after": 0, "resolved": 28},
  "segments": {"before": 10, "after": 38, "added": 28},
  "script_calls": 3,
  "tool_calls": {"read": 1, "write": 12, "bash": 2, "task": 1, "total": 16},
  "tokens": {"in": 8500, "out": 1200}
}
```

**Log location:** `meta/operations.ndjson` (relative to the skill root)
(append-only newline-delimited JSON).

**Workflow:**

1. **After each operation**, call `meta-record.sh <op-name> [flags]` with all
   available data. The agent self-reports: it tracks start/end times, counts
   its own tool calls, captures gaps delta and coverage metrics, and records
   its decision rationale in `--decision`.

2. **Every N operations** (N read from `meta/threshold`, default 3), the agent
   calls `meta-analyze.sh` to scan for patterns:
   - ⏱ Duration outliers — ops significantly slower than their mean
   - 0️⃣ Zero-delta ops — operations that resolved no gaps (wasted work)
   - 📈 Gap resolution velocity — efficient batch processing
   - ❌ Failure clusters — same op failing repeatedly
   - 🔁 Repetitive tool chains — sequences that repeat and could be scripted
   - 📊 Volume spikes — files/loc scanned jumping anomalously
   - 📊 Coverage ratio — scanned/total ratio variance
   - 📜 Script call volume — operations with many sub-script calls
   - 🧩 Token consumption — input/output token spikes
   - 🧰 Tool call outliers — ops with abnormally high tool usage

3. Output is written to `meta/suggestions.md`. The agent presents this to the
   user for review, and records which suggestions were accepted or rejected.

**Manual trigger:**

```
meta (manual trigger, normally autonomous)
  └── scripts/meta-suggest.sh ──→ meta-analyze.sh → suggestions.md
```

**Threshold configuration:**
- File: `meta/threshold` (plain text, default `3`)
- Override: `--threshold N` on `meta-suggest.sh` or `meta-analyze.sh`

**Agent responsibilities:**
- Track operation start time with `date +%s` before each major operation
- Count tool calls made during the operation (Read, Write, Edit, Bash, Grep, Glob, Task)
- Count sub-scripts called (`--script-calls`) — distinct from total bash calls
- Count total source files in repo (`--files-total`) for coverage ratio tracking
- Estimate token consumption if accessible (`--tokens-in`, `--tokens-out`)
- Capture gaps/segments delta from `verify-work.py` stdout when applicable
- Log decision rationale: `--decision "why I chose this approach"`
- After every N operations, run `meta-analyze.sh` and present `suggestions.md`
- After user review, log accepted/rejected suggestions in a follow-up record

### Fingerprint Sync

Fingerprints rebuild autonomously on every compile (after every write).

### Parallel Scan Merge

Parallel scan results merge autonomously. The `merge-parallel-results.sh` script
is invoked internally when multiple scan subagents return results.

### Coverage Check

```
coverage
  └── tree -d source/ → lookup segment Code: entries → compute % per dir → flag low
```

Coverage maps source directories to segment Code: entries, computing % per directory
and flagging areas with low coverage. The agent calculates this by running
`tree -d source/` and cross-referencing against SOURCE_MAP.md.

## Split Behavior (Auto-Scale)

See [references/split.md](references/split.md) for full rules.

- When LOGIC.md > 1000 tokens, automatically split into `.business-logic/<repo>/split/`
- Each segment file is responsible for **at most one domain segment**
- Segment files are individually bounded at 1000 tokens (recursive splitting)
- LOGIC.md becomes a lightweight index with links to segment files
- INDEX.md is generated as the navigation hub

## Entry Format

### Segment Frontmatter Schema

All segment files in `split/` use YAML frontmatter validated by `compile-segments.py`:

```yaml
---
id: 01-billing-rules        # ^[\w-]+$ — unique segment identifier
type: segment                # Segment | stub
domain: billing              # Business domain (free-form)
status: active               # active | archived | stub
confidence: high             # high | medium | low | unverified
fingerprints: []             # list of canonical fingerprint strings for dedup
tags: []                     # list of domain tags for routing
established: "2026-07-21"    # ISO date
source_refs: 0               # count of Code: entries in this segment
related: []                  # list of related segment IDs
description: ""              # free-form narrative
---
```

### Entry Format

Each business logic entry follows the schema in [references/format.md](references/format.md).
Summary:

```
## <Tag>: <Short title>

<Free-form natural language body. Explains WHAT the rule is and WHY it exists.>

- Type:  <Rule | Invariant | Limit | Definition | Decision | Exception>
- Status: <active | deprecated | pending | superseded | archived>
- Fingerprint: <normalized constraint — used for dedup>
- Trace ID: <BL-RULE-NNN — embeddable in code for backward traceability>
- Tags:  <domain, domain, ...>
- Tracks: <ISSUE-XXX, session/YYYY-MM-DD.md>
- Origin:
  - Type: <Feature Request | Bug Fix | Discussion | Spec | Test | Code Analysis | Scan>
  - ID: <tracking-id>
  - Title: "<human-readable title>"
  - URL: <optional link>
- Source:
  - Spec: <file:line (context)>
  - Test: <file:line (fn: name)>
- Code:
  - <Layer>: <file:line (fn: name, construct, type: inline | middleware | decorator | delegation | gateway | compound)>
  - <Layer>: <file:line (fn: name, construct, type: inline)>
- Established: <YYYY-MM-DD>
- Changed: <YYYY-MM-DD (reason)>
- Last reviewed: <YYYY-MM-DD>
- Next review: <YYYY-MM-DD>
- Invariants:
  - <formal-ish predicate or pseudo-code>
- Related:
  - Rules["Title of related rule"]
  - Limits["Title of related limit"]
  - Definitions["Title of related term"]
```

## Concerns Section

Auto-managed at the bottom of LOGIC.md (or as a standalone file after split):

```
## Concerns
- ⚠️ Contradiction: "Rule A" vs "Rule B" — unresolved
- 📌 Rule "Legacy coupon stacking" missing Code enforcement entries
- 🔍 Rule "Daily transfer limit" past Next review date
- 🔙 Trace ID BL-RULE-007 has no code annotation in source
```

Updated after every ingestion or validation cycle.

## Lifecycle States

```
  ┌──────────────────┐
  │   proposed*      │  (developer intent, no Code entries)
  └────────┬─────────┘
            │ code implemented → detected by scan or re-scan
           ▼
  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
  │ pending  │ → │  active  │ → │superseded│ → │ archived │
  └──────────┘    └──────────┘    └──────────┘    └──────────┘
       │               │               │
       │               ↓               │
       │          deprecated  ─────────┘
       └────────→ (direct archive)

  * proposed is created from conversation, feature requests without
    code location, or from human intent. It transitions to active when
     code implementing it is detected by a scan or re-scan.
```

- **pending** — draft in PENDING.md awaiting user y/n/edit (short-lived, never persisted)
- **proposed** — developer-defined intent, no Code entries. Stored and tracked.
  Listed in Concerns as "awaiting implementation"
- **active** — current and in force. Must have at least one verified Code entry
- **deprecated** — still present but shouldn't be relied on
- **superseded** — replaced by another rule (has Related link to replacement)
- **archived** — moved to archive/ directory, no longer in active view

## Cross-Skill Integration

This skill complements:
- **TDD** — tests encode business rules as assertions → auto-detected
- **write-a-prd / prd-to-issues** — specs are a rich source of new rules
- **tlc-spec-driven** — `spec.md` files contain requirements the learner ingests
- **git-commit-helper** — commits often encode "why" in messages

When any of these skills completes a task, check if new business logic was
created or modified. If so, run the ingestion loop.
