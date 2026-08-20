from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


def _isolate_home() -> str:
    home = tempfile.mkdtemp(prefix="sentinel-test-")
    os.environ["CORTEX_SENTINEL_HOME"] = home
    return home


_isolate_home()

from cortex_sentinel import paths  # noqa: E402
from cortex_sentinel.channel import STATUS_UP, derive_snapshot  # noqa: E402
from cortex_sentinel.registry import (  # noqa: E402
    LineRegistryError,
    east_eight_timestamp,
    sentinel_timestamp_seconds,
    upsert_line_registration,
)


class PathsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.home = Path(_isolate_home())

    def test_home_env_and_layout(self) -> None:
        home = paths.sentinel_home()
        self.assertEqual(home, self.home)
        self.assertTrue((home / "status").is_dir())
        self.assertTrue((home / "logs").is_dir())
        self.assertEqual(paths.registry_path(), home / "registry.json")
        self.assertEqual(paths.channel_status_path(), home / "channel-status.json")

    def test_missing_config_is_empty_projects(self) -> None:
        self.assertEqual(paths.load_config(), {"projects": []})
        self.assertEqual(paths.projects(), [])
        self.assertIsNone(paths.find_project(Path("/tmp/nope")))

    def test_config_and_find_project(self) -> None:
        root = self.home / "proj"
        nested = root / "src"
        nested.mkdir(parents=True)
        (self.home / "config.toml").write_text(
            "\n".join(
                [
                    "[[projects]]",
                    'name = "demo"',
                    f'root = "{root}"',
                    'dev_ports = [3000, 3401-3403]',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        rows = paths.projects()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["name"], "demo")
        self.assertEqual(rows[0]["dev_ports"], [3000, 3401, 3402, 3403])
        found = paths.find_project(nested)
        self.assertIsNotNone(found)
        assert found is not None
        self.assertEqual(found["name"], "demo")
        self.assertIsNone(paths.find_project(self.home / "other"))


class RegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.home = Path(_isolate_home())

    def test_timestamp_contract(self) -> None:
        self.assertIsNotNone(sentinel_timestamp_seconds("2026-08-11T19:25:00+08:00"))
        self.assertIsNotNone(sentinel_timestamp_seconds("2026-08-11T19:25:00"))
        self.assertIsNone(sentinel_timestamp_seconds("昨天下午"))
        source = datetime(2026, 8, 11, 20, 25, 42, tzinfo=timezone.utc)
        self.assertEqual(east_eight_timestamp(source), "2026-08-12T04:25:42+08:00")

    def test_upsert_roundtrip(self) -> None:
        path = paths.registry_path()
        first = datetime(2026, 8, 11, 11, 25, 0, tzinfo=timezone.utc)
        second = datetime(2026, 8, 11, 12, 30, 15, tzinfo=timezone.utc)
        inserted = upsert_line_registration(
            path,
            slug="same-line",
            label_zh="第一次",
            dispatcher_zh="来源一",
            now=first,
        )
        updated = upsert_line_registration(
            path,
            slug="same-line",
            label_zh="续跑",
            dispatcher_zh="来源二",
            now=second,
        )
        self.assertEqual(inserted.action, "inserted")
        self.assertEqual(updated.action, "updated")
        rows = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["label_zh"], "续跑")
        self.assertEqual(rows[0]["engine"], "codex")

    def test_reject_empty_slug(self) -> None:
        with self.assertRaises(LineRegistryError):
            upsert_line_registration(
                paths.registry_path(),
                slug=" ",
                label_zh="x",
                dispatcher_zh="y",
            )


class ChannelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.home = Path(_isolate_home())

    def test_running_live_pid_is_alive(self) -> None:
        logs_dir = self.home / "case"
        logs_dir.mkdir()
        payload = {
            "engine": "cursor-grok",
            "slug": "one",
            "state": "running",
            "agent_pid": 4242,
            "started_at": "2026-08-18T23:00:00+08:00",
            "updated_at": "2026-08-18T23:00:00+08:00",
        }
        (logs_dir / "grok-one.status.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        snapshot = derive_snapshot(
            logs_dir=logs_dir,
            stderr_dir=self.home / "stderr",
            pid_alive=lambda pid: pid == 4242,
            now=datetime(2026, 8, 18, 23, 10, tzinfo=timezone.utc),
        )
        grok = snapshot["channels"]["grok"]
        self.assertEqual(grok["status"], STATUS_UP)
        self.assertEqual(grok["running"], 1)
        self.assertEqual(snapshot["channels"]["codex"]["status"], "unknown")

    def test_empty_dir_is_nodata(self) -> None:
        logs_dir = self.home / "empty"
        logs_dir.mkdir()
        snapshot = derive_snapshot(
            logs_dir=logs_dir,
            stderr_dir=self.home / "stderr",
            pid_alive=lambda pid: False,
            now=datetime(2026, 8, 18, 23, 10, tzinfo=timezone.utc),
        )
        self.assertEqual(snapshot["channels"]["grok"]["status"], "unknown")
        self.assertEqual(snapshot["channels"]["codex"]["status"], "unknown")


if __name__ == "__main__":
    unittest.main()
