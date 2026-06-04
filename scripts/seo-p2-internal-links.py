#!/usr/bin/env python3
"""SEO Sprint P2: Batch-apply internal linking clusters with unified .related div.

Replaces all existing related-reading patterns (related-reads, related-articles, related, h2-heading)
with a consistent class="related" div per cluster mapping.
Approved by Coco 2026-06-04 23:49 SGT.
"""

from __future__ import annotations
import re
import sys
from pathlib import Path

BLOG_DIR = Path(__file__).resolve().parent.parent / "blog"

TITLES = {
    "the-guilt-spiral.html": "The Guilt Spiral: Why Missing One Meal Makes You Quit",
    "the-all-or-nothing-mindset.html": "The All-or-Nothing Mindset: Why Going Perfect Made You Quit",
    "why-you-stop-logging-after-3-weeks.html": "Why You Stop Logging After 3 Weeks",
    "the-comeback-after-falling-off.html": "The Comeback After Falling Off",
    "the-restaurant-problem-food-logging.html": "The Restaurant Problem: Why Eating Out Breaks Your Streak",
    "the-social-dinner-survival-guide.html": "The Social Dinner Survival Guide",
    "the-solo-eater-problem.html": "The Solo Eater Problem",
    "food-noise-what-it-is-why-logging-helps.html": "What Is Food Noise — And Why Logging Helps",
    "the-perfectionism-trap.html": "The Perfectionism Trap: One Missed Meal",
    "what-the-hell-effect-one-bad-meal.html": 'The "What the Hell" Effect: One Bad Meal',
    "food-logging-on-glp1-meds.html": "How to Log Food on a GLP-1",
    "glp-1-food-noise-what-it-is.html": "GLP-1 Users Notice This First — Not Weight Loss",
    "the-vacation-eating-problem.html": "The Vacation Eating Problem: Stay on Track While Traveling",
    "the-weekend-trap.html": "The Weekend Trap: Why Saturday Erases Your Food Logging Week",
    "the-travel-eating-problem.html": "The Travel Eating Problem",
    "food-logging-for-beginners.html": "Food Logging for Beginners: The Complete Guide",
    "why-your-first-week-of-logging-feels-impossible.html": "Why Your First Week of Logging Feels Impossible",
    "voice-logging.html": "Voice Food Logging: 10x Faster Than Typing",
    "the-calorie-budget-method.html": "The Calorie Budget Method",
    "eating-healthy-gain-weight.html": 'Why "Eating Healthy" Made Me Gain Weight',
    "protein-first.html": "How Much Protein Do You Need Per Day?",
    "why-you-plateau-at-week-3.html": "Why You Plateau at Week 3",
    "the-plateau-problem.html": "The Plateau Problem: You've Been Logging for Months",
    "kilokaki-vs-myfitnesspal.html": "KiloKaki vs MyFitnessPal: Which Is Better?",
    "why-photo-logging-beats-manual-entry.html": "Photo Food Logging vs Manual Entry",
    "the-comparison-trap.html": "The Comparison Trap",
    "the-home-cooked-meal-problem.html": "The Home-Cooked Meal Problem",
    "log-home-cooked-meals-no-recipe.html": "How to Log Home-Cooked Meals Without a Recipe",
    "the-food-delivery-trap.html": "The Food Delivery Trap",
    "habit-stacking-food-logging.html": "Habit Stacking for Food Logging",
    "the-maintenance-trap-food-logging.html": "The Maintenance Trap: How Food Logging Keeps Weight Off",
    "one-tiny-change-method-food-logging.html": "The One-Tiny-Change Habit for Food Logging",
    "the-mirror-effect-losing-weight-confidence.html": "The Mirror Effect: How Food Logging Changes Your Confidence",
    "what-six-months-looks-like.html": "What 6 Months of Food Logging Looks Like",
    "food-logging-psychology.html": "Why Food Logging Works When You Don't See Results",
}

