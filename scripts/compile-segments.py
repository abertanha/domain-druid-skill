#!/usr/bin/env python3
"""Segment Compiler — validate, index, and cross-reference business logic segments.

Usage:
  python3 compile-segments.py <bl-root>  # Validate and report
  python3 compile-segments.py <bl-root> --fix  # Auto-fix issues
  python3 compile-segments.py <bl-root> --rebuild  # Rebuild INDEX, FINGERPRINTS, SOURCE_MAP

Validates frontmatter schema, checks cross-refs, and generates
agent-optimized metadata files (INDEX.md, FINGERPRINTS.md, SOURCE_MAP.md).
"""

import os
import sys
import yaml
import re
import json
from datetime import date
from pathlib import Path

# ── Schema ──────────────────────────────────────────────────────────────

FRONTMATTER_SCHEMA = {
    "id": {"type": str, "required": True, "pattern": r"^[\w-]+$"},
    "type": {"type": str, "required": True, "default": "segment"},
    "domain": {"type": str, "required": False},
    "status": {"type": str, "required": False, "default": "active", "values": ["active", "archived", "stub"]},
    "confidence": {"type": str, "required": False, "default": "unverified", "values": ["high", "medium", "low", "unverified"]},
    "fingerprints": {"type": list, "required": False, "default": []},
    "tags": {"type": list, "required": False, "default": []},
    "established": {"type": str, "required": False},
    "source_refs": {"type": int, "required": False, "default": 0},
    "related": {"type": list, "required": False, "default": []},
    "description": {"type": str, "required": False},
}

VALID_TYPES = {"segment", "stub", "Segment", "Stub"}

# ── Parsers ─────────────────────────────────────────────────────────────

def parse_frontmatter(content):
    """Extract YAML frontmatter from markdown content."""
    if not content.startswith("---"):
        return None, content
    parts = content.split("---", 2)
    if len(parts) < 3:
        return None, content
    try:
        fm = yaml.safe_load(parts[1])
    except yaml.YAMLError:
        return None, content
    return fm or {}, parts[2].strip()

def parse_entries(content):
    """Parse inline entries from core format (## Title + - Type: blocks)."""
    entries = []
    blocks = re.split(r"\n(?=## )", content)
    for block in blocks:
        if not block.strip():
            continue
        title_m = re.search(r"^#{1,2}\s+(.+)", block, re.MULTILINE)
        title = title_m.group(1).strip() if title_m else ""
        entry_type = ""
        fingerprint = ""
        tags = []
        code_refs = []
        status = "active"
        established = ""

        for line in block.split("\n"):
            stripped = line.strip()
            if stripped.startswith("- Type:"):
                entry_type = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("- Fingerprint:"):
                fingerprint = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("- Tags:"):
                val = stripped.split(":", 1)[1].strip()
                tags = [t.strip().strip("`") for t in re.split(r"[,|]", val) if t.strip()]
            elif stripped.startswith("- Status:"):
                status = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("- Established:"):
                established = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("- Code:") or line.strip().startswith("- "):
                code_m = re.search(r"`([^`]+\.(ts|tsx|js|jsx|py|rs)[^`]*)`", line)
                if code_m:
                    code_refs.append(code_m.group(1))

        if title or entry_type:
            entries.append({
                "title": title,
                "type": entry_type,
                "fingerprint": fingerprint,
                "tags": tags,
                "code_refs": code_refs,
                "status": status,
                "established": established,
            })
    return entries

def parse_table_entries(content):
    """Parse uxvision-web table format entries (| ID | Rule | Code |)."""
    entries = []
    # Match markdown tables with code refs
    table_lines = re.findall(r"^\|.+\|.+\|.+`[^`]+\.\w+`.*\|$", content, re.MULTILINE)
    for line in table_lines:
        cols = [c.strip() for c in line.split("|") if c.strip()]
        if len(cols) >= 3:
            code_refs = re.findall(r"`([^`]+\.(ts|tsx|js|jsx|py|rs)[^`]*)`", line)
            entries.append({
                "title": cols[1] if len(cols) > 1 else "",
                "type": "Rule" if "Rule" in line else "Definition" if "Definition" in line else "Entry",
                "fingerprint": "",
                "tags": [],
                "code_refs": [r[0] for r in code_refs],
                "status": "active",
                "established": "",
            })
    return entries

# ── Validators ──────────────────────────────────────────────────────────

def validate_frontmatter(fm, filepath):
    """Validate frontmatter against schema. Return list of issues."""
    issues = []
    for field, schema in FRONTMATTER_SCHEMA.items():
        val = fm.get(field)
        if val is None:
            if schema.get("required"):
                issues.append(f"MISSING required field '{field}'")
            continue
        expected_type = schema["type"]
        if not isinstance(val, expected_type):
            issues.append(f"FIELD '{field}' should be {expected_type.__name__}, got {type(val).__name__}")
        if "pattern" in schema and isinstance(val, str) and not re.match(schema["pattern"], val):
            issues.append(f"FIELD '{field}'='{val}' does not match pattern {schema['pattern']}")
        if "values" in schema and isinstance(val, str) and val not in schema["values"]:
            issues.append(f"FIELD '{field}'='{val}' is not in valid values: {schema['values']}")
    if fm.get("type") not in VALID_TYPES:
        issues.append(f"FIELD 'type'='{fm.get('type')}' is not valid: {VALID_TYPES}")
    return issues

