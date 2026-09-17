"""Wire types for the Altium bridge. See docs/protocol.md."""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def write_atomic(path: Path, payload: dict[str, Any]) -> None:
    """Write JSON via a temp file + rename.

    Rename is atomic on NTFS, so the reader on the other side never observes a
    partially written file. Without this the bridge intermittently parses half
    a batch, which presents as baffling one-in-twenty failures.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


@dataclass(slots=True)
class Op:
    """A single operation for Altium to perform."""

    id: str
    op: str
    args: dict[str, Any] = field(default_factory=dict)
    doc: str | None = None

    def to_dict(self) -> dict[str, Any]:
        out = {"id": self.id, "op": self.op, "args": self.args}
        if self.doc:
            out["doc"] = self.doc
        return out


@dataclass(slots=True)
class Batch:
    batch: str
    turn: str
    txn_label: str
    ops: list[Op]
    atomic: bool = False
    created: str = field(default_factory=utcnow)

    def to_dict(self) -> dict[str, Any]:
        return {
            "batch": self.batch,
            "turn": self.turn,
            "txn_label": self.txn_label,
            "created": self.created,
            "atomic": self.atomic,
            "ops": [op.to_dict() for op in self.ops],
        }


@dataclass(slots=True)
class OpResult:
    id: str
    ok: bool
    data: dict[str, Any] | None = None
    error: str | None = None

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> OpResult:
        return cls(
            id=str(raw.get("id", "")),
            ok=bool(raw.get("ok", False)),
            data=raw.get("data"),
            error=raw.get("error"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {k: v for k, v in asdict(self).items() if v is not None or k in ("id", "ok")}


@dataclass(slots=True)
class BatchResult:
    batch: str
    ok: bool
    results: list[OpResult]
    elapsed_ms: int = 0
    error: str | None = None

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> BatchResult:
        return cls(
            batch=str(raw.get("batch", "")),
            ok=bool(raw.get("ok", False)),
            results=[OpResult.from_dict(r) for r in raw.get("results", [])],
            elapsed_ms=int(raw.get("elapsed_ms", 0)),
            error=raw.get("error"),
        )

    def by_id(self) -> dict[str, OpResult]:
        return {r.id: r for r in self.results}


@dataclass(slots=True)
class ChatRequest:
    turn: str
    text: str
    context: dict[str, Any] = field(default_factory=dict)
    created: str = field(default_factory=utcnow)

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> ChatRequest:
        return cls(
            turn=str(raw.get("turn", "")),
            text=str(raw.get("text", "")),
            context=raw.get("context") or {},
            created=str(raw.get("created", utcnow())),
        )


@dataclass(slots=True)
class ChatResponse:
    turn: str
    final: bool = False
    status: str = "working"          # working | done | error | refused
    text: str = ""
    activity: list[str] = field(default_factory=list)
    usage: dict[str, int] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class BridgeError(RuntimeError):
    """Altium did not answer, or answered with a transport-level failure."""


class BridgeTimeout(BridgeError):
    """Altium did not pick up or complete a batch in time."""
