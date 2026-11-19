unit nikrun.lsp.types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, fpjson;

const
  LSP_JSONRPC_VERSION = '2.0';

  // Standard JSON-RPC 2.0 & LSP 3.17 Error Codes
  LSP_ERR_PARSE_ERROR            = -32700;
  LSP_ERR_INVALID_REQUEST        = -32600;
  LSP_ERR_METHOD_NOT_FOUND       = -32601;
  LSP_ERR_INVALID_PARAMS         = -32602;
  LSP_ERR_INTERNAL_ERROR         = -32603;
  LSP_ERR_SERVER_NOT_INITIALIZED = -32002;
  LSP_ERR_UNKNOWN_ERROR_CODE     = -32001;
  LSP_ERR_REQUEST_FAILED         = -32803;
  LSP_ERR_SERVER_CANCELLED       = -32802;
  LSP_ERR_CONTENT_MODIFIED       = -32801;
  LSP_ERR_REQUEST_CANCELLED      = -32800;

type
  ELspError = class(Exception);

  ELspProtocolError = class(ELspError)
  private
    FCode: Integer;
  public
    constructor Create(ACode: Integer; const AMessage: string);
    property Code: Integer read FCode;
  end;

  TLspStringArray = array of string;

  generic TLspOptional<T> = record
    HasValue: Boolean;
    Value: T;
    procedure SetValue(const AValue: T);
    procedure Clear;
    function ValueOrDefault(const ADefault: T): T;
  end;

  TLspOptionalInt = specialize TLspOptional<Integer>;
  TLspOptionalBool = specialize TLspOptional<Boolean>;
  TLspOptionalString = specialize TLspOptional<string>;

  TLspIdKind = (likNull, likInt, likString);

  TLspId = record
    Kind: TLspIdKind;
    IntValue: Int64;
    StrValue: string;
    class function NullId: TLspId; static;
    class function FromInt(AValue: Int64): TLspId; static;
    class function FromString(const AValue: string): TLspId; static;
    function IsEmpty: Boolean;
    function ToKeyString: string;
    function EqualsId(const AOther: TLspId): Boolean;
  end;

  TLspPosition = record
    Line: Integer;      // 0-based line index
    Character: Integer; // 0-based UTF-16 character offset
    class function Create(ALine, ACharacter: Integer): TLspPosition; static;
  end;

  TLspRange = record
    StartPos: TLspPosition;
    EndPos: TLspPosition;
    class function Create(const AStart, AEnd: TLspPosition): TLspRange; static;
    class function SingleLine(ALine, AStartChar, AEndChar: Integer): TLspRange; static;
  end;

  TLspLocation = record
    Uri: string;
    Range: TLspRange;
    class function Create(const AUri: string; const ARange: TLspRange): TLspLocation; static;
  end;
  TLspLocationArray = array of TLspLocation;

  TLspTextEdit = record
    Range: TLspRange;
    NewText: string;
    class function Create(const ARange: TLspRange; const ANewText: string): TLspTextEdit; static;
  end;
  TLspTextEditArray = array of TLspTextEdit;

  TLspTextDocumentContentChangeEvent = record
    HasRange: Boolean;
    Range: TLspRange;
    Text: string;
  end;
  TLspContentChangeArray = array of TLspTextDocumentContentChangeEvent;

  TLspDiagnosticSeverity = (
    ldsUnspecified = 0,
    ldsError       = 1,
    ldsWarning     = 2,
    ldsInformation = 3,
    ldsHint        = 4
  );

  TLspDiagnostic = record
    Range: TLspRange;
    Severity: TLspDiagnosticSeverity;
    HasCode: Boolean;
    IntCode: Integer;
    StrCode: string;
    Source: string;
    Message: string;
  end;
  TLspDiagnosticArray = array of TLspDiagnostic;

  TLspMessageType = (
    lmtError   = 1,
    lmtWarning = 2,
    lmtInfo    = 3,
    lmtLog     = 4,
    lmtDebug   = 5
  );

  TLspTextDocumentSyncKind = (
    ltdskNone        = 0,
    ltdskFull        = 1,
    ltdskIncremental = 2
  );

  TLspSymbolKind = (
    lskFile          = 1,
    lskModule        = 2,
    lskNamespace     = 3,
    lskPackage       = 4,
    lskClass         = 5,
    lskMethod        = 6,
    lskProperty      = 7,
    lskField         = 8,
    lskConstructor   = 9,
    lskEnum          = 10,
    lskInterface     = 11,
    lskFunction      = 12,
    lskVariable      = 13,
    lskConstant      = 14,
    lskString        = 15,
    lskNumber        = 16,
    lskBoolean       = 17,
    lskArray         = 18,
    lskObject        = 19,
    lskKey           = 20,
    lskNull          = 21,
    lskEnumMember    = 22,
    lskStruct        = 23,
    lskEvent         = 24,
    lskOperator      = 25,
    lskTypeParameter = 26
  );

  { Flat-arena representation of hierarchical LSP DocumentSymbol trees.
    ParentIndex = -1 denotes a top-level symbol; ParentIndex >= 0 nests this
    symbol inside the children[] array of ASymbols[ParentIndex] when serialized. }
  TLspDocumentSymbol = record
    ParentIndex: Integer;
    Name: string;
    Detail: string;
    Kind: TLspSymbolKind;
    Range: TLspRange;
    SelectionRange: TLspRange;
  end;
  TLspDocumentSymbolArray = array of TLspDocumentSymbol;

  TLspSymbolInformation = record
    Name: string;
    Kind: TLspSymbolKind;
    Location: TLspLocation;
    ContainerName: string;
  end;
  TLspSymbolInformationArray = array of TLspSymbolInformation;

  TLspCompletionItemKind = (
    lcikUnspecified   = 0,
    lcikText          = 1,
    lcikMethod        = 2,
    lcikFunction      = 3,
    lcikConstructor   = 4,
    lcikField         = 5,
    lcikVariable      = 6,
    lcikClass         = 7,
    lcikInterface     = 8,
    lcikModule        = 9,
    lcikProperty      = 10,
    lcikUnit          = 11,
    lcikValue         = 12,
    lcikEnum          = 13,
    lcikKeyword       = 14,
    lcikSnippet       = 15,
    lcikColor         = 16,
    lcikFile          = 17,
    lcikReference     = 18,
    lcikFolder        = 19,
    lcikEnumMember    = 20,
    lcikConstant      = 21,
    lcikStruct        = 22,
    lcikEvent         = 23,
    lcikOperator      = 24,
    lcikTypeParameter = 25
  );

  TLspInsertTextFormat = (
    litfUnspecified = 0,
    litfPlainText   = 1,
    litfSnippet     = 2
  );

  TLspCompletionItem = record
    LabelText: string;
    Kind: TLspCompletionItemKind;
    Detail: string;
    DocumentationMarkdown: string;
    SortText: string;
    FilterText: string;
    InsertText: string;
    InsertTextFormat: TLspInsertTextFormat;
    HasTextEdit: Boolean;
    TextEdit: TLspTextEdit;
  end;
  TLspCompletionItemArray = array of TLspCompletionItem;

  TLspCompletionList = record
    IsIncomplete: Boolean;
    Items: TLspCompletionItemArray;
  end;

  TLspHover = record
    HasValue: Boolean;
    Markdown: string;
    HasRange: Boolean;
    Range: TLspRange;
  end;

  TLspParameterInformation = record
    LabelText: string;
    DocumentationMarkdown: string;
  end;
  TLspParameterInfoArray = array of TLspParameterInformation;

  TLspSignatureInformation = record
    LabelText: string;
    DocumentationMarkdown: string;
    Parameters: TLspParameterInfoArray;
  end;
  TLspSignatureInfoArray = array of TLspSignatureInformation;

  TLspSignatureHelp = record
    Signatures: TLspSignatureInfoArray;
    ActiveSignature: Integer;
    ActiveParameter: Integer;
  end;

  TLspWorkspaceFolder = record
    Uri: string;
    Name: string;
  end;
  TLspWorkspaceFolderArray = array of TLspWorkspaceFolder;

  TLspServerCapabilities = record
    ServerName: string;
    ServerVersion: string;
    TextDocumentSync: TLspTextDocumentSyncKind;
    OpenCloseNotify: Boolean;
    SaveNotify: Boolean;
    SaveIncludeText: Boolean;
    HoverProvider: Boolean;
    DefinitionProvider: Boolean;
    DeclarationProvider: Boolean;
    ReferencesProvider: Boolean;
    DocumentSymbolProvider: Boolean;
    WorkspaceSymbolProvider: Boolean;
    CompletionProvider: Boolean;
    CompletionTriggerChars: TLspStringArray;
    SignatureHelpProvider: Boolean;
    SignatureTriggerChars: TLspStringArray;
    class function DefaultCapabilities(const AServerName, AServerVersion: string): TLspServerCapabilities; static;
  end;

  TLspInitializeParams = record
    ProcessId: TLspOptionalInt;
    ClientName: string;
    ClientVersion: string;
    RootUri: string;
    RootPath: string;
    WorkspaceFolders: TLspWorkspaceFolderArray;
    Trace: string;
    InitializationOptionsJson: string;
  end;

  TLspFileChangeType = (
    lfctCreated = 1,
    lfctChanged = 2,
    lfctDeleted = 3
  );

  TLspFileEvent = record
    Uri: string;
    ChangeType: TLspFileChangeType;
  end;
  TLspFileEventArray = array of TLspFileEvent;

