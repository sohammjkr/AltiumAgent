{ OpsDispatch - route an op name to its handler.

  Must be listed AFTER OpsSch.pas / OpsPcb.pas and BEFORE Bridge.pas in
  AltiumAgent.PrjScr.
}


{ ------------------------------------------------------- design.* ops }

function OpDesignStatus(Flat : TStringList; const P, OpId : string) : string;
var
  Workspace : IWorkspace;
  Project   : IProject;
  Sch       : ISch_Document;
  Board     : IPCB_Board;
  ProjName  : string;
  SchName   : string;
  PcbName   : string;
begin
  ProjName := '';
  try
    Workspace := GetWorkspace;
    if Workspace <> Nil then
    begin
      Project := Workspace.DM_FocusedProject;
      if Project <> Nil then ProjName := ExtractFileName(Project.DM_ProjectFileName);
    end;
  except
    ProjName := '';
  end;

  Sch := Ops_CurrentSch;
  if Sch = Nil then SchName := '' else SchName := Sch.DocumentName;

  Board := Ops_CurrentBoard;
  if Board = Nil then PcbName := '' else PcbName := ExtractFileName(Board.FileName);

  Result := OpOk(OpId,
    '{' + JsonStr('project', ProjName) + ',' +
          JsonStr('focused_schematic', SchName) + ',' +
          JsonStr('focused_pcb', PcbName) + ',' +
          '"open_documents":' + TP_OpenDocsJson + ',' +
          JsonStr('bridge_version', BRIDGE_VERSION) +
    '}');
end;


function OpDesignOpenDocument(Flat : TStringList; const P, OpId : string) : string;
var
  Name : string;
begin
  Name := ArgStr(Flat, P, 'document', '');
  if Name = '' then
  begin
    Result := OpFail(OpId, 'document is required');
    Exit;
  end;
  try
    ResetParameters;
    AddStringParameter('ObjectKind', 'Document');
    AddStringParameter('FileName', Name);
    RunProcess('WorkspaceManager:OpenObject');
    Result := OpOk(OpId, '{' + JsonStr('opened', Name) + '}');
  except
    Result := OpFail(OpId, 'Could not open ' + Name);
  end;
end;


function OpDesignSave(Flat : TStringList; const P, OpId : string) : string;
begin
  try
    ResetParameters;
    RunProcess('WorkspaceManager:SaveObject');
    Result := OpOk(OpId, '{' + JsonStr('status', 'save dispatched') + '}');
  except
    Result := OpFail(OpId, 'Save failed - use File > Save All.');
  end;
end;


{ ------------------------------------------------------- block.capture }

{ Read the current schematic selection as a candidate block. Python turns
  this into a block definition once the model has proposed refs. }
function OpBlockCapture(Flat : TStringList; const P, OpId : string) : string;
var
  Doc      : ISch_Document;
  Iterator : ISch_Iterator;
  Comp     : ISch_Component;
  Anchor   : ISch_Component;
  AnchorD  : string;
  Items    : string;
  Count    : Integer;
  AX, AY   : Extended;
begin
  Doc := Ops_CurrentSch;
  if Doc = Nil then
  begin
    Result := OpFail(OpId, 'No schematic document is focused.');
    Exit;
  end;

  AnchorD := UpperCase(ArgStr(Flat, P, 'anchor_designator', ''));
  Anchor := Nil;
  Count := 0;

  { First pass: find the anchor. Either the named component, or the
    lower-left of the selection. }
  Iterator := Doc.SchIterator_Create;
  try
    Iterator.AddFilter_ObjectSet(MkSet(eSchComponent));
    Comp := Iterator.FirstSchObject;
    while Comp <> Nil do
    begin
      if Comp.Selection then
      begin
        Inc(Count);
        if AnchorD <> '' then
        begin
          if UpperCase(Comp.Designator.Text) = AnchorD then Anchor := Comp;
        end
        else if (Anchor = Nil) or
                (Comp.Location.X + Comp.Location.Y <
                 Anchor.Location.X + Anchor.Location.Y) then
          Anchor := Comp;
      end;
      Comp := Iterator.NextSchObject;
    end;
  finally
    Doc.SchIterator_Destroy(Iterator);
  end;

  if Count = 0 then
  begin
    Result := OpFail(OpId,
      'Nothing is selected on the schematic. Select the components that make ' +
      'up the block, then try again.');
    Exit;
  end;
  if Anchor = Nil then
  begin
    Result := OpFail(OpId, 'Anchor component ' + AnchorD + ' is not in the selection.');
    Exit;
  end;

  AX := CoordToMMs(Anchor.Location.X);
  AY := CoordToMMs(Anchor.Location.Y);

  { Second pass: emit each selected component relative to the anchor. }
  Items := '';
  Iterator := Doc.SchIterator_Create;
  try
    Iterator.AddFilter_ObjectSet(MkSet(eSchComponent));
    Comp := Iterator.FirstSchObject;
    while Comp <> Nil do
    begin
      if Comp.Selection then
      begin
        if Items <> '' then Items := Items + ',';
        Items := Items + '{' +
          JsonStr('designator', Comp.Designator.Text) + ',' +
          JsonStr('library', Comp.LibraryPath) + ',' +
          JsonStr('design_item_id', Comp.DesignItemId) + ',' +
          JsonStr('comment', Comp.Comment.Text) + ',' +
          JsonNum('dx_mm', CoordToMMs(Comp.Location.X) - AX) + ',' +
          JsonNum('dy_mm', CoordToMMs(Comp.Location.Y) - AY) +
        '}';
      end;
      Comp := Iterator.NextSchObject;
    end;
  finally
    Doc.SchIterator_Destroy(Iterator);
  end;

  Result := OpOk(OpId,
    '{' + JsonStr('anchor_designator', Anchor.Designator.Text) + ',' +
          JsonInt('count', Count) + ',' +
          '"components":[' + Items + '],' +
          JsonStr('note',
            'Schematic capture only. PCB placement capture is not implemented ' +
            'yet - see docs/roadmap.md.') +
    '}');
