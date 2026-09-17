{ OpsSch - schematic op handlers.

  VERIFICATION NOTE
  -----------------
  OpSchPlaceComponent is the handler most likely to need adjusting on your
  build. Altium offers several ways to get a library part onto a sheet and
  they differ across versions. This uses the object-factory route, which
  reliably creates the component and its identity (LibReference, designator,
  parameters); depending on the build, the symbol graphics may only resolve
  after Altium links the part to its library.

  The result of every place includes "symbol_resolved" so the agent can tell
  the engineer when a part landed as a placeholder rather than silently
  leaving a broken symbol on the sheet.

  Run Probe.pas first. See docs/altium-api.md.
}


function SchDocOrFail(const OpId : string; var Doc : ISch_Document) : string;
begin
  Result := '';
  Doc := Ops_CurrentSch;
  if Doc = Nil then
    Result := OpFail(OpId, 'No schematic document is focused. Open a .SchDoc first.');
end;


{ Find a component on the focused sheet by designator. }
function SchFindComponent(Doc : ISch_Document; const Designator : string) : ISch_Component;
var
  Iterator : ISch_Iterator;
  Comp     : ISch_Component;
begin
  Result := Nil;
  Iterator := Doc.SchIterator_Create;
  if Iterator = Nil then Exit;
  try
    Iterator.AddFilter_ObjectSet(MkSet(eSchComponent));
    Comp := Iterator.FirstSchObject;
    while Comp <> Nil do
    begin
      if UpperCase(Comp.Designator.Text) = UpperCase(Designator) then
      begin
        Result := Comp;
        Exit;
      end;
      Comp := Iterator.NextSchObject;
    end;
  finally
    Doc.SchIterator_Destroy(Iterator);
  end;
end;


{ -------------------------------------------------------------- reading }

function OpSchListComponents(Flat : TStringList; const P, OpId : string) : string;
var
  Doc      : ISch_Document;
  Iterator : ISch_Iterator;
  Comp     : ISch_Component;
  Filter   : string;
  Items    : string;
  Entry    : string;
  Count    : Integer;
  Guard    : string;
begin
  Guard := SchDocOrFail(OpId, Doc);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Filter := UpperCase(ArgStr(Flat, P, 'designator_filter', ''));
  Items  := '';
  Count  := 0;

  Iterator := Doc.SchIterator_Create;
  if Iterator = Nil then
  begin
    Result := OpFail(OpId, 'Could not create a schematic iterator');
    Exit;
  end;
  try
    Iterator.AddFilter_ObjectSet(MkSet(eSchComponent));
    Comp := Iterator.FirstSchObject;
    while Comp <> Nil do
    begin
      if (Filter = '') or
         (Copy(UpperCase(Comp.Designator.Text), 1, Length(Filter)) = Filter) then
      begin
        Entry := '{' +
          JsonStr('designator', Comp.Designator.Text) + ',' +
          JsonStr('lib_reference', Comp.LibReference) + ',' +
          JsonStr('comment', Comp.Comment.Text) + ',' +
          JsonNum('x_mm', CoordToMMs(Comp.Location.X)) + ',' +
          JsonNum('y_mm', CoordToMMs(Comp.Location.Y)) + ',' +
          JsonInt('pins', Comp.GetState_PinCount) +
          '}';
        if Items <> '' then Items := Items + ',';
        Items := Items + Entry;
        Inc(Count);
      end;
      Comp := Iterator.NextSchObject;
    end;
  finally
    Doc.SchIterator_Destroy(Iterator);
  end;

  Result := OpOk(OpId,
    '{' + JsonStr('document', Doc.DocumentName) + ',' +
          JsonInt('count', Count) + ',' +
          '"components":[' + Items + ']}');
end;


function OpSchListNets(Flat : TStringList; const P, OpId : string) : string;
var
  Doc      : ISch_Document;
  Iterator : ISch_Iterator;
  Obj      : ISch_NetLabel;
  Items    : string;
  Guard    : string;
