from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cortex_sentinel import occupancy as occ  # noqa: E402
from cortex_sentinel import review as rv  # noqa: E402

NOW = datetime(2026, 10, 3, 18, 0, 0, tzinfo=timezone.utc)  # 北京 2026-10-04 02:00


def dispatch_row(run_id: str, ticket: str, model: str, created_bj: str, executor: str = "Pro 执行者(ZCode GLM Flash·Falcon 套餐)",
                 machine: str = "pro", account: str = "falcon", executor_id: str = "ex-1") -> dict:
    return {"run_id": run_id, "ticket": ticket, "model": model, "created_bj": created_bj, "ts_bj": created_bj,
            "executor": executor, "executor_id": executor_id, "machine": machine, "account": account,
            "status_at_seen": "running"}


def write_dispatch(base: Path, rows: list, day: str = "2026-10-04") -> None:
    for row in rows:
        occ.append_jsonl(occ.dispatch_file(base, day), row)


class AddTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.reviews = Path(self.tmp.name) / "reviews"
        self.occ = Path(self.tmp.name) / "occupancy"
        self.reviews.mkdir()
        self.occ.mkdir()

    def test_add_takes_model_and_executor_from_dispatch_log(self) -> None:
        write_dispatch(self.occ, [
            dispatch_row("run-old", "COR-1", "glm-5.3-flash", "2026-10-04 00:10:00"),
            dispatch_row("run-new", "COR-1", "gpt-6.1-sol", "2026-10-04 01:10:00",
                         executor="M1Max 执行者(Codex Sol High)", machine="m1max", account="-", executor_id="ex-2"),
            dispatch_row("run-other", "COR-2", "mimo-v2.6-flash", "2026-10-04 01:30:00"),
        ])
        row = rv.add_review(self.reviews, self.occ, ticket="cor-1", grade="好", note="一轮过", by="窗口甲", now=NOW)
        self.assertEqual((row["ticket"], row["run_id"], row["model"], row["machine"], row["account"], row["source"]),
                         ("COR-1", "run-new", "gpt-6.1-sol", "m1max", "-", "派工记录"))
        self.assertEqual(row["executor"], "M1Max 执行者(Codex Sol High)")
        self.assertEqual((row["by"], row["grade"], row["note"], row["ts_bj"]), ("窗口甲", "好", "一轮过", "2026-10-04 02:00:00"))
        saved = occ.read_jsonl(rv.reviews_file(self.reviews))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0]["model"], "gpt-6.1-sol")

    def test_run_prefix_picks_older_run(self) -> None:
        write_dispatch(self.occ, [
            dispatch_row("run-old", "COR-1", "glm-5.3-flash", "2026-10-04 00:10:00"),
            dispatch_row("run-new", "COR-1", "gpt-6.1-sol", "2026-10-04 01:10:00"),
        ])
        row = rv.add_review(self.reviews, self.occ, ticket="COR-1", grade="差", note="跑偏", run_prefix="run-o", now=NOW)
        self.assertEqual((row["run_id"], row["model"]), ("run-old", "glm-5.3-flash"))

    def test_falls_back_to_multica_when_dispatch_log_has_no_run(self) -> None:
        # 派工记录里没有这张票：现查 issue runs，模型和执行者名从 agent 清单取，号从派工记录里同一执行者借
        write_dispatch(self.occ, [dispatch_row("run-x", "COR-9", "glm-5.3-flash", "2026-10-04 00:10:00", executor_id="ex-7")])
        runs = [
            {"id": "run-2", "agent_id": "ex-7", "created_at": "2026-10-03T14:46:36Z", "status": "completed"},
            {"id": "run-1", "agent_id": "ex-3", "created_at": "2026-10-03T10:00:00Z", "status": "completed"},
        ]
        agents = [{"id": "ex-7", "name": "mini 执行者(MiMo v2.6 Flash Go)", "model": "mimo-v2.6-flash"}]
        row = rv.add_review(self.reviews, self.occ, ticket="COR-12366", grade="好", note="一次做对", now=NOW,
                            runs_fn=lambda _t: (runs, None), agents_fn=lambda: (agents, None))
        self.assertEqual((row["run_id"], row["model"], row["machine"], row["account"], row["source"]),
                         ("run-2", "mimo-v2.6-flash", "mini", "falcon", "multica 现查"))
        self.assertEqual(row["run_created_bj"], "2026-10-03 22:46:36")

    def test_no_run_needs_model_override_and_bad_grade_rejected(self) -> None:
        none = dict(runs_fn=lambda _t: ([], None), agents_fn=lambda: ([], None))
        with self.assertRaises(LookupError):
            rv.add_review(self.reviews, self.occ, ticket="COR-5", grade="好", note="x", now=NOW, **none)
        row = rv.add_review(self.reviews, self.occ, ticket="COR-5", grade="一般", note="本机线做的", model_override="本机线",
                            now=NOW, **none)
        self.assertEqual((row["model"], row["source"]), ("本机线", "手填模型"))
        with self.assertRaises(ValueError):
            rv.add_review(self.reviews, self.occ, ticket="COR-5", grade="不错", note="x", now=NOW, **none)

    def test_reviewer_default_reads_env_then_unknown(self) -> None:
        self.assertEqual(rv.default_reviewer({"CLAUDE_WINDOW_NAME": "流程管理"}), "流程管理")
        self.assertEqual(rv.default_reviewer({}), "unknown")

    def test_keep_note_is_created(self) -> None:
        import os
        os.environ["CORTEX_SENTINEL_REVIEWS_DIR"] = str(self.reviews / "x")
        self.addCleanup(os.environ.pop, "CORTEX_SENTINEL_REVIEWS_DIR", None)
        base = rv.reviews_dir()
        lines = (base / "不要删除.md").read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines[0], "CORTEX-KEEP")
        self.assertEqual(lines[1], "# 不要删除 · 一定保留 · DO NOT DELETE")