end;


{ ------------------------------------------------------------- dispatch }

function Ops_Dispatch(Flat : TStringList; const OpPath : string) : string;
var
  Name : string;
  OpId : string;
  Args : string;
begin
  Name := JGet(Flat, OpPath + '.op', '');
  OpId := JGet(Flat, OpPath + '.id', 'unknown');
  Args := OpPath + '.args';

  try
    { design.* }
    if Name = 'design.status' then Result := OpDesignStatus(Flat, Args, OpId)
    else if Name = 'design.open_document' then Result := OpDesignOpenDocument(Flat, Args, OpId)
    else if Name = 'design.save' then Result := OpDesignSave(Flat, Args, OpId)

    { sch.* }
    else if Name = 'sch.list_components' then Result := OpSchListComponents(Flat, Args, OpId)
    else if Name = 'sch.list_nets' then Result := OpSchListNets(Flat, Args, OpId)
    else if Name = 'sch.place_component' then Result := OpSchPlaceComponent(Flat, Args, OpId)
    else if Name = 'sch.place_wire' then Result := OpSchPlaceWire(Flat, Args, OpId)
    else if Name = 'sch.place_net_label' then Result := OpSchPlaceNetLabel(Flat, Args, OpId)
    else if Name = 'sch.place_power_port' then Result := OpSchPlacePowerPort(Flat, Args, OpId)
    else if Name = 'sch.place_port' then Result := OpSchPlacePort(Flat, Args, OpId)
    else if Name = 'sch.set_parameter' then Result := OpSchSetParameter(Flat, Args, OpId)
    else if Name = 'sch.set_net_name' then Result := OpSchSetNetName(Flat, Args, OpId)
    else if Name = 'sch.delete_object' then Result := OpSchDeleteObject(Flat, Args, OpId)
    else if Name = 'sch.annotate' then Result := OpSchAnnotate(Flat, Args, OpId)

    { pcb.* }
    else if Name = 'pcb.board_info' then Result := OpPcbBoardInfo(Flat, Args, OpId)
    else if Name = 'pcb.list_components' then Result := OpPcbListComponents(Flat, Args, OpId)
    else if Name = 'pcb.get_component' then Result := OpPcbGetComponent(Flat, Args, OpId)
    else if Name = 'pcb.move_component' then Result := OpPcbMoveComponent(Flat, Args, OpId)
    else if Name = 'pcb.place_component' then Result := OpPcbPlaceComponent(Flat, Args, OpId)
    else if Name = 'pcb.lock_component' then Result := OpPcbLockComponent(Flat, Args, OpId)
    else if Name = 'pcb.set_origin' then Result := OpPcbSetOrigin(Flat, Args, OpId)
    else if Name = 'pcb.create_room' then Result := OpPcbCreateRoom(Flat, Args, OpId)
    else if Name = 'pcb.place_board_outline' then
      Result := OpPcbPlaceBoardOutline(Flat, Args, OpId)
    else if Name = 'pcb.update_from_schematic' then
      Result := OpPcbUpdateFromSchematic(Flat, Args, OpId)
    else if Name = 'pcb.run_drc' then Result := OpPcbRunDrc(Flat, Args, OpId)

    { block.* }
    else if Name = 'block.capture' then Result := OpBlockCapture(Flat, Args, OpId)

    else
      Result := OpFail(OpId, 'Unknown operation: ' + Name);
  except
    { An unhandled exception inside one op must not take down the batch, or
      the engineer is left with a half-applied change and no explanation. }
    Result := OpFail(OpId, 'Unhandled error in ' + Name +
                           '. See bridge.log and the Altium Messages panel.');
    TP_Log('EXCEPTION in op ' + Name + ' (' + OpId + ')');
  end;
end;