// JSON Codec Functions (pure fpjson, zero RTTI)
function LspIdToJson(const AId: TLspId): TJSONData;
function JsonToLspId(AData: TJSONData): TLspId;

function PositionToJson(const APos: TLspPosition): TJSONObject;
function JsonToPosition(AObj: TJSONObject): TLspPosition;

function RangeToJson(const ARange: TLspRange): TJSONObject;
function JsonToRange(AObj: TJSONObject): TLspRange;

function LocationToJson(const ALoc: TLspLocation): TJSONObject;
function LocationsToJson(const ALocs: TLspLocationArray): TJSONArray;

function TextEditToJson(const AEdit: TLspTextEdit): TJSONObject;
function DiagnosticToJson(const ADiag: TLspDiagnostic): TJSONObject;
function DiagnosticsToJson(const ADiags: TLspDiagnosticArray): TJSONArray;

function DocumentSymbolsToJson(const ASymbols: TLspDocumentSymbolArray): TJSONArray;
function SymbolInfosToJson(const ASymbols: TLspSymbolInformationArray): TJSONArray;

function CompletionItemToJson(const AItem: TLspCompletionItem): TJSONObject;
function CompletionListToJson(const AList: TLspCompletionList): TJSONObject;

function HoverToJson(const AHover: TLspHover): TJSONData;
function SignatureHelpToJson(const AHelp: TLspSignatureHelp): TJSONData;

