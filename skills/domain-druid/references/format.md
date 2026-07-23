# Entry Format

Each business logic entry is an atomic unit describing one domain concept.
Entries are stored in LOGIC.md (or split/ segment files) and are separated
by blank lines or `---` dividers.

## Single Entry Structure

```
## <Tag>: <Short Title>

<Body — free-form natural language, 1-5 sentences. Describes WHAT the rule is
and WHY it exists. Be precise enough to write a test against but keep it
readable prose.>

- Type: <Type>
- Status: <Status>
- Fingerprint: <normalized constraint>
- Trace ID: <BL-RULE-NNN>
- Tags: <tag list>
- Tracks: <tracking ID>
- Origin:
  - Type: <Origin Type>
  - ID: <origin ID>
  - Title: "<origin title>"
  - URL: <origin URL>
- Source:
  - Spec: <file:line (context)>
  - Test: <file:line (fn: name)>
- Code:
  - <Layer>: <file:line (fn: name, construct, type: <type>)>
  - <Layer>: <file:line (fn: name, construct, type: <type>)>
- Established: <YYYY-MM-DD>
- Changed: <YYYY-MM-DD (reason)>
- Last reviewed: <YYYY-MM-DD>
- Next review: <YYYY-MM-DD>
- Deprecated: <YYYY-MM-DD (reason, replacement)>
- Invariants:
  - <formal-ish predicate>
- Related:
  - <Type>["<Title of related entry>"]
```

## Fields

### Tag (heading prefix)

The heading must start with one of these taxonomy tags:

| Tag | Purpose |
|-----|---------|
| `Rule:` | A domain rule — "Orders over $100 get free shipping" |
| `Invariant:` | A constraint that must always hold — "An order always has ≥1 item" |
| `Limit:` | A numerical or temporal bound — "Max 5 active subscriptions" |
| `Definition:` | A domain term — "An active subscriber is..." |
| `Decision:` | An explicit architectural or product choice — "No refunds on downgrade" |
| `Exception:` | An override to a rule — "Managers can bypass the 5-subscription limit" |

### Type

| Value | When to use |
|-------|-------------|
| Domain Rule | Behavioral rule the system enforces |
| Invariant | Constraint that must always be true |
| Limit | Numerical, temporal, or capacity bound |
| Definition | Clarifies a domain term or concept |
| Decision | Records a deliberate choice and its rationale |
| Exception | Documents a carve-out from a standard rule |

### Status

| Value | Meaning |
|-------|---------|
| active | Current and in force — has at least one verified Code enforcement entry |
| pending | Draft awaiting user confirmation in PENDING.md (transient — never persisted) |
| proposed | Developer-defined intent — no Code entries yet, awaiting implementation |
| deprecated | Still present but shouldn't be relied on |
| superseded | Replaced by another entry (should have Related link) |
| archived | Moved to archive/ directory |

**Distinction between pending and proposed:**
- **pending** is a short-lived state within PENDING.md — the entry has been
  presented to the user and awaits their y/n/edit. It is NEVER written to
  LOGIC.md with this status.
- **proposed** is a persisted state — the user confirmed the rule as developer
  intent, but no code implementation exists yet. It has a `Proposed:` date
  and no `Code:` entries. Tracked in Concerns as awaiting implementation.
- **active** requires at least one verified `Code:` entry. A proposed rule
  transitions to active when the developer implements it and a scan detects
  the code.

### Trace ID

Unique identifier for backward traceability. Embeddable in source code comments
to link code back to the rule.

```
- Trace ID: BL-RULE-003
```

**Forward trace** (rule → code): Trace ID is referenced in `- Code:` entries.
**Backward trace** (code → rule): The same ID is embedded as a comment in source code:

```rust
// BL-RULE-003: Free shipping on orders over $100
if subtotal > 100 {
    shipping_charge = 0;
}
```

The auto-detector scans for existing `BL-RULE-NNN` annotations in code during
detection. The `validate` check verifies every active Trace ID has at least
one matching annotation in the codebase (and vice versa for orphan annotations).

Format: `BL-RULE-NNN`, `BL-DEF-NNN`, `BL-DEC-NNN`, `BL-LIM-NNN` depending on
entry Type. Sequential numbering per type. Auto-assigned on first write.

### Fingerprint

A normalized, grep-compatible string representing the core constraint.
Used for deduplication — when a new signal arrives, its fingerprint is computed
and compared against FINGERPRINTS.md.

