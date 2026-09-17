{ Ops - shared op machinery: transactions, argument access, result building.

  Every op handler has the signature

      function OpXxx(Flat : TStringList; const P, OpId : string) : string;

  where P is the flattened path prefix of the op's args, e.g.
  'ops.3.args', and the return value is a JSON object fragment
  {"id":"...","ok":true,"data":{...}}.
}

var
  OpsTxnSch   : ISch_Document;
  OpsTxnBoard : IPCB_Board;
  OpsTxnOpen  : Boolean;


{ ------------------------------------------------------------ documents }

function Ops_CurrentSch : ISch_Document;
begin
  Result := Nil;
  try
    if SchServer <> Nil then Result := SchServer.GetCurrentSchDocument;
  except
    Result := Nil;
  end;
end;


function Ops_CurrentBoard : IPCB_Board;
begin
  Result := Nil;
  try
    if PCBServer <> Nil then Result := PCBServer.GetCurrentPCBBoard;
  except
    Result := Nil;
  end;
end;


{ --------------------------------------------------------- transactions }

{ One transaction per batch, so one Ctrl+Z undoes one agent action.
  Both servers are opened because a single batch may touch the schematic and
  the PCB - block instantiation does exactly that. }
procedure Ops_BeginTransaction(const Label_ : string);
begin
  OpsTxnSch   := Ops_CurrentSch;
  OpsTxnBoard := Ops_CurrentBoard;
  OpsTxnOpen  := True;

  try
    if OpsTxnSch <> Nil then
    begin
      SchServer.ProcessControl.PreProcess(OpsTxnSch, '');
      SchServer.RobotManager.SendMessage(OpsTxnSch.I_ObjectAddress, c_BroadCast,
                                         SCHM_BeginModify, c_NoEventData);
    end;
  except
    TP_Log('warning: schematic transaction could not be opened');
  end;

  try
    if OpsTxnBoard <> Nil then
    begin
      PCBServer.PreProcess;
      PCBServer.SendMessageToRobots(OpsTxnBoard.I_ObjectAddress, c_Broadcast,
                                    PCBM_BeginModify, c_NoEventData);
    end;
  except
    TP_Log('warning: PCB transaction could not be opened');
  end;
end;


procedure Ops_EndTransaction(const Label_ : string);
begin
  if not OpsTxnOpen then Exit;

  try
    if OpsTxnSch <> Nil then
    begin
      SchServer.RobotManager.SendMessage(OpsTxnSch.I_ObjectAddress, c_BroadCast,
                                         SCHM_EndModify, c_NoEventData);
      SchServer.ProcessControl.PostProcess(OpsTxnSch, '');
      OpsTxnSch.GraphicallyInvalidate;
    end;
  except
    TP_Log('warning: schematic transaction could not be closed cleanly');
  end;

  try
    if OpsTxnBoard <> Nil then
    begin
      PCBServer.SendMessageToRobots(OpsTxnBoard.I_ObjectAddress, c_Broadcast,
                                    PCBM_EndModify, c_NoEventData);
      PCBServer.PostProcess;
      OpsTxnBoard.ViewManager_FullUpdate;
    end;
  except
    TP_Log('warning: PCB transaction could not be closed cleanly');
  end;

  OpsTxnOpen  := False;
  OpsTxnSch   := Nil;
  OpsTxnBoard := Nil;
end;


{ Atomic batches roll back on first failure. Altium has no scripted
  "abandon transaction", so this closes the transaction and then fires one
  Undo, which unwinds exactly the batch that was just opened. }
procedure Ops_RollbackTransaction(const Label_ : string);
begin
  Ops_EndTransaction(Label_);
  TP_Log('rolling back atomic batch: ' + Label_);
  try
    ResetParameters;
    RunProcess('Client:SendCommandToActiveDocument');
    { Undo on whichever editor is focused. }
    if Ops_CurrentBoard <> Nil then
      RunProcess('PCB:Undo')
    else if Ops_CurrentSch <> Nil then
      RunProcess('Sch:Undo');
  except
    TP_Log('warning: rollback undo failed - check the design manually');
  end;
end;


{ --------------------------------------------------------------- results }

function OpOk(const OpId, DataJson : string) : string;
var
  Data : string;
begin
  if DataJson = '' then Data := '{}' else Data := DataJson;
  Result := '{"id":"' + JsonEscape(OpId) + '","ok":true,"data":' + Data + '}';
end;


function OpFail(const OpId, Message : string) : string;
begin
  Result := '{"id":"' + JsonEscape(OpId) + '","ok":false,"error":"' +
            JsonEscape(Message) + '"}';
end;


{ ------------------------------------------------------------- arguments }

function ArgStr(Flat : TStringList; const P, Name, Default : string) : string;
begin
  Result := JGet(Flat, P + '.' + Name, Default);
end;


function ArgFloat(Flat : TStringList; const P, Name : string; Default : Extended) : Extended;
begin
  Result := JFloat(Flat, P + '.' + Name, Default);
end;


function ArgInt(Flat : TStringList; const P, Name : string; Default : Integer) : Integer;
begin
  Result := JInt(Flat, P + '.' + Name, Default);
end;


function ArgBool(Flat : TStringList; const P, Name : string; Default : Boolean) : Boolean;
begin
  Result := JBool(Flat, P + '.' + Name, Default);
end;


{ Coordinates always cross the wire in millimetres, never as Altium Coord.
  Converting only here is what stops a 10,000x placement error. }
function ArgCoordX(Flat : TStringList; const P, Name : string) : TCoord;
begin
  Result := MMsToCoord(ArgFloat(Flat, P, Name, 0.0));
end;


function ArgLayerIsBottom(Flat : TStringList; const P : string) : Boolean;
begin
  Result := LowerCase(ArgStr(Flat, P, 'layer', 'top')) = 'bottom';
end;


{ Map a rotation in degrees to Altium's schematic orientation enum. }
function SchRotationOf(Degrees : Integer) : TRotationBy90;
var
  Normalised : Integer;
begin
  Normalised := ((Degrees mod 360) + 360) mod 360;
  if Normalised = 90 then Result := eRotate90
  else if Normalised = 180 then Result := eRotate180
  else if Normalised = 270 then Result := eRotate270
  else Result := eRotate0;
end;
