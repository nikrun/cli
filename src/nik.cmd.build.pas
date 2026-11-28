unit nik.cmd.build;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nik.project;

function ExecuteBuildCommand(const AArgs: array of string): Integer;
procedure PrintBuildHelp;

type
  TBuildPipelineOptions = record
    ProfileName: string;
    Source: string;     // optional: directory, nik.yaml, Pascal file or https:// URL
    Clean: Boolean;
    Verbose: Boolean;
    Json: Boolean;
    Trust: Boolean;     // accept untrusted URL sources without prompting (run only)
    Quiet: Boolean;     // keep stdout free of nik messages (build progress goes away, details to stderr)
    ForRun: Boolean;    // binary will be executed afterwards (trust check, cache output)
    Target: TProjectTargetOptions;
  end;

{ Shared by 'nik build' and 'nik run'. Returns the exit code; ABinaryPath is the built artifact. }
function RunBuildPipeline(const AOpts: TBuildPipelineOptions; out ABinaryPath: string;
  out AIsProgram: Boolean): Integer;
function SplitOptEq(const AArg, AOptName: string; out AVal: string): Boolean;
function NextOptValue(const AArgs: array of string; var AIndex: Integer; const AOptName: string): string;

implementation

uses
  fpjson, nik.types, nik.term, nik.paths, nik.manifest.types, nik.compiler.types, nik.compiler.diag,
  nik.source;

