unit nikrun.lsp.server;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson,
  nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.transport,
  nikrun.lsp.jsonrpc, nikrun.lsp.documents;

type
  TLspLifecycleState = (
    llsUninitialized,
    llsInitialized,
    llsShutDown,
    llsExited
  );

  TLspLogEvent = procedure(const AMessage: string) of object;

  TLspServer = class
  private
    FTransport: TLspTransport;
    FOwnsTransport: Boolean;
    FDocuments: TLspDocumentStore;
    FCancellations: TLspCancellationTracker;
    FState: TLspLifecycleState;
    FExitCode: Integer;
    FNextServerRequestId: Int64;
    FInitParams: TLspInitializeParams;
    FCapabilities: TLspServerCapabilities;
    FOnLog: TLspLogEvent;

    procedure HandleRawPayload(const APayload: string);
    function DispatchRequest(AMsg: TLspRpcMessage): TJSONData;
    procedure DispatchNotification(AMsg: TLspRpcMessage);

    function HandleInitialize(AParamsObj: TJSONObject): TJSONData;
    procedure HandleDidOpen(AParamsObj: TJSONObject);
    procedure HandleDidChange(AParamsObj: TJSONObject);
    procedure HandleDidSave(AParamsObj: TJSONObject);
    procedure HandleDidClose(AParamsObj: TJSONObject);
    procedure HandleDidChangeWatchedFiles(AParamsObj: TJSONObject);

    function ExtractDocAndPos(AParamsObj: TJSONObject; out AUri: string;
      out ADoc: TLspDocument; out APos: TLspPosition): Boolean;
  protected
    procedure Log(const AMessage: string);
    procedure LogFmt(const AFmt: string; const AArgs: array of const);
    function IsRequestCancelled(const AId: TLspId): Boolean;

    // Virtual lifecycle & document hooks for concrete language server subclasses
    procedure ConfigureCapabilities(const AParams: TLspInitializeParams;
      var ACaps: TLspServerCapabilities); virtual;
    procedure DoInitialized; virtual;
    procedure DoShutdown; virtual;

    procedure DoDidOpen(ADoc: TLspDocument); virtual;
    procedure DoDidChange(ADoc: TLspDocument); virtual;
    procedure DoDidSave(ADoc: TLspDocument; const AHasSavedText: Boolean; const ASavedText: string); virtual;
    procedure DoDidClose(const AUri, AFilePath: string); virtual;
    procedure DoDidChangeWatchedFiles(const AChanges: TLspFileEventArray); virtual;

    { Non-blocking event loop hooks: return < 0 to block indefinitely until next incoming message,
      or >= 0 (ms) when a debounced validation or background child check needs periodic ticking. }
    function GetIdleTickTimeoutMs: Integer; virtual;
    procedure DoIdleTick; virtual;

    // Virtual LSP language feature hooks
    function DoDocumentSymbol(const AUri: string; ADoc: TLspDocument): TLspDocumentSymbolArray; virtual;
    function DoWorkspaceSymbol(const AQuery: string): TLspSymbolInformationArray; virtual;
    function DoDefinition(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspLocationArray; virtual;
    function DoDeclaration(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspLocationArray; virtual;
    function DoReferences(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition; AIncludeDeclaration: Boolean): TLspLocationArray; virtual;
    function DoHover(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspHover; virtual;
    function DoCompletion(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition; const ATriggerChar: string): TLspCompletionList; virtual;
    function DoSignatureHelp(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition; const ATriggerChar: string): TLspSignatureHelp; virtual;

    // Extensibility hooks for custom requests & notifications
    function DoCustomRequest(const AMethod: string; AParams: TJSONData;
      out AHandled: Boolean): TJSONData; virtual;
    procedure DoCustomNotification(const AMethod: string; AParams: TJSONData); virtual;
    procedure DoClientResponse(AMsg: TLspRpcMessage); virtual;
  public
    constructor Create(ATransport: TLspTransport; AOwnsTransport: Boolean = True);
    destructor Destroy; override;

    { Runs the blocking JSON-RPC message loop until EOF or 'exit' notification.
      Returns 0 on clean shutdown+exit (or EOF after shutdown), 1 on ungraceful exit. }
    function Run: Integer;

    { Processes a single incoming frame from Transport; returns False on EOF or 'exit'. }
    function ProcessSingleMessage: Boolean;

    // Server -> Client notifications & requests
    procedure PublishDiagnostics(const AUri: string; const ADiagnostics: TLspDiagnosticArray;
      AVersion: Integer = -1);
    procedure ClearDiagnostics(const AUri: string);
    procedure SendLogMessage(AType: TLspMessageType; const AMessage: string);
    procedure SendShowMessage(AType: TLspMessageType; const AMessage: string);
    procedure SendNotification(const AMethod: string; AParams: TJSONData);
    function SendServerRequest(const AMethod: string; AParams: TJSONData): TLspId;

    property Transport: TLspTransport read FTransport;
    property Documents: TLspDocumentStore read FDocuments;
    property State: TLspLifecycleState read FState;
    property ExitCode: Integer read FExitCode;
    property InitParams: TLspInitializeParams read FInitParams;
    property Capabilities: TLspServerCapabilities read FCapabilities;
    property OnLog: TLspLogEvent read FOnLog write FOnLog;
  end;

implementation

constructor TLspServer.Create(ATransport: TLspTransport; AOwnsTransport: Boolean);
begin
  inherited Create;
  if ATransport = nil then
    raise ELspError.Create('TLspServer requires a non-nil TLspTransport instance.');
  FTransport := ATransport;
  FOwnsTransport := AOwnsTransport;
  FDocuments := TLspDocumentStore.Create;
  FCancellations := TLspCancellationTracker.Create;
  FState := llsUninitialized;
  FExitCode := 0;
  FNextServerRequestId := 1;
end;

destructor TLspServer.Destroy;
begin
  FreeAndNil(FCancellations);
  FreeAndNil(FDocuments);
  if FOwnsTransport then
    FreeAndNil(FTransport);
  inherited Destroy;
end;

procedure TLspServer.Log(const AMessage: string);
begin
  if Assigned(FOnLog) then
    FOnLog(AMessage);
end;

procedure TLspServer.LogFmt(const AFmt: string; const AArgs: array of const);
begin
  if Assigned(FOnLog) then
    FOnLog(Format(AFmt, AArgs));
end;

function TLspServer.IsRequestCancelled(const AId: TLspId): Boolean;
begin
  Result := FCancellations.IsCancelled(AId);
end;

function TLspServer.Run: Integer;
var
  TimeoutMs: Integer;
begin
  while FState <> llsExited do
  begin
    if FState = llsInitialized then
    begin
      DoIdleTick;
      if FState = llsExited then
        Break;
      TimeoutMs := GetIdleTickTimeoutMs;
    end
    else
      TimeoutMs := -1;

    if FTransport.WaitForInput(TimeoutMs) then
    begin
      if not ProcessSingleMessage then
        Break;
    end;
  end;
  Result := FExitCode;
end;

function TLspServer.ProcessSingleMessage: Boolean;
var
  Payload: string;
begin
  if FState = llsExited then
    Exit(False);

  try
    if not FTransport.ReadMessage(Payload) then
      Exit(False);
  except
    on E: ELspProtocolError do
    begin
      LogFmt('Framing error (%d): %s', [E.Code, E.Message]);
      FTransport.WriteMessage(BuildRpcErrorJson(TLspId.NullId, E.Code, E.Message));
      Exit(True);
    end;
  end;

  HandleRawPayload(Payload);
  Result := FState <> llsExited;
end;

procedure TLspServer.HandleRawPayload(const APayload: string);
var
  Msg: TLspRpcMessage;
  ResData: TJSONData;
begin
  Msg := nil;
  try
    try
      Msg := ParseRpcMessage(APayload);
    except
      on E: ELspProtocolError do
      begin
        LogFmt('JSON-RPC parse/validation error (%d): %s', [E.Code, E.Message]);
        FTransport.WriteMessage(BuildRpcErrorJson(TLspId.NullId, E.Code, E.Message));
        Exit;
      end;
    end;

    case Msg.Kind of
      lrmkRequest:
        begin
          LogFmt('--> Request [%s] %s', [Msg.Id.ToKeyString, Msg.Method]);
          try
            if FCancellations.IsCancelled(Msg.Id) then
              raise ELspProtocolError.Create(LSP_ERR_REQUEST_CANCELLED, 'Request cancelled by client.');

            ResData := DispatchRequest(Msg);

            if FCancellations.IsCancelled(Msg.Id) then
            begin
              FreeAndNil(ResData);
              raise ELspProtocolError.Create(LSP_ERR_REQUEST_CANCELLED, 'Request cancelled by client.');
            end;

            FTransport.WriteMessage(BuildRpcResultJson(Msg.Id, ResData));
          except
            on E: ELspProtocolError do
            begin
              LogFmt('<-- Error [%s] (%d): %s', [Msg.Id.ToKeyString, E.Code, E.Message]);
              FTransport.WriteMessage(BuildRpcErrorJson(Msg.Id, E.Code, E.Message));
            end;
            on E: Exception do
            begin
              LogFmt('<-- Internal error [%s]: %s', [Msg.Id.ToKeyString, E.Message]);
              FTransport.WriteMessage(BuildRpcErrorJson(Msg.Id, LSP_ERR_INTERNAL_ERROR, E.Message));
            end;
          end;
          FCancellations.ClearId(Msg.Id);
        end;

      lrmkNotification:
        begin
          LogFmt('--> Notification %s', [Msg.Method]);
          try
            DispatchNotification(Msg);
          except
            on E: Exception do
              LogFmt('Unhandled exception in notification %s: %s', [Msg.Method, E.Message]);
          end;
        end;

      lrmkResponse:
        begin
          LogFmt('--> Client response [%s]', [Msg.Id.ToKeyString]);
          DoClientResponse(Msg);
        end;
    else
      raise ELspError.CreateFmt('Unexpected TLspRpcMessageKind ordinal: %d', [Ord(Msg.Kind)]);
    end;
  finally
    FreeAndNil(Msg);
  end;
end;

function TLspServer.ExtractDocAndPos(AParamsObj: TJSONObject; out AUri: string;
  out ADoc: TLspDocument; out APos: TLspPosition): Boolean;
var
  DocObj, PosObj: TJSONObject;
begin
  AUri := '';
  ADoc := nil;
  APos := TLspPosition.Create(0, 0);
  if AParamsObj = nil then
    Exit(False);

  DocObj := JsonGetObj(AParamsObj, 'textDocument');
  if DocObj = nil then
    Exit(False);
  AUri := JsonGetStr(DocObj, 'uri');
  if AUri = '' then
    Exit(False);

  PosObj := JsonGetObj(AParamsObj, 'position');
  if PosObj <> nil then
    APos := JsonToPosition(PosObj);

  ADoc := FDocuments.FindDocument(AUri);
  Result := True;
end;

function TLspServer.HandleInitialize(AParamsObj: TJSONObject): TJSONData;
begin
  if FState <> llsUninitialized then
    raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
      'LSP server has already been initialized.');

  FInitParams := JsonToInitializeParams(AParamsObj);
  FCapabilities := TLspServerCapabilities.DefaultCapabilities('nikrun-lsp', '0.1.0');
  ConfigureCapabilities(FInitParams, FCapabilities);

  FState := llsInitialized;
  Result := CapabilitiesToInitializeResultJson(FCapabilities);
end;

function TLspServer.DispatchRequest(AMsg: TLspRpcMessage): TJSONData;
var
  M, Uri, Query, TrigChar: string;
  ParamsObj, ContextObj: TJSONObject;
  Doc: TLspDocument;
  Pos: TLspPosition;
  IncludeDecl, CustomHandled: Boolean;
begin
  M := AMsg.Method;
  ParamsObj := AMsg.ParamsAsObject;

  if FState = llsUninitialized then
  begin
    if M = 'initialize' then
      Exit(HandleInitialize(ParamsObj));
    raise ELspProtocolError.Create(LSP_ERR_SERVER_NOT_INITIALIZED,
      'Server has not received an "initialize" request yet.');
  end;

  if FState = llsShutDown then
    raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
      'Server is shutting down and cannot accept new requests.');

  if M = 'initialize' then
    Exit(HandleInitialize(ParamsObj));

  if M = 'shutdown' then
  begin
    FState := llsShutDown;
    DoShutdown;
    Exit(TJSONNull.Create);
  end;

  if M = 'textDocument/documentSymbol' then
  begin
    if not ExtractDocAndPos(ParamsObj, Uri, Doc, Pos) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_PARAMS, 'Missing textDocument.uri in documentSymbol request.');
    Exit(DocumentSymbolsToJson(DoDocumentSymbol(Uri, Doc)));
  end;

  if M = 'workspace/symbol' then
  begin
    Query := JsonGetStr(ParamsObj, 'query');
    Exit(SymbolInfosToJson(DoWorkspaceSymbol(Query)));
  end;

  if M = 'textDocument/definition' then
  begin
    if not ExtractDocAndPos(ParamsObj, Uri, Doc, Pos) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_PARAMS, 'Invalid textDocumentPositionParams.');
    Exit(LocationsToJson(DoDefinition(Uri, Doc, Pos)));
  end;

  if M = 'textDocument/declaration' then
  begin
    if not ExtractDocAndPos(ParamsObj, Uri, Doc, Pos) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_PARAMS, 'Invalid textDocumentPositionParams.');
    Exit(LocationsToJson(DoDeclaration(Uri, Doc, Pos)));
  end;

  if M = 'textDocument/references' then
  begin
    if not ExtractDocAndPos(ParamsObj, Uri, Doc, Pos) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_PARAMS, 'Invalid ReferenceParams.');
    ContextObj := JsonGetObj(ParamsObj, 'context');
    IncludeDecl := JsonGetBool(ContextObj, 'includeDeclaration', True);
    Exit(LocationsToJson(DoReferences(Uri, Doc, Pos, IncludeDecl)));
  end;

  if M = 'textDocument/hover' then
  begin
    if not ExtractDocAndPos(ParamsObj, Uri, Doc, Pos) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_PARAMS, 'Invalid HoverParams.');
    Exit(HoverToJson(DoHover(Uri, Doc, Pos)));
  end;

  if M = 'textDocument/completion' then
  begin
    if not ExtractDocAndPos(ParamsObj, Uri, Doc, Pos) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_PARAMS, 'Invalid CompletionParams.');
    ContextObj := JsonGetObj(ParamsObj, 'context');
    TrigChar := JsonGetStr(ContextObj, 'triggerCharacter');
    Exit(CompletionListToJson(DoCompletion(Uri, Doc, Pos, TrigChar)));
  end;

  if M = 'textDocument/signatureHelp' then
  begin
    if not ExtractDocAndPos(ParamsObj, Uri, Doc, Pos) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_PARAMS, 'Invalid SignatureHelpParams.');
    ContextObj := JsonGetObj(ParamsObj, 'context');
    TrigChar := JsonGetStr(ContextObj, 'triggerCharacter');
    Exit(SignatureHelpToJson(DoSignatureHelp(Uri, Doc, Pos, TrigChar)));
  end;

  CustomHandled := False;
  Result := DoCustomRequest(M, AMsg.Params, CustomHandled);
  if CustomHandled then
    Exit;

  FreeAndNil(Result);
  raise ELspProtocolError.Create(LSP_ERR_METHOD_NOT_FOUND,
    Format('Unsupported LSP request method: ''%s''', [M]));
