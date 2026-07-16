# Auto-Split

When LOGIC.md exceeds 1000 tokens, the skill automatically reorganizes it
into multiple files under `.business-logic/<repo>/split/`. This keeps every file
small, fast to load, and domain-focused.

**⚠️ Enforcement is MANDATORY and immediate.** See Hallucination Guardrail #3
in SKILL.md: pre-write estimate, post-write verify, never defer.

## Token Budget

| Threshold | Action |
|-----------|--------|
| LOGIC.md ≤ 1000 tokens | Keep as single file (no split) |
| LOGIC.md > 1000 tokens | Split into `split/` directory |
| Any segment file > 1000 tokens | Recurse — split that segment further |
| Split yields < 3 segments? | No — keep at previous level (anti-fragmentation) |

## Token Estimation Formula

Use this deterministic formula for ALL estimates:

```
estimated_tokens = ceil(byte_count / 3.5)
```

Where `byte_count` is obtained from `wc -c <file>` or an in-memory
equivalent for pre-write estimates (count characters in the content
string to be written).

For pre-write estimation (file not yet on disk):
```
pre_write_bytes = len(content_string.encode('utf-8'))
estimated_tokens = ceil(pre_write_bytes / 3.5)
```

If content is not yet assembled, estimate per-entry:
- Each rule entry (with all fields): ~150-250 tokens depending on Code entries
- Each definition entry: ~100-150 tokens
- Segment header + index: ~50 tokens
- Add 20% overhead for safety margin

## Pre-Write Checks (MANDATORY — Step 0 of Apply)

Before writing ANY file to `.business-logic/<repo>/`:

1. **Assemble** the full content of the target file (LOGIC.md or segment)
   in memory, including the new entry being added.
2. **Estimate** using `ceil(content_bytes / 3.5)`.
3. **If estimate > 1000 tokens:**
   - Do NOT write the file as-is
   - If writing to LOGIC.md (unsplit): immediately plan the split structure
     and write directly to segment files. Never write LOGIC.md > 1000 tokens
     even temporarily.
   - If writing to a segment that already exists: split that segment into
     sub-segments (recursive split).
4. **If estimate ≤ 1000 tokens:** safe to write. Proceed.

## Post-Write Verification (MANDATORY — Step 5 of Apply)

Immediately after writing every file:

1. **Measure** actual byte count: `wc -c <file>`
2. **Estimate**: `ceil(byte_count / 3.5)`
3. **If estimate > 1000 tokens:** VIOLATION. Revert, run split, re-verify.
4. **If estimate ≥ 800 tokens:** flag in Concerns as near-limit.

## Split Procedure

### Step 1: Parse sections

Identify all top-level entries in LOGIC.md. Each entry is delimited by
`## <Tag>: <Title>` headings.

### Step 2: Cluster by domain

Group entries by their Tags and semantic proximity:

```
Tag cluster        → Segment     → File
billing, checkout  → Billing     → split/01-billing.md
providers, sched   → Scheduling  → split/02-scheduling.md
(all definitions)  → Glossary    → split/03-glossary.md
(all decisions)    → Decisions   → split/04-decisions.md
```

Rules for clustering:
- **Definitions** always go into a `glossary` segment (or `xx-glossary.md`)
- **Decisions** always go into a `decisions` segment (or `xx-decisions.md`)
- **Cross-cutting** entries (tags: security, compliance, audit, logging,
  observability, rate-limit) go into a dedicated cross-cutting segment when
  they don't have a stronger domain-specific primary tag. If they DO have a
  domain primary tag (e.g. `billing`), they stay in the domain segment.
- All other entries are grouped by their dominant tag
- If an entry has multiple tags, primary tag determines segment; secondary
  tags are preserved and create cross-segment references in RELATIONS.md
- A cross-cutting segment is always created during split even if initially
  empty — it provides a natural home for future cross-domain rules

### Step 3: Write segment files

Each segment file has:

```
# <Segment Title>

Tags: <comma-separated domain tags>
Load when: the task mentions <keywords that match this segment>
This segment covers: <short description of what's inside>

## Index
- Rule: Free shipping on orders over $100
- Limit: Daily outgoing transfer limit
- Definition: Active subscriber

---

<Full entries, one after another.>

## Concerns
<Segment-specific concerns.>
```

### Step 4: Rewrite LOGIC.md as index

```
# Business Logic

This file is an index. Individual segment files live in `split/`.

## Segments
| File | Domain | Tags | Entries | Last update |
|------|--------|------|---------|-------------|
| 01-billing.md | Billing, Payments | billing, checkout | 12 | 2026-06-20 |
| 02-scheduling.md | Scheduling | providers, sched | 8 | 2026-06-18 |
| 03-glossary.md | Definitions | glossary | 15 | 2026-06-15 |

## Concerns
<Global concerns (across all segments).>

## Quick access
- Rules: 18 entries
- Limits: 5 entries
- Definitions: 15 entries
- Decisions: 4 entries
- Exceptions: 2 entries

Total: 44 entries across 4 segments (~3500 tokens)
```

### Step 5: Generate INDEX.md

