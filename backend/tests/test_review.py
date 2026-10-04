from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cortex_sentinel import occupancy as occ  # noqa: E402
from cortex_sentinel import review as rv  # noqa: E402

_ENV_KEYS = ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CORTEX_REVIEWER", "CLAUDE_WINDOW_NAME",
             "CLAUDE_CODE_WINDOW_NAME", "CLAUDE_SESSION_NAME", "CORTEX_WINDOW_NAME", "CORTEX_REVIEWER_MODEL",
             "ANTHROPIC_MODEL", "CLAUDE_CODE_MODEL", "CLAUDE_MODEL", "CODEX_MODEL", "OPENAI_MODEL")


def setUpModule() -> None:
    # 测试不读真实窗口的会话记录：把身份相关环境变量清掉
    patcher = mock.patch.dict(os.environ, {}, clear=False)
    patcher.start()
    for key in _ENV_KEYS:
        os.environ.pop(key, None)
    unittest.addModuleCleanup(patcher.stop)


NOW = datetime(2026, 10, 3, 18, 0, 0, tzinfo=timezone.utc)  # 北京 2026-10-04 02:00


OFFLINE = dict(runs_fn=lambda _t: (None, "离线"), agents_fn=lambda: (None, "离线"))


def mk_run(run_id: str, status: str, created: str, started: str = "", completed: str = "", agent_id: str = "ex-7",
           usage: object = None) -> dict:
    return {"id": run_id, "agent_id": agent_id, "status": status, "created_at": created,
            "started_at": started or None, "completed_at": completed or None, "usage": usage}


def usage_of(model: str, tokens: int = 1000) -> list:
    return [{"model": model, "input_tokens": tokens, "output_tokens": 10, "cache_read_tokens": 5, "provider": "claude"}]


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
        patcher = mock.patch.object(rv, "fetch_issue_title", lambda t: f"标题-{t}")
        patcher.start()
        self.addCleanup(patcher.stop)
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
            mk_run("run-2", "completed", "2026-10-03T14:46:36Z", "2026-10-03T14:46:37Z", "2026-10-03T14:53:15Z",
                   usage=usage_of("mimo-v2.6-flash[1m]")),
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


