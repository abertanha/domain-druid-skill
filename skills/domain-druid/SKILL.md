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
    │   ├── FINGERPRINTS.md
    │   ├── split/
    │   └── reviews/
    └── repo2/
        ├── LOGIC.md
        ├── FINGERPRINTS.md
        ├── split/
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

## Trigger Modes

### Auto (session-based)

| Event | What happens |
|-------|-------------|
| New spec/PRD introduced | Extracts rules, proposals go to PENDING.md |
| Tests discussed or changed | Extracts invariants from assertions |
| Code diff analyzed | Detects validation logic, new limits, changed behavior |
| Bug fix described | Captures discovered invariants |
| User explicitly states a rule | "Remember: X can never be Y" → classified and proposed |
| Session end | Final diff of PENDING.md against LOGIC.md |

### Auto (git-based)

If a post-commit hook was installed during onboarding, `.business-logic/<repo>/.last-sync`
is touched on each commit. When the skill starts a session, it checks the
recency of `.last-sync`. If `now - last-sync > threshold` (default: 1 hour),
it runs a git log scan:
- `git diff HEAD~5..HEAD` — analyzes recent changes for business logic signals
- Updates `.last-sync` when done

### Manual commands

| Command | Action |
|---------|--------|
| `/sync-bl` | Full scan: git log since last sync + all specs + all tests → diff against LOGIC.md |
| `/validate-bl` | Cross-reference LOGIC.md against codebase, surface contradictions, drift, and traceability gaps |
| `/review-bl` | Present PENDING.md for batch review |
| `/scan-bl <path>` | Scan file, module, or PR diff for potential business rules — presents candidates interactively for confirm/edit/reject |
| `/reset-bl-skip` | Clear the skip cache (re-suggest previously rejected patterns) |
| `/check-bl <path>` | Audit new/modified code against active business rules. Context-aware: understands middleware, delegation, compound rules (see [references/rule-druid.md](references/rule-druid.md)). |
| `/review-pr` | Peer review of a pull request: compliance check, new rule detection, cross-reference, and suggestions (see [references/review-pr.md](references/review-pr.md)). |
| `/history-bl` | Load CHANGELOG.md (never auto-loaded; must be explicit) |
| `/archive-bl` | Move deprecated rules to archive, regenerate INDEX.md + RELATIONS.md |

## Scan & Suggest

The skill can explicitly scan code for potential business rules. Every detection
goes through an interactive confirmation loop before anything is written.

### Triggers

| Trigger | Mode | Behavior |
|---------|------|----------|
| `/scan-bl <path>` | Explicit | Scan file, module, or full repo. Present candidates one at a time. |
| Agent reads code during session | Auto | Scan file on read. If patterns found, present immediately. |
| Git diff at session start | Auto | Queue candidates for batch review on first `/review-bl`. |

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
| `/check-bl <path>` | Explicit | Audit a specific file or module |
| `/check-bl` (in PR context) | Explicit | Audit files changed in the current diff |
| Agent detects new endpoint during session | Auto-suggest | "I see a new refund endpoint. Run /check-bl?" |

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
8. **RELATIONS.md** → only on `/validate-bl` or impact analysis
9. **CHANGELOG.md** → only on `/history-bl`
10. **Archive/** → never loaded unless explicitly referenced

Total active budget: **≤2000 tokens** of business logic at any time.

## Hallucination Guardrails

Two rules that MUST be followed in every session:

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

1. **DETECT** — raw delta from any trigger (git diff, conversation, spec, test, `/scan-bl`)
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
- **Drift detection** — `/validate-bl` cross-references LOGIC.md against actual code

### 3. Apply

On approval:
1. **Re-verify** — run source verification on all Code entries again
   (file may have changed between detection and write). If any entry fails:
   - Block the write
   - Present the failure: `⛔ Write blocked: path:line no longer verifiable`
   - Options:
       (a) Correct the path  — (recommended — reason: preserves the rule with accurate traceability | trade-offs: you must locate the correct location)
       (b) Remove the entry  — (reason: eliminates stale rules cleanly | trade-offs: rule is lost and must be re-detected later)
       (c) Force with override — (reason: fastest path | trade-offs: breaks traceability, future audits always flag this entry)
2. **Determine target segment** — lookup entry Tags in SEGMENTS.md to find
   the right segment file (see [references/auto-detect.md](references/auto-detect.md) — section 7).
   If LOGIC.md is still unsplit, write directly to LOGIC.md.
3. **Update** LOGIC.md or the matched segment file with the correct Status
   (active if it has Code entries, proposed if it doesn't)
4. **Log** change in CHANGELOG.md
5. **Check size** — if LOGIC.md > 1000 tokens → run split (see [references/split.md](references/split.md))
6. **Refresh** RELATIONS.md and SEGMENTS.md
7. **Update** Concerns section
8. **Clear** approved proposals from PENDING.md

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
Ingestion Loop (y/n/edit per candidate), exactly like `/scan-bl`.

## Split Behavior (Auto-Scale)

See [references/split.md](references/split.md) for full rules.

- When LOGIC.md > 1000 tokens, automatically split into `.business-logic/<repo>/split/`
- Each segment file is responsible for **at most one domain segment**
- Segment files are individually bounded at 1000 tokens (recursive splitting)
- LOGIC.md becomes a lightweight index with links to segment files
- INDEX.md is generated as the navigation hub

## Entry Format

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
           │ code implemented → detected by scan or /sync-bl
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
    code implementing it is detected by a scan or /sync-bl.
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
