unit nik.cmd.run;

{$mode objfpc}{$H+}

{ 'nik run': builds a project, a single Pascal file or a web URL like 'nik build' and starts the result. }

interface

uses
  SysUtils;

function ExecuteRunCommand(const AArgs: array of string): Integer;
procedure PrintRunHelp;

implementation

uses
  Classes, Process, nik.types, nik.term, nik.cmd.build;

procedure PrintRunHelp;
begin
  WriteLn(StyleBold('Build and run a Free Pascal program (project, single file or web URL)'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik run [OPTIONS] [SOURCE] [-- PROGRAM_ARGS...]');
  WriteLn;
  WriteLn(StyleBold('SOURCE:'));
  WriteLn('  (none)                 Project in the current directory (nik.yaml)');
  WriteLn('  <dir> | <nik.yaml>     Another project');
  WriteLn('  <file.pas>             A single Pascal file (uses the newest installed SDK)');
  WriteLn('  <https://...>          Git repository, or a file/directory inside one, e.g.');
  WriteLn('                         https://github.com/owner/repo/blob/main/app.pas or ...repo@v1.2.0');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('  -p, --profile <NAME>   Build with the named profile from nik.yaml (default: debug)');
  WriteLn('  -m, --manifest <PATH>  Path to nik.yaml or project directory (same as a SOURCE path)');
  WriteLn('      --trust            Run an untrusted URL source without asking (for CI and scripts)');
  WriteLn('      --clean            Clean profile build cache (.nik/cache) and force rebuild (-B)');
  WriteLn('      --build-version <V> Use <V> instead of ''version'' from nik.yaml for this build');
  WriteLn('      --locked           Require nik.lock to be up to date without modifying it');
  WriteLn('      --offline          Use only locally installed SDKs and cached packages without network');
  WriteLn('  -v, --verbose          Show full compiler invocation and note/hint diagnostics');
  WriteLn('  -q, --quiet            Keep stdout for the program only: no build or fetch messages there');
  WriteLn('                         (needed for programs that speak a protocol on stdout, e.g. MCP servers)');
  WriteLn('  -h, --help             Show this help message');
  WriteLn;
  WriteLn(StyleBold('URL SOURCES:'));
  WriteLn('  Code from a URL is compiled and run natively with your user permissions (no sandbox).');
  WriteLn('  The first run of a repository state asks for confirmation; the exact tree is remembered in');
  WriteLn('  ~/.nikrun/trust.json, and a changed commit asks again. Without a terminal (or CI=1) pass --trust.');
  WriteLn('  Pin a version with ...repo@<tag|commit> or a commit in the URL for reproducible runs.');
  WriteLn;
  WriteLn(StyleBold('EXAMPLES:'));
  WriteLn('  nik run');
  WriteLn('  nik run -- --port 8080');
  WriteLn('  nik run tools/gen.pas -- input.txt');
  WriteLn('  nik run https://github.com/RalliKam/TWIN/blob/main/twin.pas');
  WriteLn('  nik run --trust https://github.com/owner/repo@v1.2.0');
end;

function ExecuteRunCommand(const AArgs: array of string): Integer;
var
  I, J: Integer;
  Arg, Val, BinPath: string;
  Opts: TBuildPipelineOptions;
  ProgArgs: array of string;
  IsProgram: Boolean;
  Proc: TProcess;
begin
  Opts := Default(TBuildPipelineOptions);
  Opts.ForRun := True;
  ProgArgs := nil;

  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if Arg = '--' then
    begin
      SetLength(ProgArgs, High(AArgs) - I);
      for J := I + 1 to High(AArgs) do
        ProgArgs[J - I - 1] := AArgs[J];
      Break;
    end
    else if (Arg = '-h') or (Arg = '--help') or (Arg = 'help') then
    begin
      PrintRunHelp;
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
    else if Arg = '--trust' then
      Opts.Trust := True
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
    else if (Arg <> '') and (Arg[1] = '-') then
      raise ENikError.CreateFmt('Unknown option ''%s'' for ''nik run''. Arguments for the program go after ''--''. Run ''nik run --help''.', [Arg])
    else if Opts.Source = '' then
      Opts.Source := Arg
    else
      raise ENikError.CreateFmt('Unexpected argument ''%s'' for ''nik run''. Arguments for the program go after ''--''.', [Arg]);
    Inc(I);
  end;

  Result := RunBuildPipeline(Opts, BinPath, IsProgram);
  if Result <> 0 then
    Exit;
  if not IsProgram then
    raise ENikError.Create('Nothing to run: the artifact is a library, not a program.');
  if not FileExists(BinPath) then
    raise ENikError.CreateFmt('Built binary not found: %s', [BinPath]);

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := BinPath;
    for I := 0 to High(ProgArgs) do
      Proc.Parameters.Add(ProgArgs[I]);
    Proc.Options := [poWaitOnExit];
    Proc.Execute;
    Result := Proc.ExitStatus;
  finally
    Proc.Free;
  end;
end;

end.
