#!/usr/bin/env python3
"""
backup-age-audit.py — Diana 月度備份年齡巡檢（task 20260706-1738-a8d5-diana-s6-db-integrity-backup-audit）

制度化 7/6 memory.db 損毀事件後老兔核可的備份清理計畫（handover/backup-cleanup-plan-20260706.md），
把當時的一次性人工盤點 prompt 機械化成可重複跑的月度腳本。三分類邏輯與盤點原始 prompt 同源：

  🔴 PROTECT（保護，絕不建議清）
    - 7 天內的任何備份（無論類型）
    - 命中已知保護 pattern：memory.db 系列（memory.db.bak-*/memory.db.*）、crontab.bak-p0-*
    - -shm/-wal sidecar 近期（<2 天）有變動 → 判定「看似備份其實還活著」
  🟡 CANDIDATE（清理候選，僅建議，不自動刪）
    - >=30 天 且 被同一組（依檔名去除備份尾綴/日期戳後的底稿名）更新版本取代
  ⚪ REVIEW（待人工判斷）
    - 命中已知「像備份但其實是活體機制」白名單（backup.sh/p2c_backup.py/state/_compact_backup//p2c-write-*）
    - 7-30 天觀察期（尚未到候選門檻）
    - >=30 天但同組內找不到更新版本可判定 superseded（可能仍對應進行中專案，需人工確認是否已結案——
      腳本無法自動判斷「專案是否已結案」，這塊本來就是盤點原始 prompt 裡人工判斷的部分）

只出報告+建議，不刪除/搬移任何檔案（out_of_scope 明列「不自動刪任何備份」）。

用法：
  python backup-age-audit.py [--root PATH] [--handover-dir PATH] [--dry-run]
  --dry-run：只印報告到 stdout，不寫檔、不送通知（測試/手動檢視用）

env（fixture 隔離用，同 repo 內其他 cron python 腳本慣例）：
  BACKUP_AUDIT_ROOT           預設 /home/oldrabbit/.claude-bots
  BACKUP_AUDIT_HANDOVER_DIR   預設 <root>/handover
"""

import argparse
import datetime
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from alert_notify import mm_post_notify  # noqa: E402

PROTECT_AGE_DAYS = 7
CANDIDATE_AGE_DAYS = 30
MAX_SCAN_DEPTH = 3  # 同 7/6 原始盤點 prompt：find ~/.claude-bots -maxdepth 3
EXCLUDE_DIR_PARTS = {"node_modules", ".git", "logs"}  # logs/ 的 .gz 走 aggregate，不逐項列

PROTECT_NAME_PATTERNS = [
    re.compile(r"memory\.db\."),
    re.compile(r"crontab\.bak-p0-"),
]
KEEP_NAME_PATTERNS = [
    re.compile(r"(^|/)backup\.sh$"),
    re.compile(r"(^|/)p2c_backup\.py$"),
    re.compile(r"(^|/)state/_compact_backup(/|$)"),
    re.compile(r"p2c-write-"),
]
SCAN_NAME_PATTERNS = [
    re.compile(r"\.bak"), re.compile(r"backup", re.I),
    re.compile(r"\.tar\.gz$"), re.compile(r"\.old$"), re.compile(r"memory\.db\."),
]


def human_size(n: int) -> str:
    for unit in ("B", "K", "M", "G"):
        if n < 1024:
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}T"


def find_candidates(root: Path):
    seen = set()
    items = []
    for depth_root, dirs, files in os.walk(root):
        rel_parts = Path(depth_root).relative_to(root).parts
        if len(rel_parts) >= MAX_SCAN_DEPTH:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIR_PARTS]
        for f in files:
            if not any(p.search(f) for p in SCAN_NAME_PATTERNS):
                continue
            fp = Path(depth_root) / f
            if fp.is_symlink():
                continue  # 符號連結本身不佔實體空間，且盤點 prompt 明列「活躍符號連結」保留
            key = str(fp)
            if key in seen:
                continue
            seen.add(key)
            items.append(fp)
    return items


def sidecar_recent(p: Path, now_ts: float, days: float = 2) -> bool:
    for suffix in ("-shm", "-wal"):
        sib = Path(str(p) + suffix)
        if sib.exists():
            age = (now_ts - sib.stat().st_mtime) / 86400
            if age < days:
                return True
    return False


def base_key(p: Path) -> str:
    name = re.sub(r"\.tar\.gz$", "", p.name)
    name = re.sub(r"(\.bak|-bak|_backup|-backup|\.backup|\.old)(-[\dT:_-]+)?$", "", name, flags=re.I)
    name = re.sub(r"-\d{8}(-\d{6})?$", "", name)
    return str(p.parent / name)


def classify_fixed(p: Path, root: Path, now_ts: float):
    """回傳 (category|None, reason)；None 表示要交給 supersede 分組判斷。"""
    rel = str(p.relative_to(root))
    st = p.stat()
    age_days = (now_ts - st.st_mtime) / 86400
    if any(pat.search(rel) for pat in KEEP_NAME_PATTERNS):
        return "REVIEW", "命中已知「看似備份實為活體機制」白名單，非清理候選"
    if age_days < PROTECT_AGE_DAYS:
        return "PROTECT", f"{age_days:.1f} 天內，落在 {PROTECT_AGE_DAYS} 天保護窗"
    if any(pat.search(rel) for pat in PROTECT_NAME_PATTERNS):
        return "PROTECT", "命中已知保護 pattern（memory.db 系列／crontab P0 快照）"
    if sidecar_recent(p, now_ts):
        return "PROTECT", "-shm/-wal sidecar 近期有活動，判定仍在使用中"
    return None, None


