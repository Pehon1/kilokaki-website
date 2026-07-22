# evidence/

Banked, read-only artifacts that `scripts/check-schema-dates.py` is load-bearing on.

## Why these live in the repo

They were captured into `~/.openclaw-nori/workspace/`, mode 0600, in another
agent's home directory and outside any git tree. A repo checker whose verdict
depends on a private file in someone else's home is broken independent of
whether that file expires — one workspace reset and the checker silently loses
its evidence arm, or worse, keeps running and reads the absence as clean.
Banking makes the evidence versioned, reviewable, and restorable by
`git checkout`.

## `first-200-utc.json`

Per-URL first observed `200`/`304` in the origin access logs, keyed by
site-absolute path.

    sha256  b65289497a86139e9b3af3fe9ca08b3016b403c746ed8405ef9091cdc3ccd292
    bytes   18926
    source  ~/.openclaw-nori/workspace/state/live-by/first-serve-by-page.json
    copied  2026-07-22, byte-identical, no fields added or renamed

**Copied verbatim on purpose.** No provenance keys were injected into the JSON;
an artifact you edit on the way in is an artifact whose hash proves nothing.
Provenance lives here instead.

## Corrections

Two claims this file has carried are false, and neither correction is reachable
from the route a reader actually takes — `git log -- evidence/README.md`, or
`blame` on the line that is wrong. Both are recorded here so they are.

**`source` read `~/.openclaw-nori/workspace/state/live-by/live_by.json` until
`1b21282`, and read it again at `a224c71`.** That path has never existed:
`find ~/.openclaw-nori/workspace -name live_by.json` returns empty. The real
artifact is `first-serve-by-page.json`, sha256 `b6528949…`, 18926 bytes. The
regression was an overwrite, not a decision — `a224c71` composed its README
edits onto `8d00738`'s text rather than `1b21282`'s and dropped the whole file
over the fix, reverting `:22` and `:35` and deleting §Rebuild.
`git diff 8d00738 a224c71 -- evidence/README.md` touches neither phantom line,
which is how you can tell. The three code sites `1b21282` fixed
(`check-schema-dates.py:118`, `:244`, `test-schema-dates-adoption.sh:486`) kept
the fix, so the tip briefly shipped a README contradicting the checker beside
it. Restored here.

**`1b21282`'s commit message calls the writer of a 16:06 checkout
"unrecorded". `29af902` retracts that.** The reflog records the event to the
second; what it lacks is a *distinguishing actor*, because every agent working
the shared checkout writes the same machine-default identity
(`Pe Hon Ong <pehonong@Mac-Studio.local>` — including every commit on this
branch). The correct word is "unattributed". The distinction is load-bearing:
no record argues for adding logging, a record whose actor field never varies
argues for giving each agent its own tree. Only the second is true.
`29af902` is an **empty** commit, so it appears in no path-filtered log and in
no `blame` — this paragraph is the only route to it from the file it corrects.
Original wording stays in history at `1b21282`; nothing is rewritten.

## Rebuild

    sed 's|^OUT = .*|OUT = Path("/tmp/rebuilt.json")|' \
        ~/.openclaw-nori/workspace/scripts/build-live-by.py > /tmp/build.py
    python3 /tmp/build.py
    shasum -a 256 /tmp/rebuilt.json   # -> b65289497a86139e9b3af3fe9ca08b3016b403c746ed8405ef9091cdc3ccd292

Re-verified 2026-07-22 17:5x, shared checkout at `1678682`: reproduces this file
**byte-identically** and prints `population 101 | with evidence 101 | no hit 0`.
The `sed` exists only to stop the script overwriting Nori's copy — the builder
hardcodes its own `OUT`.

Cite that builder by full path. There are two `build-live-by.py` under Nori's
workspace — `scripts/` (4811 b, the one above) and
`evidence/adoption-logs/` (7859 b). Same basename, different files: the same
trap this README's naming section is about, one directory over.

Two inputs it needs, and **neither is in this repo**:

* `~/.openclaw-nori/workspace/state/live-by/raw-access-2026-07-22.log` — 2.2 MB,
  mode 0600, Nori's home. Banking the *output* did not bank the *input*: this
  command dies the moment that log is gone, which is the same hazard §"Why these
  live in the repo" opens with, one level up. Rebuildability here has a shelf
  life; the banked bytes do not.
* `~/.openclaw/workspace/kilokaki-site` — the builder derives its population from
  that tree's `blog/` + `how-to/`. It is a **shared checkout whose HEAD moves**,
  so a rebuild at a different commit legitimately yields a different population
  and a different hash. Match the count (101) before trusting a mismatch.

A provenance field whose path does not resolve is a stamp, not provenance. This
block is here so the artifact can be re-derived from its own documentation
rather than vouched for by it.

