# Context Loading Strategy

This file defines the token budget and lazy-loading rules to keep the AI's
context window lean. The goal: never load more than **2000 tokens** of business
logic at any time.

## Token Budget Table

| File/Document | Est. size | When loaded | Frequency |
|--------------|-----------|-------------|-----------|
| INDEX.md (if split exists) | ~200t | **Always** | Every session |
| SEGMENTS.md (if split exists) | ~300t | **Always** | Every session (deterministic tag→file lookup) |
| FINGERPRINTS.md | ~200t | **Always** | Every session (needed for dedup on every detection) |
| PENDING.md | ~200t | **Always** | Every session |
| Concerns section | ~200t | **Always** | Every session |
| LOGIC.md (if no split) | ≤1000t | **Always** | Every session |
| Segment files (e.g. `split/01-billing.md`) | ≤1000t each | **On demand** — via SEGMENTS.md tag lookup | Per task |
| RELATIONS.md | ~300t | **On demand** — `/validate-bl` or impact analysis | On command |
| CHANGELOG.md | grows unbounded | **Never by default** — only via `/history-bl` | On command |
| Archive/ | grows unbounded | **Never** — only via explicit reference | On command |
| `.last-sync` | ~10t | **As needed** — check timestamp during auto-detect | Every session start |

### Active budget (always-loaded): ≤1100 tokens (INDEX + SEGMENTS + FINGERPRINTS + PENDING + Concerns)
### On-demand budget (task-matched): ≤1000 tokens
### Reserve: remainder of context window

## Lazy Loading Rules

### Rule 1: INDEX.md is the entry point

When `split/` exists, INDEX.md is always loaded. It provides a compact map of
all segments and their entry counts. For browsing only — loading decisions use
SEGMENTS.md.

### Rule 2: SEGMENTS.md drives loading

SEGMENTS.md is the deterministic lookup for mapping a task to segment files.
The agent follows this algorithm:

```
1. Extract domain keywords from the task description
   Task: "Add gift card support to checkout"
   Keywords: [gift, card, checkout, payment]

2. Look up each keyword in SEGMENTS.md Tags column
   - "checkout" → 01-billing.md (tags: billing, checkout, payment)
   - "payment"  → 01-billing.md (same)
   - "gift"     → no match (new domain)
   - "card"     → no match

3. Collect matching segment files
   - 01-billing.md (matched by checkout, payment)

4. Add always-load segments (Glossary, Decisions)
   - 03-glossary.md
   - 04-decisions.md

5. Load up to 2 task-matched segments
   - 01-billing.md ✅ (1 segment, within limit)
   - 03-glossary.md ✅ (always load)
   - 04-decisions.md ✅ (always load)

6. If task matches > 2 segments, ask user:
   "Your task spans 4 segments. Which 1-2 are most relevant?"
```

### Rule 3: Always-load segments

The following segments are loaded on every session:
- **Glossary** (definitions — referenced by most rules)
- **Decisions** (design choices — small file)

Marked as `Always load: Yes` in SEGMENTS.md.

### Rule 4: Max 2 task-matched segments

Never load more than 2 domain segments from tag matching. If the task matches
more than 2, the agent asks the user which to prioritize instead of guessing.

### Rule 5: FINGERPRINTS.md is always loaded

Dedup detection runs on every new signal. FINGERPRINTS.md is a compact index
(~200t) that must be available for the fingerprint comparison step during
every ingestion cycle.

### Rule 6: PENDING.md is always visible

Because it represents work-to-be-done, PENDING.md is always loaded. Its token
size is bounded by review cycles (clear after batch review).

### Rule 7: Concerns are on the surface

Concerns are either a section in LOGIC.md or a file in `split/`. They are
always loaded because they surface active problems (contradictions, drift,
overdue reviews, traceability gaps).

### Rule 7: CHANGELOG.md is opt-in only

The changelog grows unbounded over time. It is never auto-loaded. The user
must explicitly request `/history-bl` to view it.

### Rule 9: Archive is invisible

Archived entries are excluded from all auto-loading. They exist for reference
only when explicitly retrieved.

## Token Monitoring

After every session, the skill logs the peak token usage for business logic:

```
Session summary:
  Always-loaded: 1050 tokens (INDEX.md + SEGMENTS.md + FINGERPRINTS.md + PENDING.md + Concerns)
  On-demand: 920 tokens (01-billing.md, 03-glossary.md)
  Total: 1970 tokens (within 2000 budget)
```

If the budget is exceeded, the skill should:
1. Flag which load is consuming too much
2. Suggest splitting or archiving the heavy segment
3. Reduce on-demand load by loading only matching entries (not full segment)

## Mini Context Load (session start)

On session start, the skill performs a mini load to check state:

```
1. Check .last-sync exists → if not, prompt for /init-bl
2. Read LOGIC.md or INDEX.md → determine if split exists
3. Read SEGMENTS.md (if split exists) → load tag→segment mapping
4. Read FINGERPRINTS.md → load fingerprint index for dedup
5. Read PENDING.md → check pending count
6. Read Concerns → check active issues
7. Check .last-sync timestamp → if stale, flag for auto-detect
```

Total: ~1000 tokens for session awareness.

## Full Load (on task assignment)

When a task is assigned:

```
1. Mini load (above) — already done
2. Match task domain to segment Tags
3. Load 1-2 matching segment files
4. Optionally load RELATIONS.md (if impact analysis needed)
```

Total: ~1500 tokens for a full working set.
