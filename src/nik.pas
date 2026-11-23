program nik;

{$mode objfpc}{$H+}
{$IFDEF WINDOWS}
{$IFDEF NIK_HAS_WIN_RES}
{$I nik_build_icon.inc}
{$ENDIF}
{$ENDIF}

uses
  SysUtils, fpjson,
  nik.types,
  nik.platform,
  nik.term,
  nik.paths,
  nik.cmd.init,
  nik.cmd.sdk,
  nik.cmd.pkg,
  nik.cmd.build,
  nik.cmd.run,
  nik.cmd.tests,
  nik.cmd.lsp;

procedure PrintVersion;
begin
  WriteLn(Format('nik %s (%s-%s, FPC %s)',
    [NIK_VERSION, GetCompileTimeCpu, GetHostOs, {$I %FPCVERSION%}]));
end;

procedure PrintGlobalHelp;
begin
  WriteLn(StyleBold('Nikrun CLI') + ' (' + StyleBold('nik') + ') ' + NIK_VERSION + ' - Modern Zero-Config Toolchain for Free Pascal');
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik [GLOBAL OPTIONS] <COMMAND> [ARGS]');
  WriteLn;
  WriteLn(StyleBold('COMMANDS:'));
  WriteLn('  ' + PadRightStr('init', 14) + 'Initialize a new Free Pascal project (nik.yaml)');
  WriteLn('  ' + PadRightStr('build', 14) + 'Compile a project, a single Pascal file or a web URL');
  WriteLn('  ' + PadRightStr('run', 14) + 'Build and run a project, a single Pascal file or a web URL');
  WriteLn('  ' + PadRightStr('test', 14) + 'Discover, compile, and run fpcunit tests');
  WriteLn('  ' + PadRightStr('pkg', 14) + 'Fetch, update, list, and inspect nik.yaml dependencies');
  WriteLn('  ' + PadRightStr('lsp', 14) + 'Start the Free Pascal Language Server (LSP 3.17)');
  WriteLn('  ' + PadRightStr('sdk', 14) + 'Discover, install, inspect, and remove Free Pascal SDKs');
  WriteLn('  ' + PadRightStr('version', 14) + 'Print CLI version and target information');
  WriteLn('  ' + PadRightStr('help', 14) + 'Display help information');
  WriteLn;
  WriteLn(StyleBold('GLOBAL OPTIONS:'));
  WriteLn('      --nikrun-home <DIR>  Override toolchain root directory (default: ~/.nikrun or $NIKRUN_HOME)');
  WriteLn('      --no-color           Disable ANSI colored terminal output');
  WriteLn('  -V, --version            Print version information');
  WriteLn('  -h, --help               Print help information');
  WriteLn;
  WriteLn('Run ' + StyleBold('nik <COMMAND> --help') + ' for detailed information on a command.');
end;

function JsonRequested: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--json' then
      Exit(True);
end;

// Last-resort error report. Commands that know their own JSON shape (build, pkg, init) report
// their errors themselves; everything that still reaches this point (argument errors, unknown
// commands, unexpected exceptions) must not break `--json` consumers, so it becomes a JSON
// object on stdout with an empty stderr, like the command-level error objects.
procedure ReportFatalError(const AMessage: string; AExitCode: Integer);
var
  Root: TJSONObject;
begin
  if JsonRequested then
  begin
    Root := TJSONObject.Create;
    try
      Root.Add('success', False);
      Root.Add('exitCode', AExitCode);
      Root.Add('error', AMessage);
      WriteJson(Root);
    finally
      Root.Free;
    end;
  end
  else
    WriteError(AMessage);
end;

function RunCli: Integer;
var
  RawArgs, FilteredArgs, CmdArgs: array of string;
  I, Count: Integer;
  Arg, CmdName, Prefix: string;
  ForceNoColor, ShowVersion, ShowHelp: Boolean;
