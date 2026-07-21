# Parallel Scanning (`/scan-parallel`)

Distributes domain scanning across multiple Task subagents, each responsible for a directory subtree. Results are merged into a single gap report or segment write batch. Reduces wall-clock time for large codebases.

## When to use

| Scenario | Serial scan | Parallel scan |
|----------|-------------|---------------|
| core (127 segments, 600+ files) | 5-10 min | ~2 min |
| nexus (22 segments, 200+ files) | 3-5 min | ~1 min |
| Feature-specific (e.g., /gap-scan features/) | 1-2 min | N/A (single dir) |

Use `/scan-parallel` when scanning the entire source tree of a large repo. For single-directory scans, use `/gap-scan` directly.

## How it works

```
/scan-parallel
    │
    ├── Phase 1 — Topology discovery
    │   List top-level source directories: features/, models/, services/,
    │   middlewares/, globals/, validators/, utilities/, vendor/, routes/
    │
    ├── Phase 2 — Load shared context
    │   Read FINGERPRINTS.md — all agents need this for dedup
    │   Read SOURCE_MAP.md — agents need this to skip mapped files
    │
    ├── Phase 3 — Dispatch to subagents
    │   For each top-level directory, launch a Task subagent:
    │     Agent 1: scan features/ → extract signals → return candidates
    │     Agent 2: scan models/  → extract signals → return candidates
    │     Agent 3: scan services/ → extract signals → return candidates
    │     Agent 4: scan globals/  → extract signals → return candidates
    │     ...
    │
    ├── Phase 4 — Merge results
    │   Collect all candidates from subagents
    │   Deduplicate (a rule found in both features/ and models/ → one entry)
    │   Cross-reference against FINGERPRINTS.md
    │
    └── Phase 5 — Report and apply
        Present merged gap report
        On confirmation, write segments following standard ingestion loop
```

## Subagent prompt template

Each subagent receives:

```
You are scanning <subdir> in <repo> for business logic signals.

You have:
- FINGERPRINTS.md (known rules for dedup)
- SOURCE_MAP.md (files that already have segment coverage)

Your task:
1. List all .ts files in <subdir>
2. For each file, extract rule signals:
   - *Rules.ts files → extract all validation/guard functions
   - Schema files → extract enums, validators, constraints
   - Service files → extract state machines, validation chains
   - Constants → extract MAX/MIN/TIMEOUT/LIMIT
3. For each signal, compute a candidate fingerprint
4. Check against the provided fingerprint set
5. Return ONLY new candidates (skip already mapped ones)

Return format for each candidate:
- file:line
- type: Rule | Definition | Limit | Invariant
- title: short name
- fingerprint: canonical string
- description: 1-2 sentence explanation
```

## Agent orchestration

The main agent:
1. Reads shared context (FINGERPRINTS.md, SOURCE_MAP.md)
2. Splits source tree into balanced chunks (by file count, not directory depth)
   - Chunk size target: 30-50 files per agent
   - For 600 files → ~12-20 agents
   - For 200 files → ~4-7 agents
3. Launches all subagents concurrently (OpenCode Task tool)
4. Waits for all agents to complete
5. Merges results (dedup by fingerprint)
6. Presents merged report to user

## Merge rules

| Scenario | Resolution |
|----------|------------|
| Same fingerprint from 2 agents | Keep one, note both locations as Code entries |
| Same title, different fingerprints | Keep both — different aspects of same domain |
| Agent returns error | Log and continue; flag for manual review |
| Agent times out | Retry once with smaller scope |

## Usage

```
/scan-parallel                          # scan entire source tree
/scan-parallel --chunks 5              # force 5 subagents (for smaller repos)
/scan-parallel --quick                 # Rules.ts + enums only, skip deep service analysis
/scan-parallel --output gaps.md        # save merged report to file
```

## Token impact

Main context: ~400t for this reference doc + shared context. Subagent contexts are independent. Total token cost is higher than serial scan, but wall-clock time is much lower. The main context is freed after dispatching — it waits for results.
