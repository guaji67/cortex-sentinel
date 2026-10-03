from __future__ import annotations

import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cortex_sentinel import occupancy as occ  # noqa: E402

NOW = datetime(2026, 10, 3, 16, 30, 0, tzinfo=timezone.utc)  # 北京 2026-10-04 00:30

PAYLOAD = {
    "plans": [{
        "id": "falcon", "label": "Falcon 套餐", "running": 7, "max_parallel": 7, "hard_parallel": 8,
        "running_multica": 8, "running_multica_effective": 7, "running_local": 0, "local_lines_known": True,
        "dispatchable": True, "skip_code": None, "cooldown_until": None,
        "lines": [{"executor": "M1Max ZCode", "machine": "m1max"}],
        "executors": [{"id": "ex-1", "name": "M1Max ZCode", "running": 2, "max_concurrent_tasks": 5,
                       "on_board": True, "off_board_reason": None}],
    }],
}
MACHINES = [{"machine": "m1max", "mem_pressure_pct": 17.2, "pressure_level": 1, "mem_free_pct": 18.5,
             "mem_used_pct": 81.5, "swap": {"used": "1M", "total": "2M"}, "cpu_pct": 50.0,
             "ts": "2026-10-03T16:29:50Z", "zcode_other": {"falcon": {"manual": 1}}}]


class OccupancyRowTests(unittest.TestCase):
    def test_row_has_every_required_field(self) -> None:
        row = occ.build_occupancy_row(now=NOW, payload=PAYLOAD, machines=MACHINES,
                                      scan={"falcon": {"scan_running": 7, "scan_queued": 1}})
        self.assertEqual(row["ts_bj"], "2026-10-04 00:30:00")
        plan = row["plans"]["falcon"]
        for key in ("running", "cap", "board_runs", "local_lines", "manual_windows", "queued_over_cap", "queued_scan"):
            self.assertIn(key, plan)
        self.assertEqual((plan["running"], plan["cap"], plan["board_runs"], plan["queued_over_cap"],
                          plan["manual_windows"], plan["queued_scan"]), (7, 7, 8, 1, 1, 1))
        executor = row["executors"][0]
        for key in ("name", "running", "board_cap", "on_board", "archived", "stopped"):
            self.assertIn(key, executor)
        self.assertEqual(row["machines"]["m1max"]["mem_pressure_pct"], 17.2)


class DispatchDedupeTests(unittest.TestCase):
    def test_same_run_id_is_recorded_once(self) -> None:
        run = {"id": "run-1", "issue_id": "iss-1", "kind": "comment", "status": "running",
               "created_at": "2026-10-03T16:29:00Z", "trigger_summary": "x" * 90,
               "attribution": {"evidence": {"kind": "comment"}}}
        index = occ.executor_index(PAYLOAD)
        kwargs = dict(now=NOW, runs_by_agent={"ex-1": [run]}, agents_by_id={"ex-1": {"model": "m"}},
                      index=index, running_by_account={"falcon": 7}, seen={}, issue_cache={"iss-1": "COR-1"},
                      lookup_issue=lambda _i: None)
        seen: dict = {}
        first = occ.new_dispatch_rows(**{**kwargs, "seen": seen})
        second = occ.new_dispatch_rows(**{**kwargs, "seen": seen})
        self.assertEqual(len(first), 1)
        self.assertEqual(second, [])
        self.assertEqual(first[0]["ticket"], "COR-1")
        self.assertEqual(len(first[0]["trigger_head"]), 40)
        self.assertEqual((first[0]["account"], first[0]["machine"], first[0]["kind"]), ("falcon", "m1max", "comment"))


class QueryTests(unittest.TestCase):
    def test_at_picks_latest_row_not_after_the_minute(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            for second, n in ((0, 1), (30, 2), (59, 3)):
                moment = NOW.replace(minute=5, second=second)  # 北京 00:05:xx
                occ.append_jsonl(occ.occupancy_file(base, "2026-10-04"),
                                 {"ts_bj": occ.fmt_bj(moment - timedelta(minutes=25)), "n": n})
            occ.append_jsonl(occ.occupancy_file(base, "2026-10-04"), {"ts_bj": "2026-10-04 00:06:00", "n": 9})
            row = occ.row_at(base, occ.parse_when("2026-10-04 00:05"))
            self.assertEqual(row["n"], 3)
            self.assertIsNone(occ.row_at(base, occ.parse_when("2026-10-03 23:00")))


if __name__ == "__main__":
    unittest.main()
