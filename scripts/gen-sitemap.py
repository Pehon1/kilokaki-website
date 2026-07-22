#!/usr/bin/env python3
"""Generate sitemap.xml from the files actually on disk.

The previous sitemap was hand-maintained. It froze at lastmod 2026-05-03 and
drifted to 10 of 73 real posts while still advertising 5 redirect stubs.
Nothing here is hardcoded: pages are discovered by walking the tree and
classified by reading their markup, so a new post is picked up by existing.

Exclusion is by page-level signal, not by filename list:
  - meta refresh  -> redirect stub, the target gets indexed instead
  - robots noindex -> we are explicitly asking Google not to index it

lastmod is DERIVED FROM THE PAGE, in this order (see lastmod_for):
    JSON-LD dateModified -> JSON-LD datePublished -> git %as
There is no fourth tier and no carried-forward state: a page that answers none
of the three is an error, not a guess. See lastmod_for() for why mtime is gone.

SOME PAGES ARE NOT PAGES, THEY ARE LISTINGS: blog/index.html and
how-to/index.html take their lastmod from the newest page each one lists, in a
second pass after the walk, overriding the git tier. They declare no dates of
their own and their git history is adoption and comment-only commits, so all
three tiers above answer a question about the repo rather than about what a
returning reader would see. The set is LISTING_INDICES -- a map, so there is one
answer to "which pages are listings" and it has one caller. See
derive_listing_lastmods() for why this cannot be a tier inside lastmod_for, and
LISTING_INDICES for why the homepage is not in it.

Run from anywhere:  python3 scripts/gen-sitemap.py [--check]
  --check   exit 1 if sitemap.xml is stale, write nothing (for CI/cron)
"""

from __future__ import annotations

import re
import subprocess
import sys
from datetime import date
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


class SitemapError(Exception):
    """The sitemap cannot be generated from a source we are willing to stand behind."""


