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


OFFLINE = dict(runs_fn=lambda _t: (None, "离线"), agents_fn=lambda: (None, "离线"))


def mk_run(run_id: str, status: str, created: str, started: str = "", completed: str = "", agent_id: str = "ex-7") -> dict:
    return {"id": run_id, "agent_id": agent_id, "status": status, "created_at": created,
            "started_at": started or None, "completed_at": completed or None}


def dispatch_row(run_id: str, ticket: str, model: str, created_bj: str, executor: str = "Pro 执行者(ZCode GLM Flash·Falcon 套餐)",
                 machine: str = "pro", account: str = "falcon", executor_id: str = "ex-1", status: str = "running") -> dict:
    return {"run_id": run_id, "ticket": ticket, "model": model, "created_bj": created_bj, "ts_bj": created_bj,
            "executor": executor, "executor_id": executor_id, "machine": machine, "account": account,
            "status_at_seen": status}


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

    def test_add_takes_model_and_executor_from_dispatch_log_when_multica_offline(self) -> None:
        write_dispatch(self.occ, [
            dispatch_row("run-old", "COR-1", "glm-5.3-flash", "2026-10-04 00:10:00", status="completed"),
            dispatch_row("run-new", "COR-1", "gpt-6.1-sol", "2026-10-04 01:10:00",
                         executor="M1Max 执行者(Codex Sol High)", machine="m1max", account="-", executor_id="ex-2",
                         status="completed"),
            dispatch_row("run-cancel", "COR-1", "mimo", "2026-10-04 01:20:00", status="cancelled"),
            dispatch_row("run-other", "COR-2", "mimo-v2.6-flash", "2026-10-04 01:30:00", status="completed"),
        ])
        row = rv.add_review(self.reviews, self.occ, ticket="cor-1", grade="好", note="一轮过", by="窗口甲", now=NOW, **OFFLINE)
        self.assertEqual((row["ticket"], row["run_id"], row["model"], row["machine"], row["account"]),
                         ("COR-1", "run-new", "gpt-6.1-sol", "m1max", "-"))
        self.assertIn("派工记录", row["source"])
        self.assertEqual(row["executor"], "M1Max 执行者(Codex Sol High)")
        self.assertEqual((row["by"], row["grade"], row["note"], row["ts_bj"], row["kind"]),
                         ("窗口甲", "好", "一轮过", "2026-10-04 02:00:00", "review"))
        saved = occ.read_jsonl(rv.reviews_file(self.reviews))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0]["model"], "gpt-6.1-sol")

    def test_run_prefix_picks_older_run(self) -> None:
        write_dispatch(self.occ, [
            dispatch_row("run-old", "COR-1", "glm-5.3-flash", "2026-10-04 00:10:00"),
            dispatch_row("run-new", "COR-1", "gpt-6.1-sol", "2026-10-04 01:10:00"),
        ])
        row = rv.add_review(self.reviews, self.occ, ticket="COR-1", grade="差", note="跑偏", run_prefix="run-o", now=NOW, **OFFLINE)
        self.assertEqual((row["run_id"], row["model"]), ("run-old", "glm-5.3-flash"))

    def test_add_without_run_picks_latest_really_finished_run_from_multica(self) -> None:
        # 现查：最近一条真跑完的（completed 且有实际用时）。没开跑就撤的、被取消的哪怕更新也跳过。
        write_dispatch(self.occ, [dispatch_row("run-x", "COR-9", "glm-5.3-flash", "2026-10-04 00:10:00", executor_id="ex-7")])
        runs = [
            mk_run("run-cancel-unstarted", "cancelled", "2026-10-03T16:00:00Z", completed="2026-10-03T16:04:00Z"),
            mk_run("run-cancel-long", "cancelled", "2026-10-03T15:00:00Z", "2026-10-03T15:00:01Z", "2026-10-03T16:40:00Z"),
            mk_run("run-zero", "completed", "2026-10-03T14:50:00Z", "2026-10-03T14:50:00Z", "2026-10-03T14:50:00Z"),
            mk_run("run-2", "completed", "2026-10-03T14:46:36Z", "2026-10-03T14:46:37Z", "2026-10-03T14:53:15Z"),
            mk_run("run-1", "completed", "2026-10-03T10:00:00Z", "2026-10-03T10:00:05Z", "2026-10-03T10:30:00Z", agent_id="ex-3"),
        ]
        agents = [{"id": "ex-7", "name": "mini 执行者(MiMo v2.6 Flash Go)", "model": "mimo-v2.6-flash"}]
        row = rv.add_review(self.reviews, self.occ, ticket="COR-12366", grade="好", note="一次做对", now=NOW,
                            runs_fn=lambda _t: (runs, None), agents_fn=lambda: (agents, None))
        self.assertEqual((row["run_id"], row["model"], row["machine"], row["account"], row["source"]),
                         ("run-2", "mimo-v2.6-flash", "mini", "falcon", "multica 现查"))
        self.assertEqual((row["run_created_bj"], row["run_secs"]), ("2026-10-03 22:46:36", 398))

    def test_add_without_run_refuses_when_nothing_really_finished(self) -> None:
        runs = [mk_run("run-a", "cancelled", "2026-10-03T16:00:00Z", completed="2026-10-03T16:04:00Z"),
                mk_run("run-b", "failed", "2026-10-03T15:00:00Z", "2026-10-03T15:00:01Z", "2026-10-03T15:10:00Z")]
        live = dict(runs_fn=lambda _t: (runs, None), agents_fn=lambda: ([], None))
        with self.assertRaises(LookupError) as ctx:
            rv.add_review(self.reviews, self.occ, ticket="COR-12153", grade="好", note="x", now=NOW, **live)
        self.assertIn("--run", str(ctx.exception))
        self.assertEqual(occ.read_jsonl(rv.reviews_file(self.reviews)), [])
        # 明写 --run 才能评被取消的那条，状态不管
        row = rv.add_review(self.reviews, self.occ, ticket="COR-12153", grade="一般", note="被撤", run_prefix="run-a",
                            now=NOW, **live)
        self.assertEqual((row["run_id"], row["run_secs"]), ("run-a", None))

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

    def test_later_review_of_same_ticket_and_run_overrides_earlier(self) -> None:
        rows = [
            {"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-12403", "run_id": "r1", "model": "glm", "grade": "好", "note": "先评好"},
            {"ts_bj": "2026-10-04 02:30:00", "ticket": "COR-12403", "run_id": "r1", "model": "glm", "grade": "一般", "note": "被翻案，改一般"},
            {"ts_bj": "2026-10-04 01:10:00", "ticket": "COR-12403", "run_id": "r2", "model": "glm", "grade": "差", "note": "另一条 run 各算各的"},
            {"ts_bj": "2026-10-04 01:20:00", "ticket": "COR-7", "run_id": "r1", "model": "glm", "grade": "好", "note": "别的票同号 run 不受影响"},
        ]
        (entry,) = rv.summarize(rows, now=NOW, days=7)
        self.assertEqual((entry["good"], entry["ok"], entry["bad"], entry["total"]), (1, 1, 1, 3))
        notes = [r["note"] for r in entry["recent"]]
        self.assertIn("被翻案，改一般", notes)
        self.assertNotIn("先评好", notes)
        self.assertEqual(entry["recent"][0]["note"], "被翻案，改一般")
        # 旧行没动：原始记录两条都还在，只是汇总不重复算
        self.assertEqual(len(rows), 4)
        # 后评在文件里排在前面也认时刻不认行序
        flipped = [rows[1], rows[0]]
        (again,) = rv.summarize(flipped, now=NOW, days=7)
        self.assertEqual((again["good"], again["ok"], again["total"]), (0, 1, 1))


class VoidTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.reviews = Path(self.tmp.name) / "reviews"
        self.occ = Path(self.tmp.name) / "occupancy"
        self.reviews.mkdir()
        self.occ.mkdir()

    def put(self, **row) -> None:
        occ.append_jsonl(rv.reviews_file(self.reviews), row)

    def test_void_drops_the_whole_run_from_summary_and_keeps_old_rows(self) -> None:
        self.put(ts_bj="2026-10-04 01:39:00", ticket="COR-12153", run_id="01a1009f-aaaa", model="opencode/muse-spark", grade="好", note="误记")
        self.put(ts_bj="2026-10-04 01:45:00", ticket="COR-12153", run_id="01a1009f-aaaa", model="未起跑（不计口碑）", grade="一般", note="没开跑就被撤")
        self.put(ts_bj="2026-10-04 01:45:30", ticket="COR-12153", run_id="01a10012-bbbb", model="glm", grade="好", note="真跑完的那条")
        before = {e["model"] for e in rv.summarize(occ.read_jsonl(rv.reviews_file(self.reviews)), now=NOW)}
        self.assertEqual(before, {"未起跑（不计口碑）", "glm"})
        row = rv.void_review(self.reviews, self.occ, ticket="cor-12153", run_prefix="01a1009f", note="没起跑，不计口碑",
                             by="cortex-2c", now=NOW, **OFFLINE)
        self.assertEqual((row["kind"], row["ticket"], row["run_id"], row["voided_grade"], row["voided_model"]),
                         ("void", "COR-12153", "01a1009f-aaaa", "一般", "未起跑（不计口碑）"))
        rows = occ.read_jsonl(rv.reviews_file(self.reviews))
        self.assertEqual(len(rows), 4)  # 旧行都还在，只多了一行作废
        entries = rv.summarize(rows, now=NOW)
        self.assertEqual([(e["model"], e["total"]) for e in entries], [("glm", 1)])
        text = rv.format_summary(entries, 7)
        self.assertNotIn("未起跑", text)
        self.assertNotIn("opencode", text)  # 同一条 run 上更早的误记「好」也一起不算

    def test_later_review_revives_a_voided_run_and_other_runs_are_untouched(self) -> None:
        self.put(ts_bj="2026-10-04 01:00:00", ticket="COR-1", run_id="r1-aaaa", model="glm", grade="好", note="a")
        self.put(ts_bj="2026-10-04 01:01:00", ticket="COR-1", run_id="r2-bbbb", model="glm", grade="差", note="b")
        rv.void_review(self.reviews, self.occ, ticket="COR-1", run_prefix="r1", note="误记", now=NOW, **OFFLINE)
        (e,) = rv.summarize(occ.read_jsonl(rv.reviews_file(self.reviews)), now=NOW)
        self.assertEqual((e["good"], e["bad"], e["total"]), (0, 1, 1))
        later = NOW + timedelta(minutes=5)
        occ.append_jsonl(rv.reviews_file(self.reviews), {"ts_bj": occ.fmt_bj(later), "kind": "review", "ticket": "COR-1",
                                                         "run_id": "r1-aaaa", "model": "glm", "grade": "一般", "note": "重评"})
        (e,) = rv.summarize(occ.read_jsonl(rv.reviews_file(self.reviews)), now=later)
        self.assertEqual((e["good"], e["ok"], e["bad"], e["total"]), (0, 1, 1, 2))

    def test_void_needs_run_and_reason_and_resolvable_run(self) -> None:
        with self.assertRaises(ValueError):
            rv.void_review(self.reviews, self.occ, ticket="COR-1", run_prefix="", note="x", now=NOW, **OFFLINE)
        with self.assertRaises(ValueError):
            rv.void_review(self.reviews, self.occ, ticket="COR-1", run_prefix="r1", note=" ", now=NOW, **OFFLINE)
        with self.assertRaises(LookupError):
            rv.void_review(self.reviews, self.occ, ticket="COR-1", run_prefix="zzz", note="x", now=NOW, **OFFLINE)
        self.put(ts_bj="2026-10-04 01:00:00", ticket="COR-1", run_id="r1-aaaa", model="glm", grade="好", note="a")
        self.put(ts_bj="2026-10-04 01:01:00", ticket="COR-1", run_id="r1-bbbb", model="glm", grade="好", note="b")
        with self.assertRaises(ValueError):  # 前缀对到两条，要写长
            rv.void_review(self.reviews, self.occ, ticket="COR-1", run_prefix="r1", note="x", now=NOW, **OFFLINE)

    def test_pending_counts_a_ticket_again_when_its_only_review_was_voided(self) -> None:
        rows = [dispatch_row("r1", "COR-1", "glm", "2026-10-04 00:10:00")]
        current = {"r1": {"id": "r1", "status": "completed", "completed_at": "2026-10-03T17:00:00Z"}}
        reviews = [{"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "run_id": "r1", "grade": "好"},
                   {"ts_bj": "2026-10-04 01:05:00", "kind": "void", "ticket": "COR-1", "run_id": "r1"}]
        reviewed = {str(r.get("ticket")).upper() for r in rv.live_reviews(reviews)}
        items, _ = rv.compute_pending(rows, current, reviewed)
        self.assertEqual([p["ticket"] for p in items], ["COR-1"])


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