function CapabilitiesToInitializeResultJson(const ACaps: TLspServerCapabilities): TJSONObject;
function JsonToInitializeParams(AObj: TJSONObject): TLspInitializeParams;
function JsonToContentChanges(AArr: TJSONArray): TLspContentChangeArray;
function JsonToFileEvents(AArr: TJSONArray): TLspFileEventArray;

// Safe JSON lookup helpers
function JsonGetStr(AObj: TJSONObject; const AKey: string; const ADefault: string = ''): string;
function JsonGetInt(AObj: TJSONObject; const AKey: string; ADefault: Integer = 0): Integer;
function JsonGetBool(AObj: TJSONObject; const AKey: string; ADefault: Boolean = False): Boolean;
function JsonGetObj(AObj: TJSONObject; const AKey: string): TJSONObject;
function JsonGetArr(AObj: TJSONObject; const AKey: string): TJSONArray;

implementation

{ ELspProtocolError }

constructor ELspProtocolError.Create(ACode: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  FCode := ACode;
end;

{ TLspOptional<T> }

procedure TLspOptional.SetValue(const AValue: T);
begin
  Value := AValue;
  HasValue := True;
end;

procedure TLspOptional.Clear;
begin
  HasValue := False;
  Value := Default(T);
end;

function TLspOptional.ValueOrDefault(const ADefault: T): T;
begin
  if HasValue then
    Result := Value
  else
    Result := ADefault;
end;

{ TLspId }

class function TLspId.NullId: TLspId;
begin
  Result.Kind := likNull;
  Result.IntValue := 0;
  Result.StrValue := '';
end;

class function TLspId.FromInt(AValue: Int64): TLspId;
begin
  Result.Kind := likInt;
  Result.IntValue := AValue;
  Result.StrValue := '';
end;

class function TLspId.FromString(const AValue: string): TLspId;
begin
  Result.Kind := likString;
  Result.IntValue := 0;
  Result.StrValue := AValue;
end;

function TLspId.IsEmpty: Boolean;
begin
  Result := Kind = likNull;
end;

function TLspId.ToKeyString: string;
begin
  case Kind of
    likNull:   Result := 'null';
    likInt:    Result := 'i:' + IntToStr(IntValue);
    likString: Result := 's:' + StrValue;
  else
    raise ELspError.CreateFmt('Unexpected TLspIdKind ordinal: %d', [Ord(Kind)]);
  end;
end;

function TLspId.EqualsId(const AOther: TLspId): Boolean;
begin
  if Kind <> AOther.Kind then
    Exit(False);
  case Kind of
    likNull:   Result := True;
    likInt:    Result := IntValue = AOther.IntValue;
    likString: Result := StrValue = AOther.StrValue;
  else
    raise ELspError.CreateFmt('Unexpected TLspIdKind ordinal: %d', [Ord(Kind)]);
  end;
end;

{ TLspPosition / TLspRange / TLspLocation / TLspTextEdit }

class function TLspPosition.Create(ALine, ACharacter: Integer): TLspPosition;
begin
  Result.Line := ALine;
  Result.Character := ACharacter;
end;

class function TLspRange.Create(const AStart, AEnd: TLspPosition): TLspRange;
begin
  Result.StartPos := AStart;
  Result.EndPos := AEnd;
end;

class function TLspRange.SingleLine(ALine, AStartChar, AEndChar: Integer): TLspRange;
begin
  Result.StartPos := TLspPosition.Create(ALine, AStartChar);
  Result.EndPos := TLspPosition.Create(ALine, AEndChar);
end;

class function TLspLocation.Create(const AUri: string; const ARange: TLspRange): TLspLocation;
begin
  Result.Uri := AUri;
  Result.Range := ARange;
end;

class function TLspTextEdit.Create(const ARange: TLspRange; const ANewText: string): TLspTextEdit;
begin
  Result.Range := ARange;
  Result.NewText := ANewText;
end;

{ TLspServerCapabilities }

class function TLspServerCapabilities.DefaultCapabilities(const AServerName, AServerVersion: string): TLspServerCapabilities;
begin
  Result := Default(TLspServerCapabilities);
  Result.ServerName := AServerName;
  Result.ServerVersion := AServerVersion;
  Result.TextDocumentSync := ltdskIncremental;
  Result.OpenCloseNotify := True;
  Result.SaveNotify := True;
  Result.SaveIncludeText := False;
end;

{ Safe JSON Helpers }

function JsonGetStr(AObj: TJSONObject; const AKey: string; const ADefault: string): string;
var
  D: TJSONData;
begin
  if AObj = nil then
    Exit(ADefault);
  D := AObj.Find(AKey);
  if (D = nil) or (D.JSONType = jtNull) then
    Exit(ADefault);
  if D.JSONType = jtString then
    Result := D.AsString
  else
    Result := ADefault;
end;

function JsonGetInt(AObj: TJSONObject; const AKey: string; ADefault: Integer): Integer;
var
  D: TJSONData;
begin
  if AObj = nil then
    Exit(ADefault);
  D := AObj.Find(AKey);
  if (D = nil) or (D.JSONType = jtNull) then
    Exit(ADefault);
  if D.JSONType = jtNumber then
    Result := D.AsInteger
  else
    Result := ADefault;
end;

function JsonGetBool(AObj: TJSONObject; const AKey: string; ADefault: Boolean): Boolean;
var
  D: TJSONData;
begin
  if AObj = nil then
    Exit(ADefault);
  D := AObj.Find(AKey);
  if (D = nil) or (D.JSONType = jtNull) then
    Exit(ADefault);
  if D.JSONType = jtBoolean then
    Result := D.AsBoolean
  else
    Result := ADefault;
end;

function JsonGetObj(AObj: TJSONObject; const AKey: string): TJSONObject;
var
  D: TJSONData;
begin
  if AObj = nil then
    Exit(nil);
  D := AObj.Find(AKey);
  if (D <> nil) and (D.JSONType = jtObject) then
    Result := TJSONObject(D)
  else
    Result := nil;
end;

function JsonGetArr(AObj: TJSONObject; const AKey: string): TJSONArray;
var
  D: TJSONData;
begin
  if AObj = nil then
    Exit(nil);
  D := AObj.Find(AKey);
  if (D <> nil) and (D.JSONType = jtArray) then
    Result := TJSONArray(D)
  else
    Result := nil;
end;

{ JSON Codecs }

function LspIdToJson(const AId: TLspId): TJSONData;
begin
  case AId.Kind of
    likNull:   Result := TJSONNull.Create;
    likInt:    Result := TJSONInt64Number.Create(AId.IntValue);
    likString: Result := TJSONString.Create(AId.StrValue);
  else
    raise ELspError.CreateFmt('Unexpected TLspIdKind ordinal: %d', [Ord(AId.Kind)]);
  end;
end;

function JsonToLspId(AData: TJSONData): TLspId;
begin
  if (AData = nil) or (AData.JSONType = jtNull) then
    Exit(TLspId.NullId);
  case AData.JSONType of
    jtNumber: Result := TLspId.FromInt(AData.AsInt64);
    jtString: Result := TLspId.FromString(AData.AsString);
  else
    raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
      'JSON-RPC request id must be an integer, string, or null.');
  end;