CLUSTERS = {
    "the-guilt-spiral.html": ["the-all-or-nothing-mindset.html", "why-you-stop-logging-after-3-weeks.html", "the-comeback-after-falling-off.html"],
    "the-all-or-nothing-mindset.html": ["the-guilt-spiral.html", "why-you-stop-logging-after-3-weeks.html", "the-comeback-after-falling-off.html"],
    "why-you-stop-logging-after-3-weeks.html": ["the-guilt-spiral.html", "the-all-or-nothing-mindset.html", "the-comeback-after-falling-off.html"],
    "the-comeback-after-falling-off.html": ["the-guilt-spiral.html", "the-all-or-nothing-mindset.html", "why-you-stop-logging-after-3-weeks.html"],
    "the-restaurant-problem-food-logging.html": ["the-social-dinner-survival-guide.html", "the-solo-eater-problem.html", "the-food-delivery-trap.html"],
    "the-social-dinner-survival-guide.html": ["the-restaurant-problem-food-logging.html", "the-solo-eater-problem.html"],
    "the-solo-eater-problem.html": ["the-restaurant-problem-food-logging.html", "the-social-dinner-survival-guide.html"],
    "food-noise-what-it-is-why-logging-helps.html": ["the-perfectionism-trap.html", "what-the-hell-effect-one-bad-meal.html"],
    "the-perfectionism-trap.html": ["food-noise-what-it-is-why-logging-helps.html", "what-the-hell-effect-one-bad-meal.html", "the-guilt-spiral.html"],
    "what-the-hell-effect-one-bad-meal.html": ["food-noise-what-it-is-why-logging-helps.html", "the-perfectionism-trap.html"],
    "food-logging-on-glp1-meds.html": ["glp-1-food-noise-what-it-is.html"],
    "glp-1-food-noise-what-it-is.html": ["food-logging-on-glp1-meds.html"],
    "the-vacation-eating-problem.html": ["the-weekend-trap.html", "the-travel-eating-problem.html"],
    "the-weekend-trap.html": ["the-vacation-eating-problem.html", "the-travel-eating-problem.html"],
    "the-travel-eating-problem.html": ["the-vacation-eating-problem.html", "the-weekend-trap.html"],
    "food-logging-for-beginners.html": ["why-your-first-week-of-logging-feels-impossible.html", "voice-logging.html"],
    "why-your-first-week-of-logging-feels-impossible.html": ["food-logging-for-beginners.html", "voice-logging.html"],
    "voice-logging.html": ["food-logging-for-beginners.html", "why-your-first-week-of-logging-feels-impossible.html"],
    "the-calorie-budget-method.html": ["eating-healthy-gain-weight.html", "protein-first.html"],
    "eating-healthy-gain-weight.html": ["the-calorie-budget-method.html", "protein-first.html"],
    "protein-first.html": ["the-calorie-budget-method.html", "eating-healthy-gain-weight.html"],
    "why-you-plateau-at-week-3.html": ["the-plateau-problem.html"],
    "the-plateau-problem.html": ["why-you-plateau-at-week-3.html"],
    "kilokaki-vs-myfitnesspal.html": ["why-photo-logging-beats-manual-entry.html", "the-comparison-trap.html"],
    "why-photo-logging-beats-manual-entry.html": ["kilokaki-vs-myfitnesspal.html", "the-comparison-trap.html"],
    "the-comparison-trap.html": ["kilokaki-vs-myfitnesspal.html", "why-photo-logging-beats-manual-entry.html"],
    "the-home-cooked-meal-problem.html": ["log-home-cooked-meals-no-recipe.html"],
    "log-home-cooked-meals-no-recipe.html": ["the-home-cooked-meal-problem.html"],
    "the-food-delivery-trap.html": ["the-restaurant-problem-food-logging.html"],
    "habit-stacking-food-logging.html": ["the-maintenance-trap-food-logging.html", "one-tiny-change-method-food-logging.html"],
    "the-maintenance-trap-food-logging.html": ["habit-stacking-food-logging.html", "one-tiny-change-method-food-logging.html"],
    "one-tiny-change-method-food-logging.html": ["habit-stacking-food-logging.html", "the-maintenance-trap-food-logging.html"],
    "the-mirror-effect-losing-weight-confidence.html": ["what-six-months-looks-like.html", "food-logging-psychology.html"],
    "what-six-months-looks-like.html": ["the-mirror-effect-losing-weight-confidence.html", "food-logging-psychology.html"],
    "food-logging-psychology.html": ["the-mirror-effect-losing-weight-confidence.html", "what-six-months-looks-like.html"],
}

RELATED_CSS = """    .related { background: var(--cream); padding: 1.5rem; border-radius: 12px; margin: 2rem 0; border: 1px solid var(--line); }
    .related h3 { margin: 0 0 0.75rem 0; font-size: 1rem; color: var(--green-dark); }
    .related ul { list-style: none; padding: 0; margin: 0; }
    .related li { margin-bottom: 0.4rem; font-size: 0.95rem; }
    .related a { color: var(--green-dark); text-decoration: none; font-weight: 500; }
    .related a:hover { text-decoration: underline; }"""


def build_related_html(siblings: list[str]) -> str:
    lis = "\n".join(
        f'          <li><a href="/blog/{s}">{TITLES.get(s, s.replace(".html", "").replace("-", " ").title())}</a></li>'
        for s in siblings
    )
    return f"""      <div class="related">
        <h3>Related Reading</h3>
        <ul>
{lis}
        </ul>
      </div>"""


def find_div_block(html: str, start_pos: int) -> tuple[int, int] | None:
    """Find the full extent of a <div> block starting at start_pos, handling nested divs."""
    depth = 0
    pos = start_pos
    while pos < len(html):
        next_open = html.find('<div', pos)
        next_close = html.find('</div>', pos)
        if next_close == -1:
            return None
        if next_open != -1 and next_open < next_close:
            depth += 1
            pos = next_open + 4
        else:
            depth -= 1
            if depth == 0:
                return (start_pos, next_close + len('</div>'))
            pos = next_close + 6
    return None


