# Rule Druid — Context-Aware Compliance Auditor

The Rule Druid is a read-only mode that audits new or modified code against
existing business rules. Unlike a naive linter, it understands middleware
stacks, delegation boundaries, compound rules, and cross-domain code.

## Triggers

| Trigger | Mode | Behavior |
|---------|------|----------|
| `audit <path>` | Explicit | Audit a specific file or module |
| `audit` (in PR context) | Explicit | Audit files changed in the current diff |
| Agent detects new endpoint during session | Auto-suggest | "I see a new refund endpoint. Run audit against it?" |

Rule Druid is always read-only — it never creates or modifies entries in
LOGIC.md.

## Algorithm

```
INPUT: file path + optional domain hint

SYMBOL SCAN → DOMAIN RESOLUTION → RULE LOAD → PER-RULE EVALUATION → REPORT
```

### 1. Symbol Scan

Read the target file once. Extract:

| Signal | Example | Purpose |
|--------|---------|---------|
| Middleware/guard setup | `app.use(authMiddleware)`, `router.use(requireAdmin)` | Detect middleware-level enforcement |
| Decorators | `@RequireAuth`, `@ValidateBody(schema)` | Detect decorator-level enforcement |
| Models/types | `Invoice`, `Stock`, `User` | Determine which domains are touched |
| Opaque function calls | `processRefund(amount, user)` | Detect delegation to mapped functions |
| Direct validation | `if amount > 1000 { return Err }` | Detect inline enforcement |
| Endpoint definition | `router.post('/refund', handler)` | Identify the handler scope |

Collect these into a symbol table:

```
Symbols for /api/v2/refund:
  Middleware: authMiddleware (router-level)
  Models:    Invoice, User
  Calls:     processRefund, restockItems
  Guards:    if amount > original_total { return Err }
  Endpoint:  router.post('/refund', refundHandler)
```

### 2. Domain Resolution

Match extracted symbols against SEGMENTS.md Tags column:

```
Symbols: Invoice, refund, processRefund
  → SEGMENTS lookup: "invoice" → billing, "refund" → billing
  → Domain: billing

Symbols: Stock, restockItems
  → SEGMENTS lookup: "stock" → inventory
  → Domain: inventory

Result: Transitive load — billing + inventory
```

If symbols touch multiple domains, load all matched domains. Use lightweight
loading (id + description + enforcement_points only) to conserve context.

### 3. Lightweight Rule Load

For each matched domain, load only:

```
02-refunds.md (from SEGMENTS.md → billing domain)
  BL-RULE-023: Refund max 30 days | type: inline | fn: checkRefundWindow
  BL-RULE-024: Refund > $1000 needs approval | type: compound | invariants: 2
  BL-RULE-025: Audit log on refund | type: delegation | fn: auditLog.refund
  BL-RULE-026: Refund requires auth | type: middleware | fn: authMiddleware

03-inventory.md (from inventory domain)
  BL-RULE-040: Restock triggers on refund | type: delegation | fn: restockItems
```

Full entry text is loaded only when a violation is detected and the Druid
needs to reference the exact invariant language.

### 4. Per-Rule Evaluation

For each active rule, check by its `enforcement_type`:

#### type: inline
```
Construct must be directly in the scanned file at the specified line.

Check: grep -n "if amount > original_total" /api/v2/refund.ts
Found at line 45 → ✅
Not found → ❌ Not enforced
```

#### type: middleware
```
Middleware must exist in the router/app stack wrapping the handler.

Check: Does the scanned file or its parent router config include
       authMiddleware at the wrapping level?

Found: router.use(authMiddleware) wraps all /refund routes → ✅
       Satisfied via router-level authMiddleware.
Not found → ❌ Missing auth guard. Add authMiddleware to the router.
```

#### type: decorator
```
Decorator must be present on the handler function.

Check: Is @RequireAuth above the handler definition?

Found: @RequireAuth above refundHandler → ✅
Not found → ❌ Missing @RequireAuth decorator.
```

#### type: delegation
```
Delegated function must be called in the scanned file AND mapped in the rule manifest.

Check 1 (Manifest): Is processRefund mapped as an enforcement point for BR-09?
  Yes → ✅ Satisfied via delegated call to processRefund [Mapped in manifest].

Check 2 (Shallow): If NOT mapped, check the call signature quickly.
  processRefund(amount, user) → implies it handles approval?
  → 🟡 Delegated: processRefund called but not mapped in manifest.
       Please verify it handles BR-09 and map it if confirmed.

Check 3 (Deep): If user responds "check for real":
  Read processRefund source, update manifest.
```

#### type: gateway
```
Enforced at API gateway level — trust, skip check entirely.

Check: None (trusted infra level).
→ ✅ Satisfied via API gateway (trust boundary).
```

#### type: compound
```
Rule has multiple invariants (AND conditions). Evaluate each independently.

Rule: "Refunds > $500 require manager approval AND mandatory reason string."
Invariants:
  - approval: if amount > 500 { approvalStatus == "approved" }
  - reason: reason.length > 0

Check approval: found at line 42 → ✅
Check reason:   NOT found → ❌

Result: ⚠️ Partial — 1/2 invariants enforced.
  ✅ Manager approval check found at L42.
  ❌ Mandatory 'reason' string validation missing.
```

### 5. Report Generation

```
🔍 RULE DRUID AUDIT: /api/v2/refund.ts

Domains Touched: Billing, Inventory
Deep Scan: False (file-scoped + router config)

✅ BR-01 (Auth): Satisfied via router-level authMiddleware.
✅ BR-04 (Inventory Restock): Satisfied via delegated call to
   restockItems() [Mapped in manifest].
⚠️ BR-09 (High Value Refunds): Partially enforced.
   Manager approval check found at L42.
   ❌ Mandatory 'reason' string validation missing.
❌ BR-12 (Refund Timeframe): Not enforced.
   Code allows refunds without date check.

Actionable suggestions:
1. Add `reason` validation before `processRefund()` to fully satisfy BR-09.
2. Add `orderDate` check matching BR-12 fingerprint cmp(gte, orderAge, 30)
   or update BR-12 if business logic has changed.
```

## Report Statuses

| Status | Meaning | Follow-up |
|--------|---------|-----------|
| ✅ Satisfied | Rule is enforced, directly or via delegation/middleware | None |
| 🟡 Delegated (unmapped) | Opaque call to function not in manifest | Verify and optionally map |
| ⚠️ Partial | Compound rule: some invariants enforced, some missing | Add missing checks |
| ❌ Not enforced | No enforcement found for this rule | Add implementation or propose rule change |
| ℹ️ Cross-domain | Code touches multiple domains | Confirms Druid loaded transitively |

## Integration with Existing Components

| Component | Used for |
|-----------|----------|
| SEGMENTS.md | Domain resolution — map symbols to segment files |
| enforcement_type (format.md) | Determine HOW to check each Code entry |
| FINGERPRINTS.md | Compare inline constructs against known fingerprints |
| RELATIONS.md | Trace cross-segment dependencies for compound rules |
| Source verification (auto-detect.md §8) | Reuse grep-based construct verification logic |
| Concerns section | Track rules flagged as "not enforced" for follow-up |

## Error States

| State | Druid response |
|-------|---------------|
| File doesn't exist | `❌ File not found at path. Verify the path and retry.` |
| No matching domain | `📋 No business rules found for this domain. Add rules via scan or discussion.` |
| All rules satisfied | `✅ All 5 rules in the billing domain are enforced.` |
| Scanned file delegates entirely | `🟡 All enforcement is delegated. Consider mapping called functions in the rule manifest for verification.` |
