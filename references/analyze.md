# Analysis & Cross-Reference

After a raw business logic signal is detected, the skill analyzes it and
cross-references against existing entries before presenting to the user.

## Extraction Pipeline

```
Raw signal → Categorize → Structure → Fingerprint → Dedup → Present → Confirm → Propose
```

### 1. Categorize

Determine what Type the signal represents:

| Signal characteristic | Type |
|----------------------|------|
| "X can/cannot Y" | Rule |
| "X must always be Y" | Invariant |
| "X has a maximum of N" | Limit |
| "X is defined as Y" | Definition |
| "We chose X over Y because..." | Decision |
| "X is exempt from Y when..." | Exception |

### 2. Structure

Map the raw signal into the entry format, including exact code location:

```
Heading:   <derive from signal>
Body:      <restate in clear prose>
Type:      <from categorization>
Fingerprint: <computed from invariant>
Tags:      <infer from context — domain, feature area>
Tracks:    <issue ID if mentioned>
Origin:
  Type:    <source of signal — Feature Request, Discussion, Scan, etc.>
  ID:      <tracking reference>
  Title:  "<short description>"
Source:
  Spec:   <file:line (section)>
  Test:   <file:line (fn name)>
Code:
  <Layer>: <file:line (fn name, construct)>
Established: <today's date>
```

### 3. Fingerprint

Extract the core invariant from the signal and normalize it into a canonical
fingerprint string (see [format.md](format.md) — Fingerprint field).

```
Raw invariant: if subtotal > 100
Fingerprint:   cmp(gt, subtotal, 100)

Raw invariant: UNIQUE(email, tenant_id)
Fingerprint:   unique(email, tenant_id)

Raw invariant: count(subscriptions) <= 5
Fingerprint:   cmp(lte, count(subscriptions), 5)
```

### 4. Dedup Check

Read FINGERPRINTS.md (always loaded) and compare fingerprint against all
existing entries:

| Match result | Meaning | Action |
|-------------|---------|--------|
| Exact match | Same constraint detected elsewhere | Mark candidate as "already mapped" to existing Trace ID. Present for user: "Add as enforcement point?" |
| No match | Genuinely new rule | Proceed as new candidate |

This is a lightweight string comparison — no expensive semantic analysis.
Partial/fuzzy matching is intentionally skipped; if fingerprints differ,
treat as distinct and let the user decide during validation.

### 5. Present (Interactive Confirmation)

Before anything reaches PENDING.md, the candidate must pass user confirmation.
Every candidate is classified as **active** (has verified Code entries) or
**proposed** (developer intent, no Code entries). Hallucination guardrail:
never present a conversation-originated rule as if it were already in code.

Present the draft with verification status and classification:

```
🆕 Found potential rule in src/domain/billing.rs:92 (fn: delete_account)

✅ Source verified: src/domain/billing.rs:92 → "if account.balance > 0" confirmed
📋 Classification: active (1 verified Code enforcement point)

Draft:
## Rule: Cannot delete account with positive balance
An account with a positive balance cannot be deleted.
This prevents accidental loss of funds.

- Type: Domain Rule
- Status: active
- Fingerprint: cmp(gt, account.balance, 0)
- Code:
  - Backend: src/domain/billing.rs:92 (fn: delete_account, if account.balance > 0)

Correct? (y/n/edit)
```

For a **proposed** rule (from conversation, no code location):

```
🆕 Proposed rule from discussion

📋 Classification: proposed (no Code entries — developer intent)

Draft:
## Rule: Cannot delete account with positive balance
An account with a positive balance cannot be deleted.

- Type: Domain Rule
- Status: proposed
- Proposed: 2026-06-20

This rule has no implementation yet. It will be tracked as proposed
awaiting future implementation. Correct? (y/n/edit)
```

| User response | Action |
|---------------|--------|
| `y` (confirm) | Assign Trace ID, write to PENDING.md with correct Status |
| `n` (reject) | Record in skip cache (if from code) or discard (if conversation), discard |
| `edit` (refine) | Accept user corrections, re-present draft with diff |

### 6. Cross-Reference (Post-Confirmation)

After the user confirms a candidate, cross-reference it against existing entries.
If the entry has `type: compound`, the Rule Druid evaluates each invariant
independently during compliance checks (see [rule-druid.md](rule-druid.md)).

#### Contradiction Detection

Two rules contradict when their Invariants or Bodies are logically inconsistent:

