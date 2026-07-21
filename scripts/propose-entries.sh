#!/usr/bin/env bash
# propose-entries.sh — generates draft segment entries from gap signals
# Usage: propose-entries.sh <gap-report> <output-dir> [--review|--auto] [--src-dir <dir>]
#   --review : print candidates to stdout for y/n (default)
#   --auto   : write directly to new segment files
set -euo pipefail

GAP_REPORT="${1:?Usage: propose-entries.sh <gap-report> <output-dir> [--review|--auto]}"
OUT_DIR="${2:?Usage: propose-entries.sh <gap-report> <output-dir> [--review|--auto]}"
MODE="${3:---review}"
SRC_DIR=""

# Parse optional --src-dir argument
if [ "$MODE" = "--src-dir" ]; then
  SRC_DIR="$4"
  MODE="${5:---review}"
elif [ "${4:-}" = "--src-dir" ]; then
  SRC_DIR="$5"
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

mkdir -p "$OUT_DIR" 2>/dev/null || true

# Extract all 🆕 new entries from gap report
grep -E '^\s*- \[🆕 new\]' "$GAP_REPORT" > "$TMP" || {
  echo "No 🆕 new candidates found in gap report."
  exit 0
}

# Derive fingerprint prefix from project context
# Priority 1: from SRC_DIR (passed via --src-dir)
# Priority 2: from .business-logic/<repo> pattern in OUT_DIR
# Priority 3: from gap report filename (e.g. "core-gap-quick.md" → "core")
FP_PREFIX=""
if [ -n "$SRC_DIR" ]; then
  FP_PREFIX=$(basename "$(dirname "$SRC_DIR")" 2>/dev/null || echo "")
fi
if [ -z "$FP_PREFIX" ]; then
  FP_PREFIX=$(echo "$OUT_DIR" | sed -n 's|.*\.business-logic/\([^/]*\).*|\1|p')
fi
if [ -z "$FP_PREFIX" ]; then
  FP_PREFIX=$(basename "$(dirname "$OUT_DIR")" 2>/dev/null || echo "")
fi
if [ -z "$FP_PREFIX" ] || [ "$FP_PREFIX" = "tmp" ]; then
  FP_PREFIX=$(basename "$GAP_REPORT" | sed -E 's/-gap-.*//' 2>/dev/null || echo "app")
fi

# Detect project type from src dir or file paths
detect_project_type() {
  if [ -n "$SRC_DIR" ] && find "$SRC_DIR" -maxdepth 3 -name '*.tsx' -type f 2>/dev/null | head -1 | grep -q .; then
    echo "frontend"
    return
  fi
  if grep -q '\.tsx' "$TMP" 2>/dev/null; then
    echo "frontend"
    return
  fi
  echo "backend"
}

PROJECT_TYPE=$(detect_project_type)

normalize_path() {
  local p="$1"
  p="${p#source/}"
  p="${p#src/}"
  p="${p#./}"
  if [[ "$p" == *"/src/"* ]]; then
    p="${p#*/src/}"
  fi
  echo "$p"
}

# Detect layer name from file path and project type
detect_layer() {
  local p="$1"
  local norm="${p#source/}"
  norm="${norm#src/}"
  norm="${norm#./}"
  if [[ "$norm" == *"/src/"* ]]; then
    norm="${norm#*/src/}"
  fi
  local first_dir=$(echo "$norm" | cut -d'/' -f1)
  if [ "$PROJECT_TYPE" = "frontend" ]; then
    if echo "$first_dir" | grep -qi 'component\|hook\|context\|provider'; then
      echo "Frontend"
    elif echo "$first_dir" | grep -qi 'service\|api\|repository'; then
      echo "Service"
    elif echo "$first_dir" | grep -qi 'store\|slice\|state'; then
      echo "State"
    elif echo "$first_dir" | grep -qi 'util\|helper\|lib'; then
      echo "Utility"
    elif echo "$first_dir" | grep -qi 'test\|spec\|__test__'; then
      echo "Test"
    else
      echo "Frontend"
    fi
  else
    if echo "$first_dir" | grep -qi 'service\|api\|repository\|gateway'; then
      echo "Service"
    elif echo "$first_dir" | grep -qi 'controller\|handler\|router\|route'; then
      echo "Controller"
    elif echo "$first_dir" | grep -qi 'model\|schema\|entity'; then
      echo "Model"
    elif echo "$first_dir" | grep -qi 'middleware\|guard\|auth'; then
      echo "Middleware"
    elif echo "$first_dir" | grep -qi 'test\|spec\|__test__'; then
      echo "Test"
    else
      echo "Service"
    fi
  fi
}

