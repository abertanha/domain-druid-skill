#!/usr/bin/env bash
set -euo pipefail

META_DIR="${META_DIR:-$HOME/.config/opencode/skills/domain-druid/meta}"
ANALYSIS_LOG="$META_DIR/suggestions.md"
THRESHOLD_FILE="$META_DIR/threshold"

THRESHOLD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold) THRESHOLD="$2"; shift 2 ;;
    *) echo "usage: meta-suggest.sh [--threshold <n>]"; exit 1 ;;
  esac
done

if [ -z "$THRESHOLD" ] && [ -f "$THRESHOLD_FILE" ]; then
  THRESHOLD=$(cat "$THRESHOLD_FILE")
fi
THRESHOLD="${THRESHOLD:-3}"

echo "Running meta analysis (threshold=$THRESHOLD)..."
"$(dirname "$0")/meta-analyze.sh" "$THRESHOLD"

echo ""
echo "=== Last suggestions ==="
if [ -f "$ANALYSIS_LOG" ]; then
  cat "$ANALYSIS_LOG"
else
  echo "(no suggestions yet)"
fi
