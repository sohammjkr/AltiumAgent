"""Reusable circuit block tools.

The point of the feature: draw a gate drive once, then stamp it out - schematic
AND relative footprint placement together. See docs/blocks.md.
"""

from __future__ import annotations

import re
from typing import Any

from ..blocks import (
    Block,
    BlockError,
    Instance,
    build_placement_ops,
    build_schematic_ops,
)
from ..protocol import Op
from .base import (
    READ,
    ToolContext,
    ToolSpec,
    array,
    boolean,
    num,
    obj,
    string,
)

_DESIGNATOR_RE = re.compile(r"^([A-Za-z_]+)(\d+)$")


# --------------------------------------------------------------------------
# Designator allocation
# --------------------------------------------------------------------------


def allocate_designators(
    block: Block,
    *,
    start: dict[str, int] | None = None,
    overrides: dict[str, str] | None = None,
) -> dict[str, str]:
    """Assign a real designator to every block ref.

    `start` gives the first free number per prefix ({"R": 14, "C": 7}); refs are
    numbered sequentially from there in block order. `overrides` pins specific
    refs. Anything unresolved is an error rather than a guess - a silently
    wrong designator puts a part in the wrong place on the board.
    """
    start = dict(start or {})
    overrides = dict(overrides or {})

    unknown = set(overrides) - {c.ref for c in block.components}
    if unknown:
        raise BlockError(
            f"Designator overrides name refs not in block {block.name}: {sorted(unknown)}"
        )

    counters = dict(start)
    assigned: dict[str, str] = {}
    used: set[str] = set(overrides.values())

    for comp in block.components:
        if comp.ref in overrides:
            assigned[comp.ref] = overrides[comp.ref]
            continue

        prefix = comp.designator_prefix
        if prefix not in counters:
            raise BlockError(
                f"No starting number given for designator prefix {prefix!r} "
                f"(needed by ref {comp.ref!r}). Call sch_list_components to find the "
                f"next free number, then pass designator_start, e.g. {{\"{prefix}\": 20}}."
            )

        while True:
            candidate = f"{prefix}{counters[prefix]}"
            counters[prefix] += 1
            if candidate not in used:
                break
        assigned[comp.ref] = candidate
        used.add(candidate)

    duplicates = [d for d in assigned.values() if list(assigned.values()).count(d) > 1]
    if duplicates:
        raise BlockError(f"Designator collision within instance: {sorted(set(duplicates))}")

    return assigned


def _instance_from_args(block: Block, args: dict[str, Any], ctx: ToolContext) -> Instance:
    instance_id = str(args.get("instance_id") or "").strip()
    if not instance_id:
        raise BlockError("instance_id is required so the instance can be found again later.")

    designators = allocate_designators(
        block,
        start={k: int(v) for k, v in (args.get("designator_start") or {}).items()},
        overrides=args.get("designators") or {},
    )

    return Instance(
        block=block.name,
        instance_id=instance_id,
        designators=designators,
        anchor_mm=(float(args.get("pcb_x_mm", 0.0)), float(args.get("pcb_y_mm", 0.0))),
        rotation=float(args.get("rotation", 0.0)),
        side=str(args.get("side", "top")),
        net_suffix=str(args.get("net_suffix", "")),
    )


# --------------------------------------------------------------------------
# Local handlers
# --------------------------------------------------------------------------


def _list_blocks(args: dict[str, Any], ctx: ToolContext) -> dict[str, Any]:
    summaries = ctx.blocks.summaries()
    if not summaries:
        return {
            "blocks": [],
            "hint": (
                "No blocks defined yet. Draw a circuit by hand in Altium, select it, "
                "then use block_capture followed by block_save."
            ),
        }
    return {"blocks": summaries}


def _get_block(args: dict[str, Any], ctx: ToolContext) -> dict[str, Any]:
    block = ctx.blocks.get(str(args["name"]))
    return block.to_dict()


