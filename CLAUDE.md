# Altium Agent - notes for Claude

## The one rule

Altium's scripting engine runs on Altium's UI thread. **The in-Altium poll only
runs while a turn is in flight.** Before changing anything in `altium/src/Bridge.pas`
or the agent's batching, read `docs/architecture.md` - if a change means Altium
polls between turns, or wakes once per tool call instead of once per turn, it is
wrong regardless of how much cleaner it looks.

This is also why `agent.py` uses a manual tool-use loop rather than the SDK's
`tool_runner`: the runner executes tools one at a time, which would wake Altium
once per call.

## Verification status

Everything in `altium/src/` is **written but never executed inside Altium**.
Do not present any of it as working. When touching an op handler, say plainly
that it is unverified, and point at `Probe.pas` / `docs/altium-api.md`.

The Python side is tested and does work: `python -m pytest -q`.

## Conventions

- **Coordinates are millimetres on the wire, always.** Conversion to Altium
  `Coord` happens only in `Ops.pas`. An op that takes raw `Coord` is a bug -
  that is how you get 10,000x placement errors.
- **DelphiScript cannot declare records or classes.** That is why `JsonLite.pas`
  flattens JSON into a `TStringList` of dotted paths rather than building a tree.
- **Every PCB iterator needs `try/finally` with `BoardIterator_Destroy`.** A
  leaked iterator is a handle leak that persists until Altium restarts.
- **Failures are per-op, not per-batch**, except for `atomic` batches (block
  instantiation), where a partial result is worse than none.
- New tools: add the `ToolSpec` under `src/altium_agent/tools/`, the handler in
  the matching `altium/src/Ops*.pas`, and a branch in `OpsDispatch.pas`. Tool
  names use underscores (API restriction); ops use dots.

## Things not to do

- Do not add routing or autorouter control. It is deliberately out of scope -
  see README.
- Do not write `.SchDoc` / `.PcbDoc` directly. They are OLE compound binaries;
  bypassing Altium's API corrupts board files.
- Do not set `strict: true` on a tool whose schema has map-shaped fields.
  `is_closed_schema()` in `tools/base.py` decides this automatically - leave it
  to do its job.

## Commands

```bash
python -m pytest -q             # 57 tests, no Altium needed
altium-agent doctor             # environment check
altium-agent probe              # read the in-Altium capability probe
altium-agent chat --dry-run     # full agent loop, Altium simulated
altium-agent tools --json       # exact schemas the model sees
```
