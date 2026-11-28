unit nik.cmd.tests;

{$mode objfpc}{$H+}

{ 'nik test': discovers, compiles and runs fpcunit test units (see internal-notes/specs/nik-test.md). }

interface

uses
  SysUtils, Classes;

function ExecuteTestCommand(const AArgs: array of string): Integer;
procedure PrintTestHelp;

implementation

uses
  StrUtils, fpjson, nik.types, nik.term, nik.paths, nik.platform, nik.manifest.types, nik.manifest.io,
  nik.manifest.resolve, nik.compiler.types, nik.compiler.diag, nik.project,
  nik.test.discovery, nik.test.runner, nik.test.protocol;

type
  TTestOutputMode = (tomHuman, tomJson, tomStream);

  TTestRunReporter = class
  private
    FMode: TTestOutputMode;
    FVerbose: Boolean;
    FUnits: TTestUnitInfoArray;
    FCollector: TTestRunCollector;
    procedure LocateFailure(const AUnitName: string; ALine: Integer;
      const AItem: TTestResultItem; out AFile: string; out AOutLine: Integer);
  public
    constructor Create(AMode: TTestOutputMode; AVerbose: Boolean;
      const AUnits: TTestUnitInfoArray; ACollector: TTestRunCollector);
    procedure OnEvent(const AEvent: TTestEvent);
  end;