def strip_existing_related(html: str) -> str:
    """Remove any existing related-reading section."""
    # Pattern 1: <div class="related-reads">...</div>
    start = html.find('<div class="related-reads">')
    if start != -1:
        block = find_div_block(html, start)
        if block:
            html = html[:block[0]] + html[block[1]:]

    # Pattern 2: <div class="related-articles" ...>...</div>
    start = html.find('<div class="related-articles"')
    if start != -1:
        block = find_div_block(html, start)
        if block:
            html = html[:block[0]] + html[block[1]:]

    # Pattern 3: <div class="related">...</div>
    start = html.find('<div class="related">')
    if start != -1:
        block = find_div_block(html, start)
        if block:
            html = html[:block[0]] + html[block[1]:]

    # Pattern 4: <h2>Related Reading</h2> followed by <ul>...</ul>
    h2_start = html.find('<h2>Related Reading</h2>')
    if h2_start != -1:
        ul_start = html.find('<ul', h2_start)
        ul_end = html.find('</ul>', h2_start) + len('</ul>') if html.find('</ul>', h2_start) != -1 else -1
        if ul_start != -1 and ul_end > ul_start:
            html = html[:h2_start] + html[ul_end:]

    # Pattern 5: <div style="margin:40px 0 0;..."> with <h3>Related articles</h3> (inline style, no class)
    h3_match = re.search(r'<h3[^>]*>\s*Related articles\s*</h3>', html)
    if h3_match:
        # Walk backwards to find the parent <div style="...">
        search_back = html[:h3_match.start()].rstrip()
        div_start = search_back.rfind('<div style="margin')
        if div_start != -1:
            block = find_div_block(html, div_start)
            if block:
                html = html[:block[0]] + html[block[1]:]

    return html


def has_related_css(html: str) -> bool:
    return '.related {' in html


def has_old_related_css(html: str) -> bool:
    return '.related-reads {' in html or '.related-articles {' in html


def patch_file(filepath: Path, siblings: list[str]) -> bool:
    html = filepath.read_text(encoding="utf-8")
    original = html

    # Strip any existing related section
    html = strip_existing_related(html)

    # Replace old related CSS with new .related CSS
    if has_old_related_css(html):
        # Remove old CSS blocks
        html = re.sub(r'\s*\.related-reads \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-reads h3 \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-reads ul \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-reads li \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-reads a \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-reads a:hover \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-articles \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-articles h3 \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-articles ul \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-articles li \{[^}]+\}\s*', '\n', html)
        html = re.sub(r'\s*\.related-articles a \{[^}]+\}\s*', '\n', html)

    # Add new .related CSS if missing
    if not has_related_css(html):
        style_end = html.find("</style>")
        if style_end != -1:
            html = html[:style_end] + RELATED_CSS + "\n" + html[style_end:]

    # Insert new related div before </article>, <footer>, <nav class="nav", or closing </div></body>
    related_html = build_related_html(siblings)
    insert_pos = html.find("</article>")
    if insert_pos == -1:
        insert_pos = html.find("<footer")
    if insert_pos == -1:
        insert_pos = html.find('<nav class="nav"')
    if insert_pos == -1:
        # Fallback: find closing </div></div></body></html> and insert before first </div>
        body_close = html.find("</body>")
        if body_close != -1:
            # Walk backwards from </body> to find the content wrapper close
            search_area = html[:body_close].rstrip()
            # Insert before the last two </div> tags
            last_div = search_area.rfind("</div>")
            if last_div != -1:
                # Find the second-to-last </div>
                second_last = search_area[:last_div].rstrip().rfind("</div>")
                if second_last != -1:
                    insert_pos = second_last
                else:
                    insert_pos = last_div
    if insert_pos == -1:
        return False
    html = html[:insert_pos] + "\n" + related_html + "\n    " + html[insert_pos:]

    # Clean up excess blank lines
    html = re.sub(r'\n{3,}', '\n\n', html)

    if html == original:
        return False

    filepath.write_text(html, encoding="utf-8")
    return True


def main():
    patched = 0
    skipped = 0
    missing = 0

    for filename, siblings in sorted(CLUSTERS.items()):
        filepath = BLOG_DIR / filename
        if not filepath.exists():
            print(f"  ❌ {filename} — not found")
            missing += 1
            continue

        changed = patch_file(filepath, siblings)
        if changed:
            print(f"  ✅ {filename} — {len(siblings)} sibling link(s)")
            patched += 1
        else:
            skipped += 1

    print(f"\nDone: {patched} patched, {skipped} unchanged, {missing} missing")
    return 0 if missing == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
