#!/usr/bin/env bash
# detect-gaps.sh — scans source for rule signals, cross-refs against known segments
# Usage: detect-gaps.sh <source-dir> <bl-dir> <output-report> [--quick|--verify|--patterns-dir|--verify-work|--verify-work-pending]
#   --quick              : Rules.ts + enums only, skip constants scan
#   --verify <file>      : compare new gap against previous report, show resolved vs remaining
#   --verify-work        : post-implementation check (manifest diff, path-match only)
#   --verify-work-pending: verify-work + auto-write gaps to PENDING.md
#   --patterns-dir <dir> : load pattern registry from directory (technology-agnostic)
set -uo pipefail

SRC_DIR="${1:?Usage: detect-gaps.sh <source-dir> <bl-dir> <output>}"
BL_DIR="${2:?Usage: detect-gaps.sh <source-dir> <bl-dir> <output>}"
OUTPUT="${3:?Usage: detect-gaps.sh <source-dir> <bl-dir> <output>}"
QUICK=false
VERIFY_FILE=""
VERIFY_WORK=false
WRITE_PENDING=false
PATTERNS_DIR=""
# Parse remaining args (shift past first 3 positional args)
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    --verify) VERIFY_FILE="${2:-}"; shift 2 ;;
    --verify-work) VERIFY_WORK=true; shift ;;
    --verify-work-pending) VERIFY_WORK=true; WRITE_PENDING=true; shift ;;
    --patterns-dir) PATTERNS_DIR="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done

# --verify-work mode is a fast path: manifest diff + path check, skip all content scanning
if [ "$VERIFY_WORK" = true ]; then
  VW_ARGS=""
  [ "$WRITE_PENDING" = true ] && VW_ARGS="--write-pending"
  python3 "$(dirname "$0")/verify-work.py" "$SRC_DIR" "$BL_DIR" $VW_ARGS | tee "$OUTPUT"
  VW_EXIT=${PIPESTATUS[0]}
  [ $VW_EXIT -eq 0 ] && echo "✅ verify-work: all changes covered" >&2
  [ $VW_EXIT -eq 1 ] && echo "🔶 verify-work: new gaps found" >&2
  [ "$WRITE_PENDING" = true ] && [ $VW_EXIT -eq 1 ] && echo "📝 verify-work-pending: gaps written to PENDING.md — review and integrate" >&2
  [ $VW_EXIT -eq 3 ] && echo "⚠️ verify-work: no manifest — run init-manifest first" >&2
  exit $VW_EXIT
fi

SPLIT_DIR="$BL_DIR/split"

detect_project_type() {
  local src="$1"
  if find "$src" -maxdepth 3 -name '*.tsx' -type f 2>/dev/null | head -1 | grep -q .; then
    echo "frontend"
    return
  fi
  if [ -f "$src/../package.json" ] && grep -qi '"react"' "$src/../package.json" 2>/dev/null; then
    echo "frontend"
    return
  fi
  if [ -f "$src/../tsconfig.json" ] && grep -qi '"jsx"' "$src/../tsconfig.json" 2>/dev/null; then
    echo "frontend"
    return
  fi
  echo "backend"
}

PROJECT_TYPE=$(detect_project_type "$SRC_DIR")

# Total source files (for coverage baseline)
ALL_FILES=$(find "$SRC_DIR" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' 2>/dev/null | sort)
ALL_COUNT=$(echo "$ALL_FILES" | wc -l)

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

build_known_index() {
  if [ ! -d "$SPLIT_DIR" ]; then return; fi
  for SEG in "$SPLIT_DIR"/*.md; do
    [ -f "$SEG" ] || continue
    while IFS= read -r ENTRY; do
      FILEPATH="${ENTRY%% (*}"
      FILEPATH="${FILEPATH#source/}"
      FILEPATH="${FILEPATH#src/}"
      FILEPATH="${FILEPATH#./}"
      if [[ "$FILEPATH" == *"/src/"* ]]; then
        FILEPATH="${FILEPATH#*/src/}"
      fi
      FILEPATH=$(echo "$FILEPATH" | sed -E 's/:[0-9][-0-9,]*$//')
      FILEPATH="${FILEPATH#*: }"
      [ -n "$FILEPATH" ] && echo "$FILEPATH"
    done < <(grep -E '^  - [A-Za-z]+: ' "$SEG" 2>/dev/null || true)
    while IFS= read -r CELL; do
      for ext in ts tsx js jsx; do
        while IFS= read -r FP; do
          [ -n "$FP" ] && echo "$(normalize_path "$FP")"
        done < <(echo "$CELL" | grep -oP "[a-zA-Z0-9_/.-]+\.$ext" 2>/dev/null || true)
      done
    done < <(grep '|.*\`.*/' "$SEG" 2>/dev/null || true)
  done | sort -u
}

