#!/usr/bin/env python3
"""Explicit one-time import. Read source SQLite transactionally; never mutate or stop it.

Target must be empty. Runtime/native API does not depend on this migration tool or Python.
"""
import argparse
import json
import os
import sqlite3
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend/cortex_sentinel/workbench"))
from import_html import parse_map


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # This is migration output, not a source-file edit. Never overwrite an existing ledger.
    with path.open("x", encoding="utf-8") as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)


def migrate(source, destination, port, maps):
    if destination.exists() and any(destination.iterdir()):
        raise ValueError("目标必须为空；不覆盖已有哨兵资料")
    config = json.loads((source / "data/config.json").read_text())
    db = sqlite3.connect(f"file:{source / 'data/ledger.sqlite3'}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("BEGIN")
    entities = {r["id"]: dict(json.loads(r["body"]), id=r["id"], kind=r["kind"], revision=r["revision"])
                for r in db.execute("SELECT * FROM entities")}
    events = {r["event_id"]: dict(r, body=json.loads(r["body"])) for r in db.execute("SELECT * FROM events")}
    sources = {r["id"]: dict(json.loads(r["body"]), received_at=r["observed_at"])
               for r in db.execute("SELECT * FROM sources")}
    snapshots = [dict(at=r["at"], body=json.loads(r["body"])) for r in db.execute("SELECT * FROM snapshots")]
    db.close()
    # The two initial unreviewed seed-machine claims are not assignments. Retain original
    # documents/history in the migration record; never erase a later explicit AI/user edit.
    for row in entities.values():
        if row["kind"] == "track" and not row.get("updated_by") and row.get("revision") == 1:
            if "machine" in row:
                row["migration_note"] = "旧种子中的机器描述已撤下；分工以最新明确登记和哨兵读数为准"
                row["previous_seed_machine"] = row.pop("machine")
    incoming = {key.removeprefix("map:"): value for key, value in sources.items() if key.startswith("map:")}
    for track, file in maps:
        path = Path(file)
        if track not in entities:
            raise ValueError("原图必须对应已登记板块")
        incoming[track] = parse_map(path.read_text(), track, path.name,
            datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat())
    upstream = sources.get("multica", {})
    if "tickets" not in upstream:
        raise ValueError("缺少完整工单快照；停止迁移")
    old_sync = upstream.get("meta", {}).get("sync", {}).get("fetched_at", "")
    if old_sync:
        upstream["synced_at"] = datetime.fromisoformat(old_sync).replace(
            tzinfo=timezone(timedelta(hours=8))).isoformat()
    draft_file = source / "legacy/data/drafts.json"
    drafts = json.loads(draft_file.read_text()) if draft_file.exists() else upstream.get("drafts", {"domains": {}, "tickets": {}})
    document = {"schema": 1, "entities": entities, "events": events, "sources": incoming,
                "drafts": drafts, "draft_revision": 0,
                "migration": {"at": datetime.now(timezone.utc).isoformat(), "source": str(source),
                              "snapshots": snapshots, "source_preserved": True}}
    new_config = {"mode": "host", "port": port, "node_id": str(uuid.uuid4()),
                  "view_key": str(uuid.uuid4()) + str(uuid.uuid4()), "clients": config["clients"],
                  "multica_bin": config.get("multica_bin", str(Path.home()/".local/bin/multica")),
                  "local_sources": config.get("local_sources", [])}
    write(destination / "config.json", new_config)
    write(destination / "ledger.json", document)
    write(destination / "multica.json", upstream)
    print(json.dumps({"entities": len(entities), "events": len(events), "sources": len(incoming),
                      "tickets": len(upstream["tickets"]), "destination": str(destination)}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--from-directory", type=Path, required=True)
    parser.add_argument("--to-directory", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8935)
    parser.add_argument("--map", action="append", nargs=2, default=[], metavar=("TRACK", "HTML"))
    args = parser.parse_args()
    migrate(args.from_directory, args.to_directory, args.port, args.map)