end;

procedure TLspServer.HandleDidOpen(AParamsObj: TJSONObject);
var
  DocObj: TJSONObject;
  Uri, LangId, TextBody: string;
  Ver: Integer;
  Doc: TLspDocument;
begin
  DocObj := JsonGetObj(AParamsObj, 'textDocument');
  if DocObj = nil then
    Exit;
  Uri := JsonGetStr(DocObj, 'uri');
  if Uri = '' then
    Exit;
  LangId := JsonGetStr(DocObj, 'languageId');
  Ver := JsonGetInt(DocObj, 'version', 0);
  TextBody := JsonGetStr(DocObj, 'text');
  Doc := FDocuments.OpenDocument(Uri, LangId, Ver, TextBody);
  DoDidOpen(Doc);
end;

procedure TLspServer.HandleDidChange(AParamsObj: TJSONObject);
var
  DocObj: TJSONObject;
  ChangesArr: TJSONArray;
  Uri: string;
  Ver: Integer;
  Changes: TLspContentChangeArray;
  Doc: TLspDocument;
begin
  DocObj := JsonGetObj(AParamsObj, 'textDocument');
  if DocObj = nil then
    Exit;
  Uri := JsonGetStr(DocObj, 'uri');
  if Uri = '' then
    Exit;
  Ver := JsonGetInt(DocObj, 'version', -1);
  ChangesArr := JsonGetArr(AParamsObj, 'contentChanges');
  Changes := JsonToContentChanges(ChangesArr);
  Doc := FDocuments.ChangeDocument(Uri, Ver, Changes);
  if Doc <> nil then
    DoDidChange(Doc);