begin
  Guard := SchDocOrFail(OpId, Doc);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  { Net labels are the tractable part of connectivity from script. Full net
    extraction needs the compiled project netlist, which is a later milestone
    - see docs/roadmap.md. }
  Items := '';
  Iterator := Doc.SchIterator_Create;
  try
    Iterator.AddFilter_ObjectSet(MkSet(eNetLabel));
    Obj := Iterator.FirstSchObject;
    while Obj <> Nil do
    begin
      if Items <> '' then Items := Items + ',';
      Items := Items + '{' +
        JsonStr('net', Obj.Text) + ',' +
        JsonNum('x_mm', CoordToMMs(Obj.Location.X)) + ',' +
        JsonNum('y_mm', CoordToMMs(Obj.Location.Y)) + '}';
      Obj := Iterator.NextSchObject;
    end;
  finally
    Doc.SchIterator_Destroy(Iterator);
  end;

  Result := OpOk(OpId,
    '{"net_labels":[' + Items + '],' +
     JsonStr('note', 'Net labels only. Full connectivity requires a compiled project.') +
     '}');
end;


{ -------------------------------------------------------------- writing }

function OpSchPlaceComponent(Flat : TStringList; const P, OpId : string) : string;
var
  Doc       : ISch_Document;
  Comp      : ISch_Component;
  Existing  : ISch_Component;
  Keys      : TStringList;
  I         : Integer;
  Param     : ISch_Parameter;
  Designator: string;
  LibName   : string;
  ItemId    : string;
  Guard     : string;
  Resolved  : Boolean;
begin
  Guard := SchDocOrFail(OpId, Doc);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Designator := ArgStr(Flat, P, 'designator', '');
  LibName    := ArgStr(Flat, P, 'library', '');
  ItemId     := ArgStr(Flat, P, 'design_item_id', '');

  if (Designator = '') or (ItemId = '') then
  begin
    Result := OpFail(OpId, 'designator and design_item_id are both required');
    Exit;
  end;

  Existing := SchFindComponent(Doc, Designator);
  if Existing <> Nil then
  begin
    Result := OpFail(OpId,
      'Designator ' + Designator + ' is already used on this sheet. ' +
      'Call sch_list_components to find a free one.');
    Exit;
  end;

  Comp := SchServer.SchObjectFactory(eSchComponent, eCreate_GlobalCopy);
  if Comp = Nil then
  begin
    Result := OpFail(OpId, 'SchObjectFactory would not create a component');
    Exit;
  end;

  Comp.LibReference    := ItemId;
  Comp.DesignItemId    := ItemId;
  Comp.LibraryPath     := LibName;
  Comp.Designator.Text := Designator;
  Comp.Location        := Point(
    MMsToCoord(ArgFloat(Flat, P, 'x_mm', 0.0)),
    MMsToCoord(ArgFloat(Flat, P, 'y_mm', 0.0))
  );
  Comp.Orientation := SchRotationOf(ArgInt(Flat, P, 'rotation', 0));

  { Parameters arrive as a JSON map, so the keys are discovered rather than
    known ahead of time. }
  Keys := TStringList.Create;
  try
    JChildKeys(Flat, P + '.parameters', Keys);
    for I := 0 to Keys.Count - 1 do
    begin
      Param := SchServer.SchObjectFactory(eParameter, eCreate_GlobalCopy);
      if Param <> Nil then
      begin
        Param.Name  := Keys[I];
        Param.Text  := JGet(Flat, P + '.parameters.' + Keys[I], '');
        Param.Location := Comp.Location;
        Comp.AddSchObject(Param);
      end;
    end;
  finally
    Keys.Free;
  end;

  Doc.RegisterSchObjectInContainer(Comp);
  Doc.GraphicallyInvalidate;

  { Did the part actually resolve to a library symbol, or is it a shell? }
  Resolved := Comp.GetState_PinCount > 0;

  Result := OpOk(OpId,
    '{' + JsonStr('designator', Designator) + ',' +
          JsonStr('design_item_id', ItemId) + ',' +
          JsonBool('symbol_resolved', Resolved) + ',' +
          JsonStr('note',
            'If symbol_resolved is false the part was placed as a shell - ' +
            'run Tools > Update From Libraries, or check the library name.') +
    '}');
