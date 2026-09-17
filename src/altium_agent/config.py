"""Configuration, loaded from environment / .env with sane Windows defaults."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

DEFAULT_ALTIUM_EXE = r"C:\Program Files\Altium\ADDevelop\X2.EXE"
DEFAULT_WORKDIR = r"C:\ProgramData\AltiumAgent\bridge"


def _env(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


@dataclass(slots=True)
class Config:
    # --- model ---
    model: str = field(default_factory=lambda: _env("ALTIUM_AGENT_MODEL", "claude-opus-5"))
    effort: str = field(default_factory=lambda: _env("ALTIUM_AGENT_EFFORT", "high"))
    max_tokens: int = field(default_factory=lambda: _env_int("ALTIUM_AGENT_MAX_TOKENS", 32000))

    # Server-side refusal fallback. Harmless for PCB work but costs nothing to
    # have on; disabled automatically if the account lacks the beta.
    refusal_fallback: bool = True

    # --- transport ---
    workdir: Path = field(
        default_factory=lambda: Path(_env("ALTIUM_AGENT_WORKDIR", DEFAULT_WORKDIR))
    )
    altium_exe: Path = field(
        default_factory=lambda: Path(_env("ALTIUM_EXE", DEFAULT_ALTIUM_EXE))
    )

    # --- timing ---
    poll_interval_s: float = 0.08      # daemon side; costs Altium nothing
    batch_timeout_s: int = 120         # how long to wait for Altium to run one batch
    turn_timeout_s: int = 180          # matches the bridge watchdog

    # --- safety ---
    read_only: bool = False
    max_batch_ops: int = 64            # keep a single UI-thread block short
    max_turns: int = 40                # agent loop iteration cap

    # --- project ---
    blocks_dir: Path = field(default_factory=lambda: Path("blocks"))

    def __post_init__(self) -> None:
        self.workdir = Path(self.workdir).expanduser()
        self.blocks_dir = Path(self.blocks_dir).expanduser()

    # Queue subdirectories -------------------------------------------------
    @property
    def chat_req(self) -> Path:
        return self.workdir / "chat" / "req"

    @property
    def chat_res(self) -> Path:
        return self.workdir / "chat" / "res"

    @property
    def cmd_in(self) -> Path:
        return self.workdir / "cmd" / "in"

    @property
    def cmd_out(self) -> Path:
        return self.workdir / "cmd" / "out"

    @property
    def log_dir(self) -> Path:
        return self.workdir / "log"

    @property
    def state_file(self) -> Path:
        return self.workdir / "state.json"

    @property
    def instances_file(self) -> Path:
        return self.workdir / "instances.json"

    def ensure_dirs(self) -> None:
        for path in (self.chat_req, self.chat_res, self.cmd_in, self.cmd_out, self.log_dir):
            path.mkdir(parents=True, exist_ok=True)

    def warn_if_synced(self) -> str | None:
        """OneDrive sync racing the queue is a real and confusing failure mode."""
        parts = {p.lower() for p in self.workdir.parts}
        for marker in ("onedrive", "dropbox", "google drive"):
            if any(marker in p for p in parts):
                return (
                    f"Bridge workdir {self.workdir} looks like a synced folder. "
                    "File sync will race the command queue. Set ALTIUM_AGENT_WORKDIR "
                    f"to a local path such as {DEFAULT_WORKDIR}."
                )
        return None


def load_config(**overrides: object) -> Config:
    cfg = Config()
    for key, value in overrides.items():
        if value is not None and hasattr(cfg, key):
            setattr(cfg, key, value)
    return cfg