```
.business-logic/<repo>/split/INDEX.md

# Segment Index

## Segments
[Same table as LOGIC.md, but more detailed]

## All Rules (flat list, sorted by title)
- Emergency appointment override [02-scheduling.md]
- Free shipping on orders over $100 [01-billing.md]
- Single promotion per order [01-billing.md]
- ...

## All Definitions
- Active subscriber [03-glossary.md]
- Premium account [03-glossary.md]
- ...

[Same for Limits, Decisions, Exceptions]

## Cross-Segment Dependencies
- Free shipping → depends on → Discount calculation [01-billing.md]
- Premium tier → overrides → Standard tier [01-billing.md]
- Emergency slot → overrides → No double-booking [02-scheduling.md]
```

### Step 6: Regenerate RELATIONS.md

Scan all segment files to build the dependency/override graph. Output format:

```
# Relations

## Depends On
| Rule | Depends on | In file |
|------|-----------|---------|
| Free shipping > $100 | Discount calculation | 01-billing.md |
| Single promotion per order | Promo code validation | 01-billing.md |

## Overrides
| Rule | Overrides | In file |
|------|-----------|---------|
| Emergency appointment | No double-booking | 02-scheduling.md |
| Premium tier | Standard tier limits | 01-billing.md |

## Related (non-directional)
| Rule | Related to | In file |
|------|-----------|---------|
| Free shipping > $100 | Promotional discount stacking | 01-billing.md |
```

### Step 7: Update LOGIC.md Concerns

Move segment-specific concerns into segment files. Keep global concerns
in LOGIC.md.

### Step 8: Generate SEGMENTS.md

Created at `.business-logic/<repo>/SEGMENTS.md`. Provides a deterministic lookup
table so the agent knows exactly which segment file to load for a given task.

```
# Segment Map

This file is auto-generated. Do not edit manually.

| Tags | Segment file | Always load | Max entries |
|------|-------------|-------------|-------------|
| billing, checkout, payment, invoice | split/01-billing.md | No | 20 |
| scheduling, provider, appointment | split/02-scheduling.md | No | 20 |
| glossary, definition | split/03-glossary.md | Yes | 30 |
| decision | split/04-decisions.md | Yes | 20 |
| security, compliance, audit, logging | split/05-cross-cutting.md | No | 10 |

## Loading rules
1. Glossary and Decisions segments are always loaded (they are small and
   referenced by most rules).
2. Domain segments are loaded on demand: the agent extracts keywords from
   the task description, looks them up in the Tags column, and loads up to
   2 matching segments.
3. If the task matches more than 2 segments, the agent asks the user which
   are most relevant.
```

Column rules:
- **Tags**: union of all entry Tags in the segment, deduplicated
- **Always load**: Yes for Glossary and Decisions; No for domain segments
- **Max entries**: auto-calculated from segment size bound (1000t / ~50t per entry)

SEGMENTS.md is regenerated whenever LOGIC.md is updated or segments are
added/removed.

### Step 9: Compact INDEX.md (if >20 segments)

If the number of segments exceeds 20, INDEX.md groups them by category to
keep the lookup scannable:

```
# Segment Index

## Billing & Payments
- 01-billing.md (12 entries)
- 02-pricing.md (8 entries)

## Scheduling & Providers
- 03-scheduling.md (8 entries)
- 04-availability.md (5 entries)

## Definitions & Decisions
- 05-glossary.md (15 entries)
- 06-decisions.md (4 entries)

## Cross-cutting
- 07-security.md (6 entries)
```

Grouping is derived from the segment Title prefix or dominant tag cluster.
No sub-directory nesting — just logical grouping within INDEX.md.

## Recursive Split

If a segment file exceeds 1000 tokens after initial split:

1. Within the segment, identify sub-domains (secondary tag clusters)
2. Split the segment into sub-segments: `01-billing/01-checkout.md`
3. Update INDEX.md with sub-entry structure
4. The parent segment file becomes an index for its sub-segments

```
split/
├── INDEX.md
├── 01-billing.md  (index → split/01-billing/)
│   └── 01-billing/
│       ├── index.md
│       ├── 01-checkout.md
│       ├── 02-pricing.md
│       └── 03-subscriptions.md
├── 02-scheduling.md
└── 03-glossary.md
```

## Anti-Fragmentation Guard

Do NOT split if:
- The resulting directory would have fewer than 3 files (keep consolidated)
- A segment would have fewer than 2 entries (merge with related segment)
- The split would save fewer than 100 tokens per file (not worth it)

These guards prevent premature splitting on small projects.

## Reporting Token Estimates

When presenting the split plan, use the formula `ceil(bytes / 3.5)` and
report every file:

```
Pre-write estimate: target file would be ~1350 tokens (4730 bytes / 3.5).
→ Exceeds 1000 threshold. Splitting directly.

Split plan:
  01-billing.md:      ~450 tokens (1570 bytes / 3.5)
  02-scheduling.md:   ~380 tokens (1330 bytes / 3.5)
  03-glossary.md:     ~280 tokens (985 bytes / 3.5)
  05-cross-cutting.md:  ~0 tokens (empty — reserve for future)
  INDEX.md:            ~90 tokens (320 bytes / 3.5)
  SEGMENTS.md:         ~60 tokens (215 bytes / 3.5)
  Total:              ~1260 tokens
  Peak per file:       ~450 tokens ✅ (all under 1000)

Proceed with split? (y/n)
```

For post-write verification:
```
✅ 01-billing.md: ~450 tokens (1570 bytes / 3.5) — OK
⚠️ 02-scheduling.md: ~820 tokens (2870 bytes / 3.5) — near limit, flag in Concerns
```