end;

procedure TLspServer.HandleDidSave(AParamsObj: TJSONObject);
var
  DocObj: TJSONObject;
  TextField: TJSONData;
  Uri, SavedText: string;
  HasSavedText: Boolean;
  Doc: TLspDocument;
begin
  DocObj := JsonGetObj(AParamsObj, 'textDocument');
  if DocObj = nil then
    Exit;
  Uri := JsonGetStr(DocObj, 'uri');
  if Uri = '' then
    Exit;
  TextField := nil;
  if AParamsObj <> nil then
    TextField := AParamsObj.Find('text');
  HasSavedText := (TextField <> nil) and (TextField.JSONType = jtString);
  if HasSavedText then
    SavedText := TextField.AsString
  else
    SavedText := '';

  Doc := FDocuments.FindDocument(Uri);
  if (Doc <> nil) and HasSavedText then
    Doc.SetFullText(SavedText, Doc.Version);

  DoDidSave(Doc, HasSavedText, SavedText);
end;

procedure TLspServer.HandleDidClose(AParamsObj: TJSONObject);
var
  DocObj: TJSONObject;
  Uri, LocalPath: string;
begin
  DocObj := JsonGetObj(AParamsObj, 'textDocument');
  if DocObj = nil then
    Exit;
  Uri := JsonGetStr(DocObj, 'uri');
  if Uri = '' then
    Exit;
  LocalPath := UriToFilePath(Uri);
  FDocuments.CloseDocument(Uri);
  DoDidClose(Uri, LocalPath);