class ActualModelTests(unittest.TestCase):
    def setUp(self) -> None:
        patcher = mock.patch.object(rv, "fetch_issue_title", lambda t: f"标题-{t}")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.reviews = Path(self.tmp.name) / "reviews"
        self.occ = Path(self.tmp.name) / "occupancy"
        self.reviews.mkdir()
        self.occ.mkdir()

    def test_actual_model_reads_usage_strips_suffix_and_ignores_empty(self) -> None:
        self.assertEqual(rv.actual_model({"usage": usage_of("muse-spark-1.3-contributor[1m]")}), "muse-spark-1.3-contributor")
        self.assertEqual(rv.actual_model({"usage": usage_of("mimo-v2.6-flash") + usage_of("mimo-v2.6-flash[1m]", 50)}),
                         "mimo-v2.6-flash")
        big, small = usage_of("kimi-code/k3", 9000), usage_of("haiku", 10)
        self.assertEqual(rv.actual_model({"usage": small + big}), "kimi-code/k3")
        self.assertIsNone(rv.actual_model({"usage": [{"model": "x", "input_tokens": 0, "output_tokens": 0}]}))
        self.assertIsNone(rv.actual_model({"usage": None}))
        self.assertIsNone(rv.actual_model({}))

    def test_add_takes_the_model_the_run_really_used_not_the_executor_config(self) -> None:
        # COR-12266：执行者配置现在写小米，那条 run 当时实际跑的是 Spark（Go 钥匙）
        agents = [{"id": "ex-7", "name": "Pro 执行者(MiMo v2.6 Flash Go)", "model": "mimo-v2.6-flash"}]
        runs = [mk_run("run-s", "completed", "2026-10-03T09:13:13Z", "2026-10-03T09:13:14Z", "2026-10-03T09:30:00Z",
                       usage=usage_of("muse-spark-1.3-contributor[1m]"))]
        row = rv.add_review(self.reviews, self.occ, ticket="COR-12266", grade="好", note="x", now=NOW,
                            runs_fn=lambda _t: (runs, None), agents_fn=lambda: (agents, None))
        self.assertEqual((row["model"], row["model_verified"], row["source"]), ("muse-spark-1.3-contributor", True, "multica 现查"))

    def test_add_marks_model_unverified_when_run_has_no_usage(self) -> None:
        agents = [{"id": "ex-7", "name": "Pro 执行者(MiMo v2.6 Flash Go)", "model": "mimo-v2.6-flash"}]
        runs = [mk_run("run-n", "completed", "2026-10-03T09:13:13Z", "2026-10-03T09:13:14Z", "2026-10-03T09:30:00Z", usage=[])]
        row = rv.add_review(self.reviews, self.occ, ticket="COR-1", grade="好", note="x", now=NOW,
                            runs_fn=lambda _t: (runs, None), agents_fn=lambda: (agents, None))
        self.assertEqual((row["model"], row["model_verified"]), ("mimo-v2.6-flash", False))
        self.assertIn("模型未核", row["source"])

    def test_summary_groups_by_raw_model_string_so_unseen_models_get_their_own_row(self) -> None:
        # 代码里没有任何模型名单：数据里出现什么模型串就出什么行。免费 / 付费 Spark、没见过的 k3 都靠串本身分开。
        rows = [
            {"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "run_id": "a", "model": "opencode/muse-spark-1.3-contributor-free", "grade": "好", "note": "免费"},
            {"ts_bj": "2026-10-04 01:01:00", "ticket": "COR-2", "run_id": "b", "model": "muse-spark-1.3-contributor[1m]", "grade": "差", "note": "付费"},
            {"ts_bj": "2026-10-04 01:02:00", "ticket": "COR-3", "run_id": "c", "model": "kimi-code/k3", "grade": "一般", "note": "新模型"},
            {"ts_bj": "2026-10-04 01:03:00", "ticket": "COR-4", "run_id": "d", "model": "zz-never-seen-model-9", "grade": "好", "note": "从没见过的串"},
        ]
        entries = {e["model"]: e for e in rv.summarize(rows, now=NOW)}
        self.assertEqual(set(entries), {"opencode/muse-spark-1.3-contributor-free", "muse-spark-1.3-contributor",
                                        "kimi-code/k3", "zz-never-seen-model-9"})
        self.assertNotIn("label", entries["kimi-code/k3"])
        text = rv.format_summary(list(entries.values()), 7)
        self.assertIn("zz-never-seen-model-9  好 1 / 一般 0 / 差 0", text)
        self.assertIn("muse-spark-1.3-contributor  好 0 / 一般 0 / 差 1", text)
        # list 不改代码就能按子串查到没见过的模型；查不到别名不报错
        self.assertEqual([r["ticket"] for r in rv.list_reviews(rows, now=NOW, model="never-seen")], ["COR-4"])
        self.assertEqual([r["ticket"] for r in rv.list_reviews(rows, now=NOW, model="K3")], ["COR-3"])
        self.assertEqual(rv.list_reviews(rows, now=NOW, model="没有这个模型"), [])

    def test_aliases_come_from_a_file_and_unknown_alias_falls_back_to_substring(self) -> None:
        shipped = rv.load_aliases(None)  # 随代码带的那份
        self.assertIn("小米", shipped)
        base = Path(self.tmp.name) / "reviews"
        base.mkdir(exist_ok=True)
        (base / rv.ALIASES_NAME).write_text(json.dumps({"_说明": "x", "我的k": ["kimi", "k3"], "SPARK": "muse-spark"}), encoding="utf-8")
        mine = rv.load_aliases(base)  # 评价记录目录里的那份优先，下划线开头的键是说明不算
        self.assertEqual(set(mine), {"我的k", "spark"})
        self.assertTrue(rv.model_matches("kimi-code/k3", "我的k", mine))
        self.assertTrue(rv.model_matches("muse-spark-1.3-contributor", "Spark", mine))
        self.assertTrue(rv.model_matches("mimo-v2.6-flash", "mimo", mine))        # 不在表里：按子串
        self.assertFalse(rv.model_matches("mimo-v2.6-flash", "kimi", mine))
        shipped_free = rv.model_matches("opencode/muse-spark-1.3-contributor-free", "免费spark", shipped)
        shipped_paid = rv.model_matches("muse-spark-1.3-contributor", "免费spark", shipped)
        self.assertEqual((shipped_free, shipped_paid), (True, False))
        self.assertTrue(rv.model_matches("muse-spark-1.3-contributor", "付费spark", shipped))
        self.assertFalse(rv.model_matches("opencode/muse-spark-1.3-contributor-free", "付费spark", shipped))
        self.assertTrue(rv.model_matches("x", "", shipped))

    def test_model_order_usage_then_dispatch_snapshot_then_current_config_marked_unverified(self) -> None:
        agents = [{"id": "ex-7", "name": "Pro 执行者(某个通道)", "model": "config-now"}]
        occ_base = Path(self.tmp.name) / "occupancy"
        occ_base.mkdir(exist_ok=True)
        done = ("2026-10-03T09:13:13Z", "2026-10-03T09:13:14Z", "2026-10-03T09:30:00Z")
        # 1 有用量：取用量里的（带通道）
        run1 = mk_run("r1", "completed", *done, usage=usage_of("kimi-code/k3"))
        d1 = rv.describe_run(run1, occ_base, lambda: (agents, None))
        self.assertEqual((d1["model"], d1["model_verified"], d1["provider"], d1["source"]), ("kimi-code/k3", True, "claude", "multica 现查"))
        # 2 没用量，但派工记录里有这条 run 当时的配置：取它，不算未核
        write_dispatch(occ_base, [dispatch_row("r2", "COR-2", "config-at-run", "2026-10-04 00:10:00")])
        d2 = rv.describe_run(mk_run("r2", "completed", *done, usage=[]), occ_base, lambda: (agents, None))
        self.assertEqual((d2["model"], d2["model_verified"]), ("config-at-run", True))
        self.assertIn("当时的执行者配置", d2["source"])
        # 3 都没有：退执行者现配置，标未核
        d3 = rv.describe_run(mk_run("r3", "completed", *done, usage=[]), occ_base, lambda: (agents, None))
        self.assertEqual((d3["model"], d3["model_verified"]), ("config-now", False))
        self.assertIn("模型未核", d3["source"])

    def test_reverify_corrects_wrong_models_only_for_matching_executors_and_keeps_old_rows(self) -> None:
        old = lambda **kw: {"ts_bj": "2026-10-04 01:00:00", "kind": "review", "grade": "好", "note": "n", "by": "甲", **kw}
        reviews = [
            old(ticket="COR-12266", run_id="r-spark", model="mimo-v2.6-flash", executor="Pro 执行者(MiMo v2.6 Flash Go)"),
            old(ticket="COR-2", run_id="r-mimo", model="mimo-v2.6-flash", executor="mini 执行者(MiMo v2.6 Flash Go)"),
            old(ticket="COR-3", run_id="r-k3", model="opencode/muse-spark-1.3-contributor-free",
                executor="Pro 执行者(OpenCode Spark 1.3 免费)"),
            old(ticket="COR-4", run_id="r-glm", model="glm-5.3-flash", executor="Pro 执行者(ZCode GLM Flash·Falcon 套餐)"),
            old(ticket="COR-5", run_id="r-none", model="mimo-v2.6-flash", executor="M1Max 执行者(MiMo v2.6 Flash Go)"),
        ]
        runs = {
            "COR-12266": [mk_run("r-spark", "completed", "x", usage=usage_of("muse-spark-1.3-contributor[1m]"))],
            "COR-2": [mk_run("r-mimo", "completed", "x", usage=usage_of("mimo-v2.6-flash[1m]"))],
            "COR-3": [mk_run("r-k3", "completed", "x", usage=usage_of("kimi-code/k3"))],
            "COR-4": [mk_run("r-glm", "completed", "x", usage=usage_of("totally-other"))],
            "COR-5": [mk_run("r-none", "completed", "x", usage=[])],
        }
        asked: list = []

        def fake(ticket):
            asked.append(ticket)
            return runs[ticket], None

        plan = rv.reverify_models(self.reviews, self.occ, match=r"\bGo\b|Spark", apply=False, now=NOW, issue_runs_fn=fake, reviews=reviews)
        self.assertEqual((plan["checked"], plan["corrected"], plan["unchanged"], plan["no_usage"], plan["no_run"]), (4, 2, 1, 1, 0))
        self.assertNotIn("COR-4", asked)  # ZCode 执行者不在核的范围
        self.assertEqual(occ.read_jsonl(rv.reviews_file(self.reviews)), [])  # 没 --apply 不写
        done = rv.reverify_models(self.reviews, self.occ, match=r"\bGo\b|Spark", apply=True, now=NOW, issue_runs_fn=fake, reviews=reviews)
        written = occ.read_jsonl(rv.reviews_file(self.reviews))
        self.assertEqual(sorted((r["ticket"], r["model"]) for r in written),
                         [("COR-12266", "muse-spark-1.3-contributor"), ("COR-3", "kimi-code/k3")])
        self.assertTrue(all(r["orig_ts_bj"] == "2026-10-04 01:00:00" and r["ts_bj"] > r["orig_ts_bj"] for r in written))
        # 旧行留着，新行覆盖：合起来汇总时 COR-12266 算到 Spark 付费头上，小米只剩真跑小米的 COR-2 和没法核的 COR-5
        merged = reviews + written
        entries = {e["model"]: e for e in rv.summarize(merged, now=NOW)}
        self.assertEqual(entries["mimo-v2.6-flash"]["total"], 2)
        self.assertEqual(entries["muse-spark-1.3-contributor"]["total"], 1)
        self.assertEqual(entries["kimi-code/k3"]["total"], 1)
        self.assertNotIn("opencode/muse-spark-1.3-contributor-free", entries)
        self.assertEqual(len(merged), 7)
        self.assertEqual(done["after"] and len(done["after"]) >= 3, True)
        text = rv.format_reverify(done)
        self.assertIn("改 2 条", text)
        self.assertIn("mimo-v2.6-flash → muse-spark-1.3-contributor", text)

    def test_reverify_defaults_to_all_executors_without_any_name_list(self) -> None:
        reviews = [{"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-4", "run_id": "r-glm", "model": "old-config-model",
                    "executor": "任意执行者(从没见过的通道)", "grade": "好", "note": "n", "by": "甲"}]
        runs = {"COR-4": [mk_run("r-glm", "completed", "x", usage=usage_of("brand-new/model-x"))]}
        plan = rv.reverify_models(self.reviews, self.occ, apply=False, now=NOW, issue_runs_fn=lambda t: (runs[t], None), reviews=reviews)
        self.assertEqual((plan["checked"], plan["corrected"]), (1, 1))
        self.assertEqual(plan["corrections"][0]["model"], "brand-new/model-x")

    def test_corrected_row_keeps_original_time_for_window(self) -> None:
        # 更正写在「现在」，但评价是 10 天前的：仍在 7 天窗口外，不因为更正而重新冒出来
        rows = [
            {"ts_bj": "2026-09-20 01:00:00", "kind": "review", "ticket": "COR-1", "run_id": "a", "model": "mimo", "grade": "好", "note": "旧"},
            {"ts_bj": "2026-10-04 01:00:00", "orig_ts_bj": "2026-09-20 01:00:00", "kind": "review", "ticket": "COR-1",
             "run_id": "a", "model": "muse-spark-1.3-contributor", "grade": "好", "note": "旧"},
        ]
        self.assertEqual(rv.summarize(rows, now=NOW, days=7), [])
        (e,) = rv.summarize(rows, now=NOW, days=30)
        self.assertEqual(e["model"], "muse-spark-1.3-contributor")


class TaskAndListTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.reviews = Path(self.tmp.name) / "reviews"
        self.occ = Path(self.tmp.name) / "occupancy"
        self.reviews.mkdir()
        self.occ.mkdir()
        self.runs = [mk_run("run-1", "completed", "2026-10-03T14:46:36Z", "2026-10-03T14:46:37Z", "2026-10-03T14:53:15Z",
                            usage=usage_of("mimo-v2.6-flash[1m]"))]
        self.agents = [{"id": "ex-7", "name": "Pro 执行者(MiMo v2.6 Flash Go)", "model": "mimo-v2.6-flash"}]
        self.live = dict(runs_fn=lambda _t: (self.runs, None), agents_fn=lambda: (self.agents, None))

    def test_add_records_issue_title_and_reviewer_model_and_caches_title(self) -> None:
        row = rv.add_review(self.reviews, self.occ, ticket="COR-12366", grade="差", note="跑偏了", by="cortex-2c",
                            reviewer_model="Claude Opus 5.5", now=NOW, title_fn=lambda t: "升级前备份真根", **self.live)
        self.assertEqual((row["task"], row["task_src"], row["reviewer_model"]), ("升级前备份真根", "票面标题", "Claude Opus 5.5"))
        self.assertEqual(rv.load_titles(self.reviews), {"COR-12366": "升级前备份真根"})

    def test_reviewer_model_auto_from_env_and_empty_when_unreadable(self) -> None:
        self.assertEqual(rv.default_reviewer_model({"CORTEX_REVIEWER_MODEL": "GLM-5.3 Flash", "ANTHROPIC_MODEL": "x"}), "GLM-5.3 Flash")
        self.assertEqual(rv.default_reviewer_model({"ANTHROPIC_MODEL": "claude-opus"}), "claude-opus")
        self.assertEqual(rv.default_reviewer_model({}), "")
        row = rv.add_review(self.reviews, self.occ, ticket="COR-1", grade="好", note="x", now=NOW,
                            title_fn=lambda t: None, env={}, **self.live)  # 读不到：留空，不报错；标题也查不到照记
        self.assertEqual((row["reviewer_model"], row["task"]), ("", None))
        row2 = rv.add_review(self.reviews, self.occ, ticket="COR-1", grade="好", note="y", now=NOW + timedelta(seconds=5),
                             title_fn=lambda t: None, env={"CORTEX_REVIEWER_MODEL": "Claude Sonnet"}, **self.live)
        self.assertEqual(row2["reviewer_model"], "Claude Sonnet")

    def test_no_ticket_task_needs_task_and_model_and_does_not_collapse(self) -> None:
        with self.assertRaises(ValueError):
            rv.add_review(self.reviews, self.occ, ticket="-", grade="差", note="x", model_override="glm-5.3-flash", now=NOW)
        with self.assertRaises(LookupError):
            rv.add_review(self.reviews, self.occ, ticket="-", grade="差", note="x", task="整理旧文档", now=NOW)
        a = rv.add_review(self.reviews, self.occ, ticket="无票", grade="差", note="删了不该删的目录", task="整理旧文档",
                          model_override="glm-5.3-flash", now=NOW, env={})
        b = rv.add_review(self.reviews, self.occ, ticket="-", grade="好", note="一次就对", task="改一行配置",
                          model_override="glm-5.3-flash", now=NOW + timedelta(seconds=1), env={})
        self.assertEqual((a["ticket"], a["task"], a["task_src"]), ("", "整理旧文档", "手写"))
        self.assertNotEqual(a["run_id"], b["run_id"])
        (e,) = rv.summarize(occ.read_jsonl(rv.reviews_file(self.reviews)), now=NOW + timedelta(minutes=1))
        self.assertEqual((e["good"], e["bad"], e["total"]), (1, 1, 2))

    def test_task_flag_wins_over_issue_title(self) -> None:
        row = rv.add_review(self.reviews, self.occ, ticket="COR-1", grade="好", note="x", task="只改了第二段", now=NOW,
                            title_fn=lambda t: "票面标题", env={}, **self.live)
        self.assertEqual((row["task"], row["task_src"]), ("只改了第二段", "手写"))

    def test_list_filters_by_model_alias_and_grade_and_shows_who_why_task(self) -> None:
        rows = [
            {"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "run_id": "a", "model": "mimo-v2.6-flash", "grade": "差",
             "note": "跑偏", "by": "cortex-2c", "reviewer_model": "Claude Opus 5.5", "machine": "pro", "task": "升级前备份真根，分两步做完整的那一种，要写的很长很长很长很长很长很长很长很长"},
            {"ts_bj": "2026-10-04 01:01:00", "ticket": "COR-2", "run_id": "b", "model": "muse-spark-1.3-contributor", "grade": "差",
             "note": "付费", "by": "窗口乙", "reviewer_model": "", "machine": "mini"},
            {"ts_bj": "2026-10-04 01:02:00", "ticket": "COR-3", "run_id": "c", "model": "opencode/muse-spark-1.3-contributor-free",
             "grade": "好", "note": "免费", "by": "x", "machine": "pro"},
            {"ts_bj": "2026-10-04 01:03:00", "ticket": "COR-4", "run_id": "d", "model": "glm-5.3-flash", "grade": "差", "note": "g", "by": "y", "machine": "m1max"},
            {"ts_bj": "2026-10-04 01:04:00", "kind": "void", "ticket": "COR-2", "run_id": "b"},   # COR-2 被作废
            {"ts_bj": "2026-09-01 01:00:00", "ticket": "COR-9", "run_id": "z", "model": "mimo-v2.6-flash", "grade": "差", "note": "太老", "by": "q"},
        ]
        shipped = rv.load_aliases(None)
        tickets = lambda **kw: [r["ticket"] for r in rv.list_reviews(rows, now=NOW, aliases=shipped, **kw)]
        self.assertEqual(tickets(model="小米", grade="差"), ["COR-1"])
        self.assertEqual(sorted(tickets(model="spark")), ["COR-3"])          # COR-2 已作废；免费 Spark 在内
        self.assertEqual(tickets(model="glm"), ["COR-4"])
        self.assertEqual(sorted(tickets(grade="差")), ["COR-1", "COR-4"])
        self.assertEqual(tickets(model="免费spark"), ["COR-3"])
        self.assertEqual(tickets(model="付费spark"), [])
        line = rv.format_list_line(rv.list_reviews(rows, now=NOW, model="小米", aliases=shipped)[0])
        self.assertIn("2026-10-04 01:00:00 | COR-1 | 升级前备份真根", line)
        self.assertIn("| 差 | 为什么：跑偏 | 评价人 cortex-2c | 评价者模型 Claude Opus 5.5 | 模型 mimo-v2.6-flash | 执行者 - | 机器 pro", line)
        task_cell = line.split(" | ")[2]
        self.assertLessEqual(len(task_cell), 40)
        blank = rv.format_list_line({"ts_bj": "t", "ticket": "COR-5", "grade": "好", "note": "n", "by": "b", "model": "m", "machine": "pro"}, "回填的标题")
        self.assertIn("| 回填的标题 |", blank)
        self.assertIn("评价者模型  |", blank)  # 空的就空着

    def test_backfill_writes_side_table_only_and_leaves_review_rows(self) -> None:
        rv_file = rv.reviews_file(self.reviews)
        occ.append_jsonl(rv_file, {"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "run_id": "a", "model": "m", "grade": "好", "note": "n"})
        occ.append_jsonl(rv_file, {"ts_bj": "2026-10-04 01:01:00", "ticket": "COR-2", "run_id": "b", "model": "m", "grade": "好", "note": "n", "task": "已有"})
        occ.append_jsonl(rv_file, {"ts_bj": "2026-10-04 01:02:00", "ticket": "COR-3", "run_id": "c", "model": "m", "grade": "好", "note": "n"})
        before = rv_file.read_text(encoding="utf-8")
        res = rv.backfill_titles(self.reviews, occ.read_jsonl(rv_file), title_fn=lambda t: {"COR-1": "标题一"}.get(t))
        self.assertEqual(res, {"tickets": 2, "had": 0, "filled": 1, "missing": 1})
        self.assertEqual(rv.load_titles(self.reviews), {"COR-1": "标题一"})
        self.assertEqual(rv_file.read_text(encoding="utf-8"), before)  # 原行一个字没动


class ReviewerIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)

    def write_claude_session(self, sid: str, lines: list) -> None:
        d = self.home / ".claude" / "projects" / "-some-project"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{sid}.jsonl").write_text("\n".join(json.dumps(x, ensure_ascii=False) for x in lines) + "\n", encoding="utf-8")

    def test_claude_code_model_and_window_title_come_from_the_session_record(self) -> None:
        self.write_claude_session("sid-1", [
            {"type": "custom-title", "customTitle": "旧标题", "sessionId": "sid-1"},
            {"type": "assistant", "message": {"model": "claude-sonnet-5-5", "content": "x"}},
            {"type": "user", "message": {"content": "hi"}},
            {"type": "agent-name", "agentName": "流程管理", "sessionId": "sid-1"},
            {"type": "assistant", "message": {"model": "claude-opus-5-5[1m]", "content": "y"}},
            {"type": "assistant", "message": {"model": "<synthetic>", "content": "z"}},
        ])
        env = {"CLAUDE_CODE_SESSION_ID": "sid-1"}
        info = rv.claude_session_info(env, self.home)
        self.assertEqual(info, {"model": "claude-opus-5-5", "title": "流程管理"})
        self.assertEqual(rv.default_reviewer_model(env, self.home), "claude-opus-5-5")
        with mock.patch.object(rv, "local_machine", lambda: "m1max"):
            self.assertEqual(rv.default_reviewer(env, self.home), "流程管理@m1max")

    def test_explicit_env_wins_and_missing_session_gives_blank_not_error(self) -> None:
        self.assertEqual(rv.default_reviewer_model({"CORTEX_REVIEWER_MODEL": "GLM-5.3 Flash", "CLAUDE_CODE_SESSION_ID": "sid-x"}, self.home),
                         "GLM-5.3 Flash")
        self.assertEqual(rv.default_reviewer_model({"CLAUDE_CODE_SESSION_ID": "no-such-session"}, self.home), "")
        self.assertEqual(rv.default_reviewer_model({}, self.home), "")
        self.assertEqual(rv.default_reviewer({"CLAUDE_CODE_SESSION_ID": "0812b8c2-aaaa"}, self.home), "会话 0812b8c2")
        self.assertEqual(rv.default_reviewer({}, self.home), "unknown")
        self.assertEqual(rv.default_reviewer({"CLAUDE_WINDOW_NAME": "窗口甲"}, self.home), "窗口甲")
        self.assertEqual(rv.default_reviewer_model({"CLAUDE_CODE_SESSION_ID": "../etc"}, self.home), "")  # 会话号不许带路径

    def test_codex_model_from_rollout_turn_context(self) -> None:
        d = self.home / ".codex" / "sessions" / "2026" / "10" / "04"
        d.mkdir(parents=True)
        (d / "rollout-2026-10-04T01-00-00-thread-9.jsonl").write_text(
            json.dumps({"type": "turn_context", "payload": {"model": "gpt-6-astra"}}) + "\n"
            + json.dumps({"type": "event_msg", "payload": {"x": 1}}) + "\n"
            + json.dumps({"type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}) + "\n", encoding="utf-8")
        self.assertEqual(rv.default_reviewer_model({"CODEX_THREAD_ID": "thread-9"}, self.home), "gpt-6.1-sol")
        self.assertEqual(rv.default_reviewer_model({"CODEX_THREAD_ID": "thread-0"}, self.home), "")

    def test_add_records_run_start_and_finish_times(self) -> None:
        tmp = Path(self.tmp.name)
        (tmp / "r").mkdir(); (tmp / "o").mkdir()
        runs = [mk_run("run-1", "completed", "2026-10-03T14:46:36Z", "2026-10-03T14:46:37Z", "2026-10-03T14:53:15Z",
                       usage=usage_of("mimo-v2.6-flash[1m]"))]
        agents = [{"id": "ex-7", "name": "Pro 执行者(MiMo v2.6 Flash Go)", "model": "mimo-v2.6-flash"}]
        with mock.patch.object(rv, "fetch_issue_title", lambda t: "标题"):
            row = rv.add_review(tmp / "r", tmp / "o", ticket="COR-1", grade="好", note="x", now=NOW, env={},
                                runs_fn=lambda _t: (runs, None), agents_fn=lambda: (agents, None))
        self.assertEqual((row["run_started_bj"], row["run_finished_bj"], row["run_secs"]),
                         ("2026-10-03 22:46:37", "2026-10-03 22:53:15", 398))


class MirrorAndRestoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name) / "reviews"
        self.base.mkdir()

    def peer(self, files: dict):
        """假的 ssh：files 里 key 是别名，value 是 {'size': n, 'text': '...'}；记下问过的命令。"""
        asked: list = []

        def runner(argv, timeout=0):
            alias, script = argv[-2], argv[-1]
            asked.append((alias, script))
            spec = files.get(alias)
            if spec is None:
                return None, "退出码 255：ssh: connect timed out"
            if script.startswith("wc -c"):
                return f"   {len(spec['text'].encode('utf-8'))}\n", None
            return spec["text"], None

        return runner, asked

    def test_mirror_pulls_both_peers_read_only_and_skips_when_size_unchanged(self) -> None:
        pro = '{"ts_bj":"2026-10-04 01:00:00","ticket":"COR-1","grade":"好"}\n'
        runner, asked = self.peer({"cortex-pro": {"text": pro}, "cortex-mini": {"text": pro + pro}})
        first = rv.sync_mirror(self.base, aliases=["cortex-pro", "cortex-mini"], runner=runner)
        self.assertEqual((len(first["synced"]), first["unchanged"], first["missed"]), (2, [], []))
        self.assertEqual((self.base / "mirror" / "pro.jsonl").read_text(encoding="utf-8"), pro)
        self.assertTrue((self.base / "mirror" / "不要删除.md").read_text(encoding="utf-8").startswith("CORTEX-KEEP"))
        second = rv.sync_mirror(self.base, aliases=["cortex-pro", "cortex-mini"], runner=runner)
        self.assertEqual((second["synced"], sorted(second["unchanged"])), ([], ["mini", "pro"]))
        for _alias, script in asked:   # 只读：只有 wc / cat，没有往对方写的重定向
            self.assertTrue(script.startswith(("wc -c", "cat ")))
            self.assertNotIn(">", script.replace("2>/dev/null", "").replace("< ", ""))

    def test_mirror_never_shrinks_when_peer_file_is_lost_or_truncated(self) -> None:
        good = '{"ts_bj":"2026-10-04 01:00:00","ticket":"COR-1"}\n{"ts_bj":"2026-10-04 01:01:00","ticket":"COR-2"}\n'
        rv.sync_mirror(self.base, aliases=["cortex-pro"], runner=self.peer({"cortex-pro": {"text": good}})[0])
        # 对方的文件被删（空）：备份留着，记一笔
        gone = rv.sync_mirror(self.base, aliases=["cortex-pro"], runner=self.peer({"cortex-pro": {"text": ""}})[0])
        self.assertEqual(len(gone["kept"]), 1)
        self.assertEqual((self.base / "mirror" / "pro.jsonl").read_text(encoding="utf-8"), good)
        # 对方被截短：同样不覆盖
        short = rv.sync_mirror(self.base, aliases=["cortex-pro"], runner=self.peer({"cortex-pro": {"text": good[:30]}})[0])
        self.assertEqual(len(short["kept"]), 1)
        self.assertEqual((self.base / "mirror" / "pro.jsonl").read_text(encoding="utf-8"), good)
        # 对方追加了：照常更新
        more = good + '{"ts_bj":"2026-10-04 01:02:00","ticket":"COR-3"}\n'
        grown = rv.sync_mirror(self.base, aliases=["cortex-pro"], runner=self.peer({"cortex-pro": {"text": more}})[0])
        self.assertEqual(len(grown["synced"]), 1)
        self.assertEqual((self.base / "mirror" / "pro.jsonl").read_text(encoding="utf-8"), more)

    def test_unreachable_peer_is_named_not_silent(self) -> None:
        runner, _ = self.peer({"cortex-pro": {"text": '{"a":1}\n'}})
        res = rv.sync_mirror(self.base, aliases=["cortex-pro", "cortex-mini"], runner=runner)
        self.assertEqual(len(res["synced"]), 1)
        self.assertIn("cortex-mini", res["missed"][0])

    def test_restore_fills_in_what_the_local_file_lost_from_both_peers_backups_and_is_idempotent(self) -> None:
        a = {"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "run_id": "r1", "grade": "好", "note": "甲"}
        b = {"ts_bj": "2026-10-04 01:05:00", "ticket": "COR-2", "run_id": "r2", "grade": "差", "note": "乙"}
        c = {"ts_bj": "2026-10-04 01:03:00", "ticket": "COR-3", "run_id": "r3", "grade": "一般", "note": "丙"}
        occ.append_jsonl(rv.reviews_file(self.base), a)   # 本机还剩第一条，后面的丢了
        asked: list = []

        def runner(argv, timeout=0):
            asked.append(argv[-1])
            text = {"cortex-pro": json.dumps(a) + "\n" + json.dumps(b) + "\n",
                    "cortex-mini": json.dumps(a) + "\n" + json.dumps(c) + "\n"}.get(argv[-2])
            return (text, None) if text is not None else (None, "ssh: timed out")

        plan = rv.restore_from_peers(self.base, apply=False, me="m1max", aliases=["cortex-pro", "cortex-mini", "cortex-x"], runner=runner)
        self.assertEqual((plan["local"], plan["missing"], plan["sources"]), (1, 2, {"cortex-pro": 2, "cortex-mini": 2}))
        self.assertIn("cortex-x", plan["missed"][0])
        self.assertEqual(len(occ.read_jsonl(rv.reviews_file(self.base))), 1)    # 没 --apply 不写
        self.assertTrue(all("mirror/m1max.jsonl" in s for s in asked))          # 读的是对方手里「本机」的备份
        done = rv.restore_from_peers(self.base, apply=True, me="m1max", aliases=["cortex-pro", "cortex-mini"], runner=runner)
        self.assertEqual(done["missing"], 2)
        rows = occ.read_jsonl(rv.reviews_file(self.base))
        self.assertEqual([r["ticket"] for r in rows], ["COR-1", "COR-3", "COR-2"])   # 原行在前不动，补回的按时刻追加
        again = rv.restore_from_peers(self.base, apply=True, me="m1max", aliases=["cortex-pro", "cortex-mini"], runner=runner)
        self.assertEqual(again["missing"], 0)
        self.assertEqual(len(occ.read_jsonl(rv.reviews_file(self.base))), 3)

    def test_restore_when_local_file_is_completely_gone(self) -> None:
        row = {"ts_bj": "2026-10-04 01:00:00", "ticket": "COR-1", "run_id": "r1", "grade": "好", "note": "甲"}
        runner = lambda argv, timeout=0: (json.dumps(row) + "\n", None)
        res = rv.restore_from_peers(self.base, apply=True, me="pro", aliases=["cortex-mini"], runner=runner)
        self.assertEqual((res["local"], res["missing"]), (0, 1))
        self.assertEqual(len(occ.read_jsonl(rv.reviews_file(self.base))), 1)

    def test_keep_note_says_three_way_backup_and_old_note_is_upgraded(self) -> None:
        import os
        os.environ["CORTEX_SENTINEL_REVIEWS_DIR"] = str(self.base / "k")
        self.addCleanup(os.environ.pop, "CORTEX_SENTINEL_REVIEWS_DIR", None)
        d = Path(os.environ["CORTEX_SENTINEL_REVIEWS_DIR"])
        d.mkdir()
        (d / "不要删除.md").write_text("CORTEX-KEEP\n# 旧版说明\n", encoding="utf-8")
        rv.reviews_dir()
        text = (d / "不要删除.md").read_text(encoding="utf-8")
        self.assertEqual(text.splitlines()[0], "CORTEX-KEEP")
        self.assertIn("三台机器互相备份", text)
        self.assertIn("删了就丢模型口碑", text)


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
