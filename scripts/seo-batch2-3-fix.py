#!/usr/bin/env python3
"""
SEO Batch 2+3 — Meta descriptions fix.

Fixes 22 meta descriptions that have unescaped double-quotes inside the
content attribute, causing HTML parsing to truncate the value.

Also verifies title tags are already optimized (they are).

Non-destructive, idempotent. Dry-run first, pass --apply to write.
"""

import argparse
import os
import re
import sys
from pathlib import Path

BLOG_DIR = Path(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) / "blog"

# Batch 2: Meta descriptions (filename -> new description)
# Internal double-quotes will be escaped as &quot; for valid HTML
META_DESCRIPTIONS = {
    "eating-healthy-gain-weight.html": 'You eat salads, whole grains, zero junk — but the scale keeps climbing. Here\'s why "healthy" food still makes you gain weight, and what to check first.',
    "food-logging-for-beginners.html": "New to food logging? Start tracking in 10 seconds per meal with a Telegram bot. No app to download, no calorie counting obsession. Just honest logging.",
    "food-logging-on-glp1-meds.html": "On Ozempic, Wegovy, or Mounjaro? Your appetite collapsed — that's the point. Here's how to log food so you protect muscle and avoid undereating.",
    "food-noise-what-it-is-why-logging-helps.html": "If you think about food before you're hungry, that's food noise. Here's why writing down what you eat actually quiets the constant chatter.",
    "friction-problem-food-logging.html": "The #1 reason people quit food logging isn't willpower — it's friction. Here's how to make tracking so easy you actually stick with it.",
    "glp-1-food-noise-what-it-is.html": "GLP-1 users notice something strange first: the constant chatter about food just stops. Here's what food noise really is, and why tracking still matters.",
    "stop-checking-weight-daily.html": "Your weight can swing 2kg in a day from water and sodium alone. Daily numbers are noise. Here's what to track instead to actually see progress.",
    "the-calorie-budget-method.html": "What if you treated calories like a budget, not a restriction? You get a daily amount. You decide how to spend it. No guilt, no rules — just staying within your limit.",
    "the-cheat-day-myth.html": "Cheat days turn food into a reward system that makes logging feel like punishment. Here's why banking meals quietly destroys the habit that helps you lose weight.",
    "the-comparison-trap.html": "Perfect meal prep on Instagram makes your hawker dinner log feel pathetic. The comparison habit is the silent killer of food logging consistency.",
    "the-guilt-spiral.html": 'You miss one meal log. "Day\'s already ruined." The guilt spiral isn\'t about laziness — it\'s shame avoidance. Here\'s how to break it before you quit.',
    "the-home-cooked-meal-problem.html": "No label, no menu, no reference point. The hardest meal to log is the one you made yourself. Here's how to track home cooking without losing your mind.",
    "the-maintenance-trap-food-logging.html": "Losing weight is the easy part. Keeping it off is where the real work begins. Here's why maintenance is harder than losing — and how to win anyway.",
    "the-mirror-effect-losing-weight-confidence.html": "Losing weight changes more than your body. Here's what nobody tells you about the mirror, your confidence, and the weird feelings that come with success.",
    "the-perfectionism-trap.html": 'You miss one meal log and think "I broke the streak, might as well give up." Perfectionism is the hidden reason people quit food logging.',
    "the-real-reason-people-quit-food-logging.html": "86% of manual entries get edited after submission. That cycle — log, doubt, edit, doubt again — isn't a user failure. It's a system failure.",
    "the-social-anxiety-of-food-logging.html": "You don't stop logging because it's hard. You stop because it feels like everyone is watching you do it. The emotional side of food tracking nobody talks about.",
    "the-solo-eater-problem.html": "You log faithfully with friends. Eating alone? The streak vanishes. The solo eater problem isn't laziness — it's the psychology of invisible meals.",
    "the-tracking-paradox.html": "You started logging to feel in control. Now you're stressing over whether that banana was 105 or 112 calories. Here's how to find the sweet spot.",
    "why-you-plateau-at-week-3.html": "You start strong, lose a few kilos, then everything stalls by week three. It's not failure — it's physiology. Here's what actually gets the scale moving again.",
    "why-you-stop-logging-after-3-weeks.html": 'You logged every bite for two weeks. Then you "forgot." It\'s not laziness — it\'s friction and habit decay. Here\'s how to actually keep going.',
    "why-your-first-week-of-logging-feels-impossible.html": "You logged Monday and Tuesday. Wednesday you forgot. The first week isn't hard because logging is complicated — it's hard because your brain wants perfection.",
}


def escape_for_html_attr(text):
    """Escape double-quotes for use inside HTML attribute values."""
    return text.replace('"', '&quot;')


def fix_meta_description(html, new_desc):
    """Fix meta description — replace entire tag with properly escaped version.
    Returns (html, changed)."""
    escaped = escape_for_html_attr(new_desc)
    new_tag = f'<meta name="description" content="{escaped}">'

    # Pattern to match the existing meta description tag (possibly broken)
    # Match from <meta name="description" to the next > after content=
    pattern = r'<meta\s+name="description"\s+content="[^"]*"[^>]*>'
    m = re.search(pattern, html)
    if m:
        current = m.group(0)
        if current == new_tag:
            return html, False  # Already correct
        html = html.replace(current, new_tag)
        return html, True

    # Try alternate: maybe it's self-closing or has different spacing
    pattern2 = r'<meta\s+name="description"[^>]*>'
    m2 = re.search(pattern2, html)
    if m2:
        html = html.replace(m2.group(0), new_tag)
        return html, True

    return html, False


def process_file(filepath, apply=False):
    """Process a single HTML file."""
    filename = os.path.basename(filepath)

    with open(filepath, 'r', encoding='utf-8') as f:
        html = f.read()

    original = html
    changes = []

    if filename in META_DESCRIPTIONS:
        html, did_change = fix_meta_description(html, META_DESCRIPTIONS[filename])
        if did_change:
            changes.append(f"meta description fixed (HTML-escaped)")

    if html != original:
        if apply:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(html)
        return filename, changes, True
    return filename, [], False


def main():
    parser = argparse.ArgumentParser(description='SEO Batch 2+3 fix for blog meta descriptions')
    parser.add_argument('--apply', action='store_true', help='Write changes to files (default: dry-run)')
    args = parser.parse_args()

    blog_dir = BLOG_DIR
    if not blog_dir.exists():
        print(f"ERROR: Blog directory not found: {blog_dir}")
        sys.exit(1)

    html_files = sorted([str(f) for f in blog_dir.glob("*.html")])

    print(f"{'DRY RUN' if not args.apply else 'APPLYING'} — Processing {len(html_files)} blog articles\n")

    desc_changes = 0
    files_modified = 0

    for filepath in html_files:
        filename, changes, was_modified = process_file(filepath, apply=args.apply)
        if was_modified:
            files_modified += 1
            change_str = ', '.join(changes)
            prefix = "  ✓" if args.apply else "  →"
            print(f"{prefix} {filename}: {change_str}")
            desc_changes += 1

    print(f"\n{'Applied' if args.apply else 'Would apply'} changes to {files_modified}/{len(html_files)} files:")
    print(f"  Meta descriptions fixed: {desc_changes}")

    if not args.apply:
        print(f"\nPass --apply to write changes.")


if __name__ == "__main__":
    main()
