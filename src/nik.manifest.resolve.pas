unit nik.manifest.resolve;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, nik.manifest.types;

procedure ResolveEffectiveToolchain(const AManifest: TParsedManifest;
  const AProfileName: string; AForTest: Boolean;
  out AFpcSpec, ATargetSpec: string);

function ResolveManifestConfig(const AManifest: TParsedManifest;
  const AProfileName, ATargetCpu, ATargetOs: string;
  AForTest: Boolean = False;
  ARequireEntry: Boolean = True;
  ARequireToolchain: Boolean = True): TResolvedManifest;

function ResolveManifestProfile(const AManifest: TParsedManifest;
  const AProfileName: string;
  const ATargetCpu: string = '';
  const ATargetOs: string = ''): TResolvedManifest;

implementation

uses
  nik.types, nik.paths;

procedure AppendUniqueString(var ATarget: TStringArray; const AValue: string; ACaseInsensitive: Boolean);
var
  I, N: Integer;
begin
  for I := 0 to High(ATarget) do
  begin
    if ACaseInsensitive then
    begin
      if SameText(ATarget[I], AValue) then
        Exit;
    end
    else if ATarget[I] = AValue then
      Exit;
  end;
  N := Length(ATarget);
  SetLength(ATarget, N + 1);
  ATarget[N] := AValue;
end;

procedure MergeAdditiveList(var ATarget: TStringArray; const ASource: TStringArray;
  ACaseInsensitive: Boolean);
var
  I, StartIdx: Integer;
begin
  StartIdx := 0;
  if (Length(ASource) > 0) and SameText(ASource[0], '$reset') then
  begin
    ATarget := nil;
    StartIdx := 1;
  end;
  for I := StartIdx to High(ASource) do
    AppendUniqueString(ATarget, ASource[I], ACaseInsensitive);
end;

procedure MergeDependencies(var ATarget: TDependencySpecArray; const ASource: TDependencySpecArray);
var
  I, J, N: Integer;
  Replaced: Boolean;
begin
  for I := 0 to High(ASource) do
  begin
    Replaced := False;
    for J := 0 to High(ATarget) do
      if SameText(ATarget[J].Name, ASource[I].Name) then
      begin
        ATarget[J] := ASource[I];
        Replaced := True;
        Break;
      end;
    if not Replaced then
    begin
      N := Length(ATarget);
      SetLength(ATarget, N + 1);
      ATarget[N] := ASource[I];
    end;
  end;
end;

procedure ApplyOptStr(AHas: Boolean; const ASrc: string; var ADst: string);
begin
  if AHas then
    ADst := ASrc;
end;

procedure ApplyOptBool(AHas: Boolean; ASrc: Boolean; var ADst: Boolean);
begin
  if AHas then
    ADst := ASrc;
end;

procedure ApplyOptTrackedBool(AHas: Boolean; ASrc: Boolean; var ADstHas, ADst: Boolean);
begin
  if AHas then
  begin
    ADstHas := True;
    ADst := ASrc;
  end;
end;

procedure ApplyOptList(AHas: Boolean; const ASrc: TStringArray;
  var ADst: TStringArray; ACaseInsensitive: Boolean);
begin
  if AHas then
    MergeAdditiveList(ADst, ASrc, ACaseInsensitive);
end;

procedure ApplyOverlayToManifest(var AConfig: TResolvedManifest; const AOverlay: TManifestOverlay);
const
  PATH_CI = {$IFDEF WINDOWS}True{$ELSE}False{$ENDIF};
