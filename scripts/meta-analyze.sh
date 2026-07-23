#!/usr/bin/env bash
set -euo pipefail

META_DIR="${META_DIR:-$(cd "$(dirname "$0")/.." && pwd)/meta}"
LOG="$META_DIR/operations.ndjson"
ANALYSIS_LOG="$META_DIR/suggestions.md"
THRESHOLD_FILE="$META_DIR/threshold"
THRESHOLD="${1:-$(cat "$THRESHOLD_FILE" 2>/dev/null || echo 3)}"

if [ ! -f "$LOG" ]; then
  echo "No operations logged yet at $LOG"
  exit 0
fi

python3 - "$LOG" "$ANALYSIS_LOG" "$THRESHOLD" << 'PYEOF'
import sys, json, math
from collections import defaultdict
from datetime import datetime, timezone

log_path, out_path, threshold = sys.argv[1], sys.argv[2], int(sys.argv[3])

with open(log_path) as f:
    ops = [json.loads(line) for line in f if line.strip()]

if len(ops) < 2:
    msg = f"## Meta Analysis\n\nNot enough data - only {len(ops)} operation(s) logged. Need at least 2 to detect patterns.\n"
    with open(out_path, "w") as f:
        f.write(msg)
    print(msg.strip())
    sys.exit(0)

RECENT = ops[-threshold:] if len(ops) >= threshold else ops
num_recent = len(RECENT)

# ---------------------------------------------------------------------------
# Helpers: extract fields from both old (flat) and new (nested) JSON format
# ---------------------------------------------------------------------------

def _get(op, *keys, default=None):
    if len(keys) == 1:
        parts = keys[0].split("_")
        val = op
        for part in parts:
            if isinstance(val, dict):
                val = val.get(part)
            else:
                val = None
                break
        if val is not None:
            return val
        return op.get(keys[0], default)
    val = op
    for k in keys:
        if isinstance(val, dict):
            val = val.get(k)
        else:
            return default
    return val if val is not None else default

def gaps_before(op):   return _get(op, "gaps", "before", default=None)
def gaps_after(op):    return _get(op, "gaps", "after", default=None)
def gaps_resolved(op): return _get(op, "gaps", "resolved", default=None)
def segs_before(op):   return _get(op, "segments", "before", default=None)
def segs_after(op):    return _get(op, "segments", "after", default=None)
def segs_added(op):    return _get(op, "segments", "added", default=None)
def files_scanned(op): return _get(op, "files", "scanned", default=None)
def files_total(op):   return _get(op, "files", "total", default=None)
def tokens_in(op):     return _get(op, "tokens", "in", default=None)
def tokens_out(op):    return _get(op, "tokens", "out", default=None)
def tool_total(op):    return _get(op, "tool_calls", "total", default=None)
def script_calls(op):  return op.get("script_calls", 0)
def tool_calls(op):    return op.get("tool_calls", {})

# ---------------------------------------------------------------------------
# Group ops
# ---------------------------------------------------------------------------

counts = defaultdict(list)
tool_patterns = defaultdict(list)

for op in ops:
    name = op.get("op", "unknown")
    counts[name].append(op)
    tc = tool_calls(op)
    if not isinstance(tc, dict):
        continue
    chain = []
    if tc.get("read", 0) > 0: chain.append("R")
    if tc.get("write", 0) > 0: chain.append("W")
    if tc.get("edit", 0) > 0: chain.append("E")
    if tc.get("bash", 0) > 0: chain.append("B")
    if tc.get("grep", 0) > 0: chain.append("G")
    if tc.get("glob", 0) > 0: chain.append("L")
    if tc.get("task", 0) > 0: chain.append("T")
    if chain:
        tool_patterns[name].append("->".join(chain))

suggestions = []

