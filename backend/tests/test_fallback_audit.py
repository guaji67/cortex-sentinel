from __future__ import annotations

import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cortex_sentinel import fallback_audit as fa  # noqa: E402
from cortex_sentinel import occupancy as occ  # noqa: E402

# 北京 2026-10-04 09:50:00
NOW = datetime(2026, 10, 4, 1, 50, 0, tzinfo=timezone.utc)
MIMO = {"id": "ex-mimo", "name": "M1Max 执行者(MiMo v2.6 Flash Go)", "model": "mimo-v2.6-flash", "machine": "m1max"}
CODEBUDDY = {"id": "ex-cb", "name": "Pro 执行者(CodeBuddy BCGLM5.3 Flash Max)", "model": "custom-local:BC-GLM-5.3-Flash", "machine": "pro"}


def acct(running: int, cap: int, reserved: int = 0, reasons: list | None = None) -> dict:
    return {"running": running, "cap": cap, "reserved": reserved, "multica": running, "local_lines": 0, "other": 0,
            "busy_reasons": reasons if reasons is not None else ([["account_parallel", f"n={running}/{cap}"]] if cap and running >= cap else [])}


def line(ts: str = "2026-10-04T09:41:59+08:00", picked: dict = MIMO, accounts: object = "default", ticket: str = "COR-1",
         machine: str = "m1max") -> dict:
    if accounts == "default":
        accounts = {"falcon": acct(7, 7), "kailao": acct(0, 0, reasons=[["account_stopped", "n=0/0"]]),
                    "xin": acct(3, 0, reasons=[["account_stopped", "n=3/0"]]), "ylao": acct(3, 0, reasons=[["account_stopped", "n=3/0"]])}
    return {"ts_beijing": ts, "free_window": True, "ticket": ticket, "slug": "s-" + ticket, "picked": picked,
            "accounts": accounts, "reason": "falcon:满", "_machine": machine}


def plan(running: int, cap: int) -> dict:
    return {"running": running, "cap": cap}


def occ_row(ts: str, falcon: tuple = (7, 7), others: tuple = ((0, 0), (3, 0), (3, 0))) -> dict:
    return {"ts_bj": ts, "plans": {"falcon": plan(*falcon), "kailao": plan(*others[0]), "xin": plan(*others[1]), "ylao": plan(*others[2])}}


class JudgeTests(unittest.TestCase):
    def test_full_account_falling_to_mimo_is_not_a_misselect(self) -> None:
        result = fa.judge(line(), occ_row("2026-10-04 09:41:01", falcon=(7, 7)), now=NOW)
        self.assertEqual((result["misselect"], result["open_accounts"], result["to_mimo"], result["match"]),
                         (False, [], True, "同一分钟"))
        # 停用的号（帽 0）占着人也不算有空
        self.assertEqual(result["accounts"]["xin"]["cap"], 0)

    def test_open_slot_falling_to_mimo_is_a_misselect_with_the_open_account(self) -> None:
        result = fa.judge(line(), occ_row("2026-10-04 09:41:01", falcon=(5, 7)), now=NOW)
        self.assertTrue(result["misselect"])
        self.assertEqual([(a["account"], a["running"], a["cap"]) for a in result["open_accounts"]], [("falcon", 5, 7)])
        self.assertFalse(result["reserve_only"])
        self.assertEqual(result["occupancy_ts"], "2026-10-04 09:41:01")

    def test_reserved_slots_do_not_count_as_running_but_are_flagged(self) -> None:
        accounts = {"falcon": acct(5, 7, reserved=2, reasons=[["account_parallel", "n=7/7"]])}
        result = fa.judge(line(accounts=accounts), occ_row("2026-10-04 09:41:01", falcon=(5, 7)), now=NOW)
        self.assertTrue(result["misselect"])       # 预占不算在跑：真在跑 5 < 7，照判
        self.assertTrue(result["reserve_only"])    # 但标出来是预占撑满的

    def test_other_blockers_are_recorded_on_the_open_account(self) -> None:
        accounts = {"falcon": acct(5, 7, reasons=[["usage_cooldown", "到 11:00"]])}
        result = fa.judge(line(accounts=accounts), occ_row("2026-10-04 09:41:01", falcon=(5, 7)), now=NOW)
        self.assertEqual(result["open_accounts"][0]["blockers"], ["usage_cooldown"])

    def test_line_without_account_view_uses_occupancy_row_caps(self) -> None:
        result = fa.judge(line(accounts=None), occ_row("2026-10-04 09:41:01", falcon=(4, 7)), now=NOW)
        self.assertTrue(result["view_missing"])
        self.assertTrue(result["misselect"])

    def test_no_occupancy_row_is_unjudged_not_misselect(self) -> None:
        result = fa.judge(line(), None, now=NOW)
        self.assertEqual((result["misselect"], result["match"]), (None, "无同分钟占用记录"))


class AuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def put_row(self, row: dict) -> None:
        occ.append_jsonl(occ.occupancy_file(self.base, "2026-10-04"), row)

    def test_audit_uses_the_same_minute_row_only_and_is_idempotent(self) -> None:
        self.put_row(occ_row("2026-10-04 09:40:01", falcon=(3, 7)))   # 前一分钟：有空，但不是同一分钟，不能拿来比
        self.put_row(occ_row("2026-10-04 09:41:02", falcon=(7, 7)))   # 同一分钟：满了
        lines = [line(ts="2026-10-04T09:41:59+08:00", ticket="COR-1")]
        first = fa.audit(self.base, lines, now=NOW)
        second = fa.audit(self.base, lines, now=NOW + timedelta(minutes=1))
        self.assertEqual((first["added"], second["added"]), (1, 0))
        rows = occ.read_jsonl(fa.audit_file(self.base, "2026-10-04"))
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["misselect"], rows[0]["occupancy_ts"]), (False, "2026-10-04 09:41:02"))

    def test_young_line_without_row_is_deferred_old_one_is_recorded_unjudged(self) -> None:
        young = line(ts="2026-10-04T09:49:30+08:00", ticket="COR-2")   # 半分钟前
        old = line(ts="2026-10-04T09:40:00+08:00", ticket="COR-3")     # 十分钟前，始终没有占用记录
        res = fa.audit(self.base, [young, old], now=NOW)
        self.assertEqual((res["added"], res["deferred"]), (1, 1))
        (row,) = occ.read_jsonl(fa.audit_file(self.base, "2026-10-04"))
        self.assertEqual((row["ticket"], row["misselect"]), ("COR-3", None))

    def test_report_counts_fallback_mimo_and_lists_misselects_with_open_account(self) -> None:
        self.put_row(occ_row("2026-10-04 09:41:02", falcon=(7, 7)))
        self.put_row(occ_row("2026-10-04 09:42:02", falcon=(5, 7)))
        self.put_row(occ_row("2026-10-04 09:43:02", falcon=(7, 7)))
        lines = [
            line(ts="2026-10-04T09:41:20+08:00", ticket="COR-10"),                          # 满了落小米：正常
            line(ts="2026-10-04T09:42:20+08:00", ticket="COR-11"),                          # 有空位落小米：误选
            line(ts="2026-10-04T09:43:20+08:00", ticket="COR-12", picked=CODEBUDDY, machine="pro"),  # 满了落别的通道
        ]
        fa.audit(self.base, lines, now=NOW)
        rep = fa.report(self.base, "2026-10-04")
        self.assertEqual((rep["total"], rep["to_mimo"], rep["misselect"], rep["unjudged"]), (3, 2, 1, 0))
        text = fa.format_report(rep, ["本机", "cortex-pro"], ["cortex-mini（ssh: timed out）"])
        self.assertIn("落兜底档 3 次，其中落小米 2 次；误选 1 次", text)
        self.assertIn("COR-11", text)
        self.assertIn("falcon 有空 5/7", text)
        self.assertNotIn("COR-10 →", text)
        self.assertIn("没读到：cortex-mini", text)
        empty = fa.format_report(fa.report(self.base, "2026-10-03"))
        self.assertIn("落兜底档 0 次，其中落小米 0 次；误选 0 次", empty)   # 当天没有行也照样报

    def test_old_lines_before_yesterday_are_not_audited(self) -> None:
        res = fa.audit(self.base, [line(ts="2026-10-01T09:41:59+08:00")], now=NOW)
        self.assertEqual(res["added"], 0)


class ReadTests(unittest.TestCase):
    def test_peer_read_is_read_only_tail_with_per_machine_checkout_path(self) -> None:
        seen: list = []

        def runner(argv, timeout=0):
            seen.append(argv)
            return '{"ts_beijing":"2026-10-04T09:41:59+08:00","ticket":"COR-1","picked":{"id":"x"}}\n\nnot json\n', None

        rows, err = fa.read_peer("cortex-pro", runner=runner)
        self.assertEqual((len(rows), err, rows[0]["_machine"]), (1, None, "pro"))
        remote = seen[0][-1]
        self.assertIn("Documents/Code/cortex/logs/dispatch-fallback.jsonl", remote)
        self.assertTrue(remote.startswith("tail "))
        self.assertNotIn(">", remote.replace("2>/dev/null", ""))
        fa.read_peer("cortex-m1max", runner=runner)
        self.assertIn("Documents/code/cortex/logs/dispatch-fallback.jsonl", seen[1][-1])

    def test_gather_merges_machines_dedupes_and_names_unreachable(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        log = Path(tmp.name) / "dispatch-fallback.jsonl"
        occ.append_jsonl(log, {k: v for k, v in line().items() if k != "_machine"})

        def reader(alias):
            if alias == "cortex-mini":
                return [], "退出码 255：ssh: connect timed out"
            return [line(ts="2026-10-04T09:43:59+08:00", ticket="COR-9", machine="pro")], None

        lines, read_from, missed = fa.gather_lines(local_path=log, reader=reader, aliases=["cortex-pro", "cortex-mini"])
        self.assertEqual(sorted(l["ticket"] for l in lines), ["COR-1", "COR-9"])
        self.assertEqual(read_from, ["本机", "cortex-pro"])
        self.assertIn("cortex-mini", missed[0])
        lines2, _r, _m = fa.gather_lines(local_path=log, peers=False)
        self.assertEqual(len(lines2), 1)


if __name__ == "__main__":
    unittest.main()
