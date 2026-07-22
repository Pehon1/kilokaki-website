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
from datetime import date, timedelta
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

        print("\nlisting derivation (derive_listing_lastmods)")

        # THE OPERAND TEST, and it is synthetic ON PURPOSE.
        #
        # A seeded-corpus fixture was the first design and it is not sufficient.
        # Measured on the real corpus, seed inserted after blog/index.html:
        # seed 2026-07-22 -> correct and broken BOTH return 2026-07-22 (green,
        # the homepage carries the max and the seed is never consulted); seed
        # 2026-07-23 -> red. So such a fixture is blind at <= the two index
        # pages' git stamps, and those are MUTABLE GIT DATES -- the day anyone
        # commits a nav tweak to index.html the cap moves up and the fixture
        # decays to a silent pass, triggered by a commit to a file the test does
        # not mention. That is the same class as the defect being fixed.
        #
        # Here the fixture owns BOTH operands, so nothing outside this function
        # can move the threshold. All three index pages are set NEWER than every
        # listed page, and the two sections are set to DIFFERENT maxima:
        #   - any operand admitting an index page returns 2026-12-31
        #   - any operand ignoring the prefix returns the other section's max,
        #     so blog/ answering 2026-11-01 or how-to/ answering 2026-05-01 is a
        #     cross-contamination and names itself as one
        # Only per-listing prefix scoping returns 2026-05-01 / 2026-11-01.
        corpus = [
            {"rel": "index.html", "lastmod": "2026-12-31", "tier": "git"},
            {"rel": "blog/index.html", "lastmod": "2026-12-31", "tier": "git"},
            {"rel": "blog/post-a.html", "lastmod": "2026-03-01", "tier": "dateModified"},
            {"rel": "blog/post-b.html", "lastmod": "2026-05-01", "tier": "dateModified"},
            {"rel": "how-to/index.html", "lastmod": "2026-12-31", "tier": "git"},
            {"rel": "how-to/anything.html", "lastmod": "2026-11-01", "tier": "dateModified"},
            {"rel": "how-to/other.html", "lastmod": "2026-04-01", "tier": "dateModified"},
        ]
        # ONE assertion over the whole map rather than one per listing, so a map
        # that quietly loses an entry FAILS here instead of going green on the
        # entries that remain. A missing lane is the failure mode this change
        # introduces: LISTING_INDICES is the only thing standing between
        # how-to/index.html and the git tier, and dropping it from the map
        # produces a smaller-but-correct-looking dict.
        check(
            "every listing derives from its own prefix, and only its own",
            lambda: gs.derive_listing_lastmods([dict(e) for e in corpus]),
            {"blog/index.html": ("2026-05-01", "git"),
             "how-to/index.html": ("2026-11-01", "git")},
        )

        # The predicate under the max, asserted directly so a wrong answer above
        # names WHICH page leaked in rather than just a wrong date. Asserted for
        # BOTH prefixes: the blog arm alone passes under a hardcoded "blog/".
        check(
            "blog listing lists blog posts, not the homepage or itself",
            lambda: [e["rel"] for e in corpus if gs.lists_under(e["rel"], "blog/")],
            ["blog/post-a.html", "blog/post-b.html"],
        )
        check(
            "how-to listing lists how-to articles, not itself",
            lambda: [e["rel"] for e in corpus if gs.lists_under(e["rel"], "how-to/")],
            ["how-to/anything.html", "how-to/other.html"],
        )

        # No listed pages -> that listing is OMITTED. Must not raise, must not
        # invent, and must leave the page on the git tier where the census can
        # show it. The other listing must still derive: a section emptying out
        # is not a reason to stop deriving the one that did not.
        check(
            "listing with nothing to list is omitted, the other survives",
            lambda: gs.derive_listing_lastmods([e for e in corpus if not e["rel"].startswith("blog/post")]),
            {"how-to/index.html": ("2026-11-01", "git")},
        )

        # A listing that is not in the corpus at all (deleted, noindexed, or
        # skipped as a redirect stub) must be skipped, not synthesised. The map
        # is a claim about which pages ARE listings, never that they exist.
        check(
            "listing absent from the corpus is not invented",
            lambda: gs.derive_listing_lastmods([e for e in corpus if e["rel"] != "how-to/index.html"]),
            {"blog/index.html": ("2026-05-01", "git")},
        )

        print("\nlisting derivation is WIRED (collect)")

        # derive_listing_lastmods being correct proves nothing if collect() never
        # calls it, or calls it inside the loop where `included` is partial.
        # This runs the real corpus, and asserts on the TIER, which no
        # coincidence of dates can produce -- only the derivation running can.
        # Asserting the value alone would go green the day some post's
        # dateModified happens to equal the listing's git date, which is the
        # masking case this ticket opened on -- and how-to/index.html is that
        # case TODAY: its git tier and its newest article are both 2026-06-07,
        # so every date assertion about it is satisfied by a coincidence and the
        # tier label is the only operand that is not.
        #
        # LANES IS TYPED OUT HERE, NOT READ FROM gs.LISTING_INDICES, and that is
        # the point of it. Iterating the module's own map means a map that loses
        # how-to/index.html loses the assertion about how-to/index.html at the
        # same instant: the suite goes green over one lane and reports nothing
        # missing, which is the failure this whole file exists to refuse. Two
        # files, two authors, two edit occasions -- a lane can only vanish from
        # both by someone editing both.
        entries, _ = gs.collect({})
        LANES = [("blog/index.html", "blog/"), ("how-to/index.html", "how-to/")]
        for listing_rel, prefix in LANES:
            listing = next((e for e in entries if e["rel"] == listing_rel), None)
            check(f"collect() tags {listing_rel} as derived",
                  lambda listing=listing: listing and listing["tier"], "newest-post")
            # Second operand, computed by the test with its own filter over the
            # same returned list -- and with its own spelling of "not a listing"
            # (endswith), so a bug in lists_under cannot answer both sides.
            want_max = max(e["lastmod"] for e in entries
                           if e["rel"].startswith(prefix) and not e["rel"].endswith("/index.html"))
            check(f"{listing_rel} carries the newest page it lists",
                  lambda listing=listing: listing and listing["lastmod"], want_max)

        # THE PREFIX ARM, and the two assertions above do NOT cover it. Measured:
        # mutating collect() to call the derivation with a partial prefix instead
        # of post-loop leaves this suite 12-ran / 0-FAIL, fully GREEN. The
        # prefix's max happens to equal the whole corpus's max, because the
        # newest post sorts early. Both assertions above are satisfied by
        # coincidence -- the same "green from a coincidence of dates" this ticket
        # opened on, one layer up, in the test written to close it.
        #
        # A seed is the only thing that discriminates here, and it must be
        # COMPUTED, not typed. Hardcoding 2026-07-23 decays into a silent pass
        # the day anyone commits a nav tweak to either index page, because the
        # threshold it must clear is those pages' mutable git dates. So the seed
        # is derived from the corpus at runtime and its two required properties
        # are ASSERTED rather than assumed:
        #   1. strictly newer than every entry collected, both index pages
        #      included -- so it is the sole carrier of the max under any
        #      operand, and no wrong operand can answer with something else.
        #   2. sorting after the listing index in the walk -- so a prefix-scoped
        #      operand cannot contain it, whatever the prefix.
        # Note this exercises collect(), not main(): a seed one day past the
        # corpus max can be a future date, and main()'s future-lastmod guard
        # would refuse it. That guard is asserted elsewhere and is not the
        # subject here.
        #
        # ONE SEED PER LANE, AND THE TWO STAMPS DIFFER BY A DAY. Both are newer
        # than the whole corpus, so either one satisfies "the listing moved";
        # only a per-listing operand puts the RIGHT one on each page. A single
        # shared seed would be answered correctly by an implementation that
        # maxes over every section at once -- the cross-contamination bug --
        # because with one seed both lanes have the same right answer.
        corpus_max = date.fromisoformat(max(e["lastmod"] for e in entries))
        seeds = {
            "blog/": (gs.ROOT / "blog" / "zzz-sitemap-fixture-newest.html",
                      (corpus_max + timedelta(days=1)).isoformat()),
            "how-to/": (gs.ROOT / "how-to" / "zzz-sitemap-fixture-newest.html",
                        (corpus_max + timedelta(days=2)).isoformat()),
        }
        try:
            for path, stamp in seeds.values():
                path.write_text(PAGE.format(dates=f',"dateModified":"{stamp}"'), encoding="utf-8")
            seeded, _ = gs.collect({})
            # Property 1 is asserted against the UNSEEDED collect: after seeding,
            # the listing pages themselves carry the seed stamps (that is the
            # thing under test), so a post-seed check would report the subject as
            # its own corroboration.
            lowest_seed = min(stamp for _, stamp in seeds.values())
            check(
                "seeds clear every collected date (property 1, not assumed)",
                lambda: [e["rel"] for e in entries if e["lastmod"] >= lowest_seed],
                [],
            )
            for (listing_rel, prefix) in LANES:
                path, stamp = seeds[prefix]
                # Property 2 must be read off the WALK order -- sorted(glob) --
                # and not off collect()'s return, which is sorted for output with
                # every index page ahead of every post. Reading it there would
                # make the assertion trivially true and blind to the thing it
                # names.
                walk = [p.name for p in sorted((gs.ROOT / prefix.rstrip("/")).glob("*.html"))]
                check(
                    f"{prefix} seed sorts after its index in the walk (property 2)",
                    lambda walk=walk, path=path: walk.index(path.name) > walk.index("index.html"),
                    True,
                )
                seeded_listing = next((e for e in seeded if e["rel"] == listing_rel), None)
                # The wrong-lane stamp is a real, present, newer date sitting in
                # the same corpus. Answering with it is the contamination;
                # answering with the git tier is the missing lane. Both fail here
                # and print which one arrived.
                check(
                    f"post-loop: {listing_rel} sees its own seed, not the other lane's",
                    lambda seeded_listing=seeded_listing: seeded_listing and seeded_listing["lastmod"],
                    stamp,
                )
        finally:
            for path, _ in seeds.values():
                path.unlink(missing_ok=True)

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
        _collision_rows(work)

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
# LISTING DERIVATION, PROVEN RED (2026-07-22). Same protocol, run by
# /private/tmp/nori-mut-listing.py: mutate gen-sitemap.py alone, re-run, revert,
# assert the file hashes back to the original. ran-N transcribed from each run.
#
#   mutation                                          ran  FAIL
#   operand admits root homepage (max over collected)  15     4
#   operand admits blog/index.html itself              15     4
#   operand admits how-to/ (pages not in the listing)  15     3
#   derivation not wired into collect()                15     3
#   wired at the call site: partial prefix             15     1
#
# THE LAST ROW WAS 15-RAN / 0-FAIL ON THE FIRST PASS -- fully GREEN, suite
# healthy, mutation uncaught. The two assertions then covering the wiring
# ("tags the listing as derived", "value is the newest listed post") are both
# satisfied by a prefix-scoped operand on today's corpus, because the newest
# post happens to sort early enough to fall inside the prefix. Green from a
# coincidence of dates, in the suite written to close a bug whose whole
# character is green from a coincidence of dates. The seeded arm below exists
# because of that run and nothing else; it is what took the row to 1 FAIL.
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
#
# LISTING_INDICES MAP, PROVEN RED (2026-07-22). Same protocol, run by
# /private/tmp/nori-mut-listing2.py. Transcribed from the run's stdout:
#
#   mutation                                          ran  FAIL
#   map loses how-to (regression to a singleton)       21     5
#   map gains the homepage (prefix "", no operand)     21     3
#   operand ignores the prefix (cross-contamination)   21     8
#   operand admits the listing pages themselves        21     6
#   predicate excludes nothing at all                  21     6
#   derivation not wired into collect()                21     5
#   wired at the call site: partial prefix             21     3
#   applied without the tier label                     21     2
#
# READ ROW 1 CLOSELY, IT IS THE ONE WITH SOMETHING TO SAY. Under "map loses
# how-to", the assertion "how-to/index.html carries the newest page it lists"
# still PASSES. Not a gap in the mutation -- the page's git tier (2026-06-07,
# 5eb42da) and the newest article it lists (2026-06-07) are the same date, so
# the derived value and the undrived value are indistinguishable on today's
# corpus. Every date assertion about that page is currently satisfied by a
# coincidence. The tier label and the seeded arm are the only two operands that
# are not, and they are what took that row to 5.
#
# Row 2 exists to make a COMMENT falsifiable: LISTING_INDICES says the homepage
# must never be added, and a comment that nothing can violate is decoration.
# Adding it (prefix "", so every non-listing page is an operand) fails 3.
#
# NOT PROVEN, STATED INSTEAD: lists_under excludes listings by map membership
# rather than by name (`rel != listing`). The name-based spelling is not
# writable at this signature -- the function never receives the listing -- so
# there is no mutation to run and no row to claim. It is prevention against a
# nested listing, not a fix for a reachable bug, and it is labelled that way in
# the docstring.

