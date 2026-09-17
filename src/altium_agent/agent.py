"""The agent loop.

Deliberately a manual loop rather than the SDK's tool runner. The runner
executes tool functions one at a time, which would mean one Altium wake per
tool call; this loop collects every bridge tool call from an assistant turn and
ships them as ONE batch, so Altium is interrupted once per turn instead of once
per operation. That is the whole reason the editor stays responsive.
See docs/architecture.md.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from typing import Any, Callable

import anthropic

from .blocks import BlockError, BlockLibrary, InstanceStore
from .bridge import AltiumBridge
from .config import Config
from .prompts import system_blocks
from .protocol import BridgeError, Op, OpResult
from .tools import Registry, build_registry
from .tools.base import ToolSpec

log = logging.getLogger(__name__)

ProgressFn = Callable[[str, str], None]   # (kind, detail)

FALLBACK_BETA = "server-side-fallback-2026-07-01"


@dataclass
class Context:
    """What tool builders can reach. Matches the ToolContext protocol."""

    cfg: Config
    blocks: BlockLibrary
    instances: InstanceStore


@dataclass
class TurnResult:
    text: str
    status: str = "done"            # done | error | refused | truncated
    activity: list[str] = field(default_factory=list)
    usage: dict[str, int] = field(default_factory=dict)


class DesignAgent:
    """Holds one conversation and drives Altium through the bridge."""

    def __init__(
        self,
        cfg: Config,
        bridge: AltiumBridge,
        *,
        client: anthropic.Anthropic | None = None,
        registry: Registry | None = None,
    ) -> None:
        self.cfg = cfg
        self.bridge = bridge
        self.client = client or anthropic.Anthropic()
        self.registry = registry or build_registry()
        self.ctx = Context(
            cfg=cfg,
            blocks=BlockLibrary(cfg.blocks_dir),
            instances=InstanceStore(cfg.instances_file),
        )
        self.messages: list[dict[str, Any]] = []
        self._fallback_enabled = cfg.refusal_fallback
        self._usage = {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0}

    # -- public -----------------------------------------------------------

    def run_turn(
        self,
        user_text: str,
        *,
        turn_id: str = "t000000",
        context: dict[str, Any] | None = None,
        on_progress: ProgressFn | None = None,
    ) -> TurnResult:
        """Run one user turn to completion, executing tools along the way."""
        notify = on_progress or (lambda kind, detail: None)
        activity: list[str] = []

        self.messages.append({"role": "user", "content": self._user_content(user_text, context)})

        for iteration in range(self.cfg.max_turns):
            try:
                response = self._request()
            except anthropic.APIError as exc:
                log.exception("API request failed")
                return TurnResult(
                    text=f"The model request failed: {exc}",
                    status="error",
                    activity=activity,
                    usage=dict(self._usage),
                )

            self._accumulate_usage(response)

            if response.stop_reason == "refusal":
                detail = getattr(response, "stop_details", None)
                reason = getattr(detail, "explanation", None) or "no explanation given"
                return TurnResult(
                    text=f"The model declined this request ({reason}).",
                    status="refused",
                    activity=activity,
                    usage=dict(self._usage),
                )

            text = self._text_of(response)
            self.messages.append({"role": "assistant", "content": response.content})

            if response.stop_reason == "max_tokens":
                return TurnResult(
                    text=(text or "")
                    + "\n\n[Response hit the token limit and was cut off. Ask me to continue.]",
                    status="truncated",
                    activity=activity,
                    usage=dict(self._usage),
                )

            tool_uses = [b for b in response.content if b.type == "tool_use"]
            if not tool_uses:
                return TurnResult(
                    text=text,
                    status="done",
                    activity=activity,
                    usage=dict(self._usage),
                )

            if text:
                notify("text", text)

            names = ", ".join(sorted({b.name for b in tool_uses}))
            log.info("turn %s iteration %d: %d tool calls (%s)",
                     turn_id, iteration, len(tool_uses), names)

            results = self._execute(tool_uses, turn_id=turn_id, notify=notify, activity=activity)
            self.messages.append({"role": "user", "content": results})

        return TurnResult(
            text=(
                f"Stopped after {self.cfg.max_turns} tool rounds without finishing. "
                "The design may be partly changed - check the last few operations."
            ),
            status="error",
            activity=activity,
            usage=dict(self._usage),
        )

    def reset(self) -> None:
        self.messages.clear()

    # -- model ------------------------------------------------------------

    def _request(self) -> Any:
        """One streaming request. Streaming because max_tokens is large."""
        params: dict[str, Any] = {
            "model": self.cfg.model,
            "max_tokens": self.cfg.max_tokens,
            "system": system_blocks(),
            "tools": self.registry.api_tools(read_only=self.cfg.read_only),
            "messages": self.messages,
            "thinking": {"type": "adaptive"},
            "output_config": {"effort": self.cfg.effort},
        }

        if self._fallback_enabled:
            try:
                with self.client.beta.messages.stream(
                    betas=[FALLBACK_BETA], fallbacks="default", **params
                ) as stream:
                    return stream.get_final_message()
            except anthropic.BadRequestError as exc:
                if not _is_fallback_rejection(exc):
                    raise
                # The account does not have the fallback beta. Not worth failing
                # a design session over - drop it and carry on without.
                log.warning("server-side refusal fallback unavailable, disabling: %s", exc)
                self._fallback_enabled = False

        with self.client.messages.stream(**params) as stream:
            return stream.get_final_message()

    def _accumulate_usage(self, response: Any) -> None:
        usage = getattr(response, "usage", None)
        if usage is None:
            return
        for key in self._usage:
            self._usage[key] += getattr(usage, key, 0) or 0

    @staticmethod
    def _text_of(response: Any) -> str:
        return "\n".join(b.text for b in response.content if b.type == "text").strip()

    @staticmethod
    def _user_content(text: str, context: dict[str, Any] | None) -> str:
        if not context:
            return text
        # Cheap hint gathered by the panel, so the agent does not burn a tool
        # call discovering what the engineer was looking at.
        hint = json.dumps(context, separators=(",", ":"))
        return f"{text}\n\n<editor_context>{hint}</editor_context>"

    # -- tools ------------------------------------------------------------

    def _execute(
        self,
        tool_uses: list[Any],
        *,
        turn_id: str,
        notify: ProgressFn,
        activity: list[str],
    ) -> list[dict[str, Any]]:
        """Run every tool call from one assistant turn.

        Local tools answer immediately. Bridge tools are collected into a single
        batch so Altium is interrupted once, not once per call.
        """
        results: dict[str, dict[str, Any]] = {}
        batch_ops: list[Op] = []
        op_owner: dict[str, str] = {}
        labels: list[str] = []
        atomic = False

        for use in tool_uses:
            activity.append(use.name)
            notify("tool", use.name)

            try:
                spec = self.registry.get(use.name)
            except KeyError as exc:
                results[use.id] = _error_result(use.id, str(exc))
                continue

            if self.cfg.read_only and spec.mode == "write" and not spec.is_local:
                results[use.id] = _error_result(
                    use.id,
                    f"{use.name} modifies the design, but the agent is running read-only. "
                    "Restart without --read-only to make changes.",
                )
                continue

            if spec.is_local:
                results[use.id] = self._run_local(spec, use)
                continue

            try:
                ops = spec.build_ops(use.id, dict(use.input), self.ctx)
            except (BlockError, ValueError, KeyError) as exc:
                results[use.id] = _error_result(use.id, str(exc))
                continue

            for op in ops:
                op_owner[op.id] = use.id
            batch_ops.extend(ops)
            labels.append(spec.txn_label or use.name)
            atomic = atomic or use.name.startswith("block_")

        if batch_ops:
            results.update(
                self._run_batch(
                    batch_ops,
                    op_owner=op_owner,
                    turn_id=turn_id,
                    label=_label_for(labels),
                    atomic=atomic,
                )
            )

        # Order matters: results must line up with the tool_use blocks, and all
        # of them go back in ONE user message.
        return [results.get(use.id, _error_result(use.id, "Tool produced no result"))
                for use in tool_uses]

    def _run_local(self, spec: ToolSpec, use: Any) -> dict[str, Any]:
        try:
            assert spec.local is not None
            data = spec.local(dict(use.input), self.ctx)
        except (BlockError, ValueError, KeyError, OSError) as exc:
            return _error_result(use.id, str(exc))
        return {
            "type": "tool_result",
            "tool_use_id": use.id,
            "content": json.dumps(data, default=str),
        }

    def _run_batch(
        self,
        ops: list[Op],
        *,
        op_owner: dict[str, str],
        turn_id: str,
        label: str,
        atomic: bool,
    ) -> dict[str, dict[str, Any]]:
        try:
            batch_result = self.bridge.submit(
                ops, turn=turn_id, txn_label=label, atomic=atomic
            )
        except BridgeError as exc:
            # Every tool in the batch failed together. Tell the model that
            # plainly so it does not assume some of them landed.
            return {
                use_id: _error_result(use_id, f"Altium bridge error: {exc}")
                for use_id in set(op_owner.values())
            }

        grouped: dict[str, list[OpResult]] = {}
        for op_result in batch_result.results:
            owner = op_owner.get(op_result.id)
            if owner:
                grouped.setdefault(owner, []).append(op_result)

        out: dict[str, dict[str, Any]] = {}
        for use_id, op_results in grouped.items():
            failures = [r for r in op_results if not r.ok]
            payload: dict[str, Any] = {
                "ok": not failures,
                "operations": len(op_results),
            }
            if len(op_results) == 1:
                single = op_results[0]
                payload["result"] = single.data if single.ok else single.error
            else:
                payload["results"] = [
                    {"ok": r.ok, **({"data": r.data} if r.ok else {"error": r.error})}
                    for r in op_results
                ]
            if failures:
                payload["failed"] = len(failures)

            out[use_id] = {
                "type": "tool_result",
                "tool_use_id": use_id,
                "content": json.dumps(payload, default=str),
                **({"is_error": True} if failures else {}),
            }
        return out


def _error_result(tool_use_id: str, message: str) -> dict[str, Any]:
    return {
        "type": "tool_result",
        "tool_use_id": tool_use_id,
        "content": message,
        "is_error": True,
    }


def _label_for(labels: list[str]) -> str:
    """Undo-stack label for a batch. Shows up in Altium's undo history."""
    unique = list(dict.fromkeys(labels))
    if not unique:
        return "Agent operation"
    if len(unique) == 1:
        return unique[0]
    return f"{unique[0]} and {len(unique) - 1} more"


def _is_fallback_rejection(exc: anthropic.BadRequestError) -> bool:
    text = str(exc).lower()
    return "fallback" in text or "beta" in text
