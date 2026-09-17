{ OpsPcb - PCB op handlers.

  Placement only. Routing and the autorouter are deliberately not driven from
  here - see docs/altium-api.md.
}


function PcbBoardOrFail(const OpId : string; var Board : IPCB_Board) : string;
begin
  Result := '';
  Board := Ops_CurrentBoard;
  if Board = Nil then
    Result := OpFail(OpId, 'No PCB document is focused. Open a .PcbDoc first.');
end;


function PcbFindComponent(Board : IPCB_Board; const Designator : string) : IPCB_Component;
var
  Iterator : IPCB_BoardIterator;
  Comp     : IPCB_Component;
begin
  Result := Nil;
  Iterator := Board.BoardIterator_Create;
  if Iterator = Nil then Exit;
  try
    Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
    Iterator.AddFilter_LayerSet(AllLayers);
    Iterator.AddFilter_Method(eProcessAll);
    Comp := Iterator.FirstPCBObject;
    while Comp <> Nil do
    begin
      if UpperCase(Comp.Name.Text) = UpperCase(Designator) then
      begin
        Result := Comp;
        Exit;
      end;
      Comp := Iterator.NextPCBObject;
    end;
  finally
    Board.BoardIterator_Destroy(Iterator);
  end;
end;


{ -------------------------------------------------------------- reading }

function OpPcbBoardInfo(Flat : TStringList; const P, OpId : string) : string;
var
  Board    : IPCB_Board;
  Iterator : IPCB_BoardIterator;
  Comp     : IPCB_Component;
  Count    : Integer;
  Guard    : string;
  LayerText: string;
begin
  Guard := PcbBoardOrFail(OpId, Board);
  if Guard <> '' then
  begin
    Result := Guard;
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
      Inc(Count);
      Comp := Iterator.NextPCBObject;
    end;
  finally
    Board.BoardIterator_Destroy(Iterator);
  end;

  try
    LayerText := IntToStr(Board.LayerStack.SignalLayerCount);
  except
    LayerText := 'unknown';
  end;

  Result := OpOk(OpId,
    '{' + JsonStr('document', ExtractFileName(Board.FileName)) + ',' +
          JsonInt('components', Count) + ',' +
          JsonStr('signal_layers', LayerText) + ',' +
          JsonNum('origin_x_mm', CoordToMMs(Board.XOrigin)) + ',' +
          JsonNum('origin_y_mm', CoordToMMs(Board.YOrigin)) + ',' +
          JsonNum('outline_left_mm',   CoordToMMs(Board.BoundingRectangle.Left)) + ',' +
          JsonNum('outline_bottom_mm', CoordToMMs(Board.BoundingRectangle.Bottom)) + ',' +
          JsonNum('outline_right_mm',  CoordToMMs(Board.BoundingRectangle.Right)) + ',' +
          JsonNum('outline_top_mm',    CoordToMMs(Board.BoundingRectangle.Top)) +
    '}');
end;


function OpPcbListComponents(Flat : TStringList; const P, OpId : string) : string;
var
  Board    : IPCB_Board;
  Iterator : IPCB_BoardIterator;
  Comp     : IPCB_Component;
  Filter   : string;
  Items    : string;
  Count    : Integer;
  Guard    : string;
  SideText : string;
  Unplaced : Boolean;
  OnlyUnplaced : Boolean;
  Xmm, Ymm : Extended;
