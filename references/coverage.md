# Coverage Visualization (`/coverage`)

Maps source directories against documented segments to visually identify uncovered areas.

## Command

### `/coverage`

**Workflow:**

```
Step 1 — List source directories
  tree -d -L 2 <source-dir> --charset=utf-8
  Shows top-level domain directories (e.g., business/Proposal/, models/, rules/)

Step 2 — Load known file index
  Parse all segment Code: entries and table-formatted code references
  Build set of "covered" source paths

Step 3 — For each source directory, compute coverage:

  | Source Dir | Files | Covered | Uncovered | Coverage |
  |------------|-------|---------|-----------|----------|
  | business/Proposal/ | 61 | 24 | 37 | 39% |
  | business/User/ | 34 | 12 | 22 | 35% |
  | rules/auth/ | 30 | 8 | 22 | 27% |
  | models/ | 149 | 15 | 134 | 10% |
  | ... | ... | ... | ... | ... |

Step 4 — Highlight uncovered directories
  Directories with < 20% coverage are flagged:
  "⚠️ models/ — 149 files, only 15 covered (10%)"

Step 5 — Show tree with coverage annotation

  source/
  ├── business/                     # 73% coverage
  │   ├── Proposal/                 # 39%
  │   ├── User/                     # 35%
  │   ├── Product/                  # 42%
  │   └── ImportLeads/              # 🆕 0% — no segment coverage
  ├── models/                       # ⚠️ 10%
  ├── rules/                        # 27%
  ├── helpers/                      # 🆕 0%
  └── job/                          # 🆕 0%
```

## Example output

```
📊 COVERAGE REPORT — indiky-server — 2026-07-20
=============================================
Source: source/
Segments: 37
Known files: 187 / 1,598 (11.7%)

  Source Dir              Files  Covered  Coverage
 ─────────────────────────────────────────────────
  business/Proposal/        61      24      39%   
  business/User/            34      12      35%   
  business/Product/         38      16      42%   
  business/Invite/           9       8      89%   
  models/                  149      15      10%  ⚠️
  rules/                    63      17      27%   
  helpers/                  65       0       0%  🆕
  job/                      27       0       0%  🆕
  scripts/                 110       0       0%  🆕
  ...

🆕 Uncovered directories (0% coverage):
  - helpers/ (65 files)
  - job/ (27 files)
  - scripts/ (110 files)
  - services/ (24 files)
  - middlewares/ (39 files)
  - validators/ (1 file)

⚠️ Low coverage (< 20%):
  - models/ (10% — 149 files, 15 covered)
  - schemas/ (12% — 137 files, 17 covered)
  - interfaces/ (8% — 141 files, 11 covered)
  - queries/ (5% — 80 files, 4 covered)
```

## Token impact

~200t when loaded during `/coverage` execution.
