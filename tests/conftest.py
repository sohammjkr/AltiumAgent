from __future__ import annotations

from pathlib import Path

import pytest

from altium_agent.blocks import Block, BlockLibrary
from altium_agent.config import Config

REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def example_block() -> Block:
    """The shipped gate drive example, which doubles as a format regression test."""
    return BlockLibrary(REPO_ROOT / "blocks").get("gate_drive_hb")


@pytest.fixture
def cfg(tmp_path: Path) -> Config:
    """Config pointed entirely at a temp dir, so tests never touch a real queue."""
    config = Config()
    config.workdir = tmp_path / "bridge"
    config.blocks_dir = REPO_ROOT / "blocks"
    config.batch_timeout_s = 2
    config.poll_interval_s = 0.01
    config.ensure_dirs()
    return config
