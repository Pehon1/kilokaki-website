#!/usr/bin/env python3
"""Fixture tests for gen-sitemap.py's unreachable branches.

Run:  python3 scripts/test-gen-sitemap.py     (exit 0 pass, 1 fail)

WHY THIS FILE EXISTS
--------------------
Two branches in gen-sitemap.py cannot be reached by the live corpus:

  1. the datePublished tier -- 0 of 94 urls hit it, and structurally so: no
     page here carries datePublished without also carrying dateModified.
  2. the SitemapError paths -- every page either declares a date or is in git.

A production run therefore exits 0 whether those branches are correct, subtly
wrong, or a syntax error waiting for its first caller. "It ships green" is a
statement about the corpus, not about the code. So each test below names the
input that makes its branch fire, and the suite is only meaningful because
every assertion in it has been made to FAIL on purpose before being trusted --
see PROVEN RED at the bottom for what was mutated and what broke.

Fixtures are written under ROOT (not /tmp) because git_lastmod() calls
path.relative_to(ROOT), which raises outside the tree. Untracked fixture files
make git log return empty, which is exactly the "no history" input tier 3 needs
in order to fall through.
"""

from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gen_sitemap", HERE / "gen-sitemap.py")
gs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gs)

FAILURES: list[str] = []
RUN: list[str] = []  # every assertion that actually executed, counted by the suite


def check(name: str, produce, want) -> None:
    """`produce` is a THUNK, not a value.

    It was a value until a mutation test caught this: deleting the datePublished
    tier makes lastmod_for RAISE, the exception escaped check(), and the suite
    died on assertion 1 -- exit 1 with zero FAIL lines printed, and every later
    assertion silently never ran. Nonzero exit saved it that time only because
    the crash landed first. A crash in the middle produces a complete-looking
    report with a lane missing, and a missing lane reads as "nothing wrong
    there", which is the inverse of the truth. So the call is deferred and the
    raise is caught and named.
    """
    RUN.append(name)
    try:
        got = produce()
    except Exception as exc:  # noqa: BLE001 - an unexpected raise IS the failure
        print(f"  FAIL  {name}")
        print(f"          want {want!r}")
        print(f"          raised {type(exc).__name__}: {str(exc)[:96]}")
        FAILURES.append(name)
        return
    if got == want:
        print(f"  PASS  {name}")
        print(f"          got {got!r}")
    else:
        print(f"  FAIL  {name}")
        print(f"          want {want!r}")
        print(f"          got  {got!r}")
        FAILURES.append(name)


def raises(name: str, fn, exc=gs.SitemapError) -> None:
    """A branch whose whole job is to refuse. Not-raising is the failure."""
    RUN.append(name)
    try:
        result = fn()
    except exc as caught:
        print(f"  PASS  {name}")
        print(f"          raised {exc.__name__}: {str(caught)[:96]}")
        return
    except Exception as wrong:  # noqa: BLE001 - wrong exception is still a failure
        print(f"  FAIL  {name}: raised {type(wrong).__name__}, wanted {exc.__name__}")
        FAILURES.append(name)
        return
    print(f"  FAIL  {name}: returned {result!r} instead of raising {exc.__name__}")
    FAILURES.append(name)


