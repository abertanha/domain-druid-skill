# Auto-Detection Strategies

The skill detects business logic changes from multiple signal sources.

## 1. Git Diff Analysis

Runs when: session start (if .last-sync is stale) or on `re-scan`.

### Scope

Compare current state against last sync point:

```
git diff --stat HEAD~5..HEAD                           # overview
git diff HEAD~5..HEAD -- '**/*.md'                     # spec/doc changes
git diff HEAD~5..HEAD -- '**/tests/**' '**/*_test.*'   # test changes
git diff HEAD~5..HEAD -- '**/*.rs' '**/*.py' '**/*.ts' # code changes
```

### What to look for

| Signal | Example | What it implies |
|--------|---------|-----------------|
| New test case | `fn test_free_shipping_over_100()` | New rule: free shipping threshold |
| Test assertion | `assert!(shipping_cost == 0)` | Invariant: shipping cost is 0 |
| Validation function | `if amount > 10000: raise` | Limit: max transfer amount |
| Config change | `MAX_ACTIVE_SUBSCRIPTIONS = 5` | Limit: max subscription count |
| Spec section | `## Domain: Free shipping` | Potential rule cluster |
| Comment | `// Users can only have one active session` | Invariant |

### Extraction flow

For each signal found:
1. Read the surrounding context (10 lines before/after the signal)
2. Capture exact code location: `file:line (fn: function_name, construct)`
3. Detect **enforcement type** from the surrounding context:
   - Signal is wrapped in middleware setup (`app.use`, `router.use`) → `type: middleware`
   - Signal is a decorator (`@RequireAuth`, `@ValidateBody`) → `type: decorator`
   - Signal is an opaque call to a function that looks like a validation
     delegate (`processRefund`, `validateOrder`) → `type: delegation`
   - Signal is a direct guard/check (`if amount > 0`, `assert`) → `type: inline`
   - Signal is at API gateway level (config, infra) → `type: gateway`
   - Signal has multiple conditions joined by AND → `type: compound`
   - Default → `type: inline`
4. **Verify** the captured location against the filesystem (see section 8):
   - File exists? `test -f <path>`
   - Line is valid? `wc -l` → line within bounds
   - Function name matches? `grep -n "fn\|function\|def <name>" <path>` near target line
   - Construct matches? `grep -n "<pattern>" <path>` at target line
   - If construct found at different line → auto-correct location silently
   - If construct not found at all → flag with ⚠️ in presentation
   - If file or line invalid → block candidate, flag inline
4. Check for existing `// BL-RULE-NNN` annotations in surrounding code — if found, link to existing entry
5. Extract candidate invariant and compute fingerprint
6. Check fingerprint against FINGERPRINTS.md:
   - Match found → mark as "already mapped (Trace ID: BL-RULE-NNN)"
   - No match → new candidate
7. Draft entry with all context — classify as **active** (has verified Code entries) or **proposed** (no Code entries — only conversation/spec origin)
8. Present draft to user for confirmation (y/n/edit)
9. Only on user confirmation → write to PENDING.md

---

## 2. Conversation Extraction (Guarded)

Runs during the active session — any time the user states or implies a rule.
**Hallucination guardrail**: conversation alone never creates an active rule.
The agent must determine if the rule has a code implementation or is developer intent.

### Detection patterns

| Pattern | Example |
|---------|---------|
| Explicit statement | "Users can only have one active session" |
| Decision statement | "We decided to not support refunds after 30 days" |
| Conditional rule | "If the order is over $100, shipping is free" |
| Constraint | "An email must be unique across tenants" |
| Definition | "A power user is someone with >1000 transactions" |
| Exception | "Admins are exempt from the daily limit" |
| Clarification | "Actually, the discount is applied before tax" |

### Approach

When the user makes a statement that looks like business logic:

1. **Paraphrase back** — "I hear: [rule]."
2. **Classify origin** — ask the user:
   ```
   Is this:
     (a) Already implemented in code? → point me to the file
     (b) A rule you want to define for future implementation? → stored as proposed
     (c) Just context, not a rule → skip
   ```
3. **If (a) — code implementation**:
   - Ask user for file location (or infer from context)
   - Run source verification on the location (see section 8)
   - Code verified → create as **active** (Status: active, has Code entries)
   - Code not found → flag: "⚠️ Could not verify the code location. Check the path?"
4. **If (b) — developer intent**:
   - Create as **proposed** (Status: proposed, no Code entries)
   - Add concern: `📌 Proposed: "Title" — awaiting implementation (proposed YYYY-MM-DD)`
5. **If (c) — just context**:
   - Discard, no entry created
6. If the statement clarifies an existing rule → propose update to that entry
7. If the statement contradicts an existing rule → flag inline immediately

### Non-signals (ignore these)

- Technical implementation decisions ("we use Postgres")
- UI layout preferences ("the button should be blue")
- Performance requirements ("response should be under 200ms")

These are important but belong in architecture/design docs, not business logic.