procedure PrintBuildHelp;
begin
  WriteLn(StyleBold('Compile a Free Pascal project (nik.yaml), a single Pascal file or a web URL'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik build [OPTIONS] [SOURCE]');
  WriteLn;
  WriteLn(StyleBold('SOURCE:'));
  WriteLn('  (none)                 Project in the current directory (nik.yaml)');
  WriteLn('  <dir> | <nik.yaml>     Another project');
  WriteLn('  <file.pas>             A single Pascal file (uses the newest installed SDK; binary in ./bin)');
  WriteLn('  <https://...>          Git repository, or a file/directory inside one, e.g.');
  WriteLn('                         https://github.com/owner/repo/blob/main/app.pas or ...repo@v1.2.0');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('  -p, --profile <NAME>   Build with the named profile from nik.yaml (default: debug)');
  WriteLn('  -m, --manifest <PATH>  Path to nik.yaml or project directory (same as a SOURCE path)');
  WriteLn('      --clean            Clean profile build cache (.nik/cache) and force rebuild (-B)');
  WriteLn('      --build-version <V> Use <V> instead of ''version'' from nik.yaml for this build (e.g. a CI tag);');
  WriteLn('                         it feeds the generated unit nikmanifest and the Windows resource');
  WriteLn('      --locked           Require nik.lock to be up to date without modifying it');
  WriteLn('      --offline          Use only locally installed SDKs and cached packages without network');
  WriteLn('  -v, --verbose          Show full compiler invocation and note/hint diagnostics');
  WriteLn('  -q, --quiet            No progress messages on stdout (errors and diagnostics stay on stderr)');
  WriteLn('      --json             Output structured JSON build report and diagnostics');
  WriteLn('  -h, --help             Show this help message');
  WriteLn;
  WriteLn(StyleBold('EXAMPLES:'));
  WriteLn('  nik build');
  WriteLn('  nik build -p release');
  WriteLn('  nik build --profile trunk');
  WriteLn('  nik build --clean --verbose');
  WriteLn('  nik build --json');
  WriteLn('  nik build tools/gen.pas');
  WriteLn('  nik build https://github.com/RalliKam/TWIN/blob/main/twin.pas');
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
    raise ENikError.CreateFmt('Option %s requires a value.', [AOptName]);
  Inc(AIndex);
  Result := AArgs[AIndex];
end;

function FormatDurationSec(ADurationMs: Int64): string;
var
  Fmt: TFormatSettings;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  if ADurationMs < 1000 then
    Result := IntToStr(ADurationMs) + ' ms'
  else
    Result := FormatFloat('0.00', ADurationMs / 1000.0, Fmt) + ' s';
end;

function QuoteArgIfNeeded(const AArg: string): string;
begin
  if (Pos(' ', AArg) > 0) or (Pos(#9, AArg) > 0) then
    Result := '"' + AArg + '"'
  else
    Result := AArg;
end;

function FormatCommandLine(const AExe: string; const AArgs: TStringArray): string;
var
  I: Integer;
begin
  Result := QuoteArgIfNeeded(AExe);
  for I := 0 to High(AArgs) do
    Result := Result + ' ' + QuoteArgIfNeeded(AArgs[I]);
end;

procedure PrintDiagnosticHuman(const ADiag: TCompilerDiagnostic; AToStdErr: Boolean = False);
var
  Loc, SevLabel, CodePart: string;
begin
  Loc := '';
  if ADiag.FilePath <> '' then
  begin
    Loc := ADiag.FilePath;
    if ADiag.Line > 0 then
    begin
      if ADiag.Column > 0 then
        Loc := Format('%s(%d,%d): ', [ADiag.FilePath, ADiag.Line, ADiag.Column])
      else
        Loc := Format('%s(%d): ', [ADiag.FilePath, ADiag.Line]);
    end
    else
      Loc := Loc + ': ';
  end;

  if ADiag.Code > 0 then
    CodePart := Format(' [%d]', [ADiag.Code])
  else
    CodePart := '';

  case ADiag.Severity of
    dsFatal:
      begin
        SevLabel := StyleRed('fatal' + CodePart + ':');
        WriteLn(StdErr, '  ' + StyleBold(Loc) + SevLabel + ' ' + ADiag.Message);
      end;
    dsError:
      begin
        SevLabel := StyleRed('error' + CodePart + ':');
        WriteLn(StdErr, '  ' + StyleBold(Loc) + SevLabel + ' ' + ADiag.Message);
      end;
    dsWarning:
      begin
        SevLabel := StyleYellow('warning' + CodePart + ':');
        WriteLn(StdErr, '  ' + Loc + SevLabel + ' ' + ADiag.Message);
      end;
    dsNote:
      begin
        SevLabel := StyleDim('note' + CodePart + ':');
        if AToStdErr then
          WriteLn(StdErr, '  ' + StyleDim(Loc) + SevLabel + ' ' + StyleDim(ADiag.Message))
        else
          WriteLn('  ' + StyleDim(Loc) + SevLabel + ' ' + StyleDim(ADiag.Message));
      end;
    dsHint:
      begin
        SevLabel := StyleDim('hint' + CodePart + ':');
        if AToStdErr then
          WriteLn(StdErr, '  ' + StyleDim(Loc) + SevLabel + ' ' + StyleDim(ADiag.Message))
        else
          WriteLn('  ' + StyleDim(Loc) + SevLabel + ' ' + StyleDim(ADiag.Message));
      end;
  else
    raise ENikError.CreateFmt('Unsupported TDiagSeverity ordinal: %d', [Ord(ADiag.Severity)]);
  end;
end;

procedure EmitBuildResultJson(const ARes: TProjectCompileResult);
var
  Root, ProjObj, ToolObj, OutObj, CountsObj, DiagObj: TJSONObject;
  DiagArr: TJSONArray;
  I: Integer;
  D: TCompilerDiagnostic;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('success', ARes.Compile.Success);
    Root.Add('exitCode', ARes.Compile.ExitCode);
    Root.Add('durationMs', ARes.Compile.DurationMs);

    ProjObj := TJSONObject.Create;
    ProjObj.Add('kind', ManifestKindToString(ARes.Manifest.Kind));
    ProjObj.Add('name', ARes.Manifest.ProjectName);
    ProjObj.Add('version', ARes.Manifest.ProjectVersion);
    ProjObj.Add('profile', ARes.Manifest.ProfileName);
    ProjObj.Add('manifestPath', ARes.Manifest.ManifestPath);
    ProjObj.Add('projectDir', ARes.Manifest.ProjectDir);
    ProjObj.Add('entryPath', ARes.Compile.Spec.EntryPath);
    Root.Add('project', ProjObj);

    ToolObj := TJSONObject.Create;
    ToolObj.Add('sdkId', ARes.Sdk.Manifest.SdkId);
    ToolObj.Add('fpcVersion', ARes.Sdk.Manifest.FpcVersion);
    ToolObj.Add('targetTriplet', ARes.Sdk.Manifest.TargetTriplet);
    ToolObj.Add('installPath', ARes.Sdk.InstallPath);
    ToolObj.Add('sdkInstalled', ARes.SdkAutoInstalled);
    ToolObj.Add('compilerBinary', ARes.Compile.Spec.CompilerBinary);
    ToolObj.Add('fpcCfg', ARes.Compile.Spec.FpcCfgPath);
    Root.Add('toolchain', ToolObj);

    OutObj := TJSONObject.Create;
    OutObj.Add('binaryPath', ARes.Compile.Spec.OutputBinaryPath);
    OutObj.Add('cacheDir', ARes.Compile.Spec.UnitOutputDir);
    OutObj.Add('sizeBytes', ARes.Compile.OutputSizeBytes);
    OutObj.Add('linesCompiled', ARes.Compile.ParsedOutput.LinesCompiled);
    Root.Add('output', OutObj);

    CountsObj := TJSONObject.Create;
    CountsObj.Add('errors', ARes.Compile.ParsedOutput.ErrorCount);
    CountsObj.Add('warnings', ARes.Compile.ParsedOutput.WarningCount);
    CountsObj.Add('notes', ARes.Compile.ParsedOutput.NoteCount);
    CountsObj.Add('hints', ARes.Compile.ParsedOutput.HintCount);
    Root.Add('counts', CountsObj);

    DiagArr := TJSONArray.Create;
    for I := 0 to High(ARes.Compile.ParsedOutput.Diagnostics) do
    begin
      D := ARes.Compile.ParsedOutput.Diagnostics[I];
      DiagObj := TJSONObject.Create;
      if D.FilePath <> '' then
        DiagObj.Add('file', D.FilePath)
      else
        DiagObj.Add('file', TJSONNull.Create);
      DiagObj.Add('line', D.Line);
      DiagObj.Add('column', D.Column);
      DiagObj.Add('severity', SeverityToString(D.Severity));
      DiagObj.Add('code', D.Code);
      DiagObj.Add('message', D.Message);
      DiagArr.Add(DiagObj);
    end;
    Root.Add('diagnostics', DiagArr);

    WriteJson(Root);
  finally
    Root.Free;
  end;
end;

procedure EmitPreflightErrorJson(const AErrorMsg: string; AExitCode: Integer;
  ASdkAutoInstalled: Boolean);
var
  Root: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('success', False);
    Root.Add('exitCode', AExitCode);
    Root.Add('sdkInstalled', ASdkAutoInstalled);
    Root.Add('error', AErrorMsg);
    Root.Add('diagnostics', TJSONArray.Create);
    WriteJson(Root);
  finally
    Root.Free;
  end;
end;

function RunBuildPipeline(const AOpts: TBuildPipelineOptions; out ABinaryPath: string;
  out AIsProgram: Boolean): Integer;
var
  I, HiddenNotes: Integer;
  FlagClean, FlagVerbose, FlagJson, SdkAutoInstalled: Boolean;
  TargetOpts: TProjectTargetOptions;
  Prepared: TPreparedProjectTarget;
  Res: TProjectCompileResult;
  D: TCompilerDiagnostic;
  SummaryParts: string;
  SrcOpts: TSourceOptions;
  Resolved: TResolvedSource;
begin
  ABinaryPath := '';
  AIsProgram := False;
  FlagClean := AOpts.Clean;
  FlagVerbose := AOpts.Verbose;
  FlagJson := AOpts.Json;
  SdkAutoInstalled := False;
  TargetOpts := AOpts.Target;
  TargetOpts.Role := ptrMainArtifact;

  if AOpts.ProfileName <> '' then
    TargetOpts.ProfileName := AOpts.ProfileName
  else
    TargetOpts.ProfileName := 'debug';

  TargetOpts.Clean := FlagClean;
  TargetOpts.AutoInstallSdk := not TargetOpts.Offline;
  TargetOpts.QuietSdkInstall := FlagJson or AOpts.Quiet;

  try
    if AOpts.Source <> '' then
    begin
      if TargetOpts.ManifestOverride <> '' then
        raise ENikError.Create('Cannot combine a SOURCE argument with --manifest.');
      SrcOpts := Default(TSourceOptions);
      SrcOpts.Offline := TargetOpts.Offline;
      SrcOpts.Trust := AOpts.Trust;
      SrcOpts.ForRun := AOpts.ForRun;
      SrcOpts.Quiet := FlagJson or AOpts.Quiet;
      Resolved := ResolveSource(AOpts.Source, SrcOpts);
      TargetOpts.ManifestOverride := Resolved.ManifestPath;
      TargetOpts.EntryOverride := Resolved.EntryOverride;
      // 'nik build <file|url>' leaves the binary in ./bin; 'nik run' keeps it in the cache.
      if (not AOpts.ForRun) and (Resolved.DefaultOutputName <> '') then
        TargetOpts.OutputOverride := JoinPath(JoinPath(GetCurrentDir, 'bin'), Resolved.DefaultOutputName);
    end;
    Prepared := PrepareProjectTarget(TargetOpts, SdkAutoInstalled);
  except
    on E: ENikError do
    begin
      if FlagJson then
      begin
        EmitPreflightErrorJson(E.Message, E.ExitCode, SdkAutoInstalled);
        Exit(E.ExitCode);
      end;
      raise;
    end;
  end;

  if not FlagJson then
    for I := 0 to High(Prepared.Warnings) do
      WriteLn(StdErr, '  ' + StyleYellow('warning:') + ' ' + Prepared.Warnings[I]);

  if (not FlagJson) and (not AOpts.Quiet) then
  begin
    WriteStep(Format('Building %s [%s] (FPC %s, %s)...',
      [Prepared.Manifest.ProjectName, Prepared.Manifest.ProfileName,
       Prepared.Sdk.Manifest.FpcVersion, Prepared.Sdk.Manifest.TargetTriplet]));
    if FlagVerbose then
    begin
      WriteLn(StyleDim('    Manifest : ' + Prepared.Manifest.ManifestPath));
      WriteLn(StyleDim('    SDK      : ' + Prepared.Sdk.Manifest.SdkId));
      WriteLn(StyleDim('    Cache    : ' + Prepared.Compile.Spec.UnitOutputDir));
      WriteLn(StyleDim('    Command  : ' + FormatCommandLine(
        Prepared.Compile.Spec.CompilerBinary, Prepared.Compile.CompilerArgs)));
    end;
  end;

  Res := ExecuteProjectTarget(Prepared);

  if FlagJson then
  begin
    EmitBuildResultJson(Res);
    ABinaryPath := Res.Compile.Spec.OutputBinaryPath;
    AIsProgram := Res.Manifest.Kind = mkProgram;
    if Res.Compile.Success then
      Exit(0)
    else
      Exit(Res.Compile.ExitCode);
  end;

  // Human diagnostic output
  HiddenNotes := 0;
  for I := 0 to High(Res.Compile.ParsedOutput.Diagnostics) do
  begin
    D := Res.Compile.ParsedOutput.Diagnostics[I];
    if (D.Severity in [dsNote, dsHint]) and (not FlagVerbose) then
      Inc(HiddenNotes)
    else
      PrintDiagnosticHuman(D, AOpts.Quiet);
  end;

  if not Res.Compile.Success then
  begin
    if (Res.Compile.ParsedOutput.ErrorCount = 0) and (Trim(Res.Compile.RawCompilerOutput) <> '') then
      WriteLn(StdErr, TrimRight(Res.Compile.RawCompilerOutput));

    raise ENikError.CreateWithCode(
      Format('Build failed for ''%s'' [%s] (%d error(s), %d warning(s)).',
        [Res.Manifest.ProjectName, Res.Manifest.ProfileName,
         Res.Compile.ParsedOutput.ErrorCount, Res.Compile.ParsedOutput.WarningCount]),
      Res.Compile.ExitCode);
  end;

  SummaryParts := Format('%s, %s', [
    FormatByteSize(Res.Compile.OutputSizeBytes),
    FormatDurationSec(Res.Compile.DurationMs)]);
  if Res.Compile.ParsedOutput.WarningCount > 0 then
    SummaryParts := SummaryParts + Format(', %d warning(s)', [Res.Compile.ParsedOutput.WarningCount]);
  if HiddenNotes > 0 then
    SummaryParts := SummaryParts + Format(', %d note(s)', [HiddenNotes]);

  if not AOpts.Quiet then
    WriteSuccess(Format('Built %s (%s)', [Res.Compile.Spec.OutputBinaryPath, SummaryParts]));
  ABinaryPath := Res.Compile.Spec.OutputBinaryPath;
  AIsProgram := Res.Manifest.Kind = mkProgram;
  Result := 0;
end;

function ExecuteBuildCommand(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val: string;
  Opts: TBuildPipelineOptions;
  BinPath: string;
  IsProg: Boolean;
begin
  Opts := Default(TBuildPipelineOptions);
  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') or (Arg = 'help') then
    begin
      PrintBuildHelp;
      Exit(0);
    end
    else if (Arg = '-p') or (Arg = '--profile') then
      Opts.ProfileName := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--profile', Val) then
      Opts.ProfileName := Val
    else if (Arg = '-m') or (Arg = '--manifest') then
      Opts.Target.ManifestOverride := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--manifest', Val) then
      Opts.Target.ManifestOverride := Val
    else if Arg = '--clean' then
      Opts.Clean := True
    else if Arg = '--build-version' then
      Opts.Target.BuildVersion := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--build-version', Val) then
      Opts.Target.BuildVersion := Val
    else if Arg = '--locked' then
      Opts.Target.Locked := True
    else if Arg = '--offline' then
      Opts.Target.Offline := True
    else if (Arg = '-v') or (Arg = '--verbose') then
      Opts.Verbose := True
    else if (Arg = '-q') or (Arg = '--quiet') then
      Opts.Quiet := True
    else if Arg = '--json' then
      Opts.Json := True
    else if (Arg = '--release') or (Arg = '-r') then
      raise ENikError.CreateFmt('Unknown option ''%s'' for ''nik build''. Use ''-p release'' or ''--profile release''.', [Arg])
    else if (Arg <> '') and (Arg[1] = '-') then
      raise ENikError.CreateFmt('Unknown option ''%s'' for ''nik build''. Run ''nik build --help''.', [Arg])
    else if Opts.Source = '' then
      Opts.Source := Arg
    else
      raise ENikError.CreateFmt('Unexpected argument ''%s'' for ''nik build'' (only one SOURCE is allowed).', [Arg]);
    Inc(I);
  end;
  Result := RunBuildPipeline(Opts, BinPath, IsProg);
end;

end.
