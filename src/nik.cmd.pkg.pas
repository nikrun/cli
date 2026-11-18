unit nik.cmd.pkg;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

function ExecutePkgCommand(const AArgs: array of string): Integer;
procedure PrintPkgHelp;

implementation

uses
  fpjson,
  nik.types, nik.platform, nik.paths, nik.term,
  nik.manifest.types, nik.manifest.io, nik.manifest.resolve,
  nik.pkg.types, nik.pkg.semver, nik.pkg.lock, nik.pkg.fetch, nik.pkg.resolve;

procedure PrintPkgHelp;
begin
  WriteLn(StyleBold('Manage project package cache and nik.lock (dependencies live in nik.yaml)'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik pkg <SUBCOMMAND> [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('SUBCOMMANDS:'));
  WriteLn('  ' + PadRightStr('fetch', 14) + 'Download & verify all dependencies from nik.yaml and sync nik.lock');
  WriteLn('  ' + PadRightStr('update', 14) + 'Upgrade locked SemVer versions in nik.lock within nik.yaml ranges');
  WriteLn('  ' + PadRightStr('list', 14) + 'Display resolved direct and transitive dependencies');
  WriteLn('  ' + PadRightStr('info', 14) + 'Inspect available SemVer tags and HEAD commit of a Git repository URL');
  WriteLn('  ' + PadRightStr('help', 14) + 'Show help for pkg commands');
  WriteLn;
  WriteLn(StyleBold('EXAMPLES:'));
  WriteLn('  nik pkg fetch');
  WriteLn('  nik pkg fetch --locked');
  WriteLn('  nik pkg update');
  WriteLn('  nik pkg update lsp-protocol');
  WriteLn('  nik pkg list --json');
  WriteLn('  nik pkg info https://github.com/nikrun/cli');
end;

procedure PrintPkgFetchHelp;
begin
  WriteLn(StyleBold('Download and verify all project dependencies declared in nik.yaml'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik pkg fetch [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('  -m, --manifest <PATH>  Path to nik.yaml or project directory');
  WriteLn('      --locked           Require nik.lock to be in sync without modifying it');
  WriteLn('      --offline          Verify strictly against ~/.nikrun/cache/pkg without network');
  WriteLn('      --json             Output machine-readable JSON');
  WriteLn('  -h, --help             Show this help message');
end;

procedure PrintPkgUpdateHelp;
begin
  WriteLn(StyleBold('Upgrade locked SemVer versions in nik.lock within nik.yaml constraints'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik pkg update [<NAME>] [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('  -m, --manifest <PATH>  Path to nik.yaml or project directory');
  WriteLn('      --json             Output machine-readable JSON');
  WriteLn('  -h, --help             Show this help message');
end;

procedure PrintPkgListHelp;
begin
  WriteLn(StyleBold('List resolved direct and transitive dependencies'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik pkg list [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('  -p, --profile <NAME>   Resolve for named profile (default: debug)');
  WriteLn('      --test             Include test.dependencies overlay');
  WriteLn('      --offline          Resolve strictly from ~/.nikrun/cache/pkg without network');
  WriteLn('  -m, --manifest <PATH>  Path to nik.yaml or project directory');
  WriteLn('      --json             Output machine-readable JSON');
  WriteLn('  -h, --help             Show this help message');
end;

procedure PrintPkgInfoHelp;
begin
  WriteLn(StyleBold('Inspect SemVer tags and HEAD commit of a remote Git repository URL'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik pkg info <URL> [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('      --json             Output machine-readable JSON');
  WriteLn('  -h, --help             Show this help message');
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

function SourceKindToString(AKind: TDependencySourceKind): string;
begin
  case AKind of
    dskLocalPath:    Result := 'path';
    dskLocalArchive: Result := 'local-archive';
    dskGitRepo:      Result := 'git';
    dskArchiveUrl:   Result := 'archive';
  else
    raise ENikError.CreateFmt('Unsupported TDependencySourceKind ordinal: %d', [Ord(AKind)]);
  end;
end;

function BuildPackagesJsonArray(const APkgs: TResolvedPackageArray): TJSONArray;
var
  I: Integer;
  P: TResolvedPackage;
  Obj: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(APkgs) do
  begin
    P := APkgs[I];
    Obj := TJSONObject.Create;
    Obj.Add('id', P.Id);
    Obj.Add('name', P.Name);
    Obj.Add('kind', SourceKindToString(P.SourceKind));
    Obj.Add('direct', P.Direct);
    Obj.Add('overriddenLocally', P.OverriddenLocally);
    if P.Url <> '' then
      Obj.Add('url', P.Url)
    else
      Obj.Add('url', TJSONNull.Create);
    if P.Subpath <> '' then
      Obj.Add('subpath', P.Subpath)
    else
      Obj.Add('subpath', TJSONNull.Create);
    if P.Version <> '' then
      Obj.Add('version', P.Version)
    else
      Obj.Add('version', TJSONNull.Create);
    if P.Rev <> '' then
      Obj.Add('rev', P.Rev)
    else
      Obj.Add('rev', TJSONNull.Create);
    if P.IntegrityOrSha256 <> '' then
      Obj.Add('integrity', P.IntegrityOrSha256)
    else
      Obj.Add('integrity', TJSONNull.Create);
    Obj.Add('rootDir', P.RootDir);
    Result.Add(Obj);
  end;
end;

procedure EmitPkgErrorJson(const AMessage: string; AExitCode: Integer);
var
  Root: TJSONObject;
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
end;

procedure EmitResolutionJson(const AManifestPath, AProjectDir: string; const ARes: TPackageResolutionResult);
var
  Root: TJSONObject;
  LockPath: string;
begin
  LockPath := JoinPath(AProjectDir, NIK_LOCK_FILENAME);
  Root := TJSONObject.Create;
  try
    Root.Add('success', True);
    Root.Add('manifestPath', AManifestPath);
    if FileExists(LockPath) then
      Root.Add('lockPath', LockPath)
    else
      Root.Add('lockPath', TJSONNull.Create);
    Root.Add('lockUpdated', ARes.LockUpdated);
    Root.Add('packages', BuildPackagesJsonArray(ARes.Packages));
    WriteJson(Root);
  finally
    Root.Free;
  end;
end;

function FormatPkgSummaryTag(const APkg: TResolvedPackage): string;
begin
  case APkg.SourceKind of
    dskLocalPath:
      if APkg.OverriddenLocally then
        Result := 'local override -> ' + APkg.RootDir
      else
        Result := 'local -> ' + APkg.RootDir;
    dskLocalArchive:
      Result := 'local archive (' + Copy(APkg.IntegrityOrSha256, 1, 12) + ')';
    dskArchiveUrl:
      Result := 'archive (' + Copy(APkg.IntegrityOrSha256, 1, 12) + ')';
    dskGitRepo:
      if APkg.Version <> '' then
        Result := 'v' + APkg.Version + ' (' + Copy(APkg.Rev, 1, 8) + ')'
      else
        Result := '@' + Copy(APkg.Rev, 1, 8);
  else
    raise ENikError.CreateFmt('Unsupported TDependencySourceKind ordinal: %d', [Ord(APkg.SourceKind)]);
  end;
end;

function ManifestDeclaresDepNameOrId(const AParsed: TParsedManifest; const ATarget: string): Boolean;
  function OverlayHas(const AOv: TManifestOverlay): Boolean;
  var
    K: Integer;
    D: TDependencySpec;
  begin
    Result := False;
    if not AOv.HasDependencies then
      Exit;
    for K := 0 to High(AOv.Dependencies) do
    begin
      D := AOv.Dependencies[K];
      if SameText(D.Name, ATarget) or
         ((D.Url <> '') and SameText(D.Url, ATarget)) or
         SameText(BuildGitPkgId(D.Url, D.Subpath), ATarget) then
        Exit(True);
    end;
  end;
var
  I: Integer;
begin
  if OverlayHas(AParsed.Base) then
    Exit(True);
  if AParsed.HasTest and OverlayHas(AParsed.Test) then
    Exit(True);
  for I := 0 to High(AParsed.Targets) do
    if OverlayHas(AParsed.Targets[I].Overlay) then
      Exit(True);
  for I := 0 to High(AParsed.Profiles) do
    if OverlayHas(AParsed.Profiles[I].Overlay) then
      Exit(True);
  Result := False;
end;

function RunPkgFetch(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val, ManifestOverride, ManifestPath: string;
  FlagJson: Boolean;
  Opts: TPackageResolveOptions;
  Parsed: TParsedManifest;
  Res: TPackageResolutionResult;
begin
  ManifestOverride := '';
  FlagJson := False;
  Opts := Default(TPackageResolveOptions);
  Opts.AllowLockWrite := True;

  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') or (Arg = 'help') then
    begin
      PrintPkgFetchHelp;
      Exit(0);
    end
    else if (Arg = '-m') or (Arg = '--manifest') then
      ManifestOverride := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--manifest', Val) then
      ManifestOverride := Val
    else if Arg = '--locked' then
      Opts.Locked := True
    else if Arg = '--offline' then
      Opts.Offline := True
    else if Arg = '--json' then
      FlagJson := True
    else
      raise ENikError.CreateFmt('Unknown option ''%s'' for ''nik pkg fetch''. Run ''nik pkg fetch --help''.', [Arg]);
    Inc(I);
  end;

  if Opts.Locked or Opts.Offline then
    Opts.AllowLockWrite := False;

  try
    ManifestPath := FindManifestFile(ManifestOverride);
    Parsed := LoadManifestFile(ManifestPath);
    Res := FetchAllManifestPackages(Parsed, GetHostCpu, GetHostOs, Opts);
  except
    on E: ENikError do
    begin
      if FlagJson then
      begin
        EmitPkgErrorJson(E.Message, E.ExitCode);
        Exit(E.ExitCode);
      end;
      raise;
    end;
  end;

  if FlagJson then
  begin
    EmitResolutionJson(ManifestPath, Parsed.ProjectDir, Res);
    Exit(0);
  end;

  if Length(Res.Packages) = 0 then
    WriteSuccess('No dependencies declared in nik.yaml.')
  else
  begin
    for I := 0 to High(Res.Packages) do
      WriteLn('  ' + StyleBold(PadRightStr(Res.Packages[I].Name, 22)) + '  ' +
              StyleCyan(FormatPkgSummaryTag(Res.Packages[I])));
    if Res.LockUpdated then
      WriteSuccess(Format('Fetched %d package(s) and updated nik.lock.', [Length(Res.Packages)]))
    else
      WriteSuccess(Format('Verified %d package(s) up to date.', [Length(Res.Packages)]));
  end;
  Result := 0;
end;

function RunPkgUpdate(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val, ManifestOverride, ManifestPath, TargetPkg: string;
  FlagJson: Boolean;
  Opts: TPackageResolveOptions;
  Parsed: TParsedManifest;
  Res: TPackageResolutionResult;
begin
  ManifestOverride := '';
  TargetPkg := '';
  FlagJson := False;

  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') or (Arg = 'help') then
    begin
      PrintPkgUpdateHelp;
      Exit(0);
    end
    else if (Arg = '-m') or (Arg = '--manifest') then
      ManifestOverride := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--manifest', Val) then
      ManifestOverride := Val
    else if Arg = '--json' then
      FlagJson := True
    else if (Length(Arg) > 0) and (Arg[1] = '-') then
      raise ENikError.CreateFmt('Unknown option ''%s'' for ''nik pkg update''. Run ''nik pkg update --help''.', [Arg])
    else if TargetPkg = '' then
      TargetPkg := Trim(Arg)
    else
      raise ENikError.CreateFmt('Unexpected argument ''%s''. Specify at most one package name.', [Arg]);
    Inc(I);
  end;

  Opts := Default(TPackageResolveOptions);
  Opts.AllowLockWrite := True;
  Opts.UpdateAll := (TargetPkg = '');
  Opts.UpdateTargetName := TargetPkg;

  try
    ManifestPath := FindManifestFile(ManifestOverride);
    Parsed := LoadManifestFile(ManifestPath);
    if (TargetPkg <> '') and (not ManifestDeclaresDepNameOrId(Parsed, TargetPkg)) then
      raise ENikError.CreateFmt('Dependency ''%s'' is not declared in %s.', [TargetPkg, ManifestPath]);

    Res := FetchAllManifestPackages(Parsed, GetHostCpu, GetHostOs, Opts);
  except
    on E: ENikError do
    begin
      if FlagJson then
      begin
        EmitPkgErrorJson(E.Message, E.ExitCode);
        Exit(E.ExitCode);
      end;
      raise;
    end;
  end;

  if FlagJson then
  begin
    EmitResolutionJson(ManifestPath, Parsed.ProjectDir, Res);
    Exit(0);
  end;

  if Length(Res.Packages) = 0 then
    WriteInfo('No dependencies declared in nik.yaml.')
  else if Res.LockUpdated then
    WriteSuccess(Format('Updated nik.lock (%d package(s) resolved).', [Length(Res.Packages)]))
  else
    WriteSuccess('All locked packages already match the latest compatible versions.');
  Result := 0;
end;

function RunPkgList(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val, ManifestOverride, ProfileName, ManifestPath, ScopeTag: string;
  FlagJson, FlagTest, FlagOffline: Boolean;
  Parsed: TParsedManifest;
  ResolvedCfg: TResolvedManifest;
  Opts: TPackageResolveOptions;
  Res: TPackageResolutionResult;
begin
  ManifestOverride := '';
  ProfileName := 'debug';
  FlagJson := False;
  FlagTest := False;
  FlagOffline := False;

  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') or (Arg = 'help') then
    begin
      PrintPkgListHelp;
      Exit(0);
    end
    else if (Arg = '-m') or (Arg = '--manifest') then
      ManifestOverride := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--manifest', Val) then
      ManifestOverride := Val
    else if (Arg = '-p') or (Arg = '--profile') then
      ProfileName := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--profile', Val) then
      ProfileName := Val
    else if Arg = '--test' then
      FlagTest := True
    else if Arg = '--offline' then
      FlagOffline := True
    else if Arg = '--json' then
      FlagJson := True
    else
      raise ENikError.CreateFmt('Unknown option ''%s'' for ''nik pkg list''. Run ''nik pkg list --help''.', [Arg]);
    Inc(I);
  end;

  Opts := Default(TPackageResolveOptions);
  Opts.Offline := FlagOffline;
  Opts.AllowLockWrite := False;
  Opts.IncludeTestDeps := FlagTest;

  try
    ManifestPath := FindManifestFile(ManifestOverride);
    Parsed := LoadManifestFile(ManifestPath);
    ResolvedCfg := ResolveManifestConfig(Parsed, ProfileName, GetHostCpu, GetHostOs, FlagTest, False);
    Res := ResolveProjectPackages(Parsed, ResolvedCfg, GetHostCpu, GetHostOs, Opts);
  except
    on E: ENikError do
    begin
      if FlagJson then
      begin
        EmitPkgErrorJson(E.Message, E.ExitCode);
        Exit(E.ExitCode);
      end;
      raise;
    end;
  end;

  if FlagJson then
  begin
    EmitResolutionJson(ManifestPath, Parsed.ProjectDir, Res);
    Exit(0);
  end;

  if Length(Res.Packages) = 0 then
  begin
    WriteInfo('No dependencies configured for this target/profile.');
    Exit(0);
  end;

  for I := 0 to High(Res.Packages) do
  begin
    if Res.Packages[I].Direct then
      ScopeTag := 'direct'
    else
      ScopeTag := 'transitive';
    WriteLn('  ' + StyleBold(PadRightStr(Res.Packages[I].Name, 22)) + '  ' +
            StyleCyan(PadRightStr(FormatPkgSummaryTag(Res.Packages[I]), 28)) + '  ' +
            StyleDim('[' + ScopeTag + '] ' + Res.Packages[I].Id));
  end;
  Result := 0;
end;

function RunPkgInfo(const AArgs: array of string): Integer;
var
  I, J, Limit: Integer;
  Arg, RawUrl, NormUrl, ErrMsg, SuggestedName, SuggestedYaml: string;
  FlagJson: Boolean;
  Info: TGitRepoInspection;
  TagIndices: array of Integer;
  TmpIdx: Integer;
  Root, TagObj, BranchObj: TJSONObject;
  TagsArr, BranchesArr: TJSONArray;
begin
  RawUrl := '';
  FlagJson := False;

  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') or (Arg = 'help') then
    begin
      PrintPkgInfoHelp;
      Exit(0);
    end
    else if Arg = '--json' then
      FlagJson := True
    else if (Length(Arg) > 0) and (Arg[1] = '-') then
      raise ENikError.CreateFmt('Unknown option ''%s'' for ''nik pkg info''. Run ''nik pkg info --help''.', [Arg])
    else if RawUrl = '' then
      RawUrl := Trim(Arg)
    else
      raise ENikError.CreateFmt('Unexpected argument ''%s''. Usage: nik pkg info <URL>', [Arg]);
    Inc(I);
  end;

  if RawUrl = '' then
    raise ENikError.Create('Missing repository URL. Usage: nik pkg info <URL>');

  try
    if not NormalizeRemoteUrlBase(RawUrl, True, NormUrl, ErrMsg) then
      raise ENikError.Create(ErrMsg);
    Info := InspectGitRepository(NormUrl);
  except
    on E: ENikError do
    begin
      if FlagJson then
      begin
        EmitPkgErrorJson(E.Message, E.ExitCode);
        Exit(E.ExitCode);
      end;
      raise;
    end;
  end;

  TagIndices := nil;
  for I := 0 to High(Info.Refs) do
    if Info.Refs[I].IsTag and Info.Refs[I].HasSemVer then
    begin
      SetLength(TagIndices, Length(TagIndices) + 1);
      TagIndices[High(TagIndices)] := I;
    end;

  // Sort SemVer tags descending (newest first)
  for I := 0 to High(TagIndices) - 1 do
    for J := I + 1 to High(TagIndices) do
      if CompareSemVer(Info.Refs[TagIndices[J]].SemVer, Info.Refs[TagIndices[I]].SemVer) > 0 then
      begin
        TmpIdx := TagIndices[I];
        TagIndices[I] := TagIndices[J];
        TagIndices[J] := TmpIdx;
      end;

  SuggestedName := DeriveSuggestedPkgName(Info.NormalizedUrl, '');
  if Info.HasLatestSemVer then
    SuggestedYaml := Format('%s: %s@^%s', [SuggestedName, Info.NormalizedUrl, FormatSemVer(Info.LatestSemVer)])
  else if Info.HeadCommit <> '' then
    SuggestedYaml := Format('%s: %s@%s', [SuggestedName, Info.NormalizedUrl, Copy(Info.HeadCommit, 1, 8)])
  else
    SuggestedYaml := '';

  if FlagJson then
  begin
    Root := TJSONObject.Create;
    try
      Root.Add('success', True);
      Root.Add('url', Info.NormalizedUrl);
      if Info.DefaultBranch <> '' then
        Root.Add('defaultBranch', Info.DefaultBranch)
      else
        Root.Add('defaultBranch', TJSONNull.Create);
      if Info.HeadCommit <> '' then
        Root.Add('headCommit', Info.HeadCommit)
      else
        Root.Add('headCommit', TJSONNull.Create);
      if Info.HasLatestSemVer then
        Root.Add('latestVersion', FormatSemVer(Info.LatestSemVer))
      else
        Root.Add('latestVersion', TJSONNull.Create);
      if SuggestedYaml <> '' then
        Root.Add('suggestedYaml', SuggestedYaml)
      else
        Root.Add('suggestedYaml', TJSONNull.Create);

      TagsArr := TJSONArray.Create;
      for I := 0 to High(TagIndices) do
      begin
        TagObj := TJSONObject.Create;
        TagObj.Add('tag', Info.Refs[TagIndices[I]].ShortName);
        TagObj.Add('version', FormatSemVer(Info.Refs[TagIndices[I]].SemVer));
        TagObj.Add('rev', Info.Refs[TagIndices[I]].CommitSha);
        TagsArr.Add(TagObj);
      end;
      Root.Add('tags', TagsArr);

      BranchesArr := TJSONArray.Create;
      for I := 0 to High(Info.Refs) do
        if Info.Refs[I].IsBranch then
        begin
          BranchObj := TJSONObject.Create;
          BranchObj.Add('branch', Info.Refs[I].ShortName);
          BranchObj.Add('rev', Info.Refs[I].CommitSha);
          BranchesArr.Add(BranchObj);
        end;
      Root.Add('branches', BranchesArr);

      WriteJson(Root);
    finally
      Root.Free;
    end;
    Exit(0);
  end;

  WriteLn(StyleBold('Repository : ') + Info.NormalizedUrl);
  if Info.DefaultBranch <> '' then
    WriteLn(StyleBold('Branch     : ') + Info.DefaultBranch);
  if Info.HeadCommit <> '' then
    WriteLn(StyleBold('HEAD       : ') + Info.HeadCommit);
  if Info.HasLatestSemVer then
    WriteLn(StyleBold('Latest     : ') + StyleGreen(FormatSemVer(Info.LatestSemVer)) +
            StyleDim(' (' + Copy(Info.LatestSemVerCommit, 1, 8) + ')'));

  if Length(TagIndices) > 0 then
  begin
    WriteLn;
    WriteLn(StyleBold('SEMVER TAGS:'));
    Limit := Length(TagIndices);
    if Limit > 15 then
      Limit := 15;
    for I := 0 to Limit - 1 do
      WriteLn('  ' + PadRightStr(FormatSemVer(Info.Refs[TagIndices[I]].SemVer), 30) + '  ' +
              StyleDim(Copy(Info.Refs[TagIndices[I]].CommitSha, 1, 12) + '  (' + Info.Refs[TagIndices[I]].ShortName + ')'));
    if Length(TagIndices) > Limit then
      WriteLn(StyleDim(Format('  ... (%d more tags)', [Length(TagIndices) - Limit])));
  end
  else
  begin
    WriteLn;
    WriteLn(StyleYellow('No SemVer tags found; pin a commit hash in nik.yaml.'));
  end;

  if SuggestedYaml <> '' then
  begin
    WriteLn;
    WriteLn(StyleBold('NIK.YAML SNIPPET:'));
    WriteLn('  ' + StyleCyan(SuggestedYaml));
  end;
  Result := 0;
end;

function ExecutePkgCommand(const AArgs: array of string): Integer;
var
  SubCmd: string;
  SubArgs: array of string;
  I: Integer;
begin
  if Length(AArgs) = 0 then
  begin
    PrintPkgHelp;
    Exit(0);
  end;

  SubCmd := LowerCase(Trim(AArgs[0]));
  if (SubCmd = 'help') or (SubCmd = '-h') or (SubCmd = '--help') then
  begin
    if Length(AArgs) >= 2 then
    begin
      if SameText(AArgs[1], 'fetch') then
        PrintPkgFetchHelp
      else if SameText(AArgs[1], 'update') then
        PrintPkgUpdateHelp
      else if SameText(AArgs[1], 'list') then
        PrintPkgListHelp
      else if SameText(AArgs[1], 'info') then
        PrintPkgInfoHelp
      else
        PrintPkgHelp;
    end
    else
      PrintPkgHelp;
    Exit(0);
  end;

  SubArgs := nil;
  if Length(AArgs) > 1 then
  begin
    SetLength(SubArgs, Length(AArgs) - 1);
    for I := 1 to High(AArgs) do
      SubArgs[I - 1] := AArgs[I];
  end;

  if SubCmd = 'fetch' then
    Result := RunPkgFetch(SubArgs)
  else if SubCmd = 'update' then
    Result := RunPkgUpdate(SubArgs)
  else if SubCmd = 'list' then
    Result := RunPkgList(SubArgs)
  else if SubCmd = 'info' then
    Result := RunPkgInfo(SubArgs)
  else
    raise ENikError.CreateFmt(
      'Unknown ''nik pkg'' subcommand ''%s''. Expected fetch, update, list, or info (dependencies are declared in nik.yaml).',
      [AArgs[0]]);
end;

end.
