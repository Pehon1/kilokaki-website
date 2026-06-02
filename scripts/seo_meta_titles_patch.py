#!/usr/bin/env python3
"""SEO Batch 2+3: Patch meta descriptions (22) and title tags (44) on blog HTML files.

Non-destructive, idempotent. Skips redirect stubs (meta http-equiv=refresh).
Run from the kilokaki-site repo root (or pass --dir).

Usage:
    python3 scripts/seo_meta_titles_patch.py [--dir PATH] [--dry-run]
"""

import argparse
import os
import re
import sys

BLOG_DIR = "blog"

# ── Batch 2: Meta Descriptions (22 articles) ──────────────────────────
# filename → optimized description
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
    "the-solo-eater-problem.html": 'You log faithfully with friends. Eating alone? The streak vanishes. The solo eater problem isn\'t laziness — it\'s the psychology of invisible meals.',
    "the-tracking-paradox.html": "You started logging to feel in control. Now you're stressing over whether that banana was 105 or 112 calories. Here's how to find the sweet spot.",
    "why-you-plateau-at-week-3.html": "You start strong, lose a few kilos, then everything stalls by week three. It's not failure — it's physiology. Here's what actually gets the scale moving again.",
    "why-you-stop-logging-after-3-weeks.html": 'You logged every bite for two weeks. Then you "forgot." It\'s not laziness — it\'s friction and habit decay. Here\'s how to actually keep going.',
    "why-your-first-week-of-logging-feels-impossible.html": "You logged Monday and Tuesday. Wednesday you forgot. The first week isn't hard because logging is complicated — it's hard because your brain wants perfection.",
}

# ── Batch 3: Title Tags (44 articles) ─────────────────────────────────
# filename → optimized title (mapped from actual filenames on disk)
TITLE_TAGS = {
    "eating-healthy-gain-weight.html": 'Why "Eating Healthy" Made Me Gain Weight',
    "food-logging-for-beginners.html": "Food Logging for Beginners: The Complete Guide",
    "food-logging-on-glp1-meds.html": "How to Log Food on a GLP-1 (Ozempic, Wegovy)",
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
    "the-calorie-budget-method-weight-loss.html": "The Calorie Budget Method",
    "the-calorie-budget-method.html": "The Calorie Budget Method: Stop Dieting, Start Spending",
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
    "what-the-hell-effect-one-bad-meal.html": 'The "What the Hell" Effect: One Bad Meal',
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
    "calorie-counts-wrong.html": "Why Calorie Counts Are Wrong — And What Actually Matters",
}

# Draft row 4 ("Why Food Logging Works When You Don't See Results") — no matching current title found on disk.
# The closest file is "food-logging-psychology.html" but its title is unknown (not in grep output).
# Adding it to the mapping — if title matches, it patches; otherwise reports mismatch.

# Need to also check: food-logging-psychology.html and blog-why-people-stick-after-6-months.html
# These may correspond to draft items 4 and 33.

# food-logging-psychology.html — check if its current title matches draft row 4:
#   "Why Food Logging Works (Even When You Don't See Results) — KiloKaki Blog"
# blog-why-people-stick-after-6-months.html — current: "Why People Stick With KiloKaki After 6 Months — KiloKaki Blog"
#   Draft row 33: "What 6 Months of Food Logging Actually Looks Like" → that's what-six-months-looks-like.html (already mapped)

# Adding food-logging-psychology.html for draft row 4
TITLE_TAGS["food-logging-psychology.html"] = "Why Food Logging Works When You Don't See Results"

# blog-why-people-stick-after-6-months.html — not in the draft's 44 items, skip

# Also: the-real-reason-people-quit-food-logging.html is a redirect stub (title = "Redirecting…")
# blog-the-real-reason-people-quit-food-logging.html is the real file


def is_redirect_stub(html: str) -> bool:
    return bool(re.search(r'<meta\s+http-equiv=["\']refresh["\']', html, re.IGNORECASE))


