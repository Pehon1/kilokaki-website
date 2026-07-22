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

### Rebuild

    sed 's|^OUT = .*|OUT = Path("/tmp/rebuilt.json")|' \
        ~/.openclaw-nori/workspace/scripts/build-live-by.py > /tmp/build.py
    python3 /tmp/build.py
    shasum -a 256 /tmp/rebuilt.json   # -> b65289497a86139e9b3af3fe9ca08b3016b403c746ed8405ef9091cdc3ccd292

Verified 2026-07-22: reproduces this file **byte-identically**, and prints
`population 101 | with evidence 101 | no hit 0`. The `sed` exists only to stop
the script overwriting Nori's copy — the builder hardcodes its own `OUT`.

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

    ~/.openclaw-nori/workspace/evidence/adoption-logs/live-by.json          4 slugs, bare under `bounds`, no first_200_utc field
    ~/.openclaw-nori/workspace/state/live-by/first-serve-by-page.json       101 pages under `pages`, has first_200_utc

Both have been read for the other. Nori's first pass reported "durian is NOT in
[the evidence]" off the 4-slug file; Coco later read that same file while
checking a citation against the 101-page one and came within a step of ruling a
true citation fabricated. So the confusion is real and twice-attested.

**What was NOT real is the explanation this README used to give for it.** Until
`8d00738` this section said the two names were "one character apart" — a
hyphen-versus-underscore trap, `live-by.json` against `live_by.json`. There is
no `live_by.json`. It has never existed in any tree; `find` over Nori's whole
workspace returns empty. The real pair differs by directory *and* basename and
is not confusable by punctuation at all. The phantom name entered upstream (it
is in Nori's handoff notes and reached Coco's spec req 4, since corrected), and
this file inherited it and then **invented a mechanism to explain it** — a story
about a hyphen, retro-fitted to a filename that was not there. The near-miss it
was explaining had a different cause: two files answering the same question with
different schemas, in different directories.

Note what that means about the fix that came out of it: naming this copy for its
load-bearing field, `first_200_utc`, is still the right call — you cannot
confuse `first-200-utc.json` with something that lacks a `first_200_utc` — but
it was **right for a reason that was made up**. Which is why the enforcement is
not the name. `load_evidence()` refuses on **schema identity** (`pages` +
`_retention_floor_utc` + rows carrying `first_200_utc`), test K feeds it the
`bounds` artifact and asserts exit 2. A convention protects a careful reader; the
guard protects everyone else.

Cite full paths for anything in this directory. Never the basename.

### Four copies exist. This is the one to cite.

As of 2026-07-22 16:30 the same capture exists in four places across three trees:

    13:57  ~/.openclaw-nori/workspace/state/live-by/first-serve-by-page.json     the source of this copy
    13:58  ~/.openclaw-nori/workspace/evidence/adoption-logs/live-by.json        4 slugs, `bounds` schema — NOT this artifact
    13:59  ~/.openclaw-nori/workspace/state/archive/live-by-backfill-20260722-135900.json
    15:50  evidence/first-200-utc.json                                           <-- THIS FILE

A fifth, `~/.openclaw/workspace/kilokaki-site/evidence/first-serve-by-page.json`
(uncommitted, 15:53), was listed here at `8d00738` and **is gone as of 16:30** —
that tree has since been checked out to `origin/fix/schema-dates-interval` by an
unrecorded writer. Untracked files in a shared checkout are not evidence; they
are weather. Counted here only to record that the previous count was five.

**Cite this one, and only this one.** Not because it is more accurate — it is a
byte-identical copy of the same capture, `shasum` above — but because it is the
only one inside a git tree. It has a hash in this README, a commit that
introduced it, and a diff a reviewer can read. The others are files on a disk:
no version, no provenance, and nothing that would reveal an edit.

The hazard is not that a reader picks a stale copy. It is that **every one of
them returns a defensible-looking answer** and only this one can be checked
against anything. A reader who lands on `adoption-logs/live-by.json` gets a valid
JSON document with a completely different schema.

The others should be deleted or replaced with a pointer here. That is **Nori's
call on Nori's files**, not this branch's change — recorded as the ask, not as a
done thing. The one exception is the raw log under §Rebuild: deleting that ends
rebuildability, so it should outlive the copies.

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
