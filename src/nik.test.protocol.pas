unit nik.test.protocol;

{$mode objfpc}{$H+}

{ Runner protocol for 'nik test' (see internal-notes/specs/nik-test.md, section 3): parses the
  event lines (prefix @@nik-test followed by one JSON object) emitted by the generated runner, attributes
  all other output to the running test, recognizes the heaptrc leak report and executes the test binary. }

interface

uses
  SysUtils, Classes, nik.types, nik.test.discovery;

type
  TTestEventKind = (tekStart, tekPass, tekFail, tekIgnore, tekOutput);

  TTestEvent = record
    Kind: TTestEventKind;
    Id: string;
    UnitName: string;
    ClassName: string;
    MethodName: string;
    FailKind: string;        // 'failure' | 'error'
    Message: string;
    ExceptionName: string;
    SourceUnit: string;
    Line: Integer;
    DurationMs: Int64;
    Text: string;            // tekOutput
  end;

  TTestEventProc = procedure(const AEvent: TTestEvent) of object;

  TTestProtocolParser = class
  private
    FOnEvent: TTestEventProc;
    FBuffer: string;
    FCurrentId: string;
    FInHeapReport: Boolean;
    FHeapReport: string;
    FHasHeapReport: Boolean;
    FUnfreedBlocks: Integer;
    procedure HandleLine(const ALine: string);
    procedure EmitOutput(const AText: string);
    procedure HandleEventJson(const AJson: string);
  public
    constructor Create(AOnEvent: TTestEventProc);
    procedure Feed(const AChunk: string);
    procedure Finish;
    { Id of a test that started but never reported a result (crash / abnormal exit). }
    property CurrentId: string read FCurrentId;
    property HasHeapReport: Boolean read FHasHeapReport;
    property UnfreedBlocks: Integer read FUnfreedBlocks;
    property HeapReport: string read FHeapReport;
  end;

  TTestStatus = (tstNotRun, tstPassed, tstFailed, tstError, tstIgnored);

  TTestFailureInfo = record
    Kind: string;
    Message: string;
    ExceptionName: string;
    SourceUnit: string;
    Line: Integer;
  end;

  TTestResultItem = record
    Id: string;
    UnitName: string;
    ClassName: string;
    MethodName: string;
    FilePath: string;
    Line: Integer;
    Status: TTestStatus;
    DurationMs: Int64;
    HasFailure: Boolean;
    Failure: TTestFailureInfo;
    Output: string;
  end;
  TTestResultItemArray = array of TTestResultItem;

  TTestSummary = record
    Total: Integer;
    Passed: Integer;
    Failed: Integer;
    Errors: Integer;
    Ignored: Integer;
    NotRun: Integer;
  end;

  { Aggregates events into per-test results seeded from static discovery. }
  TTestRunCollector = class
  private
    FItems: TTestResultItemArray;
    FUnits: TTestUnitInfoArray;
    function EnsureItem(const AEvent: TTestEvent): Integer;
    function LocateSource(const AUnitName: string; out AFile: string): Boolean;
  public
    constructor Create(const AUnits: TTestUnitInfoArray);
    function IndexOfId(const AId: string): Integer;
    { Drops all items whose id is not in AIds (used for filtered runs). }
    procedure RestrictTo(const AIds: TStringArray);
    procedure OnEvent(const AEvent: TTestEvent);
    { Marks a started-but-unfinished test as errored (process crashed). }
    procedure MarkCrashed(const AId, AMessage: string);
    function Summary: TTestSummary;
    property Items: TTestResultItemArray read FItems;
  end;

function TestStatusToString(AStatus: TTestStatus): string;

{ Expands discovery results into the ordered list of test ids/locations (used by --list). }
function CollectDiscoveredTests(const AUnits: TTestUnitInfoArray): TTestResultItemArray;

{ Runs the compiled test binary, streaming its combined stdout/stderr into AParser. }
function RunTestBinary(const ABinaryPath, AWorkDir, AIdsFile: string;
  AParser: TTestProtocolParser): Integer;

implementation

uses
  fpjson, jsonparser, Process;

const
  EVENT_MARKER = '@@nik-test ';
  HEAP_REPORT_MARKER = 'Heap dump by heaptrc unit';

