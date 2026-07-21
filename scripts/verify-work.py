#!/usr/bin/env python3
"""verify-work — post-implementation gap verification.

Checks whether files changed since last manifest are covered by existing
business logic segments. Uses path-matching only — zero content scanning.

Usage:
  python3 verify-work.py <src-dir> <bl-root>          # standard mode
  python3 verify-work.py <src-dir> <bl-root> --strict # exit 1 if gaps exist
  python3 verify-work.py <src-dir> <bl-root> --manifest <file>  # explicit manifest

Exit codes:
  0 — all changed files covered
  1 — one or more changed files undocumented (or --strict)
  2 — usage error
  3 — no manifest found
"""

import os
import sys
import json
import hashlib
import re
import fnmatch
from pathlib import Path
from datetime import date

MANIFEST_DIR = ".domain-druid"
MANIFEST_FILE = "manifest.json"
MANIFEST_BEFORE = "manifest.before.json"


def hash_file(filepath):
    h = hashlib.sha256()
    try:
        with open(filepath, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
    except (IOError, OSError):
        return None
    return h.hexdigest()


def generate_manifest(src_dir):
    manifest = {}
    for root, dirs, files in os.walk(src_dir):
        dirs[:] = [d for d in dirs if d not in ("node_modules", ".git", "dist", "build", "__pycache__", ".next", "cache", ".cache")]
        for f in files:
            if not any(f.endswith(ext) for ext in (".ts", ".tsx", ".js", ".jsx", ".py", ".rs")):
                continue
            full = os.path.join(root, f)
            h = hash_file(full)
            if h:
                rel = os.path.relpath(full, src_dir)
                manifest[rel] = h
    return manifest


def load_manifest(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def diff_manifests(previous, current):
    prev_keys = set(previous.keys())
    curr_keys = set(current.keys())
    changed = set()
    for key in curr_keys:
        if key not in prev_keys:
            changed.add(key)
        elif previous[key] != current[key]:
            changed.add(key)
    deleted = prev_keys - curr_keys
    return changed, deleted


def normalize_path(p):
    p = re.sub(r"^source/", "", p)
    p = re.sub(r"^src/", "", p)
    p = re.sub(r"^\./", "", p)
    if "/src/" in p:
        p = p.split("/src/", 1)[1]
    return p


def load_source_map(bl_root):
    sm_path = os.path.join(bl_root, "SOURCE_MAP.md")
    mapping = {}
    if os.path.exists(sm_path):
        with open(sm_path) as f:
            for line in f:
                m = re.match(r"^\|\s*`([^`]+)`\s*\|\s*(.+?)\s*\|", line)
                if m and not m.group(1).startswith("Source File"):
                    mapping[normalize_path(m.group(1).strip())] = m.group(2).strip()
    return mapping


def check_coverage(filepath, source_map, bl_root):
    normalized = normalize_path(filepath)
    filename = os.path.basename(filepath)
    dirpath = os.path.dirname(normalized)

    # 1. Exact match in source map
    if normalized in source_map:
        return True, source_map[normalized]

    # 2. Basename match in source map
    for sm_path, seg_id in source_map.items():
        if os.path.basename(sm_path) == filename:
            return True, seg_id

    # 3. Path suffix match (e.g., "app/foo.ts" matches "src/app/foo.ts")
    for sm_path, seg_id in source_map.items():
        if normalized.endswith(sm_path) or sm_path.endswith(normalized):
            return True, seg_id

    # 4. Fallback: grep split/ for backtick refs
    split_dir = os.path.join(bl_root, "split")
    if os.path.isdir(split_dir):
        for seg_file in sorted(os.listdir(split_dir)):
            if not seg_file.endswith(".md"):
                continue
            seg_path = os.path.join(split_dir, seg_file)
            try:
                with open(seg_path) as f:
                    content = f.read()
            except (IOError, OSError):
                continue
            # Look for backtick code refs matching any part of the path
            refs = re.findall(r"`([^`]+(?:\.ts|\.tsx|\.js|\.jsx|\.py|\.rs)[^`]*)`", content)
            for ref in refs:
                ref_norm = normalize_path(ref)
                if filename in ref_norm or normalized == ref_norm or normalized.endswith(ref_norm):
                    return True, seg_file.replace(".md", "")
                # Check if any component of the path matches
                ref_parts = set(ref_norm.replace("\\", "/").split("/"))
                file_parts = set(normalized.replace("\\", "/").split("/"))
                # If they share a common suffix of 2+ path components
                ref_suffix = "/".join(ref_norm.replace("\\", "/").split("/")[-2:])
                file_suffix = "/".join(normalized.replace("\\", "/").split("/")[-2:])
                if ref_suffix and ref_suffix == file_suffix:
                    return True, seg_file.replace(".md", "")

    return False, None


def infer_type(filepath, basename):
    if re.search(r'\b(test|spec)\b', basename, re.I):
        return "Invariant"
    if re.search(r'\b(enum|type|interface|schema)\b', basename, re.I):
        return "Definition"
    if re.match(r'^I[A-Z]', basename):
        return "Definition"
    if re.search(r'\b(limit|max|min\b|threshold|constant)\b', basename, re.I):
        return "Limit"
    if re.search(r'\b(middle|auth|guard|level)\b', basename, re.I):
        return "Access Control"
    if re.search(r'\b(hook|context|provider)\b', basename, re.I):
        return "Definition"
    if re.search(r'\b(slice|store|reducer)\b', basename, re.I):
        return "Rule"
    dir_parts = filepath.replace("\\", "/").split("/")
    for part in dir_parts:
        if re.search(r'component|hook|context|provider', part, re.I):
            return "Frontend"
        if re.search(r'service|api|repository|gateway', part, re.I):
            return "Service"
        if re.search(r'controller|handler|router|route', part, re.I):
            return "Controller"
        if re.search(r'model|schema|entity', part, re.I):
            return "Model"
        if re.search(r'middleware|guard|auth', part, re.I):
            return "Middleware"
        if re.search(r'test|spec|__test__', part, re.I):
            return "Test"
    return "Rule"


def derive_domain(filepath):
    normalized = normalize_path(filepath)
    parts = normalized.replace("\\", "/").split("/")
    if len(parts) > 1:
        return "-".join(parts[:-1]).lower()
    return ""


def derive_tags(filepath):
    normalized = normalize_path(filepath)
    parts = normalized.replace("\\", "/").split("/")
    tags = [p for p in parts if p != parts[-1] and p not in ("", ".")]
    return ", ".join(tags) if tags else "auto"


def derive_fingerprint(fp_prefix, domain, basename):
    base = basename
    base = re.sub(r'\.(tsx?|jsx?|py|rs)$', '', base)
    if domain:
        raw = f"{fp_prefix}-{domain}-{base}"
    else:
        raw = f"{fp_prefix}-{base}"
    return re.sub(r'[^a-z0-9-]', '', raw.lower())


def get_repo_prefix(bl_root):
    m = re.search(r'\.business-logic/([^/]+)', bl_root)
    if m:
        return m.group(1)
    return "app"


def write_pending_entries(bl_root, gaps, src_dir):
    pending_path = os.path.join(bl_root, "PENDING.md")
    prefix = get_repo_prefix(bl_root)
    existing = set()
    if os.path.exists(pending_path):
        with open(pending_path) as f:
            for line in f:
                m = re.match(r'^### Pending:\s*(.+)$', line.strip())
                if m:
                    existing.add(m.group(1).strip())
    written = 0
    skipped = 0
    blocks = []
    for fp in sorted(gaps):
        if fp in existing:
            skipped += 1
            continue
        basename = os.path.basename(fp)
        normalized = normalize_path(fp)
        domain = derive_domain(fp)
        entry_type = infer_type(fp, basename)
        fingerprint = derive_fingerprint(prefix, domain, basename)
        tags = derive_tags(fp)
        sz = os.path.getsize(os.path.join(src_dir, fp)) if os.path.exists(os.path.join(src_dir, fp)) else 0
        block = (
            f"### Pending: {fp}\n"
            f"\n"
            f"- **Source:** `{fp}` ({sz // 1024}KB)\n"
            f"- **Discovered:** {date.today()} by verify-work\n"
            f"- **Type:** {entry_type} (inferred)\n"
            f"- **Fingerprint:** {fingerprint}\n"
            f"- **Tags:** {tags}\n"
            f"- **Status:** pending\n"
        )
        blocks.append(block)
        written += 1
    if not blocks:
        return written, skipped
    if os.path.exists(pending_path):
        with open(pending_path) as f:
            existing = f.read().rstrip()
        content = existing + "\n\n" + "\n".join(blocks)
    else:
        content = f"# PENDING — {prefix}\n\n" + "\n".join(blocks)
    with open(pending_path, "w") as f:
        f.write(content)
    return written, skipped


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print("Usage: verify-work.py <src-dir> <bl-root> [--strict] [--manifest <file>] [--write-pending]")
        sys.exit(2)

    src_dir = os.path.abspath(args[0])
    bl_root = os.path.abspath(args[1])
    strict = "--strict" in args
    write_pending = "--write-pending" in args

    # Determine manifest path
    manifest_idx = 4 if "--manifest" in args else -1
    if manifest_idx >= 0 and len(args) > manifest_idx:
        manifest_path = args[manifest_idx]
    else:
        manifest_path = os.path.join(bl_root, MANIFEST_DIR, MANIFEST_FILE)

    # Validate
    if not os.path.isdir(src_dir):
        print(f"ERROR: Source dir not found: {src_dir}", file=sys.stderr)
        sys.exit(2)
    if not os.path.isdir(bl_root):
        print(f"ERROR: BL root not found: {bl_root}", file=sys.stderr)
        sys.exit(2)

    # Load previous manifest
    prev_manifest = load_manifest(manifest_path)
    if prev_manifest is None:
        print(f"ERROR: No manifest found at {manifest_path}", file=sys.stderr)
        print("Run init-manifest first.", file=sys.stderr)
        sys.exit(3)

    # Save as .before for diff reference
    before_path = os.path.join(os.path.dirname(manifest_path), MANIFEST_BEFORE)
    with open(before_path, "w") as f:
        json.dump(prev_manifest, f, indent=2)

    # Load source map
    source_map = load_source_map(bl_root)

    # Generate current manifest
    current_manifest = generate_manifest(src_dir)
    curr_count = len(current_manifest)

    # Diff
    changed, deleted = diff_manifests(prev_manifest, current_manifest)

    # Check coverage for each changed file
    covered = []
    gaps = []
    stale_refs = []

    for filepath in sorted(changed):
        is_covered, seg_id = check_coverage(filepath, source_map, bl_root)
        if is_covered:
            covered.append((filepath, seg_id))
        else:
            gaps.append(filepath)

    # Check deleted files — are they still referenced in segments?
    for filepath in sorted(deleted):
        is_covered, seg_id = check_coverage(filepath, source_map, bl_root)
        if is_covered:
            stale_refs.append((filepath, seg_id))

    # Save current manifest as new baseline
    with open(manifest_path, "w") as f:
        json.dump(current_manifest, f, indent=2)

    # ── Build output ──
    lines = []
    lines.append(f"## Verify Work — {os.path.basename(src_dir)}")
    lines.append("")
    lines.append(f"Generated: {date.today()}")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|--------|-------|")
    lines.append(f"| Source files | {curr_count} |")
    lines.append(f"| Previously manifest | {len(prev_manifest)} |")
    lines.append(f"| Changed | {len(changed)} |")
    lines.append(f"| Deleted | {len(deleted)} |")
    lines.append(f"| Covered | {len(covered)} |")
    lines.append(f"| **New gaps** | **{len(gaps)}** |")
    lines.append(f"| Stale refs | {len(stale_refs)} |")
    lines.append("")

    if covered:
        lines.append("### ✅ Covered Changes")
        lines.append("")
        for fp, seg in covered:
            lines.append(f"- `{fp}` → {seg}")
        lines.append("")

    if gaps:
        lines.append("### 🆕 New Gaps (Undocumented)")
        lines.append("")
        lines.append("These files changed but have no code reference in any segment:")
        lines.append("")
        for fp in gaps:
            sz = os.path.getsize(os.path.join(src_dir, fp)) if os.path.exists(os.path.join(src_dir, fp)) else 0
            lines.append(f"- `{fp}` ({sz // 1024}KB)")
        lines.append("")

    if stale_refs:
        lines.append("### ⚠️ Stale Refs (Deleted Files Still Referenced)")
        lines.append("")
        lines.append("These files were deleted but are still referenced in segments:")
        lines.append("")
        for fp, seg in stale_refs:
            lines.append(f"- `{fp}` → {seg}")
        lines.append("")

    if not covered and not gaps and not stale_refs:
        lines.append("✅ No files changed since last manifest.")
        lines.append("")
    elif not gaps and not stale_refs:
        lines.append("✅ All changed files are covered by existing segments.")
        lines.append("")
    elif not gaps and stale_refs:
        lines.append("🔶 All changed files covered, but stale refs found. Run /check-staleness to clean up.")
        lines.append("")

    report_path = os.path.join(bl_root, "reviews", f"{date.today()}-verify-work.md")
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w") as f:
        f.write("\n".join(lines))
    lines.append(f"Report saved: {report_path}")
    lines.append("")

    # Write pending entries if flag set and gaps exist
    if write_pending and gaps:
        written, skipped = write_pending_entries(bl_root, gaps, src_dir)
        pending_note = f"\n📝 PENDING.md: {written} new pending entries"
        if skipped:
            pending_note += f" ({skipped} skipped — duplicates)"
        lines.append(pending_note)

    # Print to stdout
    sys.stdout.write("\n".join(lines) + "\n")

    # Exit code
    has_issues = len(gaps) > 0 or (strict and len(stale_refs) > 0)
    sys.exit(1 if has_issues else 0)


if __name__ == "__main__":
    main()
