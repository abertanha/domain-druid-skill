#!/usr/bin/env python3
"""Technology-agnostic gap scanner using pattern registry YAML files.

Usage:
  scan-from-registry.py <patterns-dir> <source-dir> <bl-dir> [--quick]

Outputs markdown sections for each pattern signal, cross-referenced
against existing fingerprints in the business logic segments.
"""

import os
import sys
import yaml
import re
import json
import glob
import fnmatch
import subprocess
from pathlib import Path
from datetime import date

CONFIDENCE_BADGES = {
    "high": "🔴 High",
    "medium": "🟡 Medium",
    "low": "🔵 Low",
    "unverified": "⚪ Unverified",
}


def load_patterns(patterns_dir):
    """Load all YAML pattern files from directory."""
    patterns = []
    for yf in sorted(glob.glob(os.path.join(patterns_dir, "*.yaml"))):
        with open(yf) as f:
            try:
                data = yaml.safe_load(f)
            except Exception as e:
                print(f"WARN: Failed to parse {yf}: {e}", file=sys.stderr)
                continue
        if not data or not isinstance(data, dict):
            continue
        base_conf = data.get("confidence", "medium")
        requires = data.get("requires", [])
        for sig in data.get("signals", []):
            patterns.append({
                "name": sig.get("name", "unknown"),
                "type": sig.get("type", "Rule"),
                "confidence": sig.get("confidence", base_conf),
                "patterns": sig.get("patterns", []),
                "files": sig.get("files", []),
                "scan_content": sig.get("scan_content", True),
                "requires": requires,
            })
    return patterns


def find_matching_files(source_dir, file_patterns):
    """Find files matching glob patterns using find + fnmatch."""
    matched = []
    if not file_patterns:
        # Scan all source files
        for ext in ["*.ts", "*.tsx", "*.js", "*.jsx", "*.py", "*.rs"]:
            for root, dirs, files in os.walk(source_dir):
                dirs[:] = [d for d in dirs if d not in ("node_modules", ".git", "dist", "build")]
                for f in files:
                    if fnmatch.fnmatch(f, ext):
                        matched.append(os.path.join(root, f))
        return sorted(set(matched))

    for fp in file_patterns:
        # Normalize glob: if it starts with *, match basename only
        for root, dirs, files in os.walk(source_dir):
            dirs[:] = [d for d in dirs if d not in ("node_modules", ".git", "dist", "build")]
            for f in files:
                full = os.path.join(root, f)
                rel = full.replace(source_dir, "").lstrip("/")
                # Match against basename (fnmatch * doesn't cross /)
                if fnmatch.fnmatch(f, fp) or fnmatch.fnmatch(rel, fp) or fnmatch.fnmatch(full, fp):
                    matched.append(full)
    return sorted(set(matched))


def load_known_fingerprints(bl_dir):
    """Load known fingerprints from BL directory."""
    known = {}
    # Read from FINGERPRINTS.md
    fp_path = os.path.join(bl_dir, "FINGERPRINTS.md")
    if os.path.exists(fp_path):
        with open(fp_path) as f:
            for line in f:
                m = re.match(r"^\|\s*(.+?)\s*\|\s*(.+?)\s*\|", line)
                if m and not m.group(1).startswith("Fingerprint"):
                    known[m.group(1).strip()] = m.group(2).strip()
    # Also read from segment frontmatter
    split_dir = os.path.join(bl_dir, "split")
    if os.path.isdir(split_dir):
        for seg_file in sorted(glob.glob(os.path.join(split_dir, "*.md"))):
            with open(seg_file) as f:
                content = f.read()
            if content.startswith("---"):
                parts = content.split("---", 2)
                if len(parts) >= 3:
                    try:
                        fm = yaml.safe_load(parts[1])
                    except yaml.YAMLError:
                        continue
                    if fm and "fingerprints" in fm:
                        seg_id = fm.get("id", os.path.basename(seg_file))
                        for fp in fm["fingerprints"]:
                            if fp not in known:
                                known[fp] = seg_id
    return known


