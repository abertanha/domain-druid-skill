#!/usr/bin/env python3
"""Migrate existing segment files to include YAML frontmatter.

Usage:
  python3 migrate-frontmatter.py <segments-dir> [--dry-run]
  python3 migrate-frontmatter.py <segments-dir> [--revert]

Parses existing inline metadata and prepends frontmatter.
Backs up originals as *.bak if --dry-run is not set.
"""

import os
import re
import sys
import yaml
import json
from datetime import date
from pathlib import Path

SCHEMA = {
    "id": {"required": True, "type": str},
    "type": {"required": True, "type": str, "default": "Segment"},
    "domain": {"required": False, "type": str},
    "status": {"required": False, "type": str, "default": "active"},
    "confidence": {"required": False, "type": str, "default": "medium"},
    "fingerprints": {"required": False, "type": list, "default": []},
    "tags": {"required": False, "type": list, "default": []},
    "established": {"required": False, "type": str},
    "source_refs": {"required": False, "type": int, "default": 0},
    "related": {"required": False, "type": list, "default": []},
    "description": {"required": False, "type": str},
}

ENTRY_META_RE = re.compile(
    r"^-\s*(Type|Status|Fingerprint|Tags|Code|Established):\s*(.+)",
    re.MULTILINE,
)

TAG_LINE_RE = re.compile(r"-\s*Tags?:\s*(.*)")
STATUS_LINE_RE = re.compile(r"Status:\s*(active|archived|stub)")
FINGERPRINT_LINE_RE = re.compile(r"Fingerprint:\s*(\S+)")
ESTABLISHED_LINE_RE = re.compile(r"Established:\s*(\S+)")
CODE_LINE_RE = re.compile(r"Code:\s*\n(\s+-.*(?:\n\s+-.*)*)")

DOMAIN_KEYWORDS = {
    "proposal": "proposal",
    "product": "product",
    "auth": "auth",
    "security": "auth",
    "user": "user",
    "customer": "customer",
    "credential": "credential",
    "bank": "banking",
    "financial": "financial",
    "payment": "financial",
    "contract": "financial",
    "report": "report",
    "dashboard": "report",
    "hierarchy": "hierarchy",
    "level": "hierarchy",
    "permission": "auth",
    "role": "auth",
    "communication": "communication",
    "integration": "communication",
    "notification": "communication",
    "backoffice": "admin",
    "admin": "admin",
    "state": "state",
    "redux": "state",
    "store": "state",
    "hook": "state",
    "context": "state",
    "rule": "rule",
    "validation": "rule",
    "limit": "limit",
    "constraint": "limit",
    "config": "config",
    "settings": "config",
}


def extract_id(filename):
    stem = Path(filename).stem
    return stem


def extract_title(content):
    m = re.search(r"^#{1,2}\s+(.+)", content, re.MULTILINE)
    return m.group(1).strip() if m else ""


def extract_description(content, title):
    lines = content.split("\n")
    after_title = False
    in_content = False
    desc_lines = []
    for line in lines:
        if line.strip().lstrip("#").strip().startswith(title) and not after_title:
            after_title = True
            continue
        if after_title:
            stripped = line.strip()
            if not stripped and not in_content:
                continue
            if not in_content:
                in_content = True
            if not stripped:
                break
            if stripped.startswith("#") or stripped.startswith("|") or stripped.startswith("-"):
                break
            if re.match(r"^- (Type|Status|Fingerprint|Tags|Code)", stripped):
                break
            desc_lines.append(stripped)
    return " ".join(desc_lines) if desc_lines else ""


def count_source_refs(content):
    code_refs = re.findall(r"`([^`]+\.(ts|tsx|js|jsx|py|rs)[^`]*)`", content)
    code_refs += re.findall(r"Code:\s*\n(\s+-.*)", content)
    return len(set(code_refs))


def extract_tags(content):
    tags = set()
    for m in TAG_LINE_RE.finditer(content):
        val = m.group(1).strip()
        for t in re.split(r"[,|]", val):
            t = t.strip().strip("`").strip()
            if t:
                tags.add(t.lower())
    return sorted(tags)


def extract_fingerprints(content):
    fps = set()
    for m in FINGERPRINT_LINE_RE.finditer(content):
        fps.add(m.group(1).strip())
    return sorted(fps)


def extract_status(content):
    m = STATUS_LINE_RE.search(content)
    return m.group(1) if m else "active"


