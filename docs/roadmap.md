# Roadmap

Ordered by what unblocks the most. Everything in Milestone 1 is a
prerequisite for trusting anything else.

## Milestone 1 - prove the bridge (next)

Nothing in `altium/src/` has been executed inside Altium yet. Until it has,
treat every op handler as a hypothesis.

- [ ] Run `Probe.pas` in Altium, then `altium-agent probe`. Fix whatever fails.
- [ ] Get `design.status` to round-trip: daemon -> batch -> handler -> result.
- [ ] Get `AgentPanel` open as a modeless window and confirm the timer starts
      on Send and stops on the final reply (watch `state.json`).
- [ ] Place one resistor end to end from a chat message.
- [ ] Confirm one Ctrl+Z undoes a whole batch, not one op.
- [ ] Measure the actual editor lag while a turn is in flight. Tune
      `BR_TICK_FAST_MS` / `BR_TICK_SLOW_MS` against what you feel, not what
      seems reasonable in the abstract.

The last one is the real acceptance test for this whole design.

## Milestone 2 - finish the op handlers

Stubs that currently return "not implemented", roughly in value order:

- [ ] `pcb.create_room` - rooms are the natural container for a block
      instance, and cheap to add
- [ ] `pcb.place_board_outline` - needed before any greenfield layout
- [ ] `pcb.place_component` - mounting holes, fiducials, mechanical parts
- [ ] `sch.place_port` - hierarchical sheets
- [ ] `sch.set_net_name` - needs pin coordinate lookup so labels land on the
      right wires. The agent currently works around it with
      `sch_place_net_label`.

## Milestone 3 - make the design readable to the agent

Right now the agent can see components but not real connectivity, which caps
how much it can reason about a circuit.

- [ ] Real netlist extraction from the compiled project, not just net labels
- [ ] Structured DRC results instead of "look in the Messages panel"
- [ ] Pin-level geometry in `sch.list_components`, so wires can be drawn to
      pins instead of estimated coordinates
- [ ] Schematic-to-PCB component mapping by `UniqueId`, exposed as a tool

## Milestone 4 - finish the block system

The schematic half of capture works. The valuable half does not yet.

- [ ] `block.capture` placement half: read the selected footprints' relative
      positions, match them to schematic components by `UniqueId`
- [ ] Report which components matched by unique id versus by designator -
      silently placing the wrong part is this tool's worst failure mode
- [ ] Round-trip test: capture a real gate drive, re-instantiate it, diff the
      placement against the original
- [ ] Block versioning, so an instance records which block version produced it
- [ ] Update an existing instance when its block definition changes

## Milestone 5 - quality of life

- [ ] Preview mode: show the engineer what the agent is about to do, with an
      approve/reject step, before it touches the design
- [ ] Undo one agent turn by id, rather than counting Ctrl+Z presses
- [ ] Conversation persistence across Altium restarts
- [ ] Cost and token display in the panel
- [ ] Multi-sheet awareness - the agent currently assumes one focused sheet

## Not planned

- **Autorouting.** Scripted routing produces bad boards. The agent sets up
  rules and placement; you route.
- **Library part creation.** Editing `.SchLib` / `.PcbLib` programmatically is
  a different project with different failure modes.
- **Anything that writes `.SchDoc` / `.PcbDoc` directly.** They are OLE
  compound binaries; going around Altium's API to write them is how you
  corrupt a board file.

## Open questions

- Does the headless `X2.EXE -RScriptingSystem:RunScript` wake dispatch into a
  running instance on this build? If not, the panel is the only entry point -
  which is fine interactively, but rules out CI.
- Does a modeless script form survive the launching procedure returning on
  this build? If not, the UI has to become a compiled extension.
- How badly does a 500 ms timer actually affect editor feel during a long
  turn? If the answer is "not at all", the adaptive interval logic is
  unnecessary complexity and should be deleted.
