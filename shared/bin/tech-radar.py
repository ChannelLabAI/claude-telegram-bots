#!/usr/bin/env python3
"""Filter new RSS/Atom items and notify a named human consumer.

The durable state deliberately contains only one GUID and timestamp per source.
Article bodies, descriptions, and rejected items are never persisted.
"""

from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET


MAX_FEED_BYTES = 2 * 1024 * 1024
UTC = dt.timezone.utc


def fail(message: str) -> None:
    raise RuntimeError(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument(
        "--feed-dir",
        type=Path,
        help="fixture-only: read <source-id>.xml here instead of the network",
    )
    parser.add_argument("--notify-bin", type=Path, help="override notifier for fixtures")
    parser.add_argument("--notify-env", type=Path, help="override Mattermost env file")
    return parser.parse_args()


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read JSON {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"JSON root must be an object: {path}")
    return value


def validate_config(config: dict) -> None:
    sources = config.get("sources")
    topics = config.get("topics")
    delivery = config.get("delivery")
    if not isinstance(sources, list) or not sources:
        fail("config.sources must be a non-empty list")
    if not isinstance(topics, list) or not topics:
        fail("config.topics must be a non-empty list")
    if not isinstance(delivery, dict):
        fail("config.delivery must be an object")
    if delivery.get("kind") != "mattermost" or not delivery.get("consumer"):
        fail("delivery must name kind=mattermost and a real consumer")

    seen: set[str] = set()
    for source in sources:
        if not isinstance(source, dict):
            fail("every source must be an object")
        source_id = source.get("id")
        if not isinstance(source_id, str) or not source_id or source_id in seen:
            fail("every source needs a unique non-empty id")
        seen.add(source_id)
        if not isinstance(source.get("feed_url"), str):
            fail(f"source {source_id} needs feed_url")
    for topic in topics:
        if not isinstance(topic, dict) or not topic.get("id"):
            fail("every topic needs an id")
        if not topic.get("impact") or not isinstance(topic.get("keywords"), list):
            fail(f"topic {topic.get('id')} needs impact and keywords")


def parse_time(raw: str) -> dt.datetime:
    if not raw:
        fail("feed item has no publication timestamp")
    try:
        parsed = email.utils.parsedate_to_datetime(raw)
    except (TypeError, ValueError):
        try:
            parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError as exc:
            fail(f"invalid publication timestamp {raw!r}: {exc}")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def child_text(element: ET.Element, names: tuple[str, ...]) -> str:
    for child in element:
        local = child.tag.rsplit("}", 1)[-1]
        if local in names and child.text:
            return child.text.strip()
    return ""


def parse_feed(payload: bytes, source_id: str) -> list[dict[str, object]]:
    try:
        root = ET.fromstring(payload)
    except ET.ParseError as exc:
        fail(f"source {source_id} returned invalid XML: {exc}")
    entries = [node for node in root.iter() if node.tag.rsplit("}", 1)[-1] in {"item", "entry"}]
    items: list[dict[str, object]] = []
    for entry in entries:
        title = child_text(entry, ("title",))
        guid = child_text(entry, ("guid", "id"))
        link = child_text(entry, ("link",))
        if not link:
            for child in entry:
                if child.tag.rsplit("}", 1)[-1] == "link" and child.attrib.get("href"):
                    link = child.attrib["href"].strip()
                    break
        published_raw = child_text(entry, ("pubDate", "published", "updated"))
        if not title or not link:
            fail(f"source {source_id} has an item missing title or link")
        published = parse_time(published_raw)
        items.append(
            {
                "guid": guid or link,
                "title": " ".join(title.split()),
                "link": link,
                "published": published,
            }
        )
    if not items:
        fail(f"source {source_id} returned zero items")
    items.sort(key=lambda item: item["published"], reverse=True)
    return items


def fetch_feed(source: dict, feed_dir: Path | None) -> bytes:
    if feed_dir:
        return (feed_dir / f"{source['id']}.xml").read_bytes()
    request = urllib.request.Request(
        source["feed_url"],
        headers={"User-Agent": "ChannelLab-Tech-Radar/1.0 (+feed-filter)"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = response.read(MAX_FEED_BYTES + 1)
    if len(payload) > MAX_FEED_BYTES:
        fail(f"source {source['id']} feed exceeds {MAX_FEED_BYTES} bytes")
    return payload


def relevance(item: dict[str, object], topics: list[dict]) -> list[tuple[dict, list[str]]]:
    title = str(item["title"]).casefold()
    matches: list[tuple[dict, list[str]]] = []
    for topic in topics:
        keywords = [str(word) for word in topic["keywords"] if str(word).casefold() in title]
        if keywords:
            matches.append((topic, keywords))
    return matches


def notification_text(source: dict, item: dict, matches: list[tuple[dict, list[str]]], consumer: str) -> str:
    reasons = "; ".join(
        f"{topic['id']} keywords={','.join(keywords)}" for topic, keywords in matches
    )
    impacts = "；".join(dict.fromkeys(str(topic["impact"]) for topic, _ in matches))
    return (
        f"[tech-radar] @{consumer} {source['name']} 命中\n"
        f"標題：{item['title']}\n"
        f"連結：{item['link']}\n"
        f"影響：{impacts}\n"
        f"判斷：{reasons}"
    )


def notifier_paths(config_path: Path, delivery: dict, args: argparse.Namespace) -> tuple[Path, Path | None]:
    root = config_path.resolve().parents[2]
    notify_bin = args.notify_bin or root / delivery["command"]
    notify_env = args.notify_env or root / delivery["env_file"]
    return notify_bin, notify_env


def notify(message: str, delivery: dict, config_path: Path, args: argparse.Namespace) -> None:
    notify_bin, notify_env = notifier_paths(config_path, delivery, args)
    env = os.environ.copy()
    if notify_env and notify_env.exists():
        for raw in notify_env.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env[key.removeprefix("export ").strip()] = value.strip().strip("'\"")
    command = [str(notify_bin), message]
    channel_id = delivery.get("channel_id")
    if channel_id:
        command.append(str(channel_id))
    subprocess.run(command, check=True, env=env)


def load_state(path: Path) -> dict:
    if not path.exists():
        return {}
    state = load_json(path)
    for source_id, watermark in state.items():
        if not isinstance(watermark, dict) or set(watermark) != {"guid", "published_at"}:
            fail(f"state for {source_id} must contain only guid and published_at")
    return state


def write_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(state, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    except BaseException:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def unseen_items(
    items: list[dict[str, object]], watermark: dict | None
) -> tuple[list[dict[str, object]], dict[str, str] | None]:
    if not watermark:
        return items, None
    for index, item in enumerate(items):
        if item["guid"] == watermark["guid"]:
            return items[:index], None
    watermark_time = parse_time(str(watermark["published_at"]))
    oldest = items[-1]
    gap = None
    if oldest["published"] > watermark_time:
        gap = {
            "watermark_guid": str(watermark["guid"]),
            "watermark_published_at": watermark_time.isoformat().replace("+00:00", "Z"),
            "oldest_visible_guid": str(oldest["guid"]),
            "oldest_visible_published_at": oldest["published"].isoformat().replace("+00:00", "Z"),
        }
    return [item for item in items if item["published"] > watermark_time], gap


def gap_notification(source: dict, gap: dict[str, str], consumer: str) -> str:
    return (
        f"[tech-radar] @{consumer} 漏抓風險 source={source['name']}：上次水位 "
        f"guid={gap['watermark_guid']} published_at={gap['watermark_published_at']} 已不在 feed；"
        f"本次最舊可見 guid={gap['oldest_visible_guid']} "
        f"published_at={gap['oldest_visible_published_at']} 仍較新，兩者之間可能有文章遺漏。"
    )


def main() -> int:
    args = parse_args()
    config = load_json(args.config)
    validate_config(config)
    state = load_state(args.state)
    delivery = config["delivery"]
    exit_code = 0

    for source in config["sources"]:
        source_id = source["id"]
        try:
            items = parse_feed(fetch_feed(source, args.feed_dir), source_id)
            new_items, gap = unseen_items(items, state.get(source_id))
            if gap:
                gap_text = gap_notification(source, gap, delivery["consumer"])
                print(
                    f"[tech-radar] GAP source={source_id} "
                    f"watermark_guid={gap['watermark_guid']} "
                    f"watermark_published_at={gap['watermark_published_at']} "
                    f"oldest_visible_guid={gap['oldest_visible_guid']} "
                    f"oldest_visible_published_at={gap['oldest_visible_published_at']} "
                    f"consumer={delivery['consumer']} action=notify"
                )
                notify(gap_text, delivery, args.config, args)
            matched = 0
            skipped = 0
            notified = 0
            for item in reversed(new_items):
                matches = relevance(item, config["topics"])
                if not matches:
                    skipped += 1
                    print(
                        f"[tech-radar] SKIP source={source_id} guid={item['guid']} "
                        f"reason=no_configured_topic title={json.dumps(item['title'], ensure_ascii=False)}"
                    )
                    continue
                matched += 1
                reason = ";".join(
                    f"{topic['id']}:{','.join(keywords)}" for topic, keywords in matches
                )
                impacts = "；".join(dict.fromkeys(str(topic["impact"]) for topic, _ in matches))
                print(
                    f"[tech-radar] MATCH source={source_id} guid={item['guid']} "
                    f"reason={json.dumps(reason, ensure_ascii=False)} "
                    f"impact={json.dumps(impacts, ensure_ascii=False)} "
                    f"title={json.dumps(item['title'], ensure_ascii=False)} link={item['link']}"
                )
                notify(notification_text(source, item, matches, delivery["consumer"]), delivery, args.config, args)
                notified += 1
            newest = items[0]
            state[source_id] = {
                "guid": newest["guid"],
                "published_at": newest["published"].isoformat().replace("+00:00", "Z"),
            }
            write_state(args.state, state)
            print(
                f"[tech-radar] SUMMARY source={source_id} fetched={len(items)} new={len(new_items)} "
                f"matched={matched} skipped={skipped} notified={notified} consumer={delivery['consumer']}"
            )
        except Exception as exc:
            exit_code = 1
            print(f"[tech-radar] ERROR source={source_id} error={exc}", file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
