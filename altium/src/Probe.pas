{ Probe - verify what this Altium build's scripting API actually supports.

  RUN THIS FIRST, before trusting anything else in altium/src/.

  The rest of the bridge is written against the standard Altium scripting API.
  That API is stable across mainstream releases, but this machine runs a
  Develop build and none of it has been executed there. Rather than discover
  the gaps one confusing failure at a time, this script exercises every
  primitive the bridge depends on and writes the result to

      %ALTIUM_AGENT_WORKDIR%\probe.json

  Then, from the repository root:

      python -m altium_agent.cli probe

  How to run: open AltiumAgent.PrjScr, open this file, press F9, choose
  Probe_Main.
}

const
  PROBE_WORKDIR = 'C:\ProgramData\AltiumAgent\bridge';

var
  ProbeResults : TStringList;


procedure ProbeAdd(const Name : string; Ok : Boolean; const Detail : string);
begin
  if Ok then
    ProbeResults.Add(Name + '|1|' + Detail)
  else
    ProbeResults.Add(Name + '|0|' + Detail);
end;


{ --------------------------------------------------------------- checks }

procedure ProbeFileIO;
var
  List : TStringList;
  Path : string;
begin
  Path := PROBE_WORKDIR + '\probe_write_test.txt';
  try
    if not DirectoryExists(PROBE_WORKDIR) then
      ForceDirectories(PROBE_WORKDIR);

    List := TStringList.Create;
    try
      List.Add('altium agent probe');
      List.SaveToFile(Path);
      List.Clear;
      List.LoadFromFile(Path);
      if (List.Count = 1) and (List[0] = 'altium agent probe') then
        ProbeAdd('file_io', True, 'read/write round trip ok')
      else
        ProbeAdd('file_io', False, 'round trip mismatch');
    finally
      List.Free;
    end;
    DeleteFile(Path);
  except
    ProbeAdd('file_io', False, 'exception writing to ' + PROBE_WORKDIR);
  end;
end;


{ Timer check - creation and configuration only.

  The earlier version of this assigned a standalone procedure to Timer.OnTimer
  and pumped the message loop with Application.ProcessMessages + Sleep to see
  whether it fired. Three problems: DelphiScript may reject assigning a plain
  procedure to a method-pointer event, Sleep is not guaranteed to exist, and
  pumping messages from a non-form script is not something this build promises
  to support. Any one of those is a compile or runtime failure that takes the
  whole probe down.

  Whether the timer actually FIRES is answered properly by opening the agent
  panel, which is a real form with a real message loop - that is the context
  the bridge runs in anyway. }
procedure ProbeTimer;
var
  Timer : TTimer;
begin
  try
    Timer := TTimer.Create(Nil);
    try
      Timer.Interval := 100;
      Timer.Enabled  := False;
      ProbeAdd('timer_create', True, 'TTimer created and configured');
    finally
      Timer.Free;
    end;
  except
    ProbeAdd('timer_create', False, 'TTimer could not be created');
  end;
end;


procedure ProbeSchServer;
var
  Doc : ISch_Document;
begin
  try
    if SchServer = Nil then
    begin
      ProbeAdd('sch_server', False, 'SchServer is nil');
      Exit;
    end;
    ProbeAdd('sch_server', True, 'SchServer available');

    Doc := SchServer.GetCurrentSchDocument;
    if Doc = Nil then
      ProbeAdd('sch_document', False, 'no schematic focused - open one and re-run')
    else
      ProbeAdd('sch_document', True, Doc.DocumentName);
  except
    ProbeAdd('sch_server', False, 'exception reaching SchServer');
  end;
end;


procedure ProbeSchFactory;
var
  Comp : ISch_Component;
begin
  try
    Comp := SchServer.SchObjectFactory(eSchComponent, eCreate_GlobalCopy);
    if Comp = Nil then
      ProbeAdd('sch_factory', False, 'SchObjectFactory returned nil')
    else
    begin
      ProbeAdd('sch_factory', True, 'component object created');
      SchServer.DestroySchObject(Comp);
    end;
  except
    ProbeAdd('sch_factory', False, 'SchObjectFactory raised');
  end;
end;


procedure ProbePcbServer;
var
  Board : IPCB_Board;
begin
  try
    if PCBServer = Nil then
    begin
      ProbeAdd('pcb_server', False, 'PCBServer is nil');
      Exit;
    end;
    ProbeAdd('pcb_server', True, 'PCBServer available');

    Board := PCBServer.GetCurrentPCBBoard;
    if Board = Nil then
      ProbeAdd('pcb_board', False, 'no PCB focused - open one and re-run')
    else
      ProbeAdd('pcb_board', True, Board.FileName);
  except
    ProbeAdd('pcb_server', False, 'exception reaching PCBServer');
  end;
end;


