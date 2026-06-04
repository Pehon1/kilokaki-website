#!/usr/bin/env python3
"""SEO Sprint P2: Patch weak titles, fix HTML entities, remove brand suffixes.

Source: ~/.openclaw-nori/workspace/memory/seo-audit-2026-06-03.md
Non-destructive, idempotent. Skips redirect stubs.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

BLOG_DIR = Path(__file__).resolve().parent.parent / "blog"

# ── Title rewrites (17 weak titles from audit) ──
TITLE_FIXES = {
    "eating-healthy-gain-weight.html": "Why \"Eating Healthy\" Made Me Gain Weight (And How Food Logging Reveals Why)",
    "food-logging-psychology.html": "Why Food Logging Works When You Don't See Results",  # audit says keep URL, title OK
    "friction-problem-food-logging.html": "Why People Quit Food Logging (And How to Make It Stick)",
    "gym-intimidation-problem-food-logging.html": "The Gym Intimidation Problem: Why Tracking Food Before Workouts Is Hard",
    "one-tiny-change-method-food-logging.html": "The One-Tiny-Change Habit for Food Logging",
    "the-maintenance-trap-food-logging.html": "The Maintenance Trap: How Food Logging Keeps Weight Off",
    "the-mirror-effect-losing-weight-confidence.html": "The Mirror Effect: How Food Logging Changes Your Confidence",
    "the-restaurant-problem-food-logging.html": "The Restaurant Problem: Why Eating Out Breaks Your Food Logging Streak",
    "the-vacation-eating-problem.html": "The Vacation Eating Problem: How to Keep Logging While Traveling",
    "the-weekend-trap.html": "The Weekend Trap: Why Saturday Erases Your Food Logging Week",
    "what-six-months-looks-like.html": "What 6 Months of Food Logging Actually Looks Like (Real Data)",
    "the-all-or-nothing-mindset.html": "The All-or-Nothing Mindset: Why Going Perfect Made You Quit",
    "the-food-delivery-trap.html": "The Food Delivery Trap: Why GrabFood Undoes Your Best Week",
    "the-healthy-snack-problem.html": "The 'Healthy' Snack Problem: Why Good Food Still Made You Gain Weight",
    "the-plateau-problem.html": "The Plateau Problem: You've Been Logging for Months and the Scale Won't Move",
    "blog-why-people-stick-after-6-months.html": "Why People Stick With Food Logging After 6 Months",
    "blog-meal-planning-method-20260421.html": "Meal Planning Method: Use Your Food Log to Plan Tomorrow",
    # Remove brand suffix from these if present
    "the-all-or-nothing-mindset.html": "The All-or-Nothing Mindset: Why Going Perfect Made You Quit",
    "the-food-delivery-trap.html": "The Food Delivery Trap: Why GrabFood Undoes Your Best Week",
    "the-healthy-snack-problem.html": "The 'Healthy' Snack Problem: Why Good Food Still Made You Gain Weight",
    "the-plateau-problem.html": "The Plateau Problem: You've Been Logging for Months and the Scale Won't Move",
    "blog-why-people-stick-after-6-months.html": "Why People Stick With Food Logging After 6 Months",
}

# ── HTML entity fixes in meta descriptions ──
# Replace &quot; in meta description content with actual quote chars
HTML_ENTITY_FILES = [
    "eating-healthy-gain-weight.html",
    "the-guilt-spiral.html",
    "the-perfectionism-trap.html",
]


def is_redirect_stub(html: str) -> bool:
    return bool(re.search(r'<meta\s+http-equiv=["\']refresh["\']', html))


def html_escape(text: str) -> str:
    return (
        text
        .replace("&", "&amp;")
        .replace('"', "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def patch_file(filepath: Path, new_title: str | None, fix_entities: bool) -> bool:
    html = filepath.read_text(encoding="utf-8")

    if is_redirect_stub(html):
        return False

    original = html

    # Patch title
    if new_title:
        title_escaped = html_escape(new_title)
        html = re.sub(r"<title>[^<]*</title>", f"<title>{title_escaped}</title>", html, count=1)

    # Fix HTML entities in meta description (replace &quot; with actual quotes)
    if fix_entities:
        # Only fix in meta description content, not in other attributes
        pattern = r'(<meta\s+name="description"\s+content=")([^"]*)(")'
        def fix_desc(m):
            return m.group(1) + m.group(2).replace("&quot;", '"') + m.group(3)
        html = re.sub(pattern, fix_desc, html)

    if html == original:
        return False

    filepath.write_text(html, encoding="utf-8")
    return True


def main():
    patched = 0
    skipped = 0
    missing = 0

    # Process title fixes
    for filename, new_title in sorted(TITLE_FIXES.items()):
        filepath = BLOG_DIR / filename
        if not filepath.exists():
            print(f"  ❌ {filename} — not found")
            missing += 1
            continue

        fix_entities = filename in HTML_ENTITY_FILES
        changed = patch_file(filepath, new_title, fix_entities)

        if changed:
            entity_str = " + entity fix" if fix_entities else ""
            print(f"  ✅ {filename} — title → {new_title}{entity_str}")
            patched += 1
        else:
            skipped += 1

    # Also fix entities in files that don't have title changes
    for filename in HTML_ENTITY_FILES:
        if filename not in TITLE_FIXES:
            filepath = BLOG_DIR / filename
            if filepath.exists():
                changed = patch_file(filepath, None, True)
                if changed:
                    print(f"  ✅ {filename} — entity fix only")
                    patched += 1

    print(f"\nDone: {patched} patched, {skipped} unchanged, {missing} missing")
    return 0 if missing == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
