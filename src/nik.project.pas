unit nik.project;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, nik.types, nik.manifest.types, nik.compiler.types;

type
  TProjectTargetRole = (ptrMainArtifact, ptrTestRunner);

  TProjectTargetOptions = record
    ManifestOverride: string;
    ProfileName: string;
    Role: TProjectTargetRole;
    EntryOverride: string;
    OutputOverride: string;
    CacheSuffix: string;
    Clean: Boolean;
    CheckOnly: Boolean;
  end;

  TPreparedProjectTarget = record
    Options: TProjectTargetOptions;
    Manifest: TResolvedManifest;
    Sdk: TInstalledSdk;
    Compile: TPreparedCompile;
  end;

  TProjectCompileResult = record
    Manifest: TResolvedManifest;
    Sdk: TInstalledSdk;
    Compile: TCompileResult;
  end;

function SanitizeCacheKey(const ARaw: string): string;
function ResolveOutputBinaryPath(const AProjectDir, ARawOutput, ATargetOs: string;
  AArtifactKind: TCompileArtifactKind): string;

function BuildCompileSpecFromManifest(const AManifest: TResolvedManifest;
  const ASdk: TInstalledSdk; const AFpcCfgPath: string;
  AArtifactKind: TCompileArtifactKind; AClean: Boolean;
  const ACacheSuffix: string = ''): TCompileSpec;

function PrepareProjectTarget(const AOptions: TProjectTargetOptions): TPreparedProjectTarget;
function ExecuteProjectTarget(const APrepared: TPreparedProjectTarget): TProjectCompileResult;
function CompileProjectTarget(const AOptions: TProjectTargetOptions): TProjectCompileResult;

implementation

uses
  nik.platform, nik.paths, nik.sdk.config, nik.sdk.manager, nik.manifest.io, nik.manifest.resolve, nik.compiler;

