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

{ True when AValue can be written as an unquoted block scalar (`key: value`) and
  ParseYamlText reads exactly AValue back. }
function YamlPlainScalarSafe(const AValue: string): Boolean;
{ Writes AValue as a double-quoted scalar that ParseYamlText reads back unchanged. }
function YamlQuoteDouble(const AValue: string): string;

implementation

uses
  nik.fs, VSoft.YAML;

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
  Code, I, Start: Integer;
  Text: string;
begin
  Result := False;
  if (FKind <> ynkScalar) or FQuoted then
    Exit;
  // Plain decimal integers only: Val would also accept '$FF', '&17', '%101' and '0x1'.
  Text := Trim(FScalarValue);
  Start := 1;
  if (Text <> '') and ((Text[1] = '-') or (Text[1] = '+')) then
    Start := 2;
  if Start > Length(Text) then
    Exit;
  for I := Start to Length(Text) do
    if (Text[I] < '0') or (Text[I] > '9') then
      Exit;
  Val(Text, AVal, Code);
  Result := (Code = 0);
end;

{ Conversion from VSoft.YAML }

function ConvertValue(const AValue: IYAMLValue; const ASource: UnicodeString;
  AParentLine: Integer; const ASourceName: string): TYamlNode;
var
  Line, I, StartIdx: Integer;
  Map: IYAMLMapping;
  Seq: IYAMLSequence;
  Key: string;
  Text: string;
  Quoted: Boolean;
begin
  if AValue.HasRange then
    Line := AValue.Range.Start.Line
  else
    Line := AParentLine;
  if Line <= 0 then
    Line := AParentLine;

  if AValue.IsAlias then
    RaiseYamlError(ASourceName, Line, 'YAML aliases are not supported; quote the value to use it literally.');
  if AValue.Tag <> '' then
    RaiseYamlError(ASourceName, Line, 'YAML tags are not supported; quote the value to use it literally.');

  if AValue.IsMapping then
  begin
    Map := AValue.AsMapping;
    Result := TYamlNode.CreateMapping(Line);
    try
      for I := 0 to Map.Count - 1 do
      begin
        Key := UTF8Encode(Map.Keys[I]);
        Result.AddEntry(Key, Map.GetKeyRange(I).Start.Line,
          ConvertValue(Map.Values[Map.Keys[I]], ASource, Map.GetKeyRange(I).Start.Line, ASourceName),
          ASourceName);
      end;
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if AValue.IsSequence then
  begin
    Seq := AValue.AsSequence;
    Result := TYamlNode.CreateSequence(Line);
    try
      for I := 0 to Seq.Count - 1 do
        Result.AddItem(ConvertValue(Seq.Items[I], ASource, Line, ASourceName));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if AValue.IsNull then
    Exit(TYamlNode.CreateNull(Line));

  Quoted := False;
  if AValue.IsString then
  begin
    if AValue.HasRange then
    begin
      StartIdx := AValue.Range.Start.Index + 1;
      Quoted := (StartIdx >= 1) and (StartIdx <= Length(ASource)) and
        ((ASource[StartIdx] = '"') or (ASource[StartIdx] = ''''));
    end;
    Text := UTF8Encode(AValue.AsString);
  end
  else
    Text := UTF8Encode(AValue.RawValue);
  Result := TYamlNode.CreateScalar(Text, Quoted, Line);
end;

function ParseYamlText(const AText: string; const ASourceName: string): TYamlNode;
var
  Source: UnicodeString;
  Options: IYAMLParserOptions;
  Doc: IYAMLDocument;
begin
  Source := UTF8Decode(StripUtf8Bom(AText));
  if Trim(Source) = '' then
    Exit(TYamlNode.CreateMapping(1));

  Options := TYAML.CreateParserOptions;
  Options.RecordPositions := True;
  Options.YAML11Compatibility := False;
  Options.DuplicateKeyBehavior := TYAMLDuplicateKeyBehavior.dkError;
  try
    Doc := TYAML.LoadFromString(Source, Options);
  except
    on E: EYAMLParseException do
      RaiseYamlError(ASourceName, E.Line, UTF8Encode(E.Message));
  end;

  if (Doc = nil) or (Doc.Root = nil) or (Doc.Root.IsNull and not Doc.Root.HasRange) then
    Exit(TYamlNode.CreateMapping(1));
  Result := ConvertValue(Doc.Root, Source, 1, ASourceName);
end;

function ParseYamlFile(const AFilePath: string): TYamlNode;
begin
  Result := ParseYamlText(ReadFileTextUtf8(AFilePath), AFilePath);
end;
function YamlPlainScalarSafe(const AValue: string): Boolean;
var
  I: Integer;
  Lower: string;
begin
  Result := False;
  if AValue = '' then
    Exit;
  if (AValue[1] = ' ') or (AValue[1] = #9) or
     (AValue[Length(AValue)] = ' ') or (AValue[Length(AValue)] = #9) then
    Exit;
  // Characters that start a quoted scalar, a flow collection, a comment, an anchor, alias,
  // tag, block scalar, directive, or a reserved indicator.
  if AValue[1] in ['''', '"', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '%', '@', '`', ',', '?'] then
    Exit;
  // '-' and ':' only start an indicator when followed by a blank (or when alone).
  if (AValue[1] = '-') and ((Length(AValue) = 1) or (AValue[2] = ' ') or (AValue[2] = #9)) then
    Exit;
  if (AValue[1] = ':') and ((Length(AValue) = 1) or (AValue[2] = ' ') or (AValue[2] = #9)) then
    Exit;
  if (Pos(' #', AValue) > 0) or (Pos(#9'#', AValue) > 0) or (Pos(': ', AValue) > 0) or
     (Pos(':'#9, AValue) > 0) or (AValue[Length(AValue)] = ':') then
    Exit;
  for I := 1 to Length(AValue) do
    if AValue[I] < #32 then
      Exit;
  Lower := LowerCase(AValue);
  if (Lower = 'null') or (Lower = '~') then
    Exit;
  Result := True;
end;

function YamlQuoteDouble(const AValue: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    case AValue[I] of
      '\': Result := Result + '\\';
      '"': Result := Result + '\"';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9:  Result := Result + '\t';
      #0:  Result := Result + '\0';
    else
      Result := Result + AValue[I];
    end;
  end;
  Result := '"' + Result + '"';
end;

end.
