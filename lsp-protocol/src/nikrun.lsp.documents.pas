unit nikrun.lsp.documents;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.utf16;

type
  TLspLineSpan = record
    StartByte: Integer; // 1-based inclusive start byte in Text
    ContentLen: Integer; // Length excluding CR/LF
  end;

  TLspDocument = class
  private
    FUri: string;
    FNormalizedKey: string;
    FFilePath: string;
    FLanguageId: string;
    FVersion: Integer;
    FText: string;
    FLinesDirty: Boolean;
    FLines: array of TLspLineSpan;
    procedure EnsureLineIndex;
    function GetLineCount: Integer;
  public
    constructor Create(const AUri, ALanguageId: string; AVersion: Integer; const AText: string);

    procedure SetFullText(const AText: string; AVersion: Integer = -1);
    procedure ApplyChange(const AChange: TLspTextDocumentContentChangeEvent);
    procedure ApplyChanges(const AChanges: TLspContentChangeArray; AVersion: Integer = -1);

    function GetLineText(ALine: Integer): string;
    function PositionToByteIndex(const APos: TLspPosition): Integer;
    function ByteIndexToPosition(AByteIndex: Integer): TLspPosition;
    function ExtractIdentifierAt(const APos: TLspPosition; out AIdent: string; out ARange: TLspRange): Boolean;

    property Uri: string read FUri;
    property NormalizedKey: string read FNormalizedKey;
    property FilePath: string read FFilePath;
    property LanguageId: string read FLanguageId;
    property Version: Integer read FVersion;
    property Text: string read FText;
    property LineCount: Integer read GetLineCount;
  end;

  TLspDocumentStore = class
  private
    FItems: TFPList;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TLspDocument;
    function IndexOfUri(const AUri: string): Integer;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    function OpenDocument(const AUri, ALanguageId: string; AVersion: Integer; const AText: string): TLspDocument;
    function ChangeDocument(const AUri: string; AVersion: Integer; const AChanges: TLspContentChangeArray): TLspDocument;
    function CloseDocument(const AUri: string): Boolean;
    function FindDocument(const AUri: string): TLspDocument;
    function FindByFilePath(const AFilePath: string): TLspDocument;

    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TLspDocument read GetItem; default;
  end;

implementation

function IsIdentChar(ACh: Char): Boolean; inline;
begin
  Result :=
    ((ACh >= 'A') and (ACh <= 'Z')) or
    ((ACh >= 'a') and (ACh <= 'z')) or
    ((ACh >= '0') and (ACh <= '9')) or
    (ACh = '_');
end;

function IsIdentStartChar(ACh: Char): Boolean; inline;
begin
  Result :=
    ((ACh >= 'A') and (ACh <= 'Z')) or
    ((ACh >= 'a') and (ACh <= 'z')) or
    (ACh = '_') or (ACh = '&');
end;

{ TLspDocument }

constructor TLspDocument.Create(const AUri, ALanguageId: string; AVersion: Integer; const AText: string);
begin
  inherited Create;
  FUri := AUri;
  FNormalizedKey := LowerCase(NormalizeDocumentUri(AUri));
  FFilePath := UriToFilePath(AUri);
  FLanguageId := ALanguageId;
  FVersion := AVersion;
  FText := AText;
  FLinesDirty := True;
end;

procedure TLspDocument.EnsureLineIndex;
var
  Len, I, LineStart, Count, Cap: Integer;
