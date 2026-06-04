#!/usr/bin/env python3
"""SEO Batch 2+3: Optimize meta descriptions and title tags for blog articles.

Non-destructive, idempotent. Only replaces <meta name="description"> and <title>.
Skips redirect stubs (meta http-equiv=refresh).

Usage:
    python3 scripts/seo_meta_titles.py [--dry-run]
"""

import os
import re
import sys
from pathlib import Path

BLOG_DIR = Path(__file__).resolve().parent.parent / "blog"

# ── Meta descriptions (22 articles) ──────────────────────────────────────────
META_DESCRIPTIONS = {
    "eating-healthy-gain-weight.html": "You eat salads, whole grains, zero junk — but the scale keeps climbing. Here's why \"healthy\" food still makes you gain weight, and what to check first.",
    "food-logging-for-beginners.html": "New to food logging? Start tracking in 10 seconds per meal with a Telegram bot. No app to download, no calorie counting obsession. Just honest logging.",
    "food-logging-on-glp1-meds.html": "On Ozempic, Wegovy, or Mounjaro? Your appetite collapsed — that's the point. Here's how to log food so you protect muscle and avoid undereating.",
    "food-noise-what-it-is-why-logging-helps.html": "If you think about food before you're hungry, that's food noise. Here's why writing down what you eat actually quiets the constant chatter.",
    "friction-problem-food-logging.html": "The #1 reason people quit food logging isn't willpower — it's friction. Here's how to make tracking so easy you actually stick with it.",
    "glp-1-food-noise-what-it-is.html": "GLP-1 users notice something strange first: the constant chatter about food just stops. Here's what food noise really is, and why tracking still matters.",
    "stop-checking-weight-daily.html": "Your weight can swing 2kg in a day from water and sodium alone. Daily numbers are noise. Here's what to track instead to actually see progress.",
    "the-calorie-budget-method.html": "What if you treated calories like a budget, not a restriction? You get a daily amount. You decide how to spend it. No guilt, no rules — just staying within your limit.",
    "the-cheat-day-myth.html": "Cheat days turn food into a reward system that makes logging feel like punishment. Here's why banking meals quietly destroys the habit that helps you lose weight.",
    "the-comparison-trap.html": "Perfect meal prep on Instagram makes your hawker dinner log feel pathetic. The comparison habit is the silent killer of food logging consistency.",
    "the-guilt-spiral.html": "You miss one meal log. \"Day's already ruined.\" The guilt spiral isn't about laziness — it's shame avoidance. Here's how to break it before you quit.",
    "the-home-cooked-meal-problem.html": "No label, no menu, no reference point. The hardest meal to log is the one you made yourself. Here's how to track home cooking without losing your mind.",
    "the-maintenance-trap-food-logging.html": "Losing weight is the easy part. Keeping it off is where the real work begins. Here's why maintenance is harder than losing — and how to win anyway.",
    "the-mirror-effect-losing-weight-confidence.html": "Losing weight changes more than your body. Here's what nobody tells you about the mirror, your confidence, and the weird feelings that come with success.",
    "the-perfectionism-trap.html": "You miss one meal log and think \"I broke the streak, might as well give up.\" Perfectionism is the hidden reason people quit food logging.",
    "the-real-reason-people-quit-food-logging.html": "86% of manual entries get edited after submission. That cycle — log, doubt, edit, doubt again — isn't a user failure. It's a system failure.",
    "the-social-anxiety-of-food-logging.html": "You don't stop logging because it's hard. You stop because it feels like everyone is watching you do it. The emotional side of food tracking nobody talks about.",
    "the-solo-eater-problem.html": "You log faithfully with friends. Eating alone? The streak vanishes. The solo eater problem isn't laziness — it's the psychology of invisible meals.",
    "the-tracking-paradox.html": "You started logging to feel in control. Now you're stressing over whether that banana was 105 or 112 calories. Here's how to find the sweet spot.",
    "why-you-plateau-at-week-3.html": "You start strong, lose a few kilos, then everything stalls by week three. It's not failure — it's physiology. Here's what actually gets the scale moving again.",
    "why-you-stop-logging-after-3-weeks.html": "You logged every bite for two weeks. Then you \"forgot.\" It's not laziness — it's friction and habit decay. Here's how to actually keep going.",
    "why-your-first-week-of-logging-feels-impossible.html": "You logged Monday and Tuesday. Wednesday you forgot. The first week isn't hard because logging is complicated — it's hard because your brain wants perfection.",
}

