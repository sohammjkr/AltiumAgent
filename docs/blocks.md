# Reusable circuit blocks

A **block** is a design fragment you draw once and then stamp out repeatedly -
a gate drive, a bias supply, a current-sense front end, an isolated DC/DC. The
point of the feature is that it captures *both halves*:

- the **schematic** half: which components, how they are wired, what is exposed
  to the outside world;
- the **placement** half: where each of those components sits relative to the
  others on the PCB.

Capturing only the schematic half is what Altium snippets already do. The
placement half is the part that actually saves you time, because relative
placement of a gate drive is where the engineering judgement lives - loop area,
the gate resistor next to the pin, the bootstrap cap tight to the driver.

## Block file format

Blocks live in `blocks/<name>.json` and are meant to be read, diffed and
reviewed in a pull request. Example (trimmed) in `blocks/gate_drive_hb.json`.

```json
{
  "name": "gate_drive_hb",
  "version": 1,
  "title": "Half-bridge gate drive (bootstrap)",
  "description": "IR2110-style high/low side driver with bootstrap supply.",
  "parameters": {
    "r_gate": { "default": "10R", "description": "Series gate resistor" },
    "c_boot": { "default": "100n", "description": "Bootstrap capacitor" }
  },
  "interface": [
    { "name": "VCC",  "kind": "power_in" },
    { "name": "PWM_H", "kind": "input" },
    { "name": "GATE_H", "kind": "output" }
  ],
  "schematic": {
    "components": [
      {
        "ref": "U_DRV",
        "library": "MyLib.SchLib",
        "design_item_id": "IR2110",
        "designator_prefix": "U",
        "dx_mm": 0.0, "dy_mm": 0.0, "rotation": 0,
        "parameters": { "Value": "IR2110" }
      },
      {
        "ref": "R_G_H",
        "library": "Miscellaneous Devices.IntLib",
        "design_item_id": "Res3",
        "designator_prefix": "R",
        "dx_mm": 30.0, "dy_mm": -10.0, "rotation": 0,
        "parameters": { "Value": "{r_gate}" }
      }
    ],
    "nets": [
      { "name": "HO",     "scope": "internal", "pins": ["U_DRV.7", "R_G_H.1"] },
      { "name": "GATE_H", "scope": "interface", "pins": ["R_G_H.2"] }
    ],
    "wires": [
      { "points_mm": [[20.0, -10.0], [30.0, -10.0]] }
    ]
  },
  "placement": {
    "anchor": "U_DRV",
    "components": [
      { "ref": "U_DRV", "dx_mm": 0.0,  "dy_mm": 0.0, "rotation": 0,   "side": "top" },
      { "ref": "R_G_H", "dx_mm": 4.20, "dy_mm": -1.80, "rotation": 90, "side": "top" }
    ]
  }
}
```

### The `ref` indirection

Every component carries a block-local `ref` (`U_DRV`, `R_G_H`). That ref is the
key that ties the schematic half to the placement half, and it is what makes
instances independent: instance 1 maps `R_G_H -> R14`, instance 2 maps
`R_G_H -> R27`. Nothing in the block file ever hardcodes a real designator.

Coordinates are `dx_mm`/`dy_mm` **relative to the anchor**, never absolute.
Instantiating at a new anchor is then a translation, and `rotation` / `side` on
the instance rotates or mirrors the whole cluster.

## Workflow

### 1. Draw it once

Design the gate drive normally, in Altium, by hand. Place the footprints the way
you want them. This is the part the agent should not be guessing at.

### 2. Capture

```
you> capture the selected components as a block called gate_drive_hb
```

The agent calls `block.capture_schematic` on your schematic selection and
`block.capture_placement` on your PCB selection. It derives:

- block-local refs from the current designators (`R14 -> R_G_H`, offered for
  you to rename),
- relative offsets from the chosen anchor,
- internal vs interface nets - a net is **interface** if any pin on it belongs
  to a component outside the selection, **internal** otherwise. That inference
  is the useful bit and it is worth sanity-checking the first few times.

The result is written to `blocks/<name>.json`. Review it, fix the ref names,
commit it.

### 3. Instantiate

```
you> place three more gate_drive_hb instances, one per phase, and connect
     PWM_H to the gate driver signals from the controller
```

`block.instantiate` runs as one atomic batch:

1. allocate the next free designators for each ref, recording the map,
2. place the schematic components at `anchor + (dx, dy)`,
3. place wires and net labels, renaming internal nets per instance
   (`HO` -> `HO_U`, `HO_V`, `HO_W`) and leaving interface nets for you or the
   agent to hook up,
4. place the PCB footprints at `anchor + (dx, dy)` with the instance rotation
   and side applied.

The designator map is recorded in `.agent/instances.json` so a later
`block.apply_placement` knows which real components belong to which instance.

### 4. Re-apply placement later

If the schematic instance exists but the footprints are sitting in a pile off
the board edge - the usual state after an ECO - then:

```
you> apply the gate_drive_hb placement to the V-phase instance, anchored at
     (62, 40), rotated 90
```

`block.apply_placement` moves the existing footprints into the captured
relative arrangement. It does not create anything, so it is safe to re-run.

## Rotation and mirroring

Applying instance rotation `theta` about the anchor:

```
dx' =  dx*cos(theta) - dy*sin(theta)
dy' =  dx*sin(theta) + dy*cos(theta)
rot' = (rot + theta) mod 360
```

For `side: "bottom"`, x is mirrored (`dx' = -dx`) and rotation negated before
the above is applied. Altium's own layer mirroring then handles the rest.

`src/altium_agent/blocks.py` implements this and it is the one piece of the
system with real unit tests (`tests/test_blocks.py`) - geometry bugs here are
expensive and silent.

## Relationship to Altium multi-channel design

Altium already has multi-channel design (repeated sheet symbols, room copy,
`Copy Room Formats`). If your repetition is genuinely identical and structural,
use that - it is better integrated with the ECO system than this is.

Blocks are for the other case: repetition that is *similar but not identical*,
parameterised, and spread across projects. A gate drive you want in this board
and the next three boards, with a different FET and a different gate resistor
each time, is a block. Four identical phases of one inverter is a channel.
