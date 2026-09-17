"""PCB placement tools.

Placement only. Routing and autorouting are deliberately out of scope for v1 -
see docs/altium-api.md for why.
"""

from __future__ import annotations

from .base import (
    POINT_MM,
    READ,
    X_MM,
    Y_MM,
    ToolSpec,
    array,
    boolean,
    num,
    obj,
    string,
)

LAYER = string("Board side the component sits on.", enum=["top", "bottom"])
PCB_ROTATION = num("Rotation in degrees counter-clockwise. Any angle is allowed on the PCB.")

PCB_TOOLS = [
    ToolSpec(
        name="pcb_board_info",
        op="pcb.board_info",
        mode=READ,
        description=(
            "Get board-level information: filename, units, origin, board outline extents, "
            "layer stack and component count. Call this before any placement work so your "
            "coordinates land on the board."
        ),
        schema=obj({}, required=[]),
    ),
    ToolSpec(
        name="pcb_list_components",
        op="pcb.list_components",
        mode=READ,
        description=(
            "List PCB components with designator, footprint, position, rotation, layer and "
            "whether they are locked or still unplaced. Components dumped off the board edge "
            "after an ECO show up here with positions outside the outline."
        ),
        schema=obj(
            {
                "designator_filter": string(
                    "Optional prefix filter, e.g. 'Q' for transistors. Empty for all."
                ),
                "unplaced_only": boolean(
                    "Only return components sitting outside the board outline."
                ),
            },
            required=[],
        ),
    ),
    ToolSpec(
        name="pcb_get_component",
        op="pcb.get_component",
        mode=READ,
        description=(
            "Get full detail for one PCB component including pad positions and courtyard "
            "extents. Use this when you need to place something relative to a specific part."
        ),
        schema=obj(
            {"designator": string("Designator of the component to inspect.")},
            required=["designator"],
        ),
    ),
    ToolSpec(
        name="pcb_move_component",
        op="pcb.move_component",
        txn_label="Move PCB component",
        description=(
            "Move an existing PCB component to a position, rotation and layer. This is the "
            "main placement tool - components normally already exist from the schematic via "
            "an ECO, so move rather than place them."
        ),
        schema=obj(
            {
                "designator": string("Designator of the component to move."),
                "x_mm": X_MM,
                "y_mm": Y_MM,
                "rotation": PCB_ROTATION,
                "layer": LAYER,
            },
            required=["designator", "x_mm", "y_mm"],
        ),
    ),
    ToolSpec(
        name="pcb_place_component",
        op="pcb.place_component",
        txn_label="Place PCB component",
        description=(
            "Place a NEW footprint on the board that does not come from the schematic - "
            "mounting holes, fiducials, mechanical parts. For anything on the schematic, "
            "run pcb_update_from_schematic and then pcb_move_component instead."
        ),
        schema=obj(
            {
                "library": string("PCB library name, e.g. 'MyFootprints.PcbLib'."),
                "footprint": string("Footprint name, e.g. 'MOUNT_M3', '0805'."),
                "designator": string("Designator for the new component."),
                "x_mm": X_MM,
                "y_mm": Y_MM,
                "rotation": PCB_ROTATION,
                "layer": LAYER,
            },
            required=["library", "footprint", "designator", "x_mm", "y_mm"],
        ),
    ),
    ToolSpec(
        name="pcb_lock_component",
        op="pcb.lock_component",
        txn_label="Lock PCB component",
        description=(
            "Lock or unlock a component so it cannot be moved accidentally. Lock connectors "
            "and mechanically constrained parts once they are positioned."
        ),
        schema=obj(
            {
                "designator": string("Designator of the component."),
                "locked": boolean("True to lock, false to unlock."),
            },
            required=["designator", "locked"],
        ),
    ),
    ToolSpec(
        name="pcb_set_origin",
        op="pcb.set_origin",
        txn_label="Set board origin",
        description=(
            "Set the board's relative origin. Do this once before coordinate-driven "
            "placement so your millimetre values are meaningful."
        ),
        schema=obj({"x_mm": X_MM, "y_mm": Y_MM}, required=["x_mm", "y_mm"]),
    ),
    ToolSpec(
        name="pcb_create_room",
        op="pcb.create_room",
        txn_label="Create PCB room",
        description=(
            "Create a rectangular room and optionally assign components to it. Rooms are the "
            "natural container for a block instance - one room per gate drive keeps the "
            "cluster together when you move things around later."
        ),
        schema=obj(
            {
                "name": string("Room name, e.g. 'GATE_DRIVE_U'."),
                "x1_mm": num("Left edge in millimetres."),
                "y1_mm": num("Bottom edge in millimetres."),
                "x2_mm": num("Right edge in millimetres."),
                "y2_mm": num("Top edge in millimetres."),
                "layer": LAYER,
                "designators": array(
                    string("A component designator."),
                    "Components to assign to this room. May be empty.",
                ),
            },
            required=["name", "x1_mm", "y1_mm", "x2_mm", "y2_mm"],
        ),
    ),
    ToolSpec(
        name="pcb_place_board_outline",
        op="pcb.place_board_outline",
        txn_label="Define board outline",
        description=(
            "Define the board outline from a closed polygon of points, and redefine the "
            "board shape from it. Give the points in order; the shape is closed automatically."
        ),
        schema=obj(
            {
                "points_mm": array(POINT_MM, "Ordered outline vertices, at least three."),
                "corner_radius_mm": num("Corner radius in millimetres. Use 0 for sharp corners."),
            },
            required=["points_mm"],
        ),
    ),
    ToolSpec(
        name="pcb_update_from_schematic",
        op="pcb.update_from_schematic",
        txn_label="Update PCB from schematic",
        description=(
            "Run Altium's Update PCB Document ECO, bringing schematic changes onto the board. "
            "Run this after schematic edits and before trying to place the new footprints. "
            "Report what the ECO changed."
        ),
        schema=obj(
            {
                "dry_run": boolean(
                    "If true, report the changes the ECO would make without applying them."
                )
            },
            required=[],
        ),
    ),
    ToolSpec(
        name="pcb_run_drc",
        op="pcb.run_drc",
        mode=READ,
        description=(
            "Run the design rule check and return violations grouped by rule. Use this to "
            "verify placement work - overlapping courtyards and off-board components show "
            "up here."
        ),
        schema=obj(
            {
                "max_violations": {
                    "type": "integer",
                    "description": "Cap on violations returned, to keep the result readable.",
                }
            },
            required=[],
        ),
    ),
]