end;

function PositionToJson(const APos: TLspPosition): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('line', APos.Line);
  Result.Add('character', APos.Character);
end;

function JsonToPosition(AObj: TJSONObject): TLspPosition;
begin
  Result.Line := JsonGetInt(AObj, 'line', 0);
  Result.Character := JsonGetInt(AObj, 'character', 0);
  if Result.Line < 0 then
    Result.Line := 0;
  if Result.Character < 0 then
    Result.Character := 0;
end;

function RangeToJson(const ARange: TLspRange): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('start', PositionToJson(ARange.StartPos));
  Result.Add('end', PositionToJson(ARange.EndPos));
end;

function JsonToRange(AObj: TJSONObject): TLspRange;
begin
  if AObj = nil then
  begin
    Result := TLspRange.SingleLine(0, 0, 0);
    Exit;
  end;
  Result.StartPos := JsonToPosition(JsonGetObj(AObj, 'start'));
  Result.EndPos := JsonToPosition(JsonGetObj(AObj, 'end'));
end;

function LocationToJson(const ALoc: TLspLocation): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('uri', ALoc.Uri);
  Result.Add('range', RangeToJson(ALoc.Range));
end;

function LocationsToJson(const ALocs: TLspLocationArray): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(ALocs) do
    Result.Add(LocationToJson(ALocs[I]));
