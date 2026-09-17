{ JsonLite - minimal JSON for DelphiScript.

  DelphiScript cannot declare new classes or records, so there is no tree to
  build. Instead the parser FLATTENS a document into a TStringList of
  Name=Value pairs with dotted paths:

      {"ops":[{"op":"sch.place_component","args":{"x_mm":120.5}}]}

  becomes

      ops.0.op=sch.place_component
      ops.0.args.x_mm=120.5
      ops.#=1

  Lookups are then just Flat.Values['ops.0.args.x_mm'], which is fast enough
  and needs no types. Array lengths are stored under '<path>.#'.

  Limitations, all acceptable for this protocol:
    - values have CR/LF collapsed to spaces so TStringList.Values works
    - no distinction between 5 and "5"; callers coerce
    - nulls become empty strings
}

const
  JSON_OK      = 0;
  JSON_BAD     = 1;

var
  JsonErr : string;


function JsonEscape(const S : string) : string;
var
  I  : Integer;
  Ch : string;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    Ch := Copy(S, I, 1);
    if Ch = '"' then Result := Result + '\"'
    else if Ch = '\' then Result := Result + '\\'
    else if Ch = #13 then Result := Result + '\r'
    else if Ch = #10 then Result := Result + '\n'
    else if Ch = #9  then Result := Result + '\t'
    else Result := Result + Ch;
  end;
end;


function JsonStr(const Name, Value : string) : string;
begin
  Result := '"' + JsonEscape(Name) + '":"' + JsonEscape(Value) + '"';
end;


function JsonRaw(const Name, Value : string) : string;
begin
  Result := '"' + JsonEscape(Name) + '":' + Value;
end;


function JsonBool(const Name : string; Value : Boolean) : string;
begin
  if Value then Result := JsonRaw(Name, 'true')
  else Result := JsonRaw(Name, 'false');
end;


function JsonNum(const Name : string; Value : Extended) : string;
var
  S : string;
begin
  S := FloatToStr(Value);
  { Altium may be running under a locale using a decimal comma. JSON is not. }
  S := StringReplace(S, ',', '.', MkSet(rfReplaceAll));
  Result := JsonRaw(Name, S);
end;


function JsonInt(const Name : string; Value : Integer) : string;
begin
  Result := JsonRaw(Name, IntToStr(Value));
end;


{ ---------------------------------------------------------------- parsing }

var
  JsonText : string;
  JsonPos  : Integer;
  JsonFlat : TStringList;


procedure JsonSkipWhite;
var
  Ch : string;
