unit nikrun_test_reporter;

{ Generated-runner support unit shipped with `nik test` (source of truth: cli/src/runner/nikrun_test_reporter.pas,
  embedded into nik via scripts/embed-test-reporter.ps1). Emits one JSON object per test event on stdout,
  prefixed with '@@nik-test '. Do not edit the copy inside .nik/cache. }

{$mode objfpc}{$H+}

interface

function NikRunRegisteredTests: Integer;

implementation

uses
  SysUtils, Classes, TypInfo, fpcunit, testregistry;

const
  EVENT_PREFIX = '@@nik-test ';

type
  TNikTestListener = class(TInterfacedObject, ITestListener)
  private
    FStartTick: QWord;
    FReported: Boolean;
    function ElapsedMs: Int64;
  public
    procedure AddFailure(ATest: TTest; AFailure: TTestFailure);
    procedure AddError(ATest: TTest; AError: TTestFailure);
    procedure StartTest(ATest: TTest);
    procedure EndTest(ATest: TTest);
    procedure StartTestSuite(ATestSuite: TTestSuite);
    procedure EndTestSuite(ATestSuite: TTestSuite);
  end;

function JsonStr(const AValue: string): string;
var
  I, Len, Need, J: Integer;
  B: Byte;
  Valid: Boolean;
begin
  Result := '"';
  I := 1;
  Len := Length(AValue);
  while I <= Len do
  begin
    B := Ord(AValue[I]);
    case B of
      8: Result := Result + '\b';
      9: Result := Result + '\t';
      10: Result := Result + '\n';
      12: Result := Result + '\f';
      13: Result := Result + '\r';
      34: Result := Result + '\"';
      92: Result := Result + '\\';
    else
      if B < 32 then
        Result := Result + '\u' + LowerCase(IntToHex(B, 4))
      else if B < 128 then
        Result := Result + Chr(B)
      else
      begin
        // Pass valid UTF-8 sequences through, replace invalid bytes
        if (B and $E0) = $C0 then
          Need := 1
        else if (B and $F0) = $E0 then
          Need := 2
        else if (B and $F8) = $F0 then
          Need := 3
        else
          Need := -1;
        Valid := (Need > 0) and (I + Need <= Len);
        if Valid then
          for J := 1 to Need do
            if (Ord(AValue[I + J]) and $C0) <> $80 then
              Valid := False;
        if Valid then
        begin
          Result := Result + Copy(AValue, I, Need + 1);
          Inc(I, Need);
        end
        else
          Result := Result + '?';
      end;
    end;
    Inc(I);
  end;
  Result := Result + '"';
end;

procedure Emit(const AJson: string);
begin
  WriteLn(EVENT_PREFIX + AJson);
  Flush(Output);
end;

function UnitOfTest(ATest: TTest): string;
var
  Info: PTypeInfo;
begin
  Result := '';
  Info := PTypeInfo(ATest.ClassInfo);
  if Info <> nil then
    Result := string(GetTypeData(Info)^.UnitName);
end;

function TestHead(ATest: TTest): string;
begin
  Result := '"unit":' + JsonStr(UnitOfTest(ATest)) +
    ',"class":' + JsonStr(ATest.ClassName) +
    ',"method":' + JsonStr(ATest.TestName);
end;

function TNikTestListener.ElapsedMs: Int64;
begin
  Result := Int64(GetTickCount64 - FStartTick);
end;

procedure TNikTestListener.StartTest(ATest: TTest);
begin
  FStartTick := GetTickCount64;
  FReported := False;
  Emit('{"event":"start",' + TestHead(ATest) + '}');
end;

procedure TNikTestListener.EndTest(ATest: TTest);
begin
  if not FReported then
    Emit('{"event":"pass",' + TestHead(ATest) + ',"durationMs":' + IntToStr(ElapsedMs) + '}');
end;

procedure TNikTestListener.AddFailure(ATest: TTest; AFailure: TTestFailure);
begin
  FReported := True;
  if AFailure.IsIgnoredTest then
    Emit('{"event":"ignore",' + TestHead(ATest) + ',"message":' + JsonStr(AFailure.ExceptionMessage) + '}')
  else
    Emit('{"event":"fail",' + TestHead(ATest) + ',"kind":"failure","message":' +
      JsonStr(AFailure.ExceptionMessage) + ',"exception":' + JsonStr(AFailure.ExceptionClassName) +
      ',"sourceUnit":' + JsonStr(AFailure.SourceUnitName) + ',"line":' + IntToStr(AFailure.LineNumber) +
      ',"durationMs":' + IntToStr(ElapsedMs) + '}');
end;

procedure TNikTestListener.AddError(ATest: TTest; AError: TTestFailure);
begin
  FReported := True;
  Emit('{"event":"fail",' + TestHead(ATest) + ',"kind":"error","message":' +
    JsonStr(AError.ExceptionMessage) + ',"exception":' + JsonStr(AError.ExceptionClassName) +
    ',"sourceUnit":' + JsonStr(AError.SourceUnitName) + ',"line":' + IntToStr(AError.LineNumber) +
    ',"durationMs":' + IntToStr(ElapsedMs) + '}');
end;

procedure TNikTestListener.StartTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TNikTestListener.EndTestSuite(ATestSuite: TTestSuite);
begin
end;

function TestIdOf(ATest: TTest): string;
begin
  Result := LowerCase(UnitOfTest(ATest) + '.' + ATest.ClassName + '.' + ATest.TestName);
end;

procedure RunNode(ATest: TTest; AResult: TTestResult; AIds: TStringList);
var
  I: Integer;
  Suite: TTestSuite;
begin
  if ATest is TTestSuite then
  begin
    Suite := TTestSuite(ATest);
    for I := 0 to Suite.ChildTestCount - 1 do
      RunNode(Suite.Test[I], AResult, AIds);
  end
  else if ATest is TTestCase then
  begin
    if (AIds = nil) or (AIds.IndexOf(TestIdOf(ATest)) >= 0) then
      AResult.Run(TTestCase(ATest));
  end;
end;

function NikRunRegisteredTests: Integer;
var
  Res: TTestResult;
  Listener: ITestListener;
  Ids: TStringList;
  IdsFile: string;
  I: Integer;
begin
  Ids := nil;
  IdsFile := '';
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '--ids-file') and (I < ParamCount) then
    begin
      Inc(I);
      IdsFile := ParamStr(I);
    end;
    Inc(I);
  end;

  if IdsFile <> '' then
  begin
    Ids := TStringList.Create;
    Ids.LoadFromFile(IdsFile);
    for I := 0 to Ids.Count - 1 do
      Ids[I] := LowerCase(Trim(Ids[I]));
  end;

  Res := TTestResult.Create;
  try
    Listener := TNikTestListener.Create;
    Res.AddListener(Listener);
    RunNode(GetTestRegistry, Res, Ids);
    if Res.WasSuccessful then
      Result := 0
    else
      Result := 1;
    Res.RemoveListener(Listener);
  finally
    Res.Free;
    Ids.Free;
  end;
end;

end.
