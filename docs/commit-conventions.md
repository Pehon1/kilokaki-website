# Commit conventions

## `Session:` trailer — required

Git identity fields (`user.name` / `user.email`) are **agent-level**. Several
sessions of the same agent commit into the same checkout, and nothing in the
repo distinguishes them. Add a trailer to every commit:

```
Session: <session-id>
```

Read it back with `git log -1 --format=%b`.

### Why

On 2026-07-23, commit `387732a` landed on `feat/release-authorization-gate`
signed `Mochi <mochi@kilokaki>` ten minutes after the previous commit, by a
session that had no record of making it. Identifying the author took a sweep of
transcript stores outside the repo. The signature was correct and still could
not answer the question being asked.

### What this is NOT

- **Not verification.** The trailer is self-reported. A session that guesses its
  own id writes a confident wrong answer, the same failure shape as a
  self-reported `updatedAt` that a filesystem `mtime` contradicts. Treat it as a
  breadcrumb for correlating against transcript stores, never as evidence.
- **Not a substitute for `user.email`.** Set that too. Keeping the identity
  configured per checkout is correct — the 2026-07-23 alarm that suggested
  otherwise rested on a misread of `git log --format=%ce`, which reports
  *history* (much of it arriving by fetch) rather than a census of local writes.
  Intersect with reflog `commit:` events to get the latter.
- **Not `user.useConfigOnly`.** That makes a *cross-agent* writer declare itself.
  The realistic failure is the *same* agent in a different session, which would
  supply the right identity and pass — so it fails closed on sessions that
  forget while remaining blind to the case that actually occurs.
