# Wire protocol

Everything between the Python daemon and the in-Altium bridge is JSON files
under `%ALTIUM_AGENT_WORKDIR%`. Both sides write to a `.tmp` file and then
rename it into place - rename is atomic on NTFS, so a reader never sees a
half-written file.

## Directory layout

```
%ALTIUM_AGENT_WORKDIR%\
  state.json           bridge heartbeat + current turn (written by Altium)
  chat\
    req\<turn>.json     panel  -> daemon   user message
    res\<turn>.json     daemon -> panel    assistant reply / progress
  cmd\
    in\<batch>.json     daemon -> Altium   batch of ops
    out\<batch>.json    Altium -> daemon   batch results
  log\
    bridge.log          appended by the Altium side
    daemon.log          appended by Python
```

Ids are monotonic and zero-padded: `t000017`, `b000042`. Sorting the filenames
sorts by time, which is all the ordering guarantee either side needs.

## Command batch (`cmd/in/<batch>.json`)

One file per assistant turn. Every op in it executes inside a single undo
transaction labelled `txn_label`.

```json
{
  "batch": "b000042",
  "turn": "t000017",
  "txn_label": "Place half-bridge gate drive block",
  "created": "2026-09-17T10:31:02.441Z",
  "ops": [
    {
      "id": "op0",
      "op": "sch.place_component",
      "args": {
        "library": "Miscellaneous Devices.IntLib",
        "design_item_id": "Res3",
        "designator": "R14",
        "x_mm": 120.0,
        "y_mm": 85.5,
        "rotation": 0,
        "parameters": { "Value": "10k", "Tolerance": "1%" }
      }
    },
    {
      "id": "op1",
      "op": "sch.place_wire",
      "args": { "points_mm": [[120.0, 85.5], [135.0, 85.5], [135.0, 70.0]] }
    }
  ]
}
```

`doc` may be set on an op to target a specific document; omitted means "the
focused document of the right kind".

## Batch result (`cmd/out/<batch>.json`)

```json
{
  "batch": "b000042",
  "ok": true,
  "elapsed_ms": 412,
  "results": [
    { "id": "op0", "ok": true,  "data": { "handle": "R14", "unique_id": "ABCDEFGH" } },
    { "id": "op1", "ok": false, "error": "No schematic document is open" }
  ]
}
```

**A failed op does not abort the batch.** Remaining ops still run and the model
gets per-op results, so it can repair its own mistake on the next turn rather
than losing the whole batch. `ok` at the top level is the AND of every op.

Set `"atomic": true` on the batch to get the opposite behaviour: first failure
rolls the whole transaction back. The block engine uses this - a half-placed
gate drive is worse than no gate drive.

## Chat request (`chat/req/<turn>.json`)

```json
{
  "turn": "t000017",
  "text": "Add a bootstrap cap across the high-side driver supply",
  "created": "2026-09-17T10:30:58.102Z",
  "context": {
    "focused_doc": "SH1_SERIES_CAPACITORS.SchDoc",
    "project": "DC_BLK_WASHER.PrjPcb",
    "selection": ["U3", "C11"]
  }
}
```

`context` is a cheap hint gathered by the panel at send time so the agent does
not have to burn a tool call discovering what you were looking at.

## Chat response (`chat/res/<turn>.json`)

Rewritten in place as the turn progresses, so the panel can show progress.

```json
{
  "turn": "t000017",
  "final": false,
  "status": "working",
  "text": "Placing the bootstrap cap...",
  "activity": ["sch.place_component C14", "sch.place_wire"],
  "usage": { "input_tokens": 18422, "output_tokens": 512 }
}
```

`status` is one of `working` | `done` | `error` | `refused`. The panel stops its
timer when it reads `"final": true`, whatever the status.

## Bridge state (`state.json`)

Written by the Altium side on every begin/end turn and every batch. The daemon
reads it to know whether Altium is actually alive.

```json
{
  "bridge_version": "0.1.0",
  "altium_build": "...",
  "turn": "t000017",
  "polling": true,
  "last_tick": "2026-09-17T10:31:02.441Z",
  "open_docs": ["DC_BLK_WASHER.PrjPcb", "SH1_SERIES_CAPACITORS.SchDoc"]
}
```

If `last_tick` is older than `turn_timeout_s` while a turn is open, the daemon
reports the bridge as dead rather than hanging forever.

## Units

All coordinates on the wire are **millimetres, floating point**, with schematic
and PCB both using the document's own origin. The bridge converts to Altium
internal coordinates (`MMsToCoord`) at the boundary. No op ever takes raw
Altium `Coord` values - that has been a reliable source of 10,000x placement
errors in every scripting project that allowed it.

Rotation is degrees counter-clockwise, one of 0 / 90 / 180 / 270 for schematic
components, arbitrary float for PCB.
