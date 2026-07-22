#!/usr/bin/env python3
"""Generate sitemap.xml from the files actually on disk.

The previous sitemap was hand-maintained. It froze at lastmod 2026-05-03 and
drifted to 10 of 73 real posts while still advertising 5 redirect stubs.
Nothing here is hardcoded: pages are discovered by walking the tree and
classified by reading their markup, so a new post is picked up by existing.

Exclusion is by page-level signal, not by filename list:
  - meta refresh  -> redirect stub, the target gets indexed instead
  - robots noindex -> we are explicitly asking Google not to index it

lastmod is STICKY: a url already in sitemap.xml keeps its published date
verbatim, and only genuinely new urls get a computed one. See published_lastmods().

Run from anywhere:  python3 scripts/gen-sitemap.py [--check]
  --check            exit 1 if sitemap.xml is stale, write nothing (for CI/cron)
  --recompute <rel>  drop stickiness for one page (repeatable), e.g.
                     --recompute blog/the-kopi-problem.html
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

RE_URL_BLOCK = re.compile(r"<url>(.*?)</url>", re.S)
RE_LOC = re.compile(r"<loc>\s*([^<\s]+)\s*</loc>")
RE_LASTMOD = re.compile(r"<lastmod>\s*(\d{4}-\d{2}-\d{2})\s*</lastmod>")


class StickyError(Exception):
    """The published sitemap exists but could not be read as a source of dates."""


def published_lastmods() -> dict[str, str]:
    """loc -> the lastmod we have already published, read back from sitemap.xml.

    lastmod is a claim about the PAGE, not about the file. Every date this
    script can compute is derived from git, and git history moves for reasons
    the page does not: a JSON-LD edit, a rename, a whitespace pass, a rebase.
    On 2026-07-22 a one-url regen moved 75 lastmods, all forward, for prose
    nobody had touched -- a 75-url freshness announcement we cannot support,
    days before a Search Console read that has to stay interpretable.

    So dates are sticky. A url already in the sitemap keeps its published date
    byte-for-byte; only a url we have never published gets a computed date.
    Ruling: Coco, 2026-07-22.

    KNOWN BLIND SPOT, stated here so it is not discovered later: this also goes
    sticky on genuine content edits. The real fix is a content-hash baseline --
    bump when the rendered page changes, not when git history moves -- and it is
    queued as a follow-up. Until it lands, --recompute is the only escape hatch,
    and it is deliberately per-page: there is no flag that re-dates everything,
    because "re-date everything" is the exact operation this function exists to
    prevent from happening by accident.
    """
    if not SITEMAP.exists():
        return {}  # first run: nothing has been published, everything is new
    text = SITEMAP.read_text(encoding="utf-8")
    published: dict[str, str] = {}
    for block in RE_URL_BLOCK.finditer(text):
        loc = RE_LOC.search(block.group(1))
        stamp = RE_LASTMOD.search(block.group(1))
        if loc and stamp:
            published[loc.group(1)] = stamp.group(1)
    # A parse that yields nothing is NOT "no prior state" -- it is indistinguishable
    # from it, and it degrades silently into exactly the mass re-dating above.
    # Empty reads as a pass everywhere else in this codebase; here it must not.
    if text.strip() and not published:
        raise StickyError(
            f"{SITEMAP.name} is {len(text)} bytes but no <loc>/<lastmod> pair parsed. "
            "Refusing to run: with no published dates to carry, every url would be "
            "re-dated from git and that is the failure this guard exists to stop."
        )
    return published


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


RE_DATE_MODIFIED = re.compile(r'"dateModified"\s*:\s*"(\d{4}-\d{2}-\d{2})')


def declared_lastmod(path: Path) -> str | None:
    """The page's own JSON-LD dateModified, which is a claim about the PAGE.

    Preferred over any git date, because git answers a different question: when
    did this file enter or move in history. The two come apart the moment a page
    is authored outside the repo -- how-to-log-kopi-and-teh.html was live on
    2026-07-21 and adopted into git on 07-22, so %as reads 07-22 for a page that
    has not changed since the 21st. Same family as %cs-vs-%as, one layer up
    again: %as survives a rebase, it does not survive an adoption.

    Sourcing from the page also makes lastmod and the page's own dateModified
    agree by construction. Measured 2026-07-22, before this change: 77 of 77
    urls disagreed, every one of them with the sitemap claiming the newer date.
    A lastmod Google can catch lying is a lastmod Google discounts.
    """
    try:
        head = path.read_text(encoding="utf-8", errors="replace")[:8000]
    except OSError:
        return None
    match = RE_DATE_MODIFIED.search(head)
    return match.group(1) if match else None


def lastmod_for(path: Path) -> str:
    stamp = declared_lastmod(path) or git_lastmod(path)
    if stamp:
        return stamp
    # No schema, uncommitted, or outside git: fall back to mtime rather than
    # invent a date.
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


def collect(published: dict[str, str], recompute: set[str]) -> tuple[list[dict], list[tuple[str, str]]]:
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
            loc = url_for(path)
            carried = None if rel in recompute else published.get(loc)
            included.append({
                "loc": loc,
                "lastmod": carried or lastmod_for(path),
                "changefreq": changefreq,
                "priority": priority,
                "rel": rel,
                "carried": carried is not None,
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


def block_diff(old_xml: str, new_xml: str) -> tuple[int, int]:
    """(url blocks carried over byte-identically, url blocks changed or added)."""
    old_blocks = set(RE_URL_BLOCK.findall(old_xml))
    new_blocks = RE_URL_BLOCK.findall(new_xml)
    same = sum(1 for b in new_blocks if b in old_blocks)
    return same, len(new_blocks) - same


def parse_recompute(argv: list[str]) -> set[str]:
    """--recompute <rel> [--recompute <rel> ...]. Unknown paths are an error:
    a typo that silently recomputes nothing looks identical to a clean run."""
    out, i = set(), 0
    while i < len(argv):
        if argv[i] == "--recompute":
            if i + 1 >= len(argv):
                raise StickyError("--recompute needs a repo-relative path")
            rel = argv[i + 1].lstrip("./")
            if not (ROOT / rel).is_file():
                raise StickyError(f"--recompute {rel}: no such file under {ROOT}")
            out.add(rel)
            i += 2
            continue
        i += 1
    return out


def main() -> int:
    check_only = "--check" in sys.argv
    try:
        recompute = parse_recompute(sys.argv[1:])
        published = published_lastmods()
    except StickyError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    entries, skipped = collect(published, recompute)

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

    fresh = [e for e in entries if not e["carried"]]
    print(f"\nlastmod: {len(entries) - len(fresh)} carried from sitemap.xml, {len(fresh)} computed")
    for e in fresh:
        why = "recompute" if e["rel"] in recompute else "new url"
        print(f"  write {e['lastmod']}  {e['rel']:<48} ({why})")

    # Receipt for the commit body, emitted by the artifact instead of hand-counted.
    # Operands come from two different sources -- the file on disk and this render --
    # so they are able to disagree.
    same, moved = block_diff(current, xml)
    print(f"url blocks: {same} byte-identical, {moved} changed or new")

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
