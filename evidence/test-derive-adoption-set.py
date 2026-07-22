#!/usr/bin/env python3
"""Mutation harness for derive-adoption-set.py.

A cross-check that has only ever been seen AGREE is not evidence of anything. Each
case below breaks one thing and names the marker that must appear. Every case is a
THUNK: a raise inside one case fails that case and the suite keeps going, so a
suite that dies at case 1 cannot be mistaken for a suite that passed. The RAN
count is printed next to PASS/FAIL for the same reason - a shrinking FAIL count
and a suite that stopped early read identically otherwise.

Every expectation here was OBSERVED, not predicted. Run it before trusting the
script's green.
"""

import copy
import importlib.util
import io
import contextlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "derive", os.path.join(HERE, "derive-adoption-set.py")
)
derive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(derive)

import json

BASE = json.load(open(derive.LIVE_BY))


def run_with(corpus=None, pattern=None):
    """Run main() against a mutated corpus / regex; return (rc, stdout)."""
    import tempfile

    doc = corpus if corpus is not None else BASE
    orig_live, orig_pat = derive.LIVE_BY, derive.DECLARES_ADOPTION
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(doc, fh)
        tmp = fh.name
    try:
        derive.LIVE_BY = tmp
        if pattern is not None:
            derive.DECLARES_ADOPTION = pattern
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = derive.main()
        return rc, buf.getvalue()
    finally:
        derive.LIVE_BY, derive.DECLARES_ADOPTION = orig_live, orig_pat
        os.unlink(tmp)


def mutate(url, new_first_200):
    doc = copy.deepcopy(BASE)
    doc["pages"][url]["first_200_utc"] = new_first_200
    return doc


CASES = []


def case(name, expect_rc, must_contain, must_not_contain=()):
    def deco(fn):
        CASES.append((name, fn, expect_rc, must_contain, must_not_contain))
        return fn

    return deco


@case(
    "UNMUTATED: both instruments agree on 5",
    0,
    ["FALSIFIED    5", "AGREE - both instruments name the same set."],
)
def _unmutated():
    return run_with()


@case(
    "A NEW silent adoption fires the alarm (the case durian proves can happen)",
    1,
    ["FALSIFIED    6", "SILENT_ADOPTION", "the-short-trip-trap.html"],
    ["AGREE"],
)
def _new_silent():
    # the-short-trip-trap is CLEAN today: committed 02:21:51Z, served 133s later.
    # Pull the serve BEFORE the commit and it becomes an adoption no commit
    # message declares - which must be loud, not absent.
    return run_with(mutate("/blog/the-short-trip-trap.html", "2026-07-11T02:00:00Z"))


@case(
    "Losing durian from the log is named, not silently dropped",
    0,
    ["FALSIFIED    4", "UNSEEN_BY_LOG", "how-to-log-durian.html"],
    ["AGREE"],
)
def _lose_durian():
    # Push durian's first serve past its commit. The log arm can no longer see it;
    # the commit-message arm still can. That gap must be printed, under its own
    # word - the same exit code as SILENT_ADOPTION would be the opposite diagnosis.
    return run_with(mutate("/blog/how-to-log-durian.html", "2026-07-17T00:00:00Z"))


@case(
    "A cross-check whose second operand is empty is NOT a pass",
    1,
    ["declared by a commit message : 0", "SILENT_ADOPTION"],
    ["AGREE"],
)
def _dead_second_operand():
    # If the commit-message arm silently matched nothing - bad regex, renamed
    # convention, shallow clone - an AGREE here would be a mirror of an empty set
    # against an empty set. It must go red instead.
    return run_with(pattern=re.compile(r"\bzzz_no_such_word\b"))


@case(
    "UNDECIDABLE is not folded into CLEAN",
    0,
    ["UNDECIDABLE  88", "CLEAN        8"],
)
def _buckets_stay_split():
    return run_with()


def main():
    ran = passed = failed = 0
    for name, fn, expect_rc, must, must_not in CASES:
        ran += 1
        try:
            rc, out = fn()
            problems = []
            if rc != expect_rc:
                problems.append(f"rc={rc} expected {expect_rc}")
            for m in must:
                if m not in out:
                    problems.append(f"missing marker: {m!r}")
            for m in must_not:
                if m in out:
                    problems.append(f"forbidden marker present: {m!r}")
            if problems:
                failed += 1
                print(f"FAIL  {name}")
                for p in problems:
                    print(f"        {p}")
            else:
                passed += 1
                print(f"PASS  {name}")
        except Exception as exc:  # a raise fails ONE case, never the suite
            failed += 1
            print(f"FAIL  {name}\n        raised {type(exc).__name__}: {exc}")

    print(f"\nRAN {ran}   PASS {passed}   FAIL {failed}   (declared {len(CASES)})")
    if ran != len(CASES):
        print("ABORT: fewer cases ran than declared")
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