class SummaryTests(unittest.TestCase):
    def test_groups_by_model_counts_grades_and_keeps_last_three_notes(self) -> None:
        rows = [
            {"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "model": "glm", "grade": "好", "note": "甲"},
            {"ts_bj": "2026-10-04 01:01:00", "ticket": "COR-2", "model": "glm", "grade": "差", "note": "乙"},
            {"ts_bj": "2026-10-04 01:02:00", "ticket": "COR-3", "model": "glm", "grade": "一般", "note": "丙"},
            {"ts_bj": "2026-10-04 01:03:00", "ticket": "COR-4", "model": "glm", "grade": "好", "note": "丁" * 60},
            {"ts_bj": "2026-10-04 01:04:00", "ticket": "COR-5", "model": "sol", "grade": "好", "note": "戊"},
            {"ts_bj": "2026-09-01 01:04:00", "ticket": "COR-6", "model": "sol", "grade": "差", "note": "太老不算"},
        ]
        out = {e["model"]: e for e in rv.summarize(rows, now=NOW, days=7)}
        self.assertEqual(set(out), {"glm", "sol"})
        self.assertEqual((out["glm"]["good"], out["glm"]["ok"], out["glm"]["bad"], out["glm"]["total"]), (2, 1, 1, 4))
        self.assertEqual([r["ticket"] for r in out["glm"]["recent"]], ["COR-4", "COR-3", "COR-2"])
        self.assertLessEqual(len(out["glm"]["recent"][0]["note"]), 40)
        self.assertEqual((out["sol"]["good"], out["sol"]["bad"]), (1, 0))
        text = rv.format_summary(rv.summarize(rows, now=NOW, days=7), 7)
        self.assertIn("glm  好 2 / 一般 1 / 差 1", text)
        self.assertEqual(len([l for l in text.splitlines() if l.startswith(("glm", "sol"))]), 2)


class PendingTests(unittest.TestCase):
    def test_pending_skips_reviewed_unfinished_and_in_flight(self) -> None:
        rows = [
            dispatch_row("r1", "COR-1", "glm", "2026-10-04 00:10:00"),   # 完工、没评价 -> 进清单
            dispatch_row("r2", "COR-2", "sol", "2026-10-04 00:20:00"),   # 完工、已评价 -> 排掉
            dispatch_row("r3", "COR-3", "glm", "2026-10-04 00:30:00"),   # 还在跑
            dispatch_row("r4", "COR-4", "glm", "2026-10-04 00:40:00"),   # 失败，不算完工
            dispatch_row("r5", "COR-5", "mimo", "2026-10-04 00:50:00"),  # 完工一轮后评论叫醒又在跑
            dispatch_row("r6", "COR-5", "mimo", "2026-10-04 01:00:00"),
        ]
        current = {
            "r1": {"id": "r1", "status": "completed", "completed_at": "2026-10-03T17:00:00Z"},
            "r2": {"id": "r2", "status": "completed", "completed_at": "2026-10-03T17:10:00Z"},
            "r3": {"id": "r3", "status": "running"},
            "r4": {"id": "r4", "status": "failed"},
            "r5": {"id": "r5", "status": "completed", "completed_at": "2026-10-03T17:20:00Z"},
            "r6": {"id": "r6", "status": "running"},
        }
        items, in_flight = rv.compute_pending(rows, current, reviewed={"COR-2"})
        self.assertEqual([(p["ticket"], p["model"], p["completed_bj"]) for p in items],
                         [("COR-1", "glm", "2026-10-04 01:00:00")])
        self.assertEqual(in_flight, 2)

    def test_fetch_current_runs_falls_back_to_issue_runs_for_uncovered(self) -> None:
        rows = [dispatch_row("r1", "COR-1", "glm", "2026-10-04 00:10:00", executor_id="ex-1"),
                dispatch_row("r2", "COR-2", "glm", "2026-10-04 00:20:00", executor_id="ex-1")]
        agent_runs = lambda _aid: ([{"id": "r1", "status": "completed", "completed_at": "2026-10-03T17:00:00Z"}], None)
        calls: list = []

        def issue_runs(ticket: str):
            calls.append(ticket)
            return [{"id": "r2", "status": "completed", "completed_at": "2026-10-03T17:05:00Z"}], None

        current = rv.fetch_current_runs(rows, agent_runs_fn=agent_runs, issue_runs_fn=issue_runs)
        self.assertEqual(sorted(current), ["r1", "r2"])
        self.assertEqual(calls, ["COR-2"])

    def test_parse_since_today_is_beijing_midnight(self) -> None:
        self.assertEqual(occ.fmt_bj(rv.parse_since("今天", NOW)), "2026-10-04 00:00:00")
        self.assertEqual(occ.fmt_bj(rv.parse_since("昨天", NOW)), "2026-10-03 00:00:00")


class PeersAndBoardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.reviews = Path(self.tmp.name) / "reviews"
        self.occ = Path(self.tmp.name) / "occupancy"
        self.reviews.mkdir()
        self.occ.mkdir()

    def test_read_peer_parses_both_sections_and_reports_failure(self) -> None:
        seen: list = []

        def ok_runner(argv, timeout=0):
            seen.append(argv)
            return ('@@reviews\n{"ticket":"COR-1","model":"glm","grade":"好","ts_bj":"2026-10-04 01:00:00"}\n\n'
                    '@@dispatch\n{"run_id":"r1","ticket":"COR-1"}\n\nnot json\n'), None

        reviews, rows, err = rv.read_peer("cortex-pro", ["2026-10-04"], runner=ok_runner)
        self.assertEqual((len(reviews), len(rows), err), (1, 1, None))
        # 只读：远端命令里只有 cat / echo，没有重定向写入
        remote = seen[0][-1]
        self.assertIn("cat ", remote)
        self.assertNotIn(">", remote.replace("2>/dev/null", ""))
        _r, _d, err = rv.read_peer("cortex-mini", [], runner=lambda argv, timeout=0: (None, "退出码 255：ssh: timed out"))
        self.assertIn("timed out", err)

    def test_gather_merges_three_machines_dedupes_and_names_unreachable(self) -> None:
        occ.append_jsonl(rv.reviews_file(self.reviews), {"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "by": "甲", "note": "x", "model": "glm", "grade": "好"})
        write_dispatch(self.occ, [dispatch_row("r1", "COR-1", "glm", "2026-10-04 00:10:00")])

        def reader(alias, days):
            if alias == "cortex-mini":
                return [], [], "退出码 255：ssh: connect timed out"
            return ([{"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "by": "甲", "note": "x", "model": "glm", "grade": "好"},
                     {"ts_bj": "2026-10-04 01:30:00", "ticket": "COR-2", "by": "乙", "note": "y", "model": "sol", "grade": "差"}],
                    [dispatch_row("r1", "COR-1", "glm", "2026-10-04 00:10:00"),
                     dispatch_row("r9", "COR-9", "sol", "2026-10-04 00:20:00")], None)

        since = occ.parse_when("2026-10-04 00:00", today=NOW)
        reviews, rows, read_from, missed = rv.gather(self.reviews, self.occ, since=since, now=NOW, reader=reader,
                                                     aliases=["cortex-pro", "cortex-mini"])
        self.assertEqual(sorted(r["ticket"] for r in reviews), ["COR-1", "COR-2"])
        self.assertEqual(sorted(r["run_id"] for r in rows), ["r1", "r9"])
        self.assertEqual(read_from, ["本机", "cortex-pro"])
        self.assertEqual(len(missed), 1)
        self.assertIn("cortex-mini", missed[0])
        text = rv.format_summary(rv.summarize(reviews, now=NOW, days=7), 7, read_from, missed)
        self.assertIn("没读到：cortex-mini", text)
        self.assertIn("合看：本机、cortex-pro", text)

    def test_local_only_never_calls_reader(self) -> None:
        def boom(alias, days):
            raise AssertionError("不该读对方")

        _r, _d, read_from, missed = rv.gather(self.reviews, self.occ, peers=False, reader=boom)
        self.assertEqual((read_from, missed), (["本机"], []))

    def test_board_rows_adds_completed_runs_missing_from_dispatch_log(self) -> None:
        # COR-12366 这类零点前完工、派工记录里没有的票：看板扫出来补成行，能进 pending
        agents = [{"id": "ex-1", "name": "Pro 执行者(ZCode GLM Flash·Falcon 套餐)", "model": "glm-5.3-flash"}]
        board = {"ex-1": [
            {"id": "rb1", "issue_id": "iss-b1", "status": "completed", "created_at": "2026-10-03T14:46:36Z",
             "completed_at": "2026-10-03T14:53:15Z"},
            {"id": "rb2", "issue_id": "iss-b2", "status": "completed", "created_at": "2026-10-02T01:00:00Z",
             "completed_at": "2026-10-02T02:00:00Z"},   # 早于时段，不补
            {"id": "rk", "issue_id": "iss-k", "status": "completed", "created_at": "2026-10-03T14:00:00Z",
             "completed_at": "2026-10-03T14:10:00Z"},   # 派工记录已有，不重复补
        ]}
        since = occ.parse_when("2026-10-03 00:00", today=NOW)
        extra = rv.board_rows(agents, board, {"rk"}, since, {"iss-b1": "COR-12366"})
        self.assertEqual([(r["run_id"], r["ticket"], r["model"], r["machine"]) for r in extra],
                         [("rb1", "COR-12366", "glm-5.3-flash", "pro")])
        current = {r["id"]: r for runs in board.values() for r in runs}
        items, _flying = rv.compute_pending(extra, current, reviewed=set())
        self.assertEqual([(p["ticket"], p["completed_bj"]) for p in items], [("COR-12366", "2026-10-03 22:53:15")])


if __name__ == "__main__":
    unittest.main()
