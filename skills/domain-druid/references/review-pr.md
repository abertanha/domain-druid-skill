# PR Peer Review Workflow

Runs the full domain-druid arsenal against a branch diff to produce a
structured peer review. The result is both displayed in chat and persisted
to the `reviews/` directory.

```
Command: /review-pr
Output:  Chat + .business-logic/<repo>/reviews/YYYY-MM-DD_<branch>.md
```

## Interactive Flow

The agent MUST NOT skip any of these four steps. Each step requires user
input before proceeding.

### Step 1 — Scope

```
Agent: Which branch and functionality to be merged should we evaluate?

User: feature/partial-refund being merged into main
```

The agent captures:

| Field | Value | How it's used |
|-------|-------|---------------|
| Source branch | `feature/partial-refund` | Used in `git diff` and output filename |
| Target branch | `main` | Base for diff comparison |
| Description | user's free-text description | Used in report preamble |

Run the diff immediately so the agent knows what files changed:

```bash
git fetch origin <source> <target> 2>/dev/null  # best-effort
git diff <target>...<source> --stat
git diff <target>...<source>
```

If the diff is empty or the branch doesn't exist locally, suggest alternatives:
- "Branch not found locally. Try `git fetch` first, or specify a local branch."

### Step 2 — Domain Mapping Check

If no LOGIC.md or split files exist for this repo:

```
Agent: Has this codebase or logic flow already been mapped by me?
       If so, which domain(s) does it belong to?
```

The user responds with known domains (e.g., "Billing, Refunds"). The agent
stores this to scope the Rule Druid audit and plan new-rule ingestion.

If LOGIC.md or split files DO exist, skip this step — the agent already
knows the domains from SEGMENTS.md.

### Step 3 — New Intent

```
Agent: Does this PR implement new requirements or functionalities
       that didn't exist before? Which ones?

User: Adds a partial-refund flow with manager approval above $500.
```

The user's answer is recorded as context for the Suggestions pass and for
cross-referencing against existing rules. It also helps the agent distinguish
between "this is a new rule" vs "this is an existing rule being implemented
for the first time."

### Step 4 — Four-Pass Review

Run these four passes in sequence. Each pass builds on the previous one.

---

## Pass 1: Compliance Check

For every file in the branch diff, run the Rule Druid algorithm
(see [rule-druid.md](rule-druid.md)). Collect results per rule.

```bash
# For each changed file in the diff:
changed_files=$(git diff <target>...<source> --name-only --diff-filter=AM)
for f in $changed_files; do
  # Run Rule Druid on each file
  run_rule_druid "$f"
done
```

Produce a per-rule compliance table:

| Rule | Status | Detail |
|------|--------|--------|
| BR-03 (Auth) | ✅ Satisfied | Router-level authMiddleware wraps new handler |
| BR-09 (Refund Timeframe) | ⚠️ Partial | 30-day check present but reason string validation missing at L142 |
| BR-12 (Refund Window) | ❌ Not enforced | No date check found in new handler |

Rules that are not triggered by the changed code are omitted from the report.

---

## Pass 2: New Rule Detection

Scan the diff for business logic signals using the same pipeline as
[auto-detect.md](auto-detect.md) (section 1):

1. **Extract** — find new validation guards, threshold constants, test
   assertions, enum variants, config toggles, error messages
2. **Categorize** — Rule / Invariant / Limit / Definition / Decision / Exception
3. **Structure** — build candidate entry with fingerprint
4. **Fingerprint** — normalize the constraint
5. **Verify** — run source verification against the current file
6. **Dedup** — check FINGERPRINTS.md for existing matches
7. **Present** — show each candidate with y/n/edit (see [analyze.md](analyze.md) §5)

On user confirmation, write to PENDING.md with the standard pipeline
(see SKILL.md — Ingestion Loop).

Detection strategy for branch diffs:

```
# Look at the diff itself for structural patterns
git diff <target>...<source>

# Look at full context around additions
git diff <target>...<source> -U10
```

High-signal targets (same as auto-detect.md §1):

| Signal | Look for |
|--------|----------|
| New test case | `fn test_\w+` in test files |
| Test assertion | `assert!`, `assert_eq!`, `expect(...)` |
| Validation function | `if ... { return Err(...) }`, `validate_` |
| Config constant | `const \w+ = \d+`, `MAX_`, `LIMIT_`, `THRESHOLD_` |
| New spec section | `## \w+` in spec files |
| Enum variant | New variant in existing enum |
| Error message | String literals containing "cannot", "must", "not allowed" |
| Guard clause | Early return with condition |

---

## Pass 3: Cross-Reference

Compare the output of Pass 1 and Pass 2 against existing business logic.

### Contradiction

Does any new rule contradict an existing rule? Use the same logic as
[analyze.md](analyze.md) §6 (Contradiction Detection).

### Drift

Does the diff change behavior that an existing rule describes? For example:

```
LOGIC.md says: refund window = 30 days
Code before PR: const REFUND_WINDOW_DAYS = 30
Code in PR:     const REFUND_WINDOW_DAYS = 45
→ Drift: doc says 30, PR changes to 45. Flag with 🔍
```

