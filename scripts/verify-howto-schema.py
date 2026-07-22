#!/usr/bin/env python3
"""Independent verifier: reads how-to/*.html fresh, parses JSON-LD, asserts.
Takes a directory so it can be pointed at a mutated copy to prove it goes RED."""
import re, glob, os, json, sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
PUB, MOD = "2026-04-19", "2026-06-07"
fails, ran = [], 0

def check(name, thunk):
    global ran
    ran += 1
    try:
        ok, detail = thunk()
    except Exception as e:
        ok, detail = False, f"{type(e).__name__}: {e}"
    if not ok:
        fails.append(f"{name}: {detail}")
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"  -- {detail}"))

allf = sorted(glob.glob(os.path.join(root, "how-to/*.html")))
scope = [f for f in allf if os.path.basename(f) != "index.html"]

check("scope is exactly 13 non-index how-to pages",
      lambda: (len(scope) == 13, f"got {len(scope)}"))

check("index.html carries NO JSON-LD (Coco: hub page, out of scope)",
      lambda: (('ld+json' not in open(os.path.join(root, "how-to/index.html")).read()),
               "index.html has JSON-LD"))

for f in scope:
    b = os.path.basename(f)
    def mk(f=f, b=b):
        s = open(f).read()
        blocks = re.findall(r'<script type="application/ld\+json">(.*?)</script>', s, re.S)
        if len(blocks) != 1:
            return False, f"{len(blocks)} ld+json blocks"
        d = json.loads(blocks[0])          # raises -> FAIL, not crash
        if d.get("@type") != "Article":
            return False, f"@type={d.get('@type')!r}"
        if d.get("datePublished") != PUB:
            return False, f"datePublished={d.get('datePublished')!r} != {PUB}"
        if d.get("dateModified") != MOD:
            return False, f"dateModified={d.get('dateModified')!r} != {MOD}"
        if d.get("url") != f"https://kilokaki.com/how-to/{b}":
            return False, f"url={d.get('url')!r}"
        h1 = re.search(r'<h1[^>]*>(.*?)</h1>', s, re.S)
        want = re.sub(r'<[^>]+>', '', h1.group(1)).strip()
        if d.get("headline") != want:
            return False, f"headline={d.get('headline')!r} != h1 {want!r}"
        if not d.get("description"):
            return False, "empty description"
        return True, ""
    check(f"{b}", mk)

print(f"\nran={ran}  failed={len(fails)}")
sys.exit(1 if fails else 0)
