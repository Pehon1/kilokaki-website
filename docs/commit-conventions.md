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

## Enforcement

`scripts/hooks/commit-msg`, installed by `scripts/install-hooks.sh`.

The convention shipped on 2026-07-23 in `f0fe4ff` and **the very next commit on
main omitted the trailer** — 1 of 4 compliant, and the violation landed *after*
the rule. That is why there is a hook: a rule with no enforcement describes
intentions, and this repo already has ten test suites with zero runners.

### The hook appends; it does not reject

Deliberate. The trailer is self-reported and a session cannot always name
itself — on the day the convention shipped, the runtime reported one id while
the turn's output persisted under another. A rejecting hook would block every
commit from a session that cannot identify itself: fails closed on the common
case, blind to the case that matters. That is the `useConfigOnly` error again.

When no id is available the hook writes `Session: unknown`. An explicit
`unknown` beats an absent trailer, because a missing line cannot be
distinguished from a session that forgot, while `unknown` records that the
question was asked and could not be answered.

### Limits, stated rather than discovered

- **Git does not version `.git/hooks`.** The tracked hook is inert until
  `install-hooks.sh` copies it, and nothing runs that installer automatically.
  An uninstalled hook enforces nothing and the repo cannot tell you so.
- **The id is still self-reported.** The hook makes the trailer *present*, not
  *true*.
- **Where the ids disagree, carry both.** `Session:` for the runtime-reported
  id, `Session-Transcript:` for the one a transcript store can be grepped by.
  A visible mismatch is worth more than a confident single value.
