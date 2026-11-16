unit nikrun.lsp.jsonrpc;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, nikrun.lsp.types;

type
  TLspRpcMessageKind = (
    lrmkRequest,      // Has "method" and "id"
    lrmkNotification, // Has "method" and no "id"
    lrmkResponse      // Has "id" and ("result" or "error"), no "method"
  );

  TLspRpcMessage = class
  private
    FRoot: TJSONObject;
    FKind: TLspRpcMessageKind;
    FId: TLspId;
    FMethod: string;
    FParams: TJSONData;
    FResultData: TJSONData;
    FErrorObj: TJSONObject;
  public
    constructor CreateParsed(ARoot: TJSONObject; AKind: TLspRpcMessageKind;
      const AId: TLspId; const AMethod: string;
      AParams, AResultData: TJSONData; AErrorObj: TJSONObject);
    destructor Destroy; override;

    function ParamsAsObject: TJSONObject;

    property Kind: TLspRpcMessageKind read FKind;
    property Id: TLspId read FId;
    property Method: string read FMethod;
    property Params: TJSONData read FParams;
    property ResultData: TJSONData read FResultData;
    property ErrorObj: TJSONObject read FErrorObj;
  end;

  { Tracks in-flight client request IDs cancelled via $/cancelRequest. }
  TLspCancellationTracker = class
  private
    FCancelledKeys: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure MarkCancelled(const AId: TLspId);
    function IsCancelled(const AId: TLspId): Boolean;
    procedure ClearId(const AId: TLspId);
  end;

function ParseRpcMessage(const APayload: string): TLspRpcMessage;

{ Outgoing JSON-RPC 2.0 builders (take ownership of AResult / AParams / AErrorData!) }
function BuildRpcResultJson(const AId: TLspId; AResult: TJSONData): string;
function BuildRpcErrorJson(const AId: TLspId; ACode: Integer; const AMessage: string;
  AErrorData: TJSONData = nil): string;
function BuildRpcNotificationJson(const AMethod: string; AParams: TJSONData): string;
function BuildRpcRequestJson(const AId: TLspId; const AMethod: string; AParams: TJSONData): string;

implementation

{ TLspRpcMessage }

constructor TLspRpcMessage.CreateParsed(ARoot: TJSONObject; AKind: TLspRpcMessageKind;
  const AId: TLspId; const AMethod: string;
  AParams, AResultData: TJSONData; AErrorObj: TJSONObject);
begin
  inherited Create;
  FRoot := ARoot;
  FKind := AKind;
  FId := AId;
  FMethod := AMethod;
  FParams := AParams;
  FResultData := AResultData;
  FErrorObj := AErrorObj;
end;

destructor TLspRpcMessage.Destroy;
begin
  FreeAndNil(FRoot);
  inherited Destroy;
end;

function TLspRpcMessage.ParamsAsObject: TJSONObject;
begin
  if (FParams <> nil) and (FParams.JSONType = jtObject) then
    Result := TJSONObject(FParams)
  else
    Result := nil;
end;

{ TLspCancellationTracker }

constructor TLspCancellationTracker.Create;
begin
  inherited Create;
  FCancelledKeys := TStringList.Create;
  FCancelledKeys.Sorted := True;
  FCancelledKeys.Duplicates := dupIgnore;
end;

destructor TLspCancellationTracker.Destroy;
begin
  FreeAndNil(FCancelledKeys);
  inherited Destroy;
end;

procedure TLspCancellationTracker.MarkCancelled(const AId: TLspId);
begin
  if not AId.IsEmpty then
    FCancelledKeys.Add(AId.ToKeyString);
end;

function TLspCancellationTracker.IsCancelled(const AId: TLspId): Boolean;
var
  Idx: Integer;
begin
  if AId.IsEmpty then
    Exit(False);
  Result := FCancelledKeys.Find(AId.ToKeyString, Idx);
end;

procedure TLspCancellationTracker.ClearId(const AId: TLspId);
var
  Idx: Integer;
begin
  if AId.IsEmpty then
    Exit;
  if FCancelledKeys.Find(AId.ToKeyString, Idx) then
    FCancelledKeys.Delete(Idx);
end;

{ JSON-RPC Parsing & Serialization }

function ParseRpcMessage(const APayload: string): TLspRpcMessage;
var
  Raw: TJSONData;
  Obj, ErrObj: TJSONObject;
  VerData, IdData, MethodData, ParamsData, ResData, ErrData: TJSONData;
  HasId, HasMethod: Boolean;
  MsgId: TLspId;
  MethodName: string;
  Kind: TLspRpcMessageKind;