begin
  ApplyOptStr(AOverlay.HasName, AOverlay.Name, AConfig.ProjectName);
  ApplyOptStr(AOverlay.HasVersion, AOverlay.Version, AConfig.ProjectVersion);
  ApplyOptStr(AOverlay.HasDescription, AOverlay.Description, AConfig.Description);
  ApplyOptStr(AOverlay.HasLicense, AOverlay.License, AConfig.License);
  ApplyOptStr(AOverlay.HasRepository, AOverlay.Repository, AConfig.Repository);
  ApplyOptList(AOverlay.HasAuthors, AOverlay.Authors, AConfig.Authors, False);
  ApplyOptStr(AOverlay.HasEntry, AOverlay.Entry, AConfig.Entry);
  ApplyOptStr(AOverlay.HasOutput, AOverlay.Output, AConfig.Output);

  ApplyOptStr(AOverlay.Toolchain.HasFpcVersion, AOverlay.Toolchain.FpcVersion, AConfig.FpcSpec);
  ApplyOptStr(AOverlay.Toolchain.HasTarget, AOverlay.Toolchain.Target, AConfig.TargetSpec);

  ApplyOptStr(AOverlay.Build.HasMode, AOverlay.Build.Mode, AConfig.Mode);
  ApplyOptBool(AOverlay.Build.HasLongStrings, AOverlay.Build.LongStrings, AConfig.LongStrings);
  ApplyOptTrackedBool(AOverlay.Build.HasCOperators, AOverlay.Build.COperators,
    AConfig.HasCOperators, AConfig.COperators);
  ApplyOptList(AOverlay.Build.HasModeSwitches, AOverlay.Build.ModeSwitches, AConfig.ModeSwitches, True);

  if AOverlay.Build.HasSubsystem then
  begin
    AConfig.HasSubsystem := True;
    AConfig.Subsystem := AOverlay.Build.Subsystem;
  end;
  if AOverlay.Build.HasPic then
    AConfig.Pic := AOverlay.Build.Pic;
  ApplyOptStr(AOverlay.Build.HasCpuType, AOverlay.Build.CpuType, AConfig.CpuType);
  ApplyOptStr(AOverlay.Build.HasFpuType, AOverlay.Build.FpuType, AConfig.FpuType);
  if AOverlay.Build.HasStackSize then
    AConfig.StackSize := AOverlay.Build.StackSize;

  ApplyOptList(AOverlay.Build.HasUnitPaths, AOverlay.Build.UnitPaths, AConfig.UnitPaths, PATH_CI);
  ApplyOptList(AOverlay.Build.HasIncludePaths, AOverlay.Build.IncludePaths, AConfig.IncludePaths, PATH_CI);
  ApplyOptList(AOverlay.Build.HasLibraryPaths, AOverlay.Build.LibraryPaths, AConfig.LibraryPaths, PATH_CI);
  ApplyOptList(AOverlay.Build.HasObjectPaths, AOverlay.Build.ObjectPaths, AConfig.ObjectPaths, PATH_CI);
  ApplyOptList(AOverlay.Build.HasResourcePaths, AOverlay.Build.ResourcePaths, AConfig.ResourcePaths, PATH_CI);

  ApplyOptList(AOverlay.Build.HasDefines, AOverlay.Build.Defines, AConfig.Defines, True);
  ApplyOptList(AOverlay.Build.HasUndefines, AOverlay.Build.Undefines, AConfig.Undefines, True);

  ApplyOptStr(AOverlay.Build.HasDebugInfo, AOverlay.Build.DebugInfo, AConfig.DebugInfo);
  ApplyOptBool(AOverlay.Build.HasHeaptrc, AOverlay.Build.Heaptrc, AConfig.Heaptrc);
  ApplyOptTrackedBool(AOverlay.Build.HasAssertions, AOverlay.Build.Assertions,
    AConfig.HasAssertions, AConfig.Assertions);
  if AOverlay.Build.HasChecks then
  begin
    AConfig.HasExplicitChecks := True;
    AConfig.Checks := nil;
    MergeAdditiveList(AConfig.Checks, AOverlay.Build.Checks, True);
  end;

  ApplyOptBool(AOverlay.Build.Warnings.HasAsErrors, AOverlay.Build.Warnings.AsErrors, AConfig.Warnings.AsErrors);
  ApplyOptTrackedBool(AOverlay.Build.Warnings.HasHints, AOverlay.Build.Warnings.Hints,
    AConfig.Warnings.HasHints, AConfig.Warnings.Hints);
  ApplyOptBool(AOverlay.Build.Warnings.HasNotes, AOverlay.Build.Warnings.Notes, AConfig.Warnings.Notes);
  ApplyOptList(AOverlay.Build.Warnings.HasSuppress, AOverlay.Build.Warnings.Suppress,
    AConfig.Warnings.Suppress, True);

  if AOverlay.Build.HasOptimization then
  begin
    AConfig.HasOptimization := True;
    AConfig.Optimization := AOverlay.Build.Optimization;
  end;
  ApplyOptTrackedBool(AOverlay.Build.HasSmartLink, AOverlay.Build.SmartLink,
    AConfig.HasSmartLink, AConfig.SmartLink);
  ApplyOptTrackedBool(AOverlay.Build.HasStripSymbols, AOverlay.Build.StripSymbols,
    AConfig.HasStripSymbols, AConfig.StripSymbols);
  ApplyOptList(AOverlay.Build.HasLinkLibraries, AOverlay.Build.LinkLibraries, AConfig.LinkLibraries, False);
  ApplyOptList(AOverlay.Build.HasLinkerArgs, AOverlay.Build.LinkerArgs, AConfig.LinkerArgs, False);
  ApplyOptList(AOverlay.Build.HasFpcArgs, AOverlay.Build.FpcArgs, AConfig.FpcArgs, False);

  if AOverlay.HasDependencies then
    MergeDependencies(AConfig.Dependencies, AOverlay.Dependencies);
