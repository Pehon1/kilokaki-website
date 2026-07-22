#!/usr/bin/env python3
"""Audit blog JSON-LD datePublished against each post's first git commit.

Rule (MEMORY.md, 2026-06-05): datePublished == date of the post's FIRST commit.
Target publish dates never go in schema; 13 posts once shipped crawlable with
future datePublished because someone stamped the plan instead of the fact.

Traps this script exists to avoid:

  --follow is mandatory. Four posts were renamed by "SEO Sprint P1: 4 URL
  renames with 301 redirects" (8a059b0). Without --follow their first commit
  reads as the rename date and four clean posts look backdated.

  Adoption. For a post published on production and copied into git afterwards,
  the first commit is the date SOMEBODY RAN `git add`. blog/adopted.json declares
  those posts and the date they actually went live; this script reads its
  comparand from there for them, and from git for everything else.

DELETED 2026-07-22 — the TZ bucket, and why its removal is the whole point:

  It classified `schema == commit-date-in-UTC` as "two clocks disagreeing, not a
  wrong date" and exonerated it. That test cannot tell a clock offset from an
  ADOPTION LAG. Both produce the identical -1d shape, and which one you get is
  decided by nothing but the wall-clock HOUR of the commit: an adoption at
  00:03 SGT has a UTC date one day earlier, matches the schema, and walks; the
  same adoption at 11:08 SGT does not, and gets reported as drift. Four posts,
  one mechanism, three exonerated and one flagged, on a coin flip.

  So the bucket was worse than wrong — it was right often enough to keep. Three
  genuine instrument failures were closed as "NOT A BUG, no action" from
  2026-07-17, and fix-schema-dates.py honoured the same verdict, which made it a
  writer that spared three true dates by accident and stood ready to overwrite
  the fourth.

  The replacement does not try to discriminate better. It refuses to exonerate
  anything it cannot distinguish: an adoption must be DECLARED by the human who
  performed it, in a second file, or its date is a finding. The cost is real and
  intended — a genuinely UTC-stamped post now needs a declaration instead of a
  free pass. Measured at deletion: the old TZ bucket held 3 posts and all 3 were
  adoptions, so nothing legitimate loses its exemption today.

Exit 1 if any real bug is found, so this can gate a deploy. NOTE, unchanged and
still true: nothing invokes this script. `grep -rn check-schema-dates *.sh` is
empty; gen-sitemap.py:128 cites it as live protection and that citation is a
phantom. Wiring it in is a separate ask, and it is Coco's.
"""
import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys

STUB_BYTES = 2000  # redirect stubs are ~500B and carry no schema by design
ADOPTED = "blog/adopted.json"


def load_adopted():
    """Declared publish dates for posts that were LIVE ON PROD before git saw them.

    THE definition of "which posts is git the wrong instrument for" — single
    source, same rule as population(): import this, never restate it. The
    duplicated TZ test that used to live in fix-schema-dates.py is exactly what
    this exists to prevent.

    Three return values, deliberately distinguishable:
      None  — the file is ABSENT. Not "no adoptions"; UNKNOWN. Callers that can
              damage content (fix-schema-dates.py) must fail closed on this.
      {}    — the file is PRESENT and declares nothing. A real, readable state.
      dict  — repo-relative path -> declaration.

    Malformed JSON raises rather than degrading to {}. A declaration file that
    cannot be parsed must never read as "nothing to spare" — that is the exact
    shape that would silently re-arm the writer against the adopted set.
    """
    if not os.path.exists(ADOPTED):
        return None
    with open(ADOPTED, encoding="utf-8") as fh:
        return json.load(fh).get("adopted", {})


def population():
    """THE definition of 'a blog post'. Single source — import this, never re-derive.

    Run with --count to make the corpus emit its own number.

    This exists because the count kept floating. 53/55/56 were recited, never
    counted. 54 came from counting index.html, which the spec excluded. 67/85
    came from counting the redirect stubs, twice over — a loose pattern AND the
    wrong population. The real number is 59/77 and nobody should hand-count it
    again.

    The 8 stubs are the corpus's own 103.11.50.23: ours, inert, no reader, and
    they have walked into three separate counts and inflated all three. A count
    is only meaningful once the population is a rule instead of a habit.
    """
    real, stubs, index = [], [], []
    for path in sorted(glob.glob("blog/*.html")):
        name = os.path.basename(path)
        if name == "index.html":
            index.append(name)
        elif os.path.getsize(path) < STUB_BYTES:
            stubs.append(name)
        else:
            real.append(path)
    return real, stubs, index


def print_count():
    real, stubs, index = population()
    print(f"\n{len(real):>4}  real posts        (>= {STUB_BYTES}B, excludes index.html)  <-- THE NUMBER")
    print(f"{len(stubs):>4}  redirect stubs    (< {STUB_BYTES}B) — EXCLUDED, no reader")
    print(f"{len(index):>4}  index.html        — EXCLUDED")
    print(f"{len(real) + len(stubs) + len(index):>4}  total blog/*.html")
    print(f"\nstubs (the three-time count inflators):")
    for s in stubs:
        print(f"      {s}")
    return 0