end;

procedure TLspServer.HandleDidChangeWatchedFiles(AParamsObj: TJSONObject);
var
  ChangesArr: TJSONArray;
  Events: TLspFileEventArray;
begin
  if AParamsObj = nil then
    Exit;
  ChangesArr := JsonGetArr(AParamsObj, 'changes');
  Events := JsonToFileEvents(ChangesArr);
  if Length(Events) > 0 then
    DoDidChangeWatchedFiles(Events);
end;

procedure TLspServer.DispatchNotification(AMsg: TLspRpcMessage);
var
  M: string;
  ParamsObj: TJSONObject;
  CancelIdData: TJSONData;
begin
  M := AMsg.Method;
  ParamsObj := AMsg.ParamsAsObject;

  if M = 'exit' then
  begin
    if FState = llsShutDown then
      FExitCode := 0
    else
      FExitCode := 1;
    FState := llsExited;
    Exit;
  end;

  if FState = llsUninitialized then
    Exit; // Per LSP spec, drop notifications other than 'exit' prior to initialize

  if M = '$/cancelRequest' then
  begin
    if ParamsObj <> nil then
    begin
      CancelIdData := ParamsObj.Find('id');
      if CancelIdData <> nil then
        FCancellations.MarkCancelled(JsonToLspId(CancelIdData));
    end;
    Exit;
  end;

  if M = '$/setTrace' then
  begin
    FInitParams.Trace := JsonGetStr(ParamsObj, 'value', FInitParams.Trace);
    Exit;
  end;

  if FState = llsShutDown then
    Exit;

  if M = 'initialized' then
  begin
    DoInitialized;
    Exit;
  end;

  if M = 'textDocument/didOpen' then
  begin
    HandleDidOpen(ParamsObj);
    Exit;
  end;

  if M = 'textDocument/didChange' then
  begin
    HandleDidChange(ParamsObj);
    Exit;
  end;

  if M = 'textDocument/didSave' then
  begin
    HandleDidSave(ParamsObj);
    Exit;
  end;

  if M = 'textDocument/didClose' then
  begin
    HandleDidClose(ParamsObj);
    Exit;
  end;

  if M = 'workspace/didChangeWatchedFiles' then
  begin
    HandleDidChangeWatchedFiles(ParamsObj);
    Exit;
  end;

  DoCustomNotification(M, AMsg.Params);