KNOWN_FILES=$(build_known_index)
KNOWN_COUNT=$(echo "$KNOWN_FILES" | wc -l)

# Build set of undocumented files (using temp files + comm for speed)
UNDOC_TMP=$(mktemp)
KNOWN_TMP=$(mktemp)
ALL_TMP=$(mktemp)

# Normalize all known paths and write to temp file
while IFS= read -r KF; do
  [ -z "$KF" ] && continue
  KP="${KF#source/}"
  KP="${KP#src/}"
  KP="${KP#./}"
  echo "$KP" >> "$KNOWN_TMP"
done <<< "$KNOWN_FILES"

# Write all source files (relative) to temp file
while IFS= read -r FILE; do
  REL="${FILE#$SRC_DIR/}"
  echo "$REL" >> "$ALL_TMP"
done <<< "$ALL_FILES"

# Use comm to find files in ALL but not in KNOWN (sorted intersection)
sort -u "$KNOWN_TMP" -o "$KNOWN_TMP"
sort -u "$ALL_TMP" -o "$ALL_TMP"

UNDOC_FILELIST=$(comm -23 "$ALL_TMP" "$KNOWN_TMP")
UNDOC_COUNT=$(echo "$UNDOC_FILELIST" | grep -c . || true)
[ -z "$UNDOC_FILELIST" ] && UNDOC_COUNT=0

rm -f "$UNDOC_TMP" "$KNOWN_TMP" "$ALL_TMP"

# Compute coverage percentage
PCT_COVERAGE=0
if [ "$ALL_COUNT" -gt 0 ]; then
  PCT_COVERAGE=$((KNOWN_COUNT * 100 / ALL_COUNT))
fi

# Top-20 largest undocumented files (sorted by file size)
top_undocumented() {
  local n=20
  echo "$UNDOC_FILELIST" | while IFS= read -r REL; do
    [ -z "$REL" ] && continue
    ABS="$SRC_DIR/$REL"
    SIZE=$(wc -c < "$ABS" 2>/dev/null || echo 0)
    echo "$SIZE|$REL"
  done | sort -t'|' -k1 -rn | head -n "$n" | while IFS='|' read -r SIZE REL; do
    KB=$((SIZE / 1024))
    echo "  - ${KB}KB \`$REL\`"
  done
}

{
  echo "# Gap Detection Report"
  echo ""
  echo "Source: $SRC_DIR"
  echo "BL Root: $BL_DIR"
  echo "Generated: $(date '+%Y-%m-%d %H:%M')"
  echo "Project Type: $PROJECT_TYPE"
  echo ""
  echo "## Coverage Summary"
  echo ""
  echo "| Metric | Value |"
  echo "|--------|-------|"
  echo "| Total source files | $ALL_COUNT |"
  echo "| Files with code refs | ${KNOWN_COUNT:-0} |"
  echo "| Files without refs | $UNDOC_COUNT |"
  echo "| **Coverage** | **${PCT_COVERAGE}%** |"
  echo ""
  if [ "$UNDOC_COUNT" -gt 0 ]; then
    echo "### Top-20 Largest Undocumented Files"
    echo ""
    echo "These files have no code references in any segment and may contain undocumented business logic:"
    echo ""
    top_undocumented
    echo ""
  fi
  echo "---"
  echo ""
} > "$OUTPUT"

is_known() {
  local FILE="$1" KF=""
  while IFS= read -r KF; do
    [ -z "$KF" ] && continue
    if [[ "$FILE" == "$KF" ]] || [[ "$FILE" == *"/$KF" ]] || [[ "$KF" == *"$FILE" ]]; then
      return 0
    fi
  done <<< "$KNOWN_FILES"
  return 1
}

ST_K=0; ST_N=0