# ---------------------------------------------------------------------------
# 1. Duration outliers
# ---------------------------------------------------------------------------
dur_notes = []
for name, entries in counts.items():
    durations = [e["duration_s"] for e in entries if e.get("duration_s") is not None]
    if len(durations) >= 3:
        mean = sum(durations) / len(durations)
        var = sum((d - mean)**2 for d in durations) / len(durations)
        std = math.sqrt(var)
        for e in RECENT:
            d = e.get("duration_s")
            if d and e["op"] == name and d > mean + 2 * std:
                dur_notes.append((name, d, mean, std, e.get("ts", "")))
if dur_notes:
    rows = [f"| {n} | {d}s | {m:.0f}s | {s:.0f}s | {t} |" for n, d, m, s, t in dur_notes]
    suggestions.append("### DURATION OUTLIERS\n\n| Op | Duration | Avg | +/-2sd | Timestamp |\n|-----|----------|-----|------|-----------|\n" + "\n".join(rows) + "\n\nCheck if batch size, file count, or contention caused the spike.\n")

# ---------------------------------------------------------------------------
# 2. Zero-delta (no gaps resolved)
# ---------------------------------------------------------------------------
recent_zero = [e for e in RECENT if gaps_resolved(e) is not None and gaps_resolved(e) == 0]
if recent_zero:
    rows = [f"| {e.get('op','?')} | {gaps_before(e) or '?'} | {gaps_after(e) or '?'} | {segs_before(e) or '?'} | {segs_added(e) or 0} | {e.get('ts','')} |" for e in recent_zero]
    suggestions.append("### ZERO-DELTA OPERATIONS\n\n| Op | Gaps before | Gaps after | Segs before | Segs added | Timestamp |\n|-----|-------------|------------|-------------|------------|-----------|\n" + "\n".join(rows) + "\n\nNo gaps resolved - operation could have been skipped.\n")

# ---------------------------------------------------------------------------
# 2b. High gap resolution velocity
# ---------------------------------------------------------------------------
high_resolve = [e for e in RECENT if gaps_resolved(e) is not None and segs_added(e) is not None and gaps_resolved(e) > 0]
if high_resolve:
    rows = [f"| {e.get('op','?')} | {gaps_resolved(e)} | {segs_added(e)} | {gaps_resolved(e) / max(segs_added(e), 1):.1f}x | {e.get('ts','')} |" for e in high_resolve]
    suggestions.append("### GAP RESOLUTION VELOCITY\n\n| Op | Gaps resolved | Segs added | Ratio | Timestamp |\n|-----|---------------|------------|-------|-----------|\n" + "\n".join(rows) + "\n\nHigh velocity indicates efficient batch processing.\n")

# ---------------------------------------------------------------------------
# 3. Failure clusters
# ---------------------------------------------------------------------------
recent_fails = [e for e in RECENT if e.get("success") == False]
if recent_fails:
    fail_groups = defaultdict(list)
    for e in recent_fails:
        fail_groups[e["op"]].append(e)
    rows = []
    for op_name, entries in sorted(fail_groups.items()):
        reasons = [e.get("error") or "no reason" for e in entries]
        unique_reasons = list(set(r for r in reasons if r))
        rows.append(f"| {op_name} | {len(entries)} | {', '.join(unique_reasons[:3])} |")
    suggestions.append("### FAILURE CLUSTERS\n\n| Op | Failures | Errors |\n|-----|----------|--------|\n" + "\n".join(rows) + "\n\nAdd pre-validation or error handling for these operations.\n")

# ---------------------------------------------------------------------------
# 4. Repetitive tool chains
# ---------------------------------------------------------------------------
chain_hits = defaultdict(int)
for name, chains in tool_patterns.items():
    for c in chains:
        chain_hits[(name, c)] += 1
repetitive_chains = [(k, v) for k, v in chain_hits.items() if v >= 2 and k[0] in [e["op"] for e in RECENT]]
if repetitive_chains:
    rows = [f"| {op_name} | `{chain}` | {count}x |" for (op_name, chain), count in sorted(repetitive_chains, key=lambda x: -x[1])]
    suggestions.append("### REPETITIVE TOOL PATTERNS\n\n| Op | Tool chain | Count |\n|-----|------------|-------|\n" + "\n".join(rows) + "\n\nChains repeating 2x+ could be collapsed into a single deterministic script.\n")

