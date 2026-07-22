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
