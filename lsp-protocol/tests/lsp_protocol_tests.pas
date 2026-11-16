program lsp_protocol_tests;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, fpjson, jsonparser,
  nikrun.lsp.types,
  nikrun.lsp.uri,
  nikrun.lsp.utf16,
  nikrun.lsp.transport,
  nikrun.lsp.jsonrpc,
  nikrun.lsp.documents,
  nikrun.lsp.server;

var
  TestsPassed: Integer = 0;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise Exception.Create('Assertion failed: ' + AMessage);
  Inc(TestsPassed);
end;

procedure CheckEqStr(const AActual, AExpected, AContext: string);
begin
  if AActual <> AExpected then
    raise Exception.CreateFmt('%s: expected "%s", got "%s"', [AContext, AExpected, AActual]);
  Inc(TestsPassed);
end;

procedure CheckEqInt(AActual, AExpected: Int64; const AContext: string);
begin
  if AActual <> AExpected then
    raise Exception.CreateFmt('%s: expected %d, got %d', [AContext, AExpected, AActual]);
  Inc(TestsPassed);
end;

procedure TestUriConversion;
var
  Uri, BackPath: string;
begin
  Uri := FilePathToUri('C:\Dev\my project\src\main.pas');
  CheckEqStr(Uri, 'file:///c:/Dev/my%20project/src/main.pas', 'Windows path -> URI');

  Check(TryUriToFilePath('file:///c%3A/Dev/my%20project/src/main.pas', BackPath), 'VS Code encoded drive URI');
  {$IFDEF WINDOWS}
  CheckEqStr(BackPath, 'C:\Dev\my project\src\main.pas', 'Decoded Windows path');
  {$ELSE}
  CheckEqStr(BackPath, 'C:/Dev/my project/src/main.pas', 'Decoded Windows path on POSIX');
  {$ENDIF}

  CheckEqStr(FilePathToUri('/home/nik/src/unit1.pas'), 'file:///home/nik/src/unit1.pas', 'POSIX path -> URI');
  CheckEqStr(
    NormalizeDocumentUri('file:///C%3A/Foo/Bar.pas'),
    NormalizeDocumentUri('file:///c:/Foo/Bar.pas'),
    'Normalized Windows drive URI equality'
  );
  CheckEqStr(
    NormalizeDocumentUri('file:////tmp/test.pas'),
    NormalizeDocumentUri('file:///tmp/test.pas'),
    'Normalized redundant leading slashes in POSIX file URI'
  );
end;

procedure TestUtf16Mapping;
var
  Line: string;
begin
  // 'ä' = 2 UTF-8 bytes (1 UTF-16 unit), '🚀' = 4 UTF-8 bytes (2 UTF-16 units)
  Line := 'aä🚀b';
  CheckEqInt(Length(Line), 8, 'UTF-8 byte length');
  CheckEqInt(Utf8LineLengthUtf16(Line), 5, 'UTF-16 length of a + ä + 🚀(2) + b');

  CheckEqInt(Utf16ColToByteIndex(Line, 0), 1, 'Col 0 -> byte 1 (a)');
  CheckEqInt(Utf16ColToByteIndex(Line, 1), 2, 'Col 1 -> byte 2 (ä)');
  CheckEqInt(Utf16ColToByteIndex(Line, 2), 4, 'Col 2 -> byte 4 (🚀)');
  CheckEqInt(Utf16ColToByteIndex(Line, 4), 8, 'Col 4 -> byte 8 (b)');
  CheckEqInt(Utf16ColToByteIndex(Line, 5), 9, 'Col 5 -> byte 9 (EOL)');

  CheckEqInt(ByteIndexToUtf16Col(Line, 1), 0, 'Byte 1 -> col 0');
  CheckEqInt(ByteIndexToUtf16Col(Line, 2), 1, 'Byte 2 -> col 1');
  CheckEqInt(ByteIndexToUtf16Col(Line, 4), 2, 'Byte 4 -> col 2');
  CheckEqInt(ByteIndexToUtf16Col(Line, 8), 4, 'Byte 8 -> col 4');
end;

procedure TestDocumentStoreIncrementalSync;
var
  Store: TLspDocumentStore;
  Doc: TLspDocument;
  Changes: TLspContentChangeArray;
  Ident: string;
  IdentRange: TLspRange;
begin
  Store := TLspDocumentStore.Create;
  try
    Doc := Store.OpenDocument(
      'file:///c%3A/proj/main.pas',
      'objectpascal',
      1,
      'program demo;' + #13#10 + 'var Grütze: Integer;' + #13#10 + 'begin' + #13#10 + 'end.'
    );
    CheckEqInt(Doc.LineCount, 4, 'Initial line count');
    CheckEqStr(Doc.GetLineText(1), 'var Grütze: Integer;', 'Line 1 text');

    // Replace 'Integer' (after 'var Grütze: ' -> 12 UTF-16 units, 13 UTF-8 bytes) with 'String'
    Changes := nil;
    SetLength(Changes, 1);
    Changes[0].HasRange := True;
    Changes[0].Range := TLspRange.SingleLine(1, 12, 19);
    Changes[0].Text := 'String';
    Store.ChangeDocument('file:///c:/proj/main.pas', 2, Changes);

    CheckEqInt(Doc.Version, 2, 'Updated version');
    CheckEqStr(Doc.GetLineText(1), 'var Grütze: String;', 'Line 1 after UTF-16 incremental edit');

    Check(Doc.ExtractIdentifierAt(TLspPosition.Create(1, 14), Ident, IdentRange), 'Extract identifier String');
    CheckEqStr(Ident, 'String', 'Extracted identifier text');
    CheckEqInt(IdentRange.StartPos.Character, 12, 'Extracted identifier start col');
    CheckEqInt(IdentRange.EndPos.Character, 18, 'Extracted identifier end col');

    Check(Store.CloseDocument('file:///C:/proj/main.pas'), 'Close document via case/encoding variant');
    CheckEqInt(Store.Count, 0, 'Store empty after close');
  finally
    Store.Free;
  end;
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