begin
  Guard := PcbBoardOrFail(OpId, Board);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Filter := UpperCase(ArgStr(Flat, P, 'designator_filter', ''));
  OnlyUnplaced := ArgBool(Flat, P, 'unplaced_only', False);
  Items := '';
  Count := 0;

  Iterator := Board.BoardIterator_Create;
  try
    Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
    Iterator.AddFilter_LayerSet(AllLayers);
    Iterator.AddFilter_Method(eProcessAll);
    Comp := Iterator.FirstPCBObject;
    while Comp <> Nil do
    begin
      Xmm := CoordToMMs(Comp.x);
      Ymm := CoordToMMs(Comp.y);

      { "Unplaced" in practice means sitting outside the board outline, which
        is where an ECO dumps new footprints. }
      Unplaced := (Comp.x < Board.BoundingRectangle.Left) or
                  (Comp.x > Board.BoundingRectangle.Right) or
                  (Comp.y < Board.BoundingRectangle.Bottom) or
                  (Comp.y > Board.BoundingRectangle.Top);

      if Comp.Layer = eBottomLayer then SideText := 'bottom' else SideText := 'top';

      if ((Filter = '') or (Copy(UpperCase(Comp.Name.Text), 1, Length(Filter)) = Filter))
         and ((not OnlyUnplaced) or Unplaced) then
      begin
        if Items <> '' then Items := Items + ',';
        Items := Items + '{' +
          JsonStr('designator', Comp.Name.Text) + ',' +
          JsonStr('footprint', Comp.Pattern) + ',' +
          JsonNum('x_mm', Xmm) + ',' +
          JsonNum('y_mm', Ymm) + ',' +
          JsonNum('rotation', Comp.Rotation) + ',' +
          JsonStr('layer', SideText) + ',' +
          JsonBool('locked', Comp.Moveable = False) + ',' +
          JsonBool('outside_outline', Unplaced) +
        '}';
        Inc(Count);
      end;
      Comp := Iterator.NextPCBObject;
    end;
  finally
    Board.BoardIterator_Destroy(Iterator);
  end;

  Result := OpOk(OpId,
    '{' + JsonInt('count', Count) + ',"components":[' + Items + ']}');
end;


function OpPcbGetComponent(Flat : TStringList; const P, OpId : string) : string;
var
  Board : IPCB_Board;
  Comp  : IPCB_Component;
  Desig : string;
  Guard : string;
  SideText : string;
begin
  Guard := PcbBoardOrFail(OpId, Board);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Desig := ArgStr(Flat, P, 'designator', '');
  Comp := PcbFindComponent(Board, Desig);
  if Comp = Nil then
  begin
    Result := OpFail(OpId, 'No PCB component with designator ' + Desig);
    Exit;
  end;

  if Comp.Layer = eBottomLayer then SideText := 'bottom' else SideText := 'top';

  Result := OpOk(OpId,
    '{' + JsonStr('designator', Comp.Name.Text) + ',' +
          JsonStr('footprint', Comp.Pattern) + ',' +
          JsonStr('source_designator', Comp.SourceDesignator) + ',' +
          JsonStr('source_unique_id', Comp.SourceUniqueId) + ',' +
          JsonNum('x_mm', CoordToMMs(Comp.x)) + ',' +
          JsonNum('y_mm', CoordToMMs(Comp.y)) + ',' +
          JsonNum('rotation', Comp.Rotation) + ',' +
          JsonStr('layer', SideText) + ',' +
          JsonNum('width_mm',
            CoordToMMs(Comp.BoundingRectangle.Right - Comp.BoundingRectangle.Left)) + ',' +
          JsonNum('height_mm',
            CoordToMMs(Comp.BoundingRectangle.Top - Comp.BoundingRectangle.Bottom)) +
    '}');
end;


{ -------------------------------------------------------------- writing }

function OpPcbMoveComponent(Flat : TStringList; const P, OpId : string) : string;
var
  Board : IPCB_Board;
  Comp  : IPCB_Component;
  Desig : string;
  Guard : string;
  WantBottom : Boolean;
begin
  Guard := PcbBoardOrFail(OpId, Board);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Desig := ArgStr(Flat, P, 'designator', '');
  Comp := PcbFindComponent(Board, Desig);
  if Comp = Nil then
  begin
    Result := OpFail(OpId,
      'No PCB component with designator ' + Desig +
      '. If it is new on the schematic, run pcb_update_from_schematic first.');
    Exit;
  end;

  if not Comp.Moveable then
  begin
    Result := OpFail(OpId, Desig + ' is locked. Unlock it with pcb_lock_component first.');
    Exit;
  end;

  PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast,
                                PCBM_BeginModify, c_NoEventData);
  try
    Comp.x := MMsToCoord(ArgFloat(Flat, P, 'x_mm', CoordToMMs(Comp.x)));
    Comp.y := MMsToCoord(ArgFloat(Flat, P, 'y_mm', CoordToMMs(Comp.y)));
    Comp.Rotation := ArgFloat(Flat, P, 'rotation', Comp.Rotation);

    if JHas(Flat, P + '.layer') then
    begin
      WantBottom := ArgLayerIsBottom(Flat, P);
      if WantBottom and (Comp.Layer <> eBottomLayer) then Comp.Layer := eBottomLayer
      else if (not WantBottom) and (Comp.Layer <> eTopLayer) then Comp.Layer := eTopLayer;
    end;
  finally
    PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast,
                                  PCBM_EndModify, c_NoEventData);
  end;

  Result := OpOk(OpId,
    '{' + JsonStr('designator', Desig) + ',' +
          JsonNum('x_mm', CoordToMMs(Comp.x)) + ',' +
          JsonNum('y_mm', CoordToMMs(Comp.y)) + ',' +
          JsonNum('rotation', Comp.Rotation) + '}');
