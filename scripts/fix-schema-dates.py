#!/usr/bin/env python3
"""Repair blog JSON-LD dates to match each post's first git commit.

Companion to check-schema-dates.py — same first_commit() logic, same rule:
datePublished == date of the post's FIRST commit (MEMORY.md, 2026-06-05).
Run the checker after this; it should exit 0.

Dry-run by default. Pass --apply to write.

What it will NOT do, deliberately:

  TZ artifacts are skipped. schema=UTC vs git=SGT is two clocks disagreeing,
  not a wrong date. The checker classifies these; we honour that.

  dateModified is only ever lifted, never lowered. Setting datePublished to an
  earlier fact can leave dateModified behind it, which is incoherent (modified
  before published). We raise it to match and otherwise leave it alone. The
  corpus-wide fact that dateModified ALSO carries plan-dates is a separate
  problem and not this script's business.
"""
import argparse
import datetime
import glob
import json
import os
import re
import subprocess

STUB_BYTES = 2000
LD = r'<script type="application/ld\+json">(.*?)</script>'


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
    fixed = added = lifted = skipped_tz = 0

    for path in sorted(glob.glob("blog/*.html")):
        name = os.path.basename(path)
        if os.path.getsize(path) < STUB_BYTES or name == "index.html":
            continue
        html = open(path, encoding="utf-8").read()
        commit = first_commit(path)
        if commit is None:
            continue
        local = commit.date().isoformat()
        utc = (commit - commit.utcoffset()).date().isoformat()
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
        if published == utc:
            skipped_tz += 1
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
          f"{lifted} dateModified lifted, {skipped_tz} TZ skipped")
    print(">>> DRY RUN — nothing written. Pass --apply to write." if not args.apply else ">>> WRITTEN.")


if __name__ == "__main__":
    main()