{
  echo "## 1. Rules.ts Analysis"
  echo ""
  echo "Confidence: 🔴 High — explicit naming convention, strong signal"
  echo ""
  while IFS= read -r FILE; do
    REL="${FILE#$SRC_DIR/}"
    if is_known "$REL"; then STATUS="✅ mapped"; ST_K=$((ST_K + 1))
    else STATUS="🆕 new"; ST_N=$((ST_N + 1)); fi
    echo "- [${STATUS}] \`$REL\`"
  done < <(find "$SRC_DIR" \( -name '*Rules.ts' -o -name '*Rules.tsx' \) -type f -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | sort)
  echo ""
  RULES_TOTAL=$(find "$SRC_DIR" \( -name '*Rules.ts' -o -name '*Rules.tsx' \) -type f -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | wc -l)
  echo "Rules.ts summary: ${RULES_TOTAL} files (✅ ${ST_K} known, 🆕 ${ST_N} new)"
  echo ""
} >> "$OUTPUT"

ST_K=0; ST_N=0; ENUM_COUNT=0

{
  echo "## 2. Schema Enum Definitions"
  echo ""
  echo "Confidence: 🟡 Medium — naming convention, but some enums are infra/config"
  echo ""
  while IFS= read -r FILE; do
    REL="${FILE#$SRC_DIR/}"
    ENUMS=$(grep -n -E '^\s*(enum|const enum|export enum|export const enum)' "$FILE" 2>/dev/null || true)
    if [ -n "$ENUMS" ]; then
      if is_known "$REL"; then STATUS="✅ mapped"; ST_K=$((ST_K + 1))
      else STATUS="🆕 new"; ST_N=$((ST_N + 1)); fi
      echo "- [${STATUS}] \`$REL\`:"
      while IFS= read -r ENUM; do
        ENUM_COUNT=$((ENUM_COUNT + 1))
        echo "  - $ENUM"
      done <<< "$ENUMS"
    fi
  done < <(find "$SRC_DIR" \( -name '*Schema.ts' -o -name '*Schema.tsx' -o -name 'I*.ts' -o -name 'I*.tsx' -o -name '*Interface.ts' -o -name '*Interface.tsx' \) -type f -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | sort)
  echo ""
  ENUM_TOTAL=$(find "$SRC_DIR" \( -name '*Schema.ts' -o -name '*Schema.tsx' -o -name 'I*.ts' -o -name 'I*.tsx' -o -name '*Interface.ts' -o -name '*Interface.tsx' \) -type f -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | wc -l)
  echo "Enum/schema files: ${ENUM_TOTAL} scanned (✅ ${ST_K} known, 🆕 ${ST_N} new)"
  echo ""
} >> "$OUTPUT"

if [ "$QUICK" = false ]; then
  ST_K=0; ST_N=0; LIMIT_COUNT=0

  {
    echo "## 3. Constants and Limits"
    echo ""
    echo "Confidence: 🟡 Medium — pattern match, needs context to confirm business meaning"
    echo ""
    while IFS= read -r FILE; do
      REL="${FILE#$SRC_DIR/}"
      CONSTANTS=$(grep -n -E '(MAX_|MIN_|TIMEOUT|_LIMIT|_EXPIRATION|_ATTEMPTS|_THRESHOLD|_INTERVAL|_TTL|_MAX)' "$FILE" 2>/dev/null || true)
      if [ -n "$CONSTANTS" ]; then
        if is_known "$REL"; then STATUS="✅ mapped"; ST_K=$((ST_K + 1))
        else STATUS="🆕 new"; ST_N=$((ST_N + 1)); fi
        echo "- [${STATUS}] \`$REL\`:"
        while IFS= read -r C; do
          LIMIT_COUNT=$((LIMIT_COUNT + 1))
          echo "  - $C"
        done <<< "$CONSTANTS"
      fi
    done < <(find "$SRC_DIR" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | sort)
    echo ""
    FILE_TOTAL=$(find "$SRC_DIR" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | wc -l)
    echo "Constant/limit signals: ${LIMIT_COUNT} across ${FILE_TOTAL} files (✅ ${ST_K} known, 🆕 ${ST_N} new)"
    echo ""
  } >> "$OUTPUT"
fi