### Gap

Does the diff introduce behavior with no corresponding rule at all?

```
Diff adds: manager_approval_required(amount > 500)
Existing:  no refund approval rules in LOGIC.md
→ Gap: entire manager-approval domain is undocumented. Propose new entry.
```

### Clarification

Does the diff add nuance that should update an existing entry?

```
LOGIC.md says: refunds are processed within 30 days
PR adds:      except for enterprise accounts (45 days)
→ Clarification: update existing entry with enterprise carve-out.
```

### Supersession

Does the PR remove or replace behavior covered by an existing rule?

```
LOGIC.md says: international orders must be manually reviewed
PR removes:   manual_review_queue and replaces with compliance API
→ Supersession: old rule is replaced, mark as superseded.
```

---

## Pass 4: Suggestions

Surface edge cases, enforcement gaps, and layering issues that the developer
might have missed. This is the most open-ended pass.

| Type | What to look for | Example |
|------|------------------|---------|
| Edge case | Rule works for normal case but misses a boundary or combination | "Partial refund + coupon line items not covered by BR-09" |
| Enforcement gap | Rule exists but this code path doesn't enforce it | "New endpoint skips the restockItems() call required by BR-04" |
| Layering | Rule is enforced at wrong layer (frontend only, no backend guard) | "Manager approval is validated in UI but not in the API handler" |
| Value consistency | Same threshold used across layers | "Frontend uses $450 threshold, backend uses $500" |
| Annotation gap | Code has no BL-RULE-NNN annotation for a rule it clearly implements | "L142 enforces BR-09 but has no `// BL-RULE-009` comment" |

Each suggestion should reference the specific file:line.

---

## Report Format

The report is written to both chat and file. The file path is:

```
.business-logic/<repo>/reviews/YYYY-MM-DD_<branch>.md
```

where `<branch>` is the source branch name with `/` replaced by `-`.

The `reviews/` directory is created automatically on the first `/review-pr`
execution if it doesn't exist.

### Full template

```
## Peer Review: <source> → <target>

Date:      <YYYY-MM-DD>
Reviewer:  Domain Druid (auto)
Domain:    <from SEGMENTS.md or user-provided>
Scope:     <user's description from Step 1>

---

### ✅ Compliance

<per-rule table from Pass 1>

### 🆕 New Rules Detected

<numbered list of candidates from Pass 2, showing:
 - status (proposed/will be written to PENDING.md vs already mapped)
 - Trace ID if already mapped
 - fingerprint
>

### ⚠️ Cross-Reference

<findings from Pass 3, annotated with:
 - 🔍 Drift: <description>
 - 📌 Gap: <description>
 - ⚠️ Contradiction: <description>
 - 📝 Clarification: <description>
 - ♻️ Supersession: <description>
>

### 💡 Suggestions

<numbered list from Pass 4, each with file:line reference>

---

_Generated by Domain Druid. New rules were proposed via interactive
confirmation during this review._
```

### Example output

```
## Peer Review: feature/partial-refund → main

Date:      2026-06-29
Reviewer:  Domain Druid (auto)
Domain:    Billing, Refunds
Scope:     Adds a partial-refund flow with manager approval above $500.

---

### ✅ Compliance

| Rule | Status | Detail |
|------|--------|--------|
| BR-03 (Auth) | ✅ Satisfied | authMiddleware wraps new /refund/partial handler |
| BR-09 (Refund Timeframe) | ⚠️ Partial | 30-day check at L41, but `reason` string validation missing at L88 |
| BR-12 (Refund Window Policy) | ❌ Not enforced | Existing `REFUND_WINDOW_DAYS` constant used in old code but new handler reads `PARTIAL_REFUND_WINDOW` instead |

### 🆕 New Rules Detected

1. **Partial refunds require manager approval above $500**
   - Code: src/api/refund.rs:72 (fn: process_partial_refund, if amount > 500)
   - Fingerprint: cmp(gt, amount, 500)
   - Status: proposed → will be written to PENDING.md

2. **Refund reason is required for partial refunds**
   - Code: src/api/refund.rs:85 (fn: process_partial_refund, if reason.is_empty())
   - Fingerprint: requires(reason, non_empty)
   - Status: proposed → will be written to PENDING.md

### ⚠️ Cross-Reference

- 🔍 Drift: BR-12 says refund window is 30 days. The new code introduces
  `PARTIAL_REFUND_WINDOW = 60`. If partial refunds intentionally have a
  longer window, BR-12 needs a carve-out. If it's an oversight, align the
  constant.
- 📌 Gap: No rule exists for refund reason requirements. The new `reason`
  validation should be documented.

### 💡 Suggestions

1. Add `// BL-RULE-009` annotation at src/api/refund.rs:41 (30-day check)
   to satisfy backward traceability.
2. Consider adding `restockItems()` call for partial refunds to satisfy
   BR-04 (Restock after refund). Current code only restocks on full refunds.
3. The manager-approval threshold ($500) is only checked in the API handler.
   Consider adding a database-level constraint or moving to a config constant.

---

_Generated by Domain Druid. New rules were proposed via interactive
confirmation during this review._
```
