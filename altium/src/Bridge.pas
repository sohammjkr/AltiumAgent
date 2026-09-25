{ Bridge - the burst poller.

  This is the file that keeps Altium responsive, so read the rule before
  changing anything here:

      THE TIMER ONLY RUNS WHILE A TURN IS IN FLIGHT.

  Altium's scripting engine runs on the UI thread. A timer that ticks
  continuously competes with whatever the engineer is doing in the editor,
  permanently. So:

    - BR_BeginTurn starts the timer when the engineer presses Send
    - BR_EndTurn stops it the moment the agent's reply is final
    - between turns, nothing in this file executes at all

  Four further measures keep the in-flight cost low:

    1. One batch per assistant turn, not per operation. Placing a 24 part
       gate drive is ONE wake, not 24.
    2. Adaptive interval - fast right after a batch (another is likely),
       backing off while waiting on the model's thinking time.
    3. Re-entrancy guard - the timer disables itself for the duration of a
       batch. Altium will happily re-enter a timer handler during a long
       operation otherwise, giving overlapping transactions and a corrupt
       undo stack.
    4. Idle watchdog - if nothing arrives within BR_TURN_TIMEOUT_MS the
       timer stops itself, so a wedged daemon can never leave a timer
       running in the engineer's session.
}

const
  BR_TICK_FAST_MS    = 80;      { just finished a batch, expect another }
  BR_TICK_SLOW_MS    = 500;     { waiting on model thinking time }
  BR_BACKOFF_AFTER_MS = 3000;   { idle this long -> slow down }
  BR_TURN_TIMEOUT_MS = 180000;  { watchdog: give up on a wedged daemon }

var
  BR_Timer      : TTimer;
  BR_Turn       : string;
  BR_Busy       : Boolean;
  BR_IdleMs     : Integer;
  BR_ElapsedMs  : Integer;
  BR_Started    : Boolean;
  BR_OnActivity : TNotifyEvent;   { panel hook: a batch just ran }
  BR_OnPoll     : TNotifyEvent;   { panel hook: check for a chat reply }
  BR_LastLabel  : string;


{ Ops_Dispatch, Ops_BeginTransaction, Ops_EndTransaction and
  Ops_RollbackTransaction live in Ops.pas / OpsSch.pas / OpsPcb.pas. Script
  files in one Altium script project share a global namespace, so they are
  called directly with no forward declaration - but Ops.pas must be listed
  BEFORE Bridge.pas in AltiumAgent.PrjScr. }


{ ------------------------------------------------------------ one batch }

{ Execute every op in a batch inside a single undo transaction, and write the
  result file. Returns True if every op succeeded. }
function BR_RunBatch(const InPath : string) : Boolean;
var
  Flat      : TStringList;
  Text      : string;
  BatchId   : string;
  Label_    : string;
  Atomic    : Boolean;
  OpCount   : Integer;
  I         : Integer;
  Results   : string;
  OneResult : string;
  AllOk     : Boolean;
  StartTick : Integer;
  Body      : string;
  OkText    : string;
begin
  Result := False;
  StartTick := GetTickCount;

  Flat := TStringList.Create;
  try
    Text := TP_ReadAll(InPath);
    if Text = '' then
    begin
      if FileExists(InPath) then DeleteFile(InPath);
      Exit;
    end;

    if not JsonFlatten(Text, Flat) then
    begin
      BatchId := 'unknown';
      TP_Log('batch parse failed: ' + JsonErr);
      TP_CompleteBatch(InPath, BatchId,
        '{"batch":"' + BatchId + '","ok":false,"results":[],"error":"' +
        JsonEscape('Malformed batch JSON: ' + JsonErr) + '"}');
      Exit;
    end;

    BatchId := JGet(Flat, 'batch', 'unknown');
    Label_  := JGet(Flat, 'txn_label', 'Agent operation');
    Atomic  := JBool(Flat, 'atomic', False);
    OpCount := JCount(Flat, 'ops');
    BR_LastLabel := Label_;

    TP_Log('batch ' + BatchId + ': ' + IntToStr(OpCount) + ' ops - ' + Label_);
    if Assigned(BR_OnActivity) then BR_OnActivity(Nil);

    AllOk := True;
    Results := '';

    { One transaction for the whole batch, so one Ctrl+Z undoes one agent
      action. This is the behaviour an engineer expects when the agent does
      something they did not intend. }
    Ops_BeginTransaction(Label_);
    try
      for I := 0 to OpCount - 1 do
      begin
        OneResult := Ops_Dispatch(Flat, 'ops.' + IntToStr(I));
        if Results <> '' then Results := Results + ',';
        Results := Results + OneResult;

        if Pos('"ok":false', OneResult) > 0 then
        begin
          AllOk := False;
          { Atomic batches (block instantiation) abandon the rest - a half
            placed gate drive is worse than none. Non-atomic batches carry
            on so the model gets per-op results and can repair itself. }
          if Atomic then Break;
        end;
      end;
    finally
      if Atomic and (not AllOk) then
        Ops_RollbackTransaction(Label_)
      else
        Ops_EndTransaction(Label_);
    end;

    if AllOk then OkText := 'true' else OkText := 'false';
    Body := '{"batch":"' + JsonEscape(BatchId) + '",' +
            '"ok":' + OkText + ',' +
            '"elapsed_ms":' + IntToStr(GetTickCount - StartTick) + ',' +
            '"results":[' + Results + ']}';

    TP_CompleteBatch(InPath, BatchId, Body);
    TP_Log('batch ' + BatchId + ' done in ' +
           IntToStr(GetTickCount - StartTick) + 'ms, ok=' + OkText);
    Result := AllOk;
  finally
    Flat.Free;
  end;