PAGE = (
    '<!doctype html><html><head><title>fixture</title>'
    '<script type="application/ld+json">{{"@type":"Article"{dates}}}</script>'
    "</head><body>fixture</body></html>"
)


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix=".sitemap-fixtures-", dir=gs.ROOT))
    try:
        print("tier selection (lastmod_for)")

        # THE UNREACHABLE ONE. datePublished present, dateModified absent.
        only_pub = work / "only-published.html"
        only_pub.write_text(PAGE.format(dates=',"datePublished":"2026-01-15"'), encoding="utf-8")
        check("datePublished alone -> tier 2", lambda: gs.lastmod_for(only_pub), ("2026-01-15", "datePublished"))

        # Precedence: tier 1 must win even when tier 2 is present and DIFFERENT.
        # Same-value fixtures cannot tell precedence from coincidence.
        both = work / "both-dates.html"
        both.write_text(
            PAGE.format(dates=',"datePublished":"2026-01-15","dateModified":"2026-03-20"'),
            encoding="utf-8",
        )
        check("dateModified beats datePublished", lambda: gs.lastmod_for(both), ("2026-03-20", "dateModified"))

        # Tier 2 must beat git, not merely exist. This fixture is untracked, so
        # git yields nothing -- assert the tier label, which is the only thing
        # that distinguishes "the page told us" from "we asked git".
        check("tier label is reported, not inferred", lambda: gs.lastmod_for(only_pub)[1], "datePublished")

        print("\nrefusals (SitemapError)")

        # No schema, no git history: the old code invented an mtime here.
        bare = work / "no-dates.html"
        bare.write_text("<!doctype html><html><body>no schema, untracked</body></html>", encoding="utf-8")
        raises("no date anywhere -> refuse, never mtime", lambda: gs.lastmod_for(bare))

        # THE REINSTATED GUARD. Non-empty sitemap that parses to zero pairs.
        # Deleted in the derived-from-page rewrite because published_lastmods()
        # became reporting-only; reinstated because the report IS the artifact
        # the deploy decision is made on.
        real_sitemap = gs.SITEMAP
        try:
            corrupt = work / "corrupt-sitemap.xml"
            corrupt.write_text("<urlset><url><loc>https://kilokaki.com/</loc></url></urlset>", encoding="utf-8")
            gs.SITEMAP = corrupt
            raises("sitemap parses to 0 pairs -> refuse", gs.published_lastmods)

            # ...and the guard must NOT fire on a genuine first run. A guard that
            # cannot tell "no file" from "unreadable file" just relocates the bug.
            gs.SITEMAP = work / "does-not-exist.xml"
            check("absent sitemap -> {} , not an error", gs.published_lastmods, {})

            # The text.strip() clause, which the absent-file case NEVER REACHES:
            # published_lastmods() returns at `if not SITEMAP.exists()` two lines
            # earlier. Caught by mutating the guard to `if not published:` --
            # dropping the clause entirely -- and watching the suite stay green.
            # An assertion that cannot reach the code it names is not coverage,
            # it is a coverage-shaped decoration, and it was the ONLY thing
            # standing behind a "PROVEN RED" line I had already written down.
            # A file that exists and is empty is a real first run: touch, or a
            # truncated write. It must be {} and must not raise.
            empty = work / "empty-sitemap.xml"
            empty.write_text("   \n", encoding="utf-8")
            gs.SITEMAP = empty
            check("empty-but-present sitemap -> {} , not an error", gs.published_lastmods, {})
        finally:
            gs.SITEMAP = real_sitemap
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if FAILURES:
        print(f"FAIL: {len(FAILURES)} of the branches above are wrong: {', '.join(FAILURES)}")
        return 1
    # Counted by the suite, not typed into it. A hand-written "7 assertions"
    # survives an assertion being deleted, commented out, or stranded after an
    # early return -- the number keeps reporting the intent of whoever last
    # edited the prose. RUN is appended to at entry to each assertion, so it
    # counts what executed.
    print(f"OK: {len(RUN)} assertions, every one over a branch the live corpus never executes.")
    return 0


# PROVEN RED (2026-07-22). Each mutation applied to gen-sitemap.py alone, suite
# re-run, mutation reverted, file diffed back to byte-identical. Counts below are
# TRANSCRIBED FROM THE RUN, not predicted:
#   - delete the datePublished tier      -> 2 FAIL (tier 2, tier label)
#   - swap tier order                    -> 1 FAIL, precedence
#   - restore the mtime fallback         -> 1 FAIL, "no date anywhere" returns a date
#   - remove the reinstated 0-pair guard -> 1 FAIL, returns {} instead of raising
#   - widen guard to `if not published`  -> 1 FAIL, empty-but-present starts raising
#
# TWO OF THOSE FIVE LINES WERE WRONG WHEN FIRST WRITTEN, and the file said
# "PROVEN RED" over both of them:
#   - "delete the tier -> 3 FAIL" was a prediction. The real run printed ZERO
#     FAIL lines and exited 1 on a traceback: check() took a VALUE, so the raise
#     escaped and killed the suite at assertion 1. Nonzero exit only because the
#     crash happened to land first. check() now takes a thunk and names the raise.
#   - "widen the guard -> 1 FAIL" was false: the run stayed GREEN. The assertion
#     backing it used an ABSENT file, which returns at `if not SITEMAP.exists()`
#     and never reaches the text.strip() clause it claimed to cover. Fixed by
#     adding an empty-but-PRESENT fixture, which does reach it.
# Both were caught by running the mutations, and by nothing else -- the suite was
# green, the code was right, and the evidence was fiction. The mutation table is
# the test for the tests; writing it from memory is how a suite earns tenure it
# has not done anything to deserve.
#
# THIRD correction, same shape as the first two: "delete the tier -> 3 FAIL" was
# also predicted, and the rerun says 2. The third assertion I expected to fall
# (the mtime refusal) PASSES under that mutation -- correctly, because a page
# with no reachable tier should refuse either way. Right verdict, and it would
# have been logged here as evidence for a tier that was no longer in the file.
# Three fabricated counts in one table, every one written while actively holding
# the rule against fabricating counts. Hence the ran-N column: each mutation run
# reports how many assertions EXECUTED (7, all five times), because a shrinking
# FAIL count and a suite quietly dying halfway produce the same reassuring line.
if __name__ == "__main__":
    sys.exit(main())
