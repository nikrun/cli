unit nik.yaml;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nik.types;

type
  TYamlNodeKind = (ynkNull, ynkScalar, ynkSequence, ynkMapping);

  TYamlNode = class;
  TYamlNodeArray = array of TYamlNode;

  TYamlKeyValue = record
    Key: string;
    KeyLine: Integer;
    Value: TYamlNode;
  end;
  TYamlKeyValueArray = array of TYamlKeyValue;

  TYamlNode = class
  private
    FKind: TYamlNodeKind;
    FLine: Integer;
    FScalarValue: string;
    FQuoted: Boolean;
    FItems: TYamlNodeArray;
    FEntries: TYamlKeyValueArray;
  public
    constructor CreateNull(ALine: Integer);
    constructor CreateScalar(const AValue: string; AQuoted: Boolean; ALine: Integer);
    constructor CreateSequence(ALine: Integer);
    constructor CreateMapping(ALine: Integer);
    destructor Destroy; override;

    procedure AddItem(AItem: TYamlNode);
    procedure AddEntry(const AKey: string; AKeyLine: Integer; AValue: TYamlNode; const ASourceName: string);

    function Count: Integer;
    function GetItem(AIndex: Integer): TYamlNode;
    function EntryCount: Integer;
    function GetEntry(AIndex: Integer): TYamlKeyValue;
    function Find(const AKey: string): TYamlNode;
    function HasKey(const AKey: string): Boolean;

    function AsBoolean(out AVal: Boolean): Boolean;
    function AsInteger(out AVal: Integer): Boolean;

    property Kind: TYamlNodeKind read FKind;
    property Line: Integer read FLine;
    property ScalarValue: string read FScalarValue;
    property Quoted: Boolean read FQuoted;
  end;

function ParseYamlText(const AText: string; const ASourceName: string = 'nik.yaml'): TYamlNode;
function ParseYamlFile(const AFilePath: string): TYamlNode;

implementation

uses
  nik.fs;

type
  TYamlLine = record
    LineNo: Integer;
    Indent: Integer;
    Content: string; // Trimmed of leading spaces, trailing comments, and trailing whitespace
  end;
  TYamlLineArray = array of TYamlLine;

procedure RaiseYamlError(const ASourceName: string; ALine: Integer; const AMsg: string);
begin
  if ALine > 0 then
    raise ENikError.CreateFmt('%s:%d: %s', [ASourceName, ALine, AMsg])
  else
    raise ENikError.CreateFmt('%s: %s', [ASourceName, AMsg]);
end;

{ TYamlNode }

constructor TYamlNode.CreateNull(ALine: Integer);
begin
  inherited Create;
  FKind := ynkNull;
  FLine := ALine;
end;

constructor TYamlNode.CreateScalar(const AValue: string; AQuoted: Boolean; ALine: Integer);
begin
  inherited Create;
  FKind := ynkScalar;
  FScalarValue := AValue;
  FQuoted := AQuoted;
  FLine := ALine;
end;

constructor TYamlNode.CreateSequence(ALine: Integer);
begin
  inherited Create;
  FKind := ynkSequence;
  FLine := ALine;
end;

constructor TYamlNode.CreateMapping(ALine: Integer);
begin
  inherited Create;
  FKind := ynkMapping;
  FLine := ALine;
end;

destructor TYamlNode.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    FItems[I].Free;
  FItems := nil;

  for I := 0 to High(FEntries) do
    FEntries[I].Value.Free;
  FEntries := nil;

  inherited Destroy;
end;

procedure TYamlNode.AddItem(AItem: TYamlNode);
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N] := AItem;
end;

procedure TYamlNode.AddEntry(const AKey: string; AKeyLine: Integer; AValue: TYamlNode; const ASourceName: string);
var
  I, N: Integer;
begin
  for I := 0 to High(FEntries) do
    if FEntries[I].Key = AKey then
    begin
      AValue.Free;
      RaiseYamlError(ASourceName, AKeyLine, Format('Duplicate key ''%s'' (first defined at line %d).', [AKey, FEntries[I].KeyLine]));
    end;

  N := Length(FEntries);
  SetLength(FEntries, N + 1);
  FEntries[N].Key := AKey;
  FEntries[N].KeyLine := AKeyLine;
  FEntries[N].Value := AValue;
