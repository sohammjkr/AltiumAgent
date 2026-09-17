{ AgentPanel - the chat window inside Altium.

  A NOTE ON "PANEL"
  -----------------
  A true docked Altium panel (one that lives in the sidebar alongside
  Projects and Navigator) requires a compiled extension built against the
  Altium SDK - it cannot be done from the scripting system. What scripting
  can give you is this: a modeless form that floats over the workspace,
  stays open while you work, and can be parked on a second monitor. That is
  what this is.

  If a docked panel turns out to matter, the move is to port this form to a
  compiled Delphi or C# extension while keeping the bridge and the whole
  Python side unchanged - the file protocol does not care what draws the UI.

  TIMER DISCIPLINE
  ----------------
  Pressing Send starts the bridge timer; a final reply stops it. Between
  turns nothing polls. See Bridge.pas.
}

var
  PanelTurn      : string;
  PanelWaiting   : Boolean;
  PanelLastText  : string;


procedure PanelAppend(const Who, Text : string);
begin
  if AgentForm.TranscriptMemo.Lines.Count > 0 then
    AgentForm.TranscriptMemo.Lines.Add('');
  AgentForm.TranscriptMemo.Lines.Add(Who + '  ' + Text);
  { Keep the newest text in view. }
  AgentForm.TranscriptMemo.SelStart := Length(AgentForm.TranscriptMemo.Text);
  AgentForm.TranscriptMemo.Perform(WM_VSCROLL, SB_BOTTOM, 0);
end;


procedure PanelStatus(const Text : string);
begin
  AgentForm.StatusLabel.Caption := Text;
  Application.ProcessMessages;
end;


{ Cheap context hint so the agent does not have to spend a tool call finding
  out what the engineer was looking at. }
function PanelContextJson : string;
var
  Sch      : ISch_Document;
  Board    : IPCB_Board;
  Iterator : ISch_Iterator;
  Comp     : ISch_Component;
  Selected : string;
  Focused  : string;
begin
  Focused := '';
  Selected := '';

  Sch := Ops_CurrentSch;
  if Sch <> Nil then
  begin
    Focused := Sch.DocumentName;
    Iterator := Sch.SchIterator_Create;
    if Iterator <> Nil then
    try
      Iterator.AddFilter_ObjectSet(MkSet(eSchComponent));
      Comp := Iterator.FirstSchObject;
      while Comp <> Nil do
      begin
        if Comp.Selection then
        begin
          if Selected <> '' then Selected := Selected + ', ';
          Selected := Selected + '"' + JsonEscape(Comp.Designator.Text) + '"';
        end;
        Comp := Iterator.NextSchObject;
      end;
    finally
      Sch.SchIterator_Destroy(Iterator);
    end;
  end
  else
  begin
    Board := Ops_CurrentBoard;
    if Board <> Nil then Focused := ExtractFileName(Board.FileName);
  end;

  Result := '{' + JsonStr('focused_doc', Focused) + ',' +
                  '"selection":[' + Selected + ']}';
end;


{ Called on every bridge tick while a turn is in flight. }
procedure PanelPoll(Sender : TObject);
var
  Path   : string;
  Text   : string;
  Flat   : TStringList;
  Reply  : string;
  Status : string;
  Final  : Boolean;
  Activity : Integer;
