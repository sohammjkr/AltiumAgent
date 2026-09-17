"""Reusable circuit blocks: schematic fragment + matching relative placement.

A block is captured once from a design you drew by hand, then stamped out. The
value is in the placement half - relative footprint arrangement is where the
engineering judgement lives (loop area, gate resistor next to the pin, bootstrap
cap tight to the driver), and it is exactly what is tedious to redo by hand.

See docs/blocks.md for the file format and the workflow.
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .protocol import Op, write_atomic

VALID_ROTATIONS = (0, 90, 180, 270)
_PARAM_RE = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")


class BlockError(ValueError):
    """A block definition is malformed, or an instantiation is impossible."""


# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------


def transform(
    dx: float,
    dy: float,
    rotation: float,
    *,
    instance_rotation: float = 0.0,
    side: str = "top",
) -> tuple[float, float, float]:
    """Map a block-relative offset to an instance-relative offset.

    Rotation is counter-clockwise degrees about the block anchor. For a bottom
    side instance the cluster is mirrored in x first, and each part's own
    rotation is negated, which is what Altium's layer flip does to a footprint.

    Returns (dx', dy', rotation') still relative to the anchor; the caller adds
    the anchor's absolute position.
    """
    if side not in ("top", "bottom"):
        raise BlockError(f"side must be 'top' or 'bottom', got {side!r}")

    if side == "bottom":
        dx = -dx
        rotation = -rotation

    theta = math.radians(instance_rotation)
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    out_dx = dx * cos_t - dy * sin_t
    out_dy = dx * sin_t + dy * cos_t
    out_rot = (rotation + instance_rotation) % 360.0

    # Kill float noise so placements land on clean values and diffs stay small.
    return (round(out_dx, 6), round(out_dy, 6), round(out_rot, 6))


def snap_schematic_rotation(rotation: float) -> int:
    """Schematic components only support 0/90/180/270."""
    return int(round(rotation / 90.0) * 90) % 360


# --------------------------------------------------------------------------
# Model
# --------------------------------------------------------------------------


@dataclass(slots=True)
class BlockComponent:
    ref: str
    library: str
    design_item_id: str
    designator_prefix: str = "U"
    dx_mm: float = 0.0
    dy_mm: float = 0.0
    rotation: float = 0.0
    parameters: dict[str, str] = field(default_factory=dict)
    footprint: str | None = None

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> BlockComponent:
        missing = [k for k in ("ref", "library", "design_item_id") if not raw.get(k)]
        if missing:
            raise BlockError(f"Block component missing required field(s): {', '.join(missing)}")
        return cls(
            ref=str(raw["ref"]),
            library=str(raw["library"]),
            design_item_id=str(raw["design_item_id"]),
            designator_prefix=str(raw.get("designator_prefix", "U")),
            dx_mm=float(raw.get("dx_mm", 0.0)),
            dy_mm=float(raw.get("dy_mm", 0.0)),
            rotation=float(raw.get("rotation", 0.0)),
            parameters=dict(raw.get("parameters") or {}),
            footprint=raw.get("footprint"),
        )


@dataclass(slots=True)
class PlacedComponent:
    ref: str
    dx_mm: float = 0.0
    dy_mm: float = 0.0
    rotation: float = 0.0
    side: str = "top"

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> PlacedComponent:
        if not raw.get("ref"):
            raise BlockError("Placement entry missing 'ref'")
        return cls(
            ref=str(raw["ref"]),
            dx_mm=float(raw.get("dx_mm", 0.0)),
            dy_mm=float(raw.get("dy_mm", 0.0)),
            rotation=float(raw.get("rotation", 0.0)),
            side=str(raw.get("side", "top")),
        )


@dataclass(slots=True)
class BlockNet:
    name: str
    pins: list[str] = field(default_factory=list)
    scope: str = "internal"      # internal | interface

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> BlockNet:
        if not raw.get("name"):
            raise BlockError("Block net missing 'name'")
        scope = str(raw.get("scope", "internal"))
        if scope not in ("internal", "interface"):
            raise BlockError(f"Net {raw['name']!r} has invalid scope {scope!r}")
        return cls(name=str(raw["name"]), pins=list(raw.get("pins") or []), scope=scope)


@dataclass(slots=True)
class Block:
    name: str
    title: str = ""
    description: str = ""
    version: int = 1
    parameters: dict[str, dict[str, str]] = field(default_factory=dict)
    interface: list[dict[str, str]] = field(default_factory=list)
    components: list[BlockComponent] = field(default_factory=list)
    nets: list[BlockNet] = field(default_factory=list)
    wires: list[dict[str, Any]] = field(default_factory=list)
    placement_anchor: str | None = None
    placement: list[PlacedComponent] = field(default_factory=list)

    # -- loading ----------------------------------------------------------

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> Block:
        if not raw.get("name"):
            raise BlockError("Block missing 'name'")

        schematic = raw.get("schematic") or {}
        placement = raw.get("placement") or {}

        block = cls(
            name=str(raw["name"]),
            title=str(raw.get("title", "")),
            description=str(raw.get("description", "")),
            version=int(raw.get("version", 1)),
            parameters=dict(raw.get("parameters") or {}),
            interface=list(raw.get("interface") or []),
            components=[BlockComponent.from_dict(c) for c in schematic.get("components", [])],
            nets=[BlockNet.from_dict(n) for n in schematic.get("nets", [])],
            wires=list(schematic.get("wires") or []),
            placement_anchor=placement.get("anchor"),
            placement=[PlacedComponent.from_dict(p) for p in placement.get("components", [])],
        )
        block.validate()
        return block

    @classmethod
    def load(cls, path: Path) -> Block:
        return cls.from_dict(json.loads(path.read_text(encoding="utf-8-sig")))

    def validate(self) -> None:
        refs = [c.ref for c in self.components]
        duplicates = {r for r in refs if refs.count(r) > 1}
        if duplicates:
            raise BlockError(f"Block {self.name}: duplicate refs {sorted(duplicates)}")

        known = set(refs)
        for placed in self.placement:
            if placed.ref not in known:
                raise BlockError(
                    f"Block {self.name}: placement references unknown ref {placed.ref!r}. "
                    f"Known refs: {sorted(known)}"
                )
        if self.placement and self.placement_anchor not in known:
            raise BlockError(
                f"Block {self.name}: placement anchor {self.placement_anchor!r} "
                "is not one of the block's components"
            )
        for net in self.nets:
            for pin in net.pins:
                ref = pin.split(".", 1)[0]
                if ref not in known:
                    raise BlockError(
                        f"Block {self.name}: net {net.name!r} references unknown ref {ref!r}"
                    )

    # -- properties -------------------------------------------------------

    @property
    def has_placement(self) -> bool:
        return bool(self.placement)

    def interface_nets(self) -> list[BlockNet]:
        return [n for n in self.nets if n.scope == "interface"]

    def internal_nets(self) -> list[BlockNet]:
        return [n for n in self.nets if n.scope == "internal"]

    def resolve_parameters(self, overrides: dict[str, str] | None = None) -> dict[str, str]:
        """Merge declared defaults with caller overrides, rejecting unknown keys."""
        overrides = overrides or {}
        unknown = set(overrides) - set(self.parameters)
        if unknown:
            raise BlockError(
                f"Block {self.name} has no parameter(s) {sorted(unknown)}. "
                f"Declared: {sorted(self.parameters)}"
            )
        resolved = {k: str(v.get("default", "")) for k, v in self.parameters.items()}
        resolved.update({k: str(v) for k, v in overrides.items()})
        return resolved

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "version": self.version,
            "title": self.title,
            "description": self.description,
            "parameters": self.parameters,
            "interface": self.interface,
            "schematic": {
                "components": [
                    {
                        "ref": c.ref,
                        "library": c.library,
                        "design_item_id": c.design_item_id,
                        "designator_prefix": c.designator_prefix,
                        "dx_mm": c.dx_mm,
                        "dy_mm": c.dy_mm,
                        "rotation": c.rotation,
                        "parameters": c.parameters,
                        **({"footprint": c.footprint} if c.footprint else {}),
                    }
                    for c in self.components
                ],
                "nets": [{"name": n.name, "scope": n.scope, "pins": n.pins} for n in self.nets],
                "wires": self.wires,
            },
            "placement": {
                "anchor": self.placement_anchor,
                "components": [
                    {
                        "ref": p.ref,
                        "dx_mm": p.dx_mm,
                        "dy_mm": p.dy_mm,
                        "rotation": p.rotation,
                        "side": p.side,
                    }
                    for p in self.placement
                ],
            },
        }

    def save(self, path: Path) -> None:
        write_atomic(path, self.to_dict())


# --------------------------------------------------------------------------
# Library
# --------------------------------------------------------------------------


class BlockLibrary:
    """The on-disk collection of blocks under blocks/."""

    def __init__(self, root: Path) -> None:
        self.root = Path(root)

    def names(self) -> list[str]:
        if not self.root.exists():
            return []
        return sorted(p.stem for p in self.root.glob("*.json"))

    def path_for(self, name: str) -> Path:
        return self.root / f"{name}.json"

    def get(self, name: str) -> Block:
        path = self.path_for(name)
        if not path.exists():
            available = self.names()
            hint = f" Available: {', '.join(available)}" if available else " No blocks defined yet."
            raise BlockError(f"No block named {name!r}.{hint}")
        return Block.load(path)

    def save(self, block: Block) -> Path:
        self.root.mkdir(parents=True, exist_ok=True)
        path = self.path_for(block.name)
        block.save(path)
        return path

    def summaries(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for name in self.names():
            try:
                block = self.get(name)
            except BlockError as exc:
                out.append({"name": name, "error": str(exc)})
                continue
            out.append(
                {
                    "name": block.name,
                    "title": block.title,
                    "components": len(block.components),
                    "has_placement": block.has_placement,
                    "parameters": sorted(block.parameters),
                    "interface": [i.get("name") for i in block.interface],
                }
            )
        return out


# --------------------------------------------------------------------------
# Instantiation
# --------------------------------------------------------------------------


@dataclass(slots=True)
class Instance:
    """One stamped copy of a block, and the map back to real designators."""

    block: str
    instance_id: str
    designators: dict[str, str] = field(default_factory=dict)   # block ref -> real designator
    anchor_mm: tuple[float, float] = (0.0, 0.0)
    rotation: float = 0.0
    side: str = "top"
    net_suffix: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "block": self.block,
            "instance_id": self.instance_id,
            "designators": self.designators,
            "anchor_mm": list(self.anchor_mm),
            "rotation": self.rotation,
            "side": self.side,
            "net_suffix": self.net_suffix,
        }

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> Instance:
        anchor = raw.get("anchor_mm") or [0.0, 0.0]
        return cls(
            block=str(raw.get("block", "")),
            instance_id=str(raw.get("instance_id", "")),
            designators=dict(raw.get("designators") or {}),
            anchor_mm=(float(anchor[0]), float(anchor[1])),
            rotation=float(raw.get("rotation", 0.0)),
            side=str(raw.get("side", "top")),
            net_suffix=str(raw.get("net_suffix", "")),
        )


def substitute(text: str, params: dict[str, str]) -> str:
    """Replace {param} placeholders. Unknown placeholders raise, never blank out."""

    def replace(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in params:
            raise BlockError(f"Unknown parameter placeholder {key!r} in {text!r}")
        return params[key]

    return _PARAM_RE.sub(replace, text)


def _map_pin(pin: str, designators: dict[str, str]) -> str:
    """Rewrite a block-local pin reference (REF.PIN) to a real one (DESIG.PIN)."""
    ref, _, pin_number = pin.partition(".")
    real = designators.get(ref, ref)
    return f"{real}.{pin_number}" if pin_number else real


def build_schematic_ops(
    block: Block,
    instance: Instance,
    *,
    params: dict[str, str],
    anchor_mm: tuple[float, float],
    sheet: str | None = None,
) -> list[Op]:
    """Ops that draw one instance of the block on a schematic sheet."""
    ops: list[Op] = []
    ax, ay = anchor_mm

    for index, comp in enumerate(block.components):
        designator = instance.designators.get(comp.ref)
        if not designator:
            raise BlockError(
                f"No designator allocated for ref {comp.ref!r} in instance {instance.instance_id}"
            )
        # Schematic layout is deliberately NOT rotated or mirrored per instance.
        # A rotated schematic is unreadable; only the PCB half honours instance
        # rotation.
        ops.append(
            Op(
                id=f"sch{index}",
                op="sch.place_component",
                doc=sheet,
                args={
                    "library": comp.library,
                    "design_item_id": comp.design_item_id,
                    "designator": designator,
                    "x_mm": round(ax + comp.dx_mm, 4),
                    "y_mm": round(ay + comp.dy_mm, 4),
                    "rotation": snap_schematic_rotation(comp.rotation),
                    "parameters": {k: substitute(v, params) for k, v in comp.parameters.items()},
                },
            )
        )

    for index, wire in enumerate(block.wires):
        points = [
            [round(ax + float(px), 4), round(ay + float(py), 4)]
            for px, py in wire.get("points_mm", [])
        ]
        if len(points) < 2:
            continue
        ops.append(
            Op(id=f"wire{index}", op="sch.place_wire", doc=sheet, args={"points_mm": points})
        )

    for index, net in enumerate(block.internal_nets()):
        ops.append(
            Op(
                id=f"net{index}",
                op="sch.set_net_name",
                doc=sheet,
                args={
                    "pins": [_map_pin(p, instance.designators) for p in net.pins],
                    "net_name": f"{net.name}{instance.net_suffix}",
                },
            )
        )

    return ops


def build_placement_ops(
    block: Block,
    instance: Instance,
    *,
    anchor_mm: tuple[float, float],
    create: bool = False,
) -> list[Op]:
    """Ops that arrange one instance's footprints on the PCB.

    create=False (the default) only MOVES footprints that already exist, which
    is the normal case after an ECO and is safe to re-run.
    """
    if not block.has_placement:
        raise BlockError(
            f"Block {block.name} has no captured placement. "
            "Place one instance by hand, then use block.capture_placement."
        )

    ops: list[Op] = []
    ax, ay = anchor_mm
    op_name = "pcb.place_component" if create else "pcb.move_component"

    for index, placed in enumerate(block.placement):
        designator = instance.designators.get(placed.ref)
        if not designator:
            raise BlockError(
                f"No designator allocated for ref {placed.ref!r} "
                f"in instance {instance.instance_id}"
            )
        dx, dy, rot = transform(
            placed.dx_mm,
            placed.dy_mm,
            placed.rotation,
            instance_rotation=instance.rotation,
            side=instance.side,
        )
        # A bottom-side instance flips every part in the cluster.
        layer = placed.side
        if instance.side == "bottom":
            layer = "bottom" if placed.side == "top" else "top"

        ops.append(
            Op(
                id=f"pcb{index}",
                op=op_name,
                args={
                    "designator": designator,
                    "x_mm": round(ax + dx, 4),
                    "y_mm": round(ay + dy, 4),
                    "rotation": rot,
                    "layer": layer,
                },
            )
        )

    return ops


class InstanceStore:
    """Persists block instances so apply_placement can find them again later."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)

    def load(self) -> dict[str, Instance]:
        if not self.path.exists():
            return {}
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8-sig"))
        except (ValueError, OSError):
            return {}
        return {k: Instance.from_dict(v) for k, v in raw.items()}

    def save(self, instances: dict[str, Instance]) -> None:
        write_atomic(self.path, {k: v.to_dict() for k, v in instances.items()})

    def add(self, instance: Instance) -> None:
        current = self.load()
        current[instance.instance_id] = instance
        self.save(current)

    def get(self, instance_id: str) -> Instance:
        instances = self.load()
        if instance_id not in instances:
            known = sorted(instances)
            hint = f" Known instances: {', '.join(known)}" if known else " None recorded yet."
            raise BlockError(f"No instance {instance_id!r}.{hint}")
        return instances[instance_id]