begin
  Raw := nil;
  try
    Raw := GetJSON(APayload);
  except
    on E: Exception do
      raise ELspProtocolError.Create(LSP_ERR_PARSE_ERROR,
        'Invalid JSON in JSON-RPC payload: ' + E.Message);
  end;

  if (Raw = nil) or (Raw.JSONType <> jtObject) then
  begin
    FreeAndNil(Raw);
    raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
      'JSON-RPC message root must be a JSON object.');
  end;

  Obj := TJSONObject(Raw);
  try
    VerData := Obj.Find('jsonrpc');
    if (VerData = nil) or (VerData.JSONType <> jtString) or (VerData.AsString <> LSP_JSONRPC_VERSION) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
        'JSON-RPC message must specify "jsonrpc": "2.0".');

    IdData := Obj.Find('id');
    HasId := IdData <> nil;
    if HasId then
      MsgId := JsonToLspId(IdData)
    else
      MsgId := TLspId.NullId;

    MethodData := Obj.Find('method');
    HasMethod := MethodData <> nil;
    MethodName := '';
    if HasMethod then
    begin
      if MethodData.JSONType <> jtString then
        raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
          'JSON-RPC "method" field must be a string.');
      MethodName := MethodData.AsString;
      if MethodName = '' then
        raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
          'JSON-RPC "method" field cannot be empty.');
    end;

    ParamsData := Obj.Find('params');
    if (ParamsData <> nil) and
       (ParamsData.JSONType <> jtObject) and
       (ParamsData.JSONType <> jtArray) and
       (ParamsData.JSONType <> jtNull) then
      raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
        'JSON-RPC "params" must be a structured value (object or array).');

    ResData := Obj.Find('result');
    ErrData := Obj.Find('error');
    if (ErrData <> nil) and (ErrData.JSONType = jtObject) then
      ErrObj := TJSONObject(ErrData)
    else
      ErrObj := nil;

    if HasMethod then
    begin
      if HasId then
        Kind := lrmkRequest
      else
        Kind := lrmkNotification;
    end
    else if HasId and ((ResData <> nil) or (ErrData <> nil)) then
      Kind := lrmkResponse
    else
      raise ELspProtocolError.Create(LSP_ERR_INVALID_REQUEST,
        'JSON-RPC message is neither a valid request, notification, nor response.');

    Result := TLspRpcMessage.CreateParsed(Obj, Kind, MsgId, MethodName, ParamsData, ResData, ErrObj);
    Obj := nil; // Ownership transferred
  finally
    FreeAndNil(Obj);
  end;
end;

function SerializeCompactJson(AObj: TJSONObject): string;
begin
  Result := AObj.AsJSON;
end;

function BuildRpcResultJson(const AId: TLspId; AResult: TJSONData): string;
var
  Envelope: TJSONObject;
begin
  Envelope := TJSONObject.Create;
  try
    Envelope.Add('jsonrpc', LSP_JSONRPC_VERSION);
    Envelope.Add('id', LspIdToJson(AId));
    if AResult = nil then
      Envelope.Add('result', TJSONNull.Create)
    else
      Envelope.Add('result', AResult);
    Result := SerializeCompactJson(Envelope);
  finally
    Envelope.Free;
  end;
end;

function BuildRpcErrorJson(const AId: TLspId; ACode: Integer; const AMessage: string;
  AErrorData: TJSONData): string;
var
  Envelope, ErrObj: TJSONObject;
begin
  Envelope := TJSONObject.Create;
  try
    Envelope.Add('jsonrpc', LSP_JSONRPC_VERSION);
    Envelope.Add('id', LspIdToJson(AId));
    ErrObj := TJSONObject.Create;
    ErrObj.Add('code', ACode);
    ErrObj.Add('message', AMessage);
    if AErrorData <> nil then
      ErrObj.Add('data', AErrorData);
    Envelope.Add('error', ErrObj);
    Result := SerializeCompactJson(Envelope);
  finally
    Envelope.Free;
  end;
end;

function BuildRpcNotificationJson(const AMethod: string; AParams: TJSONData): string;
var
  Envelope: TJSONObject;
begin
  Envelope := TJSONObject.Create;
  try
    Envelope.Add('jsonrpc', LSP_JSONRPC_VERSION);
    Envelope.Add('method', AMethod);
    if AParams <> nil then
      Envelope.Add('params', AParams);
    Result := SerializeCompactJson(Envelope);
  finally
    Envelope.Free;
  end;
end;

function BuildRpcRequestJson(const AId: TLspId; const AMethod: string; AParams: TJSONData): string;
var
  Envelope: TJSONObject;
begin
  Envelope := TJSONObject.Create;
  try
    Envelope.Add('jsonrpc', LSP_JSONRPC_VERSION);
    Envelope.Add('id', LspIdToJson(AId));
    Envelope.Add('method', AMethod);
    if AParams <> nil then
      Envelope.Add('params', AParams);
    Result := SerializeCompactJson(Envelope);
  finally
    Envelope.Free;
  end;
end;

end.