```
LOGIC.md says:
  shipping_charge == 0  WHEN  subtotal > 100  (free shipping over $100)

New signal says:
  "Premium members always get free shipping"

Result: POSSIBLE OVERLAP. Premium members with subtotal ≤ $100 are covered
by new rule but not by existing rule. Present as:

```
⚠️ Contradiction: "Free shipping > $100" vs "Premium always free"

  How to resolve?
    (a) Add premium exception to existing rule — (recommended — reason: preserves threshold for non-premium, minimal change | trade-offs: adds condition complexity, need to verify premium+ coupon edge case)
    (b) Replace with "Premium members always get free shipping" — (reason: simpler single rule | trade-offs: non-premium customers lose clear threshold, existing tests may break)
    (c) Keep both as-is (manual resolution later) — (reason: no immediate change | trade-offs: pending items accumulate, gap persists until batch review)
```
```

#### Gap Detection

A behavior described in code/tests that has no corresponding entry:

```
Found: test_refund_denied_after_30_days()
Existing: no refund rules in LOGIC.md at all

Result: Gap — entire refund domain is undocumented.
Propose: new entry for refund time window limit.
```

#### Drift Detection

Existing entry differs from observed behavior:

```
LOGIC.md says:
  Limit: Daily outgoing transfer limit = $10,000 (standard)

Code says:
  STANDARD_DAILY_LIMIT = 15_000

Result: Drift — code implements $15,000 but logic doc says $10,000.
Flag: "🔍 Drift: 'Daily outgoing transfer limit' — doc says 10k, code says 15k"
```

#### Clarification Detection

New signal adds nuance to an existing rule without contradicting it:

```
LOGIC.md says:
  "Promotional discounts cannot be combined."

New signal says:
  "Store-credits and gift-card balances can be stacked with promotions."

Result: Clarification — the existing rule needs updating to exclude
store-credits and gift-cards from the "cannot be combined" prohibition.
Propose: update to the existing entry.
```

#### Supersession Detection

New signal renders an old rule obsolete:

```
LOGIC.md says:
  Rule: "International orders require manual approval"

New signal says:
  "We automated international order approval via the compliance API"

Result: Supersession — old rule is replaced.
Propose: mark existing as superseded, reference new rule.
```

## Categorization Matrix

When proposing to PENDING.md, classify the relationship:

| Category | Tag | Action |
|----------|-----|--------|
| New | `🆕 new` | Propose as new entry |
| Contradiction | `⚠️ conflict` | Raise inline immediately |
| Clarification | `📝 clarify` | Propose as update to existing entry |
| Drift | `🔍 drift` | Propose as update to existing entry |
| Gap | `📌 gap` | Propose as new entry |
| Supersession | `♻️ supersede` | Propose replacement + deprecation |

## Dedup Detection

Business rules are often duplicated across layers (frontend, backend, database).
The dedup check prevents creating duplicate entries for the same rule.

### How it works

1. Every candidate has a fingerprint (normalized constraint string)
2. FINGERPRINTS.md is always loaded (~200t)
3. Candidate fingerprint is compared against all existing fingerprints
4. Match → existing rule, not a new one

### Presenting a dedup match

When a duplicate is found, present it differently:

```
### ⬜ Already mapped — "Max 5 active subscriptions"
  Trace ID: BL-RULE-012
  Code: src/domain/billing.rs:150 (const MAX_ACTIVE_SUBS = 5)
  Existing enforcement points:
    - Backend: src/domain/pricing.rs:44
    - Database: migration 005

  Add this as a new enforcement point? (y/n)
```

### Cross-layer value drift

If the same fingerprint is found but the **value differs**, flag it:

```
⚠️ Cross-layer drift detected for BL-RULE-003 ("Free shipping > $100"):

  Backend: threshold = $100 (src/domain/pricing.rs:44)
  Frontend: threshold = $150 (src/web/validation.ts:22)
  Expected: all enforcement points should use the same value.

  Which is correct?
    (a) Backend ($100) — (recommended — reason: backend enforces at write time and is the source of truth | trade-offs: frontend may briefly show stale shipping info until next sync)
    (b) Frontend ($150) — (reason: frontend drives user-facing validation | trade-offs: backend accepts orders the frontend would reject, creating inconsistent UX)
    (c) Neither — enter correct value
```

### What dedup is NOT

- It is NOT a full semantic comparison of rule bodies
- It is NOT a scan of all existing entries (only fingerprint match)
- It is NOT fuzzy matching — only exact fingerprint equality
- If fingerprints differ, candidates are treated as distinct and left for
  the user to decide during batch validation

## Source Attribution

Every proposed entry must include exact code location that traces back to
the signal origin:

- **Code analysis**: `file-path:line-range (fn: function_name, construct)`
- **Git diff**: `file-path:line-range (commit hash, fn: function_name)`
- **Conversation**: `session/YYYY-MM-DD.md (message N)`
- **Spec/PRD**: `spec-file.md:line-number (section name)`
- **Test**: `test-file.rs:line-number (fn: test_name)`
- **Scan**: `file-path:line-range (fn: function_name, construct)`

This ensures every rule can be verified back to its exact origin in the codebase.
