#!/usr/bin/env python3
"""
Batch 1 SEO infrastructure fix for all 48 blog articles.

Current state:
- 36 files have BOTH Article AND BlogPosting JSON-LD (duplicate) → clean to BlogPosting only
- 1 file (the-real-reason-people-quit-food-logging.html) has NO JSON-LD → add BlogPosting
- 10 files already have BlogPosting only → skip
- index.html is a listing page → has WebPage (correct), just needs canonical + og:image

Dry-run first. Pass --apply to write changes.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

BLOG_DIR = Path(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) / "blog"
DEFAULT_OG_IMAGE = "https://kilokaki.com/og-blog-default.png"
BASE_URL = "https://kilokaki.com/blog/"


def extract_fields_from_json_ld(json_text):
    """Extract key fields from a JSON-LD block."""
    fields = {}
    for key in ['headline', 'description', 'datePublished', 'dateModified', 'articleSection']:
        m = re.search(rf'"{re.escape(key)}"\s*:\s*"((?:[^"\\]|\\.)*)"', json_text)
        if m:
            val = m.group(1)
            val = val.replace('\\"', '"').replace('\\u2192', '→').replace('\\n', ' ').strip()
            fields[key] = val
    return fields


def build_blogposting_json_ld(fields, filename):
    """Build clean BlogPosting JSON-LD."""
    obj = {
        "@context": "https://schema.org",
        "@type": "BlogPosting",
        "headline": fields.get("headline", ""),
        "description": fields.get("description", ""),
        "datePublished": fields.get("datePublished", ""),
        "dateModified": fields.get("dateModified", ""),
        "url": f"{BASE_URL}{filename}",
        "author": {
            "@type": "Organization",
            "name": "KiloKaki",
            "url": "https://kilokaki.com"
        },
        "publisher": {
            "@type": "Organization",
            "name": "KiloKaki",
            "url": "https://kilokaki.com",
            "logo": {
                "@type": "ImageObject",
                "url": "https://kilokaki.com/logo.png"
            }
        },
        "mainEntityOfPage": {
            "@type": "WebPage",
            "@id": f"{BASE_URL}{filename}"
        },
        "articleSection": fields.get("articleSection", "Food Logging"),
        "inLanguage": "en-SG"
    }
    return json.dumps(obj, ensure_ascii=False)


def fix_duplicate_schema(html, filename):
    """Remove duplicate Article JSON-LD, keep only BlogPosting. Returns (html, changed)."""
    # Find all JSON-LD blocks
    pattern = r'<script\s+type="application/ld\+json">(.*?)</script>'
    blocks = list(re.finditer(pattern, html, re.DOTALL))

    if len(blocks) <= 1:
        return html, False  # Only one block, nothing to deduplicate

    # Find which blocks are Article vs BlogPosting
    article_blocks = []
    blogposting_blocks = []

    for m in blocks:
        content = m.group(1)
        if '"BlogPosting"' in content:
            blogposting_blocks.append(m)
        elif '"Article"' in content:
            article_blocks.append(m)

    if not article_blocks:
        return html, False  # No Article duplicates

    if blogposting_blocks:
        # Keep the BlogPosting block, remove all Article blocks
        # Merge fields: prefer BlogPosting fields, fill from Article if missing
        bp_fields = extract_fields_from_json_ld(blogposting_blocks[0].group(1))
        art_fields = extract_fields_from_json_ld(article_blocks[0].group(1))

        # Fill gaps in BlogPosting from Article
        for key in ['headline', 'description', 'datePublished', 'dateModified', 'articleSection']:
            if not bp_fields.get(key) and art_fields.get(key):
                bp_fields[key] = art_fields[key]

        new_json_ld = build_blogposting_json_ld(bp_fields, filename)
        replacement = f'<script type="application/ld+json">{new_json_ld}</script>'

        # Replace BlogPosting block with merged version
        html = html.replace(blogposting_blocks[0].group(0), replacement)

        # Remove all Article blocks
        for m in article_blocks:
            html = html.replace(m.group(0), '')

        # Clean up any double newlines left behind
        html = re.sub(r'\n\s*\n\s*\n', '\n\n', html)
        return html, True
    else:
        # Has Article but no BlogPosting — convert to BlogPosting
        art_fields = extract_fields_from_json_ld(article_blocks[0].group(1))
        new_json_ld = build_blogposting_json_ld(art_fields, filename)
        replacement = f'<script type="application/ld+json">{new_json_ld}</script>'
        html = html.replace(article_blocks[0].group(0), replacement)
        return html, True


def fix_add_json_ld(html, filename):
    """Add BlogPosting JSON-LD to a file that has none."""
    title_match = re.search(r'<title>([^<]+)</title>', html)
    headline = title_match.group(1).replace(' — KiloKaki Blog', '').strip() if title_match else ""

    desc_match = re.search(r'<meta\s+name="description"\s+content="([^"]+)"', html)
    description = desc_match.group(1) if desc_match else ""

    new_json_ld = build_blogposting_json_ld({
        "headline": headline,
        "description": description,
        "articleSection": "Food Logging"
    }, filename)

    script_tag = f'  <script type="application/ld+json">{new_json_ld}</script>\n'
    html = html.replace('</head>', f'{script_tag}</head>')
    return html, True


def fix_canonical(html, filename):
    """Add canonical link if missing."""
    if re.search(r'<link\s+rel="canonical"', html):
        return html, False

    canonical_url = f"{BASE_URL}{filename}"
    canonical_tag = f'  <link rel="canonical" href="{canonical_url}">\n'
    html = html.replace('</head>', f'{canonical_tag}</head>')
    return html, True


def fix_og_image(html):
    """Add og:image if missing."""
    og_img_match = re.search(r'<meta\s+property="og:image"\s+content="[^"]*"', html)
    if og_img_match:
        return html, False

    og_type_pattern = r'(<meta\s+property="og:type"[^>]*>)'
    m = re.search(og_type_pattern, html)
    if m:
        tag = f'\n  <meta property="og:image" content="{DEFAULT_OG_IMAGE}">'
        html = html.replace(m.group(1), m.group(1) + tag)
        return html, True

    return html, False


def process_file(filepath, apply=False):
    """Process a single HTML file."""
    filename = os.path.basename(filepath)

    with open(filepath, 'r', encoding='utf-8') as f:
        html = f.read()

    original = html
    changes = []

    # Skip index.html for JSON-LD changes (it's a listing page with WebPage type)
    if filename == 'index.html':
        html, did_change = fix_canonical(html, filename)
        if did_change:
            changes.append("canonical added")
        html, did_change = fix_og_image(html)
        if did_change:
            changes.append("og:image added")
    else:
        # Check for duplicate schema (Article + BlogPosting)
        json_ld_pattern = r'<script\s+type="application/ld\+json">.*?</script>'
        json_ld_blocks = re.findall(json_ld_pattern, html, re.DOTALL)

        has_article = any('"Article"' in b for b in json_ld_blocks)
        has_blogposting = any('"BlogPosting"' in b for b in json_ld_blocks)

        if has_article and has_blogposting:
            # Duplicate — clean up
            html, did_change = fix_duplicate_schema(html, filename)
            if did_change:
                changes.append("duplicate schema cleaned → BlogPosting only")
        elif has_article and not has_blogposting:
            # Only Article — convert to BlogPosting
            html, did_change = fix_duplicate_schema(html, filename)
            if did_change:
                changes.append("Article → BlogPosting")
        elif not has_article and not has_blogposting:
            # No JSON-LD at all — add BlogPosting
            html, did_change = fix_add_json_ld(html, filename)
            if did_change:
                changes.append("JSON-LD BlogPosting added")
        # else: already has BlogPosting only, nothing to do for schema

    if html != original:
        if apply:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(html)
        return filename, changes, True
    return filename, [], False


def main():
    parser = argparse.ArgumentParser(description='Batch 1 SEO fix for blog articles')
    parser.add_argument('--apply', action='store_true', help='Write changes to files (default: dry-run)')
    args = parser.parse_args()

    blog_dir = BLOG_DIR
    if not blog_dir.exists():
        print(f"ERROR: Blog directory not found: {blog_dir}")
        sys.exit(1)

    html_files = sorted([str(f) for f in blog_dir.glob("*.html")])

    print(f"{'DRY RUN' if not args.apply else 'APPLYING'} — Processing {len(html_files)} blog articles\n")

    total_changes = 0
    schema_cleaned = 0
    schema_added = 0
    canonical_added = 0
    ogimg_added = 0
    files_modified = 0

    for filepath in html_files:
        filename, changes, was_modified = process_file(filepath, apply=args.apply)
        if was_modified:
            files_modified += 1
            change_str = ', '.join(changes)
            prefix = "  ✓" if args.apply else "  →"
            print(f"{prefix} {filename}: {change_str}")
            for c in changes:
                total_changes += 1
                if "schema cleaned" in c or "Article →" in c:
                    schema_cleaned += 1
                if "BlogPosting added" in c:
                    schema_added += 1
                if "canonical" in c:
                    canonical_added += 1
                if "og:image" in c:
                    ogimg_added += 1

    print(f"\n{'Applied' if args.apply else 'Would apply'} changes to {files_modified}/{len(html_files)} files:")
    print(f"  Duplicate schema cleaned:  {schema_cleaned}")
    print(f"  JSON-LD added:             {schema_added}")
    print(f"  Canonical added:           {canonical_added}")
    print(f"  og:image added:            {ogimg_added}")
    print(f"  Total fixes:               {total_changes}")

    if not args.apply:
        print(f"\nPass --apply to write changes.")


if __name__ == "__main__":
    main()
