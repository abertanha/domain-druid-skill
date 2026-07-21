#!/usr/bin/env bash
# hill-climb.sh — verify-work evaluation loop. Iterates: detect gaps → propose
# segments → re-verify until plateau (no new gaps resolved) or max iterations.
#
# Usage: hill-climb.sh <src-dir> <bl-dir> <patterns-dir> [--max-iter 20] [--batch 50] [--confidence high|medium|low]
#
# Each iteration:
#   1. Set manifest to empty (verify-work sees ALL source files as "new")
#   2. Run verify-work.py → detect files not referenced in any segment (gaps)
#   3. If 0 gaps → plateau reached → stop
#   4. Take first N gaps (--batch) to propose segments with code refs
#   5. Validate each new segment's frontmatter (rollback on failure)
#   6. Rebuild metadata (compile-segments.py --rebuild)
#   7. Re-run verify-work → check if gaps were resolved
#   8. If same gap count persists → plateau → stop
set -euo pipefail

SRC_DIR="${1:?Usage: hill-climb.sh <src-dir> <bl-dir> <patterns-dir> [--max-iter N] [--confidence high|medium|low]}"
BL_DIR="${2:?}"
PATTERNS_DIR="${3:?}"
shift 3

MAX_ITER=20
BATCH=50
CONFIDENCE="high"

while [ $# -gt 0 ]; do
  case "$1" in
    --max-iter) MAX_ITER="$2"; shift 2 ;;
    --batch) BATCH="$2"; shift 2 ;;
    --confidence) CONFIDENCE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$BL_DIR/.domain-druid/manifest.json"
BASELINE="$BL_DIR/.domain-druid/manifest.baseline.json"

# ── Helpers ──

measure_gaps() {
  local out
  out=$(python3 "$SCRIPT_DIR/verify-work.py" "$SRC_DIR" "$BL_DIR" 2>&1 || true)
  echo "$out" | awk -F'|' '/New gaps/ {gsub(/[* ]/, "", $3); print $3; exit}'
}

extract_gap_files() {
  local out="$1"
  echo "$out" | sed -n '/New Gaps/,/^## /p' | grep '^- `' | sed 's/^- `//; s/`.*//' || true
}

validate_segment() {
  python3 -c "
import yaml, re, sys
with open('$1') as f:
    c = f.read()
if not c.startswith('---'):
    sys.exit(1)
parts = c.split('---', 2)
if len(parts) < 3:
    sys.exit(1)
fm = yaml.safe_load(parts[1])
if not fm or 'id' not in fm:
    sys.exit(1)
if not re.match(r'^[\w-]+$', fm['id']):
    sys.exit(1)
" 2>/dev/null
}

# ── Setup ──

mkdir -p "$BL_DIR/.domain-druid" "$BL_DIR/split" "$BL_DIR/reviews"

if [ ! -f "$MANIFEST" ]; then
  bash "$SCRIPT_DIR/generate-manifest.sh" "$SRC_DIR" "$MANIFEST"
fi

# Save a baseline copy that never changes during the climb
if [ ! -f "$BASELINE" ]; then
  cp "$MANIFEST" "$BASELINE"
fi

python3 "$SCRIPT_DIR/compile-segments.py" "$BL_DIR" --rebuild 2>/dev/null || true

echo "⛰️ Hill Climb — $(basename "$SRC_DIR") [verify-work loop]"
echo "   Confidence gate: ${CONFIDENCE} | Max iterations: ${MAX_ITER} | Batch: ${BATCH}"
echo ""

# ── Main Loop ──

ITER=0
PREV_GAPS=999999
INITIAL_GAPS=""
ADDED=0
ROLLED=0

while [ $ITER -lt $MAX_ITER ]; do
  ITER=$((ITER + 1))

  # Set manifest to empty so verify-work sees ALL source files as "new changes"
  # (not just files that changed since a previous manifest). This lets us
  # re-evaluate the ENTIRE codebase against the growing SOURCE_MAP each iteration.
  echo '{}' > "$MANIFEST"

  VERIFY_OUT=$(python3 "$SCRIPT_DIR/verify-work.py" "$SRC_DIR" "$BL_DIR" 2>&1 || true)
  GAPS=$(echo "$VERIFY_OUT" | awk -F'|' '/New gaps/ {gsub(/[* ]/, "", $3); print $3; exit}')
  GAPS=${GAPS:-0}

  # Capture initial gap count on first iteration
  [ -z "$INITIAL_GAPS" ] && INITIAL_GAPS=$GAPS

  echo "   Iter ${ITER}: ${GAPS} gap(s)"
  if [ "$GAPS" -eq 0 ]; then
    echo "   ✅ No gaps — plateau reached"
    break
  fi

  if [ "$GAPS" -ge "$PREV_GAPS" ] && [ "$ITER" -gt 1 ]; then
    echo "   🔶 Plateau — ${GAPS} gap(s) remain (none resolved)"
    break
  fi

  # Extract gap file paths from verify-work output (limit to batch size)
  GAP_FILES=$(extract_gap_files "$VERIFY_OUT" | head -$BATCH) || true

  # Build a temporary gap report for propose-entries.sh
  GAP_TMP=$(mktemp)
  trap 'rm -f "$GAP_TMP"' EXIT
  {
    echo "# Verify-Work Gaps"
    echo ""
    echo "## Gaps (Confidence: ${CONFIDENCE})"
    echo ""
    for FP in $GAP_FILES; do
      echo "- [🆕 new] \`$FP\`:"
    done
  } > "$GAP_TMP"

  BEFORE=$(mktemp)
  ls "$BL_DIR/split/"*.md 2>/dev/null > "$BEFORE" || true

  bash "$SCRIPT_DIR/propose-entries.sh" "$GAP_TMP" "$BL_DIR/split" --auto --src-dir "$SRC_DIR" 2>/dev/null || true

  AFTER=$(mktemp)
  ls "$BL_DIR/split/"*.md 2>/dev/null > "$AFTER" || true
  NEW_SEGMENTS=$(comm -13 <(sort "$BEFORE") <(sort "$AFTER"))

  for SEG in $NEW_SEGMENTS; do
    if validate_segment "$SEG"; then
      ADDED=$((ADDED + 1))
    else
      rm -f "$SEG"
      ROLLED=$((ROLLED + 1))
    fi
  done

  python3 "$SCRIPT_DIR/compile-segments.py" "$BL_DIR" --rebuild 2>/dev/null || true

  PREV_GAPS=$GAPS
  rm -f "$GAP_TMP" "$BEFORE" "$AFTER"
done

CURRENT_GAPS=${GAPS:-0}
echo ""
echo "✅ Completed: ${INITIAL_GAPS} → ${CURRENT_GAPS} gaps in ${ITER} iteration(s)"
echo "   ${ADDED} segment(s) integrated"
[ "$ROLLED" -gt 0 ] && echo "   🔶 ${ROLLED} rolled back (invalid frontmatter)"