```
- Fingerprint: cmp(gt, subtotal, 100)
- Fingerprint: cmp(gt, account.balance, 0)
- Fingerprint: cmp(lte, count(subscriptions), 5)
- Fingerprint: unique(email, tenant_id)
- Fingerprint: cmp(eq, role, "admin")
```

**Normalization rules:**

| Raw invariant | Fingerprint |
|---------------|-------------|
| `subtotal > 100` | `cmp(gt, subtotal, 100)` |
| `subtotal > 100.00` | `cmp(gt, subtotal, 100)` |
| `cart.subtotal > 100` | `cmp(gt, subtotal, 100)` |
| `this.account.balance > 0` | `cmp(gt, account.balance, 0)` |
| `count(subscriptions) <= 5` | `cmp(lte, count(subscriptions), 5)` |
| `email UNIQUE` | `unique(email)` |
| `UNIQUE(email, tenant_id)` | `unique(email, tenant_id)` |
| `role == "admin"` | `cmp(eq, role, admin)` |
| `subscription.status != "cancelled"` | `cmp(neq, subscription.status, cancelled)` |

Strip:
- Object/namespace prefixes (`cart.`, `this.`, `account.`)
- Trailing zeros on numbers (`100.00` → `100`)
- String value quotes (`"admin"` → `admin`)

Fingerprints are stored in `.business-logic/<repo>/FINGERPRINTS.md` as an index:

```
## Fingerprint Index
| Fingerprint | Trace ID | Tags |
|-------------|----------|------|
| cmp(gt, subtotal, 100) | BL-RULE-003 | billing, checkout |
| cmp(gt, account.balance, 0) | BL-RULE-007 | accounts |
| cmp(lte, count(subscriptions), 5) | BL-RULE-012 | billing |
```

### Source

Documents where the rule originates — requirements and verification.

```
- Source:
  - Spec: spec/checkout-v2.md:42 (section "Free Shipping")
  - Test: tests/checkout_test.rs:88-105 (fn: test_free_shipping_over_100)
```

Each entry: `file:line-range (context)`.

| Sub-field | Purpose |
|-----------|---------|
| Spec | Requirement document, PRD, or specification |
| Test | Test file that verifies this rule |

Multiple entries per sub-field are separated by newlines with the same prefix.

### Code

Documents where the rule is enforced in the codebase. Each entry includes
the layer (Backend, Frontend, Database, Config), file path, function, the
exact construct, and an enforcement type that tells the Rule Druid *how* to
verify this entry.

```
- Code:
  - Backend: src/domain/pricing.rs:44 (fn: calculate_shipping, if subtotal > 100, type: inline)
  - Backend: src/middleware/auth.rs:22 (fn: authMiddleware, type: middleware, scope: router)
  - Backend: src/services/refund.rs:88 (fn: processRefund, type: delegation)
  - Frontend: src/web/validation.ts:22 (fn: validateCart, if cart.subtotal > 100, type: inline)
  - Database: db/migrations/005_add_check.sql (CHECK(subtotal > 100), type: inline)
```

### enforcement_type

Tells the Rule Druid how to verify this enforcement point:

| Type | When to use | Druid verification |
|------|-------------|--------------------|
| inline | Construct is directly in the handler/function | grep at specified line in scanned file |
| middleware | Applied at router/app level, wraps handlers | Check middleware stack wrapping the handler |
| decorator | Applied as annotation on handler function | Check for decorator above handler definition |
| gateway | Enforced at API gateway / infra level | Trust — skip check, always reported as satisfied |
| delegation | Delegated to a mapped function (trust boundary) | Check manifest for mapping, then trust |
| compound | Rule has multiple invariant conditions | Evaluate each invariant independently, report partial |

Default is `inline`. Specify explicitly when the enforcement mechanism
differs from a direct inline check.

Layer labels are flexible — match the project's architecture:

| Common layers | Use when |
|--------------|----------|
| Backend | Server-side enforcement (Rust, Python, Go, etc.) |
| Frontend | Client-side validation (JS, TS, React, etc.) |
| Database | DB constraints, triggers, migrations |
| Config | Feature flags, YAML/TOML configs, env vars |
| Worker | Background job, queue processor |
| API Gateway | Middleware, rate limiting, auth |

Each enforcement point is checked during `validate` and `audit` for:
- File still exists (no stale references)
- Line range still contains matching logic (no drift)
- Code annotation matches (backward trace)
- Enforcement type determines verification method (see Rule Druid)

### Tags

Comma-separated domain tags for filtering and context-aware loading.