def audit(root: Path, now: datetime.datetime):
    now_ts = now.timestamp()
    items = find_candidates(root)
    results = []  # (path, category, size, age_days, reason)
    pending_groups: dict[str, list[tuple[Path, int, float]]] = {}

    for p in items:
        st = p.stat()
        age_days = (now_ts - st.st_mtime) / 86400
        cat, reason = classify_fixed(p, root, now_ts)
        if cat:
            results.append((p, cat, st.st_size, age_days, reason))
        else:
            pending_groups.setdefault(base_key(p), []).append((p, st.st_size, age_days))

    for group in pending_groups.values():
        group.sort(key=lambda x: x[2])  # age 由小到大＝mtime 由新到舊
        newest_path = group[0][0]
        for p, size, age_days in group:
            if p == newest_path:
                if age_days >= CANDIDATE_AGE_DAYS:
                    results.append((p, "REVIEW", size, age_days,
                                     "已滿 30 天但為同組最新版本，需人工確認對應專案/事件是否已結案"))
                else:
                    results.append((p, "REVIEW", size, age_days, f"{age_days:.1f} 天，7-30 天觀察期"))
            elif age_days >= CANDIDATE_AGE_DAYS:
                results.append((p, "CANDIDATE", size, age_days,
                                 f"滿 30 天且被同組更新版本取代（{newest_path.name}）"))
            else:
                results.append((p, "REVIEW", size, age_days,
                                 f"{age_days:.1f} 天，7-30 天觀察期，且已被更新版本取代"))

    # logs/ 的 *.gz 輪替只算總量，不逐項列（同原始盤點 prompt）
    logs_gz_total = 0
    logs_dir = root / "logs"
    if logs_dir.is_dir():
        for f in logs_dir.rglob("*.gz"):
            try:
                logs_gz_total += f.stat().st_size
            except OSError:
                pass

    results.sort(key=lambda r: (r[1], -r[3]))
    return results, logs_gz_total


def render_report(results, logs_gz_total: int, root: Path, now: datetime.datetime) -> str:
    by_cat: dict[str, list] = {"PROTECT": [], "CANDIDATE": [], "REVIEW": []}
    for r in results:
        by_cat[r[1]].append(r)

    candidate_bytes = sum(r[2] for r in by_cat["CANDIDATE"])
    lines = [
        f"# Diana 月度備份年齡巡檢 — {now.strftime('%Y-%m-%d')}",
        "",
        f"掃描範圍：`{root}`（maxdepth {MAX_SCAN_DEPTH}，pattern 同 7/6 盤點：*.bak*/*backup*/*.tar.gz/*.old/memory.db.*）。",
        "分類邏輯與 `handover/backup-cleanup-plan-20260706.md` 同源（見腳本頂部 docstring）。",
        "**本報告只是建議，不會自動刪除任何檔案** —— 執行仍需人工核准。",
        "",
        f"- 🔴 PROTECT：{len(by_cat['PROTECT'])} 項",
        f"- 🟡 CANDIDATE（清理候選）：{len(by_cat['CANDIDATE'])} 項，估計可回收 {human_size(candidate_bytes)}",
        f"- ⚪ REVIEW（待人工判斷）：{len(by_cat['REVIEW'])} 項",
        f"- logs/ *.gz 輪替總量（僅彙總，不逐項列）：{human_size(logs_gz_total)}",
        "",
    ]
    for cat, emoji, title in (
        ("CANDIDATE", "🟡", "清理候選（建議人工核准後清理）"),
        ("REVIEW", "⚪", "待人工判斷"),
        ("PROTECT", "🔴", "保護中（不建議動）"),
    ):
        rows = by_cat[cat]
        lines.append(f"## {emoji} {title}（{len(rows)} 項）")
        if not rows:
            lines.append("（無）")
        else:
            lines.append("| 路徑 | 大小 | mtime 年齡(天) | 理由 |")
            lines.append("|---|---|---|---|")
            for p, _cat, size, age_days, reason in rows:
                lines.append(f"| `{p.relative_to(root)}` | {human_size(size)} | {age_days:.1f} | {reason} |")
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("BACKUP_AUDIT_ROOT", "/home/oldrabbit/.claude-bots"))
    ap.add_argument("--handover-dir", default=os.environ.get("BACKUP_AUDIT_HANDOVER_DIR"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    root = Path(args.root)
    handover_dir = Path(args.handover_dir) if args.handover_dir else root / "handover"
    now = datetime.datetime.now()

    results, logs_gz_total = audit(root, now)
    report = render_report(results, logs_gz_total, root, now)

    if args.dry_run:
        print(report)
        return

    handover_dir.mkdir(parents=True, exist_ok=True)
    out_path = handover_dir / f"backup-audit-{now.strftime('%Y%m%d')}.md"
    out_path.write_text(report, encoding="utf-8")

    by_cat_count = {"PROTECT": 0, "CANDIDATE": 0, "REVIEW": 0}
    candidate_bytes = 0
    for _p, cat, size, _age, _reason in results:
        by_cat_count[cat] += 1
        if cat == "CANDIDATE":
            candidate_bytes += size
    summary = (
        f"📦 [備份巡檢] {now.strftime('%Y-%m-%d')}："
        f"保護 {by_cat_count['PROTECT']} / 候選 {by_cat_count['CANDIDATE']}"
        f"（估回收 {human_size(candidate_bytes)}）/ 待判斷 {by_cat_count['REVIEW']}。"
        f"完整報告：{out_path}"
    )
    print(summary)
    mm_post_notify(summary, source="backup-age-audit")


if __name__ == "__main__":
    main()