end;

function TYamlNode.Count: Integer;
begin
  Result := Length(FItems);
end;

function TYamlNode.GetItem(AIndex: Integer): TYamlNode;
begin
  Result := FItems[AIndex];
end;

function TYamlNode.EntryCount: Integer;
begin
  Result := Length(FEntries);
end;

function TYamlNode.GetEntry(AIndex: Integer): TYamlKeyValue;
begin
  Result := FEntries[AIndex];
end;

function TYamlNode.Find(const AKey: string): TYamlNode;
var
  I: Integer;
begin
  Result := nil;
  if FKind <> ynkMapping then
    Exit;
  for I := 0 to High(FEntries) do
    if FEntries[I].Key = AKey then
      Exit(FEntries[I].Value);
end;

function TYamlNode.HasKey(const AKey: string): Boolean;
begin
  Result := Find(AKey) <> nil;
end;

function TYamlNode.AsBoolean(out AVal: Boolean): Boolean;
var
  Lower: string;
begin
  Result := False;
  if (FKind <> ynkScalar) or FQuoted then
    Exit;
  Lower := LowerCase(Trim(FScalarValue));
  if (Lower = 'true') or (Lower = 'yes') or (Lower = 'on') then
  begin
    AVal := True;
    Exit(True);
  end;
  if (Lower = 'false') or (Lower = 'no') or (Lower = 'off') then
  begin
    AVal := False;
    Exit(True);
  end;
end;

function TYamlNode.AsInteger(out AVal: Integer): Boolean;
var
  Code: Integer;
begin
  Result := False;
  if (FKind <> ynkScalar) or FQuoted then
    Exit;
  Val(Trim(FScalarValue), AVal, Code);
  Result := (Code = 0);
end;

{ Lexing & Scalar Helpers }

function StripInlineComment(const S: string; ALineNo: Integer; const ASourceName: string): string;
var
  I, Len: Integer;
  InSingle, InDouble: Boolean;
  Ch: Char;