def _save_block(args: dict[str, Any], ctx: ToolContext) -> dict[str, Any]:
    definition = dict(args["definition"])
    definition.setdefault("name", args.get("name"))
    block = Block.from_dict(definition)   # validates refs, anchor, nets
    path = ctx.blocks.save(block)
    return {
        "saved": str(path),
        "name": block.name,
        "components": len(block.components),
        "has_placement": block.has_placement,
        "note": "Review and commit this file - blocks are meant to be version controlled.",
    }


def _list_instances(args: dict[str, Any], ctx: ToolContext) -> dict[str, Any]:
    instances = ctx.instances.load()
    return {
        "instances": [
            {
                "instance_id": inst.instance_id,
                "block": inst.block,
                "components": len(inst.designators),
                "anchor_mm": list(inst.anchor_mm),
                "rotation": inst.rotation,
                "side": inst.side,
            }
            for inst in instances.values()
        ]
    }


# --------------------------------------------------------------------------
# Op builders
# --------------------------------------------------------------------------


def _build_instantiate(args: dict[str, Any], ctx: ToolContext) -> list[Op]:
    block = ctx.blocks.get(str(args["block"]))
    params = block.resolve_parameters(args.get("parameters"))
    instance = _instance_from_args(block, args, ctx)

    ops = build_schematic_ops(
        block,
        instance,
        params=params,
        anchor_mm=(float(args["sch_x_mm"]), float(args["sch_y_mm"])),
        sheet=args.get("doc"),
    )

    if args.get("place_on_pcb") and block.has_placement:
        ops.extend(
            build_placement_ops(
                block,
                instance,
                anchor_mm=instance.anchor_mm,
                create=False,
            )
        )

    # Record before submitting: if the batch half-fails we still know which
    # designators were claimed, which is what makes a retry safe.
    ctx.instances.add(instance)
    return ops


def _build_apply_placement(args: dict[str, Any], ctx: ToolContext) -> list[Op]:
    instance = ctx.instances.get(str(args["instance_id"]))
    block = ctx.blocks.get(instance.block)

    if "x_mm" in args and "y_mm" in args:
        instance.anchor_mm = (float(args["x_mm"]), float(args["y_mm"]))
    if "rotation" in args:
        instance.rotation = float(args["rotation"])
    if "side" in args:
        instance.side = str(args["side"])
    ctx.instances.add(instance)

    return build_placement_ops(block, instance, anchor_mm=instance.anchor_mm, create=False)


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------

_MAP_STR = {"type": "object", "additionalProperties": {"type": "string"}}
_MAP_INT = {"type": "object", "additionalProperties": {"type": "integer"}}

