#!/usr/bin/env python3
"""One-time LAN node provisioning. Join secrets travel through stdin, never command arguments.
Normal users can instead pair in the bundled web UI. This does not install any daemon.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--export-join", type=Path)
    parser.add_argument("--hub-url")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--maintenance-profile", type=Path)
    parser.add_argument("--source", action="append", nargs=2, default=[])
    args = parser.parse_args()
    if args.export_join:
        config = json.loads(args.export_join.read_text())
        json.dump({"hub_url": args.hub_url, "hub_id": config["node_id"], "hub_key": config["view_key"]}, sys.stdout)
        return
    incoming = json.load(sys.stdin)
    if not args.directory or (args.directory.exists() and any(args.directory.iterdir())):
        raise SystemExit("目标必须为空，未覆盖已有连接或资料")
    if not args.maintenance_profile or not args.maintenance_profile.is_file():
        raise SystemExit("需要已授权的维护 profile")
    config = {"mode": "joined", "port": 8935, "node_id": str(uuid.uuid4()),
              "view_key": str(uuid.uuid4())+str(uuid.uuid4()),
              "clients": {"local-admin": {"secret":str(uuid.uuid4())+str(uuid.uuid4()),"scopes":["*"]}},
              "install_ai_skill": True, "maintenance_profile": str(args.maintenance_profile),
              "local_sources": [{"track":track,"file":file,"profile":str(args.maintenance_profile)} for track,file in args.source],
              **{k: incoming[k] for k in ("hub_url", "hub_id", "hub_key")}}
    args.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd=os.open(args.directory/"config.json",os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,"w") as stream:
        json.dump(config,stream)
    print("哨兵节点已配置；共享账不会复制到本机。")

if __name__ == "__main__":
    main()
