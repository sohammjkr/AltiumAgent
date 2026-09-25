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

  DELPHISCRIPT CONSTRAINTS OBSERVED HERE
  --------------------------------------
  This file compiles first in AltiumAgent.PrjScr, so anything it does wrong
  takes the whole project down with it. Accordingly it avoids:

    - `forward` declarations. The parser is ONE self-recursive procedure
      rather than the usual mutually recursive value/object/array trio,
      because self-recursion needs no forward declaration.
    - two-argument Inc(x, n)  -> written as x := x + n
    - MaxInt                  -> explicit lengths
    - DecimalSeparator        -> floats are parsed digit by digit, so the
      machine's locale cannot silently mangle a coordinate. A decimal-comma
      locale turning 120.5 into 1205 mm would be a very expensive bug.
    - `const` parameter modifiers

  Other limitations, all acceptable for this protocol:
    - values have CR/LF collapsed to spaces so TStringList.Values works
    - no distinction between 5 and "5"; callers coerce
    - nulls become empty strings
}

var
  JsonErr  : string;
  JsonText : string;
  JsonPos  : Integer;
  JsonFlat : TStringList;


{ ------------------------------------------------------------- emitting }

function JsonEscape(S : string) : string;
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


function JsonStr(Name : string; Value : string) : string;
begin
  Result := '"' + JsonEscape(Name) + '":"' + JsonEscape(Value) + '"';
end;


function JsonRaw(Name : string; Value : string) : string;
begin
  Result := '"' + JsonEscape(Name) + '":' + Value;
end;


function JsonBool(Name : string; Value : Boolean) : string;
begin
  if Value then Result := JsonRaw(Name, 'true')
  else Result := JsonRaw(Name, 'false');
end;


{ Render a float with a literal '.' regardless of locale. }
function JsonFloatText(Value : Extended) : string;
var
  S : string;
  I : Integer;
  Ch : string;
begin
  S := FloatToStr(Value);
  Result := '';
  for I := 1 to Length(S) do
  begin
    Ch := Copy(S, I, 1);
    if Ch = ',' then Result := Result + '.'
    else Result := Result + Ch;
  end;
end;


function JsonNum(Name : string; Value : Extended) : string;
begin
  Result := JsonRaw(Name, JsonFloatText(Value));
end;


function JsonInt(Name : string; Value : Integer) : string;
begin
  Result := JsonRaw(Name, IntToStr(Value));
end;


{ -------------------------------------------------------------- parsing }

procedure JsonSkipWhite;
var
  Ch : string;
  Done : Boolean;
