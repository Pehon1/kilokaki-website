# Provenance ledger

**What this is:** the drift audit's memory. It is not documentation, and it does not
need a human reader to earn its place.

`scripts/check-deploy-integrity.sh` and the prod drift audit answer one question —
*is there content on production we cannot account for?* — by diffing live bytes
against `origin/main`. **Committing unexplained production content into the repo
makes that question return "no" without anyone having answered it.** Two of the nine
files in the audit's current blind spot got there exactly that way.

So: every time we absorb bytes that originated on production, the row goes here. The
audit stays quiet, the question stays open, and the open question stays findable.

## Rules

1. **Register the ROUTE, not just the source.** *Absorbed from prod* and *published
   by scp* are different facts. Only the second names a hole the audit exists to find.
2. **`escalation` must be a channel + message id, or the literal `UNESCALATED`.**
   A believed escalation is not an escalation. (2026-09-17: a row in Nori's work
   queue claimed a delivery "with a receipt" that never existed; the word was in the
   sentence and the receipt was not.)
3. **A commit that changes what the drift audit will report must say so in its body.**
   Cheap, survives the next reader, and bans nothing legitimate.
4. **Absorption is not the same as derivation.** A commit that recomputes a value from
   a rule (e.g. `datePublished` = first git commit date) takes its bytes from the repo
   and does not belong here, even when the result happens to match production.

## Schema — what is the key

**The key is the absorbing COMMIT SHA. It is never the author identity.**

State this or the first person to `group by` gets a different answer than whoever
wrote the rows. Author identity cannot be a key in this repo:

- **89% of `origin/main` is authored by a synthesized identity** — git invents
  `Pe Hon Ong <pehonong@*.local>` from the OS account and the *current hostname*, so
  it is a class spanning three hostnames, not a string.
- Agent identities have spelling variants. `Nori <nori@kilokaki>` (9),
  `nori <nori@kilokaki>` (2) and `Nori <nori@kilokaki.local>` (1) are one actor;
  **two collapse on email and one does not.** Keyed on the author string that is
  three actors, keyed on email it is two, and neither answer is wrong.

So `absorbed by` carries the sha as the key and the identity as a *note*, explicitly
marked when the field is synthesized and therefore names nobody. `check-provenance.sh`
resolves every row through `git cat-file -e <sha>^{commit}` and never parses a name.

## Rows

| path | route | absorbed by | date | escalation | open question |
|---|---|---|---|---|---|
| `blog/how-to-log-durian.html` | absorbed from prod — "rescue", origin had no copy | `d31cca9` (author field synthesized: `Pe Hon Ong`, actor unknown) | 2026-07-16 | `UNESCALATED` | How did Blog #72 reach prod without ever being in git? Found by `check-provenance.sh` on its first run, 2026-09-17. |
| `blog/how-to-log-kopi-and-teh.html` | absorbed from prod — "adopt", single commit, came from prod | `7ece2bb` (author field synthesized: `Pe Hon Ong`, actor unknown) | 2026-07-22 | `UNESCALATED` | Same question, same route unknown. Found by `check-provenance.sh` on its first run, 2026-09-17. |
| `blog/meal-prep-sunday-playbook.html` | absorbed from prod — origin had no copy | `fb153ab` (Mochi) | 2026-08-05 | `UNESCALATED` | How did it reach prod? The file's only commit came *from* production, and prod still does not match it. |
| `blog/how-to-log-mala-xiang-guo.html` | absorbed from prod — zero git provenance fleet-wide before this commit | `2b41803` (Nori) | 2026-09-17 | `UNESCALATED` — bro owns raising it with Pehon after the credential-rotation decision lands | Who published it, and by what route? Live 200, no repo history, no deploy record. |

## Known publish routes

| route | gated? | leaves a record? |
|---|---|---|
| `scripts/deploy.sh` | yes — `release-gate.sh` aborts without an annotated `release/*` tag on origin | stdout only; **no durable receipt** |
| `scp` / `ssh` direct to `~/public_html/` using `~/.config/kilokaki-site/deploy.env` | **no** | **none at all** |

🔴 **The unsanctioned route is the one with no gate and no artifact.** Measured twice in
Nori's session history (June 2026, 2026-09-15). On 2026-09-15 the sanctioned path would
have failed closed — no release tag pointed at `21c075a` — and the ungated path worked
first try.

**A guard that only binds the compliant path converts itself into a recommendation for
the non-compliant one.** Closing that route is server-side and is Pehon's call.
