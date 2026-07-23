#!/usr/bin/env python3
"""Consolidate proposals into domain-grouped segment files.

Groups proposals by their `domain:` frontmatter field, merges entries
into one segment per domain, deduplicates, and splits by token budget.

Usage:
  python3 consolidate-proposals.py <bl-root>           # Consolidate proposals/
  python3 consolidate-proposals.py <bl-root> --in-place # Consolidate existing split/ files
"""
import re, sys
from pathlib import Path

TOKEN_LIMIT = 1000  # max tokens before sub-split

YAML_RE = re.compile(r"^---\s*\n(.*?)\n---", re.DOTALL)
ENTRY_RE = re.compile(r"^## (.+)$", re.MULTILINE)
FP_LINE = re.compile(r"^- Fingerprint:\s*(.+)", re.MULTILINE)
CODE_LINE = re.compile(r"`([^`]+\.(ts|tsx|js|jsx|py|rs)[^`]*)`")


def parse_frontmatter(content):
    m = YAML_RE.match(content)
    if not m:
        return {}, content
    fm = {}
    for line in m.group(1).split("\n"):
        if ":" in line:
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip()
            if key == "fingerprints" and val.startswith("-"):
                fm[key] = []
            elif key == "tags" and val.startswith("-"):
                fm[key] = []
            elif val == "[]" or val == "":
                fm[key] = [] if key in ("fingerprints", "tags") else val
            else:
                try:
                    fm[key] = int(val)
                except ValueError:
                    fm[key] = val.strip("'\"")
    rest = content[m.end():].strip()
    return fm, rest


def parse_entries(content):
    entries = []
    blocks = re.split(r"\n(?=## )", content)
    for block in blocks:
        if not block.strip():
            continue
        lines = block.strip().split("\n")
        title = lines[0].lstrip("#").strip() if lines[0].startswith("#") else ""
        entry = {"title": title, "fingerprint": "", "body": block.strip()}
        for line in lines:
            if line.strip().startswith("- Fingerprint:"):
                entry["fingerprint"] = line.split(":", 1)[1].strip()
        entries.append(entry)
    return entries