# ── Title tags (44 articles) ─────────────────────────────────────────────────
TITLE_TAGS = {
    "eating-healthy-gain-weight.html": "Why \"Eating Healthy\" Made Me Gain Weight",
    "food-logging-for-beginners.html": "Food Logging for Beginners: The Complete Guide",
    "food-logging-on-glp1-meds.html": "How to Log Food on a GLP-1 (Ozempic, Wegovy)",
    "food-logging-psychology.html": "Why Food Logging Works When You Don't See Results",
    "food-noise-what-it-is-why-logging-helps.html": "What Is Food Noise — And Why Logging Helps",
    "friction-problem-food-logging.html": "The Friction Problem: Why People Quit Food Logging",
    "glp-1-food-noise-what-it-is.html": "GLP-1 Users Notice This First — Not Weight Loss",
    "gym-intimidation-problem-food-logging.html": "The Gym Intimidation Problem",
    "how-to-log-grandmothers-recipes.html": "How to Log Home-Cooked Meals Without a Recipe",
    "kilokaki-vs-myfitnesspal.html": "KiloKaki vs MyFitnessPal: Which Is Better?",
    "meal-prep-hack.html": "Meal Prep for Weight Loss: The Simple Hack",
    "one-tiny-change-method-food-logging.html": "The One-Tiny-Change Method for Food Logging",
    "protein-first.html": "How Much Protein Do You Need Per Day?",
    "stop-checking-weight-daily.html": "Stop Checking Your Weight Every Day",
    "the-calorie-budget-method.html": "The Calorie Budget Method",
    "the-calorie-budget-method-weight-loss.html": "The Calorie Budget Method: Stop Dieting, Start Spending",
    "the-cheat-day-myth.html": "The Cheat Day Myth: Why Banking Meals Fails",
    "the-comparison-trap.html": "The Comparison Trap: Why Other People's Logs Make You Quit",
    "the-emotional-eating-problem.html": "The Emotional Eating Problem",
    "the-guilt-spiral.html": "The Guilt Spiral: Why Missing One Meal Makes You Quit",
    "the-home-cooked-meal-problem.html": "Why Home Cooking Made Me Gain Weight",
    "the-maintenance-trap-food-logging.html": "The Maintenance Trap: Keeping Weight Off",
    "the-mirror-effect-losing-weight-confidence.html": "The Mirror Effect: Losing Weight Changes More Than You Think",
    "the-perfectionism-trap.html": "The Perfectionism Trap: One Missed Meal",
    "the-restaurant-problem-food-logging.html": "The Restaurant Problem: Why Eating Out Breaks Your Streak",
    "the-social-anxiety-of-food-logging.html": "The Social Anxiety of Food Logging",
    "the-social-dinner-survival-guide.html": "The Social Dinner Survival Guide",
    "the-solo-eater-problem.html": "The Solo Eater Problem: Why You Stop Logging Alone",
    "the-tracking-paradox.html": "The Tracking Paradox: When Logging Stops Helping",
    "the-vacation-eating-problem.html": "The Vacation Eating Problem: Stay on Track While Traveling",
    "the-weekend-trap.html": "The Weekend Trap: Why Saturday Erases Your Week",
    "voice-logging.html": "Voice Food Logging: 10x Faster Than Typing",
    "what-six-months-looks-like.html": "What 6 Months of Food Logging Looks Like",
    "what-the-hell-effect-one-bad-meal.html": "The \"What the Hell\" Effect: One Bad Meal",
    "why-always-hungry.html": "Why You're Always Hungry (And How to Fix It)",
    "why-photo-logging-beats-manual-entry.html": "Photo Food Logging vs Manual Entry",
    "why-the-scale-went-up-after-a-good-week.html": "Why the Scale Went Up After a Good Week",
    "why-you-plateau-at-week-3.html": "Why You Plateau at Week 3 (And How to Fix It)",
    "why-you-stop-logging-after-3-weeks.html": "Why You Stop Logging After 3 Weeks",
    "why-your-first-week-of-logging-feels-impossible.html": "Why Your First Week of Logging Feels Impossible",
    "why-youre-always-hungry-on-a-diet.html": "Why You're Always Hungry on a Diet",
    "blog-habit-stacking-framework-20260421.html": "Habit Stacking for Food Logging",
    "blog-meal-planning-method-20260421.html": "Meal Planning Method: Use Your Log to Plan Tomorrow",
    "blog-the-real-reason-people-quit-food-logging.html": "Why People Quit Food Logging (And How to Stick)",
}

