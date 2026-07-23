#!/usr/bin/env bash
# accept-proposals.sh — stage proposals from proposals/ into split/
# Usage: accept-proposals.sh <bl-root> [--all|--id <id>|--interactive]
#   --all         : consolidate all proposals by domain group
#   --id <id>     : accept a single proposal by filename (no consolidation)
#   --interactive : show proposals grouped by domain, confirm per group
#   --compile     : run compile-segments.py --fix --rebuild after accepting
set -euo pipefail

BL_DIR="${1:?Usage: accept-proposals.sh <bl-root> [--all|--id <id>|--interactive|--compile]}"
MODE="all"
COMPILE=false

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE="all"; shift ;;
    --id) MODE="id"; ID="$2"; shift 2 ;;
    --interactive) MODE="interactive"; shift ;;
    --compile) COMPILE=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

PROP_DIR="$BL_DIR/proposals"
SPLIT_DIR="$BL_DIR/split"

if [ ! -d "$PROP_DIR" ]; then
  echo "No proposals/ directory found at $PROP_DIR"
  exit 0
fi

shopt -s nullglob
PROPOSALS=("$PROP_DIR"/*.md)
shopt -u nullglob

if [ ${#PROPOSALS[@]} -eq 0 ]; then
  echo "No proposals to accept."
  exit 0
fi

SCRIPT_DIR="$(dirname "$0")"
CONSOLIDATE="$SCRIPT_DIR/consolidate-proposals.py"

case "$MODE" in
  all)
    echo "Consolidating ${#PROPOSALS[@]} proposal(s) by domain..."
    python3 "$CONSOLIDATE" "$BL_DIR"
    ACCEPTED=${#PROPOSALS[@]}
    ;;

  id)
    ACCEPTED=0
    SKIPPED=0
    accept_one() {
      local FILE="$1"
      local BASENAME
      BASENAME=$(basename "$FILE")
      local TARGET="$SPLIT_DIR/$BASENAME"
      if [ -f "$TARGET" ]; then
        echo "  SKIP $BASENAME (already exists in split/)"
        SKIPPED=$((SKIPPED + 1))
        return
      fi
      mv "$FILE" "$TARGET"
      echo "  ACCEPTED $BASENAME"
      ACCEPTED=$((ACCEPTED + 1))
    }

    FOUND=false
    for F in "${PROPOSALS[@]}"; do
      BASENAME=$(basename "$F" .md)
      if [ "$BASENAME" = "$ID" ]; then
        accept_one "$F"
        FOUND=true
        break
      fi
    done
    if [ "$FOUND" = false ]; then
      echo "No proposal found with id '$ID'"
      exit 1
    fi
    echo ""
    echo "Done: $ACCEPTED accepted, $SKIPPED skipped"
    ;;

  interactive)
    echo "Found ${#PROPOSALS[@]} proposals, grouped by domain:"
    echo ""

    # Build domain groups via python
    DOMAINS=$(python3 -c "
import sys, yaml, re
from pathlib import Path
prop_dir = Path('$PROP_DIR')
groups = {}
for f in sorted(prop_dir.glob('*.md')):
    c = f.read_text()
    m = re.match(r'^---\s*\n(.*?)\n---', c, re.DOTALL)
    domain = 'general'
    if m:
        try:
            fm = yaml.safe_load(m.group(1)) or {}
            domain = fm.get('domain', 'general') or 'general'
        except:
            domain = 'general'
    groups.setdefault(domain, []).append(f.name)
for d in sorted(groups):
    print(f'  {d} ({len(groups[d])} files):')
    for n in groups[d]:
        print(f'    {n}')
    print()
print('--END--')
")

    echo "$DOMAINS"
    echo -n "Consolidate all groups by domain? (Y/n) "
    read -r RESP </dev/tty
    if [ -z "$RESP" ] || [ "$RESP" = "y" ] || [ "$RESP" = "Y" ]; then
      python3 "$CONSOLIDATE" "$BL_DIR"
      ACCEPTED=${#PROPOSALS[@]}
    else
      echo "Skipped all proposals."
      ACCEPTED=0
    fi
    ;;
esac

if [ "$COMPILE" = true ] && [ "${ACCEPTED:-0}" -gt 0 ]; then
  echo ""
  echo "Running compile-segments.py --fix --rebuild..."
  python3 "$SCRIPT_DIR/compile-segments.py" "$BL_DIR" --fix --rebuild
fi