```
- Tags: billing, checkout, promotions
- Tags: scheduling, providers
```

### Tracks + Origin

The `Tracks` field holds the primary tracking ID from the issue tracker.
The `Origin` block provides full provenance.

```
- Tracks: ISSUE-238
- Origin:
  - Type: Feature Request
  - ID: ISSUE-238
  - Title: "Free shipping for premium members"
  - URL: https://github.com/acme/app/issues/238
```

Origin Types:

| Origin Type | When used |
|-------------|-----------|
| Feature Request | New feature or capability |
| Bug Fix | A bug that revealed a previously unknown rule |
| Discussion | A conversation with stakeholders |
| Spec | A PRD or specification document |
| Test | A test that encoded an implicit rule |
| Code Analysis | Found during code review or refactoring |
| Scan | Found via explicit `scan` |

Multiple origins per entry — repeat the block:

```
- Tracks: ISSUE-238, DISC-042
- Origin:
  - Type: Feature Request
  - ID: ISSUE-238
  - Title: "Free shipping for premium members"
  - URL: https://github.com/acme/app/issues/238
- Origin:
  - Type: Discussion
  - ID: DISC-042
  - Title: "Free shipping threshold decided with PO"
```

### Invariants

Optional list of formal-ish predicates. These are not a formal spec language
but should be precise enough to derive test assertions and generate fingerprints.

```
- Invariants:
  - shipping_charge == 0  WHEN  subtotal > 100  AND  method == "standard"
  - count(applied_promotions) <= 1
  - forall appt1, appt2 in provider_schedule(provider, day):
      appt1.end_time + buffer <= appt2.start_time
```

Each invariant that expresses a simple constraint (comparison, uniqueness,
count bound) should produce a fingerprint automatically during ingestion.

### Related

Cross-references to other entries by their exact heading title.

```
- Related:
  - Rules["Free shipping on orders over $100"]
  - Limits["Max discount per order"]
  - Definitions["Active subscriber"]
```

Use the Type prefix (`Rules["..."]`, `Limits["..."]`, `Definitions["..."]`,
`Invariants["..."]`, `Decisions["..."]`, `Exceptions["..."]`).

## Complete Example

```
## Rule: Free shipping on orders over $100

Any order with a subtotal exceeding $100 qualifies for free standard shipping
(5-7 business days). Promotional discounts are deducted before the $100
threshold is evaluated.

- Type: Domain Rule
- Status: active
- Fingerprint: cmp(gt, subtotal, 100)
- Trace ID: BL-RULE-003
- Tags: billing, checkout
- Tracks: ISSUE-238
- Origin:
  - Type: Feature Request
  - ID: ISSUE-238
  - Title: "Free shipping for premium members"
  - URL: https://github.com/acme/app/issues/238
- Source:
  - Spec: spec/checkout-v2.md:42 (section "Free Shipping")
  - Test: tests/checkout_test.rs:88-105 (fn: test_free_shipping_over_100)
- Code:
  - Backend: src/domain/pricing.rs:44 (fn: calculate_shipping, if subtotal > 100, type: inline)
  - Frontend: src/web/validation.ts:22 (fn: validateCart, if cart.subtotal > 100, type: inline)
  - Database: db/migrations/005_add_check.sql (CHECK(subtotal > 100), type: inline)
- Established: 2026-06-20
- Last reviewed: 2026-06-20
- Next review: 2026-07-20
- Invariants:
  - shipping_charge == 0  WHEN  subtotal > 100  AND  method == "standard"
  - subtotal_evaluation_uses_post_discount_price
- Related:
  - Rules["Promotional discount stacking"]
  - Limits["Max discount per order"]
```

## Concerns Section

Auto-managed section at the bottom of LOGIC.md or as a standalone file after split.

```
## Concerns
- ⚠️ Contradiction: "Free shipping > $100" vs "Premium always free" — unresolved
- 📌 Rule "Legacy coupon stacking" missing Code enforcement entries
- 🔍 Rule "Daily transfer limit" past Next review date
- 🆕 3 proposals in PENDING.md awaiting batch review
- 🔙 Trace ID BL-RULE-007 has no code annotation in source
```

Prefix map:

| Prefix | Meaning |
|--------|---------|
| ⚠️ Contradiction | Two entries conflict |
| 📌 Missing info | Entry is incomplete |
| 🔍 Review due | Entry past its Next review date |
| 🆕 Pending | Proposals awaiting validation |
| 🔙 Trace gap | Trace ID missing from code annotations |