begin
  if not PanelWaiting then Exit;

  Path := TP_ChatResponsePath(PanelTurn);
  if not FileExists(Path) then Exit;

  Text := TP_ReadAll(Path);
  if Text = '' then Exit;

  Flat := TStringList.Create;
  try
    if not JsonFlatten(Text, Flat) then Exit;   { probably a partial write }

    Final  := JBool(Flat, 'final', False);
    Status := JGet(Flat, 'status', 'working');
    Reply  := JGet(Flat, 'text', '');

    if not Final then
    begin
      Activity := JCount(Flat, 'activity');
      if Activity > 0 then
        PanelStatus('Working - ' + IntToStr(Activity) + ' operation(s) so far')
      else
        PanelStatus('Working...');
      Exit;
    end;

    { Final reply: show it and stop polling. }
    if Reply <> PanelLastText then
    begin
      PanelAppend('agent>', Reply);
      PanelLastText := Reply;
    end;

    PanelWaiting := False;
    BR_EndTurn;                           { <- this is what frees Altium }

    if Status = 'done' then PanelStatus('Ready')
    else PanelStatus('Finished with status: ' + Status);

    AgentForm.SendButton.Enabled  := True;
    AgentForm.InputMemo.Enabled   := True;
    AgentForm.InputMemo.SetFocus;
  finally
    Flat.Free;
  end;
end;


procedure PanelActivity(Sender : TObject);
begin
  PanelStatus('Applying: ' + BR_LastLabel);
end;


procedure PanelSend;
var
  Text : string;
begin
  Text := Trim(AgentForm.InputMemo.Text);
  if Text = '' then Exit;
  if PanelWaiting then Exit;

  PanelAppend('you>', Text);
  AgentForm.InputMemo.Text := '';

  PanelTurn     := TP_NextTurnId;
  PanelWaiting  := True;
  PanelLastText := '';

  TP_WriteChatRequest(PanelTurn, Text, PanelContextJson);

  AgentForm.SendButton.Enabled := False;
  AgentForm.InputMemo.Enabled  := False;
  PanelStatus('Sent - waiting for the agent...');

  BR_OnPoll     := PanelPoll;
  BR_OnActivity := PanelActivity;
  BR_BeginTurn(PanelTurn);                { <- starts polling }
end;


{ ------------------------------------------------------------- events }

procedure TAgentForm.SendButtonClick(Sender : TObject);
begin
  PanelSend;
end;


procedure TAgentForm.InputMemoKeyDown(Sender : TObject; var Key : Word;
                                      Shift : TShiftState);
begin
  { Ctrl+Enter sends, plain Enter makes a new line - the usual convention. }
  if (Key = VK_RETURN) and (ssCtrl in Shift) then
  begin
    Key := 0;
    PanelSend;
  end;
end;


procedure TAgentForm.StopButtonClick(Sender : TObject);
begin
  if not PanelWaiting then Exit;
  PanelWaiting := False;
  BR_EndTurn;
  PanelStatus('Stopped. The agent may still finish its current batch.');
  AgentForm.SendButton.Enabled := True;
  AgentForm.InputMemo.Enabled  := True;
end;


procedure TAgentForm.FormCreate(Sender : TObject);
begin
  TP_EnsureDirs;
  BR_Init;
  PanelWaiting := False;
  PanelTurn    := '';
  AgentForm.TranscriptMemo.Clear;
  PanelAppend('agent>',
    'Ready. Make sure the daemon is running:' + #13#10 +
    '    altium-agent serve' + #13#10 + #13#10 +
    'Ctrl+Enter sends.');
  PanelStatus('Ready');
end;


procedure TAgentForm.FormClose(Sender : TObject; var Action : TCloseAction);
begin
  { Never leave a timer running in the engineer's Altium session. }
  BR_EndTurn;
  BR_Shutdown;
  BR_OnPoll     := Nil;
  BR_OnActivity := Nil;
end;


{ ------------------------------------------------------- entry point }

{ Run this from Altium: DXP > Run Script > AgentPanel > RunAgentPanel

  Show, not ShowModal. ShowModal would block the schematic and PCB editors,
  which defeats the entire point - you need to keep working while the agent
  does. Altium keeps script forms alive after the launching procedure
  returns.

  If this build destroys the form on return, switch to ShowModal and accept
  a blocking window, or port the UI to a compiled extension (see the note at
  the top of this file). The bridge and the Python side are unaffected
  either way. }
procedure RunAgentPanel;
begin
  AgentForm.Show;
end;