def check_fingerprint_refs(fm, all_fingerprints):
    """Check that fingerprints referenced in frontmatter exist in the index."""
    issues = []
    known = set(all_fingerprints)
    for fp in fm.get("fingerprints", []):
        if fp not in known:
            issues.append(f"FINGERPRINT '{fp}' referenced but not in FINGERPRINTS.md")
    return issues

# ── Index Builders ──────────────────────────────────────────────────────

def build_index(segments):
    """Build INDEX.md content."""
    lines = ["# Business Logic Index — Auto-generated", "",
             "| Trace ID | Title | Domain | Confidence | Status | Source Refs | Segment |",
             "|----------|-------|--------|------------|--------|-------------|---------|"]
    for seg in sorted(segments, key=lambda s: s["fm"].get("id", "")):
        fid = seg["fm"].get("id", "?")
        title = seg["fm"].get("description", "")[:60]
        domain = seg["fm"].get("domain", "?")
        conf = seg["fm"].get("confidence", "?")
        status = seg["fm"].get("status", "?")
        refs = seg["fm"].get("source_refs", 0)
        relpath = os.path.relpath(seg["path"], start=os.path.dirname(seg["bl_root"]) if "bl_root" in seg else os.path.dirname(seg["path"]))
        lines.append(f"| `{fid}` | {title} | {domain} | {conf} | {status} | {refs} | [{fid}]({relpath}) |")
    return "\n".join(lines) + "\n"

def build_fingerprints(segments):
    """Build FINGERPRINTS.md content."""
    lines = ["# Fingerprint Index — Auto-generated", "",
             f"Generated: {date.today()}", "",
             "| Fingerprint | Segment | Tags |",
             "|-------------|---------|------|"]
    for seg in sorted(segments, key=lambda s: s["fm"].get("id", "")):
        seg_id = seg["fm"].get("id", "?")
        tags = ",".join(seg["fm"].get("tags", []))
        for fp in seg["fm"].get("fingerprints", []):
            lines.append(f"| {fp} | {seg_id} | {tags} |")
    return "\n".join(lines) + "\n"

def build_source_map(segments):
    """Build SOURCE_MAP.md content — source file path -> segment mapping."""
    mapping = {}
    for seg in segments:
        seg_id = seg["fm"].get("id", "?")
        # Extract code refs from entries
        for entry in seg.get("entries", []):
            for ref in entry.get("code_refs", []):
                normalized = ref.replace("source/", "").replace("src/", "")
                if normalized not in mapping:
                    mapping[normalized] = []
                mapping[normalized].append(seg_id)

    lines = ["# Source Map — Auto-generated", "",
             f"Generated: {date.today()}", "",
             "| Source File | Segment |",
             "|-------------|---------|"]
    for src in sorted(mapping.keys()):
        segs = ", ".join(sorted(set(mapping[src])))
        lines.append(f"| `{src}` | {segs} |")
    return "\n".join(lines) + "\n"

def build_report(segments, issues, bl_root):
    """Build a compiler report with key metrics."""
    total = len(segments)
    with_frontmatter = sum(1 for s in segments if s.get("has_frontmatter"))
    with_fingerprints = sum(1 for s in segments if s["fm"].get("fingerprints"))
    with_tags = sum(1 for s in segments if s["fm"].get("tags"))
    with_refs = sum(1 for s in segments if s["fm"].get("source_refs", 0) > 0)
    total_refs = sum(s["fm"].get("source_refs", 0) for s in segments)
    total_fps = sum(len(s["fm"].get("fingerprints", [])) for s in segments)
    total_entries = sum(len(s.get("entries", [])) for s in segments)
    high_conf = sum(1 for s in segments if s["fm"].get("confidence") == "high")
    medium_conf = sum(1 for s in segments if s["fm"].get("confidence") == "medium")
    low_conf = sum(1 for s in segments if s["fm"].get("confidence") == "low")
    unverified = sum(1 for s in segments if s["fm"].get("confidence") == "unverified")
    # Domain breakdown
    domains = {}
    for s in segments:
        d = s["fm"].get("domain", "unknown")
        domains[d] = domains.get(d, 0) + 1

    lines = [
        f"# Segment Compiler Report — {Path(bl_root).name}",
        f"Generated: {date.today()}",
        "",
        "## Summary",
        "",
        f"| Metric | Value |",
        f"|--------|-------|",
        f"| Total segments | {total} |",
        f"| With frontmatter | {with_frontmatter} ({100*with_frontmatter//max(total,1)}%) |",
        f"| Total entries | {total_entries} |",
        f"| Total fingerprints | {total_fps} |",
        f"| Total source refs | {total_refs} |",
        f"| With refs | {with_refs} ({100*with_refs//max(total,1)}%) |",
        f"| With tags | {with_tags} |",
        "",
        "## Confidence Breakdown",
        "",
        f"| Level | Count |",
        f"|-------|-------|",
        f"| 🔴 High | {high_conf} |",
        f"| 🟡 Medium | {medium_conf} |",
        f"| 🔵 Low | {low_conf} |",
        f"| ⚪ Unverified | {unverified} |",
        "",
        "## Domain Distribution",
        "",
        "| Domain | Count |",
        "|--------|-------|",
    ]
    for d in sorted(domains.keys()):
        lines.append(f"| {d} | {domains[d]} |")

    if issues:
        lines.extend(["", "## Issues Found", "", f"Total: {len(issues)} issues", ""])
        for issue in issues:
            lines.append(f"- [{issue['severity']}] {issue['file']}: {issue['message']}")

    return "\n".join(lines) + "\n"

