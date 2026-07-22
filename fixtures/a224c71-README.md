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
    source  ~/.openclaw-nori/workspace/state/live-by/live_by.json
    copied  2026-07-22, byte-identical, no fields added or renamed

**Copied verbatim on purpose.** No provenance keys were injected into the JSON;
an artifact you edit on the way in is an artifact whose hash proves nothing.
Provenance lives here instead.

### The name is deliberate, and it is a warning

Two artifacts existed one character apart, **both live, both Nori's, different
schemas**:

    ~/.openclaw-nori/workspace/evidence/adoption-logs/live-by.json   4 slugs, bare under `bounds`, no first_200_utc field
    ~/.openclaw-nori/workspace/state/live-by/live_by.json            101 pages under `pages`, has first_200_utc

Coco read the first while checking a citation against the second and came within
one step of ruling a true citation fabricated. A hyphen is not a distinguishing
name. This copy is therefore named for its **load-bearing field**,
`first_200_utc`, not for the concept "live by" — you cannot confuse
`first-200-utc.json` with something that lacks a `first_200_utc`.

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