procedure ProbePcbIterator;
var
  Board    : IPCB_Board;
  Iterator : IPCB_BoardIterator;
  Comp     : IPCB_Component;
  Count    : Integer;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ProbeAdd('pcb_iterator', False, 'skipped - no PCB open');
    Exit;
  end;

  Count := 0;
  try
    Iterator := Board.BoardIterator_Create;
    try
      Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
      Iterator.AddFilter_LayerSet(AllLayers);
      Iterator.AddFilter_Method(eProcessAll);
      Comp := Iterator.FirstPCBObject;
      while Comp <> Nil do
      begin
        Inc(Count);
        Comp := Iterator.NextPCBObject;
      end;
    finally
      Board.BoardIterator_Destroy(Iterator);
    end;
    ProbeAdd('pcb_iterator', True, IntToStr(Count) + ' components enumerated');
  except
    ProbeAdd('pcb_iterator', False, 'iterator raised');
  end;
end;


procedure ProbeUnits;
var
  Value : Extended;
begin
  try
    Value := CoordToMMs(MMsToCoord(12.345));
    if Abs(Value - 12.345) < 0.001 then
      ProbeAdd('units', True, 'mm <-> Coord round trip ok')
    else
      ProbeAdd('units', False, 'round trip gave ' + FloatToStr(Value));
  except
    ProbeAdd('units', False, 'MMsToCoord/CoordToMMs unavailable');
  end;
end;


procedure ProbeWorkspace;
var
  Workspace : IWorkspace;
  Project   : IProject;
begin
  try
    Workspace := GetWorkspace;
    if Workspace = Nil then
    begin
      ProbeAdd('workspace', False, 'GetWorkspace returned nil');
      Exit;
    end;
    Project := Workspace.DM_FocusedProject;
    if Project = Nil then
      ProbeAdd('workspace', True, 'workspace ok, no project focused')
    else
      ProbeAdd('workspace', True, Project.DM_ProjectFileName);
  except
    ProbeAdd('workspace', False, 'GetWorkspace raised');
  end;
end;


procedure ProbeOle;
begin
  try
    CreateOleObject('MSXML2.XMLHTTP');
    ProbeAdd('ole_http', True, 'CreateOleObject available (optional)');
  except
    ProbeAdd('ole_http', False, 'not available - file transport is used anyway');
  end;
end;


{ ---------------------------------------------------------------- output }

procedure ProbeWriteJson;
var
  Out     : TStringList;
  I       : Integer;
  Line    : string;
  Name    : string;
  OkFlag  : string;
  Detail  : string;
  P1, P2  : Integer;
  Comma   : string;
begin
  Out := TStringList.Create;
  try
    Out.Add('{');
    Out.Add('  "altium_build": "' + JsonEscape(Client.GetProductVersion) + '",');
    Out.Add('  "written": "' + JsonEscape(DateTimeToStr(Now)) + '",');
    Out.Add('  "checks": {');

    for I := 0 to ProbeResults.Count - 1 do
    begin
      Line := ProbeResults[I];
      P1 := Pos('|', Line);
      Name := Copy(Line, 1, P1 - 1);
      Detail := Copy(Line, P1 + 1, Length(Line));
      P2 := Pos('|', Detail);
      OkFlag := Copy(Detail, 1, P2 - 1);
      Detail := Copy(Detail, P2 + 1, Length(Detail));

      if I < ProbeResults.Count - 1 then Comma := ',' else Comma := '';
      if OkFlag = '1' then
        Out.Add('    "' + JsonEscape(Name) + '": {"ok": true, "detail": "' +
                JsonEscape(Detail) + '"}' + Comma)
      else
        Out.Add('    "' + JsonEscape(Name) + '": {"ok": false, "detail": "' +
                JsonEscape(Detail) + '"}' + Comma);
    end;

    Out.Add('  }');
    Out.Add('}');

    if not DirectoryExists(PROBE_WORKDIR) then ForceDirectories(PROBE_WORKDIR);
    Out.SaveToFile(PROBE_WORKDIR + '\probe.json');
  finally
    Out.Free;
  end;
end;


function ProbeSummary : string;
var
  I, Passed : Integer;
  Line : string;
  P1, P2 : Integer;
begin
  Passed := 0;
  Result := '';
  for I := 0 to ProbeResults.Count - 1 do
  begin
    Line := ProbeResults[I];
    P1 := Pos('|', Line);
    P2 := Pos('|', Copy(Line, P1 + 1, Length(Line))) + P1;
    if Copy(Line, P1 + 1, P2 - P1 - 1) = '1' then
    begin
      Inc(Passed);
      Result := Result + '  PASS  ' + Copy(Line, 1, P1 - 1) + #13#10;
    end
    else
      Result := Result + '  FAIL  ' + Copy(Line, 1, P1 - 1) + #13#10;
  end;
  Result := IntToStr(Passed) + ' of ' + IntToStr(ProbeResults.Count) +
            ' checks passed.' + #13#10#13#10 + Result;
end;


procedure Probe_Main;
begin
  ProbeResults := TStringList.Create;
  try
    ProbeFileIO;
    ProbeTimer;
    ProbeUnits;
    ProbeWorkspace;
    ProbeSchServer;
    ProbeSchFactory;
    ProbePcbServer;
    ProbePcbIterator;
    ProbeOle;

    ProbeWriteJson;

    ShowMessage(
      'Altium Agent capability probe' + #13#10 + #13#10 +
      ProbeSummary + #13#10 +
      'Written to ' + PROBE_WORKDIR + '\probe.json' + #13#10 +
      'Now run:  python -m altium_agent.cli probe'
    );
  finally
    ProbeResults.Free;
  end;
end;
