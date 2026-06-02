#!/usr/bin/env python3
"""SEO infrastructure patch for blog articles.

Adds to each HTML file in the blog directory:
1. <link rel="canonical"> — if missing
2. JSON-LD BlogPosting schema — only if no JSON-LD exists at all
3. <meta property="og:image"> — if missing

Idempotent: safe to re-run (checks before adding each element).
Non-destructive: only inserts, never removes or modifies existing content.
"""

import os
import re
import sys
import json
from pathlib import Path

BLOG_DIR = Path(__file__).resolve().parent.parent / "blog"
SITE_URL = "https://kilokaki.com"
DEFAULT_OG_IMAGE = f"{SITE_URL}/og-blog-default.png"


def extract_title(html: str) -> str:
    """Extract text from <title> tag, strip ' — KiloKaki Blog' suffix."""
    m = re.search(r'<title[^>]*>(.*?)</title>', html, re.DOTALL)
    if not m:
        return ""
    title = m.group(1).strip()
    title = re.sub(r'\s*—\s*KiloKaki\s*Blog\s*$', '', title)
    return title


def extract_description(html: str) -> str:
    """Extract content from <meta name="description"> tag."""
    m = re.search(r'<meta\s+name=["\']description["\']\s+content=["\'](.*?)["\']', html, re.IGNORECASE)
    if not m:
        m = re.search(r'<meta\s+content=["\'](.*?)["\']\s+name=["\']description["\']', html, re.IGNORECASE)
    if not m:
        return ""
    return m.group(1).strip()


def extract_date_published(html: str) -> str:
    """Extract datePublished from existing JSON-LD, or return empty string."""
    m = re.search(r'<script\s+type=["\']application/ld\+json["\']>(.*?)</script>', html, re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(1))
            return data.get("datePublished", "")
        except (json.JSONDecodeError, AttributeError):
            pass
    return ""


def has_canonical(html: str) -> bool:
    return bool(re.search(r'<link\s+[^>]*rel=["\']canonical["\']', html, re.IGNORECASE))


def has_jsonld(html: str) -> bool:
    return bool(re.search(r'<script\s+type=["\']application/ld\+json["\']', html, re.IGNORECASE))


def has_og_image(html: str) -> bool:
    return bool(re.search(r'<meta\s+[^>]*property=["\']og:image["\']', html, re.IGNORECASE))


def is_redirect_stub(html: str) -> bool:
    """Detect <meta http-equiv='refresh'> redirect stubs."""
    return bool(re.search(r'<meta\s+[^>]*http-equiv=["\']refresh["\']', html, re.IGNORECASE))


def canonical_tag(url: str) -> str:
    return f'  <link rel="canonical" href="{url}">'


def jsonld_blogposting(headline: str, description: str, date_published: str, url: str) -> str:
    schema = {
        "@context": "https://schema.org",
        "@type": "BlogPosting",
        "headline": headline,
        "description": description,
        "datePublished": date_published,
        "url": url,
        "publisher": {
            "@type": "Organization",
            "name": "KiloKaki",
            "url": SITE_URL,
            "logo": {"@type": "ImageObject", "url": f"{SITE_URL}/logo.png"}
        },
        "author": {
            "@type": "Organization",
            "name": "KiloKaki",
            "url": SITE_URL
        }
    }
    inner = json.dumps(schema, indent=4, ensure_ascii=False)
    return f'  <script type="application/ld+json">\n  {inner}\n  </script>'


def og_image_tag() -> str:
    return f'  <meta property="og:image" content="{DEFAULT_OG_IMAGE}">'


def inject_canonical(html: str, tag: str) -> str:
    """Inject canonical after last <meta> tag in <head>."""
    meta_matches = list(re.finditer(r'<meta\b[^>]*>', html, re.IGNORECASE))
    if meta_matches:
        last_meta = meta_matches[-1]
        end = last_meta.end()
        return html[:end] + "\n" + tag + html[end:]
    # Fallback: before </head>
    return html.replace("</head>", tag + "\n</head>", 1)


def inject_jsonld(html: str, tag: str) -> str:
    """Inject JSON-LD before </head>."""
    return html.replace("</head>", tag + "\n</head>", 1)


