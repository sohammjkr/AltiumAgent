{ ProbeMinimal - dependency-free capability probe.

  WHY THIS EXISTS
  ---------------
  Probe.pas lives in AltiumAgent.PrjScr alongside JsonLite.pas, Transport.pas
  and the rest. A compile error in ANY file of that project stops ALL of them,
  so a single bad construct anywhere blocks the capability reading entirely.

  This file has zero dependencies and lives in its own script project
  (ProbeMinimal.PrjScr). It uses only the most conservative DelphiScript
  constructs, deliberately avoiding everything known to be unsupported or
  version-dependent:

    - no `const` parameter modifiers        (rejected by some builds)
    - no `forward` declarations             (mutual recursion not supported)
    - no two-argument Inc(x, n)             (single-arg only)
    - no `MaxInt`, no `DecimalSeparator`
    - no cross-file calls of any kind
    - plain text output, no JSON builder

  It writes C:\ProgramData\AltiumAgent\bridge\probe_minimal.txt

  Run: open ProbeMinimal.PrjScr, open this file, F9, choose ProbeMin_Main.
}

var
  PMResults : TStringList;


procedure PMAdd(Name : string; Ok : Boolean; Detail : string);
begin
  if Ok then
    PMResults.Add('PASS|' + Name + '|' + Detail)
  else
    PMResults.Add('FAIL|' + Name + '|' + Detail);
end;


procedure PMCheckFileIO;
var
  List : TStringList;
  Dir  : string;
  Path : string;
begin
  Dir  := 'C:\ProgramData\AltiumAgent\bridge';
  Path := Dir + '\pm_write_test.txt';
  try
    if not DirectoryExists(Dir) then
      ForceDirectories(Dir);

    List := TStringList.Create;
    try
      List.Add('probe minimal');
      List.SaveToFile(Path);
      List.Clear;
      List.LoadFromFile(Path);
      if List.Count = 1 then
        PMAdd('file_io', True, 'read/write ok')
      else
        PMAdd('file_io', False, 'round trip mismatch');
    finally
      List.Free;
    end;
    DeleteFile(Path);
  except
    PMAdd('file_io', False, 'exception writing to ' + Dir);
  end;
end;


procedure PMCheckUnits;
var
  Value : Extended;
begin
  try
    Value := CoordToMMs(MMsToCoord(12.345));
    if Abs(Value - 12.345) < 0.001 then
      PMAdd('units', True, 'mm to Coord round trip ok')
    else
      PMAdd('units', False, 'round trip gave ' + FloatToStr(Value));
  except
    PMAdd('units', False, 'MMsToCoord not available');
  end;
end;


procedure PMCheckSch;
var
  Doc : ISch_Document;
begin
  try
    if SchServer = Nil then
    begin
      PMAdd('sch_server', False, 'SchServer is nil');
      Exit;
    end;
    PMAdd('sch_server', True, 'available');

    Doc := SchServer.GetCurrentSchDocument;
    if Doc = Nil then
      PMAdd('sch_document', False, 'no schematic focused')
    else
      PMAdd('sch_document', True, Doc.DocumentName);
  except
    PMAdd('sch_server', False, 'exception');
  end;
end;


procedure PMCheckSchFactory;
var
  Comp : ISch_Component;
begin
  try
    Comp := SchServer.SchObjectFactory(eSchComponent, eCreate_GlobalCopy);
    if Comp = Nil then
      PMAdd('sch_factory', False, 'returned nil')
    else
    begin
      PMAdd('sch_factory', True, 'component created');
      SchServer.DestroySchObject(Comp);
    end;
  except
    PMAdd('sch_factory', False, 'raised');
  end;
end;


procedure PMCheckPcb;
var
  Board : IPCB_Board;