end;

function FindProfileOverlayIndex(const AManifest: TParsedManifest;
  const AProfileName: string; out AResolvedProfileName: string): Integer;
var
  EffProfile, AvailList: string;
  I: Integer;
begin
  EffProfile := Trim(AProfileName);
  if EffProfile = '' then
    EffProfile := 'debug';
  AResolvedProfileName := EffProfile;

  for I := 0 to High(AManifest.Profiles) do
    if AManifest.Profiles[I].Name = EffProfile then
      Exit(I);

  for I := 0 to High(AManifest.Profiles) do
    if SameText(AManifest.Profiles[I].Name, EffProfile) then
    begin
      AResolvedProfileName := AManifest.Profiles[I].Name;
      Exit(I);
    end;

  if (not SameText(EffProfile, 'debug')) and (not SameText(EffProfile, 'release')) then
  begin
    AvailList := 'debug, release';
    for I := 0 to High(AManifest.Profiles) do
      if (not SameText(AManifest.Profiles[I].Name, 'debug')) and
         (not SameText(AManifest.Profiles[I].Name, 'release')) then
        AvailList := AvailList + ', ' + AManifest.Profiles[I].Name;
    RaiseManifestError(AManifest.ManifestPath, AManifest.RootLine,
      Format('Profile ''%s'' is not defined in ''%s.profiles'' (available: %s).',
        [EffProfile, ManifestKindToString(AManifest.Kind), AvailList]));
  end;

  Result := -1;
end;

procedure ApplyNamedTargetIfPresent(var AConfig: TResolvedManifest;
  const ATargets: TNamedOverlayArray; const ASelector: string);
var
  I: Integer;
begin
  if ASelector = '' then
    Exit;
  for I := 0 to High(ATargets) do
    if SameText(ATargets[I].Name, ASelector) then
      ApplyOverlayToManifest(AConfig, ATargets[I].Overlay);
end;

procedure ApplyMatchingTargetOverlays(var AConfig: TResolvedManifest;
  const ATargets: TNamedOverlayArray; const ATargetCpu, ATargetOs: string);
var
  CpuLower, OsLower: string;