def inject_og_image(html: str, tag: str) -> str:
    """Inject og:image after the last <meta property="og:..."> tag."""
    og_matches = list(re.finditer(r'<meta\s+[^>]*property=["\']og:[^"\']+["\'][^>]*>', html, re.IGNORECASE))
    if og_matches:
        last_og = og_matches[-1]
        end = last_og.end()
        return html[:end] + "\n" + tag + html[end:]
    # Fallback: before </head>
    return html.replace("</head>", tag + "\n</head>", 1)


def process_file(filepath: Path) -> dict:
    """Process a single HTML file. Returns stats dict."""
    result = {"path": str(filepath.relative_to(filepath.parent.parent)), "changes": []}

    html = filepath.read_text(encoding="utf-8")
    original = html

    filename = filepath.stem  # without .html
    blog_url = f"{SITE_URL}/blog/{filename}.html"

    # Skip redirect stubs — they already canonicalize to the real article
    if is_redirect_stub(html):
        result["changes"].append("skipped (redirect stub)")
        return result

    # 1. Canonical
    if not has_canonical(html):
        html = inject_canonical(html, canonical_tag(blog_url))
        result["changes"].append("added canonical")

    # 2. JSON-LD BlogPosting (only if no JSON-LD exists at all)
    if not has_jsonld(html):
        headline = extract_title(original)  # extract from original content
        description = extract_description(original)
        date_published = extract_date_published(original)
        html = inject_jsonld(html, jsonld_blogposting(headline, description, date_published, blog_url))
        result["changes"].append("added BlogPosting JSON-LD")

    # 3. og:image
    if not has_og_image(html):
        html = inject_og_image(html, og_image_tag())
        result["changes"].append("added og:image")

    if html != original:
        filepath.write_text(html, encoding="utf-8")

    return result


def main():
    html_files = sorted(BLOG_DIR.glob("*.html"))
    # Skip index.html (blog listing page, not an article)
    html_files = [f for f in html_files if f.name != "index.html"]

    if not html_files:
        print(f"No HTML files found in {BLOG_DIR}")
        sys.exit(1)

    print(f"Processing {len(html_files)} blog articles in {BLOG_DIR}\n")

    total_changes = {"canonical": 0, "jsonld": 0, "og_image": 0}
    modified_count = 0

    for filepath in html_files:
        result = process_file(filepath)
        if result["changes"]:
            modified_count += 1
            for change in result["changes"]:
                if "canonical" in change:
                    total_changes["canonical"] += 1
                elif "BlogPosting" in change:
                    total_changes["jsonld"] += 1
                elif "og:image" in change:
                    total_changes["og_image"] += 1
            print(f"  {'  '.join(result['changes']):40s} | {result['path']}")

    print(f"\n{'='*60}")
    print(f"  Files processed: {len(html_files)}")
    print(f"  Files modified:  {modified_count}")
    print(f"  Canonical added:  {total_changes['canonical']}")
    print(f"  BlogPosting added: {total_changes['jsonld']}")
    print(f"  og:image added:   {total_changes['og_image']}")
    print(f"{'='*60}")

    # Verification: count files with each element (exclude redirect stubs)
    canonical_count = 0
    jsonld_count = 0
    og_image_count = 0
    article_count = 0
    for f in html_files:
        content = f.read_text(encoding="utf-8")
        if is_redirect_stub(content):
            continue  # redirect stubs canonicalize to real articles
        article_count += 1
        if has_canonical(content):
            canonical_count += 1
        if has_jsonld(content):
            jsonld_count += 1
        if has_og_image(content):
            og_image_count += 1

    print(f"\nVerification ({article_count} articles, excluding redirect stubs):")
    print(f"  Files with canonical:  {canonical_count}/{article_count}")
    print(f"  Files with JSON-LD:    {jsonld_count}/{article_count}")
    print(f"  Files with og:image:   {og_image_count}/{article_count}")

    # Check acceptance criteria
    all_pass = (canonical_count == article_count and
                jsonld_count == article_count and
                og_image_count == article_count)

    if all_pass:
        print(f"\n  ✅ All {article_count} articles pass acceptance criteria")
    else:
        missing = []
        if canonical_count < len(html_files):
            missing.append(f"canonical: {len(html_files) - canonical_count} files")
        if jsonld_count < len(html_files):
            missing.append(f"JSON-LD: {len(html_files) - jsonld_count} files")
        if og_image_count < len(html_files):
            missing.append(f"og:image: {len(html_files) - og_image_count} files")
        print(f"\n  ❌ Missing: {', '.join(missing)}")

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
