unit nikrun.lsp.server.test;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TServerLifecycleTests = class(TTestCase)
  published
    procedure TestFullServerLifecycleAndDispatch;
  end;

  TCompletionCodecTests = class(TTestCase)
  published
    procedure TestCompletionItemTextEditCodec;
  end;

implementation

uses
  SysUtils, Classes, fpjson, jsonparser,
  nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.utf16, nikrun.lsp.transport,
  nikrun.lsp.jsonrpc, nikrun.lsp.documents, nikrun.lsp.server;

procedure Chk(ACondition: Boolean; const AMessage: string);
begin
  TAssert.AssertTrue(AMessage, ACondition);
end;

procedure ChkEqStr(const AActual, AExpected, AContext: string);
begin
  TAssert.AssertEquals(AContext, AExpected, AActual);
end;

procedure ChkEqInt(AActual, AExpected: Int64; const AContext: string);
begin
  TAssert.AssertEquals(AContext, AExpected, AActual);
end;

type
  TMockPascalServer = class(TLspServer)
  public
    WatchedEventCount: Integer;
    LastWatchedUri: string;
    IdleTicks: Integer;
  protected
    procedure ConfigureCapabilities(const AParams: TLspInitializeParams;
      var ACaps: TLspServerCapabilities); override;
    procedure DoDidOpen(ADoc: TLspDocument); override;
    procedure DoDidChangeWatchedFiles(const AChanges: TLspFileEventArray); override;
    procedure DoIdleTick; override;
    function DoHover(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspHover; override;
    function DoDocumentSymbol(const AUri: string; ADoc: TLspDocument): TLspDocumentSymbolArray; override;
    function DoCompletion(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition; const ATriggerChar: string): TLspCompletionList; override;
  end;

procedure TMockPascalServer.ConfigureCapabilities(const AParams: TLspInitializeParams;
  var ACaps: TLspServerCapabilities);
begin
  ACaps.ServerName := 'mock-nikrun-lsp';
  ACaps.ServerVersion := '0.1.0';
  ACaps.HoverProvider := True;
  ACaps.DocumentSymbolProvider := True;
  ACaps.CompletionProvider := True;
  SetLength(ACaps.CompletionTriggerChars, 1);
  ACaps.CompletionTriggerChars[0] := '.';
end;

procedure TMockPascalServer.DoDidOpen(ADoc: TLspDocument);
var
  Diags: TLspDiagnosticArray;
begin
  Diags := nil;
  SetLength(Diags, 1);
  Diags[0] := Default(TLspDiagnostic);
  Diags[0].Range := TLspRange.SingleLine(0, 0, 7);
  Diags[0].Severity := ldsWarning;
  Diags[0].HasCode := True;
  Diags[0].IntCode := 5025;
  Diags[0].Source := 'fpc';
  Diags[0].Message := 'Local variable "X" not used';
  PublishDiagnostics(ADoc.Uri, Diags, ADoc.Version);
end;

procedure TMockPascalServer.DoDidChangeWatchedFiles(const AChanges: TLspFileEventArray);
begin
  WatchedEventCount := WatchedEventCount + Length(AChanges);
  if Length(AChanges) > 0 then
    LastWatchedUri := AChanges[High(AChanges)].Uri;
end;

procedure TMockPascalServer.DoIdleTick;
begin
  Inc(IdleTicks);
end;

function TMockPascalServer.DoHover(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspHover;
var
  Ident: string;
  R: TLspRange;
begin
  Result := Default(TLspHover);
  if (ADoc <> nil) and ADoc.ExtractIdentifierAt(APos, Ident, R) then
  begin
    Result.HasValue := True;
    Result.Markdown := '```pascal'#10'symbol ' + Ident + #10'```';
    Result.HasRange := True;
    Result.Range := R;
  end;
end;

function TMockPascalServer.DoDocumentSymbol(const AUri: string; ADoc: TLspDocument): TLspDocumentSymbolArray;
begin
  Result := nil;
  SetLength(Result, 2);
  Result[0] := Default(TLspDocumentSymbol);
  Result[0].ParentIndex := -1;
  Result[0].Name := 'TGreeter';
  Result[0].Kind := lskClass;
  Result[0].Range := TLspRange.Create(TLspPosition.Create(2, 2), TLspPosition.Create(5, 5));
  Result[0].SelectionRange := TLspRange.SingleLine(2, 2, 10);

  Result[1] := Default(TLspDocumentSymbol);
  Result[1].ParentIndex := 0;
  Result[1].Name := 'SayHello';
  Result[1].Detail := 'procedure';
  Result[1].Kind := lskMethod;
  Result[1].Range := TLspRange.SingleLine(3, 4, 22);
  Result[1].SelectionRange := TLspRange.SingleLine(3, 14, 22);
end;

function TMockPascalServer.DoCompletion(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition; const ATriggerChar: string): TLspCompletionList;
begin
  Result := Default(TLspCompletionList);
  Result.IsIncomplete := False;
  SetLength(Result.Items, 1);
  Result.Items[0] := Default(TLspCompletionItem);
  Result.Items[0].LabelText := 'WriteLn';
  Result.Items[0].Kind := lcikFunction;
  Result.Items[0].Detail := 'procedure WriteLn(...)';
end;

procedure WriteClientFrame(AStream: TStream; const AJson: string);
var
  Writer: TLspStreamTransport;
begin
  Writer := TLspStreamTransport.Create(nil, AStream, False);
  try
    Writer.WriteMessage(AJson);
  finally
    Writer.Free;
  end;
end;

procedure TServerLifecycleTests.TestFullServerLifecycleAndDispatch;
var
  InStream, OutStream: TMemoryStream;
  Transport, Reader: TLspStreamTransport;
  Server: TMockPascalServer;
  RunExitCode: Integer;
  FramePayload: string;
  Parsed: TJSONData;
  Obj, ErrObj, ResObj, CapsObj, ParamsObj: TJSONObject;
  Arr, ChildArr: TJSONArray;
begin
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    // 1. Pre-initialize request -> must return -32002 ServerNotInitialized
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","id":1,"method":"workspace/symbol","params":{"query":"foo"}}');

    // 2. Initialize
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"processId":1234,"rootUri":"file:///c:/proj","clientInfo":{"name":"vscode","version":"1.99"}}}');
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","method":"initialized","params":{}}');

    // 3. didOpen -> triggers publishDiagnostics notification
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///c:/proj/main.pas","languageId":"objectpascal","version":1,"text":"program main;\nbegin\n  WriteLn;\nend."}}}');

    // 4. hover on WriteLn (line 2, col 4)
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///c:/proj/main.pas"},"position":{"line":2,"character":4}}}');

    // 5. documentSymbol (hierarchical children[])
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","id":4,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///c:/proj/main.pas"}}}');

    // 6. cancelRequest before completion request id=5
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":5}}');
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","id":5,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///c:/proj/main.pas"},"position":{"line":2,"character":9}}}');

    // 7. Actual completion request id="req-6"
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","id":"req-6","method":"textDocument/completion","params":{"textDocument":{"uri":"file:///c:/proj/main.pas"},"position":{"line":2,"character":9},"context":{"triggerKind":2,"triggerCharacter":"."}}}');

    // 7b. workspace/didChangeWatchedFiles notification
    WriteClientFrame(InStream,
      '{"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///c:/proj/nik.yaml","type":2}]}}');

    // 8. Clean shutdown + exit
    WriteClientFrame(InStream, '{"jsonrpc":"2.0","id":7,"method":"shutdown"}');
    WriteClientFrame(InStream, '{"jsonrpc":"2.0","method":"exit"}');

    InStream.Position := 0;
    Transport := TLspStreamTransport.Create(InStream, OutStream, False);
    Server := TMockPascalServer.Create(Transport, True);
    try
      RunExitCode := Server.Run;
      ChkEqInt(RunExitCode, 0, 'Clean shutdown + exit returns 0');
      ChkEqInt(Server.WatchedEventCount, 1, 'Watched file event dispatched');
      ChkEqStr(Server.LastWatchedUri, 'file:///c:/proj/nik.yaml', 'Watched file URI preserved');
      Chk(Server.IdleTicks > 0, 'DoIdleTick invoked during initialized state');
    finally
      Server.Free;
    end;

    // Inspect recorded server output frames
    OutStream.Position := 0;
    Reader := TLspStreamTransport.Create(OutStream, nil, False);
    try
      // Frame 1: Error -32002 for id=1
      Chk(Reader.ReadMessage(FramePayload), 'Read frame 1');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ErrObj := JsonGetObj(Obj, 'error');
        Chk(ErrObj <> nil, 'Frame 1 has error object');
        ChkEqInt(JsonGetInt(ErrObj, 'code'), LSP_ERR_SERVER_NOT_INITIALIZED, 'Frame 1 code -32002');
      finally
        Parsed.Free;
      end;

      // Frame 2: InitializeResult for id=2
      Chk(Reader.ReadMessage(FramePayload), 'Read frame 2');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ResObj := JsonGetObj(Obj, 'result');
        CapsObj := JsonGetObj(ResObj, 'capabilities');
        Chk(JsonGetBool(CapsObj, 'hoverProvider'), 'hoverProvider capability');
        Chk(JsonGetBool(CapsObj, 'documentSymbolProvider'), 'documentSymbolProvider capability');
      finally
        Parsed.Free;
      end;

      // Frame 3: publishDiagnostics notification from didOpen
      Chk(Reader.ReadMessage(FramePayload), 'Read frame 3');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ChkEqStr(JsonGetStr(Obj, 'method'), 'textDocument/publishDiagnostics', 'Frame 3 method');
        ParamsObj := JsonGetObj(Obj, 'params');
        Arr := JsonGetArr(ParamsObj, 'diagnostics');
        ChkEqInt(Arr.Count, 1, '1 diagnostic published');
      finally
        Parsed.Free;
      end;

      // Frame 4: Hover response for id=3
      Chk(Reader.ReadMessage(FramePayload), 'Read frame 4');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ResObj := JsonGetObj(Obj, 'result');
        Chk(Pos('WriteLn', JsonGetStr(JsonGetObj(ResObj, 'contents'), 'value')) > 0, 'Hover markdown contains WriteLn');
      finally
        Parsed.Free;
      end;

      // Frame 5: Hierarchical DocumentSymbol[] for id=4
      Chk(Reader.ReadMessage(FramePayload), 'Read frame 5');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        Arr := JsonGetArr(Obj, 'result');
        ChkEqInt(Arr.Count, 1, '1 root DocumentSymbol');
        ChildArr := JsonGetArr(TJSONObject(Arr.Items[0]), 'children');
        Chk(ChildArr <> nil, 'Root DocumentSymbol has children[]');
        ChkEqInt(ChildArr.Count, 1, '1 nested method child');
        ChkEqStr(JsonGetStr(TJSONObject(ChildArr.Items[0]), 'name'), 'SayHello', 'Nested child name');
      finally
        Parsed.Free;
      end;

      // Frame 6: Cancelled error -32800 for id=5
      Chk(Reader.ReadMessage(FramePayload), 'Read frame 6');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ErrObj := JsonGetObj(Obj, 'error');
        ChkEqInt(JsonGetInt(ErrObj, 'code'), LSP_ERR_REQUEST_CANCELLED, 'Cancelled request returns -32800');
      finally
        Parsed.Free;
      end;

      // Frame 7: CompletionList for string id="req-6"
      Chk(Reader.ReadMessage(FramePayload), 'Read frame 7');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ChkEqStr(JsonGetStr(Obj, 'id'), 'req-6', 'String request ID preserved');
        ResObj := JsonGetObj(Obj, 'result');
        Arr := JsonGetArr(ResObj, 'items');
        ChkEqInt(Arr.Count, 1, '1 completion item');
        ChkEqStr(JsonGetStr(TJSONObject(Arr.Items[0]), 'label'), 'WriteLn', 'Completion label');
      finally
        Parsed.Free;
      end;

      // Frame 8: Shutdown result null for id=7
      Chk(Reader.ReadMessage(FramePayload), 'Read frame 8');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        Chk(Obj.Find('result').JSONType = jtNull, 'Shutdown returns null result');
      finally
        Parsed.Free;
      end;

      Chk(not Reader.ReadMessage(FramePayload), 'No trailing frames');
    finally
      Reader.Free;
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

procedure TCompletionCodecTests.TestCompletionItemTextEditCodec;
var
  Item: TLspCompletionItem;
  Obj, EditObj: TJSONObject;
begin
  Item := Default(TLspCompletionItem);
  Item.LabelText := '3.3.1';
  Item.Kind := lcikValue;
  Item.HasTextEdit := True;
  Item.TextEdit := TLspTextEdit.Create(TLspRange.SingleLine(4, 9, 13), '3.3.1');
  Obj := CompletionItemToJson(Item);
  try
    EditObj := JsonGetObj(Obj, 'textEdit');
    Chk(EditObj <> nil, 'CompletionItem serializes textEdit when HasTextEdit is True');
    ChkEqStr(JsonGetStr(EditObj, 'newText'), '3.3.1', 'textEdit.newText matches');
    ChkEqInt(JsonGetInt(JsonGetObj(JsonGetObj(EditObj, 'range'), 'start'), 'character'), 9, 'textEdit.range.start.character matches');
  finally
    Obj.Free;
  end;
end;

initialization
  RegisterTests([TServerLifecycleTests, TCompletionCodecTests]);
end.