# ── Main ────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    if not args:
        print("Usage: compile-segments.py <bl-root> [--fix] [--rebuild] [--quiet]")
        sys.exit(1)

    bl_root = Path(args[0])
    do_fix = "--fix" in args
    do_rebuild = "--rebuild" in args
    quiet = "--quiet" in args

    split_dir = bl_root / "split"
    if not split_dir.is_dir():
        print(f"ERROR: {split_dir} not found")
        sys.exit(1)

    md_files = sorted(split_dir.glob("*.md"))
    if not quiet:
        print(f"Compiling {len(md_files)} segments in {bl_root}...")

    segments = []
    all_issues = []
    all_fingerprints = set()

    for fpath in md_files:
        content = fpath.read_text(encoding="utf-8")
        if not quiet:
            print(f"  {fpath.name}...", end=" ")

        has_frontmatter = content.startswith("---")
        fm, rest = parse_frontmatter(content)

        seg_info = {
            "path": str(fpath),
            "bl_root": str(bl_root),
            "has_frontmatter": has_frontmatter,
            "fm": fm or {},
        }

        if not has_frontmatter:
            all_issues.append({
                "file": fpath.name,
                "severity": "WARN",
                "message": "No YAML frontmatter — run migrate-frontmatter.py first",
            })
            if not quiet:
                print("NO FRONTMATTER")
            segments.append(seg_info)
            continue

        # Validate
        issues = validate_frontmatter(fm, fpath.name)
        for iss in issues:
            all_issues.append({"file": fpath.name, "severity": "ERROR", "message": iss})
            if not quiet:
                print(f"  ERROR: {iss}")

        # Parse entries
        entries = parse_entries(rest) + parse_table_entries(rest)
        seg_info["entries"] = entries

        # Collect fingerprints
        for fp in fm.get("fingerprints", []):
            all_fingerprints.add(fp)
        for entry in entries:
            if entry.get("fingerprint"):
                all_fingerprints.add(entry["fingerprint"])

        # Check fingerprint cross-refs
        fp_issues = check_fingerprint_refs(fm, all_fingerprints)
        for iss in fp_issues:
            all_issues.append({"file": fpath.name, "severity": "WARN", "message": iss})
            if not quiet:
                print(f"  WARN: {iss}")

        if not quiet and has_frontmatter:
            refs = fm.get("source_refs", 0)
            conf = fm.get("confidence", "?")
            domain = fm.get("domain", "?")
            print(f"OK ({domain}, {conf}, {refs} refs)")

        segments.append(seg_info)

    # Generate reports
    if do_rebuild:
        index_content = build_index(segments)
        (bl_root / "INDEX.md").write_text(index_content, encoding="utf-8")
        if not quiet:
            print(f"\nWrote INDEX.md ({len(segments)} entries)")

        fp_content = build_fingerprints(segments)
        (bl_root / "FINGERPRINTS.md").write_text(fp_content, encoding="utf-8")
        if not quiet:
            print(f"Wrote FINGERPRINTS.md ({len(all_fingerprints)} fingerprints)")

        sm_content = build_source_map(segments)
        (bl_root / "SOURCE_MAP.md").write_text(sm_content, encoding="utf-8")
        if not quiet:
            print(f"Wrote SOURCE_MAP.md")

    # Print report
    report = build_report(segments, all_issues, bl_root)
    report_path = bl_root / "COMPILER_REPORT.md"
    report_path.write_text(report, encoding="utf-8")
    if not quiet:
        print(f"\nWrote {report_path.name}")
        print(f"\n=== Issues: {len(all_issues)} ===")
        for iss in all_issues[:20]:
            print(f"  [{iss['severity']}] {iss['file']}: {iss['message']}")
        if len(all_issues) > 20:
            print(f"  ... and {len(all_issues) - 20} more")

    # Exit with error code if issues found
    if all_issues:
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