def is_redirect(html: str) -> bool:
    return bool(re.search(r'<meta\s+http-equiv=["\']refresh["\']', html, re.IGNORECASE))

def patch_meta_description(html: str, description: str) -> tuple[str, bool]:
    pattern = r'(<meta\s+name=["\']description["\']\s+content=["\'])(.*?)(["\']\s*/?>)'
    new_html = re.sub(pattern, r'\g<1>' + description.replace('\\', '\\\\').replace(r'\g', r'\\g') + r'\3', html, count=1, flags=re.IGNORECASE)
    # Simpler approach: just do it with a lambda
    match = re.search(pattern, html, re.IGNORECASE)
    if not match:
        return html, False
    old_desc = match.group(2)
    if old_desc == description:
        return html, False
    new_html = html[:match.start()] + match.group(1) + description + match.group(3) + html[match.end():]
    return new_html, True

def patch_title(html: str, title: str) -> tuple[str, bool]:
    pattern = r'<title>(.*?)</title>'
    match = re.search(pattern, html, re.IGNORECASE)
    if not match:
        return html, False
    old_title = match.group(1)
    if old_title == title:
        return html, False
    new_html = html[:match.start()] + f'<title>{title}</title>' + html[match.end():]
    return new_html, True

def main():
    dry_run = "--dry-run" in sys.argv

    if dry_run:
        print("=== DRY RUN ===\n")

    all_files = set(META_DESCRIPTIONS.keys()) | set(TITLE_TAGS.keys())
    patched = 0
    skipped_redirect = 0
    skipped_missing = 0

    for filename in sorted(all_files):
        filepath = BLOG_DIR / filename
        if not filepath.exists():
            print(f"⚠️  MISSING: {filename}")
            skipped_missing += 1
            continue

        html = filepath.read_text(encoding="utf-8")

        if is_redirect(html):
            print(f"⏭️  REDIRECT: {filename}")
            skipped_redirect += 1
            continue

        changed = False

        if filename in META_DESCRIPTIONS:
            html, did_change = patch_meta_description(html, META_DESCRIPTIONS[filename])
            if did_change:
                changed = True
                print(f"📝 META: {filename}")

        if filename in TITLE_TAGS:
            html, did_change = patch_title(html, TITLE_TAGS[filename])
            if did_change:
                changed = True
                print(f"🏷️  TITLE: {filename}")

        if changed:
            patched += 1
            if not dry_run:
                filepath.write_text(html, encoding="utf-8")

    print(f"\n{'Would patch' if dry_run else 'Patched'}: {patched} files")
    print(f"Skipped: {skipped_redirect} redirects, {skipped_missing} missing")

if __name__ == "__main__":
    main()
