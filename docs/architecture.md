# Altium Agent - Architecture

## The problem this design is built around

Altium's scripting engine runs **on Altium's main UI thread**. Anything a script
does - including a `TTimer` tick that checks whether a file exists - competes
with the thing you are actually trying to do in the editor. A bridge script that
polls continuously at 100 ms makes Altium feel sticky, permanently.

So the central rule of this architecture is:

> **The Altium-side poll exists only while a turn is in flight, and the turn
> explicitly ends it.** Between turns, zero script code runs.

Everything below follows from that.

## The three processes

```
┌───────────────────────────────┐     ┌────────────────────────────┐
│  Altium Designer (X2.EXE)     │     │  Python daemon             │
│                               │     │  (altium-agent serve)      │
│  ┌─────────────────────────┐  │     │                            │
│  │ Agent panel             │  │     │  ┌──────────────────────┐  │
│  │ (modeless ScriptForm)   │  │     │  │ Agent loop           │  │
│  └───────────┬─────────────┘  │     │  │ (Messages API,       │  │
│              │                │     │  │  claude-opus-5)      │  │
│  ┌───────────▼─────────────┐  │     │  └──────────┬───────────┘  │
│  │ Bridge (burst timer)    │  │     │             │              │
│  │  - drains ONE batch     │  │     │  ┌──────────▼───────────┐  │
│  │  - one undo transaction │  │     │  │ Tool layer           │  │
│  │  - stops when turn ends │  │     │  │ sch. / pcb. / block. │  │
│  └───────────┬─────────────┘  │     │  └──────────┬───────────┘  │
│              │                │     │             │              │
│  ┌───────────▼─────────────┐  │     │             │              │
│  │ SchServer / PCBServer   │  │     │             │              │
│  └─────────────────────────┘  │     │             │              │
└──────────────┬────────────────┘     └─────────────┬──────────────┘
               │                                    │
               └────────────► file queue ◄──────────┘
                          %ALTIUM_AGENT_WORKDIR%
```

Transport is **plain JSON files on a local disk**. Not a socket, not COM, not a
named pipe. Reasons:

- DelphiScript file I/O is the one primitive guaranteed to exist in every
  Altium build. HTTP via `CreateOleObject` may or may not be available in this
  Develop build - see `docs/altium-api.md`.
- No admin rights, no firewall prompt, no port conflict with Altium's own
  services.
- The queue is inspectable. When something misbehaves you `cat` the last batch
  file and see exactly what the agent asked Altium to do.
- It survives an Altium crash: the queue is still on disk.

The cost is latency (a file write plus a poll interval, so ~100-200 ms per
round trip). That is irrelevant next to the model's own thinking time.

## Turn lifecycle

This is the part that satisfies the no-lag constraint. Read it carefully.

| # | Actor | Action |
|---|-------|--------|
| 1 | You | Type in the agent panel, press **Send** |
| 2 | Panel | Writes `chat/req/<turn>.json`, calls `Bridge_BeginTurn` -> **timer starts** |
| 3 | Daemon | Sees the request (it polls continuously; this costs Altium nothing) |
| 4 | Daemon | Runs the model. Model emits N tool calls in one assistant turn |
| 5 | Daemon | Writes **one** batch file `cmd/in/<batch>.json` containing all N calls |
| 6 | Bridge | Timer tick sees the batch, **disables its own timer**, executes all N ops inside a single undo transaction, writes `cmd/out/<batch>.json`, re-enables |
| 7 | - | Steps 4-6 repeat until the model stops calling tools |
| 8 | Daemon | Writes `chat/res/<turn>.json` with `"final": true` |
| 9 | Panel | Renders the reply, calls `Bridge_EndTurn` -> **timer stops** |

Between step 9 and the next step 1, **no script code runs at all**. Altium is
exactly as responsive as it is with the agent uninstalled.

### Four things that keep the in-flight cost low too

1. **Batch per assistant turn, not per tool call.** Placing a 24-component gate
   drive block is one wake, not 24. This is by far the biggest lever.
2. **Adaptive interval.** The timer ticks at 80 ms right after a batch completes
   (the model is likely to come straight back with another batch), and backs off
   toward 500 ms while waiting on model thinking time. Configured by
   `tick_fast_ms` / `tick_slow_ms` / `backoff_after_ms`.
3. **Re-entrancy guard.** The timer disables itself for the duration of a batch.
   Altium will happily re-enter a timer handler during a long operation
   otherwise, and you get overlapping transactions and a corrupt undo stack.
4. **Idle watchdog.** If no batch arrives within `turn_timeout_s` (default 180),
   the bridge stops its own timer and marks the turn failed. A wedged daemon can
   never leave a timer running in your Altium session.

### Headless wake (no panel open)

For scripted or CI use there is a second entry point: the daemon shells out to

```
X2.EXE -RScriptingSystem:RunScript(ProjectName="...\AltiumAgent.PrjScr"|ProcedureName="DrainOnce")
```

`DrainOnce` processes whatever is queued and returns - it never starts a timer.
Altium is single-instance, so this dispatches to the already-running process.
**This behaviour is unverified on this build** - see `docs/altium-api.md`.

## Why a manual agent loop instead of the SDK tool runner

The SDK's `client.beta.messages.tool_runner` executes tool functions one at a
time. That would produce one Altium wake per tool call and defeat the batching
above. The loop in `agent.py` collects every `tool_use` block from an assistant
turn, ships them as **one** batch, and returns all `tool_result` blocks in a
single user message (which is also what the API expects - splitting them across
messages trains the model out of parallel calls).

## Undo and safety

Every batch runs inside one `PCBServer.PreProcess` / `PostProcess` (or
`SchServer` `SCHM_BeginModify` / `SCHM_EndModify`) pair, labelled with the
batch's `txn_label`. In practice that means **one Ctrl+Z undoes one agent
action**, which is the behaviour you want when the agent does something you did
not intend.

Ops are classified `read` / `write` in the tool registry. `--read-only` on the
daemon refuses every write op at the Python boundary, which is the right mode
for letting the agent explore an existing board.

## Component layout

| Path | What it is |
|------|------------|
| `altium/` | DelphiScript that runs inside Altium: panel, bridge, op handlers |
| `src/altium_agent/` | Python: agent loop, tool registry, bridge client, block engine |
| `blocks/` | Captured reusable circuits as version-controlled JSON |
| `docs/` | This, plus the wire protocol and the Altium API notes |

## Known risk register

| Risk | Impact | Mitigation |
|------|--------|-----------|
| DelphiScript API differs on this Develop build | Bridge will not run | `altium/src/Probe.pas` verifies every primitive before you build on it |
| `TTimer` unavailable in ScriptForms | No live turn loop | Falls back to headless `DrainOnce` wake per batch |
| Single-instance CLI dispatch does not work | No headless wake | Panel path still works; headless becomes manual |
| Workdir on OneDrive | Sync races corrupt the queue | Default workdir is `C:\ProgramData`, documented in `.env.example` |
| Long op blocks the UI mid-batch | Altium appears frozen | Cap batch size (`max_batch_ops`), keep individual ops small |