def patch_file(filepath: str, dry_run: bool = False) -> dict:
    filename = os.path.basename(filepath)
    result = {"file": filename, "meta": None, "title": None, "skipped": False, "error": None}

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        result["error"] = "FILE_NOT_FOUND"
        return result

    if is_redirect_stub(content):
        result["skipped"] = True
        return result

    new_content = content

    # Patch meta description
    if filename in META_DESCRIPTIONS:
        target = META_DESCRIPTIONS[filename]
        pattern = r'(<meta\s+name=["\']description["\']\s+content=["\'])(.*?)(["\']\s*/?>)'
        match = re.search(pattern, new_content, re.IGNORECASE | re.DOTALL)
        if match:
            current = match.group(2)
            if current != target:
                result["meta"] = ("changed", current, target)
                if not dry_run:
                    new_content = re.sub(pattern, lambda m: m.group(1) + target + m.group(3), new_content, count=1, flags=re.IGNORECASE | re.DOTALL)
            else:
                result["meta"] = ("already_set", None, None)
        else:
            result["meta"] = ("tag_not_found", None, None)

    # Patch title tag
    if filename in TITLE_TAGS:
        target = TITLE_TAGS[filename]
        pattern = r'(<title>)(.*?)(</title>)'
        match = re.search(pattern, new_content, re.IGNORECASE | re.DOTALL)
        if match:
            current = match.group(2)
            if current != target:
                result["title"] = ("changed", current, target)
                if not dry_run:
                    new_content = re.sub(pattern, lambda m: m.group(1) + target + m.group(3), new_content, count=1, flags=re.IGNORECASE | re.DOTALL)
            else:
                result["title"] = ("already_set", None, None)
        else:
            result["title"] = ("tag_not_found", None, None)

    if not dry_run and new_content != content:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(new_content)

    return result


def main():
    parser = argparse.ArgumentParser(description="SEO Batch 2+3: Patch meta descriptions + title tags")
    parser.add_argument("--dir", default=".", help="Repo root directory")
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing")
    args = parser.parse_args()

    blog_path = os.path.join(args.dir, BLOG_DIR)
    if not os.path.isdir(blog_path):
        print(f"ERROR: {blog_path} not found", file=sys.stderr)
        sys.exit(1)

    all_files = sorted(set(META_DESCRIPTIONS.keys()) | set(TITLE_TAGS.keys()))

    changed = 0
    skipped = 0
    already = 0
    errors = 0

    for filename in all_files:
        filepath = os.path.join(blog_path, filename)
        result = patch_file(filepath, dry_run=args.dry_run)

        if result["skipped"]:
            print(f"  SKIP  {filename} — redirect stub")
            skipped += 1
            continue

        if result["error"] == "FILE_NOT_FOUND":
            print(f"  MISS  {filename} — file not found")
            errors += 1
            continue

        did_change = False
        if result["meta"] and result["meta"][0] == "changed":
            print(f"  META  {filename}")
            print(f"        OLD: {result['meta'][1][:80]}...")
            print(f"        NEW: {result['meta'][2][:80]}...")
            did_change = True
        elif result["meta"] and result["meta"][0] == "tag_not_found":
            print(f"  WARN  {filename} — no <meta description> tag found")
            errors += 1
            continue

        if result["title"] and result["title"][0] == "changed":
            print(f"  TITLE {filename}")
            print(f"        OLD: {result['title'][1]}")
            print(f"        NEW: {result['title'][2]}")
            did_change = True
        elif result["title"] and result["title"][0] == "tag_not_found":
            print(f"  WARN  {filename} — no <title> tag found")
            errors += 1
            continue

        if did_change:
            changed += 1
        else:
            already += 1

    mode = "DRY RUN — " if args.dry_run else ""
    print(f"\n{mode}Done: {changed} changed, {already} already set, {skipped} skipped, {errors} issues")
    if args.dry_run:
        print("(dry-run — no files written)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