function SanitizeCacheKey(const ARaw: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '';
  for I := 1 to Length(ARaw) do
  begin
    Ch := ARaw[I];
    if ((Ch >= 'A') and (Ch <= 'Z')) or
       ((Ch >= 'a') and (Ch <= 'z')) or
       ((Ch >= '0') and (Ch <= '9')) or
       (Ch = '-') or (Ch = '_') or (Ch = '.') then
      Result := Result + Ch
    else
      Result := Result + '_';
  end;
  if Result = '' then
    Result := 'default';
end;

procedure AppendUniquePath(var APaths: TStringArray; const APath: string);
var
  Clean: string;
  I, N: Integer;
begin
  Clean := ExcludeTrailingPathDelimiter(APath);
  if Clean = '' then
    Exit;
  for I := 0 to High(APaths) do
  begin
    {$IFDEF WINDOWS}
    if SameText(APaths[I], Clean) then
      Exit;
    {$ELSE}
    if APaths[I] = Clean then
      Exit;
    {$ENDIF}
  end;
  N := Length(APaths);
  SetLength(APaths, N + 1);
  APaths[N] := Clean;
end;

procedure ResolveDependenciesPaths(const AManifest: TResolvedManifest;
  const ATargetCpu, ATargetOs: string;
  var AUnitPaths, AIncludePaths, ALibPaths, AObjPaths: TStringArray);
var
  I, J: Integer;
  Dep: TDependencySpec;
  DepDir, DepManifestYaml, DepManifestYml, ChosenManifest: string;
  DepManifest: TParsedManifest;
  DepResolved: TResolvedManifest;
begin
  for I := 0 to High(AManifest.Dependencies) do
  begin
    Dep := AManifest.Dependencies[I];
    if Trim(Dep.Path) = '' then
      raise ENikError.CreateFmt(
        '%s:%d: Dependency ''%s'' uses a remote version/git source, which requires the upcoming ''nik install'' package manager. Use ''path: <dir>'' for local dependencies.',
        [AManifest.ManifestPath, Dep.DefinedLine, Dep.Name]);

    DepDir := ResolveRelativePath(AManifest.ProjectDir, Dep.Path);
    if not DirectoryExists(DepDir) then
      raise ENikError.CreateFmt(
        '%s:%d: Path for dependency ''%s'' does not exist: %s',
        [AManifest.ManifestPath, Dep.DefinedLine, Dep.Name, DepDir]);

    if (Length(Dep.UnitPaths) > 0) or (Length(Dep.IncludePaths) > 0) then
    begin
      for J := 0 to High(Dep.UnitPaths) do
        AppendUniquePath(AUnitPaths, ResolveRelativePath(DepDir, Dep.UnitPaths[J]));
      for J := 0 to High(Dep.IncludePaths) do
        AppendUniquePath(AIncludePaths, ResolveRelativePath(DepDir, Dep.IncludePaths[J]));
      Continue;
    end;

    DepManifestYaml := JoinPath(DepDir, 'nik.yaml');
    DepManifestYml := JoinPath(DepDir, 'nik.yml');
    ChosenManifest := '';
    if FileExists(DepManifestYaml) then
      ChosenManifest := DepManifestYaml
    else if FileExists(DepManifestYml) then
      ChosenManifest := DepManifestYml;

    if ChosenManifest <> '' then
    begin
      DepManifest := LoadManifestFile(ChosenManifest);
      DepResolved := ResolveManifestConfig(DepManifest, 'debug', ATargetCpu, ATargetOs, False, False);
      if (Length(DepResolved.UnitPaths) > 0) or (Length(DepResolved.IncludePaths) > 0) or
         (Length(DepResolved.LibraryPaths) > 0) or (Length(DepResolved.ObjectPaths) > 0) or
         (Length(DepResolved.ResourcePaths) > 0) then
      begin
        for J := 0 to High(DepResolved.UnitPaths) do
          AppendUniquePath(AUnitPaths, ResolveRelativePath(DepDir, DepResolved.UnitPaths[J]));
        for J := 0 to High(DepResolved.IncludePaths) do
          AppendUniquePath(AIncludePaths, ResolveRelativePath(DepDir, DepResolved.IncludePaths[J]));
        for J := 0 to High(DepResolved.LibraryPaths) do
          AppendUniquePath(ALibPaths, ResolveRelativePath(DepDir, DepResolved.LibraryPaths[J]));
        for J := 0 to High(DepResolved.ObjectPaths) do
          AppendUniquePath(AObjPaths, ResolveRelativePath(DepDir, DepResolved.ObjectPaths[J]));
        for J := 0 to High(DepResolved.ResourcePaths) do
        begin
          AppendUniquePath(AIncludePaths, ResolveRelativePath(DepDir, DepResolved.ResourcePaths[J]));
          AppendUniquePath(AObjPaths, ResolveRelativePath(DepDir, DepResolved.ResourcePaths[J]));
        end;
        Continue;
      end;
    end;

    // Raw Pascal directory (e.g. LazUtils): expose both .pas units and .inc files
    AppendUniquePath(AUnitPaths, DepDir);
    AppendUniquePath(AIncludePaths, DepDir);
  end;
end;

function EnsureLibPrefix(const ABaseName: string): string;
begin
  if (Length(ABaseName) >= 3) and (Copy(LowerCase(ABaseName), 1, 3) = 'lib') then
    Result := ABaseName
  else
    Result := 'lib' + ABaseName;
end;

function ResolveOutputBinaryPath(const AProjectDir, ARawOutput, ATargetOs: string;
  AArtifactKind: TCompileArtifactKind): string;
var
  Ext, DirPart, FilePart: string;
begin
  if (AArtifactKind = cakCheckOnly) and (Trim(ARawOutput) = '') then
    Exit('');

  Result := ResolveRelativePath(AProjectDir, ARawOutput);
  Ext := LowerCase(ExtractFileExt(Result));
  if Ext <> '' then
    Exit;

  case AArtifactKind of
    cakSharedLibrary:
      begin
        DirPart := ExtractFileDir(Result);
        FilePart := ExtractFileName(Result);
        if SameText(ATargetOs, 'win64') then
          Result := Result + '.dll'
        else if SameText(ATargetOs, 'darwin') then
          Result := JoinPath(DirPart, EnsureLibPrefix(FilePart) + '.dylib')
        else
          Result := JoinPath(DirPart, EnsureLibPrefix(FilePart) + '.so');
      end;
    cakExecutable, cakCheckOnly:
      begin
        if SameText(ATargetOs, 'win64') then
          Result := Result + '.exe';
      end;
  else
    raise ENikError.CreateFmt('Unsupported TCompileArtifactKind ordinal: %d', [Ord(AArtifactKind)]);
  end;
end;

function MapManifestSubsystem(ASub: TAppSubsystem): TCompileSubsystem;
begin
  case ASub of
    asConsole: Result := csConsole;
    asGui:     Result := csGui;
  else
    raise ENikError.CreateFmt('Unsupported TAppSubsystem ordinal: %d', [Ord(ASub)]);
  end;
end;

function MapManifestPicMode(APic: TPicMode): TCompilePicMode;
begin
  case APic of
    pmAuto: Result := cpmAuto;
    pmOn:   Result := cpmOn;
    pmOff:  Result := cpmOff;
  else
    raise ENikError.CreateFmt('Unsupported TPicMode ordinal: %d', [Ord(APic)]);
  end;
end;

function MapManifestWarnings(const AWarn: TWarningsConfig): TCompileWarnings;
begin
  Result := Default(TCompileWarnings);
  Result.AsErrors := AWarn.AsErrors;
  Result.HasHints := AWarn.HasHints;
  Result.Hints := AWarn.Hints;
  Result.Notes := AWarn.Notes;
  Result.Suppress := Copy(AWarn.Suppress);
end;

procedure SplitTripletSpec(const ATriplet: string; out ACpu, AOs: string);
var
  DashPos: Integer;
begin
  ACpu := GetHostCpu;
  AOs := GetHostOs;
  if (ATriplet = '') or SameText(ATriplet, 'native') then
    Exit;
  DashPos := Pos('-', ATriplet);
  if DashPos > 1 then
  begin
    ACpu := Copy(ATriplet, 1, DashPos - 1);
    AOs := Copy(ATriplet, DashPos + 1, MaxInt);
  end;
end;

function ResolveTargetArtifactKind(ARole: TProjectTargetRole; AManifestKind: TManifestKind;
  ACheckOnly: Boolean): TCompileArtifactKind;
begin
  if ACheckOnly then
    Exit(cakCheckOnly);

  case ARole of
    ptrMainArtifact:
      case AManifestKind of
        mkProgram: Result := cakExecutable;
        mkLibrary: Result := cakSharedLibrary;
        mkPackage:
          raise ENikError.Create('Cannot determine binary artifact kind for a source-only ''package'' manifest.');
      else
        raise ENikError.CreateFmt('Unsupported TManifestKind ordinal: %d', [Ord(AManifestKind)]);
      end;
    ptrTestRunner:
      Result := cakExecutable;
  else
    raise ENikError.CreateFmt('Unsupported TProjectTargetRole ordinal: %d', [Ord(ARole)]);
  end;
end;

function BuildCompileSpecFromManifest(const AManifest: TResolvedManifest;
  const ASdk: TInstalledSdk; const AFpcCfgPath: string;
  AArtifactKind: TCompileArtifactKind; AClean: Boolean;
  const ACacheSuffix: string): TCompileSpec;
var
  I: Integer;
  CacheKey, SuffixClean: string;
  EffUnitPaths, EffIncludePaths, EffLibPaths, EffObjPaths: TStringArray;
begin
  Result := Default(TCompileSpec);

  if Trim(ASdk.Manifest.Paths.PpcBinary) = '' then
    raise ENikError.CreateFmt('SDK ''%s'' does not declare paths.ppcBinary in sdk-manifest.json.',
      [ASdk.Manifest.SdkId]);

  Result.CompilerBinDir := JoinPath(ASdk.InstallPath, ASdk.Manifest.Paths.BinDir);
  Result.CompilerBinary := JoinPath(ASdk.InstallPath, ASdk.Manifest.Paths.PpcBinary);
  if not FileExists(Result.CompilerBinary) then
    raise ENikError.CreateFmt('Compiler backend binary missing in SDK ''%s'': %s',
      [ASdk.Manifest.SdkId, Result.CompilerBinary]);

  Result.FpcCfgPath := AFpcCfgPath;
  Result.TargetCpu := ASdk.Manifest.TargetCpu;
  Result.TargetOs := ASdk.Manifest.TargetOs;
  Result.WorkingDir := AManifest.ProjectDir;

  Result.ArtifactKind := AArtifactKind;
  Result.CleanRebuild := AClean;

  Result.EntryPath := ResolveRelativePath(AManifest.ProjectDir, AManifest.Entry);
  if not FileExists(Result.EntryPath) then
    raise ENikError.CreateFmt('%s: Entry source file not found: %s',
      [AManifest.ManifestPath, Result.EntryPath]);

  EffUnitPaths := nil;
  EffIncludePaths := nil;
  EffLibPaths := nil;
  EffObjPaths := nil;

  // Always include entry file's directory so sibling units next to entry are found naturally
  AppendUniquePath(EffUnitPaths, ExtractFileDir(Result.EntryPath));

  for I := 0 to High(AManifest.UnitPaths) do
    AppendUniquePath(EffUnitPaths, ResolveRelativePath(AManifest.ProjectDir, AManifest.UnitPaths[I]));
  for I := 0 to High(AManifest.IncludePaths) do
    AppendUniquePath(EffIncludePaths, ResolveRelativePath(AManifest.ProjectDir, AManifest.IncludePaths[I]));
  for I := 0 to High(AManifest.LibraryPaths) do
    AppendUniquePath(EffLibPaths, ResolveRelativePath(AManifest.ProjectDir, AManifest.LibraryPaths[I]));
  for I := 0 to High(AManifest.ObjectPaths) do
    AppendUniquePath(EffObjPaths, ResolveRelativePath(AManifest.ProjectDir, AManifest.ObjectPaths[I]));
  for I := 0 to High(AManifest.ResourcePaths) do
  begin
    AppendUniquePath(EffIncludePaths, ResolveRelativePath(AManifest.ProjectDir, AManifest.ResourcePaths[I]));
    AppendUniquePath(EffObjPaths, ResolveRelativePath(AManifest.ProjectDir, AManifest.ResourcePaths[I]));
  end;

  ResolveDependenciesPaths(AManifest, ASdk.Manifest.TargetCpu, ASdk.Manifest.TargetOs,
    EffUnitPaths, EffIncludePaths, EffLibPaths, EffObjPaths);

  Result.UnitPaths := EffUnitPaths;
  Result.IncludePaths := EffIncludePaths;
  Result.LibraryPaths := EffLibPaths;
  Result.ObjectPaths := EffObjPaths;

  Result.OutputBinaryPath := ResolveOutputBinaryPath(
    AManifest.ProjectDir, AManifest.Output, ASdk.Manifest.TargetOs, AArtifactKind);

  CacheKey := ASdk.Manifest.SdkId + '-' + AManifest.ProfileName;
  SuffixClean := Trim(ACacheSuffix);
  if SuffixClean <> '' then
    CacheKey := CacheKey + '-' + SuffixClean
  else if AManifest.ForTest then
    CacheKey := CacheKey + '-test';

  Result.UnitOutputDir := JoinPath(
    JoinPath(JoinPath(AManifest.ProjectDir, '.nik'), 'cache'),
    SanitizeCacheKey(CacheKey));

  // Dialect & syntax
  Result.Mode := AManifest.Mode;
  Result.LongStrings := AManifest.LongStrings;
  Result.HasCOperators := AManifest.HasCOperators;
  Result.COperators := AManifest.COperators;
  Result.ModeSwitches := Copy(AManifest.ModeSwitches);

  // Subsystem & codegen
  Result.HasSubsystem := AManifest.HasSubsystem;
  Result.Subsystem := MapManifestSubsystem(AManifest.Subsystem);
  Result.Pic := MapManifestPicMode(AManifest.Pic);
  Result.CpuType := AManifest.CpuType;
  Result.FpuType := AManifest.FpuType;
  Result.StackSize := AManifest.StackSize;

  // Conditional compilation
  Result.Defines := Copy(AManifest.Defines);
  Result.Undefines := Copy(AManifest.Undefines);

  // Debug info, assertions & checks
  Result.DebugInfo := AManifest.DebugInfo;
  Result.Heaptrc := AManifest.Heaptrc;
  Result.HasAssertions := AManifest.HasAssertions;
  Result.Assertions := AManifest.Assertions;
  Result.HasExplicitChecks := AManifest.HasExplicitChecks;
  Result.Checks := Copy(AManifest.Checks);

  // Warnings
  Result.Warnings := MapManifestWarnings(AManifest.Warnings);

  // Optimization & linking
  Result.HasOptimization := AManifest.HasOptimization;
  Result.Optimization := AManifest.Optimization;
  Result.HasSmartLink := AManifest.HasSmartLink;
  Result.SmartLink := AManifest.SmartLink;
  Result.HasStripSymbols := AManifest.HasStripSymbols;
  Result.StripSymbols := AManifest.StripSymbols;
  Result.LinkLibraries := Copy(AManifest.LinkLibraries);
  Result.LinkerArgs := Copy(AManifest.LinkerArgs);
  Result.ExtraArgs := Copy(AManifest.FpcArgs);
end;

function PrepareProjectTarget(const AOptions: TProjectTargetOptions): TPreparedProjectTarget;
var
  ManifestFile, EffFpcSpec, EffTargetSpec, PreCpu, PreOs, SdkBinDir, FpcCfgPath: string;
  ParsedManifest: TParsedManifest;
  ForTest, RequireManifestEntry: Boolean;
  ArtifactKind: TCompileArtifactKind;
  Spec: TCompileSpec;
begin
  Result := Default(TPreparedProjectTarget);
  Result.Options := AOptions;

  ForTest := (AOptions.Role = ptrTestRunner);
  RequireManifestEntry := (Trim(AOptions.EntryOverride) = '');

  // 1. Discover & parse nik.yaml
  ManifestFile := FindManifestFile(AOptions.ManifestOverride);
  ParsedManifest := LoadManifestFile(ManifestFile);

  ResolveEffectiveToolchain(ParsedManifest, AOptions.ProfileName, ForTest,
    EffFpcSpec, EffTargetSpec);

  // Pre-validate manifest resolution (catches missing entry / missing toolchain.fpc / unknown profile before SDK lookup)
  SplitTripletSpec(EffTargetSpec, PreCpu, PreOs);
  Result.Manifest := ResolveManifestConfig(ParsedManifest, AOptions.ProfileName,
    PreCpu, PreOs, ForTest, RequireManifestEntry);

  if (AOptions.Role = ptrMainArtifact) and (ParsedManifest.Kind = mkPackage) then
    raise ENikError.CreateFmt(
      '%s:%d: ''package'' defines a source unit package without a binary target (build a consuming ''program'' or ''library'' instead).',
      [ParsedManifest.ManifestPath, ParsedManifest.RootLine]);

  // 2. Resolve required SDK & ensure isolated fpc.cfg
  Result.Sdk := RequireInstalledSdkForTarget(Result.Manifest.FpcSpec, Result.Manifest.TargetSpec);
  SdkBinDir := JoinPath(Result.Sdk.InstallPath, Result.Sdk.Manifest.Paths.BinDir);
  FpcCfgPath := JoinPath(SdkBinDir, 'fpc.cfg');
  if not FileExists(FpcCfgPath) then
    FpcCfgPath := GenerateFpcCfgForSdk(Result.Sdk.InstallPath, Result.Sdk.Manifest);

  // 3. Re-resolve manifest against exact SDK target (CPU + OS)
  Result.Manifest := ResolveManifestConfig(ParsedManifest, AOptions.ProfileName,
    Result.Sdk.Manifest.TargetCpu, Result.Sdk.Manifest.TargetOs, ForTest, RequireManifestEntry);

  if Trim(AOptions.EntryOverride) <> '' then
    Result.Manifest.Entry := Trim(AOptions.EntryOverride);
  if Trim(AOptions.OutputOverride) <> '' then
    Result.Manifest.Output := Trim(AOptions.OutputOverride);

  // 4. Translate resolved manifest + SDK into neutral TCompileSpec & prepare compiler invocation
  ArtifactKind := ResolveTargetArtifactKind(AOptions.Role, Result.Manifest.Kind, AOptions.CheckOnly);
  Spec := BuildCompileSpecFromManifest(Result.Manifest, Result.Sdk, FpcCfgPath,
    ArtifactKind, AOptions.Clean, AOptions.CacheSuffix);

  Result.Compile := PrepareCompile(Spec);
end;

function ExecuteProjectTarget(const APrepared: TPreparedProjectTarget): TProjectCompileResult;
begin
  Result := Default(TProjectCompileResult);
  Result.Manifest := APrepared.Manifest;
  Result.Sdk := APrepared.Sdk;
  Result.Compile := ExecuteCompile(APrepared.Compile);
end;

function CompileProjectTarget(const AOptions: TProjectTargetOptions): TProjectCompileResult;
begin
  Result := ExecuteProjectTarget(PrepareProjectTarget(AOptions));
end;

end.
