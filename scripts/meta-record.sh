#!/usr/bin/env bash
set -euo pipefail

META_DIR="${META_DIR:-$HOME/.config/opencode/skills/domain-druid/meta}"
LOG="$META_DIR/operations.ndjson"
THRESHOLD_FILE="$META_DIR/threshold"

mkdir -p "$META_DIR"
[ -f "$THRESHOLD_FILE" ] || echo 3 > "$THRESHOLD_FILE"

usage() {
  echo "usage: meta-record.sh <op-name> [flags]"
  echo "  --duration <s>         Operation duration in seconds"
  echo "  --exit-code <n>        Exit code of the operation"
  echo "  --success <true|false> Was the result as expected?"
  echo "  --files-scanned <n>    Source files examined"
  echo "  --loc-scanned <n>      Lines of code examined"
  echo "  --gaps-before <n>      Gaps before the operation"
  echo "  --gaps-after <n>       Gaps after the operation"
  echo "  --segments-before <n>  Segments before the operation"
  echo "  --segments-after <n>   Segments after the operation"
  echo "  --tool-read <n>        Read tool calls"
  echo "  --tool-write <n>       Write tool calls"
  echo "  --tool-edit <n>        Edit tool calls"
  echo "  --tool-bash <n>        Bash tool calls"
  echo "  --tool-grep <n>        Grep tool calls"
  echo "  --tool-glob <n>        Glob tool calls"
  echo "  --output-chars <n>     Output character count"
  echo "  --decision <str>       Why this approach was chosen"
  echo "  --error <str>          Error message if failed"
  exit 1
}

OP="${1:?$(usage)}"
shift

DURATION="null"; EXIT_CODE="null"; SUCCESS="true"
FILES_SCANNED="null"; LOC_SCANNED="null"
GAPS_BEFORE="null"; GAPS_AFTER="null"
SEGMENTS_BEFORE="null"; SEGMENTS_AFTER="null"
TOOL_READ=0; TOOL_WRITE=0; TOOL_EDIT=0; TOOL_BASH=0; TOOL_GREP=0; TOOL_GLOB=0
OUTPUT_CHARS=0; DECISION=""; ERROR="null"

while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --exit-code) EXIT_CODE="$2"; shift 2 ;;
    --success) SUCCESS="$2"; shift 2 ;;
    --files-scanned) FILES_SCANNED="$2"; shift 2 ;;
    --loc-scanned) LOC_SCANNED="$2"; shift 2 ;;
    --gaps-before) GAPS_BEFORE="$2"; shift 2 ;;
    --gaps-after) GAPS_AFTER="$2"; shift 2 ;;
    --segments-before) SEGMENTS_BEFORE="$2"; shift 2 ;;
    --segments-after) SEGMENTS_AFTER="$2"; shift 2 ;;
    --tool-read) TOOL_READ="$2"; shift 2 ;;
    --tool-write) TOOL_WRITE="$2"; shift 2 ;;
    --tool-edit) TOOL_EDIT="$2"; shift 2 ;;
    --tool-bash) TOOL_BASH="$2"; shift 2 ;;
    --tool-grep) TOOL_GREP="$2"; shift 2 ;;
    --tool-glob) TOOL_GLOB="$2"; shift 2 ;;
    --output-chars) OUTPUT_CHARS="$2"; shift 2 ;;
    --decision) DECISION="$2"; shift 2 ;;
    --error) ERROR="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

[ "$EXIT_CODE" != "null" ] && [ "$EXIT_CODE" != "0" ] && SUCCESS="false"

jq -c -n \
  --arg op "$OP" \
  --arg ts "$TS" \
  --argjson duration "$DURATION" \
  --argjson success "$SUCCESS" \
  --argjson exit_code "$EXIT_CODE" \
  --argjson files_scanned "$FILES_SCANNED" \
  --argjson loc_scanned "$LOC_SCANNED" \
  --argjson gaps_before "$GAPS_BEFORE" \
  --argjson gaps_after "$GAPS_AFTER" \
  --argjson segments_before "$SEGMENTS_BEFORE" \
  --argjson segments_after "$SEGMENTS_AFTER" \
  --argjson tool_read "$TOOL_READ" \
  --argjson tool_write "$TOOL_WRITE" \
  --argjson tool_edit "$TOOL_EDIT" \
  --argjson tool_bash "$TOOL_BASH" \
  --argjson tool_grep "$TOOL_GREP" \
  --argjson tool_glob "$TOOL_GLOB" \
  --argjson output_chars "$OUTPUT_CHARS" \
  --arg decision "$DECISION" \
  --arg error "$ERROR" \
  '{
    op: $op, ts: $ts, duration_s: $duration, success: $success,
    exit_code: $exit_code, files_scanned: $files_scanned,
    loc_scanned: $loc_scanned, gaps_before: $gaps_before,
    gaps_after: $gaps_after, segments_before: $segments_before,
    segments_after: $segments_after,
    tool_calls: {
      read: $tool_read, write: $tool_write, edit: $tool_edit,
      bash: $tool_bash, grep: $tool_grep, glob: $tool_glob
    },
    output_chars: $output_chars,
    decision: (if $decision == "" then null else $decision end),
    error: (if $error == "null" then null else $error end)
  }' >> "$LOG"

# Return current operation count so meta-analyze can check threshold
COUNT=$(wc -l < "$LOG")
echo "meta-record: $OP logged (op #$COUNT)"
