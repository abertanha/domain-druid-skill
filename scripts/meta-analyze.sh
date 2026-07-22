#!/usr/bin/env bash
set -euo pipefail

META_DIR="${META_DIR:-$HOME/.config/opencode/skills/domain-druid/meta}"
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
    msg = f"## Meta Analysis\n\nNot enough data — only {len(ops)} operation(s) logged. Need at least 2 to detect patterns.\n"
    with open(out_path, "w") as f:
        f.write(msg)
    print(msg.strip())
    sys.exit(0)

RECENT = ops[-threshold:] if len(ops) >= threshold else ops
num_recent = len(RECENT)

counts = defaultdict(list)
tool_patterns = defaultdict(list)

for op in ops:
    name = op.get("op", "unknown")
    counts[name].append(op)
    tc = op.get("tool_calls", {})
    chain = []
    if tc.get("read", 0) > 0: chain.append("R")
    if tc.get("write", 0) > 0: chain.append("W")
    if tc.get("edit", 0) > 0: chain.append("E")
    if tc.get("bash", 0) > 0: chain.append("B")
    if tc.get("grep", 0) > 0: chain.append("G")
    if tc.get("glob", 0) > 0: chain.append("L")
    if chain:
        tool_patterns[name].append("\u2192".join(chain))

suggestions = []

# 1. Duration outliers
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
    suggestions.append("### ⏱ Duration outliers\n\n| Op | Duration | Avg | ±2σ | Timestamp |\n|-----|----------|-----|------|-----------|\n" + "\n".join(rows) + "\n\n_Check if batch size, file count, or contention caused the spike._\n")

# 2. Zero-delta
recent_zero = [e for e in RECENT if e.get("gaps_before") is not None and e.get("gaps_after") is not None and e["gaps_before"] == e["gaps_after"]]
if recent_zero:
    rows = [f"| {e.get('op','?')} | {e.get('gaps_before','?')} | {e.get('segments_before','?')} | {e.get('segments_after','?')} | {e.get('ts','')} |" for e in recent_zero]
    suggestions.append("### 0️⃣ Zero-delta operations\n\n| Op | Gaps | Segs before | Segs after | Timestamp |\n|-----|------|-------------|------------|-----------|\n" + "\n".join(rows) + "\n\n_Operation changed nothing — could it have been skipped?_\n")

# 3. Failure clusters
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
    suggestions.append("### ❌ Failure clusters\n\n| Op | Failures | Errors |\n|-----|----------|--------|\n" + "\n".join(rows) + "\n\n_Add pre-validation or error handling for these operations._\n")

# 4. Repetitive tool chains
chain_hits = defaultdict(int)
for name, chains in tool_patterns.items():
    for c in chains:
        chain_hits[(name, c)] += 1
repetitive_chains = [(k, v) for k, v in chain_hits.items() if v >= 2 and k[0] in [e["op"] for e in RECENT]]
if repetitive_chains:
    rows = [f"| {op_name} | `{chain}` | {count}\u00d7 |" for (op_name, chain), count in sorted(repetitive_chains, key=lambda x: -x[1])]
    suggestions.append("### 🔁 Repetitive tool call patterns\n\n| Op | Tool chain | Count |\n|-----|------------|-------|\n" + "\n".join(rows) + "\n\n_Chains repeating ≥2× could be collapsed into a single deterministic script._\n")

# 5. Volume trends
recent_files = [e["files_scanned"] for e in RECENT if e.get("files_scanned")]
if len(recent_files) >= 2:
    max_fs, min_fs = max(recent_files), min(recent_files)
    if max_fs > 0 and max_fs / (min_fs or 1) > 2:
        avg_files = sum(recent_files) / len(recent_files)
        suggestions.append("### 📊 Volume spike detected\n\n"
            f"files_scanned ranges from {min_fs:.0f} to {max_fs:.0f} in the last {len(recent_files)} operations (avg {avg_files:.0f}).\n\n"
            "_A spike may indicate an exclusion rule is missing (e.g., .next/, cache/)._\n")

recent_loc = [e["loc_scanned"] for e in RECENT if e.get("loc_scanned")]
if len(recent_loc) >= 2:
    max_loc, min_loc = max(recent_loc), min(recent_loc)
    if max_loc > 0 and max_loc / (min_loc or 1) > 2:
        avg_loc = sum(recent_loc) / len(recent_loc)
        suggestions.append("### 📊 LOC volume spike detected\n\n"
            f"loc_scanned ranges from {min_loc:.0f} to {max_loc:.0f} in the last {len(recent_loc)} operations (avg {avg_loc:.0f}).\n\n"
            "_Large variation may affect token budget planning._\n")

# Summary stats
summary_rows = []
for name in sorted(counts.keys()):
    entries = counts[name]
    total = len(entries)
    success_count = sum(1 for e in entries if e.get("success") != False)
    avg_dur = sum(e.get("duration_s") or 0 for e in entries) / total
    tc_all = [e.get("tool_calls", {}) for e in entries]
    reads = sum(t.get("read", 0) for t in tc_all)
    writes = sum(t.get("write", 0) for t in tc_all)
    edits = sum(t.get("edit", 0) for t in tc_all)
    bashs = sum(t.get("bash", 0) for t in tc_all)
    summary_rows.append(f"| {name} | {total} | {success_count}/{total} | {avg_dur:.1f}s | R:{reads} W:{writes} E:{edits} B:{bashs} |")

summary_block = ""
if summary_rows:
    summary_block = "### Operation summary\n\n| Op | Count | Success | Avg duration | Tool calls (R/W/E/B) |\n|-----|-------|---------|--------------|----------------------|\n" + "\n".join(summary_rows) + "\n"

now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
lines = [f"## Meta Analysis \u2014 after {len(ops)} operations, {num_recent} recent", f"Generated: {now}", ""]
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
