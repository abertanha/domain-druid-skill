#!/usr/bin/env bash
# merge-parallel-results.sh — merges and deduplicates parallel scan reports
# Usage: merge-parallel-results.sh <merged-report.md> <report1.md> [report2.md ...]
set -euo pipefail

MERGED="${1:?Usage: merge-parallel-results.sh <merged> <r1> [r2] ...}"
shift

if [ $# -lt 1 ]; then
  echo "Error: need at least one report to merge" >&2
  exit 1
fi

TMP=$(mktemp)
DEDUP=$(mktemp)
trap 'rm -f "$TMP" "$DEDUP"' EXIT

# Scoring: Rules.ts > middleware > enums > constants
score_signal() {
  local LINE="$1"
  local SCORE=0
  echo "$LINE" | grep -qi 'rules\.ts' && SCORE=$((SCORE + 10))
  echo "$LINE" | grep -qi 'middle\|auth\|guard\|level' && SCORE=$((SCORE + 5))
  echo "$LINE" | grep -qi 'enum\|type.*=' && SCORE=$((SCORE + 3))
  echo "$LINE" | grep -qi 'MAX_\|MIN_\|TIMEOUT\|_LIMIT\|_TTL' && SCORE=$((SCORE + 1))
  echo "$SCORE"
}

# Phase 1 — Collect all unique file references across reports
echo "Merged Gap Report" > "$MERGED"
echo "" >> "$MERGED"
echo "Generated: $(date '+%Y-%m-%d %H:%M')" >> "$MERGED"
echo "Sources: $# reports" >> "$MERGED"
echo "" >> "$MERGED"

# Extract 🆕 new entries from each report
ALL_NEW=$(mktemp)
for RF in "$@"; do
  [ -f "$RF" ] || continue
  grep -E '^\s*- \[🆕 new\]' "$RF" >> "$ALL_NEW" 2>/dev/null || true
done

# Dedup by file path
while IFS= read -r LINE; do
  FP=$(echo "$LINE" | sed -n 's/.*`\([^`]*\)`.*/\1/p')
  [ -z "$FP" ] && continue
  if ! grep -q "$FP" "$DEDUP" 2>/dev/null; then
    echo "$FP|$LINE" >> "$TMP"
    echo "$FP" >> "$DEDUP"
  fi
done < "$ALL_NEW"

# Phase 2 — Score and rank
echo "## 🆕 New Candidates (deduplicated, ranked)" >> "$MERGED"
echo "" >> "$MERGED"
sort -t'|' -k1 "$TMP" > "$TMP.sorted"
while IFS='|' read -r FP LINE; do
  SCORE=$(score_signal "$LINE")
  echo "$SCORE|$LINE"
done < "$TMP.sorted" | sort -t'|' -k1 -rn | while IFS='|' read -r SCORE LINE; do
  echo "  [score:$SCORE] $LINE" >> "$MERGED"
done
rm -f "$TMP.sorted"

echo "" >> "$MERGED"
echo "---" >> "$MERGED"
echo "Total unique candidates: $(wc -l < "$DEDUP")" >> "$MERGED"
echo "Ranking: higher score = stronger business logic signal" >> "$MERGED"

rm -f "$ALL_NEW"
echo "Merged report: $MERGED"