begin
  Done := False;
  while (JsonPos <= Length(JsonText)) and (not Done) do
  begin
    Ch := Copy(JsonText, JsonPos, 1);
    if (Ch = ' ') or (Ch = #9) or (Ch = #13) or (Ch = #10) then
      JsonPos := JsonPos + 1
    else
      Done := True;
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
  Ch   : string;
  Code : Integer;
  Done : Boolean;
begin
  Result := '';
  Done := False;
  JsonPos := JsonPos + 1;                { opening quote }
  while (JsonPos <= Length(JsonText)) and (not Done) do
  begin
    Ch := Copy(JsonText, JsonPos, 1);
    if Ch = '"' then
    begin
      JsonPos := JsonPos + 1;
      Done := True;
    end
    else if Ch = '\' then
    begin
      JsonPos := JsonPos + 1;
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
        JsonPos := JsonPos + 4;
      end
      else Result := Result + Ch;
      JsonPos := JsonPos + 1;
    end
    else
    begin
      Result := Result + Ch;
      JsonPos := JsonPos + 1;
    end;
  end;
  if not Done then JsonErr := 'Unterminated string';
end;


function JsonParseLiteral : string;
var
  Ch   : string;
  Done : Boolean;
begin
  Result := '';
  Done := False;
  while (JsonPos <= Length(JsonText)) and (not Done) do
  begin
    Ch := Copy(JsonText, JsonPos, 1);
    if (Ch = ',') or (Ch = '}') or (Ch = ']') or (Ch = ' ') or
       (Ch = #9) or (Ch = #13) or (Ch = #10) then
      Done := True
    else
    begin
      Result := Result + Ch;
      JsonPos := JsonPos + 1;
    end;
  end;
  if Result = 'null' then Result := '';
end;


procedure JsonStore(Path : string; Value : string);
begin
  if Path <> '' then
    JsonFlat.Add(Path + '=' + Value);
end;


{ ONE self-recursive procedure handling value, object and array.

  Written this way on purpose: the textbook shape is three mutually recursive
  procedures, which in Pascal requires a `forward` declaration that
  DelphiScript does not reliably support. A procedure that only calls itself
  needs no such declaration. }
procedure JsonParseInto(Path : string);
var
  Ch    : string;
  Key   : string;
  Child : string;
  Index : Integer;
  Done  : Boolean;
begin
  JsonSkipWhite;
  Ch := JsonPeek;

  if Ch = '{' then
  begin
    JsonPos := JsonPos + 1;
    JsonSkipWhite;
    if JsonPeek = '}' then
    begin
      JsonPos := JsonPos + 1;
      Exit;
    end;

    Done := False;
    while (JsonPos <= Length(JsonText)) and (not Done) do
    begin
      JsonSkipWhite;
      if JsonPeek <> '"' then
      begin
        JsonErr := 'Expected object key at ' + IntToStr(JsonPos);
        Exit;
      end;
      Key := JsonParseString;
      if JsonErr <> '' then Exit;

      JsonSkipWhite;
      if JsonPeek <> ':' then
      begin
        JsonErr := 'Expected colon at ' + IntToStr(JsonPos);
        Exit;
      end;
      JsonPos := JsonPos + 1;

      if Path = '' then Child := Key else Child := Path + '.' + Key;
      JsonParseInto(Child);
      if JsonErr <> '' then Exit;

      JsonSkipWhite;
      if JsonPeek = ',' then
        JsonPos := JsonPos + 1
      else if JsonPeek = '}' then
      begin
        JsonPos := JsonPos + 1;
        Done := True;
      end
      else
      begin
        JsonErr := 'Expected , or } at ' + IntToStr(JsonPos);
        Exit;
      end;
    end;
  end

  else if Ch = '[' then
  begin
    JsonPos := JsonPos + 1;
    Index := 0;
    JsonSkipWhite;
    if JsonPeek = ']' then
    begin
      JsonPos := JsonPos + 1;
      JsonStore(Path + '.#', '0');
      Exit;
    end;

    Done := False;
    while (JsonPos <= Length(JsonText)) and (not Done) do
    begin
      JsonSkipWhite;
      JsonParseInto(Path + '.' + IntToStr(Index));
      if JsonErr <> '' then Exit;
      Index := Index + 1;

      JsonSkipWhite;
      if JsonPeek = ',' then
        JsonPos := JsonPos + 1
      else if JsonPeek = ']' then
      begin
        JsonPos := JsonPos + 1;
        JsonStore(Path + '.#', IntToStr(Index));
        Done := True;
      end
      else
      begin
        JsonErr := 'Expected , or ] at ' + IntToStr(JsonPos);
        Exit;
      end;
    end;
  end

  else if Ch = '"' then
    JsonStore(Path, JsonParseString)

  else
    JsonStore(Path, JsonParseLiteral);
end;


{ Parse Text into Flat. Returns True on success; JsonErr holds the reason. }
function JsonFlatten(Text : string; Flat : TStringList) : Boolean;
begin
  JsonText := Text;
  JsonPos  := 1;
  JsonErr  := '';
  JsonFlat := Flat;
  Flat.Clear;

  JsonParseInto('');

  Result := (JsonErr = '');
end;


{ ------------------------------------------------------------- accessors }

function JGet(Flat : TStringList; Path : string; Default : string) : string;
var
  Index : Integer;
  Line  : string;
begin
  Index := Flat.IndexOfName(Path);
  if Index < 0 then
    Result := Default
  else
  begin
    Line := Flat[Index];
    Result := Copy(Line, Length(Path) + 2, Length(Line));
  end;
end;


function JHas(Flat : TStringList; Path : string) : Boolean;
begin
  Result := Flat.IndexOfName(Path) >= 0;
end;


function JCount(Flat : TStringList; Path : string) : Integer;
begin
  Result := StrToIntDef(JGet(Flat, Path + '.#', '0'), 0);
end;


{ Locale-independent float parse.

  Deliberately NOT StrToFloat: JSON always writes '.', but on a machine whose
  locale uses a decimal comma StrToFloat reads "120.5" as 1205. Every
  coordinate in this protocol is millimetres, so that bug would place parts a
  metre off the board and nothing would complain. Parsing the digits by hand
  removes the failure mode entirely. }
function JFloat(Flat : TStringList; Path : string; Default : Extended) : Extended;
var
  S        : string;
  I        : Integer;
  Ch       : string;
  IntPart  : Extended;
  FracPart : Extended;
  Scale    : Extended;
  Negative : Boolean;
  SeenDot  : Boolean;
  SeenNum  : Boolean;
begin
  S := Trim(JGet(Flat, Path, ''));
  if S = '' then
  begin
    Result := Default;
    Exit;
  end;

  IntPart  := 0;
  FracPart := 0;
  Scale    := 1;
  Negative := False;
  SeenDot  := False;
  SeenNum  := False;

  for I := 1 to Length(S) do
  begin
    Ch := Copy(S, I, 1);
    if (Ch = '-') and (I = 1) then
      Negative := True
    else if (Ch = '.') or (Ch = ',') then
      SeenDot := True
    else if (Ch >= '0') and (Ch <= '9') then
    begin
      SeenNum := True;
      if SeenDot then
      begin
        Scale := Scale / 10;
        FracPart := FracPart + (StrToInt(Ch) * Scale);
      end
      else
        IntPart := (IntPart * 10) + StrToInt(Ch);
    end
    else
    begin
      { Anything else (exponent, stray text) - fall back rather than guess. }
      Result := Default;
      Exit;
    end;
  end;

  if not SeenNum then
  begin
    Result := Default;
    Exit;
  end;

  Result := IntPart + FracPart;
  if Negative then Result := -Result;
end;


function JInt(Flat : TStringList; Path : string; Default : Integer) : Integer;
begin
  Result := StrToIntDef(Trim(JGet(Flat, Path, '')), Default);
end;


function JBool(Flat : TStringList; Path : string; Default : Boolean) : Boolean;
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
procedure JChildKeys(Flat : TStringList; Path : string; Keys : TStringList);
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
      Rest := Copy(Name, Length(Prefix) + 1, Length(Name));
      Dot := Pos('.', Rest);
      if Dot > 0 then Rest := Copy(Rest, 1, Dot - 1);
      if (Rest <> '#') and (Keys.IndexOf(Rest) < 0) then Keys.Add(Rest);
    end;
  end;
end;