def extract_established(content):
    for m in ESTABLISHED_LINE_RE.finditer(content):
        return m.group(1).strip()
    return str(date.today())


def infer_domain(title, tags, content):
    text = f"{title} {' '.join(tags)} {content[:500]}".lower()
    for keyword, domain in DOMAIN_KEYWORDS.items():
        if keyword in text:
            return domain
    return "general"


def infer_confidence(content):
    refs = count_source_refs(content)
    has_fingerprints = bool(re.search(r"Fingerprint:\s*\S+", content))
    has_code_block = bool(re.search(r"Code:\s*\n", content))
    has_table = bool(re.search(r"\|.*Code.*\|", content))
    if (has_fingerprints and has_code_block) or (has_table and refs >= 10):
        return "high"
    if has_code_block or has_table or refs >= 5:
        return "medium"
    if refs >= 1:
        return "low"
    return "unverified"


def build_frontmatter(seg_id, title, content):
    tags = extract_tags(content)
    fingerprints = extract_fingerprints(content)
    status = extract_status(content)
    established = extract_established(content)
    source_refs = count_source_refs(content)
    domain = infer_domain(title, tags, content)
    confidence = infer_confidence(content)
    description = extract_description(content, title)

    inferred_type = "segment"
    fm = {
        "id": seg_id,
        "type": inferred_type,
        "domain": domain,
        "status": status,
        "confidence": confidence,
        "fingerprints": fingerprints,
        "tags": tags,
        "established": established,
        "source_refs": source_refs,
    }
    if description:
        fm["description"] = description
    if re.search(r"^1[5-9]|^2[0-9]", seg_id.split("-")[0]):
        fm["type"] = "Stub"
    return fm


def has_frontmatter(content):
    return content.strip().startswith("---")


def migrate_file(filepath, dry_run=False):
    path = Path(filepath)
    content = path.read_text(encoding="utf-8")

    if has_frontmatter(content):
        print(f"  SKIP {path.name} (already has frontmatter)")
        return False

    seg_id = extract_id(filepath)
    title = extract_title(content)
    if not title:
        print(f"  SKIP {path.name} (no title found)")
        return False

    fm = build_frontmatter(seg_id, title, content)
    fm_str = yaml.dump(fm, default_flow_style=False, allow_unicode=True, sort_keys=False)
    fm_block = f"---\n{fm_str}---\n\n"

    if dry_run:
        print(f"  WOULD MIGRATE {path.name} -> id={seg_id}, domain={fm['domain']}, status={fm['status']}, refs={fm['source_refs']}")
        return False

    backup = path.with_suffix(path.suffix + ".bak")
    if not backup.exists():
        path.rename(backup)

    new_content = fm_block + content
    path.write_text(new_content, encoding="utf-8")
    print(f"  MIGRATED {path.name} ({fm['domain']}, {fm['confidence']}, {fm['source_refs']} refs)")
    return True


def revert_file(filepath):
    path = Path(filepath)
    backup = path.with_suffix(path.suffix + ".bak")
    if not backup.exists():
        print(f"  NO BACKUP for {path.name}")
        return False
    path.write_text(backup.read_text(encoding="utf-8"), encoding="utf-8")
    backup.unlink()
    print(f"  REVERTED {path.name}")
    return True


def main():
    args = sys.argv[1:]
    if not args:
        print("Usage: migrate-frontmatter.py <segments-dir> [--dry-run|--revert]")
        sys.exit(1)

    seg_dir = Path(args[0])
    if not seg_dir.is_dir():
        print(f"ERROR: {seg_dir} is not a directory")
        sys.exit(1)

    dry_run = "--dry-run" in args
    revert = "--revert" in args

    md_files = sorted(seg_dir.glob("*.md"))
    print(f"Found {len(md_files)} segment files in {seg_dir}")
    if dry_run:
        print("DRY RUN — no changes will be made")
    if revert:
        print("REVERT mode — restoring from .bak files")

    migrated = 0
    skipped = 0
    for fpath in md_files:
        if revert:
            if revert_file(fpath):
                migrated += 1
            else:
                skipped += 1
        else:
            if migrate_file(fpath, dry_run=dry_run):
                migrated += 1
            else:
                skipped += 1

    action = "reverted" if revert else "migrated"
    if dry_run:
        action = "would migrate"
    print(f"\nDone: {migrated} {action}, {skipped} skipped")


if __name__ == "__main__":
    main()
