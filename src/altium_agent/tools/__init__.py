"""The agent's tool surface."""

from __future__ import annotations

from .base import READ, WRITE, Registry, ToolContext, ToolSpec
from .blocks_tools import BLOCK_TOOLS
from .design import DESIGN_TOOLS
from .pcb import PCB_TOOLS
from .schematic import SCHEMATIC_TOOLS


def build_registry() -> Registry:
    registry = Registry()
    registry.extend(DESIGN_TOOLS)
    registry.extend(SCHEMATIC_TOOLS)
    registry.extend(PCB_TOOLS)
    registry.extend(BLOCK_TOOLS)
    return registry


__all__ = [
    "READ",
    "WRITE",
    "Registry",
    "ToolContext",
    "ToolSpec",
    "build_registry",
]