def _collision_rows(work) -> None:
    """Arms of mechanism_collisions. Fixture owns BOTH operands where it can.

    THE REAL-CORPUS RED ARM COCO ASKED FOR IS NOT RUNNABLE ON THIS BRANCH, and
    saying so is the point rather than a gap. Her red proof was "green on
    blog/index.html as-is, red on how-to/index.html as-is". Measured: at main,
    ac06eb6, d776419 and 1214857, how-to/index.html carries NO dateModified --
    the declaration exists only at 9da0e78 on the other branch. Asserting red
    against the working tree here would assert against a file that does not
    have the property, and would go green for the wrong reason. So the positive
    arm is synthetic and the real-corpus assertion is the one that IS true
    here: blog/index.html's only textual occurrence is a comment, and the
    parser must return None for it. That is the comment-vs-declaration
    discrimination her ruling turns on, and it is checkable today.
    """
    print("\nmechanism collision (mechanism_collisions)")

    listing = next(iter(gs.LISTING_INDICES))

    # Arm 1: the overwrite EVENT. superseded tier is what carries the signal --
    # the two DATES are equal on the real corpus, so a value comparison sees a
    # no-op and only the tier word distinguishes clobber from agreement.
    clobbered = [{"rel": listing, "lastmod": "2026-06-07", "tier": "newest-post",
                  "superseded": ("2026-06-07", "dateModified")}]
    check("arm1 fires when dates are EQUAL (the masked case)",
          lambda: len(gs.mechanism_collisions(clobbered, root=work)), 1)

    # Arm 1 must not fire on the tier it is supposed to leave alone. Without
    # this, "flags everything superseded" passes the row above.
    over_git = [{"rel": listing, "lastmod": "2026-07-21", "tier": "newest-post",
                 "superseded": ("2026-07-22", "git")}]
    check("arm1 silent when it superseded git, not a declaration",
          lambda: gs.mechanism_collisions(over_git, root=work), [])

    # Arm 2: CO-EXISTENCE, read off disk. Survives arm 1 being unreachable.
    for rel in gs.LISTING_INDICES:
        (work / rel).parent.mkdir(parents=True, exist_ok=True)
        (work / rel).write_text(PAGE.format(dates=""), encoding="utf-8")
    check("arm2 silent when no listing declares", lambda: gs.mechanism_collisions([], root=work), [])

    (work / listing).write_text(PAGE.format(dates=',"dateModified":"2026-06-07"'), encoding="utf-8")
    check("arm2 fires on a declaring listing, second pass never run",
          lambda: len(gs.mechanism_collisions([], root=work)), 1)

    # THE DISCRIMINATION. A grep arm flags this and says something false about
    # it: blog/index.html's sole occurrence FORBIDS the declaration.
    (work / listing).write_text(
        '<!doctype html><html><head>'
        '<!-- NO dateModified HERE, ON PURPOSE. Do not "fix" this by adding one. -->'
        "</head><body>fixture</body></html>",
        encoding="utf-8",
    )
    check("arm2 ignores a comment that merely says dateModified",
          lambda: gs.mechanism_collisions([], root=work), [])

    # THE WIRING, AND IT IS HERE BECAUSE THE CALL-SITE MUTATION WENT GREEN.
    # First mutation table, transcribed: neutering main()'s refusal to
    # `if False and collisions:` scored 30-ran / 0-FAIL / rc=0. Six mutations of
    # the FUNCTION all went red and not one of them touched the question of
    # whether anything READS it. Second time in this file that the call site is
    # the hole the assertions naming the behaviour cannot see (ac06eb6 was the
    # first). A guard that is computed and discarded is a guard.
    #
    # Both operands are owned here: the collision is injected, so this asserts
    # main()'s REACTION and nothing about the corpus.
    def _refusal_rc():
        real = gs.mechanism_collisions
        argv = sys.argv
        gs.mechanism_collisions = lambda entries, root=gs.ROOT: ["injected: two mechanisms"]
        sys.argv = ["gen-sitemap.py", "--check"]
        try:
            return gs.main()
        finally:
            gs.mechanism_collisions = real
            sys.argv = argv
    check("main() REFUSES (rc 2) when a collision is reported", _refusal_rc, 2)

    def _clean_rc():
        real = gs.mechanism_collisions
        argv = sys.argv
        gs.mechanism_collisions = lambda entries, root=gs.ROOT: []
        sys.argv = ["gen-sitemap.py", "--check"]
        try:
            return gs.main()
        finally:
            gs.mechanism_collisions = real
            sys.argv = argv
    check("main() does NOT refuse when the same guard reports clean", _clean_rc, 0)

    # THE REAL-CORPUS ROW, AND ITS CONTROL CAUGHT ME. I first asserted
    # declared_lastmod(blog/index.html) is None and paired it with "...and the
    # file DOES contain the word, so the None is not a miss". The control went
    # RED: at d776419 blog/index.html contains no occurrence AT ALL. Both
    # comments -- blog/index.html's "NO dateModified HERE, ON PURPOSE" and
    # how-to/index.html's -- live only on 9da0e78. So on THIS branch the None
    # is vacuous, and without the paired control it would have read as "the
    # parser correctly ignored a comment" while testing nothing.
    #
    # Same finding as the deletion that cannot be committed here: the state
    # this arm exists to discriminate is not present on this branch, for either
    # page. The discrimination is covered synthetically above; these two rows
    # assert the branch's ACTUAL state so the vacuity is on the record instead
    # of disguised as a pass.
    for rel in gs.LISTING_INDICES:
        check(f"real {rel}: no dateModified token on this branch (vacuous here, by measurement)",
              lambda rel=rel: (gs.ROOT / rel).read_text(encoding="utf-8").count("dateModified"), 0)
        check(f"real {rel}: parser agrees there is nothing to declare",
              lambda rel=rel: gs.declared_lastmod(gs.ROOT / rel), None)