end;


function OpSchPlaceWire(Flat : TStringList; const P, OpId : string) : string;
var
  Doc     : ISch_Document;
  Wire    : ISch_Wire;
  Count   : Integer;
  I       : Integer;
  Guard   : string;
begin
  Guard := SchDocOrFail(OpId, Doc);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Count := JCount(Flat, P + '.points_mm');
  if Count < 2 then
  begin
    Result := OpFail(OpId, 'A wire needs at least two points');
    Exit;
  end;

  Wire := SchServer.SchObjectFactory(eWire, eCreate_GlobalCopy);
  if Wire = Nil then
  begin
    Result := OpFail(OpId, 'SchObjectFactory would not create a wire');
    Exit;
  end;

  Wire.VerticesCount := Count;
  for I := 0 to Count - 1 do
    Wire.Vertex[I + 1] := Point(
      MMsToCoord(JFloat(Flat, P + '.points_mm.' + IntToStr(I) + '.0', 0.0)),
      MMsToCoord(JFloat(Flat, P + '.points_mm.' + IntToStr(I) + '.1', 0.0))
    );

  Doc.RegisterSchObjectInContainer(Wire);
  Doc.GraphicallyInvalidate;

  Result := OpOk(OpId, '{' + JsonInt('vertices', Count) + '}');
end;


function OpSchPlaceNetLabel(Flat : TStringList; const P, OpId : string) : string;
var
  Doc   : ISch_Document;
  Label_: ISch_NetLabel;
  Name  : string;
  Guard : string;
begin
  Guard := SchDocOrFail(OpId, Doc);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Name := ArgStr(Flat, P, 'net_name', '');
  if Name = '' then
  begin
    Result := OpFail(OpId, 'net_name is required');
    Exit;
  end;

  Label_ := SchServer.SchObjectFactory(eNetLabel, eCreate_GlobalCopy);
  if Label_ = Nil then
  begin
    Result := OpFail(OpId, 'SchObjectFactory would not create a net label');
    Exit;
  end;

  Label_.Text := Name;
  Label_.Location := Point(
    MMsToCoord(ArgFloat(Flat, P, 'x_mm', 0.0)),
    MMsToCoord(ArgFloat(Flat, P, 'y_mm', 0.0))
  );
  Label_.Orientation := SchRotationOf(ArgInt(Flat, P, 'rotation', 0));

  Doc.RegisterSchObjectInContainer(Label_);
  Doc.GraphicallyInvalidate;

  Result := OpOk(OpId, '{' + JsonStr('net', Name) + '}');
end;


function OpSchPlacePowerPort(Flat : TStringList; const P, OpId : string) : string;
var
  Doc   : ISch_Document;
  Port  : ISch_PowerObject;
  Name  : string;
  Style : string;
  Guard : string;
begin
  Guard := SchDocOrFail(OpId, Doc);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Name := ArgStr(Flat, P, 'net_name', '');
  if Name = '' then
  begin
    Result := OpFail(OpId, 'net_name is required');
    Exit;
  end;

  Port := SchServer.SchObjectFactory(ePowerObject, eCreate_GlobalCopy);
  if Port = Nil then
  begin
    Result := OpFail(OpId, 'SchObjectFactory would not create a power port');
    Exit;
  end;

  Port.Text := Name;
  Port.Location := Point(
    MMsToCoord(ArgFloat(Flat, P, 'x_mm', 0.0)),
    MMsToCoord(ArgFloat(Flat, P, 'y_mm', 0.0))
  );
  Port.Orientation := SchRotationOf(ArgInt(Flat, P, 'rotation', 0));

  Style := LowerCase(ArgStr(Flat, P, 'style', 'bar'));
  if Style = 'circle' then Port.Style := ePowerCircle
  else if Style = 'arrow' then Port.Style := ePowerArrow
  else if Style = 'wave' then Port.Style := ePowerWave
  else if Style = 'power_ground' then Port.Style := ePowerGndPower
  else if Style = 'signal_ground' then Port.Style := ePowerGndSignal
  else if Style = 'earth' then Port.Style := ePowerGndEarth
  else Port.Style := ePowerBar;

  Doc.RegisterSchObjectInContainer(Port);
  Doc.GraphicallyInvalidate;

  Result := OpOk(OpId, '{' + JsonStr('net', Name) + ',' + JsonStr('style', Style) + '}');
