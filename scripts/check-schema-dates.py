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

ADDED 2026-07-22 — the INTERVAL ARM, and the row the date arm cannot emit:

  The rule above compares two CALENDAR DATES and `continue`s on equality. That
  yields three outcomes from a two-outcome design: flagged, waved, and INVISIBLE.

      blog/how-to-log-durian.html
          first 200   2026-07-16T14:32:05Z
          commit      2026-07-16T14:55:39Z    served 1414s BEFORE its own commit

  Both instants land on 2026-07-16, so the row `continue`s out of existence — not
  flagged, not waved, absent, leaving no trace that anything went unexamined. The
  report reads `0 real bugs` with a live undeclared adoption inside it. Day
  granularity IS the defect: a 14m gap reads -1d if it straddles midnight and 0d
  if it does not, which is the same coin flip the TZ bucket was deleted for.

  So the second arm never compares dates. It compares INSTANTS in UTC seconds,
  and it asks one question the date arm structurally cannot: was this page being
  served before the commit that introduced it existed? You cannot serve a file
  that does not exist, so a positive answer is an adoption — proven, not
  inferred. An adoption that blog/adopted.json does not declare is the finding.
  This is the automated form of the discipline adopted.json's own README asks
  for in prose ("an adoption with no entry here is a post whose datePublished
  nothing can verify") and of the `evidence.first_serve_utc` field, which was
  present in every entry and read by no code.

  ABSENCE IS NEVER A VIOLATION. The artifact says so itself: origin sits behind
  Cloudflare, a page can be served entirely from cache, and no row proves
  nothing. The arm fires only on positive evidence. What it will not do is go
  quiet: when the evidence floor rises past a post's commit the arm has zero
  pre-commit coverage for it, and it reports that post as DARK, by name, with
  the floor that blinded it. A dark arm that states why is a finding. One that
  silently skips is a green report with a hole in it — the exact defect above.

EXIT CODES — three meanings, and the numbering is not a preference:

    0   clean
    1   violation found (date arm or interval arm)
    2   INSTRUMENT REFUSES — the run could not be trusted, no verdict implied

  2 was already taken, by fix-schema-dates.py:135,140 and asserted by row H of
  scripts/test-schema-dates-adoption.sh ("--apply with adopted.json ABSENT ->
  refuses, exit 2"). Numbering a violation 2 here would have made a refusal and
  a finding indistinguishable across the toolchain while row H kept passing on
  its own marker — a fails-open collision, not a style clash. The three-way split
  is unchanged; only the integers are Nori's.

  Precedence: any refusal outranks any violation. A refusing instrument means
  the clean part of the report is over an unknown subset, so it is the more
  urgent thing to fix. Both are printed regardless of which one owns the code.

  KNOWN INCONSISTENCY, left alone deliberately: the `accounted != len(real)`
  branch below is a genuine instrument failure ("the verdict below is over an
  unknown subset") and still returns 1. Renumbering it to 2 is correct and is
  NOT done here — it is pre-existing behaviour in another agent's arm and no
  test pins it, so it belongs in its own change with its own review.

Exit 1 if any real bug is found, so this can gate a deploy. NOTE, unchanged and
still true: nothing invokes this script. `grep -rn check-schema-dates *.sh` is
empty; gen-sitemap.py:128 cites it as live protection and that citation is a
phantom. Wiring it in is a separate ask, and it is Coco's. The one caller that
DOES exist is the test suite, which is why the exit-code space above is not
free real estate.
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

# Banked in-repo on purpose. The capture lives at
# ~/.openclaw-nori/workspace/state/live-by/first-serve-by-page.json — mode 0600,
# another agent's home, outside every git tree. A repo checker load-bearing on a
# private file in someone else's workspace is broken independent of log
# retention: one workspace reset and this arm loses its evidence with no way to
# notice. See evidence/README.md for the hash, the rebuild command, and why the
# banked copy is named for its load-bearing FIELD rather than for "live by" —
# two artifacts with different schemas answer the same question and each has
# been read for the other, nearly costing a true citation its credibility.
EVIDENCE = "evidence/first-200-utc.json"
UTC = datetime.timezone.utc


class InstrumentRefusal(Exception):
    """The interval arm cannot run. NEVER degrade this to 'nothing found'.

    Same discipline as load_adopted() raising on malformed JSON: an evidence
    file that will not load must not read as 'no evidence of adoption', because
    that is indistinguishable from a clean corpus at exactly the moment the
    instrument is least trustworthy.
    """


def load_adopted():
    """Declared publish dates for posts that were LIVE ON PROD before git saw them.

    Defines which posts git is the WRONG instrument for, and nothing else: it
    does not decide the population, only which members of it are judged against
    a declaration instead of a first commit. Import it rather than restating the
    rule — the duplicated TZ test that used to live in fix-schema-dates.py is
    what that prevents.

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
    """Which files in this repo count as a blog post, and which are excluded.

    Scope, stated rather than claimed: it enumerates `blog/*.html` in THIS
    checkout and excludes index.html and sub-2KB redirect stubs. It is not a
    census of what production serves — the origin log artifact covers 101 URLs
    against this population's 78, and the two differ legitimately (renamed
    paths, non-blog pages, files never committed). Do not read a count from one
    as a correction to the other.

    The "single source, never re-derive" claim that used to head this docstring
    is deleted on purpose (Coco, 2026-07-22). A competing filesystem-wide
    definition asserted the same uniqueness and produced 107; two files each
    declaring themselves THE source falsifies both claims. The competitor is
    gone, and the survivor earns its authority by naming its boundary, not by
    asserting it has no peer.

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


def _utc(stamp):
    """Parse an artifact timestamp to an aware UTC datetime. 'Z' is not ISO to Python."""
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone(UTC)


def _fmt(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def load_evidence(path):
    """First observed 200/304 per site-absolute URL, plus the log retention floor.

    Refuses rather than returning a partial or empty structure. The failure being
    guarded is specific and has already happened twice to readers of this data:
    two artifacts, ~/.../evidence/adoption-logs/live-by.json and
    ~/.../state/live-by/first-serve-by-page.json, both live, both Nori's,
    DIFFERENT SCHEMAS — 4 slugs keyed bare under `bounds` with no first_200_utc
    anywhere, versus 101 pages under `pages` with it. Loaded loosely, the wrong
    one yields a valid-looking dict with zero matching keys and the arm reports a
    clean corpus.

    So the guard is SCHEMA IDENTITY, not a filename convention and not a size
    floor. `pages` + `_retention_floor_utc` + rows carrying `first_200_utc` are
    exactly the markers the two artifacts differ on, and checking them cannot
    produce the false refusal a count threshold can (a legitimately sparse
    capture is expected — Cloudflare absorbs hits, so a valid artifact may
    genuinely cover far fewer pages than the population).
    """
    if not os.path.exists(path):
        raise InstrumentRefusal(f"{path} ABSENT — the interval arm has no evidence to reason from")
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except json.JSONDecodeError as exc:
        raise InstrumentRefusal(f"{path} UNPARSEABLE: {exc}")
    if not isinstance(doc, dict):
        raise InstrumentRefusal(f"{path} is {type(doc).__name__}, expected a JSON object")

    pages = doc.get("pages")
    if not isinstance(pages, dict):
        raise InstrumentRefusal(
            f"{path} has no `pages` map (top-level keys: {sorted(doc)[:8]}). "
            f"The 4-slug adoption-logs/live-by.json keys its bounds under `bounds` "
            f"and is NOT this artifact — check the path, hyphen included.")

    floor_raw = doc.get("_retention_floor_utc")
    if not isinstance(floor_raw, str):
        raise InstrumentRefusal(
            f"{path} has no `_retention_floor_utc`. Without it the arm cannot tell "
            f"'no serve happened' from 'the logs do not reach that far', and would "
            f"have to report unknowable as clean.")
    try:
        floor = _utc(floor_raw)
    except ValueError as exc:
        raise InstrumentRefusal(f"{path} `_retention_floor_utc` unparseable: {floor_raw!r} ({exc})")

    for url, row in pages.items():
        if not isinstance(row, dict) or "first_200_utc" not in row:
            raise InstrumentRefusal(
                f"{path} row {url!r} carries no `first_200_utc`. This is the field the "
                f"whole arm rests on; an artifact without it is the wrong artifact.")
    return pages, floor


def interval_arm(real, adopted, path):
    """Was the page served BEFORE the commit that introduced it? Instants, never dates.

    Returns (undeclared, dark, stats). Raises InstrumentRefusal — callers must
    let that reach the exit code, never swallow it into a bucket count.

    The invariant is `first_200_utc >= commit_utc` for a post git is the right
    instrument for. A violation of it is not drift and not a clock offset: it is
    proof of prior existence, because a 200 is the server saying it had bytes to
    send. Declared adoptions are expected to violate it — that is what adoption
    IS — so for those the violation is the CORROBORATION, not the finding.
    """
    pages, floor = load_evidence(path)
    undeclared, dark, undecidable = [], [], []
    corroborated = within = no_row = no_commit = 0

    # Paths the arm actually reached: it had a serve row AND the commit sits
    # inside the evidence window, so the invariant could have gone red on them.
    # Everything else is coverage, and the second operand below exists for it.
    reached = set()

    for p in real:
        commit = first_commit(p)
        if commit is None:
            no_commit += 1
            continue
        commit_utc = commit.astimezone(UTC)
        row = pages.get("/" + p)

        if row is None:
            # Absence is never a violation (artifact `_not`: origin sits behind
            # Cloudflare, no hit proves nothing). But there are two absences and
            # collapsing them is how the hole gets hidden: below the floor the
            # arm has NO pre-commit coverage at all and is structurally blind;
            # above it, the window was watched and nothing was seen.
            if commit_utc < floor:
                dark.append((os.path.basename(p),
                             f"commit {_fmt(commit_utc)} predates evidence floor {_fmt(floor)} "
                             f"— zero pre-commit log coverage, unjudgeable"))
            else:
                no_row += 1
            continue

        first = _utc(row["first_200_utc"])
        if first >= commit_utc:
            # NOT clean by default, and this branch was wrong until 2026-07-22.
            # If the commit predates the retention floor, then `first` could not
            # have been observed earlier than the floor, and therefore could not
            # have been earlier than the commit — the invariant was ARITHMETICALLY
            # INCAPABLE of failing here. It did not hold; it was never tested.
            #
            # Scoring those "invariant holds" is the same defect one level up
            # that this whole arm exists to catch: a rule that cannot go red on
            # the population it is applied to, reporting green. Measured at the
            # fix: 65 of 73 — 89% of the clean bucket was untestable, so the
            # headline number was almost entirely a claim about posts the
            # evidence cannot reach. Own bucket, out of the clean denominator.
            if commit_utc < floor:
                undecidable.append((os.path.basename(p),
                                    f"commit {_fmt(commit_utc)} predates evidence floor "
                                    f"{_fmt(floor)} — first serve could not have been earlier"))
            else:
                within += 1
                reached.add(p)
            continue

        reached.add(p)
        gap = int((commit_utc - first).total_seconds())
        detail = (f"first 200 {_fmt(first)} | commit {_fmt(commit_utc)} "
                  f"— served {gap}s BEFORE its own commit")
        if p in adopted:
            corroborated += 1
        else:
            undeclared.append((os.path.basename(p), detail))

    return undeclared, dark, {
        "corroborated": corroborated, "within": within, "no_row": no_row,
        "no_commit": no_commit, "floor": floor, "pages": len(pages),
        "undecidable": undecidable,
        # The only number in this arm that is a claim about anything: posts whose
        # commit sits inside the evidence window, where the invariant could have
        # gone red and did not. Everything else is corroboration or coverage.
        "tested": corroborated + within + len(undeclared),
        "reached": reached,
    }


DECLARES_ADOPTION = re.compile(r"\b(adopt|adopts|adopted|adoption|rescue|restore)\b", re.I)


class OperandUnavailable(RuntimeError):
    """The second operand could not be read at all.

    PROVEN RED 2026-07-22, and it is the reason this class exists rather than a
    bare `except`. Before it, both subprocess calls below took `.stdout` and
    dropped `returncode`. With a `git` on PATH that exits 128 on every call,
    `git_declared_adoptions()` returned `{}` — and `{}` is not a neutral value
    here, it is the SHAPE OF A CLEAN RUN read through the wrong direction:

        0  post(s) added by a commit whose message declares an adoption
        1  post(s) declared in blog/adopted.json
        1  post(s) the interval arm could NOT have failed on — this operand
           still covers them                              <-- claimed by nobody
        UNWITNESSED_BY_COMMIT — ... (back-fill is legitimate; this is not a finding)
        >>> 0 real bugs ... exit 0

    A dead instrument printed a positive coverage claim and then explained its
    own silence with the word reserved for the legitimate case. The one branch
    that would have caught it — `if not declared: BOTH ARE EMPTY` — is only
    reachable when blog/adopted.json is ALSO empty, i.e. never in this repo.

    Empty reads as pass; empty WEARING THE EXPECTED-STATE LABEL reads as a
    careful pass. So the failure is raised, never returned.
    """


def git_declared_adoptions():
    """Posts added by a commit whose OWN MESSAGE declares an adoption.

    The SECOND OPERAND, and the reason it is worth the lines: it is independent
    of the access log in provenance AND in reach.

      provenance — written by the adopter, at adoption time, in a different
      artifact, on a different occasion. Nothing derives it from the log and the
      log does not derive it from anything.

      reach — this is the half that matters. The log operand has a 30-day
      retention floor; measured 2026-07-22 it could have gone red on 13 of 78
      posts and was structurally incapable of failing on the other 65. Commit
      messages have no floor. So the two instruments are not merely independent,
      their blind spots do not overlap: the region where the interval arm cannot
      fail is exactly the region this one still covers.

    Deliberately over-broad. A normal post commit that happens to say "restore"
    lands here and raises a disagreement that a human has to close. That trade is
    made on purpose — a false alarm costs one read; the failure this exists to
    catch is an adoption nobody declared anywhere, and nothing else in the repo
    would ever surface it.

    NOT A GUARD ON ITS OWN. It reports what commit messages CLAIM. A commit that
    performs an adoption and says nothing is invisible to it, exactly as a serve
    below the retention floor is invisible to the log. Neither operand is a
    population; disagreement between them is the only thing either can prove.
    """
    log = subprocess.run(
        ["git", "log", "--format=%H%x00%B%x01", "--all"],
        capture_output=True, text=True,
    )
    if log.returncode != 0:
        raise OperandUnavailable(f"git log exited {log.returncode}")
    declared = {}
    for entry in log.stdout.split("\x01"):
        if "\x00" not in entry:
            continue
        sha, body = entry.strip().split("\x00", 1)
        if not DECLARES_ADOPTION.search(body):
            continue
        show = subprocess.run(
            ["git", "show", "--diff-filter=A", "--name-only", "--format=", sha],
            capture_output=True, text=True,
        )
        if show.returncode != 0:
            raise OperandUnavailable(f"git show {sha[:7]} exited {show.returncode}")
        for path in show.stdout.splitlines():
            path = path.strip()
            if path.endswith(".html"):
                declared.setdefault(path, (sha[:7], body.splitlines()[0]))
    return declared


def cross_check(real, adopted, reached):
    """Do the two operands name the same adoptions? Each mismatch gets its OWN word.

    Returns (findings, lines, unavailable) — findings are bugs, lines are printed
    either way, unavailable is a REFUSAL and outranks both. A same-exit-code
    disagreement is not the same as agreement, and two different disagreements are
    not each other; collapsing any of those three is how the report starts reading
    as a pass.
    """
    try:
        declared = {p: v for p, v in git_declared_adoptions().items() if p in real}
    except OperandUnavailable as exc:
        # Its own word, its own exit path, and NO coverage line. The sentence
        # "this operand still covers them" is the thing that must not survive an
        # operand that never ran — it is a claim about 65 posts sourced from an
        # empty dict.
        return [], [
            "",
            "--- second operand: the adopting commits' own messages ---",
            f"    OPERAND_UNAVAILABLE — {exc}",
            "    The commit-message operand did not run. It is NOT empty and it is",
            f"    NOT agreeing with {ADOPTED}; it has no value at all. Every post the",
            "    interval arm could not reach is now covered by nothing.",
        ], True
    lines = [
        "",
        "--- second operand: the adopting commits' own messages ---",
        f"    {len(declared):>4}  post(s) added by a commit whose message declares an adoption",
        f"    {len(adopted):>4}  post(s) declared in {ADOPTED}",
        f"    {len(real) - len(reached):>4}  post(s) the interval arm could NOT have failed on — "
        f"this operand still covers them",
    ]

    silent = sorted(set(declared) - set(adopted))
    unwitnessed = sorted(set(adopted) - set(declared))
    findings = []

    if silent:
        # The dangerous direction. A commit says it adopted a post and the
        # declaration file has no entry, so the checker is judging that post
        # against a git date its own history says is wrong.
        lines.append(f"    SILENT_ADOPTION — a commit message declares it, {ADOPTED} does not:")
        for p in silent:
            sha, subj = declared[p]
            blind = "" if p in reached else "  [interval arm blind here — only this operand sees it]"
            lines.append(f"        {p}  {sha} {subj[:56]}{blind}")
            findings.append((os.path.basename(p), f"declared adopted by {sha}, absent from {ADOPTED}"))
    if unwitnessed:
        # Not a bug and it must never share a word with the above. Back-filled
        # entries live here legitimately: all five entries in this file were
        # written 2026-07-22 in d80405a, days after the adoptions, so an adopting
        # commit that never used the word is expected. Named so it cannot be read
        # as the other direction.
        lines.append(f"    UNWITNESSED_BY_COMMIT — declared in {ADOPTED}, no commit message says so:")
        for p in unwitnessed:
            lines.append(f"        {p}  (back-fill is legitimate; this is not a finding)")
    if not silent and not unwitnessed:
        lines.append("    AGREE — both operands name the same set.")
        if not declared:
            # An empty set agreeing with an empty set is not agreement, it is two
            # silences. Say so rather than printing a clean line.
            lines.append("    >>> ...but BOTH ARE EMPTY. That is two silences, not a corroboration.")
    return findings, lines, False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", action="store_true",
                    help="print the population and exit; the number of record")
    ap.add_argument("--evidence", default=EVIDENCE, metavar="PATH",
                    help=f"first-200 evidence for the interval arm (default: {EVIDENCE})")
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

    # --- interval arm ---------------------------------------------------
    # Fails CLOSED and independently: a refusal here never suppresses the date
    # arm's verdict above, which has already printed. That split is the point —
    # the interval arm rests on an artifact with a 30-day expiry, and coupling
    # the whole checker to it would turn a log rotation into a permanently red
    # instrument nobody reads.
    refusal = None
    try:
        undeclared, dark, ev = interval_arm(real, adopted, args.evidence)
    except InstrumentRefusal as exc:
        refusal = str(exc)
        undeclared, dark, ev = [], [], None

    print(f"\n### UNDECLARED ADOPTION - served before its own commit, "
          f"absent from {ADOPTED}  ({len(undeclared)})")
    for name, detail in undeclared:
        print(f"    {name:<52} {detail}")

    print(f"\n--- interval arm ({args.evidence}) ---")
    if refusal:
        # Named loudly and never as a count of zero. "0 undeclared adoptions"
        # printed by an arm that never ran is the same lie as the dropped row.
        print(f"    INSTRUMENT REFUSES — NO VERDICT, this is not a clean result")
        print(f"    {refusal}")
    else:
        print(f"    {ev['pages']:>4}  URLs in the evidence, floor {_fmt(ev['floor'])}")
        print(f"    {ev['corroborated']:>4}  declared adoptions CORROBORATED by a pre-commit serve")
        print(f"    {ev['within']:>4}  first serve at or after first commit — invariant TESTED and holds")
        print(f"    {len(ev['undecidable']):>4}  UNDECIDABLE - has a serve row, but commit predates the floor:")
        print(f"          the invariant could not have failed here. Not clean; untested.")
        print(f"    {ev['no_row']:>4}  no serve row inside the covered window (Cloudflare: proves nothing)")
        print(f"    {ev['no_commit']:>4}  no first commit found")
        print(f"    {len(dark):>4}  DARK - no serve row AND commit below the floor, arm structurally blind")
        print(f"    ---- interval arm judged {ev['tested']} post(s); "
              f"{len(ev['undecidable']) + len(dark) + ev['no_row']} outside its reach ----")
        for name, why in dark:
            print(f"          {name:<46} {why}")
        if dark:
            print(f"    >>> interval arm dark for {len(dark)} post(s): evidence floor "
                  f"{_fmt(ev['floor'])} no longer covers them. Re-bank a fresh capture; "
                  f"deleting the artifact makes this notice disappear, not the gap.")

    # --- second operand -------------------------------------------------
    # Runs even when the interval arm REFUSED. That is the whole point: git
    # history has no retention floor and no 0600 path, so the operand that
    # survives an unusable evidence file is the one that must not be gated on it.
    # `reached` is empty under a refusal, which correctly reports every post as
    # outside the interval arm's reach rather than silently claiming coverage.
    cc_findings, cc_lines, cc_unavailable = cross_check(
        real, adopted, ev["reached"] if ev else set())
    for line in cc_lines:
        print(line)
    if cc_unavailable:
        # Promoted to the same rank as an unusable evidence file. Both arms are
        # now capable of saying "I could not run", and neither may say it quietly.
        refusal = (refusal or "") + \
            " | second operand unavailable — see OPERAND_UNAVAILABLE above"
    if cc_findings:
        print(f"\n### SILENT ADOPTION - declared by a commit message, absent from "
              f"{ADOPTED}  ({len(cc_findings)})")
        for name, detail in cc_findings:
            print(f"    {name:<52} {detail}")

    bugs += len(undeclared) + len(cc_findings)
    print(f"\n>>> {bugs} real bugs over {judged} judged posts")
    if refusal:
        # Refusal outranks violation: an instrument that could not run makes the
        # clean half of the report a claim about an unknown subset.
        return 2
    return 1 if bugs else 0


if __name__ == "__main__":
    sys.exit(main())
