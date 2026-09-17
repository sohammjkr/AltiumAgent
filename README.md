# Altium Agent

Conversational schematic capture and PCB placement, driving Altium Designer
live. You type in a chat window docked next to your design; the agent's changes
appear in the open schematic and board, on Altium's normal undo stack.

> **Status: scaffold complete, not yet run inside Altium.** The Python half is
> built and tested (57 tests passing). The Altium half is written but has never
> been executed in Altium Designer. See [Current state](#current-state) before
> you rely on any of it.

## Scope

**What it does**

- **Schematic capture** - place components from libraries, wire them, add net
  labels and power ports, set parameters, annotate.
- **PCB placement** - move and rotate footprints, set the board origin, lock
  parts, run the ECO from schematic, inspect what is where.
- **Reusable circuit blocks** - draw a gate drive once, then stamp it out.
  A block captures both the schematic fragment *and* the relative footprint
  placement, so the arrangement you worked out by hand comes back every time.
- **Reads the design** - components, positions, net labels, board extents, so
  the agent works from what is actually on screen rather than from your
  description of it.

**What it deliberately does not do**

- **Routing and autorouting.** Scripted routing produces bad boards. The agent
  places; you route.
- **Library part creation.** It places parts that already exist.
- **Direct file manipulation.** `.SchDoc` and `.PcbDoc` are OLE compound
  binaries. Everything goes through Altium's API, because going around it is
  how board files get corrupted.

## The design problem, and the answer

Altium's scripting engine runs **on Altium's UI thread**. A bridge script that
polls continuously - even just checking whether a file exists - makes the
editor feel sticky, permanently. That rules out the obvious architecture.

So the rule this project is built around:

> **The Altium-side poll exists only while a turn is in flight, and the turn
> explicitly ends it.** Between turns, zero script code runs.

Pressing **Send** starts the timer. The final reply stops it. In between, four
things keep the cost low: one batch per assistant turn rather than one per
operation, an adaptive tick interval, a re-entrancy guard, and a watchdog so a
wedged daemon can never leave a timer running in your session.

Full detail in [docs/architecture.md](docs/architecture.md).

```
Altium Designer                          Python daemon
┌──────────────────────┐                ┌──────────────────────┐
│ Agent panel  (chat)  │                │ Agent loop           │
│ Bridge       (burst  │◄── JSON file ──►│ Tool layer           │
│               timer) │     queue      │ Block engine         │
│ SchServer/PCBServer  │                │ Anthropic API        │
└──────────────────────┘                └──────────────────────┘
```

## Current state

### Working and tested (Python)

| Component | State |
|---|---|
| Agent loop, batching, tool dispatch | Built, unit tested |
| Bridge client, atomic queue, timeouts | Built, unit tested |
| Block engine - geometry, validation, designator allocation | Built, 30 tests |
| Tool registry - 32 tools | Built, schema-validated |
| CLI - `doctor`, `probe`, `serve`, `chat`, `blocks`, `tools`, `wake` | Working |

`altium-agent chat --dry-run` exercises the whole agent loop with Altium
simulated, which is most of what you need during development.

### Written but never executed (Altium DelphiScript)

Every file in `altium/src/` is written against the standard Altium scripting
API. That API is stable across mainstream releases, but this machine runs a
**Develop build** and none of this has been run there.

| Op group | Implemented | Stubbed |
|---|---|---|
| `design.*` | status, open_document, save | - |
| `sch.*` | list_components, list_nets*, place_component†, place_wire, place_net_label, place_power_port, set_parameter, delete_object, annotate | set_net_name, place_port |
| `pcb.*` | board_info, list_components, get_component, move_component, lock_component, set_origin, update_from_schematic, run_drc* | place_component, create_room, place_board_outline |
| `block.*` | capture (schematic half) | capture (placement half) |

\* partial - `sch.list_nets` returns net labels only, `pcb.run_drc` dispatches
the check but cannot yet return structured violations.
† `sch.place_component` is the handler most likely to need adjusting; it
reports `symbol_resolved` so a part landing as a placeholder is visible rather
than silent.

### Not started

Preview/approve before applying, real netlist extraction, structured DRC, PCB
placement capture, block versioning. See [docs/roadmap.md](docs/roadmap.md).

## Getting started

### 1. Install

```bash
python -m pip install -e ".[dev]"
```

### 2. Configure

```bash
cp .env.example .env
```

Set `ANTHROPIC_API_KEY` (or run `ant auth login`). Check `ALTIUM_EXE` matches
your install. **Leave `ALTIUM_AGENT_WORKDIR` on a local disk** - a OneDrive or
Dropbox folder will race the queue files; `altium-agent doctor` warns if you
have done this.

```bash
altium-agent doctor
```

### 3. Prove the Altium side before anything else

This is the step that tells you whether the rest of the project stands up.

1. In Altium: **File > Open Project**, select `altium/AltiumAgent.PrjScr`
2. Open `src/Probe.pas`, press **F9**, run `Probe_Main`
3. Then:

```bash
altium-agent probe
```

It checks `TTimer`, file I/O, `SchServer`, `PCBServer`, iterators and unit
conversion. [docs/altium-api.md](docs/altium-api.md) explains what breaks if
each one fails.

### 4. Run it

```bash
altium-agent serve
```

Then in Altium, run `AgentPanel.pas` > `RunAgentPanel`. Ctrl+Enter sends.

To develop without Altium running at all:

```bash
altium-agent chat --dry-run
```

## Reusable blocks

The feature that earns its keep. A block is a circuit you drew once, captured
with **both** halves:

- the **schematic** fragment - components, wiring, which nets are internal and
  which are exposed;
- the **placement** - where each of those parts sits relative to the others on
  the board.

The placement half is the valuable one. Relative footprint arrangement is where
the engineering judgement lives - loop area, the gate resistor next to the pin,
the bootstrap cap tight to the driver - and it is exactly what is tedious to
reproduce by hand for the second, third and fourth phase.

```
you> capture the selected components as a block called gate_drive_hb
you> place three more instances, one per phase, at 62/40, 62/80 and 62/120
you> apply the gate_drive_hb placement to the V-phase instance, rotated 90
```

Blocks are JSON in `blocks/`, designed to be reviewed in a pull request
alongside the design. Format and workflow in
[docs/blocks.md](docs/blocks.md).

Use Altium's own multi-channel design instead when repetition is genuinely
identical and structural. Blocks are for repetition that is similar but
parameterised, and reused across projects.

## Layout

```
altium/           DelphiScript that runs inside Altium
  AltiumAgent.PrjScr    script project - open this in Altium
  src/Probe.pas         capability probe - RUN THIS FIRST
  src/JsonLite.pas      JSON for an engine with no records or classes
  src/Transport.pas     atomic file queue
  src/Bridge.pas        the burst timer - the file that keeps Altium responsive
  src/Ops*.pas          op handlers and dispatch
  src/AgentPanel.*      the chat window
src/altium_agent/ Python: agent loop, tools, bridge client, block engine
blocks/           captured reusable circuits, version controlled
docs/             architecture, wire protocol, Altium API notes, roadmap
tests/            57 tests, no Altium required
```

## Safety

- **One Ctrl+Z per agent action.** Each batch runs in a single undo
  transaction.
- **`--read-only`** refuses every modifying operation at the Python boundary -
  the right mode for letting the agent explore an existing board.
- **Atomic block instantiation.** A half-placed gate drive rolls back; a
  half-placed gate drive is worse than none.
- **Failures are per-op.** One bad operation does not abandon the batch, and
  the model gets told exactly what failed so it can repair it.

The agent is working on real hardware and is prompted to say so - to state its
electrical assumptions, to refuse to invent part numbers, and to flag what you
should check rather than projecting confidence it has not earned.

## Development

```bash
python -m pytest -q          # 57 tests, no Altium needed
altium-agent tools           # the tool surface the model sees
altium-agent tools --json    # full schemas
altium-agent chat --dry-run  # whole loop, Altium simulated
```

The block geometry in `src/altium_agent/blocks.py` is the one piece with heavy
test coverage - a sign error there puts a footprint on the far side of the
board and nothing complains.