procedure TestFullServerLifecycleAndDispatch;
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
      CheckEqInt(RunExitCode, 0, 'Clean shutdown + exit returns 0');
      CheckEqInt(Server.WatchedEventCount, 1, 'Watched file event dispatched');
      CheckEqStr(Server.LastWatchedUri, 'file:///c:/proj/nik.yaml', 'Watched file URI preserved');
      Check(Server.IdleTicks > 0, 'DoIdleTick invoked during initialized state');
    finally
      Server.Free;
    end;

    // Inspect recorded server output frames
    OutStream.Position := 0;
    Reader := TLspStreamTransport.Create(OutStream, nil, False);
    try
      // Frame 1: Error -32002 for id=1
      Check(Reader.ReadMessage(FramePayload), 'Read frame 1');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ErrObj := JsonGetObj(Obj, 'error');
        Check(ErrObj <> nil, 'Frame 1 has error object');
        CheckEqInt(JsonGetInt(ErrObj, 'code'), LSP_ERR_SERVER_NOT_INITIALIZED, 'Frame 1 code -32002');
      finally
        Parsed.Free;
      end;

      // Frame 2: InitializeResult for id=2
      Check(Reader.ReadMessage(FramePayload), 'Read frame 2');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ResObj := JsonGetObj(Obj, 'result');
        CapsObj := JsonGetObj(ResObj, 'capabilities');
        Check(JsonGetBool(CapsObj, 'hoverProvider'), 'hoverProvider capability');
        Check(JsonGetBool(CapsObj, 'documentSymbolProvider'), 'documentSymbolProvider capability');
      finally
        Parsed.Free;
      end;

      // Frame 3: publishDiagnostics notification from didOpen
      Check(Reader.ReadMessage(FramePayload), 'Read frame 3');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        CheckEqStr(JsonGetStr(Obj, 'method'), 'textDocument/publishDiagnostics', 'Frame 3 method');
        ParamsObj := JsonGetObj(Obj, 'params');
        Arr := JsonGetArr(ParamsObj, 'diagnostics');
        CheckEqInt(Arr.Count, 1, '1 diagnostic published');
      finally
        Parsed.Free;
      end;

      // Frame 4: Hover response for id=3
      Check(Reader.ReadMessage(FramePayload), 'Read frame 4');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ResObj := JsonGetObj(Obj, 'result');
        Check(Pos('WriteLn', JsonGetStr(JsonGetObj(ResObj, 'contents'), 'value')) > 0, 'Hover markdown contains WriteLn');
      finally
        Parsed.Free;
      end;

      // Frame 5: Hierarchical DocumentSymbol[] for id=4
      Check(Reader.ReadMessage(FramePayload), 'Read frame 5');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        Arr := JsonGetArr(Obj, 'result');
        CheckEqInt(Arr.Count, 1, '1 root DocumentSymbol');
        ChildArr := JsonGetArr(TJSONObject(Arr.Items[0]), 'children');
        Check(ChildArr <> nil, 'Root DocumentSymbol has children[]');
        CheckEqInt(ChildArr.Count, 1, '1 nested method child');
        CheckEqStr(JsonGetStr(TJSONObject(ChildArr.Items[0]), 'name'), 'SayHello', 'Nested child name');
      finally
        Parsed.Free;
      end;

      // Frame 6: Cancelled error -32800 for id=5
      Check(Reader.ReadMessage(FramePayload), 'Read frame 6');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        ErrObj := JsonGetObj(Obj, 'error');
        CheckEqInt(JsonGetInt(ErrObj, 'code'), LSP_ERR_REQUEST_CANCELLED, 'Cancelled request returns -32800');
      finally
        Parsed.Free;
      end;

      // Frame 7: CompletionList for string id="req-6"
      Check(Reader.ReadMessage(FramePayload), 'Read frame 7');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        CheckEqStr(JsonGetStr(Obj, 'id'), 'req-6', 'String request ID preserved');
        ResObj := JsonGetObj(Obj, 'result');
        Arr := JsonGetArr(ResObj, 'items');
        CheckEqInt(Arr.Count, 1, '1 completion item');
        CheckEqStr(JsonGetStr(TJSONObject(Arr.Items[0]), 'label'), 'WriteLn', 'Completion label');
      finally
        Parsed.Free;
      end;

      // Frame 8: Shutdown result null for id=7
      Check(Reader.ReadMessage(FramePayload), 'Read frame 8');
      Parsed := GetJSON(FramePayload);
      try
        Obj := TJSONObject(Parsed);
        Check(Obj.Find('result').JSONType = jtNull, 'Shutdown returns null result');
      finally
        Parsed.Free;
      end;

      Check(not Reader.ReadMessage(FramePayload), 'No trailing frames');
    finally
      Reader.Free;
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

begin
  {$IF Declared(HaltOnNotReleased)}
  HaltOnNotReleased := True;
  {$ENDIF}
  try
    TestUriConversion;
    TestUtf16Mapping;
    TestDocumentStoreIncrementalSync;
    TestFullServerLifecycleAndDispatch;
    WriteLn(Format('PASS: %d assertions succeeded across nikrun-lsp-protocol test suite.', [TestsPassed]));
    ExitCode := 0;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