begin
  try
    if PCBServer = Nil then
    begin
      PMAdd('pcb_server', False, 'PCBServer is nil');
      Exit;
    end;
    PMAdd('pcb_server', True, 'available');

    Board := PCBServer.GetCurrentPCBBoard;
    if Board = Nil then
      PMAdd('pcb_board', False, 'no PCB focused')
    else
      PMAdd('pcb_board', True, Board.FileName);
  except
    PMAdd('pcb_server', False, 'exception');
  end;
end;


procedure PMCheckPcbIterator;
var
  Board    : IPCB_Board;
  Iterator : IPCB_BoardIterator;
  Comp     : IPCB_Component;
  Count    : Integer;
begin
  try
    Board := PCBServer.GetCurrentPCBBoard;
    if Board = Nil then
    begin
      PMAdd('pcb_iterator', False, 'skipped, no PCB open');
      Exit;
    end;

    Count := 0;
    Iterator := Board.BoardIterator_Create;
    try
      Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
      Iterator.AddFilter_LayerSet(AllLayers);
      Iterator.AddFilter_Method(eProcessAll);
      Comp := Iterator.FirstPCBObject;
      while Comp <> Nil do
      begin
        Count := Count + 1;
        Comp := Iterator.NextPCBObject;
      end;
    finally
      Board.BoardIterator_Destroy(Iterator);
    end;
    PMAdd('pcb_iterator', True, IntToStr(Count) + ' components');
  except
    PMAdd('pcb_iterator', False, 'raised');
  end;
end;


procedure PMCheckWorkspace;
var
  Workspace : IWorkspace;
  Project   : IProject;
begin
  try
    Workspace := GetWorkspace;
    if Workspace = Nil then
    begin
      PMAdd('workspace', False, 'nil');
      Exit;
    end;
    Project := Workspace.DM_FocusedProject;
    if Project = Nil then
      PMAdd('workspace', True, 'no project focused')
    else
      PMAdd('workspace', True, Project.DM_ProjectFileName);
  except
    PMAdd('workspace', False, 'raised');
  end;
end;


procedure PMCheckTimerClass;
var
  Timer : TTimer;
begin
  { Only checks that TTimer can be created and configured. Whether it FIRES
    is tested separately, because that needs a message pump and this build
    may not allow one from a non-form script. }
  try
    Timer := TTimer.Create(Nil);
    try
      Timer.Interval := 100;
      Timer.Enabled := False;
      PMAdd('timer_create', True, 'TTimer created and configured');
    finally
      Timer.Free;
    end;
  except
    PMAdd('timer_create', False, 'TTimer not available');
  end;
end;


procedure PMWrite;
var
  Dir : string;
begin
  Dir := 'C:\ProgramData\AltiumAgent\bridge';
  try
    if not DirectoryExists(Dir) then ForceDirectories(Dir);
    PMResults.SaveToFile(Dir + '\probe_minimal.txt');
  except
    ShowMessage('Could not write probe_minimal.txt to ' + Dir);
  end;
end;


function PMSummary : string;
var
  I : Integer;
begin
  Result := '';
  for I := 0 to PMResults.Count - 1 do
    Result := Result + PMResults[I] + #13#10;
end;


procedure PMCheckBuild;
begin
  { Client.GetProductVersion is not guaranteed to exist. Guarded, because an
    unguarded call here would take the whole probe down with it. }
  try
    PMAdd('altium_build', True, Client.GetProductVersion);
  except
    PMAdd('altium_build', False, 'Client.GetProductVersion unavailable');
  end;
end;


procedure ProbeMin_Main;
begin
  PMResults := TStringList.Create;
  try
    PMCheckBuild;
    PMCheckFileIO;
    PMCheckUnits;
    PMCheckTimerClass;
    PMCheckWorkspace;
    PMCheckSch;
    PMCheckSchFactory;
    PMCheckPcb;
    PMCheckPcbIterator;
    PMWrite;
    ShowMessage('Altium Agent - minimal probe' + #13#10 + #13#10 + PMSummary);
  finally
    PMResults.Free;
  end;
end;