### The name is deliberate, and it is a warning

Two artifacts are live, **both Nori's, different schemas**:

    ~/.openclaw-nori/workspace/evidence/adoption-logs/live-by.json      4 slugs, bare under `bounds`, no first_200_utc field
    ~/.openclaw-nori/workspace/state/live-by/first-serve-by-page.json   101 pages under `pages`, has first_200_utc

Coco read the first while checking a citation against the second and came within
one step of ruling a true citation fabricated. The near-miss is real and twice
attested — Nori's first pass reported "durian is NOT in [the evidence]" off the
4-slug file.

They are **not** one character apart. This section said so until `1b21282` and
said so again at `a224c71`; it was a mechanism invented to explain the near-miss,
retrofitted to a `live_by.json` that does not exist (§Corrections). The real pair
differs by directory *and* basename, and the confusion was schema-shaped, not
punctuation-shaped.

This copy is therefore named for its **load-bearing field**, `first_200_utc`, not
for the concept "live by" — you cannot confuse `first-200-utc.json` with
something that lacks a `first_200_utc`. Right call, originally for a made-up
reason, which is why the name is not the enforcement: `load_evidence()` refuses
on schema identity (`pages` + `_retention_floor_utc` + rows carrying
`first_200_utc`), and test K feeds it the `bounds` artifact and asserts exit 2.
A convention protects a careful reader; the guard protects everyone else.

Cite full paths for anything in this directory. Never the basename.

### Four copies exist. This is the one to cite.

As of 2026-07-22 16:1x the same capture exists in four places across three trees.
**Re-measure this list before citing it; do not read the times as current.**

    13:57  ~/.openclaw-nori/workspace/state/live-by/first-serve-by-page.json
    13:58  ~/.openclaw-nori/workspace/evidence/adoption-logs/live-by.json   4 slugs, `bounds` schema — NOT this artifact
    13:59  ~/.openclaw-nori/workspace/state/archive/live-by-backfill-*.json
    15:50  evidence/first-200-utc.json                                      <-- THIS FILE

**Cite this one, and only this one.** Not because it is more accurate — it is a
byte-identical copy of the same capture — but because it is the only one inside
a git tree. It has a hash in this README, a commit that introduced it, and a
diff a reviewer can read. The other three are files on a disk: no version, no
provenance, and nothing that would reveal an edit.

**A fifth copy was listed here and is now deleted** — `evidence/first-serve-by-page.json`,
a parallel banking of the same capture made alongside `a069755`. Before deleting it
its `pages` payload was compared to this file key-set-wise and value-wise: 101/101,
zero diffs, against a control mutation that produced exactly 1. It was not kept as a
cross-check, because two files with one provenance are not two instruments — they are
one instrument that has acquired the ability to disagree with itself.

Two things about the line that named it are worth keeping, because both are the
failure mode this README is about:

  * It was recorded as living in `~/.openclaw/workspace/kilokaki-site/evidence/`.
    True when written at 15:53; by 16:02 a parallel run had extracted that work to a
    detached worktree and restored the shared checkout clean, so the path named a
    file that was no longer there while the file itself still existed elsewhere.
    **A census of copies is itself a typed value with no invalidation** — the exact
    defect that makes five copies dangerous, committed inside the warning about it.
  * "Five" was correct for about twelve minutes. The count above will rot the same
    way. It is a snapshot with a timestamp, not a live fact, and it is safe only
    because the paragraph under it tells you which one to use regardless of how
    many there turn out to be.

The hazard is not that a reader picks a stale copy. It is that **every one of
the five returns a defensible-looking answer**, and four of them cannot be
checked against anything. A reader who lands on `adoption-logs/live-by.json`
gets a valid JSON document with a completely different schema — that near-miss
already cost Coco a citation review and came one step from a true citation
being ruled fabricated.

The other four should be deleted or replaced with a pointer here. That is
**Nori's call on Nori's files**, not this branch's change — recorded as the ask,
not as a done thing.

### What it does and does not prove

Straight from the artifact's own `_what` / `_not`:

* `live_by` is an **upper bound** on `datePublished`, not a publish date.
* Origin sits behind Cloudflare. **A missing row proves nothing** — the page may
  have been served entirely from cache. Absence is never a violation; only a
  positive pre-commit serve is.
* `_retention_floor_utc` = `2026-06-22T00:18:43Z`. Below that instant the logs
  simply do not reach, so "no row" is unknowable rather than negative. The
  checker computes darkness from this field and names it in the report.

### Expiry

Logs rotate at 30 days; the 16-Jul rows age out around 2026-08-15. When they do,
the interval arm goes **dark and says so** — it does not start passing. Re-bank a
fresh capture to extend coverage; do not delete this file to make the notice go
away.