if [ "$PROJECT_TYPE" = "frontend" ] && [ "$QUICK" = false ]; then
  FE_ST_K=0; FE_ST_N=0

  {
    echo "## 4a. Frontend Hooks (Business Logic)"
    echo ""
    echo "Confidence: 🔵 Low-Med — hooks may contain UI logic, not business rules"
    echo ""
    while IFS= read -r FILE; do
      REL="${FILE#$SRC_DIR/}"
      HOOK_SIGNALS=$(grep -n -E '(useState|useEffect|useReducer|useCallback|useMemo)' "$FILE" 2>/dev/null || true)
      if [ -n "$HOOK_SIGNALS" ]; then
        if is_known "$REL"; then STATUS="✅ mapped"; FE_ST_K=$((FE_ST_K + 1))
        else STATUS="🆕 new"; FE_ST_N=$((FE_ST_N + 1)); fi
        echo "- [${STATUS}] \`$REL\`:"
        COUNT=0
        while IFS= read -r H; do
          COUNT=$((COUNT + 1))
          [ $COUNT -le 5 ] && echo "  - $H"
        done <<< "$HOOK_SIGNALS"
        HOOK_TOTAL=$(echo "$HOOK_SIGNALS" | wc -l)
        [ "$HOOK_TOTAL" -gt 5 ] && echo "  - ... and $(($HOOK_TOTAL - 5)) more signals"
      fi
    done < <(find "$SRC_DIR" -type f \( -name '*Hook.ts' -o -name '*Hook.tsx' -o -name '*hooks.ts' -o -name '*hooks.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | sort)
    FE_HOOK_TOTAL=$(find "$SRC_DIR" -type f \( -name '*Hook.ts' -o -name '*Hook.tsx' -o -name '*hooks.ts' -o -name '*hooks.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | wc -l)
    echo ""
    echo "Hook files scanned: ${FE_HOOK_TOTAL} (✅ ${FE_ST_K} known, 🆕 ${FE_ST_N} new)"
    echo ""
  } >> "$OUTPUT"

  FE_ST_K=0; FE_ST_N=0

  {
    echo "## 4b. State Slices (Redux/Zustand)"
    echo ""
    echo "Confidence: 🟡 Medium — state transitions often encode business rules"
    echo ""
    while IFS= read -r FILE; do
      REL="${FILE#$SRC_DIR/}"
      SLICE_SIGNALS=$(grep -n -E '(createSlice|createReducer|createAction|configureStore|reducer|initialState)' "$FILE" 2>/dev/null || true)
      if [ -n "$SLICE_SIGNALS" ]; then
        if is_known "$REL"; then STATUS="✅ mapped"; FE_ST_K=$((FE_ST_K + 1))
        else STATUS="🆕 new"; FE_ST_N=$((FE_ST_N + 1)); fi
        echo "- [${STATUS}] \`$REL\`:"
        COUNT=0
        while IFS= read -r S; do
          COUNT=$((COUNT + 1))
          [ $COUNT -le 5 ] && echo "  - $S"
        done <<< "$SLICE_SIGNALS"
        SLICE_TOTAL=$(echo "$SLICE_SIGNALS" | wc -l)
        [ "$SLICE_TOTAL" -gt 5 ] && echo "  - ... and $(($SLICE_TOTAL - 5)) more signals"
      fi
    done < <(find "$SRC_DIR" -type f \( -name '*Slice.ts' -o -name '*Slice.tsx' -o -name 'store*.ts' -o -name 'store*.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | sort)
    FE_SLICE_TOTAL=$(find "$SRC_DIR" -type f \( -name '*Slice.ts' -o -name '*Slice.tsx' -o -name 'store*.ts' -o -name 'store*.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | wc -l)
    echo ""
    echo "Slice files scanned: ${FE_SLICE_TOTAL} (✅ ${FE_ST_K} known, 🆕 ${FE_ST_N} new)"
    echo ""
  } >> "$OUTPUT"

  FE_ST_K=0; FE_ST_N=0

  {
    echo "## 4c. Context Providers"
    echo ""
    echo "Confidence: 🔵 Low — many contexts are pure infrastructure (theme, i18n)"
    echo ""
    while IFS= read -r FILE; do
      REL="${FILE#$SRC_DIR/}"
      CTX_SIGNALS=$(grep -n -E '(createContext|useContext|Context\.Provider|ContextProvider)' "$FILE" 2>/dev/null || true)
      if [ -n "$CTX_SIGNALS" ]; then
        if is_known "$REL"; then STATUS="✅ mapped"; FE_ST_K=$((FE_ST_K + 1))
        else STATUS="🆕 new"; FE_ST_N=$((FE_ST_N + 1)); fi
        echo "- [${STATUS}] \`$REL\`:"
        while IFS= read -r C; do
          echo "  - $C"
        done <<< "$CTX_SIGNALS"
      fi
    done < <(find "$SRC_DIR" -type f \( -name '*Context.tsx' -o -name '*Context.ts' -o -name '*Provider.tsx' -o -name '*Provider.ts' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | sort)
    FE_CTX_TOTAL=$(find "$SRC_DIR" -type f \( -name '*Context.tsx' -o -name '*Context.ts' -o -name '*Provider.tsx' -o -name '*Provider.ts' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | wc -l)
    echo ""
    echo "Context files scanned: ${FE_CTX_TOTAL} (✅ ${FE_ST_K} known, 🆕 ${FE_ST_N} new)"
    echo ""
  } >> "$OUTPUT"

  FE_ST_K=0; FE_ST_N=0

  {
    echo "## 4d. Validation Schemas"
    echo ""
    echo "Confidence: 🟡 Medium — form validations are business rules by definition"
    echo ""
    while IFS= read -r FILE; do
      REL="${FILE#$SRC_DIR/}"
      VAL_SIGNALS=$(grep -n -E '(yup|zod|object\(\{|string\(|number\(|boolean\(|mixed\(|array\(|shape\()' "$FILE" 2>/dev/null || true)
      if [ -n "$VAL_SIGNALS" ]; then
        if is_known "$REL"; then STATUS="✅ mapped"; FE_ST_K=$((FE_ST_K + 1))
        else STATUS="🆕 new"; FE_ST_N=$((FE_ST_N + 1)); fi
        echo "- [${STATUS}] \`$REL\`:"
        COUNT=0
        while IFS= read -r V; do
          COUNT=$((COUNT + 1))
          [ $COUNT -le 5 ] && echo "  - $V"
        done <<< "$VAL_SIGNALS"
        VAL_TOTAL=$(echo "$VAL_SIGNALS" | wc -l)
        [ "$VAL_TOTAL" -gt 5 ] && echo "  - ... and $(($VAL_TOTAL - 5)) more signals"
      fi
    done < <(find "$SRC_DIR" -type f \( -name '*Validator.ts' -o -name '*Validator.tsx' -o -name '*Validation.ts' -o -name '*Validation.tsx' -o -name '*Schema.ts' -o -name '*Schema.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | sort)
    FE_VAL_TOTAL=$(find "$SRC_DIR" -type f \( -name '*Validator.ts' -o -name '*Validator.tsx' -o -name '*Validation.ts' -o -name '*Validation.tsx' -o -name '*Schema.ts' -o -name '*Schema.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | wc -l)
    echo ""
    echo "Validation files scanned: ${FE_VAL_TOTAL} (✅ ${FE_ST_K} known, 🆕 ${FE_ST_N} new)"
    echo ""
  } >> "$OUTPUT"

  FE_ST_K=0; FE_ST_N=0

  {
    echo "## 4e. API Service Layers"
    echo ""
    echo "Confidence: 🔵 Low — may be thin CRUD wrappers, not business rules"
    echo ""
    while IFS= read -r FILE; do
      REL="${FILE#$SRC_DIR/}"
      API_SIGNALS=$(grep -n -E '(axios|fetch\(|api\.(get|post|put|delete)|baseURL|interceptor)' "$FILE" 2>/dev/null || true)
      if [ -n "$API_SIGNALS" ]; then
        if is_known "$REL"; then STATUS="✅ mapped"; FE_ST_K=$((FE_ST_K + 1))
        else STATUS="🆕 new"; FE_ST_N=$((FE_ST_N + 1)); fi
        echo "- [${STATUS}] \`$REL\`:"
        COUNT=0
        while IFS= read -r A; do
          COUNT=$((COUNT + 1))
          [ $COUNT -le 5 ] && echo "  - $A"
        done <<< "$API_SIGNALS"
        API_TOTAL=$(echo "$API_SIGNALS" | wc -l)
        [ "$API_TOTAL" -gt 5 ] && echo "  - ... and $(($API_TOTAL - 5)) more signals"
      fi
    done < <(find "$SRC_DIR" -type f \( -name '*Service.ts' -o -name '*Service.tsx' -o -name '*Api.ts' -o -name '*Api.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | sort)
    FE_API_TOTAL=$(find "$SRC_DIR" -type f \( -name '*Service.ts' -o -name '*Service.tsx' -o -name '*Api.ts' -o -name '*Api.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | wc -l)
    echo ""
    echo "API service files scanned: ${FE_API_TOTAL} (✅ ${FE_ST_K} known, 🆕 ${FE_ST_N} new)"
    echo ""
  } >> "$OUTPUT"

  FE_ST_K=0; FE_ST_N=0

  {
    echo "## 4f. Test-Encoded Invariants"
    echo ""
    echo "Confidence: ⚪ Low — assertions may be technical, not business rules"
    echo ""
    while IFS= read -r FILE; do
      REL="${FILE#$SRC_DIR/}"
      TEST_SIGNALS=$(grep -n -E '(expect\(|it\(|describe\(|test\(|assert\.|should\b)' "$FILE" 2>/dev/null || true)
      if [ -n "$TEST_SIGNALS" ]; then
        if is_known "$REL"; then STATUS="✅ mapped"; FE_ST_K=$((FE_ST_K + 1))
        else STATUS="🆕 new"; FE_ST_N=$((FE_ST_N + 1)); fi
        echo "- [${STATUS}] \`$REL\`:"
        COUNT=0
        while IFS= read -r T; do
          COUNT=$((COUNT + 1))
          [ $COUNT -le 5 ] && echo "  - $T"
        done <<< "$TEST_SIGNALS"
        TEST_TOTAL=$(echo "$TEST_SIGNALS" | wc -l)
        [ "$TEST_TOTAL" -gt 5 ] && echo "  - ... and $(($TEST_TOTAL - 5)) more signals"
      fi
    done < <(find "$SRC_DIR" -type f \( -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.spec.ts' -o -name '*.spec.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | sort)
    FE_TEST_TOTAL=$(find "$SRC_DIR" -type f \( -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.spec.ts' -o -name '*.spec.tsx' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | wc -l)
    echo ""
    echo "Test files scanned: ${FE_TEST_TOTAL} (✅ ${FE_ST_K} known, 🆕 ${FE_ST_N} new)"
    echo ""
  } >> "$OUTPUT"
fi



# --verify mode: compare against previous report and show resolved vs remaining
if [ -n "$VERIFY_FILE" ] && [ -f "$VERIFY_FILE" ]; then
  # Count 🆕 entries in previous report vs current report
  PREV_NEW=$(grep -c '🆕 new' "$VERIFY_FILE" 2>/dev/null || echo 0)
  CURR_NEW=$(grep -c '🆕 new' "$OUTPUT" 2>/dev/null || echo 0)
  RESOLVED=$((PREV_NEW - CURR_NEW))
  [ "$RESOLVED" -lt 0 ] && RESOLVED=0

  {
    echo ""
    echo "## Verification vs Previous Report"
    echo ""
    echo "| Metric | Previous | Current | Change |"
    echo "|--------|----------|---------|--------|"
    echo "| Total 🆕 signals | $PREV_NEW | $CURR_NEW | $((CURR_NEW - PREV_NEW)) |"
    echo "| Resolved | — | — | **${RESOLVED}** |"
    echo "| Remaining | — | — | **${CURR_NEW}** |"
    echo ""
    if [ "$CURR_NEW" -eq 0 ]; then
      echo "✅ All gaps resolved. Coverage is complete by current detection patterns."
    elif [ "$RESOLVED" -eq 0 ] && [ "$CURR_NEW" -eq "$PREV_NEW" ]; then
      echo "⚠️ No gaps resolved. Integration may not have covered these findings."
    elif [ "$RESOLVED" -gt 0 ] && [ "$CURR_NEW" -gt 0 ]; then
      echo "🔶 ${RESOLVED} gaps resolved, ${CURR_NEW} remaining. Continue integration or review false positives."
    fi
    echo ""
  } >> "$OUTPUT"
fi

{
  echo "---"
  echo "Report complete. 🆕 entries above are candidates for new documentation."
  echo ""
  echo "## Confidence Legend"
  echo ""
  echo "| Badge | Meaning | Sections |"
  echo "|-------|---------|----------|"
  echo "| 🔴 High | Near-certain business logic | Rules.ts |"
  echo "| 🟡 Medium | Likely business logic, verify context | Enums, Constants, Slices, Validation |"
  echo "| 🔵 Low-Med | May be business logic or UI infrastructure | Hooks |"
  echo "| 🔵 Low | Typically infrastructure, flag if custom | Contexts, API Services |"
  echo "| ⚪ Low | Technical assertions, only flag if domain-specific | Tests |"
  echo ""
} >> "$OUTPUT"

# Pattern registry scan (appended after all other sections to avoid truncation)
if [ -n "$PATTERNS_DIR" ] && [ -d "$PATTERNS_DIR" ]; then
  python3 "$(dirname "$0")/scan-from-registry.py" \
    "$PATTERNS_DIR" "$SRC_DIR" "$BL_DIR" \
    $( [ "$QUICK" = true ] && echo "--quick" ) >> "$OUTPUT" 2>&1 && \
    echo "Pattern registry applied: $PATTERNS_DIR" >&2
fi

echo "OK: $OUTPUT"