def first_commit(path):
    out = subprocess.run(
        ["git", "log", "--diff-filter=A", "--follow", "--format=%ad", "--date=iso", "--", path],
        capture_output=True, text=True,
    ).stdout.strip()
    if not out:
        return None
    date, time, off = out.split("\n")[-1].split()
    return datetime.datetime.fromisoformat(f"{date}T{time}{off[:3]}:{off[3:]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", action="store_true",
                    help="print the population and exit; the number of record")
    args = ap.parse_args()

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir)
    os.chdir(root)
    if args.count:
        return print_count()

    buckets = {"FWD": [], "BACK": [], "MINOR": [], "ADOPTED_DRIFT": [],
               "NOSCHEMA": [], "NODATE": [], "ORPHAN": []}

    real = population()[0]
    adopted = load_adopted()
    if adopted is None:
        adopted = {}
        adopted_state = f"{ADOPTED} ABSENT — 0 declarations, every post judged against git"
    else:
        adopted_state = f"{ADOPTED}: {len(adopted)} declaration(s)"
        # An entry naming a path that is not in the population is a POPULATION
        # MISMATCH, not a date bug — opposite diagnosis, so it gets its own word
        # and its own bucket even though it shares the exit code. A declaration
        # that matches nothing is how a file quietly stops covering what it names.
        for decl in sorted(adopted):
            if decl not in real:
                buckets["ORPHAN"].append(
                    (decl, "declared adopted, matches no post in the population"))

    by_declaration = by_git = no_commit = 0

    for path in real:
        name = os.path.basename(path)
        html = open(path, encoding="utf-8").read()
        block = re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S)
        if not block:
            buckets["NOSCHEMA"].append((name, ""))
            continue
        try:
            published = json.loads(block.group(1)).get("datePublished")
        except json.JSONDecodeError as exc:
            buckets["NOSCHEMA"].append((name, f"INVALID JSON: {exc}"))
            continue
        if not published:
            buckets["NODATE"].append((name, ""))
            continue

        # Adopted posts are judged against the declaration, never against git.
        # The hour of the adopting commit is not consulted, which is the entire
        # fix: the verdict must be identical whether the copy ran at 00:03 or
        # 11:08.
        if path in adopted:
            by_declaration += 1
            expected = adopted[path]["datePublished"]
            if published != expected:
                buckets["ADOPTED_DRIFT"].append(
                    (name, f"schema {published} | declared {expected} "
                           f"(adopted @ {adopted[path]['adopting_commit']})"))
            continue

        commit = first_commit(path)
        if commit is None:
            no_commit += 1
            continue
        by_git += 1
        local = commit.date().isoformat()
        if published == local:
            continue
        delta = (datetime.date.fromisoformat(published) - commit.date()).days
        detail = f"schema {published} | commit {local} ({delta:+d}d)"
        if delta > 3:
            buckets["FWD"].append((name, detail))
        elif delta < -3:
            buckets["BACK"].append((name, detail))
        else:
            buckets["MINOR"].append((name, detail))

    labels = [
        ("FWD", "FORWARD-DATED - schema later than first commit. Violates the rule."),
        ("BACK", "BACKDATED >3d"),
        ("MINOR", "MINOR DRIFT <=3d - authored-vs-committed slippage"),
        ("ADOPTED_DRIFT", "ADOPTED POST DISAGREES WITH ITS DECLARATION"),
        ("NOSCHEMA", "REAL ARTICLE WITH NO JSON-LD BLOCK"),
        ("NODATE", "HAS SCHEMA, NO datePublished"),
        ("ORPHAN", "DECLARED-BUT-ABSENT - blog/adopted.json names a post that isn't there"),
    ]
    for key, label in labels:
        rows = buckets[key]
        print(f"\n### {label}  ({len(rows)})")
        for name, detail in rows:
            print(f"    {name:<52} {detail}")

    # Coverage, emitted every run and derived, never typed. A checker that is
    # green on everything and silent about how much it looked at is
    # indistinguishable from a no-op. These must add up to the population.
    judged = by_declaration + by_git
    accounted = judged + no_commit + len(buckets["NOSCHEMA"]) + len(buckets["NODATE"])
    print(f"\n--- coverage ---")
    print(f"    {adopted_state}")
    print(f"    {by_declaration:>4}  judged against {ADOPTED}")
    print(f"    {by_git:>4}  judged against git first-commit")
    print(f"    {no_commit:>4}  UNJUDGED - in the population, no first commit found")
    print(f"    {len(buckets['NOSCHEMA']):>4}  UNJUDGED - no JSON-LD block")
    print(f"    {len(buckets['NODATE']):>4}  UNJUDGED - no datePublished")
    print(f"    {accounted:>4}  accounted for / {len(real)} real posts"
          f"{'' if accounted == len(real) else '   <-- DOES NOT ADD UP'}")

    bugs = sum(len(buckets[k]) for k, _ in labels)
    if accounted != len(real):
        print(f"\n>>> ARITHMETIC: {accounted} accounted for but the population is "
              f"{len(real)}. The verdict below is over an unknown subset.")
        return 1
    print(f"\n>>> {bugs} real bugs over {judged} judged posts")
    return 1 if bugs else 0


if __name__ == "__main__":
    sys.exit(main())