---

## 3. Test Analysis

Tests are the most precise source of business logic — they encode rules as
code that must pass.

### Signal extraction

```
# Test: test_premium_member_free_shipping
# Assertion: assert_eq!(calculate_shipping(premium_member, 50), 0)
```

Extract:
- **Rule**: Premium members always get free shipping regardless of order amount
- **Invariant**: shipping_cost(premium_member, _) == 0
- **Limit**: N/A

### Mapping

| Test pattern | Business logic interpretation |
|-------------|------------------------------|
| `assert!(x == y)` | Invariant: x must equal y under these conditions |
| `assert!(x < y)` | Limit: x must be strictly less than y |
| `assert!(x.is_err())` | Rule: this condition must be rejected |
| Parametrized test with boundary values | Limit: threshold at the boundary value |
| Setup/teardown with specific state | Definitions: what constitutes that state |

---

## 4. Spec Document Ingestion

When a PRD or spec file is presented.

### What to extract

- **Each user story** → potential rule or definition
- **Acceptance criteria** → invariants and limits
- **Out of scope section** → decisions (what was deliberately excluded)
- **Glossary** → definitions
- **Diagrams/models** → entity relationships that imply rules

### Flow

1. Read the spec document
2. Extract candidate entries
3. Cross-reference against existing LOGIC.md
4. Propose new entries to PENDING.md
5. Flag contradictions or clarifications inline

---

## 5. File Change Detection

The skill also watches for changes to specific file patterns during a session.

| Pattern | Action |
|---------|--------|
| Any spec file being read or discussed | Trigger spec ingestion |
| Test file being edited or created | Run test analysis on the changes |
| Domain model / entity files | Check for new fields, validation, limits |
| Migration files | Check for new constraints (unique, check, FK) |
| Configuration/constants files | Check for new threshold values |

This is lightweight — the skill does not actively poll. It responds to files
that come up in conversation or are explicitly read/edited during the session.

---

## 6. Explicit Scan (`scan`)

Triggered by `scan <path>` command. Scans a file, module, or the full
source tree for potential business rules. Each candidate is presented to the
user for interactive confirmation before anything is written.

### Scope

| Scope | Command | Behavior |
|-------|---------|----------|
| Single file | `scan src/domain/billing.rs` | Scan one file |
| Module | `scan src/domain/` | Scan all files in directory (bounded to 10 results) |
| Full tree | `scan` | Scan entire source tree (bounded to 15 results) |
| PR diff | `scan` (in PR context) | Scan only the diff, not full tree |

### Signal catalog

| Pattern | Code example | Business logic type |
|---------|-------------|-------------------|
| Validation guard | `if balance > 0 { return Err(...) }` | Rule |
| Threshold constant | `const MAX_ACTIVE_SUBS = 5` | Limit |
| Conditional branch | `if user.role == "admin"` | Rule (role-based behavior) |
| Enum variant | `enum Status { Active, Suspended }` | Definition (status lifecycle) |
| DB constraint | `UNIQUE(email)` | Invariant |
| Error message | `"cannot delete account with balance > 0"` | Rule (inferred from message) |
| Config value | `max_retries: 3` | Limit |
| Feature flag | `feature_flag("new_pricing")` | Decision |
| Type definition | `struct Money { amount: Decimal }` | Definition |
| Migration check | `ADD CONSTRAINT balance_check` | Invariant |

### Dedup during scan

Before presenting any candidate:
1. Extract invariant from the pattern
2. Normalize to fingerprint (see [format.md](format.md) — Fingerprint)
3. Check fingerprint against FINGERPRINTS.md
4. Match found → prepend `⬜ Already mapped — "Title" (Trace ID)` to the presentation
5. No match → proceed as new candidate

### Interactive output format

```
Scan Results: src/domain/billing.rs

Found 3 candidates (1 already mapped, 2 new):

### ⬜ Already mapped — "Max 5 active subscriptions"
  Code: src/domain/billing.rs:150 (const MAX_ACTIVE_SUBS = 5)
  → See BL-RULE-012 in LOGIC.md

### 🆕 Rule — "Cannot delete account with balance > 0"
  Code: src/domain/billing.rs:88-92 (fn: delete_account)
  Construct: if account.balance > 0 { return Err("has balance") }

  Draft fingerprint: cmp(gt, account.balance, 0)

  Draft:
  ## Rule: Cannot delete account with positive balance
  An account with a positive balance cannot be deleted.
  This prevents accidental loss of funds.

  Add this rule? (y/n/edit)

### 🆕 Invariant — "Email must be unique across tenants"
  Code: db/migrations/003_create_users.sql:15
  Construct: UNIQUE(email, tenant_id)

  Draft fingerprint: unique(email, tenant_id)

  Draft:
  ## Invariant: Email is unique per tenant
  No two users within the same tenant may share the same email address.

  Add this rule? (y/n/edit)
```

### Response handling