# ---------------------------------------------------------------------------
# 5. Volume trends (files scanned)
# ---------------------------------------------------------------------------
recent_fs = [files_scanned(e) for e in RECENT if files_scanned(e) is not None]
if len(recent_fs) >= 2:
    max_fs, min_fs = max(recent_fs), min(recent_fs)
    if max_fs > 0 and max_fs / (min_fs or 1) > 2:
        avg_files = sum(recent_fs) / len(recent_fs)
        suggestions.append("### FILES VOLUME SPIKE\n\n"
            f"files_scanned ranges from {min_fs:.0f} to {max_fs:.0f} in the last {len(recent_fs)} operations (avg {avg_files:.0f}).\n\n"
            "A spike may indicate an exclusion rule is missing (e.g., .next/, cache/).\n")

# ---------------------------------------------------------------------------
# 5b. Coverage ratio (scanned / total)
# ---------------------------------------------------------------------------
ratio_ops = [(e, files_scanned(e), files_total(e)) for e in RECENT if files_scanned(e) is not None and files_total(e) is not None and files_total(e) > 0]
if len(ratio_ops) >= 2:
    ratios = [s / t for _, s, t in ratio_ops]
    max_r, min_r = max(ratios), min(ratios)
    if max_r > 0 and max_r / (min_r or 0.01) > 2:
        rows = [f"| {e.get('op','?')} | {s:.0f} | {t:.0f} | {r:.0%} | {e.get('ts','')} |" for e, s, t in ratio_ops]
        suggestions.append("### COVERAGE RATIO VARIANCE\n\n| Op | Scanned | Total | Ratio | Timestamp |\n|-----|---------|-------|-------|-----------|\n" + "\n".join(rows) + "\n\nScanned/total ratio varies - check if exclusion rules are consistent.\n")

# ---------------------------------------------------------------------------
# 6. LOC trends
# ---------------------------------------------------------------------------
recent_loc = [e["loc_scanned"] for e in RECENT if e.get("loc_scanned")]
if len(recent_loc) >= 2:
    max_loc, min_loc = max(recent_loc), min(recent_loc)
    if max_loc > 0 and max_loc / (min_loc or 1) > 2:
        avg_loc = sum(recent_loc) / len(recent_loc)
        suggestions.append("### LOC VOLUME SPIKE\n\n"
            f"loc_scanned ranges from {min_loc:.0f} to {max_loc:.0f} in the last {len(recent_loc)} operations (avg {avg_loc:.0f}).\n\n"
            "Large variation may affect token budget planning.\n")

# ---------------------------------------------------------------------------
# 7. Script call volume
# ---------------------------------------------------------------------------
recent_sc = [(e, script_calls(e)) for e in RECENT]
sc_values = [sc for _, sc in recent_sc]
if len(sc_values) >= 2 and max(sc_values) > 0:
    avg_sc = sum(sc_values) / len(sc_values)
    high_sc = [(e.get("op","?"), sc) for e, sc in recent_sc if sc > avg_sc * 1.5]
    if high_sc:
        rows = [f"| {opn} | {sc}" for opn, sc in high_sc]
        suggestions.append("### SCRIPT CALL VOLUME\n\n| Op | Script calls |\n|-----|-------------|\n" + "\n".join(rows) + "\n\nOperations with many sub-script calls may benefit from parallelization or batching.\n")