end;

function TextEditToJson(const AEdit: TLspTextEdit): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('range', RangeToJson(AEdit.Range));
  Result.Add('newText', AEdit.NewText);
end;

function DiagnosticToJson(const ADiag: TLspDiagnostic): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('range', RangeToJson(ADiag.Range));
  if ADiag.Severity <> ldsUnspecified then
    Result.Add('severity', Ord(ADiag.Severity));
  if ADiag.HasCode then
  begin
    if ADiag.StrCode <> '' then
      Result.Add('code', ADiag.StrCode)
    else
      Result.Add('code', ADiag.IntCode);
  end;
  if ADiag.Source <> '' then
    Result.Add('source', ADiag.Source);
  Result.Add('message', ADiag.Message);
end;

function DiagnosticsToJson(const ADiags: TLspDiagnosticArray): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(ADiags) do
    Result.Add(DiagnosticToJson(ADiags[I]));
end;

function BuildDocumentSymbolNodeJson(const ASymbols: TLspDocumentSymbolArray; AIndex: Integer): TJSONObject;
var
  Sym: TLspDocumentSymbol;
  ChildrenArr: TJSONArray;
  J: Integer;
begin
  Sym := ASymbols[AIndex];
  Result := TJSONObject.Create;
  Result.Add('name', Sym.Name);
  if Sym.Detail <> '' then
    Result.Add('detail', Sym.Detail);
  Result.Add('kind', Ord(Sym.Kind));
  Result.Add('range', RangeToJson(Sym.Range));
  Result.Add('selectionRange', RangeToJson(Sym.SelectionRange));

  ChildrenArr := nil;
  for J := 0 to High(ASymbols) do
  begin
    if (J <> AIndex) and (ASymbols[J].ParentIndex = AIndex) then
    begin
      if ChildrenArr = nil then
        ChildrenArr := TJSONArray.Create;
      ChildrenArr.Add(BuildDocumentSymbolNodeJson(ASymbols, J));
    end;
  end;
  if ChildrenArr <> nil then
    Result.Add('children', ChildrenArr);
