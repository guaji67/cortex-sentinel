#!/usr/bin/env python3
"""Codex 派工守护：发射 + 健康监控 + 自愈一体。

替代 AI 人肉设短闹钟盯 Codex（Falcon 2026-07-04 拍板：盯健康这种事让程序做，
程序救不活再叫醒 AI）。一次派工 = detached 起一个本脚本，它负责全生命周期：

  初派/续跑前按 provider base_url 选健康探针：本地 AIO 网关直探 /v1/models，
  直连 Input 才读公共状态页；不通写 waiting_relay 本地排队 -> 每 30s 续探，
  恢复即放行；已注册的备用 provider 可单线尝试一次 -> 运行中每 30s 体检 ->
  hang(rollout 停滞且进程树 CPU~0) kill -9 重拉 -> 首次无进展满 30 分钟才写
  HELP 并通知 -> 正常收工(rc=0)写 DONE 退出。

  重拉方式（2026-07-24 改）：fresh 线一律初派新会话（原工单+续跑前言，先看 git
  现场续做半成品），绝不 codex exec resume——resume 断流会话有接错线和工具通道
  整段失效两种死法。rc=0 但日志尾自认未完成（假收工）同样按异常重拉，退避 5 分钟。
  resume 只保留给显式 --resume-sid 接管模式。

状态落 logs/codex-babysitter-<slug>.status.json，AI 长闹钟只读它决定要不要介入。
窗口盯线不要再写 while true，走 scripts/health/line_watch.py watch；本脚本是干活的守护，收工自己退。

用法（都从主仓跑，detached 起法见 docs/reference/codex-parallel-worktree-runbook.md）:
  初派:  codex_babysitter.py --slug s3 --label-zh <中文名> --dispatcher-zh <来源> --cd <worktree> --prompt-file <f> --workorder-base <commit> --log <log>
  接管:  codex_babysitter.py --slug s3 --label-zh <中文名> --dispatcher-zh <来源> --resume-sid <SID> --resume-prompt "..." --log <log>

hang 判定取双条件（只看 mtime 会误杀在跑长测试的 Codex）:
  rollout 文件停滞 >= stall 分钟  且  连续 3 次体检整棵进程树 CPU < 2%
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from zoneinfo import ZoneInfo

from cortex_sentinel.channel import apply_dispatch_channel_gate
from cortex_sentinel.disk import apply_dispatch_disk_gate
from cortex_sentinel.paths import registry_path, status_dir
from cortex_sentinel.registry import LineRegistryError, local_host_name, upsert_line_registration

APP_TIMEZONE = ZoneInfo("Asia/Shanghai")
LINE_REGISTRY_PATH = registry_path()

def _resolve_codex() -> str:
    """codex 二进制探测：环境变量 CODEX_BIN > ~/.local/bin/codex（本机默认，保持原行为）
    > PATH 里的 codex > 兜底默认串。硬编码单一路径在换机/codex 搬家时会静默失效
    （Air 曾被迫维护一个只改这一行的本机副本，见 macbook-air-remote-execution-runbook）。"""
    import shutil

    env = os.environ.get("CODEX_BIN")
    if env and Path(env).exists():
        return env
    default = Path.home() / ".local" / "bin" / "codex"
    if default.exists():
        return str(default)
    found = shutil.which("codex")
    if found:
        return found
    return str(default)


CODEX = _resolve_codex()


def codex_home() -> Path:
    """返回 Codex 配置根；CODEX_HOME 与 Codex CLI 的覆盖语义一致。"""
    configured = os.environ.get("CODEX_HOME")
    return Path(configured).expanduser() if configured else Path.home() / ".codex"


def codex_config_path() -> Path:
    return codex_home() / "config.toml"


SESSIONS = codex_home() / "sessions"
POLL_SECONDS = 30
CONTROL_POLL_SECONDS = 1
LOW_CPU_STREAK_NEEDED = 3
BALANCE_REFRESH_SECONDS = 300  # 余额是辅助信息不是健康信号：5 分钟一刷，及时跟随 AIO 切号
BALANCE_WARN_THRESHOLD = 10.0  # 低于此数在 balance.note 挂"告急"，AI 读 status 就知道该提醒充值
INPUT_RELAY_STATUS_ENDPOINT = "https://status.input.im/api/status"
INPUT_RELAY_PROBE_TIMEOUT_SECONDS = 8
AIO_GATEWAY_PORT = 37123
AIO_GATEWAY_PROBE_TIMEOUT_SECONDS = 8
RELAY_PROBE_CACHE_SECONDS = 30
RELAY_HISTORY_WINDOW = 2
RELAY_DOWN_STREAK_FOR_FALLBACK = 2
DEFAULT_FALLBACK_PROVIDER: str | None = None
# Falcon 的口径是短于半小时的中转波动不惊动人；30 分钟一到立即求助，
# 既给正常闪断留恢复窗口，也避免守护静默等到数小时后才暴露。
RELAY_ESCALATION_SECONDS = 30 * 60
# 结构性无出口（AIO 启用名单全是 Input 系且 Input 挂着）时的低频恢复感知节奏。
# 对齐哨兵的 InputStatusConstants.backgroundRefreshInterval（5 分钟），不另发明数字；
# 这一档只读免费的 Input 公共状态页，不发模型请求、不烧任何额度。
NO_EXIT_POLL_SECONDS = 300
# AIO 库路径口径与哨兵 SentinelFileReader 完全一致，别另定一套。
AIO_DB_RELATIVE_PATH = (".aio-coding-hub", "aio-coding-hub.db")
AIO_EXIT_POSTURE_CACHE_SECONDS = 30
# 官方 GPT 家族（Plus / Pro）烧的是 ChatGPT 的周窗口，跟中转那份 USD 余额是两个桶。
# 守护过去只看得到 USD 那个桶，对周窗口是瞎的——Falcon 2026-08-12 为此发火。
#
# 90% 这条线是这么定的：周窗口打满要等一整周才回血，而产品侧的官方通道
# （runOfficialText / OAuth）跟派工抢的是同一个桶。留 10% 给产品侧，是"派工可以用掉
# 绝大部分额度、但不许把他自己的 GPT 功能挤死一整周"的最小保留量。低于 90% 就拦属于
# 过度保守——额度买来就是要用的；高于 90% 再发，代价是最长 7 天不可逆，是不对称风险。
OFFICIAL_WEEKLY_BLOCK_PCT = 90.0
# 75% 只告警不拦：给他一个"还剩四分之一"的提前量，自己决定要不要换出口或充值。
OFFICIAL_WEEKLY_WARN_PCT = 75.0
# 5 小时窗口 5 小时就回血，暂停成本极低，所以卡得比周窗口更紧一点，纯粹防打空。
OFFICIAL_FIVE_HOUR_BLOCK_PCT = 95.0
OFFICIAL_QUOTA_CACHE_SECONDS = 300
# 这几个状态码说明"这台 AIO 根本没有额度接口"，不是"暂时打不通"。
# 两者必须分开：前者等多久都不会有数，拿它当暂时故障反复扣着等就是永久卡死。
OFFICIAL_USAGE_UNSUPPORTED_STATUSES = frozenset({404, 405, 501})
# 额度接口取不到数时的宽限：等满这段仍取不到就放行一次并写明"额度未经核实"。
# 复用 30 分钟这个既有口径（短于半小时的波动不当回事），既不瞎放行也不整个停摆。
OFFICIAL_QUOTA_UNKNOWN_GRACE_SECONDS = 30 * 60
# codex config 里问官方周窗口用的 provider：名字含 official 的那条（read_billing_endpoint
# 的既有约定），它带着能打通 /usage 的 base 与 provider header。
OFFICIAL_USAGE_PROVIDER_HINT = "official"
SERVICE_TIER_ASSIGNMENT_RE = re.compile(
    r"^\s*(?:service_tier|\"service_tier\"|'service_tier')\s*="
)
FINDING_FRESHNESS_FIELD_RE = re.compile(
    r"^\s*(?:[-*]\s*)?复测基线\s*[：:]",
    re.MULTILINE,
)

_ACTIVE_CODEX_PROCESS: subprocess.Popen | None = None

DEFAULT_RESUME_PROMPT = (
    "你被打断了（网络断流或上一动作卡死被守护进程中止）。继续干活：先 git status 核对现场，"
    "之后跑命令一律非交互式（加超时、别开 REPL、长跑命令输出重定向到文件再轮询），"
    "按工单执行顺序和验收清单推进到完工，纪律不变。"
)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True)
class RelayProbeResult:
    """当前 provider 的守护侧判定；Input 情报可附带但不必参与 gating。"""

    state: str
    checked_at: str
    last_ok: bool | None
    recent_ok: tuple[bool, ...]
    detail: str
    source: str = "input_public_status"
    endpoint: str | None = None
    model_count: int | None = None
    input_intel_state: str | None = None
    input_intel_detail: str | None = None


@dataclass(frozen=True)
class AIOOfficialProvider:
    id: int
    name: str | None


@dataclass(frozen=True)
class AIOExitPosture:
    """AIO 里已启用出口的分类计数。

    只带计数，永远不携带出口名字：Falcon 的出口名里有金额和人名，
    一旦进了状态文件或日志就等于把私人信息写进产物。
    """

    enabled_total: int
    input_count: int
    official_gpt_count: int
    third_party_count: int

    @property
    def only_input(self) -> bool:
        """启用名单非空且清一色 Input 系——这才谈得上"结构上没别的出口"。"""
        return self.enabled_total > 0 and self.input_count == self.enabled_total

    def as_payload(self) -> dict[str, int]:
        return {
            "enabled_total": self.enabled_total,
            "input": self.input_count,
            "official_gpt": self.official_gpt_count,
            "third_party": self.third_party_count,
        }


@dataclass(frozen=True)
class OfficialQuotaVerdict:
    """官方 GPT 周窗口的放行判据。

    只带百分比、重置时刻和一句人话：**绝不带账号标识**（邮箱 / 出口名 / plan 归属），
    也绝不带任何凭据——这份东西要落进状态文件、日志和哨兵界面。
    """

    state: str  # ok / warn / tight / unknown
    weekly_used_pct: float | None
    weekly_reset_at: str | None
    five_hour_used_pct: float | None
    five_hour_reset_at: str | None
    detail: str

    @property
    def blocks(self) -> bool:
        return self.state == "tight"

    @property
    def is_unknown(self) -> bool:
        return self.state == "unknown"

    @property
    def is_unsupported(self) -> bool:
        """这台 AIO 没有额度接口——这条信息永远拿不到，扣着等没有意义。"""
        return self.state == "unsupported"

    def as_payload(self) -> dict[str, object]:
        return {
            "state": self.state,
            "weekly_used_pct": self.weekly_used_pct,
            "weekly_reset_at": self.weekly_reset_at,
            "five_hour_used_pct": self.five_hour_used_pct,
            "five_hour_reset_at": self.five_hour_reset_at,
            "detail": self.detail,
            "block_at_weekly_pct": official_weekly_block_pct(),
        }


@dataclass
class RelayRetryState:
    """单条 babysitter 的中转等待与单次备用出口切换状态。"""

    primary_provider: str | None
    fallback_provider: str | None
    active_provider: str | None
    down_streak: int = 0
    fallback_attempted: bool = False
    switch_count: int = 0
    last_switch_at: str | None = None
    first_failure_monotonic: float | None = None
    first_failure_at: str | None = None
    alert: str | None = None
    last_probe: RelayProbeResult | None = None
    primary_base_url: str | None = None
    probe_source: str | None = None
    fallback_warning: str | None = None
    exit_posture: AIOExitPosture | None = None
    no_exit: bool = False
    no_exit_since: str | None = None
    official_quota: OfficialQuotaVerdict | None = None
    # None / "no_exit" / "quota_tight" / "quota_unknown"：为什么这轮不发射。
    launch_hold: str | None = None
    quota_unknown_since: float | None = None
    quota_unverified_launch_at: str | None = None


@dataclass(frozen=True)
class RelayWaitResult:
    """一次排队等待的结束原因。"""

    reason: str
    probe: RelayProbeResult | None


@dataclass
class RuntimeControlState:
    """控制文件覆盖后的本线运行时参数；只活在当前 babysitter 周期。"""

    max_restarts: int
    escalate_after_failures: int | None = None


def read_runtime_control(path: Path) -> dict[str, object]:
    """读取一条线的控制信号；缺失、坏 JSON 或非对象都按无信号降级。"""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def apply_runtime_control(path: Path, state: RuntimeControlState) -> bool:
    """应用参数覆盖并消费 probe_now；返回是否应跳过剩余等待立即重探。"""
    payload = read_runtime_control(path)
    max_restarts = payload.get("max_restarts_override")
    if isinstance(max_restarts, int) and not isinstance(max_restarts, bool) and 0 <= max_restarts <= 100:
        state.max_restarts = max_restarts
    escalate_after = payload.get("escalate_after_failures")
    if isinstance(escalate_after, int) and not isinstance(escalate_after, bool) and 1 <= escalate_after <= 100:
        state.escalate_after_failures = escalate_after
    probe_now = payload.get("action") == "probe_now"
    if probe_now:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            # 信号已读到就按幂等动作执行；删失败只会让下一轮再探一次。
            pass
    return probe_now


def _unknown_relay_probe(detail: str) -> RelayProbeResult:
    return RelayProbeResult(
        state="unknown",
        checked_at=now_iso(),
        last_ok=None,
        recent_ok=(),
        detail=detail,
        endpoint=INPUT_RELAY_STATUS_ENDPOINT,
    )


def parse_input_relay_status(payload: object, model: str) -> RelayProbeResult:
    """用目标模型的 last.ok 与最近 history 判定 Input 中转是否可派工。

    all_ok 是全局聚合，不能代表当前模型刚刚恢复后的稳定度。最近两个样本必须
    连续成功才放行；last=false 或近期 history 有失败时留在本地队列。
    """
    checked_at = now_iso()
    if not isinstance(payload, dict):
        return RelayProbeResult(
            "unknown", checked_at, None, (), "状态页不是 JSON object",
            endpoint=INPUT_RELAY_STATUS_ENDPOINT,
        )
    services = payload.get("services")
    if not isinstance(services, list):
        return RelayProbeResult(
            "unknown", checked_at, None, (), "状态页缺少 services",
            endpoint=INPUT_RELAY_STATUS_ENDPOINT,
        )
    service = next(
        (
            item
            for item in services
            if isinstance(item, dict) and item.get("model") == model
        ),
        None,
    )
    if service is None:
        return RelayProbeResult(
            "unknown", checked_at, None, (), f"状态页没有模型 {model}",
            endpoint=INPUT_RELAY_STATUS_ENDPOINT,
        )

    last = service.get("last")
    last_ok = last.get("ok") if isinstance(last, dict) and isinstance(last.get("ok"), bool) else None
    history = service.get("history")
    recent_ok = tuple(
        point["ok"]
        for point in (history[-RELAY_HISTORY_WINDOW:] if isinstance(history, list) else [])
        if isinstance(point, dict) and isinstance(point.get("ok"), bool)
    )

    if last_ok is False or False in recent_ok:
        return RelayProbeResult(
            "unhealthy", checked_at, last_ok, recent_ok, "last 或近期 history 显示失败",
            endpoint=INPUT_RELAY_STATUS_ENDPOINT,
        )
    if last_ok is True and len(recent_ok) == RELAY_HISTORY_WINDOW and all(recent_ok):
        return RelayProbeResult(
            "healthy", checked_at, last_ok, recent_ok, "last 与近期 history 连续成功",
            endpoint=INPUT_RELAY_STATUS_ENDPOINT,
        )
    return RelayProbeResult(
        "unknown", checked_at, last_ok, recent_ok, "近期样本不足，沿用原有重试",
        endpoint=INPUT_RELAY_STATUS_ENDPOINT,
    )


def fetch_input_relay_status(endpoint: str, timeout_s: float) -> object:
    """读取公开 Input 状态页；调用者负责把异常折成 unknown。"""
    # status.input.im 会对默认 Python-urllib 返回 Human Verification HTML；明确给守护身份
    # 才能拿到与 Sentinel 同样的 JSON 状态。响应仍须经 JSON 解析，失败一律回 unknown。
    request = urllib.request.Request(
        endpoint,
        headers={"Accept": "application/json", "User-Agent": "CortexSentinel/1.0"},
    )
    with urllib.request.urlopen(request, timeout=timeout_s) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


class InputRelayProbe:
    """带短缓存的公开探针，避免每次状态心跳都重复请求状态页。"""

    def __init__(
        self,
        model: str,
        *,
        endpoint: str = INPUT_RELAY_STATUS_ENDPOINT,
        timeout_s: float = INPUT_RELAY_PROBE_TIMEOUT_SECONDS,
        cache_seconds: float = RELAY_PROBE_CACHE_SECONDS,
        fetcher: Callable[[str, float], object] = fetch_input_relay_status,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.model = model
        self.endpoint = endpoint
        self.timeout_s = timeout_s
        self.cache_seconds = cache_seconds
        self.fetcher = fetcher
        self.monotonic = monotonic
        self._cached_at: float | None = None
        self._cached_result: RelayProbeResult | None = None

    def check(self, *, force: bool = False) -> RelayProbeResult:
        current = self.monotonic()
        if (
            not force
            and self._cached_result is not None
            and self._cached_at is not None
            and current - self._cached_at < self.cache_seconds
        ):
            return self._cached_result
        try:
            result = parse_input_relay_status(self.fetcher(self.endpoint, self.timeout_s), self.model)
        except (OSError, TimeoutError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
            result = _unknown_relay_probe(f"探针请求失败：{type(exc).__name__}")
        except Exception as exc:
            # 可注入 fetcher 的未知错误也必须降级，不能让探针连坐杀掉守护。
            result = _unknown_relay_probe(f"探针异常：{type(exc).__name__}")
        self._cached_at = current
        self._cached_result = result
        return result


def fetch_gateway_models(endpoint: str, timeout_s: float) -> object:
    """读取本地 AIO 网关模型表；请求不携带或记录任意凭据。"""
    request = urllib.request.Request(
        endpoint,
        headers={"Accept": "application/json", "User-Agent": "CortexCodexBabysitter/1.0"},
    )
    with urllib.request.urlopen(request, timeout=timeout_s) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def parse_gateway_models(payload: object, endpoint: str) -> RelayProbeResult:
    """AIO 网关只有在 /v1/models 返回非空模型列表时才可放行。"""
    checked_at = now_iso()
    # AIO 2026-08-02 更新把响应从 OpenAI 标准 {"data":[{"id":...}]} 改成 {"models":[{"slug":...}]}，两种都认
    models = None
    if isinstance(payload, dict):
        models = payload.get("data") if isinstance(payload.get("data"), list) else payload.get("models")
    model_ids = (
        [
            name
            for item in models
            if isinstance(item, dict)
            for name in (item.get("id") or item.get("slug"),)
            if isinstance(name, str) and name
        ]
        if isinstance(models, list)
        else []
    )
    if isinstance(models, list) and model_ids:
        return RelayProbeResult(
            "healthy",
            checked_at,
            True,
            (),
            f"本地网关 /v1/models 返回 {len(model_ids)} 个模型",
            source="aio_gateway_models",
            endpoint=endpoint,
            model_count=len(model_ids),
        )
    detail = "本地网关 /v1/models 未返回模型列表" if not isinstance(models, list) else "本地网关模型列表为空"
    return RelayProbeResult(
        "unhealthy",
        checked_at,
        False,
        (),
        detail,
        source="aio_gateway_models",
        endpoint=endpoint,
        model_count=0,
    )


class GatewayRelayProbe:
    """AIO 本地网关直探；Input 公共状态只作为日志情报，不改变网关判定。"""

    def __init__(
        self,
        endpoint: str,
        *,
        timeout_s: float = AIO_GATEWAY_PROBE_TIMEOUT_SECONDS,
        cache_seconds: float = RELAY_PROBE_CACHE_SECONDS,
        fetcher: Callable[[str, float], object] = fetch_gateway_models,
        input_intel_probe: InputRelayProbe | None = None,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.endpoint = endpoint
        self.timeout_s = timeout_s
        self.cache_seconds = cache_seconds
        self.fetcher = fetcher
        self.input_intel_probe = input_intel_probe
        self.monotonic = monotonic
        self._cached_at: float | None = None
        self._cached_result: RelayProbeResult | None = None

    def check(self, *, force: bool = False) -> RelayProbeResult:
        current = self.monotonic()
        if (
            not force
            and self._cached_result is not None
            and self._cached_at is not None
            and current - self._cached_at < self.cache_seconds
        ):
            return self._cached_result
        try:
            gateway_result = parse_gateway_models(self.fetcher(self.endpoint, self.timeout_s), self.endpoint)
        except (
            OSError,
            TimeoutError,
            urllib.error.URLError,
            urllib.error.HTTPError,
            json.JSONDecodeError,
        ) as exc:
            gateway_result = RelayProbeResult(
                "unhealthy",
                now_iso(),
                False,
                (),
                f"本地网关探针失败：{type(exc).__name__}",
                source="aio_gateway_models",
                endpoint=self.endpoint,
                model_count=0,
            )
        except Exception as exc:
            gateway_result = RelayProbeResult(
                "unhealthy",
                now_iso(),
                False,
                (),
                f"本地网关探针异常：{type(exc).__name__}",
                source="aio_gateway_models",
                endpoint=self.endpoint,
                model_count=0,
            )

        # force 必须往下传：结构性暂停靠 Input 情报放行，情报被 30 秒缓存压住
        # 就等于把"Input 恢复"这个绝对信号延迟掉一整个等待周期。
        input_intel = (
            self.input_intel_probe.check(force=force) if self.input_intel_probe is not None else None
        )
        result = RelayProbeResult(
            state=gateway_result.state,
            checked_at=gateway_result.checked_at,
            last_ok=gateway_result.last_ok,
            recent_ok=gateway_result.recent_ok,
            detail=gateway_result.detail,
            source=gateway_result.source,
            endpoint=gateway_result.endpoint,
            model_count=gateway_result.model_count,
            input_intel_state=input_intel.state if input_intel is not None else None,
            input_intel_detail=input_intel.detail if input_intel is not None else None,
        )
        self._cached_at = current
        self._cached_result = result
        return result


def aio_exit_db_path() -> Path:
    """AIO 库位置：CORTEX_AIO_DB_PATH 覆盖，否则 ~/.aio-coding-hub/aio-coding-hub.db。"""
    configured = os.environ.get("CORTEX_AIO_DB_PATH")
    if configured and configured.strip():
        return Path(configured.strip()).expanduser()
    return Path.home().joinpath(*AIO_DB_RELATIVE_PATH)


def classify_exit_name(name: str | None) -> str:
    """按 Falcon 定的名字规则给出口分类：official_gpt / input / third_party。

    Falcon 2026-08-12 原话：进口中转站名字上都会写明，GPT（Plus 或 Pro）名字里一定带
    GPT，其他第三方中转不会带 GPT。

    先判 GPT 再判 input 是刻意选的容错方向，不是随手排的顺序：只有"启用的全是 Input 系"
    才会触发暂停，所以名字同时命中两边时判成非 Input，最坏代价是多试一次；反过来判成
    Input 就可能把还有活路的线停掉。名字为空同理落 third_party（非 Input）。
    这是启发式不是真值，判错必须只会多试、不会漏试。
    """
    lowered = (name or "").strip().lower()
    if not lowered:
        return "third_party"
    if "gpt" in lowered:
        return "official_gpt"
    if "input" in lowered:
        return "input"
    return "third_party"


def _exit_enabled(value: object) -> bool:
    """AIO 各版本 enabled 列可能是 int / bool / 字符串，只有明确为真才算启用。"""
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


# 只取 name 与 enabled 两列；库里的明文凭据列一个都不碰，也绝不出现在任何查询里。
# 老库没有 cli_key 列时退到不带过滤的那条，读不出来就返回 None 走降级。
_AIO_EXIT_QUERIES = (
    "SELECT name, enabled FROM providers WHERE cli_key = 'codex'",
    "SELECT name, enabled FROM providers",
)


def read_aio_exit_posture(db_path: Path | None = None) -> AIOExitPosture | None:
    """只读 AIO 出口名单的启用分类；库缺失 / 表结构不认识一律返回 None。

    返回 None 表示"这条信息拿不到"，调用方必须降级成老行为继续尝试，
    绝不能因为读不到名单就把线停摆。
    """
    path = db_path if db_path is not None else aio_exit_db_path()
    rows: list[tuple[object, object]] | None = None
    try:
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=0.2) as conn:
            for query in _AIO_EXIT_QUERIES:
                try:
                    rows = conn.execute(query).fetchall()
                    break
                except sqlite3.Error:
                    continue
    except (OSError, sqlite3.Error):
        return None
    if rows is None:
        return None

    counts = {"input": 0, "official_gpt": 0, "third_party": 0}
    total = 0
    for row in rows:
        if len(row) < 2 or not _exit_enabled(row[1]):
            continue
        total += 1
        counts[classify_exit_name(row[0] if isinstance(row[0], str) else None)] += 1
    return AIOExitPosture(
        enabled_total=total,
        input_count=counts["input"],
        official_gpt_count=counts["official_gpt"],
        third_party_count=counts["third_party"],
    )


class AIOExitPostureReader:
    """带短缓存的出口名单读取。

    Falcon 随时会自己开关出口（2026-08-12 下午就手动开了一条官方 GPT 让线跑起来），
    所以守护必须周期性重读，不能开工时读一次就当真值用到死。
    """

    def __init__(
        self,
        *,
        db_path: Path | None = None,
        cache_seconds: float = AIO_EXIT_POSTURE_CACHE_SECONDS,
        # 默认留 None 而不是把函数对象绑进签名：绑了就是定义期快照，
        # 之后再替换模块级实现（测试或热修）都不会生效。
        reader: Callable[[Path | None], AIOExitPosture | None] | None = None,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.db_path = db_path
        self.cache_seconds = cache_seconds
        self.reader = reader
        self.monotonic = monotonic
        self._cached_at: float | None = None
        self._cached: AIOExitPosture | None = None

    def read(self, *, force: bool = False) -> AIOExitPosture | None:
        current = self.monotonic()
        if (
            not force
            and self._cached_at is not None
            and current - self._cached_at < self.cache_seconds
        ):
            return self._cached
        reader = self.reader if self.reader is not None else read_aio_exit_posture
        self._cached = reader(self.db_path)
        self._cached_at = current
        return self._cached


def probe_input_state(probe: RelayProbeResult | None) -> str | None:
    """取探针里的 Input 侧判定：直连 Input 看自身 state，走 AIO 网关看附带的 Input 情报。"""
    if probe is None:
        return None
    if probe.source == "input_public_status":
        return probe.state
    return probe.input_intel_state


def relay_no_exit(
    posture: AIOExitPosture | None,
    probe: RelayProbeResult | None,
) -> bool:
    """结构性无出口 = 启用的出口全是 Input 系，且 Input 被明确判为不通。

    三种拿不准一律判 False（继续老行为）：名单读不到、名单为空、Input 只是 unknown。
    本地 AIO 网关自己活着不算数——它 healthy 只证明网关进程在，不证明背后还有活路，
    正是这一点让守护过去每 30 秒发一次注定 502 的请求。
    """
    if posture is None or not posture.only_input:
        return False
    return probe_input_state(probe) == "unhealthy"


def _never_release(_probe: RelayProbeResult | None) -> bool:
    """额度闸档的放行判据：等满这一轮再回外层重判，不靠探针提前放行。"""
    return False


def input_relay_released(probe: RelayProbeResult | None) -> bool:
    """结构性暂停期间的放行判据：Input 不再明确不通就立刻续上。

    Falcon 原话「Input 中转站恢复肯定是它续接的一个绝对的信号」。状态页取不到结果
    （unknown）时也放行——宁可多试一次，不可把该跑的线关死。
    """
    return probe_input_state(probe) != "unhealthy"


def official_quota_gate_applies(state: RelayRetryState) -> bool:
    """只有真的经本机 AIO 网关出去的线才受这道闸管。

    直连 Input（probe_source=input_public_status）的线压根不走 AIO 路由，AIO 名单里
    开没开官方 GPT 跟它无关；对它拦一下就是纯误伤。
    """
    return state.probe_source == "aio_gateway_models"


def official_gpt_in_route(posture: AIOExitPosture | None) -> bool:
    """官方 GPT 家族在不在启用名单里——在就该把它的额度报出来给人看。"""
    return posture is not None and posture.official_gpt_count > 0


def official_gpt_is_active_exit(
    posture: AIOExitPosture | None,
    probe: RelayProbeResult | None,
) -> bool:
    """官方 GPT 是不是此刻**实际会被走到**的出口。

    只有这种时候才拦，不是"名单里有它"就拦——Input 还通着的时候拦下来属于误伤，
    该发的不发比多发一次更糟。判据：
      - 名单里有官方 GPT，且
      - 名单里没有第三方中转（第三方通不通判不了，保守当它还能用，于是不拦），且
      - 要么名单里只有官方 GPT，要么其余全是 Input 系而 Input 已明确不通（兜底落到它）
    """
    if posture is None or posture.official_gpt_count <= 0:
        return False
    if posture.third_party_count > 0:
        return False
    if posture.input_count == 0:
        return True
    return probe_input_state(probe) == "unhealthy"


def official_weekly_block_pct() -> float:
    """周窗口暂停线；90% 是守护给的默认值，Falcon 可用环境变量自己调。

    额度花到什么程度算"该停"归他判断，不该由我在代码里焊死一个数字。
    只接受 50-100 之间的值，写歪了就退回默认值，绝不让一个笔误把闸整个关掉。
    """
    raw = os.environ.get("CORTEX_OFFICIAL_WEEKLY_BLOCK_PCT")
    if raw is None or not raw.strip():
        return OFFICIAL_WEEKLY_BLOCK_PCT
    try:
        value = float(raw.strip())
    except ValueError:
        return OFFICIAL_WEEKLY_BLOCK_PCT
    return value if 50.0 <= value <= 100.0 else OFFICIAL_WEEKLY_BLOCK_PCT


def _quota_pct(value: object) -> float | None:
    try:
        pct = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return pct if 0 <= pct <= 100 else None


def format_reset_local(value: object) -> str | None:
    """把重置时刻折成东八区人话；解析不了就原样返回，绝不因为格式化崩掉判据。"""
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        stamp = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return value.strip()
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(APP_TIMEZONE).strftime("%-m 月 %-d 日 %H:%M")


def judge_official_quota(balance: object) -> OfficialQuotaVerdict:
    """把官方额度快照折成放行判据。

    **取不到数一律 unknown，绝不当成额度充足。** 这条是 Falcon 这次点名的重点：
    接口不可达时既不许瞎放行，也不许当成额度耗尽把线停死。
    """
    if not isinstance(balance, dict):
        return OfficialQuotaVerdict(
            "unknown", None, None, None, None, "官方额度快照缺失，额度未知"
        )

    weekly = _quota_pct(balance.get("weekly_used_pct"))
    five_hour = _quota_pct(balance.get("five_hour_used_pct"))
    weekly_reset = balance.get("weekly_reset_at")
    five_hour_reset = balance.get("five_hour_reset_at")
    weekly_reset = weekly_reset if isinstance(weekly_reset, str) else None
    five_hour_reset = five_hour_reset if isinstance(five_hour_reset, str) else None

    if weekly is None and five_hour is None:
        note = balance.get("note")
        detail = note.strip() if isinstance(note, str) and note.strip() else "官方额度接口没给出可用数字"
        # 接口压根不存在 = 这条信息永远拿不到。再怎么扣着等都不会有数，
        # 扣下去就是把所有派工永久卡死（他明令禁止的"整个停摆"）。
        # 所以不拦，但把"守护核实不了额度"这件事一直挂在状态里，不假装额度充足。
        if balance.get("usage_unsupported") is True:
            return OfficialQuotaVerdict(
                "unsupported", None, weekly_reset, None, five_hour_reset, detail
            )
        return OfficialQuotaVerdict("unknown", None, weekly_reset, None, five_hour_reset, detail)

    block_pct = official_weekly_block_pct()
    if weekly is not None and weekly >= block_pct:
        reset = format_reset_local(weekly_reset)
        tail = f"，要等到 {reset} 才回血" if reset else ""
        return OfficialQuotaVerdict(
            "tight", weekly, weekly_reset, five_hour, five_hour_reset,
            f"官方 GPT 这周的额度已经用掉 {weekly:g}%{tail}",
        )
    if five_hour is not None and five_hour >= OFFICIAL_FIVE_HOUR_BLOCK_PCT:
        reset = format_reset_local(five_hour_reset)
        tail = f"，{reset} 前后回血" if reset else ""
        return OfficialQuotaVerdict(
            "tight", weekly, weekly_reset, five_hour, five_hour_reset,
            f"官方 GPT 这 5 小时的额度已经用掉 {five_hour:g}%{tail}",
        )
    if weekly is not None and weekly >= min(OFFICIAL_WEEKLY_WARN_PCT, block_pct):
        return OfficialQuotaVerdict(
            "warn", weekly, weekly_reset, five_hour, five_hour_reset,
            f"官方 GPT 这周的额度已经用掉 {weekly:g}%，还能发但该留意了",
        )
    used = f"{weekly:g}%" if weekly is not None else f"5 小时窗 {five_hour:g}%"
    return OfficialQuotaVerdict(
        "ok", weekly, weekly_reset, five_hour, five_hour_reset,
        f"官方 GPT 额度还够（已用 {used}）",
    )


def find_official_usage_provider(providers: dict[str, str | None]) -> str | None:
    """在 codex config 的 provider 里找名字含 official 的那条，用它去问官方周窗口。

    只返回 provider 名字，不碰它的任何凭据字段。
    """
    for name in providers:
        if isinstance(name, str) and OFFICIAL_USAGE_PROVIDER_HINT in name.lower():
            return name
    return None


class OfficialQuotaReader:
    """带缓存的官方周窗口读取；查不到一律折成 unknown，绝不抛给守护主职。

    正常派工走的是本机 AIO 网关，read_billing_endpoint 拿到的是**中转的 USD 余额**，
    跟 AIO 内部路由到官方 GPT 时烧的 ChatGPT 周窗口完全是两个桶。所以这里必须显式
    用名字含 official 的那条 provider 去问，不能拿本线 provider 的余额顶替。
    """

    def __init__(
        self,
        *,
        provider: str | None = None,
        cache_seconds: float = OFFICIAL_QUOTA_CACHE_SECONDS,
        refresher: Callable[[str | None], dict] | None = None,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.provider = provider
        self.cache_seconds = cache_seconds
        self.refresher = refresher
        self.monotonic = monotonic
        self._cached_at: float | None = None
        self._cached: OfficialQuotaVerdict | None = None

    def read(self, *, force: bool = False) -> OfficialQuotaVerdict:
        if self.provider is None and self.refresher is None:
            # 找不到问官方额度的 provider 就**根本不发这个请求**：拿默认 provider 去问，
            # 回来的是中转那份 USD 余额，判成 unknown 会让所有线白等 30 分钟，
            # 而那个数字跟官方周窗口压根不是一个桶。
            return OfficialQuotaVerdict(
                "unsupported", None, None, None, None,
                "codex 配置里没有可查官方额度的出口，守护核实不了周额度",
            )
        current = self.monotonic()
        if (
            not force
            and self._cached is not None
            and self._cached_at is not None
            and current - self._cached_at < self.cache_seconds
        ):
            return self._cached
        refresh = self.refresher if self.refresher is not None else refresh_balance_meta
        try:
            snapshot = refresh(self.provider)
        except Exception as exc:
            snapshot = {"note": f"官方额度查询异常：{type(exc).__name__}"}
        verdict = judge_official_quota(snapshot)
        self._cached = verdict
        self._cached_at = current
        return verdict


def official_quota_reason_text(state: RelayRetryState) -> str:
    """给 Falcon 看的人话，不写英文错误码，也不出现账号标识。"""
    quota = state.official_quota
    if state.launch_hold == "quota_tight":
        detail = quota.detail if quota is not None else "官方 GPT 额度告急"
        return (
            f"现在只能走官方 GPT 那条出口，{detail}。再发就可能把你产品里的 GPT 功能"
            "一起挤没，已暂停等额度回血；名单里出现别的能用的出口就立刻继续。"
        )
    if state.launch_hold == "quota_unknown":
        waited = ""
        if state.quota_unknown_since is not None:
            minutes = max(0, int((time.monotonic() - state.quota_unknown_since) // 60))
            waited = f"已等 {minutes} 分钟，"
        grace = OFFICIAL_QUOTA_UNKNOWN_GRACE_SECONDS // 60
        return (
            "现在只能走官方 GPT 那条出口，但额度接口取不到数——不敢当成额度充足就发。"
            f"{waited}最多等 {grace} 分钟；到点还取不到会放行一次，并注明这轮额度没核实过。"
        )
    return quota.detail if quota is not None else "官方 GPT 额度状态未知"


def no_exit_reason_text(posture: AIOExitPosture | None) -> str:
    """给 Falcon 看的人话，不许写英文错误码。"""
    head = (
        f"AIO 里启用的 {posture.enabled_total} 个出口全是 Input 系"
        if posture is not None and posture.enabled_total
        else "AIO 里启用的出口全是 Input 系"
    )
    minutes = max(1, NO_EXIT_POLL_SECONDS // 60)
    return (
        f"{head}，而 Input 正挂着——这时候发出去也是白发，已暂停无谓重试；"
        f"每 {minutes} 分钟看一眼 Input，它一恢复就自动继续。"
    )


def read_codex_provider_settings(
    config_path: Path | None = None,
) -> tuple[str | None, dict[str, str | None]]:
    """只读默认 provider 与注册表 base_url，不读取或记录任意凭据。"""
    try:
        import tomllib

        path = config_path or codex_config_path()
        payload = tomllib.loads(path.read_text())
    # except 子句不能引用 tomllib：系统 python3.9 无该模块时 import 就抛，
    # 原写法在 except 里再摸 tomllib.TOMLDecodeError 变 UnboundLocalError 炸死整个守护（Air 2026-08-02 实踩）
    except Exception:
        return None, {}

    value = payload.get("model_provider")
    default_provider = value.strip() if isinstance(value, str) and value.strip() else None
    raw_providers = payload.get("model_providers")
    providers: dict[str, str | None] = {}
    if isinstance(raw_providers, dict):
        for name, raw in raw_providers.items():
            if not isinstance(name, str) or not isinstance(raw, dict):
                continue
            base_url = raw.get("base_url")
            providers[name] = base_url.strip() if isinstance(base_url, str) and base_url.strip() else None
    return default_provider, providers


def find_global_service_tier(config_path: Path | None = None) -> tuple[Path, int, str] | None:
    """定位 config.toml 中首条未注释的 service_tier 赋值。"""
    path = config_path or codex_config_path()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise RuntimeError(f"拒绝发射：读取全局 Codex config 失败：{path}（{exc}）") from exc
    for line_number, line in enumerate(lines, start=1):
        if SERVICE_TIER_ASSIGNMENT_RE.match(line):
            return path, line_number, line.strip()
    return None


def explicit_service_tier(config_kv: list[str] | None) -> str | None:
    """返回本线显式 service_tier 覆盖值；None 表示调用方未授权。"""
    for item in reversed(config_kv or []):
        key, separator, value = item.partition("=")
        if separator and key.strip().strip("\"'") == "service_tier":
            return value.strip()
    return None


def enforce_global_service_tier_guard(
    config_kv: list[str] | None,
    *,
    allow_global_service_tier: bool = False,
    config_path: Path | None = None,
) -> str | None:
    """发射前阻断全局 service_tier；--allow-global-service-tier 仅救急使用。"""
    assignment = find_global_service_tier(config_path)
    explicit_tier = explicit_service_tier(config_kv)
    if explicit_tier is not None:
        normalized_tier = explicit_tier.strip("\"'")
        if normalized_tier == "priority":
            return "FAST: 已显式授权本线 service_tier=priority；该线正在使用 Fast（双倍计费）"
        return f"SERVICE_TIER: 已显式授权本线 service_tier={normalized_tier}"
    if assignment is None:
        return None

    path, line_number, line = assignment
    if allow_global_service_tier:
        return (
            "WARN: 已用 --allow-global-service-tier 救急放行全局 "
            f"service_tier：{path}:{line_number}（{line}）"
        )
    raise RuntimeError(
        "拒绝发射：检测到全局 Codex config 存在未注释的 service_tier 赋值："
        f"{path}:{line_number}（{line}）。Fast（service_tier=priority）有双倍计费风险。"
        "请注释掉该行；确要 Fast，请只为本线显式传 "
        "--config-kv service_tier=priority。"
    )


def provider_probe_source(base_url: str | None) -> str | None:
    """健康探针按真实 endpoint 分类，不按 aio / aio_official 名称猜。"""
    if not base_url:
        return None
    try:
        parsed = urllib.parse.urlsplit(base_url)
        host = (parsed.hostname or "").lower()
        port = parsed.port
    except ValueError:
        return None
    if host in {"127.0.0.1", "localhost", "::1"} and port == AIO_GATEWAY_PORT:
        return "aio_gateway_models"
    if host == "ai.input.im":
        return "input_public_status"
    return None


def gateway_models_endpoint(base_url: str) -> str:
    # AIO 2026-08-02 更新后 /v1/models 强制要求 client_version query，缺参返回 422 会误判网关不可用
    return f"{base_url.rstrip('/')}/models?client_version=1.0.0"


def make_relay_retry_state(
    args: argparse.Namespace,
    *,
    provider_settings: tuple[str | None, dict[str, str | None]] | None = None,
    warn: Callable[[str], None] | None = None,
) -> RelayRetryState:
    default_provider, providers = provider_settings or read_codex_provider_settings()
    primary = getattr(args, "provider", None) or default_provider
    fallback = getattr(args, "fallback_provider", DEFAULT_FALLBACK_PROVIDER)
    fallback = fallback if isinstance(fallback, str) and fallback and fallback != primary else None
    fallback_warning = None
    if fallback is not None and fallback not in providers:
        fallback_warning = (
            f"fallback provider={fallback} 未在 ~/.codex/config.toml [model_providers.*] 注册，"
            "已禁用本线 fallback"
        )
        fallback = None
        if warn is not None:
            warn(fallback_warning)
    primary_base_url = providers.get(primary) if primary is not None else None
    return RelayRetryState(
        primary_provider=primary,
        fallback_provider=fallback,
        active_provider=primary,
        primary_base_url=primary_base_url,
        probe_source=provider_probe_source(primary_base_url),
        fallback_warning=fallback_warning,
    )


def make_relay_probe(
    state: RelayRetryState,
    model: str,
) -> InputRelayProbe | GatewayRelayProbe | None:
    if state.probe_source == "aio_gateway_models" and state.primary_base_url:
        return GatewayRelayProbe(
            gateway_models_endpoint(state.primary_base_url),
            input_intel_probe=InputRelayProbe(model, timeout_s=2),
        )
    if state.probe_source == "input_public_status":
        return InputRelayProbe(model)
    return None


def next_relay_action(
    state: RelayRetryState,
    probe: RelayProbeResult | None,
    *,
    posture: AIOExitPosture | None = None,
    quota: OfficialQuotaVerdict | None = None,
    monotonic_now: float | None = None,
) -> str:
    """返回 launch / wait / launch_fallback；已配置探针的 unknown 保守按不可用等待。

    posture / quota 缺省为 None，等于"不知道出口名单和额度"，全部走原有逻辑；
    老调用方无需改。
    """
    if state.probe_source is None or state.active_provider != state.primary_provider:
        return "launch"

    if posture is not None:
        # 判据和状态文件用同一份 posture，免得界面显示的和刚才拿来决策的不是一回事。
        state.exit_posture = posture
    was_no_exit = state.no_exit
    state.no_exit = relay_no_exit(posture, probe)
    if state.no_exit:
        state.launch_hold = "no_exit"
        state.no_exit_since = state.no_exit_since or now_iso()
        # 备用出口是另一条 base_url，跟 AIO 里那批 Input 出口不是一回事；
        # 注册过就仍给它一次机会（多试的方向），没注册才纯等。
        if activate_fallback(state):
            return "launch_fallback"
        return "wait"

    if was_no_exit:
        # 结构性无出口刚解除：30 分钟窗口从"真正开始重试"这一刻重新计时，
        # 免得停摆期间攒下的时间一恢复就立刻叫人。
        state.no_exit_since = None
        clear_no_progress(state)

    state.official_quota = quota
    quota_action = official_quota_gate_action(
        state, posture, probe, quota, monotonic_now=monotonic_now
    )
    if quota_action == "wait":
        return "wait"

    if probe is not None and probe.state == "healthy":
        state.down_streak = 0
        return "launch"

    # 已知通道的探针自己也取不到结果时，先等比贸然发射更便宜；无探针的 provider
    # 已在上面保留原行为，不会把普通进程错误误吞成中转故障。
    state.down_streak += 1
    if state.down_streak >= RELAY_DOWN_STREAK_FOR_FALLBACK and activate_fallback(state):
        return "launch_fallback"
    return "wait"


def official_quota_gate_action(
    state: RelayRetryState,
    posture: AIOExitPosture | None,
    probe: RelayProbeResult | None,
    quota: OfficialQuotaVerdict | None,
    *,
    monotonic_now: float | None = None,
) -> str:
    """出口额度闸：返回 launch / wait，并把停发原因记进 state.launch_hold。

    只在"官方 GPT 是此刻实际会被走到的出口"时才拦；名单里有它但 Input 还通着的时候
    只把额度报出去给人看，不拦——该发的不发比多发一次更糟。
    """
    # 通道本身就不通的时候不许抢话：那时更准确、更该说的事实是"网关没起来 / 探针不可用"，
    # 让它走原有的探针路径去 wait。额度闸只在"路已经通、马上就要发出去"这一刻才有意义。
    # 顺带一个要紧的副作用：额度未知的宽限只在网关真活着时才累积，不会在网关宕机期间
    # 白白走完，然后网关一回来就以"额度未核实"放行。
    transport_ready = probe is not None and probe.state == "healthy"
    if (
        quota is None
        or not transport_ready
        or not official_quota_gate_applies(state)
        or not official_gpt_is_active_exit(posture, probe)
    ):
        state.launch_hold = None
        state.quota_unknown_since = None
        return "launch"

    if quota.blocks:
        state.launch_hold = "quota_tight"
        state.quota_unknown_since = None
        return "wait"

    if quota.is_unknown:
        current = time.monotonic() if monotonic_now is None else monotonic_now
        if state.quota_unknown_since is None:
            state.quota_unknown_since = current
        if current - state.quota_unknown_since < OFFICIAL_QUOTA_UNKNOWN_GRACE_SECONDS:
            state.launch_hold = "quota_unknown"
            return "wait"
        # 宽限用尽：放行一次，但明确记账"额度没核实过"，绝不假装额度充足。
        # 计时器清零 = 下一次重拉必须重新等满宽限，坏接口因此始终是刹车而不是永久停摆。
        state.launch_hold = None
        state.quota_unknown_since = None
        state.quota_unverified_launch_at = now_iso()
        return "launch"

    state.launch_hold = None
    state.quota_unknown_since = None
    return "launch"


def activate_fallback(state: RelayRetryState) -> bool:
    """每个无进展窗口最多切一次备用出口。"""
    if not state.fallback_provider or state.fallback_attempted:
        return False
    state.active_provider = state.fallback_provider
    state.fallback_attempted = True
    state.switch_count += 1
    state.last_switch_at = now_iso()
    return True


def return_to_primary_provider(state: RelayRetryState) -> None:
    """备用出口本轮没有拉活后，继续等待主出口恢复，不反复切换。"""
    state.active_provider = state.primary_provider


def note_no_progress(
    state: RelayRetryState,
    *,
    monotonic_now: float | None = None,
    wall_time: str | None = None,
) -> None:
    if state.first_failure_monotonic is not None:
        return
    state.first_failure_monotonic = time.monotonic() if monotonic_now is None else monotonic_now
    state.first_failure_at = now_iso() if wall_time is None else wall_time


def clear_no_progress(state: RelayRetryState) -> None:
    """一条命已经稳定跑足够久，下一次异常从新的 30 分钟窗口重新计算。"""
    state.first_failure_monotonic = None
    state.first_failure_at = None
    state.fallback_attempted = False
    state.down_streak = 0
    state.active_provider = state.primary_provider


def escalation_due(state: RelayRetryState, *, monotonic_now: float | None = None) -> bool:
    if state.first_failure_monotonic is None:
        return False
    current = time.monotonic() if monotonic_now is None else monotonic_now
    return current - state.first_failure_monotonic >= RELAY_ESCALATION_SECONDS


def relay_status_payload(state: RelayRetryState) -> dict[str, object]:
    probe = state.last_probe
    wait_elapsed_s = None
    if state.first_failure_monotonic is not None:
        wait_elapsed_s = max(0, int(time.monotonic() - state.first_failure_monotonic))
    return {
        "state": probe.state if probe is not None else "not_applicable",
        "checked_at": probe.checked_at if probe is not None else None,
        "last_ok": probe.last_ok if probe is not None else None,
        "recent_ok": list(probe.recent_ok) if probe is not None else [],
        "detail": probe.detail if probe is not None else None,
        "primary_provider": state.primary_provider,
        "active_provider": state.active_provider,
        "fallback_provider": state.fallback_provider,
        "fallback_attempted": state.fallback_attempted,
        "switch_count": state.switch_count,
        "last_switch_at": state.last_switch_at,
        "first_failure_at": state.first_failure_at,
        "wait_elapsed_s": wait_elapsed_s,
        "escalation_after_s": RELAY_ESCALATION_SECONDS,
        # 出口感知：哨兵靠这三个字段把"为什么现在没动静"显示成人话。
        # enabled_exits 只有计数，绝不含出口名字。
        "no_exit": state.no_exit,
        "no_exit_since": state.no_exit_since,
        "no_exit_reason": no_exit_reason_text(state.exit_posture) if state.no_exit else None,
        "enabled_exits": state.exit_posture.as_payload() if state.exit_posture is not None else None,
        # 出口额度闸：官方 GPT 家族在不在路由里、它的周窗口用到哪了、这轮为什么不发射。
        # 只有百分比 / 重置时刻 / 人话，没有账号标识，更没有任何凭据。
        "official_gpt_in_route": official_gpt_in_route(state.exit_posture),
        "official_quota": state.official_quota.as_payload() if state.official_quota is not None else None,
        "launch_hold": state.launch_hold,
        "launch_hold_reason": (
            no_exit_reason_text(state.exit_posture)
            if state.launch_hold == "no_exit"
            else official_quota_reason_text(state) if state.launch_hold else None
        ),
        "quota_unverified_launch_at": state.quota_unverified_launch_at,
    }


def wait_for_relay_or_backoff(
    *,
    delay_s: float,
    probe: InputRelayProbe | GatewayRelayProbe | None,
    release_on_healthy: bool,
    on_tick: Callable[[RelayProbeResult | None, int], bool],
    should_probe_now: Callable[[], bool] | None = None,
    probe_interval_s: float = POLL_SECONDS,
    release_when: Callable[[RelayProbeResult | None], bool] | None = None,
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> RelayWaitResult:
    """退避期间保持心跳；控制文件按 1 秒轮询，健康探针默认保持原 30 秒频率。

    probe_interval_s 让结构性无出口那档把探测降到 5 分钟；release_when 让那一档改用
    "Input 不再明确不通"当放行判据——本地网关 healthy 在那种局面下是假信号，
    照它放行等于 30 秒发一次注定失败的请求。
    """
    deadline = monotonic() + max(0.0, delay_s)
    next_probe_at = monotonic()
    latest: RelayProbeResult | None = None
    while True:
        if should_probe_now is not None and should_probe_now():
            return RelayWaitResult("probe_now", latest)
        current = monotonic()
        if current >= next_probe_at and probe is not None:
            latest = probe.check()
            released = release_when(latest) if release_when is not None else latest.state == "healthy"
            if release_on_healthy and released:
                return RelayWaitResult("relay_recovered", latest)
        if current >= next_probe_at:
            remaining = max(0, int(deadline - current + 0.999))
            if on_tick(latest, remaining):
                return RelayWaitResult("escalated", latest)
            next_probe_at = current + max(1.0, probe_interval_s)
        remaining = max(0, int(deadline - monotonic() + 0.999))
        if remaining == 0:
            return RelayWaitResult("backoff_elapsed", latest)
        until_probe = max(0.0, next_probe_at - monotonic())
        sleep(min(CONTROL_POLL_SECONDS, until_probe or CONTROL_POLL_SECONDS, remaining))


def log_line(log: Path, msg: str) -> None:
    with log.open("a") as f:
        f.write(f"=== babysitter {datetime.now(APP_TIMEZONE).strftime('%H:%M:%S')} {msg} ===\n")


def first_line(f: Path) -> str:
    try:
        with f.open("rb") as fh:
            return fh.readline(65536).decode("utf-8", errors="replace")
    except OSError:
        return ""


def worklog_hint_from_prompt(prompt_file: str | None) -> str | None:
    if not prompt_file:
        return None
    try:
        text = Path(prompt_file).read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    for line in text.splitlines():
        if "交活报告写" not in line:
            continue
        hint = line.split("交活报告写", 1)[1].strip(" ：:。")
        return hint or line.strip()
    return None


RESUME_CONTEXT_FIELDS = ("workdir", "prompt_file", "workorder_base", "worklog_hint")


def read_resume_context(status_path: Path) -> dict[str, str]:
    """从同线旧状态恢复救援坐标；坏文件或缺字段按空上下文降级。"""
    try:
        payload = json.loads(status_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict):
        return {}
    return {
        field: value
        for field in RESUME_CONTEXT_FIELDS
        for value in (payload.get(field),)
        if isinstance(value, str) and value.strip()
    }


def run_workorder_coordinate_audit(
    prompt_file: str,
    workdir: str,
    base: str,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> subprocess.CompletedProcess[str]:
    """Fresh dispatches must prove prompt coordinates against an explicit Git base."""
    interpreter = Path(sys.executable).expanduser().resolve()
    script = Path(__file__).resolve().with_name("audit_workorder_coordinates.py")
    repository = Path(workdir).expanduser().resolve()
    return runner(
        [
            str(interpreter),
            str(script),
            "--repo",
            str(repository),
            "--base",
            base,
            str(Path(prompt_file).expanduser().resolve()),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def run_finding_freshness_audit(
    prompt_file: str,
    workdir: str,
    target: str,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> subprocess.CompletedProcess[str] | None:
    """Run the opt-in finding gate; legacy workorders return without side effects."""
    prompt = Path(prompt_file).expanduser().resolve()
    try:
        text = prompt.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    if FINDING_FRESHNESS_FIELD_RE.search(text) is None:
        return None

    interpreter = Path(sys.executable).expanduser().resolve()
    script = Path(__file__).resolve().with_name("audit_finding_freshness.py")
    repository = Path(workdir).expanduser().resolve()
    return runner(
        [
            str(interpreter),
            str(script),
            "--repo",
            str(repository),
            "--target",
            target,
            str(prompt),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def marker_matches(marker: str, line: str) -> bool:
    """路径型 marker 必须整段匹配到边界，防前缀撞车。

    2026-07-04 实踩：marker=主仓 /Users/.../Code/cortex 时，子串匹配会把
    /Users/.../Code/cortex-worktrees/settings-modal 的别线会话认成自己的，
    重启分支顺着 resume 了别人的活跃会话。路径 marker 要求后面紧跟引号
    （rollout 第一行元数据里 cwd 是 JSON 字符串）。
    """
    if marker.startswith("/"):
        return f'{marker}"' in line
    return marker in line


def find_rollout(marker: str, newer_than: float) -> Path | None:
    """找 mtime 最新、且会话元数据（第一行，含 cwd）匹配 marker 的 rollout。

    只看第一行是根因修复：全文匹配会把「读过含 marker 文件的别家会话」认成自己的
    （2026-07-04 实踩：把隔壁 D1 线会话当成 stage3 的 resume 了）。
    """
    best: tuple[float, Path] | None = None
    for f in SESSIONS.glob("*/*/*/rollout-*.jsonl"):
        try:
            mtime = f.stat().st_mtime
        except OSError:
            continue
        if mtime < newer_than:
            continue
        if best is not None and mtime <= best[0]:
            continue
        if marker_matches(marker, first_line(f)):
            best = (mtime, f)
    return best[1] if best else None


def rollout_born_after(ts: float) -> Path | None:
    """按文件名里的创建时间找 ts 之后新开的 rollout（跨窗口区分靠时间贴近）。"""
    best: tuple[float, Path] | None = None
    for f in SESSIONS.glob("*/*/*/rollout-*.jsonl"):
        m = re.match(r"rollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-", f.name)
        if not m:
            continue
        born = time.mktime((int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]), int(m[6]), 0, 0, -1))
        if born >= ts - 5 and (best is None or born > best[0]):
            best = (born, f)
    return best[1] if best else None


def rollout_from_fds(root_pid: int) -> Path | None:
    """按进程树打开的文件句柄认领 rollout（lsof），一锤定音。

    同 cwd 多线并发初派时，mtime+marker 竞猜会互认漂移（2026-07-06 实踩：
    四线同窗口，find_rollout 每轮扫到谁最后被写就认谁）。codex 引擎子进程
    全程持有自己 rollout 的写句柄，fd 归属不会撞；拿不到（lsof 缺失/超时）
    返回 None 走旧逻辑兜底。
    """
    pids = [root_pid]
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True, timeout=10).stdout
        kids: dict[int, list[int]] = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) != 2:
                continue
            try:
                pid, ppid = int(parts[0]), int(parts[1])
            except ValueError:
                continue
            kids.setdefault(ppid, []).append(pid)
        queue = [root_pid]
        while queue:
            cur = queue.pop()
            for c in kids.get(cur, []):
                pids.append(c)
                queue.append(c)
    except Exception:
        pass
    for pid in pids:
        try:
            out = subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True, timeout=10).stdout
        except Exception:
            continue
        for line in out.splitlines():
            m = re.search(r"(/\S*/rollout-\S*\.jsonl)", line)
            if m:
                return Path(m.group(1))
    return None


def sid_from_rollout(path: Path) -> str | None:
    m = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$", path.name)
    return m.group(1) if m else None


def tree_cpu_percent(root_pid: int) -> float:
    """整棵进程树（含孙子，如测试子进程）的 CPU 百分比之和。"""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,%cpu="], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return 999.0  # 拿不到就当活着，宁可漏杀不误杀
    children: dict[int, list[int]] = {}
    cpu: dict[int, float] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        try:
            pid, ppid, pct = int(parts[0]), int(parts[1]), float(parts[2])
        except ValueError:
            continue
        children.setdefault(ppid, []).append(pid)
        cpu[pid] = pct
    total, stack, seen = 0.0, [root_pid], set()
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        total += cpu.get(p, 0.0)
        stack.extend(children.get(p, []))
    return total


def read_billing_endpoint(provider_override: str | None = None) -> tuple[str, str, str] | str:
    """读本线 Codex 计费出口。返回 (provider, base_url, key) 或降级原因。

    密钥源优先级（2026-07-11 补，Falcon 用 Cockpit Tools 切号后 provider 定义
    自带显式密钥）：① provider 段的 experimental_bearer_token ② auth.json 的
    OPENAI_API_KEY。都没有 = OAuth 转发型中转，API 层查不到余额。
    Falcon 切中转站会改写 config.toml，本函数每次刷新重读即自动跟上激活站。
    """
    try:
        import tomllib

        cfg = tomllib.loads(codex_config_path().read_text())
        provider = provider_override or cfg.get("model_provider")
        if not provider:
            return "官方计费通道，无余额接口"
        provider_cfg = cfg.get("model_providers", {}).get(provider, {})
        base = (provider_cfg.get("base_url") or "").rstrip("/")
        key = (provider_cfg.get("experimental_bearer_token") or "").strip()
        if not key.startswith("sk-"):
            key = json.loads((codex_home() / "auth.json").read_text()).get("OPENAI_API_KEY") or ""
        if base and key:
            return provider, base, key
        return f"计费走中转({provider})但无 sk- 密钥（OAuth 转发型），API 查不到余额"
    except Exception:
        return "计费出口配置读取失败，余额未知"


def fetch_relay_balance(base: str, key: str) -> dict:
    """查中转站余额（Cola 切号器配方；2026-07-10 实测 Furry=sub2api 系回真实账户余额，
    inputim=OAuth 转发型 API 层查不到只能落"不支持"）。

    sub2api 系 GET {root}/v1/usage 拿账户余额 → new-api 系 GET {root}/api/usage/token/
    拿本密钥额度(÷500000，只是密钥额度、绝不冒充账户余额) → 都不行落"不支持" note。
    余额查不到永不报错：任何失败降级为 note，绝不影响守护主职；密钥只进请求头不落盘。
    """
    import urllib.request

    def get_json(url: str) -> dict | None:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
        try:
            with urllib.request.urlopen(req, timeout=8) as r:
                return json.loads(r.read().decode("utf-8", errors="replace"))
        except Exception:
            return None

    root = re.sub(r"/v1/?$", "", base)
    d = get_json(f"{root}/v1/usage")
    if isinstance(d, dict) and ("balance" in d or "remaining" in d):
        try:
            remaining = round(float(d.get("balance", d.get("remaining"))), 2)
        except (TypeError, ValueError):
            remaining = None
        out = {"remaining": remaining, "currency": d.get("unit") or "?", "scope": "account",
               "checked_at": now_iso()}
        if remaining is not None and remaining <= BALANCE_WARN_THRESHOLD:
            out["note"] = "余额告急，该提醒 Falcon 充值了"
        return out
    d = get_json(f"{root}/api/usage/token/")
    if isinstance(d, dict) and isinstance(d.get("data"), dict) and d["data"].get("object") == "token_usage":
        data = d["data"]
        total = data.get("total_available")
        if data.get("unlimited_quota") or total is None:
            return {"scope": "token", "note": "密钥未设限额，查不到额度", "checked_at": now_iso()}
        remaining = round(float(total) / 500000, 2)
        out = {"remaining": remaining, "currency": "?", "scope": "token", "checked_at": now_iso()}
        if remaining <= BALANCE_WARN_THRESHOLD:
            out["note"] = "密钥额度告急"
        return out
    return {"note": "该中转不支持 API 余额查询（如 OAuth 转发型）", "checked_at": now_iso()}


def resolve_aio_official_provider(
    db_path: Path = Path.home() / ".aio-coding-hub" / "aio-coding-hub.db",
) -> AIOOfficialProvider | None:
    """找 AIO 当前启用的 Codex OAuth provider，只读 id/name，不读取凭据列。"""
    try:
        with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=0.2) as conn:
            row = conn.execute(
                """
                SELECT id, name
                FROM providers
                WHERE enabled = 1 AND cli_key = 'codex'
                  AND auth_mode = 'oauth' AND oauth_provider_type = 'codex_oauth'
                ORDER BY priority DESC, sort_order ASC, id ASC
                LIMIT 1
                """
            ).fetchone()
    except (OSError, sqlite3.Error):
        return None
    if not row:
        return None
    name = row[1].strip() if isinstance(row[1], str) and row[1].strip() else None
    return AIOOfficialProvider(id=int(row[0]), name=name)


def resolve_aio_official_provider_id(
    db_path: Path = Path.home() / ".aio-coding-hub" / "aio-coding-hub.db",
) -> int | None:
    """兼容旧调用方：只返回当前启用的 Codex OAuth provider id。"""
    provider = resolve_aio_official_provider(db_path)
    return provider.id if provider is not None else None


def _window_value(window: dict, *keys: str) -> object | None:
    for key in keys:
        if key in window:
            return window[key]
    return None


def _window_used_percent(window: dict) -> float | None:
    raw = _window_value(window, "used_percent", "usedPercent", "utilization")
    try:
        value = round(float(raw), 1)
    except (TypeError, ValueError):
        return None
    return int(value) if value.is_integer() else value


def _window_reset_iso(window: dict) -> str | None:
    raw = _window_value(window, "reset_at", "resetAt", "reset_time", "resetTime")
    try:
        timestamp = float(raw)
    except (TypeError, ValueError):
        return raw if isinstance(raw, str) and raw.strip() else None
    try:
        return datetime.fromtimestamp(timestamp, timezone.utc).isoformat()
    except (OverflowError, OSError, ValueError):
        return None


def parse_official_usage(payload: object) -> dict:
    """把 AIO 代理的官方 wham usage 收敛成 status.json 的稳定周额度结构。"""
    checked_at = now_iso()
    if not isinstance(payload, dict):
        return {"scope": "official_weekly", "note": "官方额度接口返回格式暂不支持", "checked_at": checked_at}
    rate_limit = payload.get("rate_limit") or payload.get("rateLimit")
    if not isinstance(rate_limit, dict):
        return {"scope": "official_weekly", "note": "官方额度接口返回格式暂不支持", "checked_at": checked_at}

    windows: list[tuple[str | None, dict]] = []
    for label, *keys in (
        ("five_hour", "five_hour_window", "fiveHourWindow", "5_hour_window"),
        ("weekly", "weekly_window", "weeklyWindow"),
        (None, "primary_window", "primaryWindow"),
        (None, "secondary_window", "secondaryWindow"),
    ):
        value = next((rate_limit.get(key) for key in keys if isinstance(rate_limit.get(key), dict)), None)
        if isinstance(value, dict):
            windows.append((label, value))

    weekly: dict | None = None
    five_hour: dict | None = None
    for label, window in windows:
        seconds_raw = _window_value(window, "limit_window_seconds", "limitWindowSeconds", "window_seconds")
        try:
            seconds = float(seconds_raw)
        except (TypeError, ValueError):
            seconds = 0
        if label == "weekly" or seconds >= 6 * 24 * 60 * 60:
            weekly = weekly or window
        elif label == "five_hour" or (0 < seconds <= 6 * 60 * 60):
            five_hour = five_hour or window

    weekly_used = _window_used_percent(weekly) if weekly is not None else None
    if weekly_used is None:
        return {"scope": "official_weekly", "note": "官方额度接口暂未返回周窗口", "checked_at": checked_at}

    plan_type = payload.get("plan_type") or payload.get("planType")
    email = payload.get("email")
    out: dict[str, object] = {
        "scope": "official_weekly",
        "plan_type": plan_type if isinstance(plan_type, str) else None,
        "email": email if isinstance(email, str) and email.strip() else None,
        "weekly_used_pct": weekly_used,
        "weekly_reset_at": _window_reset_iso(weekly),
        "checked_at": checked_at,
    }
    if five_hour is not None:
        five_hour_used = _window_used_percent(five_hour)
        if five_hour_used is not None:
            out["five_hour_used_pct"] = five_hour_used
            out["five_hour_reset_at"] = _window_reset_iso(five_hour)
    return out


def fetch_official_usage(
    base: str,
    key: str,
    provider_id: int | None,
    provider_name: str | None = None,
) -> dict:
    """经 AIO `/v1/usage` 查询官方账户；provider header 把请求锁到官方 OAuth 上游。"""
    headers = {"Authorization": f"Bearer {key}", "User-Agent": "CortexSentinel/1.0"}
    if provider_id is not None:
        headers["x-aio-provider-id"] = str(provider_id)
    request = urllib.request.Request(f"{base.rstrip('/')}/usage", headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.loads(response.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        # 404 / 405 / 501 = 这台 AIO 压根没有这个接口，等多久都不会有数。
        # 必须跟"暂时打不通"分开：拿它当暂时故障去反复扣着等，就是永久卡死。
        if exc.code in OFFICIAL_USAGE_UNSUPPORTED_STATUSES:
            return {
                "scope": "official_weekly",
                "provider_name": provider_name,
                "note": "这台 AIO 没有提供官方额度接口，守护查不到周额度",
                "usage_unsupported": True,
                "checked_at": now_iso(),
            }
        return {
            "scope": "official_weekly",
            "provider_name": provider_name,
            "note": "官方额度接口暂不可达",
            "checked_at": now_iso(),
        }
    except (OSError, TimeoutError, urllib.error.URLError, json.JSONDecodeError):
        return {
            "scope": "official_weekly",
            "provider_name": provider_name,
            "note": "官方额度接口暂不可达",
            "checked_at": now_iso(),
        }
    result = parse_official_usage(payload)
    result["provider_name"] = provider_name
    return result


def refresh_balance_meta(
    provider_override: str | None = None,
    *,
    aio_db_path: Path | None = None,
) -> dict:
    ep = read_billing_endpoint(provider_override)
    if isinstance(ep, str):
        return {"note": ep, "checked_at": now_iso()}
    provider, base, key = ep
    if "official" in provider.lower():
        official = (
            resolve_aio_official_provider(aio_db_path)
            if aio_db_path is not None
            else resolve_aio_official_provider()
        )
        return fetch_official_usage(
            base,
            key,
            official.id if official is not None else None,
            official.name if official is not None else None,
        )
    return fetch_relay_balance(base, key)


def _balance_has_value(balance: object) -> bool:
    return isinstance(balance, dict) and (
        balance.get("weekly_used_pct") is not None or balance.get("remaining") is not None
    )


def merge_balance_refresh(previous: object, refreshed: dict) -> dict:
    """失败时保留最后一次成功快照，避免把旧数字伪装成刚刷新的数字。"""
    if _balance_has_value(refreshed):
        return {**refreshed, "stale": False}

    failed = {**refreshed, "stale": True}
    if not _balance_has_value(previous):
        return failed

    preserved = dict(previous)
    preserved["stale"] = True
    preserved["note"] = refreshed.get("note") or "余额刷新失败，保留上次成功值"
    if refreshed.get("checked_at") is not None:
        preserved["refresh_failed_at"] = refreshed["checked_at"]
    return preserved


def refresh_balance_if_due(
    status_meta: dict,
    provider_override: str | None,
    last_refresh_at: float | None,
    *,
    now_monotonic: float | None = None,
    refresher: Callable[[str | None], dict] | None = None,
) -> float | None:
    """按 monotonic 周期刷新 balance；供 running/waiting 共用并便于合成时钟测试。"""
    current = time.monotonic() if now_monotonic is None else now_monotonic
    if last_refresh_at is not None and current - last_refresh_at < BALANCE_REFRESH_SECONDS:
        return last_refresh_at
    refresh = refresher or refresh_balance_meta
    status_meta["balance"] = merge_balance_refresh(
        status_meta.get("balance"),
        refresh(provider_override),
    )
    return current


RATE_LIMIT_BACKOFF = (15, 30, 60, 120, 300)  # 429 阶梯退避秒数，索引超界后 300 封顶

# 余额不足类：重试无意义（充值前一直是这错），必须直接 help。大小写不敏感子串匹配。
NO_BALANCE_MARKERS = (
    "insufficient", "quota exceeded", "quota_exceeded", "arrearage",
    "balance", "余额不足", "余额", "欠费", "credit",
)
# 限流类：阶梯退避后大概率能续上。
RATE_LIMIT_MARKERS = (
    "429", "too many requests", "rate limit", "rate_limit", "ratelimit", "限流",
)
# 只匹配 Codex CLI 的 ERROR 行；这些是传输/上游机械信号，不拿模型正文猜。
CHANNEL_FAILURE_MARKERS = (
    "stream disconnected",
    "connection reset",
    "connection refused",
    "network unreachable",
    "error sending request",
    "bad gateway",
    "service unavailable",
    "gateway timeout",
    "upstream error",
    "upstream_error",
    "http 502",
    "http 503",
    "http 504",
)
# 假收工类：rc=0 但模型自己在结语里承认没干完（2026-07-24 v2/v3 三轮实踩：
# 工具通道故障时模型把 exec 写成纯文字空转，最后"正常"退出 rc=0 被误标 done）。
# 匹配对象是模型结语的自认话术 + 通道故障的机械信号（模型把工具调用打成
# " to=functions.exec" 字面文本），都只会出现在故障轮的日志尾部。
FAKE_DONE_MARKERS = (
    "任务尚未完成", "尚未完成最终验收", "请重新建立工具会话", "工具调用通道", "to=functions",
)
FAKE_DONE_SLEEP = 300  # 通道故障多半是上游/聚合切到坏中转，退避久一点等天气变化
# 真错误仍用有界阶梯退避；通道侧失败走独立 30 分钟等待窗，不再使用或消耗本预算。
STORM_BACKOFF = (60, 300, 900, 1800, 3600, 3600)
RELAY_SIDE_ERROR_CLASSES = frozenset({"rate_limit", "fake_done", "relay_unavailable"})


def is_relay_side_failure(
    err_class: str,
    probe: RelayProbeResult | None,
    *,
    probe_configured: bool,
) -> bool:
    """判定本轮是否应归入通道等待，而不是消耗真错误重拉预算。

    明确的限流/工具通道假收工直接算通道侧；已配置探针时，unhealthy、unknown
    以及探针暂时拿不到结果都保守算通道侧。没有可用探针且没有机械通道信号时，
    进程崩溃等异常仍是普通错误，继续受 max_restarts 约束。
    """
    if err_class in RELAY_SIDE_ERROR_CLASSES:
        return True
    if not probe_configured:
        return False
    return probe is None or probe.state in {"unhealthy", "unknown"}


def _log_tail(log_path: Path, lines: int = 120) -> str:
    """读 log 尾部约 N 行（seek 尾部 128KB 再切，绝不整文件载入）。"""
    try:
        with log_path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - 131072))
            raw = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return ""
    return "\n".join(raw.splitlines()[-lines:])


def classify_exit_error(log_path: Path) -> str:
    """本轮退出错误分类：rate_limit/no_balance/relay_unavailable/unknown。

    本轮错误必在 log 尾部（codex stdout/stderr 顺序追加同一 log）。余额不足优先于
    限流判定：一条日志两者都命中按余额算——欠费常伴随 4xx/429，但重试无意义，
    必须走"不踹直接 help"而不是傻等阶梯退避。

    只认 CLI 错误行（ERROR 开头）：日志尾部大头是模型自己的工作输出，代理写切号/
    余额相关代码时正文里全是 balance/余额字样，全文子串匹配会把 429 误判成欠费
    （2026-07-23 sentinel-failover 刀实踩，429 被按 no_balance 直接 help）。
    """
    tail = _log_tail(log_path)
    if not tail:
        return "unknown"
    error_lines = " ".join(
        ln for ln in tail.splitlines() if ln.lstrip().lower().startswith("error")
    ).lower()
    if not error_lines:
        return "unknown"
    if any(m in error_lines for m in NO_BALANCE_MARKERS):
        return "no_balance"
    if any(m in error_lines for m in RATE_LIMIT_MARKERS):
        return "rate_limit"
    if any(m in error_lines for m in CHANNEL_FAILURE_MARKERS):
        return "relay_unavailable"
    return "unknown"


def fake_done_marker(log_path: Path) -> str | None:
    """rc=0 收工前的假收工体检：日志尾部命中自认未完成/通道故障信号则返回命中串。

    只看尾部约 40 行：命中信号都在模型结语附近；看太长会把工单原文里引用的
    历史教训（如本注释这类描述文字进了 prompt 回显）误判进来。
    """
    tail = _log_tail(log_path, lines=40)
    for m in FAKE_DONE_MARKERS:
        if m in tail:
            return m
    return None


def error_excerpt(log_path: Path, limit: int = 200) -> str:
    """给 help 状态挑一句人话摘录：尾部最后一条非空行，截到 limit 字符。"""
    for line in reversed(_log_tail(log_path).splitlines()):
        s = line.strip()
        if s:
            return s[:limit]
    return "（日志无内容）"


def restart_preamble(attempt: int) -> str:
    """fresh 重拉时拼在工单后的续跑前言：新会话看不到前轮上下文，钉死先看现场再续做。"""
    return (
        f"\n\n【守护第 {attempt} 轮重拉】前一轮会话已死（断流或工具通道故障），"
        "这是全新会话，看不到前轮任何上下文。工作区可能已有前轮 commit 的半成品："
        "先 git log --oneline -10 和 git status 看现场，接着做剩下的，绝不重做已完成部分。"
    )


def spawn_codex(
    args: argparse.Namespace,
    sid: str | None,
    log: Path,
    attempt: int = 0,
    provider: str | None = None,
) -> subprocess.Popen:
    global _ACTIVE_CODEX_PROCESS

    # "--" 分隔符防 prompt 内容被 CLI 当参数解析
    # （2026-07-04 实踩：工单文件以 YAML frontmatter "---" 开头，fresh 派工被
    #  codex CLI 报 unexpected argument 秒炸，随后重启分支接错别线会话）。
    if sid:
        resume_prompt = args.resume_prompt
        # 2026-07-05 实踩：断流 resume 后模型可能失忆、翻别的 plans/handoff 当"当前工作面"，
        # 跑出 worktree 用绝对路径改主仓（gw12 首派事故）。resume 必须重新钉死工单与工作目录。
        anchor = []
        if args.cd:
            anchor.append(f"你的工作目录锁定 {args.cd}，只准在这个目录里编辑/commit，绝不改其他目录（包括主仓）。")
        if args.prompt_file:
            anchor.append(f"你的唯一工单是 {args.prompt_file}，如果不记得自己在干什么，先重读它再继续；其他任何 plans/handoff 文档都不是你的任务。")
        if anchor:
            resume_prompt = resume_prompt + " " + " ".join(anchor)
        cmd = [CODEX, "exec", "resume", "--skip-git-repo-check",
               "-c", f"model={args.model}", "-c", f"model_reasoning_effort={args.effort}"]
        active_provider = provider or getattr(args, "provider", None)
        if active_provider:
            cmd += ["-c", f"model_provider={active_provider}"]
        for kv in getattr(args, "config_kv", None) or []:
            cmd += ["-c", kv]
        cmd += ["--", sid, resume_prompt]
        log_line(log, f"resume {sid}")
    else:
        # fresh 线重拉不 resume：codex exec resume 对断流会话有两种死法（接错线 /
        # 工具通道整段失效纯文字空转），2026-07-24 v3 刀实锤后一律初派新会话续半成品。
        prompt = Path(args.prompt_file).read_text()
        if attempt:
            prompt += restart_preamble(attempt)
            log_line(log, f"fresh restart #{attempt} cd={args.cd}")
        else:
            log_line(log, f"fresh dispatch cd={args.cd}")
        cmd = [CODEX, "exec", "--skip-git-repo-check", "--cd", args.cd,
               "-m", args.model, "-c", f"model_reasoning_effort={args.effort}"]
        active_provider = provider or getattr(args, "provider", None)
        if active_provider:
            cmd += ["-c", f"model_provider={active_provider}"]
        for kv in getattr(args, "config_kv", None) or []:
            cmd += ["-c", kv]
        cmd += ["--", prompt]
    logf = log.open("a")
    process = subprocess.Popen(cmd, stdout=logf, stderr=logf, stdin=subprocess.DEVNULL, start_new_session=True)
    _ACTIVE_CODEX_PROCESS = process
    return process


def notify_terminal_state(slug: str, state: str, reason: str = "") -> bool:
    """终态通知；help 由 30 分钟升级门显式调用，避免提前惊动人。"""
    title = {"done": "Codex 收工", "dead": "Codex 死亡"}.get(state, state)
    body = f"{slug}: {reason}" if reason else slug
    try:
        result = subprocess.run(
            ["osascript", "-e",
             f'display notification "{body}" with title "{title}" sound name "Glass"'],
            timeout=10, capture_output=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


# 连续速断计数：短命 +1，长命归零。它仍作为状态诊断信号，但不再在第 3 次直接
# 打扰人；中转可在几十分钟后恢复，求助统一由首次无进展满 30 分钟的门槛决定。
SHORT_LIFE_S = 600
SHORT_LIFE_STREAK_HELP = 3


def update_short_streak(streak: int, lifetime_s: float) -> int:
    """速断连击计数：短命 +1，长命归零。"""
    return streak + 1 if lifetime_s < SHORT_LIFE_S else 0


def notify_escalation(slug: str, body: str) -> bool:
    try:
        result = subprocess.run(
            ["osascript", "-e",
             f'display notification "{slug}: {body}" with title "Codex 求助" sound name "Basso"'],
            timeout=10, capture_output=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def write_status(path: Path, **kw) -> None:
    kw["updated_at"] = now_iso()
    # 原子写：先写同目录 .tmp 再 os.replace，外部监控（每 10min 读一次）绝不会读到
    # 写一半的截断 JSON 而误报 invalid_status。os.replace 同盘原子。
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(kw, ensure_ascii=False, indent=1, sort_keys=True))
    os.replace(tmp, path)
    if kw.get("state") in {"done", "dead"}:
        notify_terminal_state(str(kw.get("slug", path.stem)), str(kw["state"]), str(kw.get("reason", "")))


def _terminate_codex_process(process: subprocess.Popen | None) -> None:
    """精确停止本 babysitter 拉起的独立 Codex 进程组。"""
    if process is None:
        return

    pgid = process.pid
    if process.poll() is None:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass

    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return

    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def process_start_identity(pid: int) -> str | None:
    """返回进程生命周期内稳定的 PID 复用防护标识。"""
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        capture_output=True,
        text=True,
        check=False,
    )
    value = result.stdout.strip()
    return value or None


def _ensure_detached() -> None:
    """让 babysitter 无论被怎么起，都自成独立会话、reparent 到 launchd(PID 1)，
    从源头免疫 Claude Code 的后台任务回收 / 会话进程组连坐信号。

    2026-07-24 实锤：用 Bash run_in_background 起 babysitter，它留在 harness 进程组里，
    harness 回收后台 shell 时把守护连同 codex 子进程一锅端（Falcon 侧零提示）。正确起法
    (Popen start_new_session=True) 早写在 runbook，但靠每个会话手打那串咒语太脆、复发多次。
    根治=守护自己保证脱离，起法起错也杀不死它。

    分支：
    - 已是会话领导者（start_new_session 正确起法）→ 跳过，行为完全不变（零回归）。
    - 交互式终端前台跑（人肉调试）→ 跳过，别把调试进程偷偷藏后台。
    - 其余（run_in_background / nohup / 管道，非 tty 非领导者）→ fork 子进程 setsid 脱离，
      父进程立即退出（让起工方看到"命令跑完即退"），子进程挂 launchd 独立续命。
    """
    try:
        if os.getsid(0) == os.getpid():
            return
    except OSError:
        return
    try:
        if os.isatty(0) or os.isatty(1):
            return
    except OSError:
        pass
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    try:
        devnull = os.open(os.devnull, os.O_RDWR)
        for _fd in (0, 1, 2):
            os.dup2(devnull, _fd)
        if devnull > 2:
            os.close(devnull)
    except OSError:
        pass


def main() -> int:
    ap = argparse.ArgumentParser(description="Codex dispatch babysitter")
    ap.add_argument("--slug", required=True, help="线名，也用于状态文件名")
    ap.add_argument("--model", default="gpt-5.6-sol", help="codex 模型（默认 gpt-5.6-sol，Falcon 2026-07-10 拍板；降智期 Falcon 点名可传旧模型如 gpt-5.4）")
    ap.add_argument("--effort", default="xhigh", help="model_reasoning_effort 档位（默认 xhigh，Falcon 2026-07-25 拍板改回来：max 用的人太多会降智；2026-07-23 的 max 默认作废）")
    ap.add_argument("--provider", help="model_provider 覆盖（如 codex_local_access / aio）。不传= 走 ~/.codex/config.toml 默认。用于中转半残时本线单独换出口，而不必改全局 config 波及别的窗口/桌面版会话（2026-07-27 夜间中转 502 实踩）")
    ap.add_argument("--config-kv", action="append", help="额外 codex -c 覆盖，key=value 形态可传多次（如 service_tier=priority 开 Fast；per 线覆盖别改全局 config.toml，时效性开关忘不掉回滚）")
    ap.add_argument(
        "--allow-global-service-tier",
        action="store_true",
        help="仅救急使用：即使全局 config 有未注释的 service_tier 也放行；默认关闭",
    )
    ap.add_argument(
        "--fallback-provider",
        default=DEFAULT_FALLBACK_PROVIDER,
        help="主出口持续断开时单线尝试一次的备用 model_provider；默认关闭，且名称必须存在于 config.toml 注册表",
    )
    ap.add_argument("--log", required=True, help="codex 输出日志（追加）")
    ap.add_argument("--label-zh", help="面板中文任务名；与 --dispatcher-zh 成对传入后由守护自动登记")
    ap.add_argument("--dispatcher-zh", help="面板来源对话描述；与 --label-zh 成对传入后由守护自动登记")
    ap.add_argument("--cd", help="初派工作目录（fresh 模式）")
    ap.add_argument("--prompt-file", help="初派提示词文件（fresh 模式）")
    ap.add_argument("--workorder-base", help="初派工单坐标对应的 Git commit/ref；fresh 模式必填")
    ap.add_argument("--resume-sid", help="接管已有会话的 session id")
    ap.add_argument("--resume-prompt", default=DEFAULT_RESUME_PROMPT)
    ap.add_argument("--marker", help="rollout 归属识别串，默认= --cd 或 slug")
    ap.add_argument("--stall-minutes", type=float, default=10.0)
    ap.add_argument("--max-restarts", type=int, default=6)
    ap.add_argument("--retry-sleep", type=int, default=60)
    ap.add_argument(
        "--ignore-channel-status",
        action="store_true",
        help="目标通道不通时仍发射；默认不通则拒绝",
    )
    a = ap.parse_args()

    resume = bool(a.resume_sid)
    fresh = not resume and bool(a.cd and a.prompt_file)
    if not fresh and not resume:
        ap.error("要么 --cd + --prompt-file（初派），要么 --resume-sid（接管）")
    gate = apply_dispatch_channel_gate("codex", ignore=bool(a.ignore_channel_status))
    if not gate.allowed:
        return 1
    if fresh:
        disk_gate = apply_dispatch_disk_gate()
        if not disk_gate.allowed:
            return 1
    if fresh and not a.workorder_base:
        # Falcon 2026-08-18 拆闸令：不传就取派工工作树当前 HEAD，别拦人。
        a.workorder_base = "HEAD"
    registration_requested = a.label_zh is not None or a.dispatcher_zh is not None
    if registration_requested and not (
        a.label_zh
        and a.label_zh.strip()
        and a.dispatcher_zh
        and a.dispatcher_zh.strip()
    ):
        ap.error("自动登记必须同时传非空 --label-zh 和 --dispatcher-zh；不写看不懂的面板行")
    try:
        service_tier_notice = enforce_global_service_tier_guard(
            a.config_kv,
            allow_global_service_tier=a.allow_global_service_tier,
        )
    except RuntimeError as exc:
        ap.error(str(exc))
    if fresh:
        coordinate_audit = run_workorder_coordinate_audit(a.prompt_file, a.cd, a.workorder_base)
        if coordinate_audit.stdout:
            print(coordinate_audit.stdout, end="")
        if coordinate_audit.stderr:
            print(coordinate_audit.stderr, end="", file=sys.stderr)
        if coordinate_audit.returncode != 0:
            print("WARN(已放宽·不拦发射): 工单坐标审计有意见；Falcon 2026-08-18 拆闸令。", file=sys.stderr)
        freshness_audit = run_finding_freshness_audit(a.prompt_file, a.cd, a.workorder_base)
        if freshness_audit is not None:
            if freshness_audit.stdout:
                print(freshness_audit.stdout, end="")
            if freshness_audit.stderr:
                print(freshness_audit.stderr, end="", file=sys.stderr)
            if freshness_audit.returncode != 0:
                print("WARN(已放宽·不拦发射): 新鲜度审计有意见；Falcon 2026-08-18 拆闸令。", file=sys.stderr)

    registration_result = None
    if registration_requested:
        try:
            registration_result = upsert_line_registration(
                LINE_REGISTRY_PATH,
                slug=a.slug,
                label_zh=a.label_zh,
                dispatcher_zh=a.dispatcher_zh,
                host=local_host_name(),
            )
        except (LineRegistryError, OSError) as exc:
            ap.error(f"派工登记失败，未启动守护: {exc}")
    else:
        print(
            "WARNING 未传 --label-zh/--dispatcher-zh，按旧调用兼容模式不自动登记；新派工必须补齐这两个参数",
            file=sys.stderr,
        )

    # 起法无关自保：参数错误已在上面同步报出（前台可见），到这里再脱离进独立会话，
    # 保证无论被 Bash run_in_background / nohup / 直接跑，都杀不死。
    _ensure_detached()

    marker = a.marker or a.cd or a.slug
    log = Path(a.log)
    log.parent.mkdir(parents=True, exist_ok=True)
    log_line(log, f"[detach] babysitter pid={os.getpid()} ppid={os.getppid()} sid={os.getsid(0)} 起法自保已生效")
    if gate.line:
        log_line(log, gate.line)
    if registration_result is not None:
        log_line(
            log,
            "line registry "
            f"{registration_result.action} slug={a.slug} registered_at={registration_result.entry['registered_at']}",
        )
    if service_tier_notice:
        log_line(log, service_tier_notice)
    status = status_dir() / f"codex-babysitter-{a.slug}.status.json"
    previous_context = read_resume_context(status) if resume else {}
    if resume:
        # 同 slug 接管会复用原状态文件；先恢复坐标，再写新状态和构造 resume anchor。
        # 调用方显式传值优先，旧状态只补缺失项。
        a.cd = a.cd or previous_context.get("workdir")
        a.prompt_file = a.prompt_file or previous_context.get("prompt_file")
        a.workorder_base = a.workorder_base or previous_context.get("workorder_base")
    status_meta = {
        "babysitter_pid": os.getpid(),
        "babysitter_started": process_start_identity(os.getpid()),
        "prompt_file": a.prompt_file,
        "workorder_base": a.workorder_base,
        "workdir": a.cd,
        "started_at": now_iso(),
        "log_path": str(log),
        "worklog_hint": worklog_hint_from_prompt(a.prompt_file) or previous_context.get("worklog_hint"),
        "channel_status": gate.line,
    }

    handled_signals = (signal.SIGTERM, signal.SIGINT)
    previous_signal_handlers = {sig: signal.getsignal(sig) for sig in handled_signals}

    def stop_on_signal(signum: int, _frame: object) -> None:
        global _ACTIVE_CODEX_PROCESS

        for handled in handled_signals:
            signal.signal(handled, signal.SIG_IGN)
        signal_name = signal.Signals(signum).name
        finished_at = now_iso()
        payload = dict(status_meta)
        try:
            current = json.loads(status.read_text(encoding="utf-8"))
            if isinstance(current, dict):
                payload.update(current)
        except (OSError, json.JSONDecodeError):
            pass
        payload.update(
            slug=a.slug,
            state="killed",
            reason=f"收到 {signal_name}，主控主动停止",
            codex_pid=None,
            codex_started=None,
            babysitter_pid=None,
            killed_at=finished_at,
            finished_at=finished_at,
            exit_code=128 + signum,
        )
        try:
            write_status(status, **payload)
        finally:
            try:
                _terminate_codex_process(_ACTIVE_CODEX_PROCESS)
            finally:
                _ACTIVE_CODEX_PROCESS = None
                raise SystemExit(128 + signum)

    for handled in handled_signals:
        signal.signal(handled, stop_on_signal)

    # 顶层兜底：守护自身一旦抛异常（bad prompt 路径 / codex 缺失 / 磁盘满等），
    # detached 进程 stdout 被吞会无声死亡不写状态 = Falcon 最恨的"命令成功但监控进程消失"。
    # 这里兜住 → 写 dead 状态 + 弹系统通知，绝不静默失联。
    try:
        return supervise_loop(a, log, status, status_meta)
    except Exception as e:
        import traceback

        log_line(log, f"FATAL 守护进程自身异常（非 Codex 问题）: {e}")
        try:
            with log.open("a") as _f:
                _f.write(traceback.format_exc() + "\n")
        except OSError:
            pass
        write_status(status, **status_meta, slug=a.slug, state="dead",
                     reason=f"守护进程自身异常退出（非 Codex 问题，看日志排查）: {str(e)[:200]}")
        return 1
    finally:
        for handled, previous in previous_signal_handlers.items():
            signal.signal(handled, previous)


def supervise_loop(a: argparse.Namespace, log: Path, status: Path, status_meta: dict) -> int:
    relay_state = make_relay_retry_state(
        a,
        warn=lambda message: log_line(log, f"WARN: {message}"),
    )
    relay_probe = make_relay_probe(relay_state, a.model)
    exit_posture_reader = AIOExitPostureReader()
    official_quota_reader = OfficialQuotaReader(
        provider=find_official_usage_provider(read_codex_provider_settings()[1]),
    )
    last_probe_log_signature: tuple[object, ...] | None = None
    last_no_exit_logged: bool | None = None
    last_hold_logged: str | None = None
    last_unverified_alerted: str | None = None
    control_path = status.parent / f"codex-babysitter-{a.slug}.control.json"
    runtime_control = RuntimeControlState(max_restarts=a.max_restarts)
    balance_ts: float | None = None

    def poll_control() -> bool:
        before = (runtime_control.max_restarts, runtime_control.escalate_after_failures)
        probe_now = apply_runtime_control(control_path, runtime_control)
        a.max_restarts = runtime_control.max_restarts
        after = (runtime_control.max_restarts, runtime_control.escalate_after_failures)
        if after != before:
            log_line(
                log,
                f"CONTROL: max_restarts={after[0]} escalate_after_failures={after[1]}",
            )
        if probe_now:
            log_line(log, "CONTROL: 收到 probe_now，跳过剩余等待立即重探")
        return probe_now

    def set_status(**kw) -> None:
        nonlocal balance_ts
        balance_ts = refresh_balance_if_due(
            status_meta,
            relay_state.active_provider,
            balance_ts,
        )
        kw.setdefault("alert", relay_state.alert)
        kw["relay_probe"] = relay_status_payload(relay_state)
        kw["max_restarts_override"] = runtime_control.max_restarts
        kw["escalate_after_failures"] = runtime_control.escalate_after_failures
        kw.setdefault("relay_failures", relay_failures)
        kw.setdefault("launch_attempt", launch_attempt)
        write_status(status, **status_meta, **kw)

    def remember_probe(probe: RelayProbeResult | None) -> None:
        nonlocal last_probe_log_signature
        if probe is not None:
            relay_state.last_probe = probe
            signature = (
                probe.source,
                probe.state,
                probe.detail,
                probe.input_intel_state,
                probe.input_intel_detail,
            )
            if signature != last_probe_log_signature:
                intel = (
                    f"；Input 公共状态情报={probe.input_intel_state}"
                    "（仅日志，不参与 gating）"
                    if probe.input_intel_state is not None
                    else ""
                )
                log_line(
                    log,
                    f"PROBE: source={probe.source} state={probe.state} detail={probe.detail}{intel}",
                )
                last_probe_log_signature = signature

    def queue_reason(
        probe: RelayProbeResult | None,
        remaining_s: int,
        err_class: str | None,
        *,
        relay_outage: bool,
    ) -> str:
        if relay_state.no_exit:
            # 结构性无出口时不写探针术语，直接给 Falcon 看得懂的那句话。
            return f"{no_exit_reason_text(relay_state.exit_posture)}（下次查看 {remaining_s}s 后）"
        if relay_state.launch_hold in {"quota_tight", "quota_unknown"}:
            return f"{official_quota_reason_text(relay_state)}（下次查看 {remaining_s}s 后）"
        if probe is not None and probe.state == "unhealthy":
            head = "通道探针显示不可用，任务留在本地队列"
        elif probe is not None and probe.state == "unknown":
            head = "通道探针结果不确定，保守留在本地队列"
        elif relay_outage:
            head = "日志显示通道侧失败，任务留在本地队列"
        else:
            head = "真错误重拉退避中，任务留在本地队列"
        suffix = f"；最近异常 {err_class}" if err_class else ""
        budget = (
            f"；真错误预算保持 {restarts}/{runtime_control.max_restarts}"
            if relay_outage
            else f"；真错误预算已用 {restarts}/{runtime_control.max_restarts}"
        )
        return f"{head}{suffix}{budget}；{remaining_s}s 后继续检查"

    def wait_in_queue(
        *,
        delay_s: float,
        err_class: str | None,
        rollout: Path | None,
        release_on_healthy: bool,
        relay_outage: bool,
    ) -> RelayWaitResult:
        # 三种"守护主动不发射"的停留：结构性无出口 / 额度紧 / 额度查不到。
        # 都用 5 分钟慢节奏，因为它们都不是靠 30 秒重探能解决的事。
        hold = relay_state.launch_hold if relay_outage else None
        slow_hold = hold is not None
        # 不叫人的只有两种：no_exit 是他自己的配置、他本来就知道；额度查不到是探针问题，
        # 而且自己会在宽限用尽时放行。额度真的打满要叫人——那是动态发生、他不一定知道的事，
        # 而且通知内容可行动（充值 / 换出口 / 接受暂停）。这次发火恰恰是因为没人告诉他。
        structural_pause = hold in {"no_exit", "quota_unknown"}

        def on_tick(probe: RelayProbeResult | None, remaining_s: int) -> bool:
            remember_probe(probe)
            failure_limit = runtime_control.escalate_after_failures
            count_due = not relay_outage and failure_limit is not None and restarts >= failure_limit
            time_due = escalation_due(relay_state) and not structural_pause
            if (relay_outage and time_due) or (not relay_outage and (time_due or count_due)):
                if relay_outage and hold == "quota_tight":
                    # 额度打满跟"通道不通"不是一回事，别用中转的话术糊弄他。
                    relay_state.alert = official_quota_reason_text(relay_state)
                    reason = (
                        f"{official_quota_reason_text(relay_state)}"
                        f"已这样等了 {RELAY_ESCALATION_SECONDS // 60} 分钟，"
                        "守护自己解决不了：要么在 AIO 里开一条别的出口，要么等额度回血。"
                    )
                elif relay_outage:
                    relay_state.alert = (
                        f"通道长时间不通，已等待 {RELAY_ESCALATION_SECONDS // 60} 分钟；"
                        f"真错误预算保持 {restarts}/{runtime_control.max_restarts}"
                    )
                    reason = (
                        f"通道长时间不通：已连续等待 {RELAY_ESCALATION_SECONDS // 60} 分钟，"
                        "期间未消耗真错误重试预算；需要人工介入检查中转。"
                    )
                elif count_due:
                    relay_state.alert = f"已连续失败 {restarts} 次，达到本线设置的 {failure_limit} 次上报门槛"
                    reason = f"守护已连续失败 {restarts} 次，达到本线设置的上报门槛。"
                else:
                    relay_state.alert = (
                        f"首次无进展已超过 {RELAY_ESCALATION_SECONDS // 60} 分钟，"
                        f"已重拉 {restarts} 次并尝试中转恢复"
                    )
                    reason = (
                        f"守护已重试、等待中转恢复并尝试备用出口；从首次无进展起超过 "
                        f"{RELAY_ESCALATION_SECONDS // 60} 分钟仍没有进展。"
                    )
                set_status(
                    slug=a.slug,
                    state="help",
                    codex_pid=None,
                    codex_started=None,
                    restarts=restarts,
                    last_error_class=err_class,
                    reason=reason,
                    rollout=str(rollout) if rollout else None,
                )
                notified = notify_escalation(a.slug, reason)
                log_line(log, f"ESCALATE: {relay_state.alert}，系统通知={'已发送' if notified else '发送失败'}")
                return True
            set_status(
                slug=a.slug,
                state="waiting_relay",
                codex_pid=None,
                codex_started=None,
                restarts=restarts,
                last_error_class=err_class,
                reason=queue_reason(probe, remaining_s, err_class, relay_outage=relay_outage),
                rollout=str(rollout) if rollout else None,
                rollout_age_s=None,
            )
            return False

        result = wait_for_relay_or_backoff(
            delay_s=delay_s,
            probe=relay_probe,
            release_on_healthy=release_on_healthy,
            on_tick=on_tick,
            should_probe_now=poll_control,
            probe_interval_s=NO_EXIT_POLL_SECONDS if slow_hold else POLL_SECONDS,
            # 额度闸这两档不设提前放行判据：本地网关一直是 healthy，照它放行等于没拦。
            # 让 5 分钟走满、回到外层重读额度与出口名单再决定，是最不容易判错的做法。
            release_when=(
                input_relay_released
                if hold == "no_exit"
                else _never_release if slow_hold else None
            ),
        )
        remember_probe(result.probe)
        return result

    # main 里同款推导；漏这行时函数内 find_rollout/marker_matches 全是 NameError
    # （2026-07-23 实踩：两条守护死于 584 行 name 'marker' is not defined）
    marker = a.marker or a.cd or a.slug

    # 接管场景 rollout 可能早于本进程启动，往前放宽 1h；初派只认自己拉起之后
    # 出生的会话，防重启分支把别线近一小时的会话捡走（2026-07-04 实踩第二环）。
    start_ts = time.time() - 3600 if a.resume_sid else time.time() - 5

    sid = a.resume_sid
    restarts = 0
    relay_failures = 0
    launch_attempt = 0
    short_streak = 0
    while True:
        poll_control()
        balance_ts = refresh_balance_if_due(status_meta, relay_state.active_provider, balance_ts)

        # 每次初派与重拉前都按 primary provider 的 base_url 看真实通道状态：本地 AIO
        # 直探 /v1/models，直连 Input 才以公开状态页 gating；备用 provider 不受主探针阻塞。
        while True:
            poll_control()
            # 结构性暂停期间外层每 5 分钟才转一次（或被哨兵 probe_now 叫醒），
            # 这时必须拿鲜结果判定，不能让 30 秒缓存把"Input 已恢复"压掉一整轮。
            probe = (
                relay_probe.check(force=relay_state.no_exit) if relay_probe is not None else None
            )
            remember_probe(probe)
            # 每轮重读 AIO 启用名单：Falcon 随时会自己开关出口，读一次当真值会误判。
            relay_state.exit_posture = exit_posture_reader.read()
            # 官方 GPT 在名单里就把它的周窗口读出来：即便这轮不拦也要报给人看，
            # 因为守护正常派工时看到的是中转的 USD 余额，跟这个桶完全是两回事。
            quota = (
                official_quota_reader.read()
                if official_quota_gate_applies(relay_state)
                and official_gpt_in_route(relay_state.exit_posture)
                else None
            )
            action = next_relay_action(
                relay_state, probe, posture=relay_state.exit_posture, quota=quota
            )
            if relay_state.no_exit != last_no_exit_logged:
                log_line(
                    log,
                    f"RELAY: {no_exit_reason_text(relay_state.exit_posture)}"
                    if relay_state.no_exit
                    else "RELAY: 出口名单里已有非 Input 系出口（或 Input 已恢复），恢复正常重试节奏",
                )
                last_no_exit_logged = relay_state.no_exit
            if relay_state.launch_hold != last_hold_logged:
                if relay_state.launch_hold in {"quota_tight", "quota_unknown"}:
                    log_line(log, f"QUOTA: {official_quota_reason_text(relay_state)}")
                elif last_hold_logged in {"quota_tight", "quota_unknown"}:
                    log_line(log, "QUOTA: 官方 GPT 额度闸已解除，恢复正常发射")
                last_hold_logged = relay_state.launch_hold
            if (
                action == "launch"
                and relay_state.quota_unverified_launch_at is not None
                and relay_state.quota_unverified_launch_at != last_unverified_alerted
            ):
                # 只在真正发生"未核实放行"的那一刻报一次；这个时刻戳会一直留在状态里
                # 当历史记录，但不该每次重拉都把同一句话再喊一遍。
                relay_state.alert = (
                    "官方 GPT 额度查不到，等满宽限后放行了一次，"
                    "这轮的额度消耗没有核实过"
                )
                last_unverified_alerted = relay_state.quota_unverified_launch_at
            if action == "launch":
                if probe is not None and probe.state == "healthy":
                    clear_no_progress(relay_state)
                break
            note_no_progress(relay_state)
            if action == "launch_fallback":
                log_line(
                    log,
                    f"RELAY: 主出口连续 {relay_state.down_streak} 次探测不可用，"
                    f"单线切换 provider={relay_state.active_provider} 重拉一次",
                )
                break
            if relay_state.launch_hold is None:
                log_line(log, "RELAY: 主出口探针不可用，任务留在本地队列等待恢复")
            queued = wait_in_queue(
                delay_s=(
                    NO_EXIT_POLL_SECONDS if relay_state.launch_hold is not None else POLL_SECONDS
                ),
                err_class=None,
                rollout=None,
                release_on_healthy=True,
                relay_outage=True,
            )
            if queued.reason == "escalated":
                return 1
            if queued.reason == "relay_recovered":
                log_line(
                    log,
                    "RELAY: Input 恢复，提前放行重拉"
                    if relay_state.no_exit
                    else "RELAY: 主出口探针恢复，提前放行重拉",
                )

        spawn_ts = time.time()
        if not a.resume_sid:
            start_ts = time.time() - 5  # fresh 重拉只认本轮新生会话，绝不捡上一轮尸体
        provider_override = a.provider if relay_state.active_provider == relay_state.primary_provider else relay_state.active_provider
        p = spawn_codex(a, sid, log, launch_attempt, provider=provider_override)
        codex_started = process_start_identity(p.pid)
        # spawn 后立即写 running，防外部监听读到上一轮残留的 done/help（启动竞态，2026-07-04 实踩）
        set_status(
            slug=a.slug,
            state="running",
            codex_pid=p.pid,
            codex_started=codex_started,
            restarts=restarts,
            rollout=None,
            rollout_age_s=None,
            reason=None,
        )
        low_cpu_streak = 0
        rollout: Path | None = None
        fd_locked = False
        rc: int | None = None
        wrong_session_checked = False
        wrong_session_strikes = 0
        while True:
            time.sleep(POLL_SECONDS)
            poll_control()
            rc = p.poll()
            # 首选 fd 认领：codex 引擎子进程持有自己 rollout 的写句柄，认准后锁死
            # 不再重扫（2026-07-06 实踩：同 cwd 四线并发，mtime+marker 竞猜互认漂移）。
            if not fd_locked and rc is None:
                fd_ro = rollout_from_fds(p.pid)
                if fd_ro is not None:
                    rollout = fd_ro
                    fd_locked = True
            # 接错会话检测：codex resume 解析不了截断会话时会静默回落到别的会话
            # （2026-07-04 实踩）。fd 已锁时直接核自己 rollout 的元数据，一次定论；
            # 拿不到 fd 才走旧 newborn 竞猜（并发多线时 "最新 newborn" 可能是别线的，
            # 2026-07-05 实踩误杀 user-manual 线；resume 给 2 轮宽限）。
            if not wrong_session_checked and rc is None:
                if fd_locked:
                    if sid is not None and not marker_matches(marker, first_line(rollout)):
                        log_line(log, f"WRONG-SESSION: fd 认领的 {rollout.name} 元数据不含 {marker}，resume 接错线，杀掉求救")
                        try:
                            os.killpg(p.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        p.wait()
                        set_status(
                            slug=a.slug,
                            state="help",
                            codex_pid=None,
                            codex_started=None,
                            restarts=restarts,
                            reason=f"resume 接错会话（fd rollout {rollout.name} 归属不符），需要 AI 换初派模式",
                        )
                        return 1
                    wrong_session_checked = True
                else:
                    newborn = rollout_born_after(spawn_ts)
                    if newborn is not None:
                        if marker_matches(marker, first_line(newborn)) or find_rollout(marker, spawn_ts) is not None:
                            wrong_session_checked = True
                        elif sid is None:
                            pass
                        else:
                            wrong_session_strikes += 1
                            if wrong_session_strikes >= 2:
                                log_line(log, f"WRONG-SESSION: 新会话 {newborn.name} 元数据不含 {marker}，且宽限后仍无本线新会话，接错线，杀掉求救")
                                try:
                                    os.killpg(p.pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                                p.wait()
                                set_status(
                                    slug=a.slug,
                                    state="help",
                                    codex_pid=None,
                                    codex_started=None,
                                    restarts=restarts,
                                    reason=f"resume 接错会话（新 rollout {newborn.name} 归属不符），需要 AI 换初派模式",
                                )
                                return 1
            if not fd_locked:
                fresh_rollout = find_rollout(marker, start_ts)
                if fresh_rollout is not None:
                    rollout = fresh_rollout
            r_mtime = rollout.stat().st_mtime if rollout and rollout.exists() else None
            set_status(
                slug=a.slug,
                state="running",
                codex_pid=p.pid,
                codex_started=codex_started,
                restarts=restarts,
                rollout=str(rollout) if rollout else None,
                rollout_age_s=round(time.time() - r_mtime) if r_mtime else None,
                reason=None,
            )
            if rc is not None:
                break
            # hang 体检：rollout 停滞 + 进程树 CPU 连续偏低
            stale = r_mtime is not None and (time.time() - r_mtime) >= a.stall_minutes * 60
            if stale and tree_cpu_percent(p.pid) < 2.0:
                low_cpu_streak += 1
            else:
                low_cpu_streak = 0
            if stale and low_cpu_streak >= LOW_CPU_STREAK_NEEDED:
                log_line(log, f"HANG: rollout 停滞>{a.stall_minutes}min 且树CPU~0，kill -9 组 {p.pid}")
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                p.wait()
                rc = -1  # 强制走重启分支
                break

        if rc == 0:
            fake = fake_done_marker(log)
            if fake is None:
                log_line(log, "收工 rc=0")
                set_status(
                    slug=a.slug,
                    state="done",
                    codex_pid=None,
                    codex_started=None,
                    restarts=restarts,
                    rollout=str(rollout) if rollout else None,
                )
                return 0
            # rc=0 但模型自认没干完 = 假收工（工具通道故障典型结局），按异常重拉自救
            err_class = "fake_done"
            log_line(log, f"FAKE-DONE: rc=0 但日志尾命中「{fake}」，判定假收工，按异常处理")
        else:
            # 按错误类型分层（Falcon 2026-07-16）：分类只看本轮 log 尾部。
            err_class = classify_exit_error(log)

        lifetime_s = int(time.time() - spawn_ts)
        launch_attempt += 1
        # 发射前的绿色缓存不能给刚发生的断线背书；退出归因必须拿一份鲜探针结果。
        probe_after_exit = relay_probe.check(force=True) if relay_probe is not None else None
        remember_probe(probe_after_exit)
        relay_side_failure = is_relay_side_failure(
            err_class,
            probe_after_exit,
            probe_configured=relay_probe is not None,
        )

        if relay_side_failure:
            relay_failures += 1
            note_no_progress(relay_state)
            log_line(
                log,
                f"通道侧失败 rc={rc}（{err_class}），本条命活了 {lifetime_s}s；"
                f"真错误预算保持 {restarts}/{a.max_restarts}，通道失败累计 {relay_failures}",
            )
            if relay_state.active_provider != relay_state.primary_provider:
                log_line(log, f"RELAY: 备用 provider={relay_state.active_provider} 本轮未拉活，回主出口等待恢复")
                return_to_primary_provider(relay_state)

            if err_class == "rate_limit":
                sleep_s = RATE_LIMIT_BACKOFF[min(relay_failures - 1, len(RATE_LIMIT_BACKOFF) - 1)]
                log_line(log, f"限流等待 第{relay_failures}次 等{sleep_s}s（不消耗真错误预算）")
            elif err_class == "fake_done":
                sleep_s = FAKE_DONE_SLEEP
                log_line(log, f"通道故障等待 第{relay_failures}次 等{sleep_s}s（不消耗真错误预算）")
            else:
                sleep_s = POLL_SECONDS
                log_line(log, f"通道不可用，{sleep_s}s 后续探（不消耗真错误预算）")

            queued = wait_in_queue(
                delay_s=sleep_s,
                err_class=err_class,
                rollout=rollout,
                release_on_healthy=(
                    probe_after_exit is None
                    or probe_after_exit.state in {"unhealthy", "unknown"}
                ),
                relay_outage=True,
            )
            if queued.reason == "escalated":
                return 1
            if queued.reason == "relay_recovered":
                log_line(log, "RELAY: 通道等待期间探到主出口恢复，提前放行重拉")
            continue

        # 探针健康或该 provider 没有探针时，进程崩溃/脚本错误属于真错误，
        # 只由有限 max_restarts 预算控制，不能被通道等待吞掉。
        clear_no_progress(relay_state)
        restarts += 1
        short_streak = update_short_streak(short_streak, lifetime_s)
        log_line(
            log,
            f"真错误退出 rc={rc}（{err_class}），本条命活了 {lifetime_s}s，"
            f"已用预算 {restarts}/{a.max_restarts}",
        )

        if restarts >= a.max_restarts:
            relay_state.alert = f"真错误重拉预算已耗尽 {restarts}/{a.max_restarts}"
            reason = (
                f"真错误重拉预算已耗尽（{restarts}/{a.max_restarts}）："
                f"最近异常 {err_class}，exit={rc}；守护停止自动重拉，需要人工介入。"
            )
            set_status(
                slug=a.slug,
                state="help",
                codex_pid=None,
                codex_started=None,
                restarts=restarts,
                last_error_class=err_class,
                reason=reason,
                rollout=str(rollout) if rollout else None,
            )
            notified = notify_escalation(a.slug, reason)
            log_line(log, f"ESCALATE: {relay_state.alert}，系统通知={'已发送' if notified else '发送失败'}")
            return 1

        # 余额不足本身不会恢复；优先给单线备用出口一次机会，两个出口都失败后仍按
        # 统一 30 分钟门槛求助，不在第一次错误时弹通知。
        if err_class == "no_balance":
            note_no_progress(relay_state)
            if relay_state.active_provider == relay_state.primary_provider and activate_fallback(relay_state):
                log_line(log, f"RELAY: 主出口余额不足，单线切换 provider={relay_state.active_provider} 尝试一次")
                continue
            remaining = RELAY_ESCALATION_SECONDS
            if relay_state.first_failure_monotonic is not None:
                remaining = max(1, RELAY_ESCALATION_SECONDS - (time.monotonic() - relay_state.first_failure_monotonic))
            queued = wait_in_queue(
                delay_s=remaining,
                err_class=err_class,
                rollout=rollout,
                release_on_healthy=False,
                relay_outage=False,
            )
            if queued.reason == "escalated":
                return 1
            continue

        if relay_state.active_provider != relay_state.primary_provider:
            log_line(log, f"RELAY: 备用 provider={relay_state.active_provider} 本轮未拉活，回主出口等待恢复")
            return_to_primary_provider(relay_state)
        if short_streak >= SHORT_LIFE_STREAK_HELP:
            log_line(log, f"RETRY: 已连续 {short_streak} 次真错误速断，仍受 {a.max_restarts} 次总预算约束")

        # 只有显式接管模式（--resume-sid）才续 sid 走 resume；fresh 线重拉永远初派新会话
        if a.resume_sid:
            latest = rollout if fd_locked else find_rollout(marker, start_ts)
            if latest:
                sid = sid_from_rollout(latest) or sid
        sleep_s = max(a.retry_sleep, STORM_BACKOFF[min(restarts - 1, len(STORM_BACKOFF) - 1)])
        log_line(log, f"真错误退避 第{restarts}次 等{sleep_s}s")
        queued = wait_in_queue(
            delay_s=sleep_s,
            err_class=err_class,
            rollout=rollout,
            release_on_healthy=False,
            relay_outage=False,
        )
        if queued.reason == "escalated":
            return 1


if __name__ == "__main__":
    sys.exit(main())
