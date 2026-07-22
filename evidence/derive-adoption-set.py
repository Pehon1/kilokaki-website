#!/usr/bin/env python3
"""Re-derive the FULL adoption set: every page in the capture vs its first commit.

Source of the capture: state/live-by/first-serve-by-page.json in Nori's workspace,
banked in-repo as evidence/first-200-utc.json. NOT `live_by.json` — that path does
not exist and never did; `live_by` is a field inside the capture, not a file.

Answers one question for the whole 101-page corpus, not one entry:
    for how many pages is  first_200_utc < first_commit_utc ?
i.e. prod served the file before the commit that introduced it existed.
A file that does not exist cannot be served, so such a git date is FALSIFIED.

WHY A THREE-WAY VERDICT AND NOT A BOOLEAN
-----------------------------------------
The access log has a retention floor (`_retention_floor_utc`). A page whose
first commit predates that floor CANNOT be judged: its true first serve is
older than anything we can see, so `first_200_utc > commit_utc` is what the
instrument emits whether the page was adopted or not. Scoring those CLEAN is
the exact shape that hid durian - a rule that cannot go red on the population
it is applied to. They get their own bucket, UNDECIDABLE, and they are not in
the denominator of "clean".

The retention floor can only push first_200 LATER, never earlier, so it can
never MINT a falsification. FALSIFIED is therefore a hard lower bound on the
true adoption count; CLEAN is only meaningful inside the log window.

Emits its own counts. Nothing here is hand-transcribed into a report.
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
# Banked in-repo on purpose: the workspace original is mode 0600 and its source log
# rotates out ~15 Aug 2026. Read the banked copy so this stays runnable afterwards.
LIVE_BY = os.path.join(HERE, "first-200-utc.json")
OUR_EGRESS = "103.11.50.23"


def iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def git(*args):
    return subprocess.run(
        ["git", "-C", REPO, *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def first_commit(path):
    """First commit that introduced `path`, following renames. None if unknown."""
    out = git("log", "--follow", "--diff-filter=A", "--format=%H %cI", "--", path)
    if not out:
        return None
    sha, when = out.splitlines()[-1].split(" ", 1)
    return sha, iso(when)


DECLARES_ADOPTION = re.compile(r"\b(adopt|adopts|adopted|adoption|rescue|restore)\b", re.I)


def git_declared_adoptions():
    """Files added by a commit whose OWN MESSAGE declares an adoption.

    Second operand, and it is genuinely independent of the access log: written by
    the adopter at adoption time, in a different file, on a different occasion.
    Over-broad on purpose - a normal post commit that happens to say "restore"
    lands here and raises a DISAGREEMENT. A false alarm is cheap; the failure this
    exists to catch (an adoption nobody declared anywhere) is not.
    """
    out = git("log", "--format=%H%x00%B%x01", "--all")
    declared = {}
    for entry in out.split("\x01"):
        if "\x00" not in entry:
            continue
        sha, body = entry.strip().split("\x00", 1)
        if not DECLARES_ADOPTION.search(body):
            continue
        added = git("show", "--diff-filter=A", "--name-only", "--format=", sha)
        for path in added.splitlines():
            if path.strip().endswith(".html"):
                declared[path.strip()] = (sha[:7], body.splitlines()[0])
    return declared


def cross_check(buckets, floor):
    """Do the two instruments name the same set? Each mismatch gets its OWN word."""
    logged = {r[0].lstrip("/") for r in buckets.get("FALSIFIED", [])}
    declared = git_declared_adoptions()

    print("=== CROSS-CHECK: access log vs the adopting commits' own messages ===")
    print(f"falsified by access log      : {len(logged)}")
    print(f"declared by a commit message : {len(declared)}")

    undeclared = sorted(logged - set(declared))
    unlogged = sorted(set(declared) - logged)

    rc = 0
    if undeclared:
        # The dangerous direction: prod served it before its commit, and no commit
        # message ever said so. Nothing but this script would ever surface it.
        print("SILENT_ADOPTION - falsified by the log, declared by nobody:")
        for p in undeclared:
            print(f"    {p}")
        rc = 1
    if unlogged:
        # Expected whenever an adoption predates the log window - the log CANNOT
        # see it, so this is a coverage limit, not a contradiction. Named
        # separately from SILENT_ADOPTION: same exit code would be the opposite
        # diagnosis.
        print("UNSEEN_BY_LOG - declared as an adoption, not falsifiable from the log:")
        for p in unlogged:
            sha, subj = declared[p]
            print(f"    {p}  {sha} {subj[:60]}")
        print(f"    (expected if the adoption predates the retention floor {floor.date()})")
    if not undeclared and not unlogged:
        print("AGREE - both instruments name the same set.")
    print()
    return rc


def main():
    doc = json.load(open(LIVE_BY))
    floor = iso(doc["_retention_floor_utc"])
    pages = doc["pages"]

    rows = []
    for url, rec in sorted(pages.items()):
        rel = url.lstrip("/")
        served = iso(rec["first_200_utc"])
        fc = first_commit(rel)
        if fc is None:
            rows.append((url, None, None, served, None, "NO_COMMIT"))
            continue
        sha, committed = fc
        gap = (committed - served).total_seconds()
        if served < committed:
            verdict = "FALSIFIED"
        elif committed < floor:
            verdict = "UNDECIDABLE"
        else:
            verdict = "CLEAN"
        rows.append((url, sha, committed, served, gap, verdict))

    buckets = {}
    for r in rows:
        buckets.setdefault(r[5], []).append(r)

    print(f"corpus            : {LIVE_BY}")
    print(f"pages in corpus   : {len(pages)}")
    print(f"retention floor   : {floor.isoformat()}")
    print(f"rows evaluated    : {len(rows)}")
    print()
    for name in ("FALSIFIED", "UNDECIDABLE", "NO_COMMIT", "CLEAN"):
        print(f"{name:<12} {len(buckets.get(name, []))}")
    print()

    # `rows` is built by iterating `pages` with no skip path, so `len(rows) !=
    # len(pages)` cannot differ: both operands resolve from the same source. That
    # is a mirror, not a check, and it was in the first draft of this script.
    # The real second operand is below: nginx wrote the serve times, a human wrote
    # the commit messages, on different occasions. Those two CAN disagree.
    rc = cross_check(buckets, floor)

    print("=== FALSIFIED (served before the commit that introduced it) ===")
    for url, sha, committed, served, gap, _ in sorted(
        buckets.get("FALSIFIED", []), key=lambda r: r[3]
    ):
        print(f"{url}")
        print(f"    first_200_utc  {served.isoformat()}")
        print(f"    first_commit   {sha[:7]}  {committed.isoformat()}")
        print(f"    commit later by {int(gap)}s")
    print()

    print("=== UNDECIDABLE (first commit predates the log window) ===")
    for url, sha, committed, served, gap, _ in sorted(
        buckets.get("UNDECIDABLE", []), key=lambda r: r[2]
    ):
        print(f"{url}  {sha[:7]} {committed.date()}  (first seen {served.date()})")
    print()

    if buckets.get("NO_COMMIT"):
        print("=== NO_COMMIT (in the log, not in git history at this HEAD) ===")
        for url, *_ in buckets["NO_COMMIT"]:
            print(f"{url}")
        print()

    return rc


if __name__ == "__main__":
    sys.exit(main())