end;


{ Drain every queued batch once, then return. Used both by the timer and by
  the headless entry point. Returns the number of batches executed. }
function BR_DrainQueue : Integer;
var
  Path : string;
begin
  Result := 0;
  TP_EnsureDirs;
  Path := TP_NextBatchFile;
  while Path <> '' do
  begin
    BR_RunBatch(Path);
    Inc(Result);
    Path := TP_NextBatchFile;
  end;
end;


{ ---------------------------------------------------------------- timer }

{ Stop polling. Called as soon as the reply is final. After this, no script
  code runs until the next turn.

  Declared BEFORE BR_Tick deliberately: BR_Tick's watchdog calls it, and
  DelphiScript has no usable `forward` declaration, so a callee must appear
  above its caller. }
procedure BR_EndTurn;
begin
  if BR_Timer <> Nil then BR_Timer.Enabled := False;
  BR_Started := False;
  TP_WriteState(BR_Turn, False);
  TP_Log('turn ' + BR_Turn + ' end - polling stopped');
  BR_Turn := '';
end;


procedure BR_Tick(Sender : TObject);
var
  Executed : Integer;
begin
  { Re-entrancy guard. A long op pumps messages, and Altium will happily
    re-enter this handler while the previous call is still inside a
    transaction. }
  if BR_Busy then Exit;

  BR_Busy := True;
  BR_Timer.Enabled := False;
  try
    BR_ElapsedMs := BR_ElapsedMs + BR_Timer.Interval;

    Executed := BR_DrainQueue;

    { One timer does both jobs - draining the op queue and checking for the
      agent's reply - so a turn in flight costs Altium one timer, not two. }
    if Assigned(BR_OnPoll) then BR_OnPoll(Nil);

    if Executed > 0 then
    begin
      { More work is likely to follow immediately - stay responsive. }
      BR_IdleMs := 0;
      BR_Timer.Interval := BR_TICK_FAST_MS;
      TP_WriteState(BR_Turn, True);
    end
    else
    begin
      BR_IdleMs := BR_IdleMs + BR_Timer.Interval;
      if BR_IdleMs > BR_BACKOFF_AFTER_MS then
        BR_Timer.Interval := BR_TICK_SLOW_MS;
    end;

    { Watchdog - never let a wedged daemon leave a timer running. }
    if BR_ElapsedMs > BR_TURN_TIMEOUT_MS then
    begin
      TP_Log('watchdog: turn ' + BR_Turn + ' timed out, stopping poll');
      BR_EndTurn;
      Exit;
    end;
  finally
    BR_Busy := False;
    if BR_Started then BR_Timer.Enabled := True;
  end;
end;


procedure BR_Init;
begin
  if BR_Timer <> Nil then Exit;
  TP_EnsureDirs;
  BR_Timer := TTimer.Create(Nil);
  BR_Timer.Enabled  := False;
  BR_Timer.Interval := BR_TICK_FAST_MS;
  BR_Timer.OnTimer  := BR_Tick;
  BR_Busy    := False;
  BR_Started := False;
end;


{ Start polling. Called when the engineer presses Send. }
procedure BR_BeginTurn(const TurnId : string);
begin
  BR_Init;
  BR_Turn      := TurnId;
  BR_IdleMs    := 0;
  BR_ElapsedMs := 0;
  BR_Started   := True;
  BR_Timer.Interval := BR_TICK_FAST_MS;
  BR_Timer.Enabled  := True;
  TP_WriteState(TurnId, True);
  TP_Log('turn ' + TurnId + ' begin - polling started');
end;


procedure BR_Shutdown;
begin
  if BR_Timer <> Nil then
  begin
    BR_Timer.Enabled := False;
    BR_Timer.Free;
    BR_Timer := Nil;
  end;
  BR_Started := False;
end;


{ ----------------------------------------------------- headless entry point }

{ Called from the command line:
    X2.EXE -RScriptingSystem:RunScript(ProjectName="...")|ProcedureName="DrainOnce")
  Processes whatever is queued and returns. Never starts a timer, so it costs
  Altium nothing beyond the work itself. }
procedure DrainOnce;
var
  Count : Integer;
begin
  TP_EnsureDirs;
  Count := BR_DrainQueue;
  TP_WriteState('', False);
  TP_Log('DrainOnce executed ' + IntToStr(Count) + ' batch(es)');
end;
