#!/usr/bin/env python3
"""Generate sitemap.xml from the files actually on disk.

The previous sitemap was hand-maintained. It froze at lastmod 2026-05-03 and
drifted to 10 of 73 real posts while still advertising 5 redirect stubs.
Nothing here is hardcoded: pages are discovered by walking the tree and
classified by reading their markup, so a new post is picked up by existing.

Exclusion is by page-level signal, not by filename list:
  - meta refresh  -> redirect stub, the target gets indexed instead
  - robots noindex -> we are explicitly asking Google not to index it

Run from anywhere:  python3 scripts/gen-sitemap.py [--check]
  --check  exit 1 if sitemap.xml is stale, write nothing (for CI/cron)
"""

from __future__ import annotations

import re
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path

BASE_URL = "https://kilokaki.com"
ROOT = Path(__file__).resolve().parent.parent
SITEMAP = ROOT / "sitemap.xml"

# Directories to walk. Anything not listed is not considered.
SECTIONS = ["", "blog", "how-to"]

# Per-path tuning. Longest matching prefix wins.
# how-to sits above blog: product docs catch mid-decision intent, not browsing.
PRIORITY = {"": ("1.0", "weekly"), "blog/": ("0.7", "monthly"), "how-to/": ("0.8", "monthly")}
INDEX_PRIORITY = {"blog/": ("0.9", "weekly"), "how-to/": ("0.9", "monthly")}

RE_REFRESH = re.compile(r'http-equiv=["\']refresh["\']', re.I)
RE_NOINDEX = re.compile(r'name=["\']robots["\'][^>]*content=["\'][^"\']*noindex', re.I)


def git_lastmod(path: Path) -> str | None:
    """Last commit date touching this file. Authoritative over mtime, which
    rsync and chmod both perturb.

    %as (author date), not %cs (committer date). A rebase replays commits and
    rewrites %cs to the replay time, so the 2026-07-22 rebase of the schema
    work restamped 27 posts as edited-today when the edit was 07-17. That is
    the same perturbation this function was written to escape from, one layer
    up: %cs is to a rebase what mtime is to rsync. %as survives both.
    """
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%as", "--", str(path.relative_to(ROOT))],
            cwd=ROOT, capture_output=True, text=True, timeout=10,
        )
        stamp = out.stdout.strip()
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", stamp):
            return stamp
    except (subprocess.SubprocessError, OSError):
        pass
    return None


def lastmod_for(path: Path) -> str:
    stamp = git_lastmod(path)
    if stamp:
        return stamp
    # Uncommitted or outside git: fall back to mtime rather than invent a date.
    return datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d")


def classify(path: Path) -> str | None:
    """Return a skip reason, or None if the page belongs in the sitemap."""
    try:
        html = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return f"unreadable ({exc})"
    head = html[:4000]  # both signals are meta tags; they live in <head>
    if RE_REFRESH.search(head):
        return "redirect stub"
    if RE_NOINDEX.search(head):
        return "noindex"
    return None


def url_for(path: Path) -> str:
    rel = path.relative_to(ROOT).as_posix()
    if rel == "index.html":
        return f"{BASE_URL}/"
    if rel.endswith("/index.html"):
        return f"{BASE_URL}/{rel[: -len('index.html')]}"
    return f"{BASE_URL}/{rel}"


def weight_for(path: Path) -> tuple[str, str]:
    rel = path.relative_to(ROOT).as_posix()
    if rel == "index.html":
        return PRIORITY[""]
    for prefix, val in INDEX_PRIORITY.items():
        if rel == f"{prefix}index.html":
            return val
    best = PRIORITY[""]
    for prefix, val in PRIORITY.items():
        if prefix and rel.startswith(prefix):
            best = val
    return best


def collect() -> tuple[list[dict], list[tuple[str, str]]]:
    included, skipped = [], []
    for section in SECTIONS:
        directory = ROOT / section if section else ROOT
        for path in sorted(directory.glob("*.html")):
            reason = classify(path)
            rel = path.relative_to(ROOT).as_posix()
            if reason:
                skipped.append((rel, reason))
                continue
            priority, changefreq = weight_for(path)
            included.append({
                "loc": url_for(path),
                "lastmod": lastmod_for(path),
                "changefreq": changefreq,
                "priority": priority,
                "rel": rel,
            })
    # Homepage first, then blog index, then posts newest-first.
    def sort_key(e):
        depth = 0 if e["rel"] == "index.html" else (1 if e["rel"].endswith("index.html") else 2)
        return (depth, "" if depth < 2 else _invert(e["lastmod"]), e["loc"])
    included.sort(key=sort_key)
    return included, skipped


def _invert(stamp: str) -> str:
    """Sort dates descending inside an ascending sort."""
    return str(99999999 - int(stamp.replace("-", "")))


def render(entries: list[dict]) -> str:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<!-- Generated by scripts/gen-sitemap.py. Do not hand-edit:",
        "     edits are overwritten on the next run, and hand-maintenance is",
        "     what let this file rot to 10 of 73 posts. Add a post, rerun. -->",
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ]
    for e in entries:
        lines += [
            "  <url>",
            f"    <loc>{e['loc']}</loc>",
            f"    <lastmod>{e['lastmod']}</lastmod>",
            f"    <changefreq>{e['changefreq']}</changefreq>",
            f"    <priority>{e['priority']}</priority>",
            "  </url>",
        ]
    lines.append("</urlset>")
    return "\n".join(lines) + "\n"


def main() -> int:
    check_only = "--check" in sys.argv
    entries, skipped = collect()

    if not entries:
        print("ERROR: no pages found — refusing to write an empty sitemap.", file=sys.stderr)
        return 2

    future = [e for e in entries if e["lastmod"] > date.today().isoformat()]
    if future:
        print(f"ERROR: {len(future)} future lastmod — refusing to write.", file=sys.stderr)
        for e in future:
            print(f"  {e['lastmod']}  {e['rel']}", file=sys.stderr)
        return 2

    xml = render(entries)
    current = SITEMAP.read_text(encoding="utf-8") if SITEMAP.exists() else ""

    posts = sum(1 for e in entries if e["rel"].startswith("blog/") and not e["rel"].endswith("index.html"))
    print(f"{len(entries)} urls ({posts} blog posts), {len(skipped)} excluded")
    for rel, reason in skipped:
        print(f"  skip  {rel:<52} {reason}")

    if check_only:
        if xml != current:
            print("\nSTALE: sitemap.xml does not match the tree. Run without --check.")
            return 1
        print("\nOK: sitemap.xml is current.")
        return 0

    if xml == current:
        print("\nNo change.")
        return 0

    SITEMAP.write_text(xml, encoding="utf-8")
    was = current.count("<url>")
    print(f"\nWrote {SITEMAP.relative_to(ROOT)}: {was} -> {len(entries)} urls")
    return 0


if __name__ == "__main__":
    sys.exit(main())