end;


function OpPcbLockComponent(Flat : TStringList; const P, OpId : string) : string;
var
  Board  : IPCB_Board;
  Comp   : IPCB_Component;
  Desig  : string;
  Locked : Boolean;
  Guard  : string;
begin
  Guard := PcbBoardOrFail(OpId, Board);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Desig := ArgStr(Flat, P, 'designator', '');
  Comp := PcbFindComponent(Board, Desig);
  if Comp = Nil then
  begin
    Result := OpFail(OpId, 'No PCB component with designator ' + Desig);
    Exit;
  end;

  Locked := ArgBool(Flat, P, 'locked', True);
  PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast,
                                PCBM_BeginModify, c_NoEventData);
  try
    Comp.Moveable := not Locked;
  finally
    PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast,
                                  PCBM_EndModify, c_NoEventData);
  end;

  Result := OpOk(OpId, '{' + JsonStr('designator', Desig) + ',' +
                             JsonBool('locked', Locked) + '}');
end;


function OpPcbSetOrigin(Flat : TStringList; const P, OpId : string) : string;
var
  Board : IPCB_Board;
  Guard : string;
begin
  Guard := PcbBoardOrFail(OpId, Board);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Board.XOrigin := MMsToCoord(ArgFloat(Flat, P, 'x_mm', 0.0));
  Board.YOrigin := MMsToCoord(ArgFloat(Flat, P, 'y_mm', 0.0));
  Board.ViewManager_FullUpdate;

  Result := OpOk(OpId,
    '{' + JsonNum('origin_x_mm', CoordToMMs(Board.XOrigin)) + ',' +
          JsonNum('origin_y_mm', CoordToMMs(Board.YOrigin)) + '}');
end;


function OpPcbUpdateFromSchematic(Flat : TStringList; const P, OpId : string) : string;
begin
  if ArgBool(Flat, P, 'dry_run', False) then
  begin
    Result := OpFail(OpId,
      'A dry-run ECO cannot be reported from script. Run it without dry_run, ' +
      'or use Design > Update PCB Document and review the dialog.');
    Exit;
  end;

  try
    ResetParameters;
    AddStringParameter('Action', 'DesignToPCB');
    RunProcess('WorkspaceManager:Update');
    Result := OpOk(OpId,
      '{' + JsonStr('status', 'ECO dispatched') + ',' +
            JsonStr('note',
              'Altium may have shown the Engineering Change Order dialog. ' +
              'Check it was applied, then call pcb_list_components.') + '}');
  except
    Result := OpFail(OpId,
      'Could not run the ECO from script. Use Design > Update PCB Document.');
  end;
end;


function OpPcbRunDrc(Flat : TStringList; const P, OpId : string) : string;
begin
  try
    ResetParameters;
    RunProcess('PCB:DesignRuleCheck');
    Result := OpOk(OpId,
      '{' + JsonStr('status', 'DRC dispatched') + ',' +
            JsonStr('note',
              'Violations are in the Messages panel. Structured DRC results ' +
              'are not available from script yet - see docs/roadmap.md.') + '}');
  except
    Result := OpFail(OpId, 'Could not run DRC - use Tools > Design Rule Check.');
  end;
end;


{ Not yet implemented - see docs/roadmap.md. }

function OpPcbPlaceComponent(Flat : TStringList; const P, OpId : string) : string;
begin
  Result := OpFail(OpId,
    'pcb.place_component is not implemented yet. Components that exist on the ' +
    'schematic reach the board via pcb_update_from_schematic, then move them ' +
    'with pcb_move_component.');
end;


function OpPcbCreateRoom(Flat : TStringList; const P, OpId : string) : string;
begin
  Result := OpFail(OpId, 'pcb.create_room is not implemented yet.');
end;


function OpPcbPlaceBoardOutline(Flat : TStringList; const P, OpId : string) : string;
begin
  Result := OpFail(OpId, 'pcb.place_board_outline is not implemented yet.');
end;
