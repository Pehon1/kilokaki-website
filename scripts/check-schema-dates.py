#!/usr/bin/env python3
"""Audit blog JSON-LD datePublished against each post's first git commit.

Rule (MEMORY.md, 2026-06-05): datePublished == date of the post's FIRST commit.
Target publish dates never go in schema; 13 posts once shipped crawlable with
future datePublished because someone stamped the plan instead of the fact.

Exit 1 if any real bug is found, so this can gate a deploy.

Two traps this script exists to avoid, both hit by hand-audits on 2026-07-17:

  --follow is mandatory. Four posts were renamed by "SEO Sprint P1: 4 URL
  renames with 301 redirects" (8a059b0). Without --follow their first commit
  reads as the rename date and four clean posts look backdated.

  Timezone. git --date=short reports the author's local date (SGT). A generator
  stamping UTC produces an off-by-one for anything committed 00:00-08:00 SGT.
  That is a disagreement between two clocks, not a wrong date. Classified as
  TZ and never counted as a bug.
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

    buckets = {"FWD": [], "BACK": [], "MINOR": [], "TZ": [], "NOSCHEMA": [], "NODATE": []}

    for path in population()[0]:
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
        commit = first_commit(path)
        if commit is None:
            continue
        local = commit.date().isoformat()
        if published == local:
            continue
        utc = (commit - commit.utcoffset()).date().isoformat()
        delta = (datetime.date.fromisoformat(published) - commit.date()).days
        detail = f"schema {published} | commit {local} ({delta:+d}d)"
        if published == utc:
            buckets["TZ"].append((name, detail))
        elif delta > 3:
            buckets["FWD"].append((name, detail))
        elif delta < -3:
            buckets["BACK"].append((name, detail))
        else:
            buckets["MINOR"].append((name, detail))

    labels = [
        ("FWD", "FORWARD-DATED - schema later than first commit. Violates the rule."),
        ("BACK", "BACKDATED >3d"),
        ("MINOR", "MINOR DRIFT <=3d - authored-vs-committed slippage"),
        ("NOSCHEMA", "REAL ARTICLE WITH NO JSON-LD BLOCK"),
        ("NODATE", "HAS SCHEMA, NO datePublished"),
        ("TZ", "TZ-ARTIFACT - schema=UTC, git=SGT. NOT A BUG, no action."),
    ]
    for key, label in labels:
        rows = buckets[key]
        print(f"\n### {label}  ({len(rows)})")
        for name, detail in rows:
            print(f"    {name:<52} {detail}")

    bugs = sum(len(buckets[k]) for k, _ in labels if k != "TZ")
    print(f"\n>>> {bugs} real bugs, {len(buckets['TZ'])} TZ artifacts (ignored)")
    return 1 if bugs else 0


if __name__ == "__main__":
    sys.exit(main())