begin
  ForceNoColor := False;
  ShowVersion := False;
  ShowHelp := False;
  RawArgs := nil;
  FilteredArgs := nil;

  SetLength(RawArgs, ParamCount);
  for I := 1 to ParamCount do
    RawArgs[I - 1] := ParamStr(I);

  // Extract global options accepted anywhere on the command line
  Count := 0;
  I := 0;
  Prefix := '--nikrun-home=';
  while I <= High(RawArgs) do
  begin
    Arg := RawArgs[I];
    if Arg = '--no-color' then
      ForceNoColor := True
    else if Arg = '--nikrun-home' then
    begin
      if I + 1 > High(RawArgs) then
      begin
        InitTerminal(ForceNoColor);
        raise ENikError.Create('Option --nikrun-home requires a directory path.');
      end;
      Inc(I);
      SetNikrunHomeOverride(RawArgs[I]);
    end
    else if (Length(Arg) >= Length(Prefix)) and SameText(Copy(Arg, 1, Length(Prefix)), Prefix) then
      SetNikrunHomeOverride(Copy(Arg, Length(Prefix) + 1, MaxInt))
    else
    begin
      SetLength(FilteredArgs, Count + 1);
      FilteredArgs[Count] := Arg;
      Inc(Count);
    end;
    Inc(I);
  end;

  InitTerminal(ForceNoColor);

  if Length(FilteredArgs) = 0 then
  begin
    PrintGlobalHelp;
    Exit(0);
  end;

  CmdName := LowerCase(Trim(FilteredArgs[0]));
  ShowVersion := (CmdName = 'version') or (CmdName = '-v') or (FilteredArgs[0] = '-V') or (CmdName = '--version');
  if ShowVersion then
  begin
    PrintVersion;
    Exit(0);
  end;

  ShowHelp := (CmdName = 'help') or (CmdName = '-h') or (CmdName = '--help');
  if ShowHelp then
  begin
    if (Length(FilteredArgs) >= 2) and SameText(FilteredArgs[1], 'init') then
      PrintInitHelp
    else if (Length(FilteredArgs) >= 2) and SameText(FilteredArgs[1], 'sdk') then
      PrintSdkHelp
    else if (Length(FilteredArgs) >= 2) and SameText(FilteredArgs[1], 'pkg') then
      PrintPkgHelp
    else if (Length(FilteredArgs) >= 2) and SameText(FilteredArgs[1], 'build') then
      PrintBuildHelp
    else if (Length(FilteredArgs) >= 2) and SameText(FilteredArgs[1], 'run') then
      PrintRunHelp
    else if (Length(FilteredArgs) >= 2) and SameText(FilteredArgs[1], 'test') then
      PrintTestHelp
    else if (Length(FilteredArgs) >= 2) and SameText(FilteredArgs[1], 'lsp') then
      PrintLspHelp
    else
      PrintGlobalHelp;
    Exit(0);
  end;

  CmdArgs := nil;
  if Length(FilteredArgs) > 1 then
  begin
    SetLength(CmdArgs, Length(FilteredArgs) - 1);
    for I := 1 to High(FilteredArgs) do
      CmdArgs[I - 1] := FilteredArgs[I];
  end;

  if CmdName = 'init' then
    Result := ExecuteInitCommand(CmdArgs)
  else if CmdName = 'sdk' then
    Result := ExecuteSdkCommand(CmdArgs)
  else if CmdName = 'pkg' then
    Result := ExecutePkgCommand(CmdArgs)
  else if CmdName = 'build' then
    Result := ExecuteBuildCommand(CmdArgs)
  else if CmdName = 'run' then
    Result := ExecuteRunCommand(CmdArgs)
  else if CmdName = 'test' then
    Result := ExecuteTestCommand(CmdArgs)
  else if CmdName = 'lsp' then
    Result := ExecuteLspCommand(CmdArgs)
  else
    raise ENikError.CreateFmt('Unknown command ''%s''. Run ''nik --help'' for available commands.', [FilteredArgs[0]]);
end;

begin
  HardenHostProcess;
  try
    ExitCode := RunCli;
  except
    on E: ENikError do
    begin
      ReportFatalError(E.Message, E.ExitCode);
      ExitCode := E.ExitCode;
    end;
    on E: Exception do
    begin
      ReportFatalError(E.Message, 1);
      ExitCode := 1;
    end;
  end;
  if (ExitCode <> 0) and ((ExitCode and $FF) = 0) then
    ExitCode := 1;
end.