begin
  while JsonPos <= Length(JsonText) do
  begin
    Ch := Copy(JsonText, JsonPos, 1);
    if (Ch = ' ') or (Ch = #9) or (Ch = #13) or (Ch = #10) then
      Inc(JsonPos)
    else
      Break;
  end;
end;


function JsonPeek : string;
begin
  if JsonPos <= Length(JsonText) then
    Result := Copy(JsonText, JsonPos, 1)
  else
    Result := '';
end;


function JsonParseString : string;
var
  Ch : string;
  Code : Integer;
begin
  Result := '';
  Inc(JsonPos);                          { opening quote }
  while JsonPos <= Length(JsonText) do
  begin
    Ch := Copy(JsonText, JsonPos, 1);
    if Ch = '"' then
    begin
      Inc(JsonPos);
      Exit;
    end
    else if Ch = '\' then
    begin
      Inc(JsonPos);
      Ch := Copy(JsonText, JsonPos, 1);
      if Ch = 'n' then Result := Result + ' '
      else if Ch = 'r' then Result := Result + ' '
      else if Ch = 't' then Result := Result + ' '
      else if Ch = 'u' then
      begin
        { \uXXXX - only the Latin-1 range is meaningful for designators }
        Code := StrToIntDef('$' + Copy(JsonText, JsonPos + 1, 4), 32);
        if (Code > 31) and (Code < 256) then Result := Result + Chr(Code)
        else Result := Result + '?';
        Inc(JsonPos, 4);
      end
      else Result := Result + Ch;
      Inc(JsonPos);
    end
    else
    begin
      Result := Result + Ch;
      Inc(JsonPos);
    end;
  end;
  JsonErr := 'Unterminated string';
end;


function JsonParseLiteral : string;
var
  Ch : string;
begin
  Result := '';
  while JsonPos <= Length(JsonText) do
  begin
    Ch := Copy(JsonText, JsonPos, 1);
    if (Ch = ',') or (Ch = '}') or (Ch = ']') or (Ch = ' ') or
       (Ch = #9) or (Ch = #13) or (Ch = #10) then Break;
    Result := Result + Ch;
    Inc(JsonPos);
  end;
  if Result = 'null' then Result := '';
end;


procedure JsonStore(const Path, Value : string);
begin
  if Path <> '' then
    JsonFlat.Add(Path + '=' + Value);
end;


procedure JsonParseValue(const Path : string); forward;


procedure JsonParseObject(const Path : string);
var
  Key   : string;
  Child : string;
begin
  Inc(JsonPos);                          { '{' }
  JsonSkipWhite;
  if JsonPeek = '}' then
  begin
    Inc(JsonPos);
    Exit;
  end;

  while JsonPos <= Length(JsonText) do
  begin
    JsonSkipWhite;
    if JsonPeek <> '"' then
    begin
      JsonErr := 'Expected object key at ' + IntToStr(JsonPos);
      Exit;
    end;
    Key := JsonParseString;

    JsonSkipWhite;
    if JsonPeek <> ':' then
    begin
      JsonErr := 'Expected colon at ' + IntToStr(JsonPos);
      Exit;
    end;
    Inc(JsonPos);

    if Path = '' then Child := Key else Child := Path + '.' + Key;
    JsonSkipWhite;
    JsonParseValue(Child);
    if JsonErr <> '' then Exit;

    JsonSkipWhite;
    if JsonPeek = ',' then
    begin
      Inc(JsonPos);
      Continue;
    end;
    if JsonPeek = '}' then
    begin
      Inc(JsonPos);
      Exit;
    end;
    JsonErr := 'Expected , or } at ' + IntToStr(JsonPos);
    Exit;
  end;
end;


procedure JsonParseArray(const Path : string);
var
  Index : Integer;
begin
  Inc(JsonPos);                          { '[' }
  Index := 0;
  JsonSkipWhite;
  if JsonPeek = ']' then
  begin
    Inc(JsonPos);
    JsonStore(Path + '.#', '0');
    Exit;
  end;

  while JsonPos <= Length(JsonText) do
  begin
    JsonSkipWhite;
    JsonParseValue(Path + '.' + IntToStr(Index));
    if JsonErr <> '' then Exit;
    Inc(Index);

    JsonSkipWhite;
    if JsonPeek = ',' then
    begin
      Inc(JsonPos);
      Continue;
    end;
    if JsonPeek = ']' then
    begin
      Inc(JsonPos);
      JsonStore(Path + '.#', IntToStr(Index));
      Exit;
    end;
    JsonErr := 'Expected , or ] at ' + IntToStr(JsonPos);
    Exit;
  end;
end;


procedure JsonParseValue(const Path : string);
var
  Ch : string;
begin
  JsonSkipWhite;
  Ch := JsonPeek;
  if Ch = '{' then JsonParseObject(Path)
  else if Ch = '[' then JsonParseArray(Path)
  else if Ch = '"' then JsonStore(Path, JsonParseString)
  else JsonStore(Path, JsonParseLiteral);
end;


{ Parse Text into Flat. Returns True on success; JsonErr holds the reason. }
function JsonFlatten(const Text : string; Flat : TStringList) : Boolean;
begin
  JsonText := Text;
  JsonPos  := 1;
  JsonErr  := '';
  JsonFlat := Flat;
  Flat.Clear;

  JsonParseValue('');

  Result := (JsonErr = '');
end;


{ ------------------------------------------------------------- accessors }

function JGet(Flat : TStringList; const Path, Default : string) : string;
var
  Index : Integer;
begin
  Index := Flat.IndexOfName(Path);
  if Index < 0 then Result := Default
  else Result := Copy(Flat[Index], Length(Path) + 2, MaxInt);
end;


function JHas(Flat : TStringList; const Path : string) : Boolean;
begin
  Result := Flat.IndexOfName(Path) >= 0;
end;


function JCount(Flat : TStringList; const Path : string) : Integer;
begin
  Result := StrToIntDef(JGet(Flat, Path + '.#', '0'), 0);
end;


function JFloat(Flat : TStringList; const Path : string; Default : Extended) : Extended;
var
  S : string;
begin
  S := Trim(JGet(Flat, Path, ''));
  if S = '' then
  begin
    Result := Default;
    Exit;
  end;
  { JSON always uses a dot; the local decimal separator may not. }
  S := StringReplace(S, '.', DecimalSeparator, MkSet(rfReplaceAll));
  Result := StrToFloatDef(S, Default);
end;


function JInt(Flat : TStringList; const Path : string; Default : Integer) : Integer;
begin
  Result := StrToIntDef(Trim(JGet(Flat, Path, '')), Default);
end;


function JBool(Flat : TStringList; const Path : string; Default : Boolean) : Boolean;
var
  S : string;
begin
  S := LowerCase(Trim(JGet(Flat, Path, '')));
  if S = 'true' then Result := True
  else if S = 'false' then Result := False
  else Result := Default;
end;


{ Collect the immediate child keys of an object path, e.g. every parameter
  name under 'ops.0.args.parameters'. }
procedure JChildKeys(Flat : TStringList; const Path : string; Keys : TStringList);
var
  I      : Integer;
  Prefix : string;
  Name   : string;
  Rest   : string;
  Dot    : Integer;
begin
  Keys.Clear;
  Prefix := Path + '.';
  for I := 0 to Flat.Count - 1 do
  begin
    Name := Flat.Names[I];
    if (Length(Name) > Length(Prefix)) and
       (Copy(Name, 1, Length(Prefix)) = Prefix) then
    begin
      Rest := Copy(Name, Length(Prefix) + 1, MaxInt);
      Dot := Pos('.', Rest);
      if Dot > 0 then Rest := Copy(Rest, 1, Dot - 1);
      if (Rest <> '#') and (Keys.IndexOf(Rest) < 0) then Keys.Add(Rest);
    end;
  end;
end;