end;

{ Default Virtual Hooks }

procedure TLspServer.ConfigureCapabilities(const AParams: TLspInitializeParams;
  var ACaps: TLspServerCapabilities);
begin
  // Default capabilities already populated; subclasses customize flags here.
end;

procedure TLspServer.DoInitialized;
begin
end;

procedure TLspServer.DoShutdown;
begin
end;

procedure TLspServer.DoDidOpen(ADoc: TLspDocument);
begin
end;

procedure TLspServer.DoDidChange(ADoc: TLspDocument);
begin
end;

procedure TLspServer.DoDidSave(ADoc: TLspDocument; const AHasSavedText: Boolean; const ASavedText: string);
begin
end;

procedure TLspServer.DoDidClose(const AUri, AFilePath: string);
begin
end;

procedure TLspServer.DoDidChangeWatchedFiles(const AChanges: TLspFileEventArray);
begin
end;

function TLspServer.GetIdleTickTimeoutMs: Integer;
begin
  Result := -1;
end;

procedure TLspServer.DoIdleTick;
begin
end;

function TLspServer.DoDocumentSymbol(const AUri: string; ADoc: TLspDocument): TLspDocumentSymbolArray;
begin
  Result := nil;
end;

function TLspServer.DoWorkspaceSymbol(const AQuery: string): TLspSymbolInformationArray;
begin
  Result := nil;