procedure PrintTestHelp;
begin
  WriteLn(StyleBold('Discover, compile, and run fpcunit tests'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik test [OPTIONS] [FILTER...]');
  WriteLn;
  WriteLn('Test units are Free Pascal units whose file name ends in _test.pas, _test.pp,');
  WriteLn('.test.pas or .test.pp and live next to the unit they test. They register their');
  WriteLn('TTestCase classes with RegisterTest in the initialization section.');
  WriteLn;
  WriteLn(StyleBold('FILTER:'));
  WriteLn('  Test ids are <unit>.<Class>.<Method> (case-insensitive). A filter matches a full id or');
  WriteLn('  a prefix at a ''.'' boundary; ''*'' is a wildcard. Multiple filters are OR-ed.');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('  -p, --profile <NAME>   Build with the named profile from nik.yaml (default: debug)');
  WriteLn('  -m, --manifest <PATH>  Path to nik.yaml or project directory');
  WriteLn('      --list             List discovered tests without compiling (static scan)');
  WriteLn('      --no-run           Compile the test runner only');
  WriteLn('      --clean            Clean the test build cache (.nik/cache) and force rebuild');
  WriteLn('      --build-version <V> Use <V> instead of ''version'' from nik.yaml (feeds the generated unit nikmanifest)');
  WriteLn('      --locked           Require nik.lock to be up to date without modifying it');
  WriteLn('      --offline          Use only locally installed SDKs and cached packages');
  WriteLn('  -v, --verbose          Show the compiler invocation and full test output');
  WriteLn('      --json             Output one structured JSON report');
  WriteLn('      --json-stream      Output NDJSON events while the tests run (IDE integration)');
  WriteLn('  -h, --help             Show this help message');
  WriteLn;
  WriteLn(StyleBold('EXAMPLES:'));
  WriteLn('  nik test');
  WriteLn('  nik test nik.pkg.semver.test');
  WriteLn('  nik test "*.TSemVerTests.TestCaret*" --json');
  WriteLn('  nik test --list --json');
end;

function SplitOptEq(const AArg, AOptName: string; out AVal: string): Boolean;
var
  Prefix: string;
begin
  AVal := '';
  Prefix := AOptName + '=';
  if (Length(AArg) >= Length(Prefix)) and SameText(Copy(AArg, 1, Length(Prefix)), Prefix) then
  begin
    AVal := Copy(AArg, Length(Prefix) + 1, MaxInt);
    Exit(True);
  end;
  Result := False;
end;

function NextOptValue(const AArgs: array of string; var AIndex: Integer; const AOptName: string): string;
begin
  if AIndex + 1 > High(AArgs) then
    raise ENikError.CreateWithCode(Format('Option %s requires a value.', [AOptName]), 2);
  Inc(AIndex);
  Result := AArgs[AIndex];
end;

procedure AppendStr(var AArr: TStringArray; const AValue: string);
var
  N: Integer;
begin
  N := Length(AArr);
  SetLength(AArr, N + 1);
  AArr[N] := AValue;
end;

procedure AppendUniqueDir(var AArr: TStringArray; const ADir: string);
var
  I: Integer;
  Clean: string;
begin
  Clean := ExcludeTrailingPathDelimiter(ADir);
  if Clean = '' then
    Exit;
  for I := 0 to High(AArr) do
    if SameText(AArr[I], Clean) then
      Exit;
  AppendStr(AArr, Clean);
end;

procedure EmitStreamLine(AObj: TJSONObject);
begin
  WriteLn(AObj.FormatJSON(AsCompressedJSON, 0));
  Flush(Output);
end;

function DiagnosticsToJson(const ADiags: TCompilerDiagnosticArray): TJSONArray;
var
  I: Integer;
  Obj: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(ADiags) do
  begin
    Obj := TJSONObject.Create;
    if ADiags[I].FilePath <> '' then
      Obj.Add('file', ADiags[I].FilePath)
    else
      Obj.Add('file', TJSONNull.Create);
    Obj.Add('line', ADiags[I].Line);
    Obj.Add('column', ADiags[I].Column);
    Obj.Add('severity', SeverityToString(ADiags[I].Severity));
    Obj.Add('code', ADiags[I].Code);
    Obj.Add('message', ADiags[I].Message);
    Result.Add(Obj);
  end;
end;

function MessageDiagnosticJson(const AMsg: string): TJSONArray;
var
  Obj: TJSONObject;
begin
  Result := TJSONArray.Create;
  Obj := TJSONObject.Create;
  Obj.Add('file', TJSONNull.Create);
  Obj.Add('line', 0);
  Obj.Add('column', 0);
  Obj.Add('severity', 'error');
  Obj.Add('code', 0);
  Obj.Add('message', AMsg);
  Result.Add(Obj);
end;

procedure EmitPreflightError(AMode: TTestOutputMode; const AMsg: string; AExitCode: Integer;
  ASdkInstalled: Boolean);
var
  Root: TJSONObject;
begin
  if AMode = tomStream then
  begin
    Root := TJSONObject.Create;
    try
      Root.Add('event', 'build');
      Root.Add('success', False);
      Root.Add('durationMs', 0);
      Root.Add('diagnostics', MessageDiagnosticJson(AMsg));
      EmitStreamLine(Root);
    finally
      Root.Free;
    end;
    Root := TJSONObject.Create;
    try
      Root.Add('event', 'summary');
      Root.Add('success', False);
      Root.Add('exitCode', AExitCode);
      Root.Add('error', AMsg);
      EmitStreamLine(Root);
    finally
      Root.Free;
    end;
  end
  else
  begin
    Root := TJSONObject.Create;
    try
      Root.Add('success', False);
      Root.Add('exitCode', AExitCode);
      Root.Add('sdkInstalled', ASdkInstalled);
      Root.Add('error', AMsg);
      Root.Add('tests', TJSONArray.Create);
      WriteJson(Root);
    finally
      Root.Free;
    end;
  end;
end;

function FindUnitFile(const AUnits: TTestUnitInfoArray; const AUnitName: string): string;
var
  I: Integer;
begin
  Result := '';
  if AUnitName = '' then
    Exit;
  for I := 0 to High(AUnits) do
    if SameText(AUnits[I].UnitName, AUnitName) then
      Exit(AUnits[I].FilePath);
end;

function LocationJson(const AFile: string; ALine: Integer): TJSONData;
begin
  if AFile = '' then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(AFile);
  if ALine < 0 then
    ALine := 0;
end;

function ItemToJson(const AItem: TTestResultItem; const AUnits: TTestUnitInfoArray;
  AWithStatus: Boolean): TJSONObject;
var
  Fail: TJSONObject;
  FailFile: string;
  FailLine: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('id', AItem.Id);
  Result.Add('unit', AItem.UnitName);
  Result.Add('class', AItem.ClassName);
  Result.Add('method', AItem.MethodName);
  if AItem.FilePath <> '' then
    Result.Add('file', AItem.FilePath)
  else
    Result.Add('file', TJSONNull.Create);
  Result.Add('line', AItem.Line);
  if not AWithStatus then
    Exit;
  Result.Add('status', TestStatusToString(AItem.Status));
  Result.Add('durationMs', AItem.DurationMs);
  if AItem.HasFailure and (AItem.Status in [tstFailed, tstError]) then
  begin
    FailFile := FindUnitFile(AUnits, AItem.Failure.SourceUnit);
    FailLine := AItem.Failure.Line;
    if (FailFile = '') or (FailLine <= 0) then
    begin
      FailFile := AItem.FilePath;
      FailLine := AItem.Line;
    end;
    Fail := TJSONObject.Create;
    Fail.Add('kind', AItem.Failure.Kind);
    Fail.Add('message', AItem.Failure.Message);
    Fail.Add('file', LocationJson(FailFile, FailLine));
    Fail.Add('line', FailLine);
    Fail.Add('exception', AItem.Failure.ExceptionName);
    Fail.Add('sourceUnit', AItem.Failure.SourceUnit);
    Result.Add('failure', Fail);
  end
  else if (AItem.Status = tstIgnored) and (AItem.Failure.Message <> '') then
  begin
    Fail := TJSONObject.Create;
    Fail.Add('kind', 'ignored');
    Fail.Add('message', AItem.Failure.Message);
    Result.Add('failure', Fail);
  end;
  Result.Add('output', AItem.Output);
end;

function WarningsToJson(const AWarnings: TTestWarningArray): TJSONArray;
var
  I: Integer;
  Obj: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(AWarnings) do
  begin
    Obj := TJSONObject.Create;
    Obj.Add('file', AWarnings[I].FilePath);
    Obj.Add('line', AWarnings[I].Line);
    Obj.Add('message', AWarnings[I].Message);
    Result.Add(Obj);
  end;
end;

function SummaryToJson(const ASummary: TTestSummary): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('total', ASummary.Total);
  Result.Add('passed', ASummary.Passed);
  Result.Add('failed', ASummary.Failed);
  Result.Add('errors', ASummary.Errors);
  Result.Add('ignored', ASummary.Ignored);
  if ASummary.NotRun > 0 then
    Result.Add('notRun', ASummary.NotRun);
end;

function ProjectToJson(const AManifest: TResolvedManifest; const AProfile: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('kind', ManifestKindToString(AManifest.Kind));
  Result.Add('name', AManifest.ProjectName);
  Result.Add('profile', AProfile);
  Result.Add('manifestPath', AManifest.ManifestPath);
  Result.Add('projectDir', AManifest.ProjectDir);
end;

function FormatMs(AMs: Int64): string;
var
  Fmt: TFormatSettings;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  if AMs < 1000 then
    Result := IntToStr(AMs) + ' ms'
  else
    Result := FormatFloat('0.00', AMs / 1000.0, Fmt) + ' s';
end;

{ TTestRunReporter }

constructor TTestRunReporter.Create(AMode: TTestOutputMode; AVerbose: Boolean;
  const AUnits: TTestUnitInfoArray; ACollector: TTestRunCollector);
begin
  inherited Create;
  FMode := AMode;
  FVerbose := AVerbose;
  FUnits := AUnits;
  FCollector := ACollector;
end;

procedure TTestRunReporter.LocateFailure(const AUnitName: string; ALine: Integer;
  const AItem: TTestResultItem; out AFile: string; out AOutLine: Integer);
begin
  AFile := FindUnitFile(FUnits, AUnitName);
  AOutLine := ALine;
  if (AFile = '') or (AOutLine <= 0) then
  begin
    AFile := AItem.FilePath;
    AOutLine := AItem.Line;
  end;
end;

procedure TTestRunReporter.OnEvent(const AEvent: TTestEvent);
var
  Idx: Integer;
  Item: TTestResultItem;
  Obj: TJSONObject;
  FailFile, Loc: string;
  FailLine: Integer;
begin
  FCollector.OnEvent(AEvent);
  Idx := FCollector.IndexOfId(AEvent.Id);
  if Idx >= 0 then
    Item := FCollector.Items[Idx]
  else
    Item := Default(TTestResultItem);

  if FMode = tomStream then
  begin
    Obj := TJSONObject.Create;
    try
      case AEvent.Kind of
        tekStart:
          begin
            Obj.Add('event', 'start');
            Obj.Add('id', AEvent.Id);
          end;
        tekPass:
          begin
            Obj.Add('event', 'pass');
            Obj.Add('id', AEvent.Id);
            Obj.Add('durationMs', AEvent.DurationMs);
          end;
        tekIgnore:
          begin
            Obj.Add('event', 'ignore');
            Obj.Add('id', AEvent.Id);
            Obj.Add('message', AEvent.Message);
          end;
        tekFail:
          begin
            LocateFailure(AEvent.SourceUnit, AEvent.Line, Item, FailFile, FailLine);
            Obj.Add('event', 'fail');
            Obj.Add('id', AEvent.Id);
            Obj.Add('kind', AEvent.FailKind);
            Obj.Add('message', AEvent.Message);
            Obj.Add('file', LocationJson(FailFile, FailLine));
            Obj.Add('line', FailLine);
            Obj.Add('exception', AEvent.ExceptionName);
            Obj.Add('durationMs', AEvent.DurationMs);
          end;
        tekOutput:
          begin
            Obj.Add('event', 'output');
            if AEvent.Id <> '' then
              Obj.Add('id', AEvent.Id)
            else
              Obj.Add('id', TJSONNull.Create);
            Obj.Add('text', AEvent.Text);
          end;
      end;
      EmitStreamLine(Obj);
    finally
      Obj.Free;
    end;
    Exit;
  end;

  if FMode = tomJson then
    Exit;

  // Human output
  case AEvent.Kind of
    tekPass:
      WriteLn('  ' + StyleGreen('ok  ') + ' ' + AEvent.Id + StyleDim(' (' + FormatMs(AEvent.DurationMs) + ')'));
    tekIgnore:
      WriteLn('  ' + StyleYellow('skip') + ' ' + AEvent.Id + StyleDim(' ' + AEvent.Message));
    tekFail:
      begin
        if Item.Status in [tstFailed, tstError] then
        begin
          LocateFailure(AEvent.SourceUnit, AEvent.Line, Item, FailFile, FailLine);
          WriteLn('  ' + StyleRed('FAIL') + ' ' + AEvent.Id);
          Loc := '';
          if FailFile <> '' then
            Loc := Format('%s(%d): ', [FailFile, FailLine]);
          WriteLn('       ' + Loc + AEvent.Message);
          if AEvent.ExceptionName <> '' then
            WriteLn(StyleDim('       ' + AEvent.ExceptionName));
        end;
      end;
    tekOutput:
      if FVerbose then
        Write(StyleDim(AEvent.Text));
    tekStart:
      ;
  end;
end;

function ExecuteTestCommand(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val, ExplicitProfile, ManifestOverride, BuildVersion: string;
  FlagList, FlagNoRun, FlagClean, FlagVerbose, FlagJson, FlagStream, FlagLocked, FlagOffline: Boolean;
  Mode: TTestOutputMode;
  Filters: TStringArray;
  SdkAutoInstalled: Boolean;
  StartTick: QWord;

  // phase 1
  ManifestFile, Profile, FpcSpecDummy, TargetSpec, HostCpu, HostOs: string;
  Parsed: TParsedManifest;
  TestManifest, BaseManifest: TResolvedManifest;
  Roots: TStringArray;
  Disc: TTestDiscoveryResult;
  AllItems, Selected: TTestResultItemArray;
  SelectedIds: TStringArray;

  // phase 2
  Runner: TGeneratedRunner;
  TargetOpts: TProjectTargetOptions;
  Prepared: TPreparedProjectTarget;
  BuildRes: TProjectCompileResult;
  ExtraDirs: TStringArray;

  // run
  Collector: TTestRunCollector;
  Reporter: TTestRunReporter;
  Parser: TTestProtocolParser;
  RunExit: Integer;
  Summary: TTestSummary;
  CrashEvent: TTestEvent;
  LeakFail, RunOk: Boolean;
  ExitCodeOut: Integer;
  TotalMs: Int64;

  procedure LoadDiscovery;
  var
    K: Integer;
    EntryDir: string;
  begin
    ManifestFile := FindManifestFile(ManifestOverride);
    Parsed := LoadManifestFile(ManifestFile);
    ResolveEffectiveToolchain(Parsed, Profile, True, FpcSpecDummy, TargetSpec);
    SplitTripletSpec(TargetSpec, HostCpu, HostOs);
    TestManifest := ResolveManifestConfig(Parsed, Profile, HostCpu, HostOs, True, False, False);
    BaseManifest := ResolveManifestConfig(Parsed, Profile, HostCpu, HostOs, False, False, False);

    Roots := nil;
    if Trim(BaseManifest.Entry) <> '' then
    begin
      EntryDir := ExtractFileDir(ResolveRelativePath(BaseManifest.ProjectDir, BaseManifest.Entry));
      AppendUniqueDir(Roots, EntryDir);
    end;
    for K := 0 to High(TestManifest.UnitPaths) do
      AppendUniqueDir(Roots, ResolveRelativePath(TestManifest.ProjectDir, TestManifest.UnitPaths[K]));

    Disc := DiscoverTestUnits(TestManifest.ProjectDir, Roots);
    AllItems := CollectDiscoveredTests(Disc.Units);

    Selected := nil;
    SelectedIds := nil;
    for K := 0 to High(AllItems) do
      if TestIdMatchesAnyFilter(AllItems[K].Id, Filters) then
      begin
        SetLength(Selected, Length(Selected) + 1);
        Selected[High(Selected)] := AllItems[K];
        AppendStr(SelectedIds, AllItems[K].Id);
      end;
  end;

  procedure EmitList;
  var
    Root: TJSONObject;
    Arr: TJSONArray;
    K: Integer;
  begin
    if Mode <> tomHuman then
    begin
      Root := TJSONObject.Create;
      try
        Root.Add('success', True);
        Root.Add('mode', 'list');
        Root.Add('project', ProjectToJson(TestManifest, Profile));
        Root.Add('warnings', WarningsToJson(Disc.Warnings));
        Arr := TJSONArray.Create;
        for K := 0 to High(Selected) do
          Arr.Add(ItemToJson(Selected[K], Disc.Units, False));
        Root.Add('tests', Arr);
        WriteJson(Root);
      finally
        Root.Free;
      end;
      Exit;
    end;

    for K := 0 to High(Disc.Warnings) do
      WriteWarn(Format('%s(%d): %s', [Disc.Warnings[K].FilePath, Disc.Warnings[K].Line, Disc.Warnings[K].Message]));
    for K := 0 to High(Selected) do
      WriteLn(Selected[K].Id);
    WriteLn(StyleDim(Format('%d test(s) in %d unit(s)', [Length(Selected), Length(Disc.Units)])));
  end;

  procedure PrintBuildDiagnostics(const AParsed: TParsedCompilerOutput; const ARaw: string);
  var
    K: Integer;
    D: TCompilerDiagnostic;
    Loc: string;
  begin
    for K := 0 to High(AParsed.Diagnostics) do
    begin
      D := AParsed.Diagnostics[K];
      if (D.Severity in [dsNote, dsHint]) and (not FlagVerbose) then
        Continue;
      Loc := '';
      if D.FilePath <> '' then
      begin
        if D.Line > 0 then
          Loc := Format('%s(%d,%d): ', [D.FilePath, D.Line, D.Column])
        else
          Loc := D.FilePath + ': ';
      end;
      WriteLn(StdErr, '  ' + Loc + SeverityToString(D.Severity) + ': ' + D.Message);
    end;
    if (AParsed.ErrorCount = 0) and (Trim(ARaw) <> '') then
      WriteLn(StdErr, TrimRight(ARaw));
  end;

  procedure EmitBuildEvent(const ARes: TProjectCompileResult);
  var
    Root: TJSONObject;
  begin
    Root := TJSONObject.Create;
    try
      Root.Add('event', 'build');
      Root.Add('success', ARes.Compile.Success);
      Root.Add('durationMs', ARes.Compile.DurationMs);
      Root.Add('diagnostics', DiagnosticsToJson(ARes.Compile.ParsedOutput.Diagnostics));
      EmitStreamLine(Root);
    finally
      Root.Free;
    end;
  end;

  procedure EmitFinalJson(ABuildOk: Boolean; const ARes: TProjectCompileResult;
    ABuildRan: Boolean; const ASum: TTestSummary; ASuccess: Boolean; AExit: Integer;
    AHasLeak: Boolean; AUnfreed: Integer; const ALeakReport: string);
  var
    Root, Build, Leaks, Tool: TJSONObject;
    Arr: TJSONArray;
    K: Integer;
    Items: TTestResultItemArray;
  begin
    if Mode = tomStream then
    begin
      Root := TJSONObject.Create;
      try
        Root.Add('event', 'summary');
        Root.Add('success', ASuccess);
        Root.Add('exitCode', AExit);
        Root.Add('durationMs', TotalMs);
        Root.Add('summary', SummaryToJson(ASum));
        Leaks := TJSONObject.Create;
        Leaks.Add('unfreedBlocks', AUnfreed);
        Root.Add('leaks', Leaks);
        EmitStreamLine(Root);
      finally
        Root.Free;
      end;
      Exit;
    end;

    Root := TJSONObject.Create;
    try
      Root.Add('success', ASuccess);
      Root.Add('exitCode', AExit);
      Root.Add('mode', 'run');
      Root.Add('durationMs', TotalMs);
      Root.Add('project', ProjectToJson(BuildRes.Manifest, Profile));
      Tool := TJSONObject.Create;
      Tool.Add('sdkId', BuildRes.Sdk.Manifest.SdkId);
      Tool.Add('fpcVersion', BuildRes.Sdk.Manifest.FpcVersion);
      Tool.Add('targetTriplet', BuildRes.Sdk.Manifest.TargetTriplet);
      Tool.Add('sdkInstalled', SdkAutoInstalled);
      Root.Add('toolchain', Tool);
      Build := TJSONObject.Create;
      Build.Add('success', ABuildOk);
      if ABuildRan then
      begin
        Build.Add('durationMs', ARes.Compile.DurationMs);
        Build.Add('diagnostics', DiagnosticsToJson(ARes.Compile.ParsedOutput.Diagnostics));
      end
      else
        Build.Add('diagnostics', TJSONArray.Create);
      Root.Add('build', Build);
      Root.Add('summary', SummaryToJson(ASum));
      Leaks := TJSONObject.Create;
      Leaks.Add('unfreedBlocks', AUnfreed);
      if AHasLeak and (ALeakReport <> '') then
        Leaks.Add('report', ALeakReport);
      Root.Add('leaks', Leaks);
      Root.Add('warnings', WarningsToJson(Disc.Warnings));
      Arr := TJSONArray.Create;
      if Assigned(Collector) then
        Items := Collector.Items
      else
        Items := nil;
      for K := 0 to High(Items) do
        Arr.Add(ItemToJson(Items[K], Disc.Units, True));
      Root.Add('tests', Arr);
      WriteJson(Root);
    finally
      Root.Free;
    end;
  end;

var
  UnfreedBlocks, K: Integer;
  HeapReport: string;
  EmptyRes: TProjectCompileResult;
begin
  ExplicitProfile := '';
  ManifestOverride := '';
  BuildVersion := '';
  FlagList := False;
  FlagNoRun := False;
  FlagClean := False;
  FlagVerbose := False;
  FlagJson := False;
  FlagStream := False;
  FlagLocked := False;
  FlagOffline := False;
  Filters := nil;
  SdkAutoInstalled := False;
  Collector := nil;
  Reporter := nil;
  Parser := nil;
  EmptyRes := Default(TProjectCompileResult);

  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') or (Arg = 'help') then
    begin
      PrintTestHelp;
      Exit(0);
    end
    else if (Arg = '-p') or (Arg = '--profile') then
      ExplicitProfile := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--profile', Val) then
      ExplicitProfile := Val
    else if (Arg = '-m') or (Arg = '--manifest') then
      ManifestOverride := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--manifest', Val) then
      ManifestOverride := Val
    else if Arg = '--list' then
      FlagList := True
    else if Arg = '--no-run' then
      FlagNoRun := True
    else if Arg = '--clean' then
      FlagClean := True
    else if Arg = '--build-version' then
      BuildVersion := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--build-version', Val) then
      BuildVersion := Val
    else if Arg = '--locked' then
      FlagLocked := True
    else if Arg = '--offline' then
      FlagOffline := True
    else if (Arg = '-v') or (Arg = '--verbose') then
      FlagVerbose := True
    else if Arg = '--json' then
      FlagJson := True
    else if Arg = '--json-stream' then
      FlagStream := True
    else if (Length(Arg) > 0) and (Arg[1] = '-') then
      raise ENikError.CreateWithCode(
        Format('Unknown option ''%s'' for ''nik test''. Run ''nik test --help''.', [Arg]), 2)
    else
      AppendStr(Filters, Arg);
    Inc(I);
  end;

  if FlagJson and FlagStream then
    raise ENikError.CreateWithCode('Options --json and --json-stream cannot be combined.', 2);
  if FlagStream and FlagList then
    raise ENikError.CreateWithCode('Option --json-stream cannot be combined with --list (use --list --json).', 2);

  if FlagStream then
    Mode := tomStream
  else if FlagJson then
    Mode := tomJson
  else
    Mode := tomHuman;

  if ExplicitProfile <> '' then
    Profile := ExplicitProfile
  else
    Profile := 'debug';

  StartTick := GetTickCount64;
  Disc := Default(TTestDiscoveryResult);
  BuildRes := Default(TProjectCompileResult);

  try
    try
      LoadDiscovery;

      if FlagList then
      begin
        EmitList;
        Exit(0);
      end;

      if Length(Selected) = 0 then
      begin
        if Length(Filters) > 0 then
          raise ENikError.CreateWithCode('No tests match the given filter.', 2);
        if Mode = tomHuman then
        begin
          for K := 0 to High(Disc.Warnings) do
            WriteWarn(Format('%s(%d): %s', [Disc.Warnings[K].FilePath, Disc.Warnings[K].Line, Disc.Warnings[K].Message]));
          WriteInfo('No tests found (test units end in _test.pas or .test.pas and register TTestCase classes).');
        end
        else if Mode = tomStream then
        begin
          TotalMs := Int64(GetTickCount64 - StartTick);
          Summary := Default(TTestSummary);
          EmitFinalJson(True, EmptyRes, False, Summary, True, 0, False, 0, '');
        end
        else
        begin
          TotalMs := Int64(GetTickCount64 - StartTick);
          Summary := Default(TTestSummary);
          // Need project info without SDK for the empty report
          BuildRes.Manifest := TestManifest;
          EmitFinalJson(True, EmptyRes, False, Summary, True, 0, False, 0, '');
        end;
        Exit(0);
      end;

      for K := 0 to High(Disc.Warnings) do
        if Mode = tomHuman then
          WriteWarn(Format('%s(%d): %s', [Disc.Warnings[K].FilePath, Disc.Warnings[K].Line, Disc.Warnings[K].Message]));

      // Phase 2: generated runner + compile
      Runner := GenerateTestRunner(TestManifest.ProjectDir, Profile, Disc.Units);
      ExtraDirs := nil;
      for K := 0 to High(Disc.Units) do
        if Length(Disc.Units[K].Classes) > 0 then
          AppendUniqueDir(ExtraDirs, ExtractFileDir(Disc.Units[K].FilePath));
      AppendUniqueDir(ExtraDirs, Runner.RunnerDir);

      TargetOpts := Default(TProjectTargetOptions);
      TargetOpts.Role := ptrTestRunner;
      TargetOpts.ManifestOverride := ManifestOverride;
      TargetOpts.ProfileName := Profile;
      TargetOpts.EntryOverride := Runner.ProgramPath;
      TargetOpts.ExtraUnitPaths := ExtraDirs;
      TargetOpts.Clean := FlagClean;
      TargetOpts.BuildVersion := BuildVersion;
      TargetOpts.Locked := FlagLocked;
      TargetOpts.Offline := FlagOffline;
      TargetOpts.AutoInstallSdk := not FlagOffline;
      TargetOpts.QuietSdkInstall := (Mode <> tomHuman);

      Prepared := PrepareProjectTarget(TargetOpts, SdkAutoInstalled);

      if Mode = tomHuman then
      begin
        WriteStep(Format('Testing %s [%s] (FPC %s, %s)...',
          [Prepared.Manifest.ProjectName, Prepared.Manifest.ProfileName,
           Prepared.Sdk.Manifest.FpcVersion, Prepared.Sdk.Manifest.TargetTriplet]));
        if FlagVerbose then
        begin
          WriteLn(StyleDim('    Manifest : ' + Prepared.Manifest.ManifestPath));
          WriteLn(StyleDim('    SDK      : ' + Prepared.Sdk.Manifest.SdkId));
          WriteLn(StyleDim('    Cache    : ' + Prepared.Compile.Spec.UnitOutputDir));
        end;
      end;

      BuildRes := ExecuteProjectTarget(Prepared);

      if Mode = tomStream then
        EmitBuildEvent(BuildRes);

      if not BuildRes.Compile.Success then
      begin
        TotalMs := Int64(GetTickCount64 - StartTick);
        Summary := Default(TTestSummary);
        if Mode = tomHuman then
        begin
          PrintBuildDiagnostics(BuildRes.Compile.ParsedOutput, BuildRes.Compile.RawCompilerOutput);
          raise ENikError.CreateWithCode(
            Format('Test build failed for ''%s'' [%s] (%d error(s)).',
              [BuildRes.Manifest.ProjectName, BuildRes.Manifest.ProfileName,
               BuildRes.Compile.ParsedOutput.ErrorCount]),
            BuildRes.Compile.ExitCode);
        end;
        Collector := nil;
        EmitFinalJson(False, BuildRes, True, Summary, False, BuildRes.Compile.ExitCode, False, 0, '');
        Exit(BuildRes.Compile.ExitCode);
      end;

      if FlagNoRun then
      begin
        TotalMs := Int64(GetTickCount64 - StartTick);
        Summary := Default(TTestSummary);
        if Mode = tomHuman then
          WriteSuccess(Format('Built test runner %s (%s)',
            [BuildRes.Compile.Spec.OutputBinaryPath, FormatMs(BuildRes.Compile.DurationMs)]))
        else
        begin
          Collector := TTestRunCollector.Create(Disc.Units);
          try
            EmitFinalJson(True, BuildRes, True, Collector.Summary, True, 0, False, 0, '');
          finally
            FreeAndNil(Collector);
          end;
        end;
        Exit(0);
      end;

      // Run
      if Length(Filters) > 0 then
        WriteRunnerIdsFile(Runner.IdsFilePath, SelectedIds);

      Collector := TTestRunCollector.Create(Disc.Units);
      if Length(Filters) > 0 then
        Collector.RestrictTo(SelectedIds);
      Reporter := TTestRunReporter.Create(Mode, FlagVerbose, Disc.Units, Collector);
      Parser := TTestProtocolParser.Create(@Reporter.OnEvent);

      if Length(Filters) > 0 then
        RunExit := RunTestBinary(BuildRes.Compile.Spec.OutputBinaryPath,
          BuildRes.Manifest.ProjectDir, Runner.IdsFilePath, Parser)
      else
        RunExit := RunTestBinary(BuildRes.Compile.Spec.OutputBinaryPath,
          BuildRes.Manifest.ProjectDir, '', Parser);

      if Parser.CurrentId <> '' then
      begin
        // The test process died while a test was running: report it like any other error event
        CrashEvent := Default(TTestEvent);
        CrashEvent.Kind := tekFail;
        CrashEvent.Id := Parser.CurrentId;
        CrashEvent.FailKind := 'error';
        CrashEvent.Message := Format('Test process terminated unexpectedly (exit code %d).', [RunExit]);
        Reporter.OnEvent(CrashEvent);
      end;

      // Tests filtered out by --ids-file stay 'notrun'; drop them from the report unless no filter
      UnfreedBlocks := Parser.UnfreedBlocks;
      HeapReport := Parser.HeapReport;
      LeakFail := Parser.HasHeapReport and (UnfreedBlocks > 0) and (Parser.CurrentId = '');
      Summary := Collector.Summary;
      if Length(Filters) > 0 then
        Summary.NotRun := 0;

      RunOk := (Summary.Failed = 0) and (Summary.Errors = 0) and (not LeakFail) and
        (Parser.CurrentId = '') and (RunExit = 0);

      if RunOk then
        ExitCodeOut := 0
      else
        ExitCodeOut := 1;
      TotalMs := Int64(GetTickCount64 - StartTick);

      if Mode = tomHuman then
      begin
        for K := 0 to High(Collector.Items) do
          if (Collector.Items[K].Status in [tstFailed, tstError]) and
             (Trim(Collector.Items[K].Output) <> '') and (not FlagVerbose) then
          begin
            WriteLn(StyleDim('--- output of ' + Collector.Items[K].Id + ' ---'));
            Write(Collector.Items[K].Output);
          end;
        if LeakFail then
        begin
          WriteLn(StdErr, StyleRed(Format('Memory leak detected: %d unfreed memory block(s).', [UnfreedBlocks])));
          WriteLn(StdErr, TrimRight(HeapReport));
        end;
        if Summary.NotRun > 0 then
          WriteWarn(Format('%d test(s) did not run.', [Summary.NotRun]));
        if RunOk then
          WriteSuccess(Format('%d test(s) passed%s (%s)', [Summary.Passed,
            IfThen(Summary.Ignored > 0, Format(', %d skipped', [Summary.Ignored]), ''), FormatMs(TotalMs)]))
        else
          raise ENikError.CreateWithCode(
            Format('%d of %d test(s) failed%s (%s)',
              [Summary.Failed + Summary.Errors, Summary.Total,
               IfThen(LeakFail, ', memory leak detected', ''), FormatMs(TotalMs)]),
            1);
      end
      else
        EmitFinalJson(True, BuildRes, True, Summary, RunOk, ExitCodeOut, LeakFail, UnfreedBlocks, HeapReport);

      Result := ExitCodeOut;
    except
      on E: ENikError do
      begin
        if Mode <> tomHuman then
        begin
          EmitPreflightError(Mode, E.Message, E.ExitCode, SdkAutoInstalled);
          Exit(E.ExitCode);
        end;
        raise;
      end;
    end;
  finally
    Parser.Free;
    Reporter.Free;
    Collector.Free;
  end;
end;

end.