def token_estimate(text):
    return max(1, len(text.encode("utf-8")) // 4)


def count_code_refs(entries):
    refs = set()
    for e in entries:
        for m in CODE_LINE.findall(e["body"]):
            refs.add(m[0])
    return len(refs)


def build_segment_content(domain, entries, max_nn):
    refs = count_code_refs(entries)
    lines = [
        "---",
        f"id: {domain}",
        "type: segment",
        f"domain: {domain}",
        "status: active",
        "confidence: low",
        "fingerprints: []",
        "tags: []",
        f"source_refs: {refs}",
        "---",
        "",
    ]
    for e in entries:
        lines.append("")
        lines.append(e["body"])
        lines.append("")
    content = "\n".join(lines) + "\n"
    return content


def distribute_entries(entries, budgets):
    """Split entries into N roughly equal groups."""
    n = len(budgets)
    k, m = divmod(len(entries), n)
    groups = []
    start = 0
    for i in range(n):
        size = k + (1 if i < m else 0)
        groups.append(entries[start:start + size])
        start += size
    return groups


def consolidate_split(bl_root):
    """Consolidate existing split/ segments in-place by domain.

    Only consolidates files with confidence: low (auto-proposed micro-segments).
    Leaves curated segments (confidence: high/medium) untouched.
    """
    split_dir = bl_root / "split"
    if not split_dir.is_dir():
        return

    all_files = sorted(split_dir.glob("*.md"))
    # Separate low-confidence (consolidation candidates) from curated
    low_conf_files = []
    for fpath in all_files:
        content = fpath.read_text(encoding="utf-8")
        if not content.startswith("---"):
            continue
        fm, _ = parse_frontmatter(content)
        if fm.get("confidence", "") == "low":
            low_conf_files.append((fpath, fm, content))

    if not low_conf_files:
        return

    # Phase 1: Group by domain
    groups = {}
    for fpath, fm, content in low_conf_files:
        domain = fm.get("domain", "general") or "general"
        groups.setdefault(domain, []).append((fpath, fm, content))

    print(f"\nConsolidating {len(low_conf_files)} low-confidence segments into {len(groups)} domain groups...")

    # Phase 2: Find max NN from remaining files (high/medium confidence)
    remaining_files = {f for f, _, _ in low_conf_files}
    max_nn = 0
    for f in split_dir.glob("*.md"):
        if f not in {f for f, _, _ in low_conf_files}:
            m = re.match(r"^(\d{2,})", f.name)
            if m:
                nn = int(m.group(1))
                if nn > max_nn:
                    max_nn = nn

    total_consolidated = 0
    old_files_to_remove = []

    for domain in sorted(groups):
        group = groups[domain]
        max_nn += 1
        nn = max_nn

        entries = []
        seen_fps = set()
        for fpath, fm, content in group:
            old_files_to_remove.append(fpath)
            if not content.startswith("---"):
                continue
            fm2, rest = parse_frontmatter(content)
            parsed = parse_entries(rest)
            for e in parsed:
                fp = e.get("fingerprint", "")
                if fp and fp in seen_fps:
                    continue
                if fp:
                    seen_fps.add(fp)
                entries.append(e)

        if not entries:
            continue

        body = "\n".join(e["body"] for e in entries)
        full = f"---\nid: {domain}\ntype: segment\ndomain: {domain}\n---\n\n{body}\n"
        est = token_estimate(full)

        if est <= TOKEN_LIMIT:
            content = build_segment_content(domain, entries, nn)
            name = f"{nn:02d}-{domain}.md"
            (split_dir / name).write_text(content, encoding="utf-8")
            total_consolidated += len(group)
            print(f"  CONSOLIDATED {len(entries)} entries → {name} ({est}t)")
        else:
            n_subs = min((est // TOKEN_LIMIT) + 1, 26)
            labels = [chr(ord("a") + i) for i in range(n_subs)]
            budgets = [1] * n_subs
            groups_subs = distribute_entries(entries, budgets)
            for i, sub_entries in enumerate(groups_subs):
                if not sub_entries:
                    continue
                label = labels[i]
                content = build_segment_content(f"{domain}-{label}", sub_entries, nn)
                name = f"{nn:02d}-{domain}-{label}.md"
                (split_dir / name).write_text(content, encoding="utf-8")
                sub_est = token_estimate(content)
                print(f"  SPLIT {len(sub_entries)} entries → {name} ({sub_est}t)")
            total_consolidated += len(group)

    # Remove old micro-segments
    for fpath in old_files_to_remove:
        fpath.unlink()

    if total_consolidated > 0:
        remaining = len([f for f in split_dir.glob("*.md") if re.match(r"^\d{2,}", f.name)])
        print(f"\nIn-place consolidation complete: {total_consolidated} files → {remaining} active segments")


def main():
    if len(sys.argv) < 2:
        print("Usage: consolidate-proposals.py <bl-root> [--in-place]")
        sys.exit(1)

    bl_root = Path(sys.argv[1])
    in_place = "--in-place" in sys.argv

    if in_place:
        consolidate_split(bl_root)
        return

    prop_dir = bl_root / "proposals"
    split_dir = bl_root / "split"

    if not prop_dir.is_dir():
        return

    prop_files = sorted(prop_dir.glob("*.md"))
    if not prop_files:
        return

    # Phase 1: Read and group by domain
    groups = {}
    for fpath in prop_files:
        content = fpath.read_text(encoding="utf-8")
        if not content.startswith("---"):
            groups.setdefault("general", []).append((fpath, {}, content))
            continue
        fm, rest = parse_frontmatter(content)
        domain = fm.get("domain", "general") or "general"
        groups.setdefault(domain, []).append((fpath, fm, content))

    # Phase 2: Find max NN in existing split/
    max_nn = 0
    for f in split_dir.glob("*.md"):
        m = re.match(r"^(\d{2,})", f.name)
        if m:
            nn = int(m.group(1))
            if nn > max_nn:
                max_nn = nn

    total_consolidated = 0

    for domain in sorted(groups):
        group = groups[domain]
        max_nn += 1
        nn = max_nn

        entries = []
        seen_fps = set()
        for fpath, fm, content in group:
            if not content.startswith("---"):
                continue
            fm2, rest = parse_frontmatter(content)
            parsed = parse_entries(rest)
            for e in parsed:
                fp = e.get("fingerprint", "")
                if fp and fp in seen_fps:
                    continue
                if fp:
                    seen_fps.add(fp)
                entries.append(e)

        if not entries:
            continue

        # Estimate total tokens
        body = "\n".join(e["body"] for e in entries)
        full = f"---\nid: {domain}\ntype: segment\ndomain: {domain}\n---\n\n{body}\n"
        est = token_estimate(full)

        if est <= TOKEN_LIMIT:
            content = build_segment_content(domain, entries, nn)
            name = f"{nn:02d}-{domain}.md"
            (split_dir / name).write_text(content, encoding="utf-8")
            total_consolidated += len(group)
            print(f"  CONSOLIDATED {len(entries)} entries → {name} ({est}t)")
        else:
            # Split into sub-files
            n_subs = min((est // TOKEN_LIMIT) + 1, 26)
            labels = [chr(ord("a") + i) for i in range(n_subs)]
            budgets = [1] * n_subs
            groups_subs = distribute_entries(entries, budgets)
            for i, sub_entries in enumerate(groups_subs):
                if not sub_entries:
                    continue
                label = labels[i]
                content = build_segment_content(f"{domain}-{label}", sub_entries, nn)
                name = f"{nn:02d}-{domain}-{label}.md"
                (split_dir / name).write_text(content, encoding="utf-8")
                sub_est = token_estimate(content)
                print(f"  SPLIT {len(sub_entries)} entries → {name} ({sub_est}t)")
            total_consolidated += len(group)

    # Phase 3: Remove consolidated proposals
    for fpath in prop_files:
        fpath.unlink()

    if prop_dir.exists() and not list(prop_dir.iterdir()):
        try:
            prop_dir.rmdir()
        except OSError:
            pass

    if total_consolidated > 0:
        print(f"\nConsolidated: {total_consolidated} proposals → {len([f for f in split_dir.glob('*.md') if re.match(r'^\d{2,}', f.name)])} active segments")


if __name__ == "__main__":
    main()