# MECHANISM COLLISION GUARD, PROVEN RED (2026-07-22). Run by
# /tmp/nori-mut-collide.py, TRANSCRIBED from its stdout, not predicted:
#
#   mutation                                          ran  FAIL
#   arm1 deleted                                       32     1
#   arm1 keys on the wrong tier (git)                  32     2
#   arm1 fires on ANY supersede (tier ignored)         32     1
#   arm2 deleted                                       32     1
#   arm2 is a TEXT MATCH, not a parse (Coco's grep)    32     3
#   arm2 scans every entry, not LISTING_INDICES        32     1
#   CALL SITE: guard computed but never acted on       32     1
#   RESTORED (control)                                 32     0   rc=0
#
# ROW 5 IS THE ONE COCO'S RULING TURNS ON. Swapping the parser for
# `"dateModified" in text` -- the obvious implementation -- fails 3. Measured at
# 9da0e78, grep over the three listing pages returns 2 / 1 / 3 hits and four of
# those six are comment prose, including blog/index.html whose ONLY occurrence
# is a comment forbidding the declaration. The grep arm flags that page and
# asserts something false about it: fires on the correct page, for a reason
# that is not true.
#
# ROW 7 WAS 32-RAN / 0-FAIL ON THE FIRST TABLE. Neutering main()'s refusal to
# `if False and collisions:` left every one of the then-30 assertions green,
# rc=0. Six mutations of the function all went red and not one of them asked
# whether anything READS the result. Second time in this file the call site is
# the hole (ac06eb6 was the first, and that one was also 15-ran / 0-FAIL on the
# first pass). The two rows added for it -- main() refuses on an injected
# collision, and does not refuse when the same guard reports clean -- are what
# took it to 1. A verdict emitted identically under both branches carries zero
# bits, so both branches are asserted.
#
# NOT PROVEN, STATED INSTEAD: the real-corpus arm Coco specified ("green on
# blog/index.html as-is, red on how-to/index.html as-is") is NOT RUNNABLE on
# this branch. Measured: at d776419 and main, BOTH listing pages contain zero
# occurrences of the token; the declaration and both explanatory comments exist
# only at 9da0e78. The first version of that row asserted None from the parser
# and would have read as "correctly ignored a comment" while testing nothing --
# its paired occurrence-count control is what caught it. The rows now assert
# the branch's actual state and name the vacuity.
if __name__ == "__main__":
    sys.exit(main())