begin
  if Length(ATargets) = 0 then
    Exit;

  CpuLower := LowerCase(Trim(ATargetCpu));
  OsLower := LowerCase(Trim(ATargetOs));

  // 1. OS family
  if (OsLower = 'linux') or (OsLower = 'darwin') then
    ApplyNamedTargetIfPresent(AConfig, ATargets, 'unix');

  // 2. OS name & friendly aliases
  if OsLower = 'win64' then
  begin
    ApplyNamedTargetIfPresent(AConfig, ATargets, 'windows');
    ApplyNamedTargetIfPresent(AConfig, ATargets, 'win64');
  end
  else if OsLower = 'linux' then
    ApplyNamedTargetIfPresent(AConfig, ATargets, 'linux')
  else if OsLower = 'darwin' then
  begin
    ApplyNamedTargetIfPresent(AConfig, ATargets, 'macos');
    ApplyNamedTargetIfPresent(AConfig, ATargets, 'darwin');
  end;

  // 3. CPU architecture
  if CpuLower <> '' then
    ApplyNamedTargetIfPresent(AConfig, ATargets, CpuLower);

  // 4. Exact <cpu>-<os> triplet
  if (CpuLower <> '') and (OsLower <> '') then
    ApplyNamedTargetIfPresent(AConfig, ATargets, CpuLower + '-' + OsLower);
end;

procedure ResolveEffectiveToolchain(const AManifest: TParsedManifest;
  const AProfileName: string; AForTest: Boolean;
  out AFpcSpec, ATargetSpec: string);
var
  ProfileIdx: Integer;
  ResolvedProfile: string;
begin
  AFpcSpec := '';
  ATargetSpec := 'native';
  ProfileIdx := FindProfileOverlayIndex(AManifest, AProfileName, ResolvedProfile);

  ApplyOptStr(AManifest.Base.Toolchain.HasFpcVersion, AManifest.Base.Toolchain.FpcVersion, AFpcSpec);
  ApplyOptStr(AManifest.Base.Toolchain.HasTarget, AManifest.Base.Toolchain.Target, ATargetSpec);

  if AForTest and AManifest.HasTest then
  begin
    ApplyOptStr(AManifest.Test.Toolchain.HasFpcVersion, AManifest.Test.Toolchain.FpcVersion, AFpcSpec);
    ApplyOptStr(AManifest.Test.Toolchain.HasTarget, AManifest.Test.Toolchain.Target, ATargetSpec);
  end;

  if ProfileIdx >= 0 then
  begin
    ApplyOptStr(AManifest.Profiles[ProfileIdx].Overlay.Toolchain.HasFpcVersion,
      AManifest.Profiles[ProfileIdx].Overlay.Toolchain.FpcVersion, AFpcSpec);
    ApplyOptStr(AManifest.Profiles[ProfileIdx].Overlay.Toolchain.HasTarget,
      AManifest.Profiles[ProfileIdx].Overlay.Toolchain.Target, ATargetSpec);
  end;
end;

function ResolveManifestConfig(const AManifest: TParsedManifest;
  const AProfileName, ATargetCpu, ATargetOs: string;
  AForTest, ARequireEntry, ARequireToolchain: Boolean): TResolvedManifest;
var
  ProfileIdx: Integer;
  EffProfile: string;