def normalize_path(p):
    """Normalize a source file path for comparison."""
    p = re.sub(r"^source/", "", p)
    p = re.sub(r"^src/", "", p)
    p = re.sub(r"^\./", "", p)
    if "/src/" in p:
        p = p.split("/src/", 1)[1]
    return p


def scan_signal(source_dir, signal, known_fps, quick=False):
    """Scan for a single signal and return markdown section."""
    name = signal["name"]
    sig_type = signal["type"]
    confidence = signal["confidence"]
    content_patterns = signal["patterns"]
    file_patterns = signal["files"]
    scan_content = signal["scan_content"]

    if quick and name in ("constant-limit", "state-machine", "test-assertion"):
        return None

    badge = CONFIDENCE_BADGES.get(confidence, "🔵 Low")
    files = find_matching_files(source_dir, file_patterns)

    if not files:
        return None

    known_count = 0
    new_count = 0
    lines = [f"\n### {name}", "", f"Type: {sig_type} | Confidence: {badge}", ""]

    if scan_content and content_patterns:
        # Build combined regex
        try:
            combined = "|".join(f"({p})" for p in content_patterns)
            regex = re.compile(combined)
        except re.error:
            regex = None

        for fpath in files:
            rel = normalize_path(fpath.replace(source_dir, "").lstrip("/"))
            try:
                with open(fpath, errors="ignore") as f:
                    content = f.read()
            except (IOError, OSError):
                continue

            matches = []
            for i, line in enumerate(content.split("\n"), 1):
                if regex and regex.search(line):
                    matches.append(f"  - L{i}: {line.strip()[:120]}")

            if matches:
                is_known = False
                for kfp in known_fps:
                    if kfp in rel:
                        is_known = True
                        break
                if is_known:
                    status = "✅ mapped"
                    known_count += 1
                else:
                    status = "🆕 new"
                    new_count += 1
                lines.append(f"- [{status}] `{rel}`:")
                lines.extend(matches[:5])
                if len(matches) > 5:
                    lines.append(f"  - ... and {len(matches) - 5} more signals")
    else:
        # File-only mode
        for fpath in files:
            rel = normalize_path(fpath.replace(source_dir, "").lstrip("/"))
            is_known = False
            for kfp in known_fps:
                if kfp in rel:
                    is_known = True
                    break
            if is_known:
                status = "✅ mapped"
                known_count += 1
            else:
                status = "🆕 new"
                new_count += 1
            lines.append(f"- [{status}] `{rel}`")

    if known_count == 0 and new_count == 0:
        return None

    lines.append("")
    lines.append(f"Files: {len(files)} (✅ {known_count} known, 🆕 {new_count} new)")
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    if len(args) < 3:
        print("Usage: scan-from-registry.py <patterns-dir> <source-dir> <bl-dir> [--quick]")
        sys.exit(1)

    patterns_dir = args[0]
    source_dir = args[1]
    bl_dir = args[2]
    quick = "--quick" in args

    if not os.path.isdir(patterns_dir):
        print(f"ERROR: Patterns dir not found: {patterns_dir}", file=sys.stderr)
        sys.exit(1)

    patterns = load_patterns(patterns_dir)
    known_fps = load_known_fingerprints(bl_dir)

    sections = []
    for sig in patterns:
        section = scan_signal(source_dir, sig, known_fps, quick=quick)
        if section:
            sections.append(section)

    output = []
    output.append("## Pattern Registry Scan")
    output.append("")
    output.append(f"Loaded from: {patterns_dir}")
    output.append(f"Signals: {len(patterns)}")
    output.append("")

    output.extend(sections)

    if sections:
        output.append("")
        output.append("---")

    print("\n".join(output))


if __name__ == "__main__":
    main()