BLOCK_TOOLS = [
    ToolSpec(
        name="block_list",
        mode=READ,
        local=_list_blocks,
        description=(
            "List the reusable circuit blocks available, with their component count, "
            "parameters and whether they carry captured PCB placement. Call this when the "
            "user mentions reusing, replicating or stamping out a circuit."
        ),
        schema=obj({}, required=[]),
    ),
    ToolSpec(
        name="block_get",
        mode=READ,
        local=_get_block,
        description=(
            "Read a block's full definition: components, nets, wires and relative placement. "
            "Use this before instantiating so you know which parameters and interface nets "
            "the block exposes."
        ),
        schema=obj({"name": string("Block name, as shown by block_list.")}, required=["name"]),
    ),
    ToolSpec(
        name="block_capture",
        op="block.capture",
        mode=READ,
        description=(
            "Read the current selection out of Altium as a candidate block: components with "
            "positions relative to an anchor, their nets, and - if a PCB is open and the "
            "matching footprints are selected - their relative placement. This only reads. "
            "Propose sensible block-local refs to the user, then call block_save to write it."
        ),
        schema=obj(
            {
                "anchor_designator": string(
                    "Designator to use as the block origin, e.g. the driver IC. "
                    "Omit to use the lower-left component."
                ),
                "include_placement": boolean(
                    "Also capture relative PCB placement from the matching footprints."
                ),
            },
            required=[],
        ),
    ),
    ToolSpec(
        name="block_save",
        local=_save_block,
        description=(
            "Write a block definition to blocks/<name>.json. The definition is validated "
            "first - refs must be unique, the placement anchor must be one of the components, "
            "and nets may only reference known refs. Show the user the refs you chose before "
            "saving, since those names are how they will refer to the block later."
        ),
        schema={
            "type": "object",
            "properties": {
                "name": string("Block name, lower_snake_case, e.g. 'gate_drive_hb'."),
                "definition": {
                    "type": "object",
                    "description": (
                        "The full block definition following the schema in docs/blocks.md: "
                        "name, title, description, parameters, interface, "
                        "schematic {components, nets, wires} and placement {anchor, components}."
                    ),
                },
            },
            "required": ["name", "definition"],
        },
    ),
    ToolSpec(
        name="block_instantiate",
        build=_build_instantiate,
        txn_label="Instantiate block",
        description=(
            "Stamp out one instance of a block: place its components on the schematic at the "
            "given anchor, wire them, name its internal nets with the instance suffix, and "
            "optionally arrange the matching footprints on the PCB. "
            "Call sch_list_components first to find the next free designator per prefix and "
            "pass those in designator_start - otherwise this fails rather than guessing. "
            "Interface nets are left unconnected for you to hook up afterwards."
        ),
        schema={
            "type": "object",
            "properties": {
                "block": string("Block name, as shown by block_list."),
                "instance_id": string(
                    "Unique id for this instance, e.g. 'gate_drive_U'. Used later by "
                    "block_apply_placement."
                ),
                "sch_x_mm": num("Schematic anchor X in millimetres."),
                "sch_y_mm": num("Schematic anchor Y in millimetres."),
                "designator_start": {
                    **_MAP_INT,
                    "description": (
                        "First free designator number per prefix, e.g. {\"R\": 14, \"C\": 7, "
                        "\"U\": 3}. Every prefix the block uses must be present."
                    ),
                },
                "designators": {
                    **_MAP_STR,
                    "description": (
                        "Optional explicit designator per block ref, e.g. {\"U_DRV\": \"U7\"}. "
                        "Overrides designator_start for those refs."
                    ),
                },
                "parameters": {
                    **_MAP_STR,
                    "description": (
                        "Values for the block's declared parameters, e.g. {\"r_gate\": \"22R\"}. "
                        "Omitted parameters use their defaults."
                    ),
                },
                "net_suffix": string(
                    "Suffix appended to internal net names to keep instances distinct, "
                    "e.g. '_U' giving 'HO_U'."
                ),
                "place_on_pcb": boolean(
                    "Also arrange the footprints on the PCB using the block's captured "
                    "placement. Requires the footprints to exist already - run "
                    "pcb_update_from_schematic first if they do not."
                ),
                "pcb_x_mm": num("PCB anchor X in millimetres. Required if place_on_pcb."),
                "pcb_y_mm": num("PCB anchor Y in millimetres. Required if place_on_pcb."),
                "rotation": num("Rotation of the whole PCB cluster, degrees counter-clockwise."),
                "side": string("Board side for the cluster.", enum=["top", "bottom"]),
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            "required": ["block", "instance_id", "sch_x_mm", "sch_y_mm"],
        },
    ),
    ToolSpec(
        name="block_apply_placement",
        build=_build_apply_placement,
        txn_label="Apply block placement",
        description=(
            "Move an existing instance's footprints into the block's captured relative "
            "arrangement, anchored at a new position. This only moves parts that already "
            "exist, so it is safe to re-run - the usual fix after an ECO dumps footprints "
            "in a pile off the board edge."
        ),
        schema=obj(
            {
                "instance_id": string("Instance id, as passed to block_instantiate."),
                "x_mm": num("New PCB anchor X in millimetres."),
                "y_mm": num("New PCB anchor Y in millimetres."),
                "rotation": num("Rotation of the whole cluster, degrees counter-clockwise."),
                "side": string("Board side for the cluster.", enum=["top", "bottom"]),
            },
            required=["instance_id", "x_mm", "y_mm"],
        ),
    ),
    ToolSpec(
        name="block_list_instances",
        mode=READ,
        local=_list_instances,
        description=(
            "List block instances already stamped out in this design, with their designator "
            "counts and anchors. Use this to find an instance_id for block_apply_placement."
        ),
        schema=obj({}, required=[]),
    ),
]
