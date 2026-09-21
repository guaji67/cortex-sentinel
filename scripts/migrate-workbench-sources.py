#!/usr/bin/env python3
"""Move explicitly registered HTML ownership to Sentinel; preserve originals and old paths."""
import argparse
import json
import os
from pathlib import Path
import shutil


def atomic_json(path, data):
    temporary = path.with_suffix(path.suffix + ".migrating")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--location", type=Path, required=True)
    args = parser.parse_args()
    config_path = args.directory / "config.json"
    config = json.loads(config_path.read_text())
    location = json.loads(args.location.read_text()) if args.location.exists() else {}
    pointers = dict(location.get("legacy_sources", {}))
    count = 0
    for row in config.get("local_sources", []):
        source = Path(row["file"])
        track = row["track"]
        if not track.replace("-", "").replace("_", "").isalnum():
            raise ValueError("invalid track path")
        target = args.directory / "sources" / track / source.name
        if target.exists() and target.resolve() == source.resolve():
            row["file"] = str(target); pointers[track] = str(target)
            continue
        if not source.is_file() or source.is_symlink() or target.exists():
            raise ValueError("source changed or target exists; no files overwritten: " + str(source))
        backup = args.directory / "source-backups" / track / source.name
        if backup.exists():
            raise ValueError("backup already exists; inspect before retry")
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copy2(source, target)
        source.rename(backup)
        source.symlink_to(target)
        row["file"] = str(target); pointers[track] = str(target); count += 1
    location["legacy_sources"] = pointers
    if not config_path.with_suffix(".before-sources.json").exists():
        shutil.copy2(config_path, config_path.with_suffix(".before-sources.json"))
    atomic_json(config_path, config)
    atomic_json(args.location, location)
    print(f"已迁移 {count} 份登记原图；原文件有备份，旧路径保留兼容链接。")


if __name__ == "__main__":
    main()
