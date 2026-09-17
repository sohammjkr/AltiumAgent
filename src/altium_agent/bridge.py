"""Client side of the Altium bridge: submit a batch, wait for its result.

The design constraint this file exists to serve: Altium's scripting engine runs
on the UI thread, so the in-Altium side must do as little work as possible and
must not poll when no turn is in flight. Consequently ALL batching happens here
- one file per assistant turn, never one per tool call. See docs/architecture.md.
"""

from __future__ import annotations

import itertools
import logging
import time
from pathlib import Path
from typing import Any

from .config import Config
from .protocol import (
    Batch,
    BatchResult,
    BridgeError,
    BridgeTimeout,
    Op,
    OpResult,
    read_json,
    write_atomic,
)

log = logging.getLogger(__name__)


class AltiumBridge:
    """Submits op batches to Altium and collects results."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.cfg.ensure_dirs()
        self._counter = itertools.count(self._next_batch_index())

    # -- ids ---------------------------------------------------------------

    def _next_batch_index(self) -> int:
        """Resume numbering after a restart so ids stay monotonic on disk."""
        existing = sorted(self.cfg.cmd_in.glob("b*.json"))
        if not existing:
            return 1
        try:
            return int(existing[-1].stem.lstrip("b")) + 1
        except ValueError:
            return 1

    def _new_batch_id(self) -> str:
        return f"b{next(self._counter):06d}"

    # -- state -------------------------------------------------------------

    def read_state(self) -> dict[str, Any]:
        if not self.cfg.state_file.exists():
            return {}
        try:
            return read_json(self.cfg.state_file)
        except (ValueError, OSError):
            return {}

    def is_alive(self) -> bool:
        """True if the in-Altium bridge has ticked recently enough to trust."""
        state = self.read_state()
        return bool(state.get("polling")) or bool(state.get("last_tick"))

    # -- submission --------------------------------------------------------

    def submit(
        self,
        ops: list[Op],
        *,
        turn: str,
        txn_label: str,
        atomic: bool = False,
        wake: bool = False,
    ) -> BatchResult:
        """Send one batch and block until Altium answers.

        atomic=True makes the whole batch roll back on the first failure - used
        for block instantiation, where a half-placed circuit is worse than none.
        Otherwise a failed op is reported per-op and the rest still run, so the
        model can repair its own mistake on the next turn.
        """
        if not ops:
            return BatchResult(batch="", ok=True, results=[])

        if len(ops) > self.cfg.max_batch_ops:
            raise BridgeError(
                f"Batch of {len(ops)} ops exceeds max_batch_ops={self.cfg.max_batch_ops}. "
                "Large batches block the Altium UI thread for too long."
            )

        batch_id = self._new_batch_id()
        batch = Batch(
            batch=batch_id,
            turn=turn,
            txn_label=txn_label[:120],
            ops=ops,
            atomic=atomic,
        )

        in_path = self.cfg.cmd_in / f"{batch_id}.json"
        out_path = self.cfg.cmd_out / f"{batch_id}.json"
        out_path.unlink(missing_ok=True)

        write_atomic(in_path, batch.to_dict())
        log.info("batch %s submitted: %d ops (%s)", batch_id, len(ops), txn_label)

        if wake:
            from .wake import wake_altium

            dispatched, message = wake_altium(self.cfg.altium_exe)
            if not dispatched:
                log.warning("headless wake failed: %s", message)

        return self._await_result(batch_id, out_path, len(ops))

    def _await_result(self, batch_id: str, out_path: Path, op_count: int) -> BatchResult:
        deadline = time.monotonic() + self.cfg.batch_timeout_s
        while time.monotonic() < deadline:
            if out_path.exists():
                # The writer renames into place atomically, but give a failed
                # parse one retry in case of an exotic filesystem interleaving.
                for attempt in range(2):
                    try:
                        return BatchResult.from_dict(read_json(out_path))
                    except ValueError:
                        if attempt:
                            raise BridgeError(f"Batch {batch_id} result is not valid JSON")
                        time.sleep(0.05)
            time.sleep(self.cfg.poll_interval_s)

        raise BridgeTimeout(
            f"Altium did not complete batch {batch_id} ({op_count} ops) within "
            f"{self.cfg.batch_timeout_s}s. Is the agent panel open and is the "
            "bridge polling? Check state.json."
        )

    # -- convenience -------------------------------------------------------

    def run_one(self, op_name: str, args: dict[str, Any], *, turn: str = "t000000") -> OpResult:
        """Run a single op. Convenience for the CLI and tests, not the agent loop."""
        result = self.submit(
            [Op(id="op0", op=op_name, args=args)],
            turn=turn,
            txn_label=op_name,
        )
        if not result.results:
            raise BridgeError(f"Altium returned no result for {op_name}")
        return result.results[0]


class FakeBridge(AltiumBridge):
    """Records batches and replays canned results. Used by tests and --dry-run.

    Lets the whole agent loop, tool registry and block engine be exercised with
    no Altium running, which is most of what you want during development.
    """

    def __init__(self, cfg: Config, responses: dict[str, Any] | None = None) -> None:
        super().__init__(cfg)
        self.submitted: list[Batch] = []
        self.responses = responses or {}

    def submit(
        self,
        ops: list[Op],
        *,
        turn: str,
        txn_label: str,
        atomic: bool = False,
        wake: bool = False,
    ) -> BatchResult:
        batch_id = self._new_batch_id()
        self.submitted.append(
            Batch(batch=batch_id, turn=turn, txn_label=txn_label, ops=ops, atomic=atomic)
        )
        results = [
            OpResult(
                id=op.id,
                ok=True,
                data=self.responses.get(op.op, {"simulated": True, "op": op.op}),
            )
            for op in ops
        ]
        return BatchResult(batch=batch_id, ok=True, results=results, elapsed_ms=0)