def published_lastmods() -> dict[str, str]:
    """loc -> the lastmod currently published, read back from sitemap.xml.

    REPORTING ONLY. Nothing in the generated output is derived from this; it
    exists so the run can print which urls move and by how much. It was load
    bearing under the sticky design (b13ea2e, superseded) and is deliberately
    demoted rather than deleted, because "what did this change move" is the
    question a reviewer asks and the answer should come from the file, not
    from the render describing itself.

    Demoted to reporting is NOT demoted to optional. The move census is the
    entire basis on which this change was reviewed and unblocked -- 63 moved,
    60 backward -- and a parse that silently yields nothing reports that same
    corpus as "78 new, 0 moved", which is the shape of a first run. The output
    written to disk would be identical either way, so nothing downstream can
    catch it; the only casualty is the reviewer's evidence, and it fails in the
    direction that looks clean. Empty reads as a pass everywhere else in this
    codebase. Here it must not: non-empty file, zero pairs parsed -> refuse.
    """
    if not SITEMAP.exists():
        return {}  # first run: nothing published yet, "0 moved" is the truth
    text = SITEMAP.read_text(encoding="utf-8")
    published: dict[str, str] = {}
    for block in RE_URL_BLOCK.finditer(text):
        loc = RE_LOC.search(block.group(1))
        stamp = RE_LASTMOD.search(block.group(1))
        if loc and stamp:
            published[loc.group(1)] = stamp.group(1)
    if text.strip() and not published:
        raise SitemapError(
            f"{SITEMAP.name} is {len(text)} bytes but no <loc>/<lastmod> pair parsed. "
            "Refusing to run: the move census would report every url as new, which "
            "is indistinguishable from a first run and is how this change gets "
            "reviewed on evidence that silently does not exist."
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
RE_DATE_PUBLISHED = re.compile(r'"datePublished"\s*:\s*"(\d{4}-\d{2}-\d{2})')


def declared_published(path: Path) -> str | None:
    """The page's own JSON-LD datePublished.

    Second tier, above git. A page carrying a datePublished and no dateModified
    is claiming it was published and never edited, and that claim answers "when
    did this page last change" more honestly than git does -- git answers "when
    did this file last move in history", which a rename or an adoption changes
    without touching a byte the reader sees.

    This tier is gated by check-schema-dates.py, which enforces
    datePublished == first commit across the corpus. So it is not a second
    opinion about the same number; it is a claim the page makes about itself
    that we already verify separately.

    ATTRIBUTION, corrected 2026-07-22: an earlier revision of this docstring
    credited the tier to "Coco's amendment". She never made that amendment --
    she is the one who caught the citation. The reasoning above is mine and is
    load bearing on nothing but itself, which is the point of saying so: a
    borrowed name is a shortcut past the argument, and it works best exactly
    where the argument is weakest. Judge the tier on the paragraph, not the
    signature.

    NOT EXERCISED BY THE CORPUS: as of 2026-07-22 this tier fires 0 times
    (78 dateModified, 0 datePublished, 16 git), and structurally so -- no page
    here carries datePublished without dateModified. It is covered by
    test-gen-sitemap.py instead, because a branch the corpus cannot reach is a
    branch no production run can prove correct.
    """
    try:
        head = path.read_text(encoding="utf-8", errors="replace")[:8000]
    except OSError:
        return None
    match = RE_DATE_PUBLISHED.search(head)
    return match.group(1) if match else None


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


def lastmod_for(path: Path) -> tuple[str, str]:
    """(date, which tier produced it). dateModified -> datePublished -> git %as.

    Returning the tier is not decoration. Three tiers that all yield a plausible
    date are three ways to be wrong that look identical in the output, and the
    tier is the only thing that distinguishes "the page told us" from "we asked
    git because the page was silent". The run prints the per-tier census so a
    reviewer can see the git surface instead of inferring it.

    There is no mtime tier any more. The old one contradicted the function
    directly above it: git_lastmod's own docstring rejects mtime because rsync
    and chmod perturb it, and then the fallback reached for mtime anyway. A
    date we have already written down as untrustworthy is worse than no date,
    because no date is loud and a wrong date is not. Tier 4 is an error.
    """
    stamp = declared_lastmod(path)
    if stamp:
        return stamp, "dateModified"
    stamp = declared_published(path)
    if stamp:
        return stamp, "datePublished"
    stamp = git_lastmod(path)
    if stamp:
        return stamp, "git"
    raise SitemapError(
        f"{path.relative_to(ROOT)}: no dateModified, no datePublished, and no git "
        "history. Refusing to invent a lastmod. Commit the page, or give it schema."
    )


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


# Listing pages, each mapped to the prefix whose pages it carries.
#
# A MAP, NOT A CONSTANT, and that shape change is half of this commit. It was
# LISTING_INDEX = "blog/index.html": one string, one caller, correct. A
# singleton is the shape that gets copy-pasted into a second block the day a
# second page needs the same treatment, and then the two blocks disagree about
# which pages are listings -- that is the deploy.sh / ledger_approve.sh
# two-copies bug, already shipped once in this repo. Generalised here while
# there is still exactly one caller, which is the only cheap moment to do it.
#
# WHICH PAGES BELONG HERE is a property of the page, not a preference: DERIVE
# where the page's content IS a list of dated things, DECLARE where there is
# nothing to derive from (Coco, ruling 2026-07-22).
#
#   blog/index.html  -- its bytes are the post list.
#   how-to/index.html -- its bytes are the 13 how-to articles. Its git tier is
#       only ACCIDENTALLY right today, because shipping an article edits the
#       listing in the same commit. 1678682 broke that accident by touching the
#       file with a schema-only commit and stamping it 2026-07-22; a convention
#       holds until someone commits without knowing about it. Derivation is
#       right by construction instead.
#
# index.html (the homepage) is deliberately ABSENT and must not be added. It
# lists nothing, so there is no operand to max over; it declares its date, which
# is the honest tier for a page with no derivable fact behind it. Adding it here
# would silently kill that declaration -- the second pass overrides
# unconditionally -- which is the collision this map exists to prevent.
LISTING_INDICES = {
    "blog/index.html": "blog/",
    "how-to/index.html": "how-to/",
}


def lists_under(rel: str, prefix: str) -> bool:
    """The operand set for one listing: the pages at `prefix` that it LISTS.

    Spelled out as a named predicate instead of inlined into the max(), because
    the operand is the entire defect. An earlier reading of this ticket had the
    fix as "max over the pages collected so far", which is a different set in
    two ways at once, and both of them let a poisoned date answer first:

      - it contains the ROOT HOMEPAGE. included[0] is index.html, git tier,
        2026-07-22 off 0edc2b4 "homepage: add self-referencing canonical" -- a
        head-tag-only commit, i.e. the exact poisoning this function exists to
        remove -- and it sits ahead of every other entry. Excluded here by the
        prefix.
      - it contains the listing page itself, whose git date is the thing being
        replaced.

    The self-exclusion is `not in LISTING_INDICES`, not `!= listing`, and the
    difference is deliberate: NO listing's date may be an operand for ANY other
    listing. Under today's two disjoint prefixes those two spellings cannot
    disagree, so this is prevention rather than a fix -- a nested listing
    (blog/series/index.html) would otherwise feed its derived date upward and
    the outer listing would report a date derived from a date.

    It also excludes the other section's pages, which this listing does not
    carry. Deriving a listing's date from pages it does not list is the same
    class of error as deriving it from git: a fact about the repo wearing a
    claim about the page.

    LIMIT, stated because the map now invites additions: membership is by path
    PREFIX, so a page under `prefix` that the listing does not actually link is
    still an operand. That holds today (every blog/*.html and how-to/*.html is
    linked or skipped as a redirect stub) and it is not asserted anywhere. A
    listing that carries a curated subset of its directory needs a real link
    parse, not another map entry.
    """
    return rel.startswith(prefix) and rel not in LISTING_INDICES


def derive_listing_lastmods(included: list[dict]) -> dict[str, tuple[str, str]]:
    """listing rel -> (new lastmod, superseded tier), for every listing that has one.

    A listing page declares neither dateModified nor datePublished, so
    lastmod_for falls to git %as -- and git answers "when did this file last
    move in history", which for these pages means adoption commits and
    comment-only commits. 1678682 is the load-bearing example, and it hit both:
    26 insertions into blog/index.html, all of them an HTML comment, and a
    schema block into how-to/index.html, together stamping 2026-07-22 on two
    pages whose reader-visible bytes did not move.

    The honest answer is the newest page the listing carries, which is what a
    reader coming back to it would see as new.

    WHY THIS IS POST-LOOP AND NOT A TIER INSIDE lastmod_for. The max is over a
    list collect() has not finished building. Every call site inside that loop
    holds a partial `included`, and it is partial in a way with no signature in
    the output: the date is resolved and then appended, so the current path is
    absent from its own prefix by construction, and the entries missing from a
    listing's prefix are the alphabetically-later pages, not the older ones. An
    inline edit reads correct, ships green, and silently maxes over a fraction
    of the corpus. There is no cheap tier here; there is a second pass.

    A listing with no operands is OMITTED from the result rather than raising:
    with nothing to list, the git date is the only date there is, and it stays
    on the git tier where the census will show it. Same for a listing that is
    not in the corpus at all -- how-to/ can be deleted or noindexed without
    this function inventing an entry for it.

    Every derivation is computed here and applied by the caller afterwards, not
    interleaved. No listing is an operand for another (see lists_under), so
    ordering cannot matter today; keeping compute and apply separate is what
    keeps that true if a nested listing ever appears.
    """
    derived: dict[str, tuple[str, str]] = {}
    for listing, prefix in LISTING_INDICES.items():
        entry = next((e for e in included if e["rel"] == listing), None)
        if entry is None:
            continue
        stamps = [e["lastmod"] for e in included if lists_under(e["rel"], prefix)]
        if not stamps:
            continue
        derived[listing] = (max(stamps), entry["tier"])
    return derived


def collect(published: dict[str, str]) -> tuple[list[dict], list[tuple[str, str]]]:
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
            stamp, tier = lastmod_for(path)
            included.append({
                "loc": loc,
                "lastmod": stamp,
                "tier": tier,
                "was": published.get(loc),  # reporting only; never an input
                "changefreq": changefreq,
                "priority": priority,
                "rel": rel,
            })
    # SECOND PASS. Only now is `included` complete enough to max over.
    derived = derive_listing_lastmods(included)
    for e in included:
        if e["rel"] in derived:
            stamp, superseded = derived[e["rel"]]
            e["superseded"] = (e["lastmod"], superseded)
            e["lastmod"] = stamp
            e["tier"] = "newest-post"

    # Homepage first, then the listing indexes, then posts newest-first.
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


def main() -> int:
    check_only = "--check" in sys.argv
    unknown = [a for a in sys.argv[1:] if a != "--check"]
    if unknown:
        print(f"ERROR: unknown argument(s): {' '.join(unknown)}", file=sys.stderr)
        print("       --recompute is gone; it existed only to escape stickiness.", file=sys.stderr)
        return 2
    try:
        published = published_lastmods()
        entries, skipped = collect(published)
    except SitemapError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

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

    census = {t: sum(1 for e in entries if e["tier"] == t)
              for t in ("dateModified", "datePublished", "git", "newest-post")}
    print("\nlastmod source: " + ", ".join(f"{n} {t}" for t, n in census.items()))
    for e in entries:
        if e["tier"] == "git":
            print(f"  git   {e['lastmod']}  {e['rel']:<48} (page declares neither date)")
    # Print what the derivation REPLACED, not just what it produced. "derived
    # 2026-07-21" alone is consistent with the derivation never running and git
    # having said 07-21 anyway -- the masking case this ticket opened on, where
    # a real adoption and a comment-only commit landed the same day and the two
    # tiers agreed by coincidence. The superseded value is what makes the run
    # able to report that it did something.
    for e in entries:
        if e.get("superseded"):
            old, old_tier = e["superseded"]
            print(f"  derive {old} ({old_tier}) -> {e['lastmod']}  {e['rel']:<43} (newest listed post)")

    moved = [e for e in entries if e["was"] and e["was"] != e["lastmod"]]
    added = [e for e in entries if not e["was"]]
    back = sum(1 for e in moved if e["lastmod"] < e["was"])
    print(f"\nvs published sitemap.xml: {len(moved)} moved ({back} backwards, "
          f"{len(moved) - back} forwards), {len(added)} new")
    for e in moved:
        print(f"  move  {e['was']} -> {e['lastmod']}  {e['rel']:<48} ({e['tier']})")
    for e in added:
        print(f"  new   {e['lastmod']}  {e['rel']:<48} ({e['tier']})")

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
