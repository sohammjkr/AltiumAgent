# Altium API notes and verification checklist

## Read this first

The DelphiScript in `altium/src/` is written against the standard Altium
scripting API (`SchServer`, `PCBServer`, `Client`, `TTimer`, `TStringList`).
That API is stable across mainstream Altium Designer releases, but **this
machine runs a Develop build**:

```
C:\Program Files\Altium\ADDevelop\X2.EXE
%LOCALAPPDATA%\Altium\Altium Designer Develop {75A5ADBB-CF11-49F6-942F-6899A1A1CA11}
```

Nothing here has been executed inside that build. Before writing any more op
handlers, run the probe and find out what is actually true.

## Step 1: run the probe

1. In Altium: **File > Open Project**, select `altium/AltiumAgent.PrjScr`
2. Open `Probe.pas`
3. **Run** (F9) -> pick `Probe_Main`

It writes `%ALTIUM_AGENT_WORKDIR%\probe.json` and shows a summary dialog. Then:

```bash
python -m altium_agent.cli probe
```

which reads that file and prints a pass/fail table.

## What the probe checks, and what breaks if it fails

| Check | Why it matters | If it fails |
|---|---|---|
| `TTimer` can be created and fires | The entire live turn loop | Fall back to headless `DrainOnce` - one wake per batch via the CLI |
| File read/write from DelphiScript | The whole transport | Project is dead in this form; would need a compiled extension |
| `SchServer.GetCurrentSchDocument` | All schematic ops | Check a schematic is focused; API name may differ |
| `PCBServer.GetCurrentPCBBoard` | All PCB ops | Same |
| `SchServer.SchObjectFactory` | Creating schematic objects | Placement may have to go through `Client.SendMessage` process calls instead |
| `PCBServer.PCBObjectFactory` | Creating PCB objects | Same |
| Undo transaction pairs work | One Ctrl+Z per agent action | Ops still work, undo granularity gets ugly |
| `CreateOleObject` available | Optional faster HTTP transport | Ignore - file transport is the default anyway |
| Component library enumeration | `sch.place_component` by name | Would need explicit library paths in every call |

## Step 2: verify the headless wake

With Altium already running, from PowerShell:

```powershell
& "C:\Program Files\Altium\ADDevelop\X2.EXE" -RScriptingSystem:RunScript(ProjectName=\"<abs path>\AltiumAgent.PrjScr\"^|ProcedureName=\"DrainOnce\")
```

Altium is single-instance, so this is *expected* to dispatch into the running
process rather than starting a second one. **Unverified.** If it launches a
second instance or silently does nothing, headless wake is unavailable and the
panel becomes the only entry point - which is fine for interactive use.

`scripts/wake_test.ps1` runs this and reports what happened.

## API idioms this project relies on

These are the standard patterns. Kept here so op handlers stay consistent.

### Schematic write, wrapped for undo

```pascal
SchServer.ProcessControl.PreProcess(Doc, '');
SchServer.RobotManager.SendMessage(Doc.I_ObjectAddress, c_BroadCast,
                                   SCHM_BeginModify, c_NoEventData);
// ... create objects, Doc.RegisterSchObjectInContainer(Obj) ...
SchServer.RobotManager.SendMessage(Doc.I_ObjectAddress, c_BroadCast,
                                   SCHM_EndModify, c_NoEventData);
SchServer.ProcessControl.PostProcess(Doc, '');
Doc.GraphicallyInvalidate;
```

### PCB write, wrapped for undo

```pascal
PCBServer.PreProcess;
PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast,
                              PCBM_BeginModify, c_NoEventData);
// ... Board.AddPCBObject(Obj) / modify ...
PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast,
                              PCBM_EndModify, c_NoEventData);
PCBServer.PostProcess;
Board.ViewManager_FullUpdate;
```

### Units

Never let a coordinate cross the wire as an Altium `Coord`. The protocol is
millimetres; convert at the boundary only:

```pascal
X := MMsToCoord(ArgFloat(Op, 'x_mm'));     // in
Result := CoordToMMs(Comp.x);              // out
```

### Iteration

```pascal
Iterator := Board.BoardIterator_Create;
Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
Iterator.AddFilter_LayerSet(AllLayers);
Iterator.AddFilter_Method(eProcessAll);
try
  Comp := Iterator.FirstPCBObject;
  while Comp <> Nil do begin ... Comp := Iterator.NextPCBObject; end;
finally
  Board.BoardIterator_Destroy(Iterator);
end;
```

`try/finally` around every iterator, without exception. A leaked iterator is a
handle leak in Altium's process that persists until restart.

### Linking schematic to PCB

For block placement the agent must find the footprint belonging to a schematic
component. In order of preference:

1. `SchComponent.UniqueId` <-> `PCBComponent.SourceUniqueId` - survives
   re-annotation, the correct answer
2. designator match - simple, breaks the moment anything is re-annotated
3. `SourceDesignator` / `SourceHierarchicalPath` - needed for multi-channel

The block engine records `unique_id` at capture time and falls back to
designator with a warning. `block.apply_placement` reports which components it
matched by which method, because silently placing the wrong part is the worst
failure mode this tool has.

## Things deliberately not done through scripting

- **Autorouting.** Drive it through the UI or an OutJob. Scripted routing is a
  well-known source of bad boards and this agent should not pretend otherwise.
- **Library management.** Editing `.SchLib`/`.PcbLib` programmatically is out of
  scope for v1. The agent places what already exists.
- **ECO / Update PCB.** `pcb.update_from_schematic` fires Altium's own ECO
  process rather than reimplementing it.

## Reference

- Altium scripting API index: <https://www.altium.com/documentation/altium-designer/scripting>
- The object model docs (`ISch_*`, `IPCB_*`) are the ones worth having open
  while writing op handlers.