function TestStatusToString(AStatus: TTestStatus): string;
begin
  case AStatus of
    tstNotRun: Result := 'notrun';
    tstPassed: Result := 'passed';
    tstFailed: Result := 'failed';
    tstError:  Result := 'error';
    tstIgnored: Result := 'ignored';
  else
    raise ENikError.CreateFmt('Unsupported TTestStatus ordinal: %d', [Ord(AStatus)]);
  end;
end;

{ TTestProtocolParser }

constructor TTestProtocolParser.Create(AOnEvent: TTestEventProc);
begin
  inherited Create;
  FOnEvent := AOnEvent;
end;

procedure TTestProtocolParser.EmitOutput(const AText: string);
var
  Ev: TTestEvent;
begin
  if (AText = '') or (not Assigned(FOnEvent)) then
    Exit;
  Ev := Default(TTestEvent);
  Ev.Kind := tekOutput;
  Ev.Id := FCurrentId;
  Ev.Text := AText;
  FOnEvent(Ev);
end;

procedure TTestProtocolParser.HandleEventJson(const AJson: string);
var
  Data: TJSONData;
  Obj: TJSONObject;
  Ev: TTestEvent;
  Name: string;
begin
  Data := nil;
  try
    Data := GetJSON(AJson);
  except
    EmitOutput(EVENT_MARKER + AJson + LineEnding);
    Exit;
  end;
  try
    if not (Data is TJSONObject) then
    begin
      EmitOutput(EVENT_MARKER + AJson + LineEnding);
      Exit;
    end;
    Obj := TJSONObject(Data);
    Name := Obj.Get('event', '');
    Ev := Default(TTestEvent);
    Ev.UnitName := Obj.Get('unit', '');
    Ev.ClassName := Obj.Get('class', '');
    Ev.MethodName := Obj.Get('method', '');
    Ev.Id := MakeTestId(Ev.UnitName, Ev.ClassName, Ev.MethodName);
    Ev.DurationMs := Obj.Get('durationMs', Int64(0));
    Ev.Message := Obj.Get('message', '');
    Ev.FailKind := Obj.Get('kind', 'failure');
    Ev.ExceptionName := Obj.Get('exception', '');
    Ev.SourceUnit := Obj.Get('sourceUnit', '');
    Ev.Line := Obj.Get('line', 0);

    if Name = 'start' then
    begin
      Ev.Kind := tekStart;
      FCurrentId := Ev.Id;
    end
    else if Name = 'pass' then
    begin
      Ev.Kind := tekPass;
      FCurrentId := '';
    end
    else if Name = 'fail' then
    begin
      Ev.Kind := tekFail;
      FCurrentId := '';
    end
    else if Name = 'ignore' then
    begin
      Ev.Kind := tekIgnore;
      FCurrentId := '';
    end
    else
    begin
      EmitOutput(EVENT_MARKER + AJson + LineEnding);
      Exit;
    end;
    if Assigned(FOnEvent) then
      FOnEvent(Ev);
  finally
    Data.Free;
  end;
end;

procedure TTestProtocolParser.HandleLine(const ALine: string);
var
  P, E, Code: Integer;
  Prefix, Json, Num: string;
  Clean: string;