begin
  InSingle := False;
  InDouble := False;
  Len := Length(S);
  I := 1;
  while I <= Len do
  begin
    Ch := S[I];
    if InSingle then
    begin
      if Ch = '''' then
      begin
        if (I < Len) and (S[I + 1] = '''') then
          Inc(I)
        else
          InSingle := False;
      end;
    end
    else if InDouble then
    begin
      if (Ch = '\') and (I < Len) then
        Inc(I)
      else if Ch = '"' then
        InDouble := False;
    end
    else
    begin
      if Ch = '''' then
        InSingle := True
      else if Ch = '"' then
        InDouble := True
      else if (Ch = '#') and ((I = 1) or (S[I - 1] = ' ') or (S[I - 1] = #9)) then
        Exit(TrimRight(Copy(S, 1, I - 1)));
    end;
    Inc(I);
  end;

  if InSingle or InDouble then
    RaiseYamlError(ASourceName, ALineNo, 'Unterminated quoted string.');

  Result := TrimRight(S);
end;

function UnescapeDoubleQuoted(const AInner: string; ALineNo: Integer; const ASourceName: string): string;
var
  I, Len: Integer;
  Ch: Char;
begin
  Result := '';
  Len := Length(AInner);
  I := 1;
  while I <= Len do
  begin
    Ch := AInner[I];
    if Ch = '\' then
    begin
      if I = Len then
        RaiseYamlError(ASourceName, ALineNo, 'Trailing backslash in double-quoted string.');
      Inc(I);
      case AInner[I] of
        '"':  Result := Result + '"';
        '\':  Result := Result + '\';
        '/':  Result := Result + '/';
        'n':  Result := Result + #10;
        'r':  Result := Result + #13;
        't':  Result := Result + #9;
        '0':  Result := Result + #0;
      else
        Result := Result + '\' + AInner[I];
      end;
    end
    else
      Result := Result + Ch;
    Inc(I);
  end;
end;

function ParseScalarNode(const ARaw: string; ALineNo: Integer; const ASourceName: string): TYamlNode;
var
  S, Lower: string;
  Len: Integer;
begin
  S := Trim(ARaw);
  Len := Length(S);
  if Len = 0 then
    Exit(TYamlNode.CreateNull(ALineNo));

  if (S[1] = '"') then
  begin
    if (Len < 2) or (S[Len] <> '"') then
      RaiseYamlError(ASourceName, ALineNo, 'Malformed double-quoted value.');
    Exit(TYamlNode.CreateScalar(UnescapeDoubleQuoted(Copy(S, 2, Len - 2), ALineNo, ASourceName), True, ALineNo));
  end;

  if (S[1] = '''') then
  begin
    if (Len < 2) or (S[Len] <> '''') then
      RaiseYamlError(ASourceName, ALineNo, 'Malformed single-quoted value.');
    Exit(TYamlNode.CreateScalar(StringReplace(Copy(S, 2, Len - 2), '''''', '''', [rfReplaceAll]), True, ALineNo));
  end;

  Lower := LowerCase(S);
  if (Lower = 'null') or (Lower = '~') then
    Exit(TYamlNode.CreateNull(ALineNo));

  Result := TYamlNode.CreateScalar(S, False, ALineNo);
end;

function UnquoteKey(const ARawKey: string; ALineNo: Integer; const ASourceName: string): string;
var
  Node: TYamlNode;
begin
  Node := ParseScalarNode(ARawKey, ALineNo, ASourceName);
  try
    if (Node.Kind <> ynkScalar) or (Node.ScalarValue = '') then
      RaiseYamlError(ASourceName, ALineNo, 'Mapping key cannot be empty.');
    Result := Node.ScalarValue;
  finally
    Node.Free;
  end;
end;

function SplitKeyValue(const AText: string; out ARawKey, ARawVal: string): Boolean;
var
  I, Len, DepthBracket, DepthBrace: Integer;
  InSingle, InDouble: Boolean;
  Ch: Char;
begin
  Result := False;
  ARawKey := '';
  ARawVal := '';
  InSingle := False;
  InDouble := False;
  DepthBracket := 0;
  DepthBrace := 0;
  Len := Length(AText);
  I := 1;
  while I <= Len do
  begin
    Ch := AText[I];
    if InSingle then
    begin
      if Ch = '''' then
      begin
        if (I < Len) and (AText[I + 1] = '''') then
          Inc(I)
        else
          InSingle := False;
      end;
    end
    else if InDouble then
    begin
      if (Ch = '\') and (I < Len) then
        Inc(I)
      else if Ch = '"' then
        InDouble := False;
    end
    else
    begin
      if Ch = '''' then
        InSingle := True
      else if Ch = '"' then
        InDouble := True
      else if Ch = '[' then
        Inc(DepthBracket)
      else if (Ch = ']') and (DepthBracket > 0) then
        Dec(DepthBracket)
      else if Ch = '{' then
        Inc(DepthBrace)
      else if (Ch = '}') and (DepthBrace > 0) then
        Dec(DepthBrace)
      else if (Ch = ':') and (DepthBracket = 0) and (DepthBrace = 0) and
              ((I = Len) or (AText[I + 1] = ' ') or (AText[I + 1] = #9)) then
      begin
        ARawKey := Trim(Copy(AText, 1, I - 1));
        ARawVal := Trim(Copy(AText, I + 1, MaxInt));
        Exit(ARawKey <> '');
      end;
    end;
    Inc(I);
  end;
end;

function ParseFlowNode(const AText: string; ALineNo: Integer; const ASourceName: string): TYamlNode; forward;

function SplitFlowItems(const AInner: string; ALineNo: Integer; const ASourceName: string): TStringArray;
var
  I, StartPos, Len, DepthBracket, DepthBrace, Count: Integer;
  InSingle, InDouble: Boolean;
  Ch: Char;
  Part: string;
begin
  Result := nil;
  if Trim(AInner) = '' then
    Exit;

  InSingle := False;
  InDouble := False;
  DepthBracket := 0;
  DepthBrace := 0;
  StartPos := 1;
  Count := 0;
  Len := Length(AInner);
  I := 1;

  while I <= Len do
  begin
    Ch := AInner[I];
    if InSingle then
    begin
      if Ch = '''' then
      begin
        if (I < Len) and (AInner[I + 1] = '''') then
          Inc(I)
        else
          InSingle := False;
      end;
    end
    else if InDouble then
    begin
      if (Ch = '\') and (I < Len) then
        Inc(I)
      else if Ch = '"' then
        InDouble := False;
    end
    else
    begin
      if Ch = '''' then
        InSingle := True
      else if Ch = '"' then
        InDouble := True
      else if Ch = '[' then
        Inc(DepthBracket)
      else if Ch = ']' then
      begin
        Dec(DepthBracket);
        if DepthBracket < 0 then
          RaiseYamlError(ASourceName, ALineNo, 'Unexpected closing '']'' in flow collection.');
      end
      else if Ch = '{' then
        Inc(DepthBrace)
      else if Ch = '}' then
      begin
        Dec(DepthBrace);
        if DepthBrace < 0 then
          RaiseYamlError(ASourceName, ALineNo, 'Unexpected closing ''}'' in flow collection.');
      end
      else if (Ch = ',') and (DepthBracket = 0) and (DepthBrace = 0) then
      begin
        Part := Trim(Copy(AInner, StartPos, I - StartPos));
        if Part <> '' then
        begin
          SetLength(Result, Count + 1);
          Result[Count] := Part;
          Inc(Count);
        end;
        StartPos := I + 1;
      end;
    end;
    Inc(I);
  end;

  if (DepthBracket <> 0) or (DepthBrace <> 0) or InSingle or InDouble then
    RaiseYamlError(ASourceName, ALineNo, 'Unclosed flow collection or quoted string.');

  Part := Trim(Copy(AInner, StartPos, MaxInt));
  if Part <> '' then
  begin
    SetLength(Result, Count + 1);
    Result[Count] := Part;
  end;
end;

function ParseFlowNode(const AText: string; ALineNo: Integer; const ASourceName: string): TYamlNode;
var
  S, RawKey, RawVal: string;
  Len, I: Integer;
  Parts: TStringArray;
begin
  S := Trim(AText);
  Len := Length(S);

  if (Len >= 2) and (S[1] = '[') and (S[Len] = ']') then
  begin
    Result := TYamlNode.CreateSequence(ALineNo);
    try
      Parts := SplitFlowItems(Copy(S, 2, Len - 2), ALineNo, ASourceName);
      for I := 0 to High(Parts) do
        Result.AddItem(ParseFlowNode(Parts[I], ALineNo, ASourceName));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if (Len >= 2) and (S[1] = '{') and (S[Len] = '}') then
  begin
    Result := TYamlNode.CreateMapping(ALineNo);
    try
      Parts := SplitFlowItems(Copy(S, 2, Len - 2), ALineNo, ASourceName);
      for I := 0 to High(Parts) do
      begin
        if not SplitKeyValue(Parts[I], RawKey, RawVal) then
          RaiseYamlError(ASourceName, ALineNo, Format('Invalid entry ''%s'' in flow mapping (expected key: value).', [Parts[I]]));
        Result.AddEntry(UnquoteKey(RawKey, ALineNo, ASourceName), ALineNo,
          ParseFlowNode(RawVal, ALineNo, ASourceName), ASourceName);
      end;
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if (Len >= 1) and ((S[1] = '[') or (S[1] = '{')) then
    RaiseYamlError(ASourceName, ALineNo, 'Unclosed inline collection (keep [..] or {..} on a single line or use block indentation).');

  Result := ParseScalarNode(S, ALineNo, ASourceName);
end;

function IsSequenceLine(const AContent: string; out ARest: string): Boolean;
begin
  Result := False;
  ARest := '';
  if AContent = '-' then
    Exit(True);
  if (Length(AContent) >= 2) and (AContent[1] = '-') and ((AContent[2] = ' ') or (AContent[2] = #9)) then
  begin
    ARest := Trim(Copy(AContent, 3, MaxInt));
    Exit(True);
  end;
end;

function TokenizeYamlLines(const AText, ASourceName: string): TYamlLineArray;
var
  Normalized, RawLine, Stripped: string;
  StartPos, I, Len, LineNo, Indent, Count: Integer;
begin
  Result := nil;
  Normalized := StripUtf8Bom(AText);
  Normalized := StringReplace(Normalized, #13#10, #10, [rfReplaceAll]);
  Normalized := StringReplace(Normalized, #13, #10, [rfReplaceAll]);

  Len := Length(Normalized);
  StartPos := 1;
  LineNo := 0;
  Count := 0;
  I := 1;

  while I <= Len + 1 do
  begin
    if (I > Len) or (Normalized[I] = #10) then
    begin
      Inc(LineNo);
      RawLine := Copy(Normalized, StartPos, I - StartPos);
      StartPos := I + 1;

      Indent := 0;
      while (Indent < Length(RawLine)) and (RawLine[Indent + 1] = ' ') do
        Inc(Indent);

      if (Indent < Length(RawLine)) and (RawLine[Indent + 1] = #9) then
        RaiseYamlError(ASourceName, LineNo, 'Tab characters are not allowed for YAML indentation; use spaces.');

      Stripped := StripInlineComment(Copy(RawLine, Indent + 1, MaxInt), LineNo, ASourceName);
      if Stripped = '' then
      begin
        Inc(I);
        Continue;
      end;

      if (Indent = 0) and (Stripped = '---') and (Count = 0) then
      begin
        Inc(I);
        Continue;
      end;

      if (Indent = 0) and (Stripped = '...') then
        Break;

      SetLength(Result, Count + 1);
      Result[Count].LineNo := LineNo;
      Result[Count].Indent := Indent;
      Result[Count].Content := Stripped;
      Inc(Count);
    end;
    Inc(I);
  end;
end;

function ParseBlockNode(const ALines: TYamlLineArray; var AIdx: Integer;
  AExpectedIndent: Integer; const ASourceName: string): TYamlNode; forward;

procedure ParseMappingEntriesInto(AMap: TYamlNode; const ALines: TYamlLineArray;
  var AIdx: Integer; AMapIndent: Integer; const ASourceName: string);
var
  CurLine: TYamlLine;
  RawKey, RawVal, DummyRest, CleanKey: string;
  ChildNode: TYamlNode;
  NextIndent: Integer;
begin
  while AIdx <= High(ALines) do
  begin
    CurLine := ALines[AIdx];
    if CurLine.Indent < AMapIndent then
      Break;
    if CurLine.Indent > AMapIndent then
      RaiseYamlError(ASourceName, CurLine.LineNo,
        Format('Unexpected indentation (%d spaces, expected %d).', [CurLine.Indent, AMapIndent]));

    if IsSequenceLine(CurLine.Content, DummyRest) then
      Break;

    if not SplitKeyValue(CurLine.Content, RawKey, RawVal) then
      RaiseYamlError(ASourceName, CurLine.LineNo,
        Format('Expected ''key: value'' mapping entry, got ''%s''.', [CurLine.Content]));

    CleanKey := UnquoteKey(RawKey, CurLine.LineNo, ASourceName);
    Inc(AIdx);

    if RawVal <> '' then
      ChildNode := ParseFlowNode(RawVal, CurLine.LineNo, ASourceName)
    else
    begin
      if AIdx <= High(ALines) then
      begin
        NextIndent := ALines[AIdx].Indent;
        if NextIndent > AMapIndent then
          ChildNode := ParseBlockNode(ALines, AIdx, NextIndent, ASourceName)
        else if (NextIndent = AMapIndent) and IsSequenceLine(ALines[AIdx].Content, DummyRest) then
          ChildNode := ParseBlockNode(ALines, AIdx, NextIndent, ASourceName)
        else
          ChildNode := TYamlNode.CreateNull(CurLine.LineNo);
      end
      else
        ChildNode := TYamlNode.CreateNull(CurLine.LineNo);
    end;

    AMap.AddEntry(CleanKey, CurLine.LineNo, ChildNode, ASourceName);
  end;
end;

function ParseSequenceBlock(const ALines: TYamlLineArray; var AIdx: Integer;
  ASeqIndent: Integer; const ASourceName: string): TYamlNode;
var
  CurLine: TYamlLine;
  Rest, RawKey, RawVal, CleanKey: string;
  ItemMap, FirstVal, ItemNode: TYamlNode;
  EntryIndent, NextIndent: Integer;
begin
  Result := TYamlNode.CreateSequence(ALines[AIdx].LineNo);
  try
    while AIdx <= High(ALines) do
    begin
      CurLine := ALines[AIdx];
      if CurLine.Indent < ASeqIndent then
        Break;
      if CurLine.Indent > ASeqIndent then
        RaiseYamlError(ASourceName, CurLine.LineNo,
          Format('Unexpected indentation in sequence (%d spaces, expected %d).', [CurLine.Indent, ASeqIndent]));

      if not IsSequenceLine(CurLine.Content, Rest) then
        Break;

      Inc(AIdx);
      if Rest = '' then
      begin
        if (AIdx <= High(ALines)) and (ALines[AIdx].Indent > ASeqIndent) then
          ItemNode := ParseBlockNode(ALines, AIdx, ALines[AIdx].Indent, ASourceName)
        else
          ItemNode := TYamlNode.CreateNull(CurLine.LineNo);
        Result.AddItem(ItemNode);
      end
      else if (Rest[1] <> '[') and (Rest[1] <> '{') and SplitKeyValue(Rest, RawKey, RawVal) then
      begin
        // Inline mapping item starting on '- key: val'
        ItemMap := TYamlNode.CreateMapping(CurLine.LineNo);
        try
          CleanKey := UnquoteKey(RawKey, CurLine.LineNo, ASourceName);
          EntryIndent := ASeqIndent + 2;
          if RawVal <> '' then
            FirstVal := ParseFlowNode(RawVal, CurLine.LineNo, ASourceName)
          else if (AIdx <= High(ALines)) and (ALines[AIdx].Indent > EntryIndent) then
            FirstVal := ParseBlockNode(ALines, AIdx, ALines[AIdx].Indent, ASourceName)
          else
            FirstVal := TYamlNode.CreateNull(CurLine.LineNo);

          ItemMap.AddEntry(CleanKey, CurLine.LineNo, FirstVal, ASourceName);

          if (AIdx <= High(ALines)) and (ALines[AIdx].Indent > ASeqIndent) then
          begin
            NextIndent := ALines[AIdx].Indent;
            ParseMappingEntriesInto(ItemMap, ALines, AIdx, NextIndent, ASourceName);
          end;
        except
          ItemMap.Free;
          raise;
        end;
        Result.AddItem(ItemMap);
      end
      else
        Result.AddItem(ParseFlowNode(Rest, CurLine.LineNo, ASourceName));
    end;
  except
    Result.Free;
    raise;
  end;
end;

function ParseBlockNode(const ALines: TYamlLineArray; var AIdx: Integer;
  AExpectedIndent: Integer; const ASourceName: string): TYamlNode;
var
  DummyRest, RawKey, RawVal: string;
begin
  if AIdx > High(ALines) then
    Exit(TYamlNode.CreateNull(0));

  if IsSequenceLine(ALines[AIdx].Content, DummyRest) then
    Exit(ParseSequenceBlock(ALines, AIdx, AExpectedIndent, ASourceName));

  if SplitKeyValue(ALines[AIdx].Content, RawKey, RawVal) then
  begin
    Result := TYamlNode.CreateMapping(ALines[AIdx].LineNo);
    try
      ParseMappingEntriesInto(Result, ALines, AIdx, AExpectedIndent, ASourceName);
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  Result := ParseFlowNode(ALines[AIdx].Content, ALines[AIdx].LineNo, ASourceName);
  Inc(AIdx);
end;

function ParseYamlText(const AText: string; const ASourceName: string): TYamlNode;
var
  Lines: TYamlLineArray;
  Idx: Integer;
begin
  Lines := TokenizeYamlLines(AText, ASourceName);
  if Length(Lines) = 0 then
    Exit(TYamlNode.CreateMapping(1));

  Idx := 0;
  Result := ParseBlockNode(Lines, Idx, Lines[0].Indent, ASourceName);
  try
    if Idx <= High(Lines) then
      RaiseYamlError(ASourceName, Lines[Idx].LineNo,
        Format('Unexpected content ''%s'' at indentation %d.', [Lines[Idx].Content, Lines[Idx].Indent]));
  except
    Result.Free;
    raise;
  end;
end;

function ParseYamlFile(const AFilePath: string): TYamlNode;
begin
  Result := ParseYamlText(ReadFileTextUtf8(AFilePath), AFilePath);
end;

end.
