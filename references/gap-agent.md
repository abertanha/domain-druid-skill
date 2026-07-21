# Automated Gap Agent (`/gap-scan`)

Scans source files for potential business rule signals, cross-references against FINGERPRINTS.md, and outputs a gap report. The agent that does what was manual work during the nexus session.

## When to use

| Trigger | Behavior |
|---------|----------|
| `/gap-scan <path>` | Full gap analysis on a directory |
| `/gap-scan --quick <path>` | Quick scan — Rules.ts and enums only |
| After `/refresh-manifest` with changes | Auto-suggest: "N files changed. Run /gap-scan?" |

## What it detects

All projects:
| Signal | Pattern | Source |
|--------|---------|--------|
| Explicit rules | `*Rules.ts`, `*Rules.tsx` files | All validation/guard functions |
| Enumerations | `enum`, `const enum`, `type X = 'a' \| 'b'` | Schema/interface files |
| State machines | `if status ===`, `switch status` | Service files |
| Constants & limits | `MAX_`, `MIN_`, `_LIMIT`, `_TIMEOUT` | Any file |
| Validators | `validate()`, `isValid()`, `guard()` | Validator/validation files |
| DB constraints | `unique: true`, `required: true` | Schema/model files |
| Feature flags/gates | `if level ===`, `level-gated` | Routes, middleware |

Frontend-specific (auto-detected when `.tsx` files or React are present):
| Signal | Pattern | Source |
|--------|---------|--------|
| React Hooks | `useState`, `useEffect`, `useReducer` | `*Hook.ts`, `*hooks.tsx` |
| State Slices | `createSlice`, `reducer`, `initialState` | `*Slice.ts`, `store*.ts` |
| Context Providers | `createContext`, `Context.Provider` | `*Context.tsx`, `*Provider.tsx` |
| Validation schemas | `yup`, `zod`, `.shape()`, `.string()` | `*Validator.ts`, `*Schema.ts` |
| API layers | `axios`, `fetch(`, `baseURL`, `interceptor` | `*Service.ts`, `*Api.ts` |
| Test-encoded invariants | `expect(`, `it(`, `describe(` | `*.test.tsx`, `*.spec.tsx` |

## Workflow

```
/gap-scan <path>
    │
    ├── Phase 1 — Load fingerprints
    │   Read FINGERPRINTS.md, build set of known fingerprints
    │
    ├── Phase 2 — Discover source files
    │   Walk <path> for .ts/.tsx/.js/.jsx/.py/.rs files
    │   (extensions auto-detected; frontend repos also scan .tsx/.jsx)
    │   If manifest exists, skip unchanged files
    │
    ├── Phase 3 — Scan for signals
    │   For each file, extract rule signals (see table above)
    │   For each signal, compute candidate fingerprint
    │
    ├── Phase 4 — Cross-reference
    │   Compare candidate fingerprints against known set
    │   Classify: ✅ already mapped / 🆕 new / ⚠️ possible drift
    │
    ├── Phase 5 — Coverage Summary
    │   Compute total source files vs files with code refs → coverage %
    │   List top-20 largest undocumented files (likely business logic)
    │
    ├── Phase 6 — Confidence Tiers
    │   Tag each signal with confidence level (🔴 High / 🟡 Medium / 🔵 Low / ⚪ Test)
    │
    └── Phase 7 — Report
        Output markdown report to chat and save to reviews/<date>-gap-report.md
        In --verify mode, compare against previous report: resolved vs remaining
```

## Phase 3 — Signal Extraction

For each new/modified file, run these extractors:

### Rules.ts extractor
Every function/export in a `*Rules.ts` file is a strong candidate. Extract:
- Function name → candidate title
- Parameter validation → candidate rule description
- Inline comments → rule rationale
- File:line → Code entry

### Enum extractor
For every `enum` / `type Union = 'a' | 'b'` in schema files:
- Enum name + values → candidate Definition
- If enum values contain business meaning (statuses, types, origins) → strong candidate

### Constant extractor
For every `const FOO = <number>` matching pattern `[A-Z_]{3,}`:
- Name → candidate Limit
- Value + unit → description

### Middleware extractor
For middleware files:
- Auth/guard conditions → candidate Rule
- Level checks → candidate RBAC rule

### Frontend-specific extractors (when project type = frontend)

#### Hook extractor
For every custom hook (`useXxx` naming):
- State transitions → candidate Rule
- Effect dependencies → candidate Invariant
- Memoized computations → candidate Definition

#### Slice extractor
For Redux/Zustand slices:
- Reducer cases → candidate Rule (state transitions)
- Initial state → candidate Definition
- Async thunks → candidate Rule (API call outcomes)

#### Context extractor
For context providers:
- Provided values → candidate Definition
- State shape → candidate Invariant

#### Validator extractor
For schema validators (yup/zod):
- Field rules → candidate Rule
- Refinements → candidate Invariant

#### API Service extractor
For API service layers:
- Endpoint definitions → candidate Rule
- Request/response transforms → candidate Definition
- Error handling → candidate Invariant

#### Test invariant extractor
For test files:
- Assertions → candidate Invariant
- Test descriptions → candidate Rule (encoded business logic)

## Phase 4 — Fingerprint Cross-Reference

Fingerprint format for matching:

| Signal type | Fingerprint pattern |
|-------------|-------------------|
| Enum | `enum-<name>-<values-count>` |
| Rule | `<file>-<function-name>-<guard-type>` |
| Limit | `<const-name>-<value>` |
| Middleware | `<middleware-name>-<guard-condition>` |

### Dedup logic

1. Normalize candidate into canonical fingerprint
2. Look up fingerprint in FINGERPRINTS.md
3. If match found → mark as "already mapped" with Trace ID
4. If no match → mark as new candidate

## Phase 5 — Report Format

```
GAP REPORT — <repo> — 2026-07-17
=====================================
Scanned: 142 files (12 new, 3 modified, 127 unchanged)
Known fingerprints: 67

✅ Already mapped (4):
  - `enum ProposalSituation` → FINGERPRINT-012 (seg 02-proposal-lifecycle.md)
  - ...

🆕 NEW candidates (8):
  - DoNotDisturb.ts:13 — `cellphoneAndCpf` (enum value not in existing seg)
    Add as Definition to existing DND segment? (y/n/seg)
  - LinkType — 20 values not documented anywhere
    Create new segment 19-model-enums.md? (y/n)
  - Aws.ts:146-214 — 5 bucket configs not documented
    ...
⚠️ Possible drift (1):
  - AppForgeRules.ts:49 — `fogedAppProductId` (typo in field name)
    Fingerprint mismatch vs existing rule
```

Each candidate is presented for y/n/edit/assign-segment response. On confirmation, the agent follows the standard Ingestion Loop (write to segment or PENDING.md).

## Integration with Manifest

If `/refresh-manifest` was run first, the Gap Agent automatically:
- Skips unchanged files (95%+ of the codebase)
- Only scans new/modified files
- Focuses analysis on the delta, not the full tree

This makes `/gap-scan` efficient even for repos like core (127 segments, 600+ source files).

## Usage

```
/gap-scan                              # scan entire source dir (default)
/gap-scan source/features/AppForge/    # scan a specific directory
/gap-scan --quick                      # Rules.ts + enums only, skip constants
/gap-scan --output gaps.md             # save report to file
```

## Token impact

Gap Agent runs as a Task subagent (not in main context). The report is brought back as a single message. Main context cost: ~300t for this reference doc when loaded.
