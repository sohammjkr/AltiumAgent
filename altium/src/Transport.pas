{ Transport - the file queue, from the Altium side.

  Everything is written to a .tmp file and then renamed into place, because
  rename is atomic on NTFS and the Python side must never read half a file.

  Paths mirror docs/protocol.md.
}

const
  AGENT_WORKDIR = 'C:\ProgramData\AltiumAgent\bridge';
  BRIDGE_VERSION = '0.1.0';


function TP_Dir(const Sub : string) : string;
begin
  Result := AGENT_WORKDIR + '\' + Sub;
end;


procedure TP_EnsureDirs;
begin
  if not DirectoryExists(AGENT_WORKDIR) then ForceDirectories(AGENT_WORKDIR);
  if not DirectoryExists(TP_Dir('chat\req')) then ForceDirectories(TP_Dir('chat\req'));
  if not DirectoryExists(TP_Dir('chat\res')) then ForceDirectories(TP_Dir('chat\res'));
  if not DirectoryExists(TP_Dir('cmd\in'))   then ForceDirectories(TP_Dir('cmd\in'));
  if not DirectoryExists(TP_Dir('cmd\out'))  then ForceDirectories(TP_Dir('cmd\out'));
  if not DirectoryExists(TP_Dir('log'))      then ForceDirectories(TP_Dir('log'));
end;


{ Write Text to Path via a temp file + rename. }
procedure TP_WriteAtomic(const Path, Text : string);
var
  List : TStringList;
  Temp : string;
begin
  Temp := Path + '.tmp';
  List := TStringList.Create;
  try
    List.Text := Text;
    List.SaveToFile(Temp);
  finally
    List.Free;
  end;
  if FileExists(Path) then DeleteFile(Path);
  RenameFile(Temp, Path);
end;


function TP_ReadAll(const Path : string) : string;
var
  List : TStringList;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  List := TStringList.Create;
  try
    List.LoadFromFile(Path);
    Result := List.Text;
  finally
    List.Free;
  end;
end;


procedure TP_Log(const Message : string);
var
  List : TStringList;
  Path : string;
begin
  Path := TP_Dir('log') + '\bridge.log';
  List := TStringList.Create;
  try
    if FileExists(Path) then List.LoadFromFile(Path);
    List.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' + Message);
    { Keep the log from growing without bound across long sessions. }
    while List.Count > 2000 do List.Delete(0);
    List.SaveToFile(Path);
  finally
    List.Free;
  end;
end;


{ Oldest pending batch file, or '' if the queue is empty. }
function TP_NextBatchFile : string;
var
  Search : TSearchRec;
  Best   : string;
  Dir    : string;
begin
  Result := '';
  Best := '';
  Dir := TP_Dir('cmd\in');
  if FindFirst(Dir + '\b*.json', faAnyFile, Search) = 0 then
  begin
    repeat
      { Ids are zero padded, so lexical order is chronological order. }
      if (Best = '') or (Search.Name < Best) then Best := Search.Name;
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  if Best <> '' then Result := Dir + '\' + Best;
end;


procedure TP_CompleteBatch(const InPath, BatchId, Body : string);
begin
  TP_WriteAtomic(TP_Dir('cmd\out') + '\' + BatchId + '.json', Body);
  if FileExists(InPath) then DeleteFile(InPath);
end;


{ ---------------------------------------------------------- bridge state }

function TP_OpenDocsJson : string;
var
  Workspace : IWorkspace;
  Project   : IProject;
  Document  : IDocument;
  I         : Integer;
  Parts     : string;
begin
  Parts := '';
  try
    Workspace := GetWorkspace;
    if Workspace = Nil then
    begin
      Result := '[]';
      Exit;
    end;
    Project := Workspace.DM_FocusedProject;
    if Project = Nil then
    begin
      Result := '[]';
      Exit;
    end;
    for I := 0 to Project.DM_LogicalDocumentCount - 1 do
    begin
      Document := Project.DM_LogicalDocuments(I);
      if Parts <> '' then Parts := Parts + ', ';
      Parts := Parts + '"' + JsonEscape(ExtractFileName(Document.DM_FullPath)) + '"';
    end;
  except
    Parts := '';
  end;
  Result := '[' + Parts + ']';
end;


procedure TP_WriteState(const Turn : string; Polling : Boolean);
var
  Body : string;
  PollingText : string;
begin
  if Polling then PollingText := 'true' else PollingText := 'false';
  Body :=
    '{' + #13#10 +
    '  "bridge_version": "' + BRIDGE_VERSION + '",' + #13#10 +
    '  "altium_build": "' + JsonEscape(Client.GetProductVersion) + '",' + #13#10 +
    '  "turn": "' + JsonEscape(Turn) + '",' + #13#10 +
    '  "polling": ' + PollingText + ',' + #13#10 +
    '  "last_tick": "' + FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now) + '",' + #13#10 +
    '  "open_docs": ' + TP_OpenDocsJson + #13#10 +
    '}';
  TP_WriteAtomic(AGENT_WORKDIR + '\state.json', Body);
end;


{ ------------------------------------------------------------ chat queue }

function TP_NextTurnId : string;
var
  Search : TSearchRec;
  Highest : Integer;
  Number  : Integer;
  Dir     : string;
begin
  Highest := 0;
  Dir := TP_Dir('chat\req');
  if FindFirst(Dir + '\t*.json', faAnyFile, Search) = 0 then
  begin
    repeat
      Number := StrToIntDef(Copy(Search.Name, 2, 6), 0);
      if Number > Highest then Highest := Number;
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  Result := 't' + FormatFloat('000000', Highest + 1);
end;


procedure TP_WriteChatRequest(const TurnId, Text, ContextJson : string);
var
  Body : string;
begin
  Body :=
    '{' + #13#10 +
    '  "turn": "' + JsonEscape(TurnId) + '",' + #13#10 +
    '  "text": "' + JsonEscape(Text) + '",' + #13#10 +
    '  "created": "' + FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now) + '",' + #13#10 +
    '  "context": ' + ContextJson + #13#10 +
    '}';
  TP_WriteAtomic(TP_Dir('chat\req') + '\' + TurnId + '.json', Body);
end;


function TP_ChatResponsePath(const TurnId : string) : string;
begin
  Result := TP_Dir('chat\res') + '\' + TurnId + '.json';
end;