end;


function OpSchSetParameter(Flat : TStringList; const P, OpId : string) : string;
var
  Doc   : ISch_Document;
  Comp  : ISch_Component;
  Param : ISch_Parameter;
  Name  : string;
  Value : string;
  Guard : string;
begin
  Guard := SchDocOrFail(OpId, Doc);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Comp := SchFindComponent(Doc, ArgStr(Flat, P, 'designator', ''));
  if Comp = Nil then
  begin
    Result := OpFail(OpId,
      'No component with designator ' + ArgStr(Flat, P, 'designator', '(blank)'));
    Exit;
  end;

  Name  := ArgStr(Flat, P, 'name', '');
  Value := ArgStr(Flat, P, 'value', '');
  if Name = '' then
  begin
    Result := OpFail(OpId, 'Parameter name is required');
    Exit;
  end;

  { Comment and Designator are not ordinary parameters. }
  if UpperCase(Name) = 'COMMENT' then
  begin
    Comp.Comment.Text := Value;
    Doc.GraphicallyInvalidate;
    Result := OpOk(OpId, '{' + JsonStr('set', 'Comment') + '}');
    Exit;
  end;

  Param := SchServer.SchObjectFactory(eParameter, eCreate_GlobalCopy);
  if Param = Nil then
  begin
    Result := OpFail(OpId, 'SchObjectFactory would not create a parameter');
    Exit;
  end;
  Param.Name       := Name;
  Param.Text       := Value;
  Param.Location   := Comp.Location;
  Param.IsHidden   := not ArgBool(Flat, P, 'visible', True);
  Comp.AddSchObject(Param);
  Doc.GraphicallyInvalidate;

  Result := OpOk(OpId, '{' + JsonStr('set', Name) + ',' + JsonStr('value', Value) + '}');
end;


function OpSchDeleteObject(Flat : TStringList; const P, OpId : string) : string;
var
  Doc   : ISch_Document;
  Comp  : ISch_Component;
  Desig : string;
  Guard : string;
begin
  Guard := SchDocOrFail(OpId, Doc);
  if Guard <> '' then
  begin
    Result := Guard;
    Exit;
  end;

  Desig := ArgStr(Flat, P, 'designator', '');
  Comp := SchFindComponent(Doc, Desig);
  if Comp = Nil then
  begin
    Result := OpFail(OpId, 'No component with designator ' + Desig);
    Exit;
  end;

  Doc.RemoveSchObject(Comp);
  Doc.GraphicallyInvalidate;
  Result := OpOk(OpId, '{' + JsonStr('deleted', Desig) + '}');
end;


function OpSchAnnotate(Flat : TStringList; const P, OpId : string) : string;
var
  Scope : string;
begin
  Scope := ArgStr(Flat, P, 'scope', 'current_sheet');
  try
    ResetParameters;
    if Scope = 'whole_project' then
    begin
      AddStringParameter('Mode', 'Update');
      RunProcess('Sch:AnnotateProject');
    end
    else
      RunProcess('Sch:AnnotateSheet');
    Result := OpOk(OpId, '{' + JsonStr('scope', Scope) + '}');
  except
    Result := OpFail(OpId, 'Annotation process failed - run it from the Tools menu instead');
  end;
end;


{ set_net_name needs pin coordinate lookup to place labels on the right
  wires. Deferred - see docs/roadmap.md. }
function OpSchSetNetName(Flat : TStringList; const P, OpId : string) : string;
begin
  Result := OpFail(OpId,
    'sch.set_net_name is not implemented yet. Place a net label at the wire ' +
    'coordinate with sch_place_net_label instead.');
end;


function OpSchPlacePort(Flat : TStringList; const P, OpId : string) : string;
begin
  Result := OpFail(OpId, 'sch.place_port is not implemented yet.');
end;
