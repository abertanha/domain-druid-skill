#!/usr/bin/env bash
# generate-manifest.sh — walks source dir, computes sha256 hashes, writes manifest
# Usage: generate-manifest.sh <source-dir> <output-json>
set -euo pipefail

SRC_DIR="${1:?Usage: generate-manifest.sh <source-dir> <output-json>}"
OUTPUT="${2:?Usage: generate-manifest.sh <source-dir> <output-json>}"

if [ ! -d "$SRC_DIR" ]; then
  echo "Error: source directory not found: $SRC_DIR" >&2
  exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

find "$SRC_DIR" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.py' -o -name '*.rs' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' \
  -print0 | sort -z | while IFS= read -r -d '' FILE; do
  REL="${FILE#$SRC_DIR/}"
  HASH=$(sha256sum "$FILE" | cut -d' ' -f1)
  echo "$REL|$HASH"
done > "$TMPFILE"

{
  echo "{"
  FIRST=true
  while IFS='|' read -r REL HASH; do
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo ","
    fi
    ESCAPED=$(printf '%s' "$REL" | sed 's/"/\\"/g')
    printf '  "%s": "%s"' "$ESCAPED" "$HASH"
  done < "$TMPFILE"
  echo ""
  echo "}"
} > "$OUTPUT"

echo "Manifest written: $OUTPUT ($(wc -l < "$OUTPUT") lines)"