| User input | Action |
|------------|--------|
| `y` | Write draft to PENDING.md with all context. Move to next candidate. |
| `n` | Record in skip cache (`file:line` → pattern, date, reason if given). Discard draft. |
| `edit` | Wait for user correction. Refine draft. Re-present with diff. |

### Skip cache

Stored as `.business-logic/<repo>/skip-cache.json` to avoid re-suggesting the same
pattern in future scans:

```json
{
  "billing.rs:88": {
    "pattern": "if account.balance > 0",
    "rejected": "2026-06-20",
    "reason": "soft warning, not a hard rule"
  }
}
```

Checked before presenting any candidate. User can clear with skip cache.

---

## 7. Segment Placement

Once a candidate is confirmed by the user, it must be assigned to the correct
segment file. This applies to all detection sources (git, conversation, spec,
scan).

### Placement logic

1. Read the entry's Tags field
2. Look up each tag in SEGMENTS.md Tags column
3. The segment with the most matching tags wins
4. If no segment matches any tag, the entry goes into `split/xx-general.md`
   (created on first orphan — a catch-all segment)
5. If multiple segments match equally, ask the user:
   "This rule matches 'billing' and 'scheduling' equally. Which segment?"

### Tag assignment during detection

When drafting a candidate, assign Tags carefully — they drive placement:

```
Code found in: src/domain/billing/pricing.rs
Suggested Tags: billing, checkout, pricing
SEGMENTS.md lookup:
  - billing → 01-billing.md ✅ (match)
  - checkout → 01-billing.md ✅ (same segment)
  - pricing → 01-billing.md ✅ (same segment)
Result: 01-billing.md (3 tag matches)
```

If the source file path hints at a domain (e.g. `src/domain/billing/`), use
that as the primary tag source. If the source is cross-cutting (e.g.
`src/middleware/rate_limit.rs`), assign `security, rate-limit` tags which
route to the cross-cutting segment.

---

## 8. Source Verification

A deterministic check that every `Code:` entry points to a real location in
the codebase. Prevents hallucinated file paths, line numbers, and function
names from polluting the business logic document.

### Verification method (language-agnostic grep)

For a `Code:` entry like `src/domain/billing.rs:88 (fn: delete_account, if account.balance > 0)`:

| Check | Command | Pass condition |
|-------|---------|----------------|
| File exists | `test -f "src/domain/billing.rs"` | Exit code 0 |
| Line is valid | `wc -l < "src/domain/billing.rs"` | 88 ≤ total lines |
| Function name | `grep -n "fn delete_account\b" "src/domain/billing.rs"` | Returns a line near 88 (within ±5) |
| Construct | `grep -n "if account.balance > 0" "src/domain/billing.rs"` | Returns line 88 exactly |

Language-specific function patterns:

| Language | Function grep pattern |
|----------|----------------------|
| Rust | `fn <name>\b` |
| TypeScript/JS | `function <name>\b` or `<name>\s*[=(].*\)\s*(:\s*\w+)?\s*{` |
| Python | `def <name>\b` |
| Go | `func <name>\b` |
| SQL | `CONSTRAINT <name>` or `CHECK (<pattern>)` |
| YAML/TOML | `<key>:` |

### Verification points

| Point | When | Action on failure |
|-------|------|-------------------|
| **Detection** | After step 2, before fingerprint | Auto-correct line number if construct found nearby (±10 lines). If construct not found at all → flag with ⚠️. If file doesn't exist → block candidate. |
| **Write** | When user confirms, before saving to LOGIC.md | Re-verify all Code entries. If stale → block write, ask user to confirm corrected location or remove. |
| **Batch** | During `validate` | Re-verify all Code entries across all active rules. Flag stale entries with ❌. |

### Auto-correction logic

When the construct is found but at a different line than reported:

```
Reported:  billing.rs:88 (if account.balance > 0)
Found at:  billing.rs:92 (if account.balance > 0)
Difference: +4 lines

→ Auto-correct: silently update to line 92 (within ±10 threshold)
→ If difference > 10 lines: flag ⚠️, present to user as correction candidate
```

### Error states and handling

| State | Presentation | User action |
|-------|-------------|-------------|
| ✅ Verified | `✅ Source verified: path:line` | None (automatic) |
| ⚠️ Adjusted | `✅ Source adjusted: path:88→92 (construct found at 92)` | Optional review |
| ⚠️ Not found | `⚠️ "if account.balance > 0" not found at path:88. Line contains: ...` | Confirm corrected construct or remove entry |
| ❌ File missing | `❌ File "src/legacy/coupons.rs" does not exist` | Remove entry or provide correct path |

### Write-time re-verification

When the user confirms a candidate and the agent proceeds to Apply:

1. Re-run file exists + line valid + function + construct for every Code entry
2. If any check fails (file was renamed, line shifted after refactor):
   - Block the write
   - Present: `⛔ Write blocked: path:line no longer verifiable. Current state: ...`
   - User decides: correct path, remove entry, or force write with override
3. Only on user resolution → proceed to write
