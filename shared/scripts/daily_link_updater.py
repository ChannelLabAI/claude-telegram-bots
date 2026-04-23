#!/usr/bin/env python3
"""
Daily note 今日關聯 updater.
Updates 00Daily/{date}.md in personal vault with:
- Pearl drafts generated today
- Key Ocean docs updated today
- People links

Run after Dream Cycle or as daily cron.
"""

import os
import re
import sys
from datetime import date, datetime

PERSONAL_DAILY = os.path.expanduser(
    "~/Documents/Obsidian Vault - OldRabbit/00Daily/"
)
OCEAN_PEARL_DRAFTS = os.path.expanduser(
    "~/Documents/Obsidian Vault/Ocean/珍珠卡/_drafts/"
)
OCEAN_PEARL = os.path.expanduser(
    "~/Documents/Obsidian Vault/Ocean/珍珠卡/"
)

DEFAULT_PEOPLE = ["[[老兔]]", "[[菜姐]]", "[[Ron]]", "[[Nicky]]", "[[桃桃]]"]


def get_today():
    return date.today().strftime("%Y-%m-%d")


def find_pearl_drafts(target_date: str):
    """Find Pearl draft files created on target_date."""
    results = []
    if not os.path.isdir(OCEAN_PEARL_DRAFTS):
        return results
    prefix = f"{target_date}-"
    for fname in sorted(os.listdir(OCEAN_PEARL_DRAFTS)):
        if fname.startswith(prefix) and fname.endswith(".md") and fname != "Pearl_drafts.clsc.md":
            slug = fname[:-3]
            # Build readable title from slug (drop date prefix)
            parts = slug.split("-")
            title = " ".join(parts[3:]) if len(parts) > 3 else slug
            results.append((slug, title))
    return results


def find_pearl_cards(target_date: str):
    """Find promoted Pearl cards (not in _drafts) created on target_date."""
    results = []
    if not os.path.isdir(OCEAN_PEARL):
        return results
    prefix = f"{target_date}-"
    for fname in os.listdir(OCEAN_PEARL):
        if fname.startswith(prefix) and fname.endswith(".md"):
            slug = fname[:-3]
            parts = slug.split("-")
            title = " ".join(parts[3:]) if len(parts) > 3 else slug
            results.append((slug, title))
    return sorted(results)


def update_daily_note(target_date: str = None):
    if target_date is None:
        target_date = get_today()
    
    daily_path = os.path.join(PERSONAL_DAILY, f"{target_date}.md")
    
    if not os.path.exists(daily_path):
        print(f"Daily note not found: {daily_path}")
        return False
    
    with open(daily_path) as f:
        content = f.read()
    
    if "今日關聯" in content:
        # Update existing section - rebuild it
        content = re.sub(r'\n\n---\n\n## 今日關聯\n.*$', '', content, flags=re.DOTALL)
    
    pearl_drafts = find_pearl_drafts(target_date)
    pearl_cards = find_pearl_cards(target_date)
    
    section = "\n\n---\n\n## 今日關聯\n\n"
    
    if pearl_cards:
        section += "### Pearl（今日升格）\n\n"
        for slug, title in pearl_cards:
            section += f"- [[{slug}|{title}]]\n"
        section += "\n"
    
    if pearl_drafts:
        section += "### Pearl 草稿（今日生成）\n\n"
        for slug, title in pearl_drafts:
            section += f"- [[{slug}|{title}]]\n"
        section += "\n"
    
    section += "### 相關人物\n\n"
    section += "- " + " · ".join(DEFAULT_PEOPLE) + "\n"
    
    new_content = content.rstrip() + section
    
    with open(daily_path, 'w') as f:
        f.write(new_content)
    
    print(f"Updated {target_date}.md: {len(pearl_cards)} cards, {len(pearl_drafts)} drafts")
    return True


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else None
    update_daily_note(target)