begin
  Result := Default(TResolvedManifest);
  Result.ManifestPath := AManifest.ManifestPath;
  Result.ProjectDir := AManifest.ProjectDir;
  Result.Kind := AManifest.Kind;
  Result.ForTest := AForTest;

  ProfileIdx := FindProfileOverlayIndex(AManifest, AProfileName, EffProfile);
  Result.ProfileName := EffProfile;

  // 1. Sensible baseline defaults
  Result.ProjectName := ExtractFileName(ExcludeTrailingPathDelimiter(AManifest.ProjectDir));
  Result.ProjectVersion := '0.1.0';
  Result.TargetSpec := 'native';
  Result.Mode := 'objfpc';
  Result.LongStrings := True;
  Result.Subsystem := asConsole;
  Result.Pic := pmAuto;
  Result.Warnings.Notes := True;
  Result.Warnings.Hints := False;
  Result.Warnings.AsErrors := False;

  if SameText(EffProfile, 'debug') then
  begin
    AppendUniqueString(Result.Defines, 'DEBUG', True);
    Result.DebugInfo := 'dwarf2';
    Result.HasAssertions := True;
    Result.Assertions := True;
    Result.HasExplicitChecks := True;
    AppendUniqueString(Result.Checks, 'range', True);
    AppendUniqueString(Result.Checks, 'overflow', True);
    AppendUniqueString(Result.Checks, 'io', True);
  end
  else if SameText(EffProfile, 'release') then
  begin
    AppendUniqueString(Result.Defines, 'RELEASE', True);
    Result.DebugInfo := 'none';
    Result.HasAssertions := True;
    Result.Assertions := False;
    Result.HasOptimization := True;
    Result.Optimization := 2;
    Result.HasSmartLink := True;
    Result.SmartLink := True;
    Result.HasStripSymbols := True;
    Result.StripSymbols := True;
  end;

  if AForTest then
  begin
    Result.Heaptrc := True;
    Result.HasAssertions := True;
    Result.Assertions := True;
  end;

  // 2. Apply base artifact configuration
  ApplyOverlayToManifest(Result, AManifest.Base);

  // 3. Apply test overlay when resolving test builds
  if AForTest then
  begin
    Result.Entry := '';
    Result.Output := '';
    if AManifest.HasTest then
      ApplyOverlayToManifest(Result, AManifest.Test);
  end;

  // 4. Apply platform/architecture targets overlays
  ApplyMatchingTargetOverlays(Result, AManifest.Targets, ATargetCpu, ATargetOs);

  // 5. Apply profile overlay
  if ProfileIdx >= 0 then
    ApplyOverlayToManifest(Result, AManifest.Profiles[ProfileIdx].Overlay);

  // 6. Finalize names, entry & output validation
  if (Trim(Result.ProjectName) = '') and (Trim(Result.Entry) <> '') then
    Result.ProjectName := ChangeFileExt(ExtractFileName(NormalizeNativeSeparators(Result.Entry)), '');

  if AForTest then
  begin
    if ARequireEntry and (Trim(Result.Entry) = '') then
      RaiseManifestError(AManifest.ManifestPath, AManifest.RootLine,
        Format('Missing ''%s.test.entry'' (e.g. tests/test_all.pas) for test execution.',
          [ManifestKindToString(AManifest.Kind)]));
    if Trim(Result.Output) = '' then
      Result.Output := 'bin/' + Result.ProjectName + '-test';
  end
  else
  begin
    case Result.Kind of
      mkProgram:
        begin
          if ARequireEntry and (Trim(Result.Entry) = '') then
            RaiseManifestError(AManifest.ManifestPath, AManifest.RootLine,
              Format('Missing required ''program.entry'' (e.g. src/main.pas) for profile ''%s''.',
                [Result.ProfileName]));
          if Trim(Result.Output) = '' then
            Result.Output := 'bin/' + Result.ProjectName;
        end;
      mkLibrary:
        begin
          if ARequireEntry and (Trim(Result.Entry) = '') then
            RaiseManifestError(AManifest.ManifestPath, AManifest.RootLine,
              '''library'' requires ''entry'' (builds a native .dll/.so/.dylib). Did you mean ''package'' for a Pascal unit package?');
          if Trim(Result.Output) = '' then
            Result.Output := 'bin/' + Result.ProjectName;
        end;
      mkPackage:
        begin
          // Source unit package: no binary entry or output
          Result.Entry := '';
          Result.Output := '';
        end;
    else
      raise ENikError.CreateFmt('Unsupported TManifestKind ordinal: %d', [Ord(Result.Kind)]);
    end;
  end;

  if ARequireToolchain and (Result.Kind <> mkPackage) and (Trim(Result.FpcSpec) = '') then
    RaiseManifestError(AManifest.ManifestPath, AManifest.RootLine,
      Format('Missing required ''%s.toolchain.fpc'' (e.g. ''3.2.2'' or ''3.3.1'').',
        [ManifestKindToString(Result.Kind)]));
end;

function ResolveManifestProfile(const AManifest: TParsedManifest;
  const AProfileName: string;
  const ATargetCpu: string;
  const ATargetOs: string): TResolvedManifest;
begin
  Result := ResolveManifestConfig(AManifest, AProfileName, ATargetCpu, ATargetOs, False, True);
end;

end.
