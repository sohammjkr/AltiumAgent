"""The daemon: watches the chat queue, runs turns, writes replies back.

This side polls continuously, which is free - it is a separate process and
never touches Altium's UI thread. All the restraint lives on the Altium side.
"""

from __future__ import annotations

import logging
import time
from pathlib import Path

from .agent import DesignAgent, TurnResult
from .bridge import AltiumBridge
from .config import Config
from .protocol import ChatRequest, ChatResponse, read_json, write_atomic

log = logging.getLogger(__name__)


class Daemon:
    def __init__(self, cfg: Config, agent: DesignAgent) -> None:
        self.cfg = cfg
        self.agent = agent
        self._seen: set[str] = set()

    # -- queue ------------------------------------------------------------

    def _pending(self) -> list[Path]:
        requests = sorted(self.cfg.chat_req.glob("t*.json"))
        return [p for p in requests if p.stem not in self._seen and not self._answered(p.stem)]

    def _answered(self, turn: str) -> bool:
        """A turn already carrying a final response survives a daemon restart."""
        path = self.cfg.chat_res / f"{turn}.json"
        if not path.exists():
            return False
        try:
            return bool(read_json(path).get("final"))
        except (ValueError, OSError):
            return False

    def _respond(self, response: ChatResponse) -> None:
        write_atomic(self.cfg.chat_res / f"{response.turn}.json", response.to_dict())

    # -- turn handling ----------------------------------------------------

    def handle(self, path: Path) -> None:
        try:
            request = ChatRequest.from_dict(read_json(path))
        except (ValueError, OSError) as exc:
            log.error("unreadable request %s: %s", path.name, exc)
            self._seen.add(path.stem)
            return

        turn = request.turn or path.stem
        self._seen.add(turn)
        log.info("turn %s: %s", turn, request.text[:120])

        progress = ChatResponse(turn=turn, status="working", text="Working...")
        self._respond(progress)

        def on_progress(kind: str, detail: str) -> None:
            if kind == "text" and detail:
                progress.text = detail
            elif kind == "tool":
                progress.activity.append(detail)
            self._respond(progress)

        started = time.monotonic()
        try:
            result = self.agent.run_turn(
                request.text,
                turn_id=turn,
                context=request.context,
                on_progress=on_progress,
            )
        except Exception as exc:  # noqa: BLE001 - a crash here must still answer the panel
            log.exception("turn %s failed", turn)
            result = TurnResult(
                text=f"The agent hit an unexpected error: {exc}",
                status="error",
                activity=progress.activity,
            )

        elapsed = time.monotonic() - started
        log.info("turn %s finished in %.1fs (%s)", turn, elapsed, result.status)

        self._respond(
            ChatResponse(
                turn=turn,
                final=True,
                status=result.status,
                text=result.text or "(no reply)",
                activity=result.activity,
                usage=result.usage,
            )
        )

    # -- main loop --------------------------------------------------------

    def run(self, *, once: bool = False) -> None:
        self.cfg.ensure_dirs()
        warning = self.cfg.warn_if_synced()
        if warning:
            log.warning(warning)

        log.info("watching %s", self.cfg.chat_req)
        log.info("model=%s effort=%s read_only=%s",
                 self.cfg.model, self.cfg.effort, self.cfg.read_only)

        try:
            while True:
                for path in self._pending():
                    self.handle(path)
                if once:
                    return
                time.sleep(self.cfg.poll_interval_s)
        except KeyboardInterrupt:
            log.info("stopped")


def build_daemon(cfg: Config) -> Daemon:
    bridge = AltiumBridge(cfg)
    agent = DesignAgent(cfg, bridge)
    return Daemon(cfg, agent)
