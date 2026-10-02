#!/usr/bin/env python3
"""Small LAN client: freeform notes, structures, relationships and acceptance."""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

from import_html import parse_map
from protocol import signature


def request(profile, path, payload=None):
    raw = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"}
    stamp = str(int(time.time()))
    headers.update({"X-Board-Client": profile["client"], "X-Board-Time": stamp,
                    "X-Board-Signature": signature(profile["secret"], stamp, path, raw or b"")})
    req = urllib.request.Request(profile["url"].rstrip("/") + path, data=raw, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read())


def main():
    ap = argparse.ArgumentParser(description="Cortex 板块维护；正文形式自由，验收结论须证据")
    ap.add_argument("--profile", default=str(Path.home() / ".config/cortex-board/client.json"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("overview")
    read = sub.add_parser("read")
    read.add_argument("id")
    update = sub.add_parser("update")
    update.add_argument("--file", required=True, help="完整事件 JSON；显式填写基线版本与 event_id")
    register = sub.add_parser("register-track", help="登记或更新全景板块，沿用唯一 track 账本")
    register.add_argument("id")
    register.add_argument("--title")
    register.add_argument("--owner")
    register.add_argument("--domain", action="append")
    register.add_argument("--family", action="append")
    register.add_argument("--summary")
    register.add_argument("--blocker")
    register.add_argument("--archive", action="store_true", help="撤下测试或已退役板块，保留可恢复历史")
    publish = sub.add_parser("publish-html", help="兼容现有板块图；不把来源颜色/文案当验收结论")
    publish.add_argument("--file", required=True)
    publish.add_argument("--track", required=True)
    args = ap.parse_args()
    profile = json.loads(Path(args.profile).read_text())
    try:
        if args.cmd == "overview":
            result = request(profile, "/api/overview")
        elif args.cmd == "read":
            if any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:." for c in args.id):
                raise ValueError("非法 ID")
            result = request(profile, "/api/entities/" + args.id)
        elif args.cmd == "update":
            result = request(profile, "/api/update", json.loads(Path(args.file).read_text()))
        elif args.cmd == "register-track":
            if not args.id or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:." for c in args.id):
                raise ValueError("非法 ID")
            try:
                previous = request(profile, "/api/entities/" + args.id)
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
                previous = {}
            if previous and previous.get("kind") != "track":
                raise ValueError("这个 ID 已用于其他记录")
            patch = {"track": args.id, "title": args.title or previous.get("title") or args.id,
                     "archived": args.archive}
            for flag, field in [("owner", "owner"), ("summary", "status_label"), ("blocker", "blocker")]:
                value = getattr(args, flag)
                if value is not None:
                    patch[field] = value
            if args.domain is not None:
                patch["domains"] = list(dict.fromkeys(args.domain))
            if args.family is not None:
                patch["ticket_labels"] = list(dict.fromkeys(
                    value if value.startswith("家族:") else "家族:" + value for value in args.family))
            event = {"event_id": str(uuid.uuid4()), "id": args.id, "kind": "track",
                     "base_revision": previous.get("revision", 0), "patch": patch}
            result = request(profile, "/api/update", event)
            checked = request(profile, "/api/entities/" + args.id)
            if any(checked.get(key) != value for key, value in patch.items()):
                raise ValueError("登记回读不一致，请重读后核对")
            result["readback_verified"] = True
        else:
            source = Path(args.file)
            observed = datetime.fromtimestamp(source.stat().st_mtime, timezone.utc).isoformat()
            result = request(profile, "/api/source", parse_map(source.read_text(), args.track, source.name, observed))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except urllib.error.HTTPError as error:
        print(error.read().decode(), file=sys.stderr)
        return 2
    except Exception as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