begin
  Clean := ALine;
  if (Clean <> '') and (Clean[Length(Clean)] = #13) then
    SetLength(Clean, Length(Clean) - 1);

  if FInHeapReport or (Pos(HEAP_REPORT_MARKER, Clean) > 0) then
  begin
    FInHeapReport := True;
    FHasHeapReport := True;
    FHeapReport := FHeapReport + Clean + LineEnding;
    P := Pos(' unfreed memory blocks', Clean);
    if P > 1 then
    begin
      E := P - 1;
      P := E;
      while (P >= 1) and (Clean[P] in ['0'..'9']) do
        Dec(P);
      Num := Copy(Clean, P + 1, E - P);
      Val(Num, FUnfreedBlocks, Code);
      if Code <> 0 then
        FUnfreedBlocks := 0;
    end;
    Exit;
  end;

  P := Pos(EVENT_MARKER, Clean);
  if P > 0 then
  begin
    Prefix := Copy(Clean, 1, P - 1);
    Json := Copy(Clean, P + Length(EVENT_MARKER), MaxInt);
    if Prefix <> '' then
      EmitOutput(Prefix + LineEnding);
    HandleEventJson(Json);
    Exit;
  end;

  EmitOutput(Clean + LineEnding);
end;

procedure TTestProtocolParser.Feed(const AChunk: string);
var
  P: Integer;
  Line: string;
begin
  FBuffer := FBuffer + AChunk;
  repeat
    P := Pos(#10, FBuffer);
    if P = 0 then
      Break;
    Line := Copy(FBuffer, 1, P - 1);
    Delete(FBuffer, 1, P);
    HandleLine(Line);
  until False;
end;

procedure TTestProtocolParser.Finish;
begin
  if FBuffer <> '' then
  begin
    HandleLine(FBuffer);
    FBuffer := '';
  end;
end;

{ TTestRunCollector }

constructor TTestRunCollector.Create(const AUnits: TTestUnitInfoArray);
begin
  inherited Create;
  FUnits := AUnits;
  FItems := CollectDiscoveredTests(AUnits);
end;

function TTestRunCollector.IndexOfId(const AId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    if SameText(FItems[I].Id, AId) then
      Exit(I);
  Result := -1;
end;

function TTestRunCollector.LocateSource(const AUnitName: string; out AFile: string): Boolean;
var
  I: Integer;
begin
  AFile := '';
  for I := 0 to High(FUnits) do
    if SameText(FUnits[I].UnitName, AUnitName) then
    begin
      AFile := FUnits[I].FilePath;
      Exit(True);
    end;
  Result := False;
end;

function TTestRunCollector.EnsureItem(const AEvent: TTestEvent): Integer;
var
  N: Integer;
begin
  Result := IndexOfId(AEvent.Id);
  if Result >= 0 then
    Exit;
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N] := Default(TTestResultItem);
  FItems[N].Id := AEvent.Id;
  FItems[N].UnitName := AEvent.UnitName;
  FItems[N].ClassName := AEvent.ClassName;
  FItems[N].MethodName := AEvent.MethodName;
  LocateSource(AEvent.UnitName, FItems[N].FilePath);
  Result := N;
end;

procedure TTestRunCollector.RestrictTo(const AIds: TStringArray);
var
  I, J, N: Integer;
  Keep: Boolean;
  Kept: TTestResultItemArray;
begin
  Kept := nil;
  for I := 0 to High(FItems) do
  begin
    Keep := False;
    for J := 0 to High(AIds) do
      if SameText(AIds[J], FItems[I].Id) then
      begin
        Keep := True;
        Break;
      end;
    if Keep then
    begin
      N := Length(Kept);
      SetLength(Kept, N + 1);
      Kept[N] := FItems[I];
    end;
  end;
  FItems := Kept;
end;

procedure TTestRunCollector.OnEvent(const AEvent: TTestEvent);
var
  Idx: Integer;
  Failure: TTestFailureInfo;
begin
  if AEvent.Kind = tekOutput then
  begin
    Idx := IndexOfId(AEvent.Id);
    if (AEvent.Id <> '') and (Idx >= 0) then
      FItems[Idx].Output := FItems[Idx].Output + AEvent.Text;
    Exit;
  end;

  Idx := EnsureItem(AEvent);
  case AEvent.Kind of
    tekStart:
      ;
    tekPass:
      begin
        if FItems[Idx].Status = tstNotRun then
          FItems[Idx].Status := tstPassed;
        FItems[Idx].DurationMs := AEvent.DurationMs;
      end;
    tekIgnore:
      begin
        FItems[Idx].Status := tstIgnored;
        FItems[Idx].HasFailure := False;
        FItems[Idx].Failure.Message := AEvent.Message;
      end;
    tekFail:
      begin
        FItems[Idx].DurationMs := AEvent.DurationMs;
        // Keep the first failure as primary; an error outranks a plain failure
        if (FItems[Idx].Status in [tstFailed, tstError]) then
          Exit;
        Failure := Default(TTestFailureInfo);
        Failure.Kind := AEvent.FailKind;
        Failure.Message := AEvent.Message;
        Failure.ExceptionName := AEvent.ExceptionName;
        Failure.SourceUnit := AEvent.SourceUnit;
        Failure.Line := AEvent.Line;
        FItems[Idx].HasFailure := True;
        FItems[Idx].Failure := Failure;
        if SameText(AEvent.FailKind, 'error') then
          FItems[Idx].Status := tstError
        else
          FItems[Idx].Status := tstFailed;
      end;
  else
    raise ENikError.CreateFmt('Unsupported TTestEventKind ordinal: %d', [Ord(AEvent.Kind)]);
  end;
end;

procedure TTestRunCollector.MarkCrashed(const AId, AMessage: string);
var
  Idx: Integer;
begin
  Idx := IndexOfId(AId);
  if Idx < 0 then
    Exit;
  FItems[Idx].Status := tstError;
  FItems[Idx].HasFailure := True;
  FItems[Idx].Failure := Default(TTestFailureInfo);
  FItems[Idx].Failure.Kind := 'error';
  FItems[Idx].Failure.Message := AMessage;
end;

function TTestRunCollector.Summary: TTestSummary;
var
  I: Integer;
begin
  Result := Default(TTestSummary);
  Result.Total := Length(FItems);
  for I := 0 to High(FItems) do
    case FItems[I].Status of
      tstPassed:  Inc(Result.Passed);
      tstFailed:  Inc(Result.Failed);
      tstError:   Inc(Result.Errors);
      tstIgnored: Inc(Result.Ignored);
      tstNotRun:  Inc(Result.NotRun);
    end;
end;

function CollectDiscoveredTests(const AUnits: TTestUnitInfoArray): TTestResultItemArray;
var
  U, C, M, N: Integer;
  Impl: Integer;
begin
  Result := nil;
  for U := 0 to High(AUnits) do
    for C := 0 to High(AUnits[U].Classes) do
      for M := 0 to High(AUnits[U].Classes[C].Methods) do
      begin
        N := Length(Result);
        SetLength(Result, N + 1);
        Result[N] := Default(TTestResultItem);
        Result[N].UnitName := AUnits[U].UnitName;
        Result[N].ClassName := AUnits[U].Classes[C].Name;
        Result[N].MethodName := AUnits[U].Classes[C].Methods[M].Name;
        Result[N].Id := MakeTestId(Result[N].UnitName, Result[N].ClassName, Result[N].MethodName);
        Result[N].FilePath := AUnits[U].FilePath;
        Impl := AUnits[U].Classes[C].Methods[M].ImplLine;
        if Impl > 0 then
          Result[N].Line := Impl
        else
          Result[N].Line := AUnits[U].Classes[C].Methods[M].DeclLine;
        Result[N].Status := tstNotRun;
      end;
end;

function RunTestBinary(const ABinaryPath, AWorkDir, AIdsFile: string;
  AParser: TTestProtocolParser): Integer;
var
  Proc: TProcess;
  Buf: array[0..4095] of Byte;
  BytesRead: LongInt;
  Chunk: RawByteString;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := ABinaryPath;
    if AWorkDir <> '' then
      Proc.CurrentDirectory := AWorkDir;
    if AIdsFile <> '' then
    begin
      Proc.Parameters.Add('--ids-file');
      Proc.Parameters.Add(AIdsFile);
    end;
    Proc.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    Proc.Execute;

    while Proc.Running or (Proc.Output.NumBytesAvailable > 0) do
    begin
      while Proc.Output.NumBytesAvailable > 0 do
      begin
        BytesRead := Proc.Output.Read(Buf[0], SizeOf(Buf));
        if BytesRead > 0 then
        begin
          SetString(Chunk, PChar(@Buf[0]), BytesRead);
          AParser.Feed(string(Chunk));
        end;
      end;
      if Proc.Running then
        Sleep(5);
    end;
    repeat
      BytesRead := Proc.Output.Read(Buf[0], SizeOf(Buf));
      if BytesRead > 0 then
      begin
        SetString(Chunk, PChar(@Buf[0]), BytesRead);
        AParser.Feed(string(Chunk));
      end;
    until BytesRead <= 0;

    Proc.WaitOnExit;
    Result := Proc.ExitCode;
    if (Result = 0) and (Proc.ExitStatus <> 0) then
      Result := 128 + (Proc.ExitStatus and $7F);
    AParser.Finish;
  finally
    Proc.Free;
  end;
end;

end.