# ---------------------------------------------------------------------------
# 8. Token volume
# ---------------------------------------------------------------------------
recent_ti = [(e, tokens_in(e)) for e in RECENT if tokens_in(e) is not None]
if len(recent_ti) >= 2:
    ti_vals = [ti for _, ti in recent_ti]
    max_ti, min_ti = max(ti_vals), min(ti_vals)
    if max_ti > 0 and max_ti / (min_ti or 1) > 2:
        avg_ti = sum(ti_vals) / len(ti_vals)
        rows = [f"| {e.get('op','?')} | {ti:,} | {tokens_out(e) or 0:,} | {e.get('ts','')} |" for e, ti in recent_ti]
        suggestions.append("### TOKEN CONSUMPTION\n\n| Op | Tokens in | Tokens out | Timestamp |\n|-----|-----------|------------|-----------|\n" + "\n".join(rows) + f"\n\nAvg input: {avg_ti:,.0f} tokens across {len(recent_ti)} ops. Spikes may need context budget tuning.\n")

# ---------------------------------------------------------------------------
# 9. Tool total outliers
# ---------------------------------------------------------------------------
recent_tt = [(e, e.get("op","?"), tool_total(e)) for e in RECENT if tool_total(e) is not None]
tt_vals = [tt for _, _, tt in recent_tt]
if len(tt_vals) >= 3:
    tt_mean = sum(tt_vals) / len(tt_vals)
    tt_var = sum((v - tt_mean)**2 for v in tt_vals) / len(tt_vals)
    tt_std = math.sqrt(tt_var) if tt_var > 0 else 0
    if tt_std > 0:
        high_tt = [(opn, tt) for e, opn, tt in recent_tt if tt > tt_mean + 2 * tt_std]
        if high_tt:
            rows = [f"| {opn} | {tt} | {tt_mean:.0f} | {tt_std:.0f}" for opn, tt in high_tt]
            suggestions.append("### TOOL CALL VOLUME OUTLIERS\n\n| Op | Tool calls | Avg | +/-2sd |\n|-----|------------|-----|------|\n" + "\n".join(rows) + "\n\nHigh tool call count may indicate inefficiency - consider batching or scripting.\n")

# ---------------------------------------------------------------------------
# Summary stats
# ---------------------------------------------------------------------------
summary_rows = []
for name in sorted(counts.keys()):
    entries = counts[name]
    total = len(entries)
    success_count = sum(1 for e in entries if e.get("success") != False)
    avg_dur = sum(e.get("duration_s") or 0 for e in entries) / total
    tc_all = [tool_calls(e) for e in entries]
    reads = sum(t.get("read", 0) for t in tc_all)
    writes = sum(t.get("write", 0) for t in tc_all)
    edits = sum(t.get("edit", 0) for t in tc_all)
    bashs = sum(t.get("bash", 0) for t in tc_all)
    tasks = sum(t.get("task", 0) for t in tc_all)
    total_gaps = sum(gaps_resolved(e) or 0 for e in entries)
    total_segs = sum(segs_added(e) or 0 for e in entries)
    avg_sc = sum(script_calls(e) for e in entries) / total
    summary_rows.append(
        f"| {name} | {total} | {success_count}/{total} | {avg_dur:.1f}s | "
        f"R:{reads} W:{writes} E:{edits} B:{bashs} T:{tasks} | "
        f"gaps:{total_gaps} segs:{total_segs} sc:{avg_sc:.1f} |"
    )

summary_block = ""
if summary_rows:
    summary_block = "### Operation summary\n\n" \
        "| Op | Count | Success | Avg duration | Tool calls (R/W/E/B/T) | Metrics (gaps/segs/sc) |\n" \
        "|-----|-------|---------|--------------|------------------------|------------------------|\n" \
        + "\n".join(summary_rows) + "\n"

now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
lines = [f"## Meta Analysis - after {len(ops)} operations, {num_recent} recent", f"Generated: {now}", ""]
if summary_block:
    lines.append(summary_block)

if suggestions:
    lines.extend(suggestions)
else:
    lines.append("No significant patterns detected in the last operations.\n")

lines.append("---\n*Suggestions are data-grounded. Review each and decide whether to act.*\n")

output = "\n".join(lines)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(output)
print(output)
PYEOF