end;

function TLspServer.DoDefinition(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspLocationArray;
begin
  Result := nil;
end;

function TLspServer.DoDeclaration(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspLocationArray;
begin
  Result := DoDefinition(AUri, ADoc, APos);
end;

function TLspServer.DoReferences(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition; AIncludeDeclaration: Boolean): TLspLocationArray;
begin
  Result := nil;
end;

function TLspServer.DoHover(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspHover;
begin
  Result := Default(TLspHover);
end;

function TLspServer.DoCompletion(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition; const ATriggerChar: string): TLspCompletionList;
begin
  Result := Default(TLspCompletionList);
end;

function TLspServer.DoSignatureHelp(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition; const ATriggerChar: string): TLspSignatureHelp;
begin
  Result := Default(TLspSignatureHelp);
end;

function TLspServer.DoCustomRequest(const AMethod: string; AParams: TJSONData;
  out AHandled: Boolean): TJSONData;
begin
  AHandled := False;
  Result := nil;
end;

procedure TLspServer.DoCustomNotification(const AMethod: string; AParams: TJSONData);
begin
end;

procedure TLspServer.DoClientResponse(AMsg: TLspRpcMessage);
begin
end;

{ Outgoing Server -> Client Helpers }

procedure TLspServer.PublishDiagnostics(const AUri: string;
  const ADiagnostics: TLspDiagnosticArray; AVersion: Integer);
var
  Params: TJSONObject;
begin
  Params := TJSONObject.Create;
  Params.Add('uri', AUri);
  if AVersion >= 0 then
    Params.Add('version', AVersion);
  Params.Add('diagnostics', DiagnosticsToJson(ADiagnostics));
  SendNotification('textDocument/publishDiagnostics', Params);
end;

procedure TLspServer.ClearDiagnostics(const AUri: string);
var
  EmptyDiags: TLspDiagnosticArray;
begin
  EmptyDiags := nil;
  PublishDiagnostics(AUri, EmptyDiags);
end;

procedure TLspServer.SendLogMessage(AType: TLspMessageType; const AMessage: string);
var
  Params: TJSONObject;
begin
  Params := TJSONObject.Create;
  Params.Add('type', Ord(AType));
  Params.Add('message', AMessage);
  SendNotification('window/logMessage', Params);
end;

procedure TLspServer.SendShowMessage(AType: TLspMessageType; const AMessage: string);
var
  Params: TJSONObject;
begin
  Params := TJSONObject.Create;
  Params.Add('type', Ord(AType));
  Params.Add('message', AMessage);
  SendNotification('window/showMessage', Params);
end;

procedure TLspServer.SendNotification(const AMethod: string; AParams: TJSONData);
begin
  LogFmt('<-- Notification %s', [AMethod]);
  FTransport.WriteMessage(BuildRpcNotificationJson(AMethod, AParams));
end;

function TLspServer.SendServerRequest(const AMethod: string; AParams: TJSONData): TLspId;
begin
  Result := TLspId.FromInt(FNextServerRequestId);
  Inc(FNextServerRequestId);
  LogFmt('<-- Server request [%s] %s', [Result.ToKeyString, AMethod]);
  FTransport.WriteMessage(BuildRpcRequestJson(Result, AMethod, AParams));
end;

end.
