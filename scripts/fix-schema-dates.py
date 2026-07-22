#!/usr/bin/env python3
"""Repair blog JSON-LD dates to match each post's first git commit.

Companion to check-schema-dates.py — same first_commit() logic, same rule:
datePublished == date of the post's FIRST commit (MEMORY.md, 2026-06-05).
Run the checker after this; it should exit 0.

Dry-run by default. Pass --apply to write.

What it will NOT do, deliberately:

  Adopted posts are REFUSED, never rewritten. blog/adopted.json names the posts
  that were live on production before git ever saw them; for those, the first
  commit is a copy date and writing it destroys the truer value. The set is
  imported from check-schema-dates.load_adopted() — one definition, one answer.
  If the file is absent or unparseable this script refuses to run at all.

  It used to say "TZ artifacts are skipped ... the checker classifies these; we
  honour that." Both halves were false. This script never imported the checker's
  classification; it carried its OWN copy of the UTC test, so the two could drift
  and a reader auditing the checker would have audited the wrong file. And the
  test itself could not tell a clock offset from an adoption lag — it exonerated
  three adopted posts and rewrote a fourth purely on the hour their adopting
  commits happened to run. The copy is deleted, not repaired.

  dateModified is only ever lifted, never lowered. Setting datePublished to an
  earlier fact can leave dateModified behind it, which is incoherent (modified
  before published). We raise it to match and otherwise leave it alone. The
  corpus-wide fact that dateModified ALSO carries plan-dates is a separate
  problem and not this script's business.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys

LD = r'<script type="application/ld\+json">(.*?)</script>'

# Import the population rule rather than restating it. Two copies of "what counts
# as a post" is how the count floated in the first place (53/54, 67/85), and how
# three deploy.sh copies drifted apart unnoticed. One definition, one number.
_spec = importlib.util.spec_from_file_location(
    "check_schema_dates",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-schema-dates.py"),
)
_checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_checker)
population = _checker.population
load_adopted = _checker.load_adopted


def first_commit(path):
    out = subprocess.run(
        ["git", "log", "--diff-filter=A", "--follow", "--format=%ad", "--date=iso", "--", path],
        capture_output=True, text=True,
    ).stdout.strip()
    if not out:
        return None
    date, time, off = out.split("\n")[-1].split()
    return datetime.datetime.fromisoformat(f"{date}T{time}{off[:3]}:{off[3:]}")


def strip_suffix(title):
    for suf in (" | KiloKaki", " — KiloKaki Blog", " - KiloKaki Blog", " — KiloKaki", " | KiloKaki Blog"):
        if title.endswith(suf):
            return title[: -len(suf)]
    return title


def build_block(html, published):
    """Construct a JSON-LD block for a post that has none, from its own head tags."""
    title = re.search(r"<title>(.*?)</title>", html, re.S)
    desc = re.search(r'<meta name="description" content="(.*?)"', html, re.S)
    canon = re.search(r'<link rel="canonical" href="(.*?)"', html, re.S)
    if not (title and desc and canon):
        return None
    data = {
        "@context": "https://schema.org",
        "@type": "BlogPosting",
        "headline": strip_suffix(title.group(1).strip()),
        "description": desc.group(1).strip(),
        "url": canon.group(1).strip(),
        "datePublished": published,
        "dateModified": published,
        "author": {"@type": "Organization", "name": "KiloKaki", "url": "https://kilokaki.com"},
        "publisher": {
            "@type": "Organization",
            "name": "KiloKaki",
            "url": "https://kilokaki.com",
            "logo": {"@type": "ImageObject", "url": "https://kilokaki.com/logo.png"},
        },
        "mainEntityOfPage": {"@type": "WebPage", "@id": canon.group(1).strip()},
        "inLanguage": "en-SG",
    }
    body = json.dumps(data, indent=2, ensure_ascii=False)
    body = "\n".join("  " + ln for ln in body.split("\n"))
    return f'<script type="application/ld+json">\n{body}\n  </script>\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir)
    os.chdir(root)
    fixed = added = lifted = refused = 0

    # --- Adoption guard. Fails closed, and runs before anything is computed. ---
    #
    # Every write below sets datePublished from git. For a post that was published
    # on production and adopted into the repo later, git's first commit is the date
    # SOMEBODY COPIED THE FILE, and writing it destroys the truer value to satisfy a
    # false premise. blog/how-to-log-kopi-and-teh.html is the live case: this script
    # would rewrite 2026-07-21 -> 2026-07-22 AND lift dateModified after it, so two
    # true fields for one wrong reason.
    #
    # Until 2026-07-22 the three OTHER adopted posts were spared here, but only by
    # accident: their adopting commit landed at 00:03 SGT, so its UTC date happened
    # to equal the schema date and the old TZ test read that coincidence as "two
    # clocks disagreeing". kopi's adoption ran at 11:08 and was not spared. Same
    # defect, same shape, opposite outcome, decided by the hour on the clock.
    #
    # ABSENT is UNKNOWN, never "no adoptions to spare" — refuse rather than run
    # unguarded over a corpus we cannot classify.
    try:
        adopted = load_adopted()
    except json.JSONDecodeError as exc:
        print(f"!! REFUSING TO RUN: {_checker.ADOPTED} is present but unparseable: {exc}")
        print("!! An unreadable declaration file must not degrade into 'nothing to spare'.")
        return 2
    if adopted is None:
        print(f"!! REFUSING TO RUN: {_checker.ADOPTED} is ABSENT.")
        print("!! Without it this script cannot tell an adopted post from a published one,")
        print("!! and every adopted post is a date it would overwrite with a copy date.")
        return 2
    print(f"→ Adoption guard: {len(adopted)} declared adoption(s) will be REFUSED, not rewritten.")

    for path in population()[0]:
        name = os.path.basename(path)
        if path in adopted:
            decl = adopted[path]
            refused += 1
            print(f"  REFUSED   {name:<52} adopted @ {decl['adopting_commit']}, "
                  f"declared {decl['datePublished']} — git date is a copy date, not a publish date")
            continue
        html = open(path, encoding="utf-8").read()
        commit = first_commit(path)
        if commit is None:
            continue
        local = commit.date().isoformat()
        block = re.search(LD, html, re.S)

        if not block:
            new = build_block(html, local)
            if not new:
                print(f"  SKIP (no head tags to build from) {name}")
                continue
            out = html.replace("</head>", f"  {new}</head>", 1)
            if out == html:
                print(f"  SKIP (no </head>) {name}")
                continue
            added += 1
            print(f"  + SCHEMA  {name:<52} datePublished {local}")
            if args.apply:
                open(path, "w", encoding="utf-8").write(out)
            continue

        raw = block.group(1)
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            print(f"  SKIP (invalid JSON) {name}")
            continue
        published = data.get("datePublished")
        if not published or published == local:
            continue

        new_raw = re.sub(r'("datePublished"\s*:\s*")[^"]*(")', rf"\g<1>{local}\g<2>", raw)
        note = ""
        modified = data.get("dateModified")
        if modified and modified < local:
            new_raw = re.sub(r'("dateModified"\s*:\s*")[^"]*(")', rf"\g<1>{local}\g<2>", new_raw)
            lifted += 1
            note = f"  (dateModified {modified} -> {local})"
        out = html.replace(raw, new_raw, 1)
        fixed += 1
        print(f"  ~ DATE    {name:<52} {published} -> {local}{note}")
        if args.apply:
            open(path, "w", encoding="utf-8").write(out)

    print(f"\n>>> {fixed} datePublished fixed, {added} schema blocks added, "
          f"{lifted} dateModified lifted, {refused} adopted REFUSED")
    print(">>> DRY RUN — nothing written. Pass --apply to write." if not args.apply else ">>> WRITTEN.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