CANDIDATE_COUNT=0
while IFS= read -r LINE; do
  # Extract file path: - [🆕 new] `source/path/file.ts`
  FILEPATH=$(echo "$LINE" | sed -n 's/.*`\([^`]*\)`.*/\1/p')
  [ -z "$FILEPATH" ] && continue

  CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))

  # Strip extension from basename (handle .ts, .tsx, .js, .jsx)
  BASENAME=$(basename "$FILEPATH")
  BASENAME=${BASENAME%.tsx}
  BASENAME=${BASENAME%.ts}
  BASENAME=${BASENAME%.jsx}
  BASENAME=${BASENAME%.js}

  # Derive domain and title from path
  DIR=$(dirname "$FILEPATH")
  DOMAIN=$(echo "$DIR" | sed 's|source/||; s|src/||; s|/|-|g')
  TITLE=$(echo "$BASENAME" | sed -E 's/([A-Z])/ \1/g; s/^ *//' | sed 's/Rules/Rules/g')

  # Derive fingerprint using project prefix instead of hardcoded 'indiky-'
  FP="$FP_PREFIX-$(echo "$DOMAIN-$BASENAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')"

  # Derive type with better detection for I* interface files
  TYPE="Rule"
  if echo "$BASENAME" | grep -qiE '\b(test|spec)\b'; then
    TYPE="Invariant"
  elif echo "$BASENAME" | grep -qiE '\b(enum|type|interface|schema)\b'; then
    TYPE="Definition"
  elif [[ "$BASENAME" =~ ^I[A-Z] ]]; then
    TYPE="Definition"
  elif echo "$BASENAME" | grep -qiE '\b(limit|max|min\b|threshold|constant)\b'; then
    TYPE="Limit"
  elif echo "$BASENAME" | grep -qiE '\b(middle|auth|guard|level)\b'; then
    TYPE="Access Control"
  elif echo "$BASENAME" | grep -qiE '\b(hook|context|provider)\b'; then
    TYPE="Definition"
  elif echo "$BASENAME" | grep -qiE '\b(slice|store|reducer)\b'; then
    TYPE="Rule"
  fi

  # Derive tags from directory
  TAGS=$(echo "$DOMAIN" | sed 's/-/, /g')

  # Derive layer name
  LAYER=$(detect_layer "$FILEPATH")

  # Build tags as YAML list (include old TYPE as a tag)
  TYPE_TAG=$(echo "$TYPE" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')
  TAGS_YAML="  - $TYPE_TAG"$'\n'
  IFS=',' read -ra TAG_ARR <<< "$TAGS"
  for TAG in "${TAG_ARR[@]}"; do
    TAG="$(echo "$TAG" | xargs)"
    [ -n "$TAG" ] && TAGS_YAML+="  - $TAG"$'\n'
  done

  # Generate entry with YAML frontmatter + body code reference
  RAW_ID="auto-$DOMAIN-$BASENAME"
  SEG_ID=$(echo "$RAW_ID" | sed 's/[^a-zA-Z0-9_-]/-/g' | sed 's/--*/-/g; s/-$//; s/^-//')
  [ -z "$SEG_ID" ] && SEG_ID="auto-unknown-$(date '+%s')"
  DOMAIN_FIRST=$(echo "$DOMAIN" | cut -d'-' -f1)
  ENTRY="---
id: $SEG_ID
type: segment
domain: $DOMAIN_FIRST
status: stub
confidence: unverified
fingerprints:
  - $FP
tags:
${TAGS_YAML}established: '$(date '+%Y-%m-%d')'
source_refs: 1
description: Auto-proposed from high-confidence gap scan for $FILEPATH
---

## $TITLE

- Type: $TYPE
- Code:
  - $LAYER: \`$FILEPATH\`
- Fingerprint: $FP
- Established: '$(date '+%Y-%m-%d')'

Auto-proposed from high-confidence gap scan. Review and refine the business logic described here.
"

  if [ "$MODE" = "--auto" ]; then
    # Write to a new segment file (dedup: only write if file doesn't exist)
    SEG_FILE="$OUT_DIR/$SEG_ID.md"
    if [ ! -f "$SEG_FILE" ]; then
      echo "$ENTRY" > "$SEG_FILE"
      echo "Wrote: $SEG_FILE"
    fi
  else
    # Print to stdout for review
    echo "=============================================="
    echo "Candidate #$CANDIDATE_COUNT"
    echo "Source: $FILEPATH"
    echo "----------------------------------------------"
    echo "$ENTRY"
  fi

done < "$TMP"

if [ "$MODE" = "--review" ]; then
  echo "=============================================="
  echo "Total candidates: $CANDIDATE_COUNT"
  echo "Review entries above. To auto-accept, run with --auto"
fi
