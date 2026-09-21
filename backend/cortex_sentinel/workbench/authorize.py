#!/usr/bin/env python3
"""Create a scoped maintenance profile through the local running Sentinel, never print its key."""
import argparse
import json
import os
from pathlib import Path
import urllib.request

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--track", action="append", required=True)
    parser.add_argument("--hub-url", required=True, help="The stable LAN address for the receiving machine")
    parser.add_argument("--local-port", type=int, default=8935)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit("输出已存在，未覆盖")
    request = urllib.request.Request(f"http://127.0.0.1:{args.local_port}/api/clients",
        data=json.dumps({"name": args.name, "scopes": args.track}).encode(),
        headers={"Content-Type": "application/json", "X-Sentinel-Local": "1"})
    with urllib.request.urlopen(request, timeout=15) as response:
        profile = json.load(response)
    profile["url"] = args.hub_url.rstrip("/")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(profile, stream)
    print("已保存限板块维护授权：" + str(args.output))

if __name__ == "__main__":
    main()