end;

function DocumentSymbolsToJson(const ASymbols: TLspDocumentSymbolArray): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(ASymbols) do
  begin
    if (ASymbols[I].ParentIndex < 0) or (ASymbols[I].ParentIndex >= Length(ASymbols)) then
      Result.Add(BuildDocumentSymbolNodeJson(ASymbols, I));
  end;
end;

function SymbolInfosToJson(const ASymbols: TLspSymbolInformationArray): TJSONArray;
var
  I: Integer;
  Obj: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(ASymbols) do
  begin
    Obj := TJSONObject.Create;
    Obj.Add('name', ASymbols[I].Name);
    Obj.Add('kind', Ord(ASymbols[I].Kind));
    Obj.Add('location', LocationToJson(ASymbols[I].Location));
    if ASymbols[I].ContainerName <> '' then
      Obj.Add('containerName', ASymbols[I].ContainerName);
    Result.Add(Obj);
  end;
end;

function MarkupContentToJson(const AMarkdown: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('kind', 'markdown');
  Result.Add('value', AMarkdown);
end;

function CompletionItemToJson(const AItem: TLspCompletionItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('label', AItem.LabelText);
  if AItem.Kind <> lcikUnspecified then
    Result.Add('kind', Ord(AItem.Kind));
  if AItem.Detail <> '' then
    Result.Add('detail', AItem.Detail);
  if AItem.DocumentationMarkdown <> '' then
    Result.Add('documentation', MarkupContentToJson(AItem.DocumentationMarkdown));
  if AItem.SortText <> '' then
    Result.Add('sortText', AItem.SortText);
  if AItem.FilterText <> '' then
    Result.Add('filterText', AItem.FilterText);
  if AItem.InsertText <> '' then
    Result.Add('insertText', AItem.InsertText);
  if AItem.InsertTextFormat <> litfUnspecified then
    Result.Add('insertTextFormat', Ord(AItem.InsertTextFormat));
  if AItem.HasTextEdit then
    Result.Add('textEdit', TextEditToJson(AItem.TextEdit));
end;

function CompletionListToJson(const AList: TLspCompletionList): TJSONObject;
var
  ItemsArr: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('isIncomplete', AList.IsIncomplete);
  ItemsArr := TJSONArray.Create;
  for I := 0 to High(AList.Items) do
    ItemsArr.Add(CompletionItemToJson(AList.Items[I]));
  Result.Add('items', ItemsArr);
end;

function HoverToJson(const AHover: TLspHover): TJSONData;
var
  Obj: TJSONObject;
begin
  if not AHover.HasValue then
    Exit(TJSONNull.Create);
  Obj := TJSONObject.Create;
  Obj.Add('contents', MarkupContentToJson(AHover.Markdown));
  if AHover.HasRange then
    Obj.Add('range', RangeToJson(AHover.Range));
  Result := Obj;
end;

function SignatureHelpToJson(const AHelp: TLspSignatureHelp): TJSONData;
var
  Obj, SigObj, ParamObj: TJSONObject;
  SigsArr, ParamsArr: TJSONArray;
  I, J: Integer;
begin
  if Length(AHelp.Signatures) = 0 then
    Exit(TJSONNull.Create);

  Obj := TJSONObject.Create;
  SigsArr := TJSONArray.Create;
  for I := 0 to High(AHelp.Signatures) do
  begin
    SigObj := TJSONObject.Create;
    SigObj.Add('label', AHelp.Signatures[I].LabelText);
    if AHelp.Signatures[I].DocumentationMarkdown <> '' then
      SigObj.Add('documentation', MarkupContentToJson(AHelp.Signatures[I].DocumentationMarkdown));
    if Length(AHelp.Signatures[I].Parameters) > 0 then
    begin
      ParamsArr := TJSONArray.Create;
      for J := 0 to High(AHelp.Signatures[I].Parameters) do
      begin
        ParamObj := TJSONObject.Create;
        ParamObj.Add('label', AHelp.Signatures[I].Parameters[J].LabelText);
        if AHelp.Signatures[I].Parameters[J].DocumentationMarkdown <> '' then
          ParamObj.Add('documentation', MarkupContentToJson(AHelp.Signatures[I].Parameters[J].DocumentationMarkdown));
        ParamsArr.Add(ParamObj);
      end;
      SigObj.Add('parameters', ParamsArr);
    end;
    SigsArr.Add(SigObj);
  end;
  Obj.Add('signatures', SigsArr);
  Obj.Add('activeSignature', AHelp.ActiveSignature);
  Obj.Add('activeParameter', AHelp.ActiveParameter);
  Result := Obj;
end;

function StringArrayToJson(const AItems: TLspStringArray): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(AItems) do
    Result.Add(AItems[I]);
end;

function CapabilitiesToInitializeResultJson(const ACaps: TLspServerCapabilities): TJSONObject;
var
  CapsObj, SyncObj, SaveObj, CompObj, SigObj, InfoObj: TJSONObject;
begin
  Result := TJSONObject.Create;
  CapsObj := TJSONObject.Create;

  SyncObj := TJSONObject.Create;
  SyncObj.Add('openClose', ACaps.OpenCloseNotify);
  SyncObj.Add('change', Ord(ACaps.TextDocumentSync));
  if ACaps.SaveNotify then
  begin
    SaveObj := TJSONObject.Create;
    SaveObj.Add('includeText', ACaps.SaveIncludeText);
    SyncObj.Add('save', SaveObj);
  end;
  CapsObj.Add('textDocumentSync', SyncObj);

  if ACaps.HoverProvider then
    CapsObj.Add('hoverProvider', True);
  if ACaps.DefinitionProvider then
    CapsObj.Add('definitionProvider', True);
  if ACaps.DeclarationProvider then
    CapsObj.Add('declarationProvider', True);
  if ACaps.ReferencesProvider then
    CapsObj.Add('referencesProvider', True);
  if ACaps.DocumentSymbolProvider then
    CapsObj.Add('documentSymbolProvider', True);
  if ACaps.WorkspaceSymbolProvider then
    CapsObj.Add('workspaceSymbolProvider', True);

  if ACaps.CompletionProvider then
  begin
    CompObj := TJSONObject.Create;
    if Length(ACaps.CompletionTriggerChars) > 0 then
      CompObj.Add('triggerCharacters', StringArrayToJson(ACaps.CompletionTriggerChars));
    CapsObj.Add('completionProvider', CompObj);
  end;

  if ACaps.SignatureHelpProvider then
  begin
    SigObj := TJSONObject.Create;
    if Length(ACaps.SignatureTriggerChars) > 0 then
      SigObj.Add('triggerCharacters', StringArrayToJson(ACaps.SignatureTriggerChars));
    CapsObj.Add('signatureHelpProvider', SigObj);
  end;

  Result.Add('capabilities', CapsObj);

  if ACaps.ServerName <> '' then
  begin
    InfoObj := TJSONObject.Create;
    InfoObj.Add('name', ACaps.ServerName);
    if ACaps.ServerVersion <> '' then
      InfoObj.Add('version', ACaps.ServerVersion);
    Result.Add('serverInfo', InfoObj);
  end;
end;

function JsonToInitializeParams(AObj: TJSONObject): TLspInitializeParams;
var
  PidData, InitOptData: TJSONData;
  ClientObj, FolderObj: TJSONObject;
  FoldersArr: TJSONArray;
  I, OutIdx: Integer;
begin
  Result := Default(TLspInitializeParams);
  if AObj = nil then
    Exit;

  PidData := AObj.Find('processId');
  if (PidData <> nil) and (PidData.JSONType = jtNumber) then
    Result.ProcessId.SetValue(PidData.AsInteger);

  ClientObj := JsonGetObj(AObj, 'clientInfo');
  if ClientObj <> nil then
  begin
    Result.ClientName := JsonGetStr(ClientObj, 'name');
    Result.ClientVersion := JsonGetStr(ClientObj, 'version');
  end;

  Result.RootUri := JsonGetStr(AObj, 'rootUri');
  Result.RootPath := JsonGetStr(AObj, 'rootPath');
  Result.Trace := JsonGetStr(AObj, 'trace', 'off');

  FoldersArr := JsonGetArr(AObj, 'workspaceFolders');
  if FoldersArr <> nil then
  begin
    SetLength(Result.WorkspaceFolders, FoldersArr.Count);
    OutIdx := 0;
    for I := 0 to FoldersArr.Count - 1 do
    begin
      if FoldersArr.Items[I].JSONType = jtObject then
      begin
        FolderObj := TJSONObject(FoldersArr.Items[I]);
        Result.WorkspaceFolders[OutIdx].Uri := JsonGetStr(FolderObj, 'uri');
        Result.WorkspaceFolders[OutIdx].Name := JsonGetStr(FolderObj, 'name');
        Inc(OutIdx);
      end;
    end;
    SetLength(Result.WorkspaceFolders, OutIdx);
  end;

  InitOptData := AObj.Find('initializationOptions');
  if (InitOptData <> nil) and (InitOptData.JSONType <> jtNull) then
    Result.InitializationOptionsJson := InitOptData.AsJSON;
end;

function JsonToContentChanges(AArr: TJSONArray): TLspContentChangeArray;
var
  I, OutIdx: Integer;
  ItemObj, RangeObj: TJSONObject;
begin
  Result := nil;
  if AArr = nil then
    Exit;

  SetLength(Result, AArr.Count);
  OutIdx := 0;
  for I := 0 to AArr.Count - 1 do
  begin
    if AArr.Items[I].JSONType = jtObject then
    begin
      ItemObj := TJSONObject(AArr.Items[I]);
      RangeObj := JsonGetObj(ItemObj, 'range');
      Result[OutIdx].HasRange := RangeObj <> nil;
      if RangeObj <> nil then
        Result[OutIdx].Range := JsonToRange(RangeObj)
      else
        Result[OutIdx].Range := TLspRange.SingleLine(0, 0, 0);
      Result[OutIdx].Text := JsonGetStr(ItemObj, 'text');
      Inc(OutIdx);
    end;
  end;
  SetLength(Result, OutIdx);
end;

function JsonToFileEvents(AArr: TJSONArray): TLspFileEventArray;
var
  I, OutIdx, RawType: Integer;
  ItemObj: TJSONObject;
begin
  Result := nil;
  if AArr = nil then
    Exit;

  SetLength(Result, AArr.Count);
  OutIdx := 0;
  for I := 0 to AArr.Count - 1 do
  begin
    if AArr.Items[I].JSONType = jtObject then
    begin
      ItemObj := TJSONObject(AArr.Items[I]);
      Result[OutIdx].Uri := JsonGetStr(ItemObj, 'uri');
      if Result[OutIdx].Uri = '' then
        Continue;
      RawType := JsonGetInt(ItemObj, 'type', 2);
      case RawType of
        1: Result[OutIdx].ChangeType := lfctCreated;
        2: Result[OutIdx].ChangeType := lfctChanged;
        3: Result[OutIdx].ChangeType := lfctDeleted;
      else
        Result[OutIdx].ChangeType := lfctChanged;
      end;
      Inc(OutIdx);
    end;
  end;
  SetLength(Result, OutIdx);
end;

end.
