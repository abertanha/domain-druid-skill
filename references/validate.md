# Validation Flows

Proposed changes go through validation before being applied. The skill uses
two modes depending on the nature of the change.

## Inline Validation (Critical)

Triggered for: contradictions, breaking changes, ambiguous logic, drift.

### Flow

```
1. Detect: ⚠️ contradiction or 🔍 drift or ambiguous rule
2. Present to user immediately:
   "I found a contradiction:

    LOGIC.md says:   Free shipping for orders > $100
    Test implies:    Free shipping for all premium accounts

    These overlap for premium accounts with orders ≤ $100.
    How should I resolve this?
    a) Premium overrides the $100 threshold (premium always free)
    b) Both conditions apply ($100 threshold still required, premium is
       about speed/type, not cost)
    c) Something else"

3. On user response:
   - If clear → apply update
   - If "let me think" → move to PENDING.md with ⚠️ flag
```

### When to use inline vs batch

| Situation | Mode |
|-----------|------|
| Direct contradiction | Inline |
| Code vs doc drift | Inline |
| Ambiguous rule phrasing | Inline |
| Simple new rule (no conflicts) | Batch |
| Clarification on existing rule | Batch |
| Routine limit/threshold update | Batch |

## Batch Validation (Routine)

Accumulates proposals in PENDING.md. Reviewed via `/review-bl`.

### PENDING.md format

```
# Pending Proposals

Generated: 2026-06-20 14:30 UTC (3 proposals)

---

## Proposal 1: 🆕 New — Rule "Emergency appointment override"
- Origin: Discussion with PO about urgent care scheduling

[Full entry draft with Trace ID, Fingerprint, Source, and Code fields as they would appear in LOGIC.md]

---

## Proposal 2: 📝 Clarify — Rule "Daily outgoing transfer limit"
- Current: "A standard account holder cannot transfer more than $10,000..."
- Proposed: "A standard account holder cannot transfer more than $15,000..."
- Reason: CODE_DRIFT — code implements 15k, doc says 10k

[diff format of changes]

---

## Proposal 3: ♻️ Supersede — Rule "International orders require manual approval"
- Reason: Manual approval automated via compliance API
- Proposed: Mark as superseded, new rule documents automated flow

[Full replacement entry + status change for old entry]
```

### Review flow (`/review-bl`)

```
1. Load PENDING.md
2. Present summary: "3 proposals: 1 new, 1 clarify, 1 supersede"
3. For each proposal, present the entry draft and ask:
   "Proposal 1: Add rule 'Emergency appointment override' — OK? (y/n/edit)"
4. On "y" → apply to LOGIC.md, log in CHANGELOG.md
5. On "n" → discard or archive to PENDING.md with reason
6. On "edit" → modify entry based on feedback, re-present
7. After all reviewed → clear approved items from PENDING.md
8. Run post-validation (see below)
```

## Post-Validation

After any update to LOGIC.md:

1. **Check size** — if > 1000 tokens, trigger split (see split.md)
2. **Regenerate RELATIONS.md** — rebuild dependency graph
3. **Update Concerns section** — remove resolved concerns, check for new ones
4. **Update CHANGELOG.md** — log what changed and why
5. **Clear applied proposals** from PENDING.md

## Drift Detection (`/validate-bl`)

Cross-references LOGIC.md against the current codebase.

### What it checks

| Check | Method |
|-------|--------|
| Limit values match code | Grep for constants vs LOGIC.md values |
| Rules have code coverage | Grep test files for rule-related test names |
| No undefined behavior | Check for code paths without matching rules |
| Definitions are referenced | Check that LOGIC.md terms are used in code |

### Traceability verification

**Proposed rules are exempt** from Code source checks — they intentionally
have no implementation yet. Only active rules are verified.

| Check | Method | Flag |
|-------|--------|------|
| Forward trace | `grep` for file:function:construct at each `Code:` entry path:line | `📌 Missing Code source` |
| Backward trace | `grep -r "BL-RULE-NNN" src/` for each active Trace ID | `🔙 Missing code annotation` |
| Stale file references | `test -f <path>` for each `Code:` entry | `❌ Stale source — file not found` |
| Stale line references | `grep -n "<construct>" <path>` — verify output line matches recorded line | `❌ Stale source — logic not found at line` |
| Active without Code | Entries with `Status: active` but zero `Code:` entries | `❌ Invalid — active rule has no Code source` |
| Orphan annotations | `grep -r "BL-RULE-NNN" src/` for IDs with no matching entry or only proposed entries | `❌ Orphan annotation — no matching rule` |
| Cross-layer drift | Compare construct values across multiple `Code:` entries for the same rule | `⚠️ Cross-layer value mismatch` |
| Proposed tracking | Entries with `Status: proposed` — list with proposal date | `📌 Proposed awaiting implementation` |

### Cross-layer drift check

For entries with multiple `Code:` enforcement points, compare the actual
values across layers:

```
⚠️ Cross-layer drift for BL-RULE-003 ("Free shipping > $100"):

  Backend: threshold = $100 (src/domain/pricing.rs:44, if subtotal > 100)
  Frontend: threshold = $150 (src/web/validation.ts:22, if cart.subtotal > 150)
  Database: $100 (migration 005, CHECK(subtotal > 100))

  Frontend (150) disagrees with Backend (100) and Database (100).
  Which is correct? (backend/frontend/database/neither — enter value)
```

### Output

```
/validate-bl results:

✅ 12 rules verified (code matches doc)
⚠️ 2 drifts found:
   - "Daily transfer limit": doc=10k, code=15k
   - "Max active subscriptions": doc=3, code=5
📌 2 proposed rules awaiting implementation:
   - "Cannot delete account with balance > 0" (proposed 2026-06-20)
   - "Email must be unique per tenant" (proposed 2026-06-19)
🔙 2 Trace IDs missing code annotations in source
   - BL-RULE-007: no // BL-RULE-007 found in any source file
   - BL-RULE-011: code annotation deleted (last found at src/legacy/coupons.rs before removal)
❌ 1 stale reference: "Legacy coupon stacking" → src/legacy/coupons.rs:88 (file removed)
❌ 1 invalid: "Legacy price override" is status=active but has zero Code entries
❌ 1 orphan annotation: // BL-RULE-099 found in src/web/pricing.ts:15 but no matching rule
⚠️ 1 cross-layer drift: BL-RULE-003 ($100 backend vs $150 frontend)
```

Each flagged item gets resolved inline or moved to PENDING.md.
