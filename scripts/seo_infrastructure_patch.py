#!/usr/bin/env python3
"""
SEO Infrastructure Patch — Batch 1

Patches all blog HTML files with:
1. <link rel="canonical"> — if missing
2. JSON-LD BlogPosting schema — if missing
3. <meta property="og:image"> — if missing

Idempotent: safe to re-run. Non-destructive: only adds, never removes.
"""

import json
import re
import sys
from pathlib import Path

BLOG_DIR = Path(__file__).resolve().parent.parent / "blog"
BASE_URL = "https://kilokaki.com"
DEFAULT_OG_IMAGE = f"{BASE_URL}/og-blog-default.png"


def extract_title(html: str) -> str:
    """Extract text from <title> tag, strip ' — KiloKaki Blog' suffix."""
    m = re.search(r'<title>(.*?)</title>', html, re.DOTALL)
    if not m:
        return ""
    title = m.group(1).strip()
    # Strip common suffixes
    for suffix in [" — KiloKaki Blog", " - KiloKaki Blog"]:
        if title.endswith(suffix):
            title = title[: -len(suffix)].strip()
    return title


def extract_description(html: str) -> str:
    """Extract content from <meta name='description'>."""
    m = re.search(r'<meta\s+name="description"\s+content="(.*?)"', html)
    if m:
        return m.group(1).strip()
    # Also try reversed attribute order
    m = re.search(r'<meta\s+content="(.*?)"\s+name="description"', html)
    if m:
        return m.group(1).strip()
    return ""


def extract_date_published(html: str) -> str:
    """Extract datePublished from existing JSON-LD (Article or BlogPosting)."""
    # Find all JSON-LD blocks
    for m in re.finditer(
        r'<script\s+type="application/ld\+json">(.*?)</script>', html, re.DOTALL
    ):
        try:
            data = json.loads(m.group(1))
            dp = data.get("datePublished", "")
            if dp:
                return dp
        except json.JSONDecodeError:
            continue
    return ""


def build_blogposting(headline: str, description: str, date_published: str, filename: str) -> str:
    """Build the BlogPosting JSON-LD block."""
    url = f"{BASE_URL}/blog/{filename}"
    data = {
        "@context": "https://schema.org",
        "@type": "BlogPosting",
        "headline": headline,
        "description": description,
        "datePublished": date_published if date_published else "",
        "url": url,
        "publisher": {
            "@type": "Organization",
            "name": "KiloKaki",
            "url": BASE_URL,
            "logo": {
                "@type": "ImageObject",
                "url": f"{BASE_URL}/logo.png",
            },
        },
        "author": {
            "@type": "Organization",
            "name": "KiloKaki",
            "url": BASE_URL,
        },
    }
    # Remove empty datePublished if not found
    if not date_published:
        del data["datePublished"]

    json_str = json.dumps(data, indent=2, ensure_ascii=False)
    return f'  <script type="application/ld+json">\n{json_str}\n  </script>'


def patch_file(filepath: Path) -> dict:
    """Patch a single HTML file. Returns dict of changes made."""
    html = filepath.read_text(encoding="utf-8")
    filename = filepath.name
    changes = {"canonical": False, "blogposting": False, "ogimage": False}

    # --- 1. Canonical URL ---
    if 'rel="canonical"' not in html:
        canonical = f'  <link rel="canonical" href="{BASE_URL}/blog/{filename}">'
        # Insert after the last <meta> tag in <head>
        meta_positions = [m.end() for m in re.finditer(r'<meta\b[^>]*>', html)]
        if meta_positions:
            # Find last meta that's before </head>
            last_meta_end = meta_positions[-1]
            # Insert after trailing whitespace on the same line
            rest = html[last_meta_end:]
            line_end = rest.find("\n")
            if line_end == -1:
                insert_pos = last_meta_end
            else:
                insert_pos = last_meta_end + line_end + 1
            html = html[:insert_pos] + canonical + "\n" + html[insert_pos:]
        changes["canonical"] = True

    # --- 2. og:image ---
    if 'property="og:image"' not in html:
        og_image = f'  <meta property="og:image" content="{DEFAULT_OG_IMAGE}">'
        # Insert before </head>
        html = html.replace("</head>", og_image + "\n</head>")
        changes["ogimage"] = True

    # --- 3. BlogPosting JSON-LD ---
    if '"BlogPosting"' not in html:
        headline = extract_title(html)
        description = extract_description(html)
        date_published = extract_date_published(html)
        blogposting_block = build_blogposting(headline, description, date_published, filename)
        # Insert before </head>
        html = html.replace("</head>", blogposting_block + "\n</head>")
        changes["blogposting"] = True

    # Only write if anything changed
    if any(changes.values()):
        filepath.write_text(html, encoding="utf-8")

    return changes


def main():
    html_files = sorted(BLOG_DIR.glob("*.html"))
    # Exclude index.html
    html_files = [f for f in html_files if f.name != "index.html"]

    if not html_files:
        print("ERROR: No blog HTML files found.")
        sys.exit(1)

    print(f"Found {len(html_files)} blog articles to process.\n")

    stats = {
        "total": len(html_files),
        "canonical_added": 0,
        "blogposting_added": 0,
        "ogimage_added": 0,
        "skipped": 0,
    }

    for filepath in html_files:
        changes = patch_file(filepath)
        any_change = any(changes.values())
        if any_change:
            change_str = ", ".join(k for k, v in changes.items() if v)
            print(f"  ✓ {filepath.name}: {change_str}")
        else:
            print(f"  — {filepath.name}: already complete")
            stats["skipped"] += 1

        if changes["canonical"]:
            stats["canonical_added"] += 1
        if changes["blogposting"]:
            stats["blogposting_added"] += 1
        if changes["ogimage"]:
            stats["ogimage_added"] += 1

    # --- Verification ---
    print("\n--- Verification ---")
    canonical_count = 0
    blogposting_count = 0
    ogimage_count = 0

    for filepath in html_files:
        content = filepath.read_text(encoding="utf-8")
        if 'rel="canonical"' in content:
            canonical_count += 1
        if '"BlogPosting"' in content:
            blogposting_count += 1
        if 'property="og:image"' in content:
            ogimage_count += 1

    print(f"  canonical: {canonical_count}/{stats['total']}")
    print(f"  BlogPosting: {blogposting_count}/{stats['total']}")
    print(f"  og:image: {ogimage_count}/{stats['total']}")

    all_ok = (
        canonical_count == stats["total"]
        and blogposting_count == stats["total"]
        and ogimage_count == stats["total"]
    )

    print(f"\n{'✅ ALL 48 articles patched successfully!' if all_ok else '⚠️  Some articles still missing items.'}")
    print(f"  Added: canonical={stats['canonical_added']}, BlogPosting={stats['blogposting_added']}, og:image={stats['ogimage_added']}")
    print(f"  Skipped (already complete): {stats['skipped']}")

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