begin
  if not FLinesDirty then
    Exit;

  Len := Length(FText);
  Count := 0;
  Cap := 64;
  SetLength(FLines, Cap);

  LineStart := 1;
  I := 1;
  while I <= Len do
  begin
    if (FText[I] = #13) or (FText[I] = #10) then
    begin
      if Count >= Cap then
      begin
        Cap := Cap * 2;
        SetLength(FLines, Cap);
      end;
      FLines[Count].StartByte := LineStart;
      FLines[Count].ContentLen := I - LineStart;
      Inc(Count);

      if (FText[I] = #13) and (I + 1 <= Len) and (FText[I + 1] = #10) then
        Inc(I, 2)
      else
        Inc(I);
      LineStart := I;
    end
    else
      Inc(I);
  end;

  if Count >= Cap then
    SetLength(FLines, Count + 1);
  FLines[Count].StartByte := LineStart;
  FLines[Count].ContentLen := (Len + 1) - LineStart;
  Inc(Count);

  SetLength(FLines, Count);
  FLinesDirty := False;
end;

function TLspDocument.GetLineCount: Integer;
begin
  EnsureLineIndex;
  Result := Length(FLines);
end;

procedure TLspDocument.SetFullText(const AText: string; AVersion: Integer);
begin
  FText := AText;
  if AVersion >= 0 then
    FVersion := AVersion;
  FLinesDirty := True;
end;

procedure TLspDocument.ApplyChange(const AChange: TLspTextDocumentContentChangeEvent);
var
  StartIdx, EndIdx, TempIdx: Integer;
begin
  if not AChange.HasRange then
  begin
    FText := AChange.Text;
    FLinesDirty := True;
    Exit;
  end;

  StartIdx := PositionToByteIndex(AChange.Range.StartPos);
  EndIdx := PositionToByteIndex(AChange.Range.EndPos);
  if EndIdx < StartIdx then
  begin
    TempIdx := StartIdx;
    StartIdx := EndIdx;
    EndIdx := TempIdx;
  end;

  FText := Copy(FText, 1, StartIdx - 1) + AChange.Text + Copy(FText, EndIdx, MaxInt);
  FLinesDirty := True;
end;

procedure TLspDocument.ApplyChanges(const AChanges: TLspContentChangeArray; AVersion: Integer);
var
  I: Integer;
begin
  for I := 0 to High(AChanges) do
    ApplyChange(AChanges[I]);
  if AVersion >= 0 then
    FVersion := AVersion;
end;

function TLspDocument.GetLineText(ALine: Integer): string;
begin
  EnsureLineIndex;
  if (ALine < 0) or (ALine >= Length(FLines)) then
    Exit('');
  if FLines[ALine].ContentLen <= 0 then
    Exit('');
  Result := Copy(FText, FLines[ALine].StartByte, FLines[ALine].ContentLen);
end;

function TLspDocument.PositionToByteIndex(const APos: TLspPosition): Integer;
var
  LineText: string;
  RelByte: Integer;
begin
  EnsureLineIndex;
  if Length(FLines) = 0 then
    Exit(1);
  if APos.Line < 0 then
    Exit(1);
  if APos.Line >= Length(FLines) then
    Exit(Length(FText) + 1);

  LineText := GetLineText(APos.Line);
  RelByte := Utf16ColToByteIndex(LineText, APos.Character);
  Result := FLines[APos.Line].StartByte + RelByte - 1;
end;

function TLspDocument.ByteIndexToPosition(AByteIndex: Integer): TLspPosition;
var
  Clamped, Lo, Hi, Mid, RelByte: Integer;
  LineText: string;
begin
  EnsureLineIndex;
  if Length(FLines) = 0 then
    Exit(TLspPosition.Create(0, 0));

  Clamped := AByteIndex;
  if Clamped < 1 then
    Clamped := 1
  else if Clamped > Length(FText) + 1 then
    Clamped := Length(FText) + 1;

  Lo := 0;
  Hi := High(FLines);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi + 1) div 2;
    if FLines[Mid].StartByte <= Clamped then
      Lo := Mid
    else
      Hi := Mid - 1;
  end;

  LineText := GetLineText(Lo);
  RelByte := Clamped - FLines[Lo].StartByte + 1;
  if RelByte > Length(LineText) + 1 then
    RelByte := Length(LineText) + 1;

  Result := TLspPosition.Create(Lo, ByteIndexToUtf16Col(LineText, RelByte));
end;

function TLspDocument.ExtractIdentifierAt(const APos: TLspPosition; out AIdent: string; out ARange: TLspRange): Boolean;
var
  LineText: string;
  ColByte, StartByte, EndByte: Integer;
begin
  AIdent := '';
  ARange := TLspRange.SingleLine(APos.Line, APos.Character, APos.Character);
  Result := False;

  LineText := GetLineText(APos.Line);
  if LineText = '' then
    Exit;

  ColByte := Utf16ColToByteIndex(LineText, APos.Character);
  if (ColByte > Length(LineText)) or (not IsIdentChar(LineText[ColByte])) then
  begin
    if (ColByte > 1) and (ColByte - 1 <= Length(LineText)) and IsIdentChar(LineText[ColByte - 1]) then
      Dec(ColByte)
    else
      Exit;
  end;

  StartByte := ColByte;
  while (StartByte > 1) and IsIdentChar(LineText[StartByte - 1]) do
    Dec(StartByte);
  if (StartByte > 1) and (LineText[StartByte - 1] = '&') then
    Dec(StartByte);

  if not IsIdentStartChar(LineText[StartByte]) then
    Exit;

  EndByte := ColByte;
  while (EndByte <= Length(LineText)) and IsIdentChar(LineText[EndByte]) do
    Inc(EndByte);

  AIdent := Copy(LineText, StartByte, EndByte - StartByte);
  if (Length(AIdent) > 1) and (AIdent[1] = '&') then
    Delete(AIdent, 1, 1);

  ARange := TLspRange.SingleLine(
    APos.Line,
    ByteIndexToUtf16Col(LineText, StartByte),
    ByteIndexToUtf16Col(LineText, EndByte)
  );
  Result := AIdent <> '';
end;

{ TLspDocumentStore }

constructor TLspDocumentStore.Create;
begin
  inherited Create;
  FItems := TFPList.Create;
end;

destructor TLspDocumentStore.Destroy;
begin
  Clear;
  FreeAndNil(FItems);
  inherited Destroy;
end;

procedure TLspDocumentStore.Clear;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TObject(FItems[I]).Free;
  FItems.Clear;
end;

function TLspDocumentStore.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TLspDocumentStore.GetItem(AIndex: Integer): TLspDocument;
begin
  Result := TLspDocument(FItems[AIndex]);
end;

function TLspDocumentStore.IndexOfUri(const AUri: string): Integer;
var
  Key: string;
  I: Integer;
begin
  Key := LowerCase(NormalizeDocumentUri(AUri));
  for I := 0 to FItems.Count - 1 do
  begin
    if TLspDocument(FItems[I]).NormalizedKey = Key then
      Exit(I);
  end;
  Result := -1;
end;

function TLspDocumentStore.OpenDocument(const AUri, ALanguageId: string; AVersion: Integer; const AText: string): TLspDocument;
var
  Idx: Integer;
begin
  Idx := IndexOfUri(AUri);
  if Idx >= 0 then
  begin
    Result := TLspDocument(FItems[Idx]);
    Result.SetFullText(AText, AVersion);
    Exit;
  end;

  Result := TLspDocument.Create(AUri, ALanguageId, AVersion, AText);
  FItems.Add(Result);
end;

function TLspDocumentStore.ChangeDocument(const AUri: string; AVersion: Integer;
  const AChanges: TLspContentChangeArray): TLspDocument;
begin
  Result := FindDocument(AUri);
  if Result <> nil then
    Result.ApplyChanges(AChanges, AVersion);
end;

function TLspDocumentStore.CloseDocument(const AUri: string): Boolean;
var
  Idx: Integer;
  Doc: TLspDocument;
begin
  Idx := IndexOfUri(AUri);
  if Idx < 0 then
    Exit(False);
  Doc := TLspDocument(FItems[Idx]);
  FItems.Delete(Idx);
  Doc.Free;
  Result := True;
end;

function TLspDocumentStore.FindDocument(const AUri: string): TLspDocument;
var
  Idx: Integer;
begin
  Idx := IndexOfUri(AUri);
  if Idx >= 0 then
    Result := TLspDocument(FItems[Idx])
  else
    Result := nil;
end;

function TLspDocumentStore.FindByFilePath(const AFilePath: string): TLspDocument;
begin
  if Trim(AFilePath) = '' then
    Exit(nil);
  Result := FindDocument(FilePathToUri(ExpandFileName(AFilePath)));
end;

end.
