#!/usr/bin/env python3
"""
ChannelLab Skill Loop — Demo
Demonstrates: bot completes task → skill created → skill reused next time.

Demo scenario:
  Round 1: Anna completes the CLSC compression task (6 steps, success)
           → SkillManager evaluates → creates skills/data/compress-clsc-text/SKILL.md

  Round 2: Anya asks "compress this meeting notes to CLSC"
           → SkillManager finds relevant skill → injects into context
           → Anna's prompt is enriched with the learned procedure

Run: python3 demo.py
"""

import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from skill_manager import SkillManager, TaskTrace

# ─── Helpers ──────────────────────────────────────────────────────────────────

def hr(title: str = ""):
    line = "─" * 60
    if title:
        print(f"\n{line}")
        print(f"  {title}")
        print(f"{line}")
    else:
        print(line)

# ─── Demo ─────────────────────────────────────────────────────────────────────

def main():
    sm = SkillManager(bot="anna")

    print("╔══════════════════════════════════════════════════════════╗")
    print("║  ChannelLab Skill Loop — Demo                           ║")
    print("║  Minimal self-improving skill loop PoC                  ║")
    print("╚══════════════════════════════════════════════════════════╝")

    # ── Round 1: Anna just completed the CLSC v0.2 test task ──────────────────
    hr("ROUND 1: Task just completed → should we create a skill?")

    trace = TaskTrace(
        task="Run CLSC v0.2 compression test on 32 Chinese text samples, applying 3-stage LLM compression prompt, context-aware P0 detection, gzip baseline, reversibility drift test, and dictionary hit rate tracking",
        steps=[
            "Read v0.1 test data (32 samples) from CLSC-Test-Data-Sonnet.json",
            "Design 3-stage compression prompt (tokenize → replacement table → output)",
            "Implement context-aware P0 detector with list-numbering exclusion and 千分位 normalization",
            "Write compression engine with self-check (ratio > 0.70 → retry with aggressive prompt)",
            "Add gzip baseline calculator using Python gzip module",
            "Add reversibility drift test for subset of 11 samples (compress→decompress→compress→decompress)",
            "Add dictionary hit rate tracker across all compressed outputs",
            "Run full suite via subprocess claude CLI (32 samples × ~60s each)",
            "Aggregate metrics: overall ratio, P0 pass rate, gzip compliance, drift avg",
            "Write output JSON to CLSC-Test-Data-Sonnet-v0.2.json",
            "Submit to Bella for code review + LLM judge",
        ],
        outcome="success",
        tool_count=11,
        duration_s=2100.0,
        bot="anna",
        errors=["CLAUDE.md context interference degraded @tag substitution rate"],
    )

    print(f"\nTask: {trace.task[:80]}...")
    print(f"Steps: {trace.tool_count}, Outcome: {trace.outcome}")
    print(f"Errors: {trace.errors}")
    print("\n[skill-loop] Evaluating task for skill creation...")

    t0 = time.time()
    path = sm.maybe_create_skill(trace)
    elapsed = time.time() - t0

    if path:
        print(f"\n✓ Skill created in {elapsed:.1f}s: {path}")
        print(f"\nSkill file contents:")
        hr()
        print(path.read_text())
        hr()
    else:
        print(f"\n✗ No skill created (threshold not met or LLM decided no)")

    # ── Round 2: Anya asks for a similar task ────────────────────────────────
    hr("ROUND 2: New request arrives → does Anna have a skill for this?")

    new_task = "compress these meeting notes to CLSC format and verify P0 hard rules are preserved"
    print(f"\nNew task: {new_task}")
    print("\n[skill-loop] Searching for relevant skills...")

    relevant = sm.search_skills(new_task, top_k=2)
    if relevant:
        print(f"\n✓ Found {len(relevant)} relevant skill(s):")
        for s in relevant:
            print(f"  - {s.name} (v{s.version}): {s.description}")
            print(f"    Trigger: {s.trigger}")

        context = sm.inject_context(new_task)
        print(f"\n[skill-loop] Context injected into Anna's prompt:")
        hr()
        print(context[:800] + ("..." if len(context) > 800 else ""))
        hr()
        print("\n→ Anna can now execute the task using the saved procedure,")
        print("  skipping the design phase and going straight to execution.")
    else:
        print("\n✗ No relevant skills found — Anna starts from scratch.")

    # ── Summary ────────────────────────────────────────────────────────────────
    hr("RESULT")
    all_skills = sm.list_skills()
    print(f"\nSkill library: {len(all_skills)} skill(s)")
    for s in all_skills:
        print(f"  [{s['category']}] {s['name']} v{s['version']}: {s['description']}")

    print("\n✓ Demo complete.")
    print("\nKey takeaway:")
    print("  Before: Anna re-designs the CLSC test pipeline from scratch each time.")
    print("  After:  Anna loads 'compress-clsc-text' skill → skips ~3 planning steps.")
    print("          Next iteration: skill gets patched with lessons from this run.")

if __name__ == "__main__":
    main()
