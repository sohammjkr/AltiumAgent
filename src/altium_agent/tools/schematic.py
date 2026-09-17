"""Schematic capture tools."""

from __future__ import annotations

from .base import (
    POINT_MM,
    READ,
    WRITE,
    X_MM,
    Y_MM,
    ToolSpec,
    array,
    boolean,
    integer,
    obj,
    string,
)

ROTATION = integer(
    "Rotation in degrees counter-clockwise. Schematic components support 0, 90, 180 or 270.",
    enum=[0, 90, 180, 270],
)

PARAMETERS = {
    "type": "object",
    "description": (
        "Component parameters such as Value, Tolerance, Voltage, Manufacturer Part Number. "
        "Keys are parameter names exactly as they should appear in Altium."
    ),
    "additionalProperties": {"type": "string"},
}

SCHEMATIC_TOOLS = [
    ToolSpec(
        name="sch_list_components",
        op="sch.list_components",
        mode=READ,
        description=(
            "List components on a schematic sheet with designator, library reference, "
            "position and parameters. Use this before modifying an existing sheet so you "
            "know what is already there."
        ),
        schema=obj(
            {
                "doc": string(
                    "Schematic filename, e.g. SH1_POWER.SchDoc. Omit for the focused sheet."
                ),
                "designator_filter": string(
                    "Optional prefix filter, e.g. 'R' for resistors only. Empty for all."
                ),
            },
            required=[],
        ),
    ),
    ToolSpec(
        name="sch_list_nets",
        op="sch.list_nets",
        mode=READ,
        description=(
            "List nets on a schematic sheet and the pins connected to each. Use this to "
            "understand existing connectivity before adding to it."
        ),
        schema=obj(
            {"doc": string("Schematic filename. Omit for the focused sheet.")},
            required=[],
        ),
    ),
    ToolSpec(
        name="sch_place_component",
        op="sch.place_component",
        txn_label="Place schematic component",
        description=(
            "Place one component on a schematic sheet from an integrated or schematic "
            "library. The designator must be unique on the sheet - call sch_list_components "
            "first if you are unsure what is taken."
        ),
        schema=obj(
            {
                "library": string(
                    "Library name, e.g. 'Miscellaneous Devices.IntLib' or 'MyParts.SchLib'."
                ),
                "design_item_id": string(
                    "The part's Design Item ID / library reference, e.g. 'Res3', 'Cap Pol1'."
                ),
                "designator": string("Reference designator, e.g. 'R14', 'C7', 'U3'."),
                "x_mm": X_MM,
                "y_mm": Y_MM,
                "rotation": ROTATION,
                "parameters": PARAMETERS,
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            required=["library", "design_item_id", "designator", "x_mm", "y_mm"],
        ),
    ),
    ToolSpec(
        name="sch_place_wire",
        op="sch.place_wire",
        txn_label="Place schematic wire",
        description=(
            "Draw a wire through a series of points. Give at least two points. Wires connect "
            "electrically only where they land exactly on a pin's connection point, so read "
            "pin positions from sch_list_components rather than estimating."
        ),
        schema=obj(
            {
                "points_mm": array(POINT_MM, "Ordered vertices of the wire, at least two."),
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            required=["points_mm"],
        ),
    ),
    ToolSpec(
        name="sch_place_net_label",
        op="sch.place_net_label",
        txn_label="Place net label",
        description=(
            "Place a net label at a point. The label must sit on a wire to name that net. "
            "Prefer net labels over long wires for readability."
        ),
        schema=obj(
            {
                "net_name": string("Net name, e.g. 'VBUS', 'GATE_H', 'PWM_U'."),
                "x_mm": X_MM,
                "y_mm": Y_MM,
                "rotation": ROTATION,
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            required=["net_name", "x_mm", "y_mm"],
        ),
    ),
    ToolSpec(
        name="sch_place_power_port",
        op="sch.place_power_port",
        txn_label="Place power port",
        description=(
            "Place a power or ground port. Power ports of the same name connect globally "
            "across the whole project, so use them for rails rather than wiring them."
        ),
        schema=obj(
            {
                "net_name": string("Rail name, e.g. 'GND', '+12V', 'VBUS'."),
                "style": string(
                    "Port symbol style.",
                    enum=[
                        "circle",
                        "arrow",
                        "bar",
                        "wave",
                        "power_ground",
                        "signal_ground",
                        "earth",
                        "gost_arrow",
                    ],
                ),
                "x_mm": X_MM,
                "y_mm": Y_MM,
                "rotation": ROTATION,
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            required=["net_name", "x_mm", "y_mm"],
        ),
    ),
    ToolSpec(
        name="sch_place_port",
        op="sch.place_port",
        txn_label="Place sheet port",
        description=(
            "Place a hierarchical sheet port, which exposes a net to the parent sheet. "
            "Use for signals crossing a sheet boundary."
        ),
        schema=obj(
            {
                "name": string("Port name, matching the sheet entry on the parent sheet."),
                "io_type": string(
                    "Electrical direction of the port.",
                    enum=["input", "output", "bidirectional", "unspecified"],
                ),
                "x_mm": X_MM,
                "y_mm": Y_MM,
                "width_mm": {"type": "number", "description": "Port width in millimetres."},
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            required=["name", "io_type", "x_mm", "y_mm"],
        ),
    ),
    ToolSpec(
        name="sch_set_parameter",
        op="sch.set_parameter",
        txn_label="Set component parameter",
        description=(
            "Set or add a parameter on an existing schematic component, e.g. change a "
            "resistor's Value or add a Manufacturer Part Number."
        ),
        schema=obj(
            {
                "designator": string("Designator of the component to modify."),
                "name": string("Parameter name, e.g. 'Value', 'Tolerance', 'Comment'."),
                "value": string("Parameter value."),
                "visible": boolean("Whether the parameter is shown on the sheet."),
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            required=["designator", "name", "value"],
        ),
    ),
    ToolSpec(
        name="sch_set_net_name",
        op="sch.set_net_name",
        txn_label="Name net",
        description=(
            "Name the net connecting a set of pins, placing net labels as needed. Pins are "
            "given as DESIGNATOR.PIN, e.g. 'U3.7'. Prefer this over manual label placement "
            "when you know which pins should be common."
        ),
        schema=obj(
            {
                "pins": array(
                    string("A pin reference in DESIGNATOR.PIN form, e.g. 'U3.7'."),
                    "Pins that should share this net.",
                ),
                "net_name": string("Net name to apply."),
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            required=["pins", "net_name"],
        ),
    ),
    ToolSpec(
        name="sch_delete_object",
        op="sch.delete_object",
        txn_label="Delete schematic object",
        description=(
            "Delete a schematic component by designator. Deleting is destructive - say what "
            "you are about to remove and why before calling this."
        ),
        schema=obj(
            {
                "designator": string("Designator of the component to delete."),
                "doc": string("Schematic filename. Omit for the focused sheet."),
            },
            required=["designator"],
        ),
    ),
    ToolSpec(
        name="sch_annotate",
        op="sch.annotate",
        txn_label="Annotate schematic",
        description=(
            "Run Altium's annotation to assign designators to any components left as R?, C? "
            "and so on. Run this after placing several components without explicit designators."
        ),
        schema=obj(
            {
                "scope": string(
                    "What to annotate.",
                    enum=["current_sheet", "whole_project"],
                )
            },
            required=["scope"],
        ),
    ),
]
