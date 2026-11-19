unit nik.pkg.resolve;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  nik.types, nik.manifest.types, nik.pkg.types;

function ResolveProjectPackages(const AParsedRoot: TParsedManifest;
  const AResolvedRoot: TResolvedManifest;
  const ATargetCpu, ATargetOs: string;
  const AOptions: TPackageResolveOptions): TPackageResolutionResult;

function FetchAllManifestPackages(const AParsedRoot: TParsedManifest;
  const ATargetCpu, ATargetOs: string;
  const AOptions: TPackageResolveOptions): TPackageResolutionResult;

implementation

uses
  nik.paths, nik.fs, nik.archive,
  nik.manifest.io, nik.manifest.resolve,
  nik.pkg.semver, nik.pkg.lock, nik.pkg.fetch;

type
  TConstraintOrigin = record
    HasSemVer: Boolean;
    Constraint: TSemVerConstraint;
    RawSpec: string;
    RevPin: string;
    Chain: string;
  end;
  TConstraintOriginArray = array of TConstraintOrigin;

  TAccumulatedGitReq = record
    PkgId: string;
    NormUrl: string;
    Subpath: string;
    DisplayName: string;
    Origins: TConstraintOriginArray;
    HasChosen: Boolean;
    ChosenVersion: string;
    ChosenRev40: string;
    ChosenIntegrity: string;
    ChosenCacheDir: string;
  end;
  TAccumulatedGitReqArray = array of TAccumulatedGitReq;

  TLocalOverrideEntry = record
    TargetPkgId: string;
    TargetUrl: string;
    OverrideSpec: TDependencySpec;
    BaseDir: string;
  end;
  TLocalOverrideArray = array of TLocalOverrideEntry;

  TRepoInspectionCacheEntry = record
    NormUrl: string;
    Info: TGitRepoInspection;
  end;
  TRepoInspectionCache = array of TRepoInspectionCacheEntry;

const
  MAX_MVS_PASSES = 64;

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

procedure AppendUniqueStr(var AList: TStringArray; const AVal: string; ACaseInsensitive: Boolean);
var
  I, N: Integer;
begin
  if AVal = '' then
    Exit;
  for I := 0 to High(AList) do
  begin
    if ACaseInsensitive then
    begin
      if SameText(AList[I], AVal) then
        Exit;
    end
    else if AList[I] = AVal then
      Exit;
  end;
  N := Length(AList);
  SetLength(AList, N + 1);
  AList[N] := AVal;
end;

function SameNodeKey(const A, B: string): Boolean;
begin
  if (Pos('://', A) > 0) or (Pos('://', B) > 0) then
    Result := (A = B)
  else
  begin
    {$IFDEF WINDOWS}
    Result := SameText(A, B);
    {$ELSE}
    Result := (A = B);
    {$ENDIF}
  end;
end;

function FindManifestInDir(const ADir: string): string;
var
  CandYaml, CandYml: string;
begin
  CandYaml := JoinPath(ADir, 'nik.yaml');
  if FileExists(CandYaml) then
    Exit(CandYaml);
  CandYml := JoinPath(ADir, 'nik.yml');
  if FileExists(CandYml) then
    Exit(CandYml);
  Result := '';
end;

function FormatArchiveRelOrAbsId(const ARootProjectDir, AOwnerDir, ARawPath, ASubpath: string): string;
var
  AbsArchive, RootPrefix, RelSlash: string;
begin
  AbsArchive := ResolveRelativePath(AOwnerDir, ARawPath);
  RootPrefix := IncludeTrailingPathDelimiter(ExpandFileName(ARootProjectDir));
  {$IFDEF WINDOWS}
  if SameText(Copy(AbsArchive, 1, Length(RootPrefix)), RootPrefix) then
  {$ELSE}
  if Copy(AbsArchive, 1, Length(RootPrefix)) = RootPrefix then
  {$ENDIF}
  begin
    RelSlash := './' + NormalizeForwardSlashes(Copy(AbsArchive, Length(RootPrefix) + 1, MaxInt));
    Result := BuildArchivePkgId(RelSlash, ASubpath);
  end
  else
    Result := BuildArchivePkgId(NormalizeForwardSlashes(ARawPath), ASubpath);
end;

procedure CollectOverridesFromRootDeps(const ARootDir: string;
  const ADeps: TDependencySpecArray; var AOverrides: TLocalOverrideArray);
var
  I, N: Integer;
  Dep: TDependencySpec;
  LocalDir, ManifestPath, NormRepoUrl, ErrMsg: string;
  LocalParsed: TParsedManifest;
begin
  for I := 0 to High(ADeps) do
  begin
    Dep := ADeps[I];
    if (Dep.Kind <> dskLocalPath) and (Dep.Kind <> dskLocalArchive) then
      Continue;

    NormRepoUrl := Dep.Url;
    if (NormRepoUrl = '') and (Dep.Kind = dskLocalPath) then
    begin
      LocalDir := ResolveRelativePath(ARootDir, Dep.Path);
      if Dep.Subpath <> '' then
        LocalDir := JoinPath(LocalDir, Dep.Subpath);
      ManifestPath := FindManifestInDir(LocalDir);
      if ManifestPath <> '' then
      begin
        try
          LocalParsed := LoadManifestFile(ManifestPath);
          if LocalParsed.Base.HasRepository and (Trim(LocalParsed.Base.Repository) <> '') then
          begin
            if not NormalizeRemoteUrlBase(LocalParsed.Base.Repository, True, NormRepoUrl, ErrMsg) then
              NormRepoUrl := '';
          end;
        except
          NormRepoUrl := '';
        end;
      end;
    end;

    if NormRepoUrl <> '' then
    begin
      N := Length(AOverrides);
      SetLength(AOverrides, N + 1);
      AOverrides[N].TargetUrl := NormRepoUrl;
      if IsSupportedArchivePath(NormRepoUrl) then
        AOverrides[N].TargetPkgId := BuildArchivePkgId(NormRepoUrl, Dep.Subpath)
      else
        AOverrides[N].TargetPkgId := BuildGitPkgId(NormRepoUrl, Dep.Subpath);
      AOverrides[N].OverrideSpec := Dep;
      AOverrides[N].OverrideSpec.Url := ''; // Prevent infinite override recursion
      AOverrides[N].BaseDir := ARootDir;
    end;
  end;
end;

function FindLocalOverride(const AOverrides: TLocalOverrideArray; const APkgId, AUrl: string;
  out AEntry: TLocalOverrideEntry): Boolean;
var
  I: Integer;
begin
  Result := False;
  AEntry := Default(TLocalOverrideEntry);
  for I := 0 to High(AOverrides) do
    if (AOverrides[I].TargetPkgId = APkgId) or
       ((AUrl <> '') and (AOverrides[I].TargetUrl = AUrl) and (AOverrides[I].OverrideSpec.Subpath = '')) then
    begin
      AEntry := AOverrides[I];
      Exit(True);
    end;
end;

function GetCachedInspection(const ANormUrl: string; var ACache: TRepoInspectionCache): TGitRepoInspection;
var
  I, N: Integer;
begin
  for I := 0 to High(ACache) do
    if ACache[I].NormUrl = ANormUrl then
      Exit(ACache[I].Info);

  Result := InspectGitRepository(ANormUrl);
  N := Length(ACache);
  SetLength(ACache, N + 1);
  ACache[N].NormUrl := ANormUrl;
  ACache[N].Info := Result;
end;

function FindOrCreateGitReq(var ATable: TAccumulatedGitReqArray;
  const APkgId, ANormUrl, ASubpath, ADisplayName: string): Integer;
var
  I, N: Integer;
begin
  for I := 0 to High(ATable) do
    if ATable[I].PkgId = APkgId then
      Exit(I);

  N := Length(ATable);
  SetLength(ATable, N + 1);
  ATable[N] := Default(TAccumulatedGitReq);
  ATable[N].PkgId := APkgId;
  ATable[N].NormUrl := ANormUrl;
  ATable[N].Subpath := ASubpath;
  ATable[N].DisplayName := ADisplayName;
  Result := N;
end;

function AddOriginToGitReq(var AReq: TAccumulatedGitReq; const ADep: TDependencySpec;
  const AChain: string): Boolean;
var
  I, N: Integer;
  ErrMsg: string;
  ParsedCon: TSemVerConstraint;
begin
  Result := False;
  for I := 0 to High(AReq.Origins) do
    if (AReq.Origins[I].RawSpec = ADep.VersionSpec) and
       (AReq.Origins[I].RevPin = ADep.Rev) and
       (AReq.Origins[I].Chain = AChain) then
      Exit(False);

  N := Length(AReq.Origins);
  SetLength(AReq.Origins, N + 1);
  AReq.Origins[N] := Default(TConstraintOrigin);
  AReq.Origins[N].Chain := AChain;

  if ADep.Rev <> '' then
    AReq.Origins[N].RevPin := ADep.Rev
  else
  begin
    if not TryParseSemVerConstraint(ADep.VersionSpec, ParsedCon, ErrMsg) then
      raise ENikError.CreateFmt('Invalid version constraint ''%s'' for ''%s'': %s',
        [ADep.VersionSpec, AReq.PkgId, ErrMsg]);
    AReq.Origins[N].HasSemVer := True;
    AReq.Origins[N].Constraint := ParsedCon;
    AReq.Origins[N].RawSpec := ADep.VersionSpec;
  end;
  Result := True;
end;

function FormatOriginsSummary(const AOrigins: TConstraintOriginArray): string;
var
  I: Integer;
  Piece: string;
begin
  Result := '';
  for I := 0 to High(AOrigins) do
  begin
    if AOrigins[I].RevPin <> '' then
      Piece := Format('@%s (required by %s)', [AOrigins[I].RevPin, AOrigins[I].Chain])
    else
      Piece := Format('%s (required by %s)', [AOrigins[I].RawSpec, AOrigins[I].Chain]);
    if Result <> '' then
      Result := Result + '; ';
    Result := Result + Piece;
  end;
end;

function SelectionSatisfiesAllOrigins(const AReq: TAccumulatedGitReq;
  const AVerStr, ARev40: string): Boolean;
var
  I: Integer;
  ParsedVer: TSemVer;
  HasVer: Boolean;
begin
  HasVer := (AVerStr <> '') and TryParseSemVer(AVerStr, ParsedVer, True);
  for I := 0 to High(AReq.Origins) do
  begin
    if AReq.Origins[I].RevPin <> '' then
    begin
      if not SameText(Copy(ARev40, 1, Length(AReq.Origins[I].RevPin)), AReq.Origins[I].RevPin) then
        Exit(False);
    end
    else if AReq.Origins[I].HasSemVer then
    begin
      if (not HasVer) or (not SemVerSatisfiesConstraint(ParsedVer, AReq.Origins[I].Constraint)) then
        Exit(False);
    end;
  end;
  Result := True;
end;

function ShouldUpdatePkg(const AOptions: TPackageResolveOptions;
  const ADisplayName, APkgId: string): Boolean;
begin
  if AOptions.UpdateAll then
    Exit(True);
  if Trim(AOptions.UpdateTargetName) = '' then
    Exit(False);
  Result := SameText(ADisplayName, AOptions.UpdateTargetName) or
            SameText(APkgId, AOptions.UpdateTargetName);
end;

function ResolveGitRequirement(var AReq: TAccumulatedGitReq;
  const AExistingLock: TLockFile;
  const AOptions: TPackageResolveOptions;
  var AInspectCache: TRepoInspectionCache;
  var AMissingList: TStringArray): Boolean;
var
  I: Integer;
  PinnedPrefix, CandidateCommit, ExpectedIntegrity: string;
  Constraints: TSemVerConstraintArray;
  LockedEntry: TLockedPackage;
  HasLock: Boolean;
  RepoInfo: TGitRepoInspection;
  TagVers: TSemVerArray;
  ChosenVer: TSemVer;
  FoundCommit: Boolean;
begin
  Result := False;
  PinnedPrefix := '';
  Constraints := nil;

  // Validate compatibility of accumulated rev pins & collect SemVer constraints
  for I := 0 to High(AReq.Origins) do
  begin
    if AReq.Origins[I].RevPin <> '' then
    begin
      if PinnedPrefix = '' then
        PinnedPrefix := AReq.Origins[I].RevPin
      else if (not SameText(Copy(PinnedPrefix, 1, Length(AReq.Origins[I].RevPin)), AReq.Origins[I].RevPin)) and
              (not SameText(Copy(AReq.Origins[I].RevPin, 1, Length(PinnedPrefix)), PinnedPrefix)) then
        raise ENikError.CreateFmt('Conflicting commit pins for ''%s'': %s',
          [AReq.PkgId, FormatOriginsSummary(AReq.Origins)]);

      if Length(AReq.Origins[I].RevPin) > Length(PinnedPrefix) then
        PinnedPrefix := AReq.Origins[I].RevPin;
    end
    else if AReq.Origins[I].HasSemVer then
    begin
      SetLength(Constraints, Length(Constraints) + 1);
      Constraints[High(Constraints)] := AReq.Origins[I].Constraint;
    end;
  end;

  if (PinnedPrefix <> '') and (Length(Constraints) > 0) then
    raise ENikError.CreateFmt(
      'Conflicting commit pin and SemVer version constraint for ''%s'': %s',
      [AReq.PkgId, FormatOriginsSummary(AReq.Origins)]);

  HasLock := FindLockedPackageById(AExistingLock, AReq.PkgId, LockedEntry) and
             (LockedEntry.Kind = lpkGit);

  // 1. Reuse nik.lock entry whenever valid and not explicitly updating this package
  if HasLock and (not ShouldUpdatePkg(AOptions, AReq.DisplayName, AReq.PkgId)) and
     SelectionSatisfiesAllOrigins(AReq, LockedEntry.Version, LockedEntry.Rev) then
  begin
    if AOptions.Offline then
    begin
      if FindCachedGitPackageDir(AReq.NormUrl, LockedEntry.Rev,
           AReq.ChosenRev40, AReq.ChosenCacheDir, AReq.ChosenIntegrity) then
      begin
        if not SameText(AReq.ChosenIntegrity, LockedEntry.Integrity) then
          raise ENikError.CreateFmt(
            'Package integrity mismatch for ''%s'': nik.lock expects %s, cached tree has %s.',
            [AReq.PkgId, LockedEntry.Integrity, AReq.ChosenIntegrity]);
        AReq.ChosenVersion := LockedEntry.Version;
        AReq.HasChosen := True;
        Exit(True);
      end;

      if AOptions.SoftMissingForLsp then
      begin
        AppendUniqueStr(AMissingList, AReq.PkgId, False);
        Exit(False);
      end;

      raise ENikError.CreateFmt(
        'Dependency ''%s'' (%s) is not in local package cache (offline mode). Run ''nik pkg fetch'' while online.',
        [AReq.DisplayName, AReq.PkgId]);
    end;

    EnsureGitPackageCached(AReq.NormUrl, LockedEntry.Rev, LockedEntry.Integrity,
      AReq.ChosenRev40, AReq.ChosenCacheDir, AReq.ChosenIntegrity);
    AReq.ChosenVersion := LockedEntry.Version;
    AReq.HasChosen := True;
    Exit(True);
  end;

  // Locked mode forbids resolving unlocked or out-of-date dependencies
  if AOptions.Locked then
    raise ENikError.CreateFmt(
      'nik.lock is missing or out of sync for dependency ''%s'' (%s). Run ''nik pkg fetch'' or ''nik build'' without --locked to update nik.lock.',
      [AReq.DisplayName, AReq.PkgId]);

  // 2. Offline handling when not in nik.lock
  if AOptions.Offline then
  begin
    if (PinnedPrefix <> '') and
       FindCachedGitPackageDir(AReq.NormUrl, PinnedPrefix,
         AReq.ChosenRev40, AReq.ChosenCacheDir, AReq.ChosenIntegrity) then
    begin
      AReq.ChosenVersion := '';
      AReq.HasChosen := True;
      Exit(True);
    end;

    if AOptions.SoftMissingForLsp then
    begin
      AppendUniqueStr(AMissingList, AReq.PkgId, False);
      Exit(False);
    end;

    raise ENikError.CreateFmt(
      'Cannot resolve uncached remote dependency ''%s'' (%s) in --offline mode. Run ''nik pkg fetch'' first.',
      [AReq.DisplayName, AReq.PkgId]);
  end;

  // 3. Online resolution: commit pin vs. SemVer tag resolution
  ExpectedIntegrity := '';
  if PinnedPrefix <> '' then
  begin
    // A pin names an immutable commit: when nik.lock already records that commit, the tree must still
    // hash to the recorded integrity, otherwise `nik pkg update` would silently overwrite it.
    if HasLock and SameText(Copy(LockedEntry.Rev, 1, Length(PinnedPrefix)), PinnedPrefix) then
      ExpectedIntegrity := LockedEntry.Integrity;
    EnsureGitPackageCached(AReq.NormUrl, PinnedPrefix, ExpectedIntegrity,
      AReq.ChosenRev40, AReq.ChosenCacheDir, AReq.ChosenIntegrity);
    AReq.ChosenVersion := '';
    AReq.HasChosen := True;
    Exit(True);
  end;

  RepoInfo := GetCachedInspection(AReq.NormUrl, AInspectCache);
  TagVers := nil;
  for I := 0 to High(RepoInfo.Refs) do
    if RepoInfo.Refs[I].IsTag and RepoInfo.Refs[I].HasSemVer then
    begin
      SetLength(TagVers, Length(TagVers) + 1);
      TagVers[High(TagVers)] := RepoInfo.Refs[I].SemVer;
    end;

  if Length(TagVers) = 0 then
  begin
    if RepoInfo.HeadCommit <> '' then
      raise ENikError.CreateFmt(
        'Repository ''%s'' has no SemVer tags. Pin a commit hash instead (e.g. %s@%s).',
        [AReq.NormUrl, AReq.NormUrl, Copy(RepoInfo.HeadCommit, 1, 8)])
    else
      raise ENikError.CreateFmt('Repository ''%s'' has no SemVer tags.', [AReq.NormUrl]);
  end;

  // On 'nik pkg update' pick latest matching tag; on normal MVS resolution pick minimal version satisfying all constraints
  if ShouldUpdatePkg(AOptions, AReq.DisplayName, AReq.PkgId) then
  begin
    if not SelectLatestMatchingVersion(TagVers, Constraints, ChosenVer) then
      raise ENikError.CreateFmt(
        'No SemVer tag in ''%s'' satisfies constraints: %s',
        [AReq.PkgId, FormatOriginsSummary(AReq.Origins)]);
  end
  else
  begin
    if not SelectMinimalMatchingVersion(TagVers, Constraints, ChosenVer) then
      raise ENikError.CreateFmt(
        'No SemVer tag in ''%s'' satisfies constraints: %s',
        [AReq.PkgId, FormatOriginsSummary(AReq.Origins)]);
  end;

  CandidateCommit := '';
  FoundCommit := False;
  for I := 0 to High(RepoInfo.Refs) do
    if RepoInfo.Refs[I].IsTag and RepoInfo.Refs[I].HasSemVer and
       (CompareSemVer(RepoInfo.Refs[I].SemVer, ChosenVer) = 0) then
    begin
      CandidateCommit := RepoInfo.Refs[I].CommitSha;
      FoundCommit := True;
      Break;
    end;

  if not FoundCommit then
    raise ENikError.CreateFmt('Internal error: failed to locate commit SHA for tag %s in %s.',
      [ChosenVer.RawTag, AReq.NormUrl]);

  if HasLock and SameText(LockedEntry.Rev, CandidateCommit) then
    ExpectedIntegrity := LockedEntry.Integrity;

  EnsureGitPackageCached(AReq.NormUrl, CandidateCommit, ExpectedIntegrity,
    AReq.ChosenRev40, AReq.ChosenCacheDir, AReq.ChosenIntegrity);
  AReq.ChosenVersion := FormatSemVer(ChosenVer);
  AReq.HasChosen := True;
  Result := True;
end;

procedure CollectDeclaredManifestPkgIds(const AOverlay: TManifestOverlay;
  const AProjectDir: string; var AIds: TStringArray);
var
  I: Integer;
  Dep: TDependencySpec;
begin
  if not AOverlay.HasDependencies then
    Exit;
  for I := 0 to High(AOverlay.Dependencies) do
  begin
    Dep := AOverlay.Dependencies[I];
    case Dep.Kind of
      dskGitRepo:
        AppendUniqueStr(AIds, BuildGitPkgId(Dep.Url, Dep.Subpath), False);
      dskArchiveUrl:
        AppendUniqueStr(AIds, BuildArchivePkgId(Dep.Url, Dep.Subpath), False);
      dskLocalArchive:
        AppendUniqueStr(AIds, FormatArchiveRelOrAbsId(AProjectDir, AProjectDir, Dep.Path, Dep.Subpath), False);
      dskLocalPath:
        ; // Local directories are not stored in nik.lock
    else
      raise ENikError.Create('Internal error: unexpected TDependencySourceKind.');
    end;
  end;
end;

function CollectAllDeclaredRemoteIdsInParsed(const AParsed: TParsedManifest): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  CollectDeclaredManifestPkgIds(AParsed.Base, AParsed.ProjectDir, Result);
  if AParsed.HasTest then
    CollectDeclaredManifestPkgIds(AParsed.Test, AParsed.ProjectDir, Result);
  for I := 0 to High(AParsed.Targets) do
    CollectDeclaredManifestPkgIds(AParsed.Targets[I].Overlay, AParsed.ProjectDir, Result);
  for I := 0 to High(AParsed.Profiles) do
    CollectDeclaredManifestPkgIds(AParsed.Profiles[I].Overlay, AParsed.ProjectDir, Result);
end;

function ExecuteGraphResolution(const AParsedRoot: TParsedManifest;
  const ARootProjectDir, ARootDisplayName: string;
  const ADirectDeps: TDependencySpecArray;
  const ATargetCpu, ATargetOs: string;
  const AOptions: TPackageResolveOptions;
  APreserveOtherRootSectionsInLock: Boolean): TPackageResolutionResult;
var
  ExistingLock: TLockFile;
  Overrides: TLocalOverrideArray;
  GitTable: TAccumulatedGitReqArray;
  InspectCache: TRepoInspectionCache;
  DesiredLocks: TLockedPackageArray;
  ResolvedList: TResolvedPackageArray;
  VisitedKeys, ActiveStack, DeclaredRootIds: TStringArray;
  NeedsRestart: Boolean;
  PassNo, I: Integer;

  procedure PushStack(const AKey: string);
  var
    N: Integer;
  begin
    N := Length(ActiveStack);
    SetLength(ActiveStack, N + 1);
    ActiveStack[N] := AKey;
  end;

  procedure PopStack;
  begin
    if Length(ActiveStack) > 0 then
      SetLength(ActiveStack, Length(ActiveStack) - 1);
  end;

  function StackContains(const AKey: string): Boolean;
  var
    K: Integer;
  begin
    for K := 0 to High(ActiveStack) do
      if SameNodeKey(ActiveStack[K], AKey) then
        Exit(True);
    Result := False;
  end;

  function VisitedContains(const AKey: string): Boolean;
  var
    K: Integer;
  begin
    for K := 0 to High(VisitedKeys) do
      if SameNodeKey(VisitedKeys[K], AKey) then
        Exit(True);
    Result := False;
  end;

  procedure MarkVisited(const AKey: string);
  var
    N: Integer;
  begin
    N := Length(VisitedKeys);
    SetLength(VisitedKeys, N + 1);
    VisitedKeys[N] := AKey;
  end;

  procedure RecordDesiredLock(const AEntry: TLockedPackage);
  var
    K, N: Integer;
  begin
    for K := 0 to High(DesiredLocks) do
      if DesiredLocks[K].Id = AEntry.Id then
      begin
        DesiredLocks[K] := AEntry;
        Exit;
      end;
    N := Length(DesiredLocks);
    SetLength(DesiredLocks, N + 1);
    DesiredLocks[N] := AEntry;
  end;

  procedure VisitDependencyEdge(const AOwnerDir, AChainPrefix: string;
    const ADep: TDependencySpec; AIsDirect, AWasOverridden: Boolean); forward;

  procedure MaterializeAndTraversePackageDir(const ANodeKey, APkgId, AEffectiveDir, AChain: string;
    const AConsumerDep: TDependencySpec; AActualKind: TDependencySourceKind;
    const AUrl, AVersion, ARev, AIntegrityOrSha: string;
    AIsDirect, AWasOverridden: Boolean);
  var
    PkgManifestPath: string;
    PkgParsed: TParsedManifest;
    PkgCfg: TResolvedManifest;
    HasPkgManifest, UsedExplicitConsumerPaths: Boolean;
    J, Idx: Integer;
    NodeInfo: TResolvedPackage;
  begin
    if StackContains(ANodeKey) then
      raise ENikError.CreateFmt('Circular dependency detected: %s', [AChain]);

    if VisitedContains(ANodeKey) then
    begin
      // If a direct dependency was earlier visited transitively, upgrade its Direct flag
      if AIsDirect then
      begin
        for Idx := 0 to High(ResolvedList) do
          if SameNodeKey(ResolvedList[Idx].Id, APkgId) then
            ResolvedList[Idx].Direct := True;
      end;
      Exit;
    end;

    MarkVisited(ANodeKey);
    PushStack(ANodeKey);
    try
      PkgManifestPath := FindManifestInDir(AEffectiveDir);
      HasPkgManifest := (PkgManifestPath <> '');
      PkgCfg := Default(TResolvedManifest);

      if HasPkgManifest then
      begin
        AppendUniquePath(Result.ManifestFiles, ExpandFileName(PkgManifestPath));
        if AOptions.SoftMissingForLsp then
        begin
          try
            PkgParsed := LoadManifestFile(PkgManifestPath);
            PkgCfg := ResolveManifestConfig(PkgParsed, 'debug', ATargetCpu, ATargetOs, False, False, False);
          except
            HasPkgManifest := False;
          end;
        end
        else
        begin
          PkgParsed := LoadManifestFile(PkgManifestPath);
          PkgCfg := ResolveManifestConfig(PkgParsed, 'debug', ATargetCpu, ATargetOs, False, False, False);
        end;
      end;

      // Traverse transitive dependencies first (topological order: leaf packages registered cleanly)
      if HasPkgManifest then
      begin
        for J := 0 to High(PkgCfg.Dependencies) do
        begin
          VisitDependencyEdge(
            AEffectiveDir,
            AChain + ' -> ' + PkgCfg.Dependencies[J].Name,
            PkgCfg.Dependencies[J],
            False,
            False
          );
          if NeedsRestart then
            Exit;
        end;
      end;

      // Emit search paths and link libraries for this package
      UsedExplicitConsumerPaths := (Length(AConsumerDep.UnitPaths) > 0) or
                                   (Length(AConsumerDep.IncludePaths) > 0);
      if UsedExplicitConsumerPaths then
      begin
        for J := 0 to High(AConsumerDep.UnitPaths) do
          AppendUniquePath(Result.UnitPaths, ResolveRelativePath(AEffectiveDir, AConsumerDep.UnitPaths[J]));
        for J := 0 to High(AConsumerDep.IncludePaths) do
          AppendUniquePath(Result.IncludePaths, ResolveRelativePath(AEffectiveDir, AConsumerDep.IncludePaths[J]));
      end
      else if HasPkgManifest and
              ((Length(PkgCfg.UnitPaths) > 0) or (Length(PkgCfg.IncludePaths) > 0) or
               (Length(PkgCfg.LibraryPaths) > 0) or (Length(PkgCfg.ObjectPaths) > 0) or
               (Length(PkgCfg.ResourcePaths) > 0)) then
      begin
        for J := 0 to High(PkgCfg.UnitPaths) do
          AppendUniquePath(Result.UnitPaths, ResolveRelativePath(AEffectiveDir, PkgCfg.UnitPaths[J]));
        for J := 0 to High(PkgCfg.IncludePaths) do
          AppendUniquePath(Result.IncludePaths, ResolveRelativePath(AEffectiveDir, PkgCfg.IncludePaths[J]));
        for J := 0 to High(PkgCfg.LibraryPaths) do
          AppendUniquePath(Result.LibraryPaths, ResolveRelativePath(AEffectiveDir, PkgCfg.LibraryPaths[J]));
        for J := 0 to High(PkgCfg.ObjectPaths) do
          AppendUniquePath(Result.ObjectPaths, ResolveRelativePath(AEffectiveDir, PkgCfg.ObjectPaths[J]));
        for J := 0 to High(PkgCfg.ResourcePaths) do
        begin
          AppendUniquePath(Result.IncludePaths, ResolveRelativePath(AEffectiveDir, PkgCfg.ResourcePaths[J]));
          AppendUniquePath(Result.ObjectPaths, ResolveRelativePath(AEffectiveDir, PkgCfg.ResourcePaths[J]));
        end;
      end
      else
      begin
        AppendUniquePath(Result.UnitPaths, AEffectiveDir);
        AppendUniquePath(Result.IncludePaths, AEffectiveDir);
      end;

      if HasPkgManifest then
      begin
        for J := 0 to High(PkgCfg.LinkLibraries) do
          AppendUniqueStr(Result.LinkLibraries, PkgCfg.LinkLibraries[J], False);
      end;

      NodeInfo := Default(TResolvedPackage);
      NodeInfo.Id := APkgId;
      NodeInfo.Name := AConsumerDep.Name;
      NodeInfo.SourceKind := AActualKind;
      NodeInfo.Url := AUrl;
      NodeInfo.Subpath := AConsumerDep.Subpath;
      NodeInfo.Version := AVersion;
      NodeInfo.Rev := ARev;
      NodeInfo.IntegrityOrSha256 := AIntegrityOrSha;
      NodeInfo.RootDir := AEffectiveDir;
      NodeInfo.Direct := AIsDirect;
      NodeInfo.OverriddenLocally := AWasOverridden;

      Idx := Length(ResolvedList);
      SetLength(ResolvedList, Idx + 1);
      ResolvedList[Idx] := NodeInfo;
    finally
      PopStack;
    end;
  end;

  procedure VisitDependencyEdge(const AOwnerDir, AChainPrefix: string;
    const ADep: TDependencySpec; AIsDirect, AWasOverridden: Boolean);
  var
    PkgId, EffectiveDir, LocalBase, ActualSha, CacheDir, ExpectedSha: string;
    OverrideHit: TLocalOverrideEntry;
    SubSpec: TDependencySpec;
    ReqIdx: Integer;
    WasChosen: Boolean;
    PrevRev: string;
    LockedArch, NewLock: TLockedPackage;
    HasLockArch: Boolean;
  begin
    case ADep.Kind of
      dskLocalPath:
        begin
          LocalBase := ResolveRelativePath(AOwnerDir, ADep.Path);
          if ADep.Subpath <> '' then
            EffectiveDir := JoinPath(LocalBase, ADep.Subpath)
          else
            EffectiveDir := LocalBase;

          if not DirectoryExists(EffectiveDir) then
          begin
            if AOptions.SoftMissingForLsp then
            begin
              AppendUniqueStr(Result.MissingPackages, ADep.Name + ' (' + EffectiveDir + ')', False);
              Exit;
            end;
            raise ENikError.CreateFmt('Path for dependency ''%s'' does not exist: %s', [ADep.Name, EffectiveDir]);
          end;

          MaterializeAndTraversePackageDir(
            EffectiveDir,
            NormalizeForwardSlashes(EffectiveDir),
            EffectiveDir,
            AChainPrefix,
            ADep,
            dskLocalPath,
            ADep.Url,
            '',
            '',
            '',
            AIsDirect,
            AWasOverridden or (ADep.Url <> '')
          );
        end;

      dskLocalArchive:
        begin
          LocalBase := ResolveRelativePath(AOwnerDir, ADep.Path);
          PkgId := FormatArchiveRelOrAbsId(ARootProjectDir, AOwnerDir, ADep.Path, ADep.Subpath);
          HasLockArch := FindLockedPackageById(ExistingLock, PkgId, LockedArch) and (LockedArch.Kind = lpkArchive);

          ExpectedSha := ADep.Sha256;
          if (ExpectedSha = '') and AOptions.Locked then
          begin
            if not HasLockArch then
              raise ENikError.CreateFmt(
                'nik.lock is missing entry for local archive ''%s'' (%s) in --locked mode.',
                [ADep.Name, PkgId]);
            ExpectedSha := LockedArch.Sha256;
          end;

          if (not FileExists(LocalBase)) and AOptions.SoftMissingForLsp then
          begin
            AppendUniqueStr(Result.MissingPackages, ADep.Name + ' (' + LocalBase + ')', False);
            Exit;
          end;

          EnsureArchivePackageCached(LocalBase, True, ExpectedSha, ActualSha, CacheDir);
          if AOptions.Locked and HasLockArch and (not SameText(ActualSha, LockedArch.Sha256)) then
            raise ENikError.CreateFmt(
              'Local archive ''%s'' changed on disk (nik.lock expects %s, found %s).',
              [ADep.Path, LockedArch.Sha256, ActualSha]);

          if ADep.Subpath <> '' then
            EffectiveDir := JoinPath(CacheDir, ADep.Subpath)
          else
            EffectiveDir := CacheDir;

          if not DirectoryExists(EffectiveDir) then
            raise ENikError.CreateFmt('Subpath ''%s'' not found inside archive ''%s''.', [ADep.Subpath, ADep.Path]);

          NewLock := Default(TLockedPackage);
          NewLock.Id := PkgId;
          NewLock.Kind := lpkArchive;
          NewLock.Path := NormalizeForwardSlashes(ADep.Path);
          NewLock.Subpath := ADep.Subpath;
          NewLock.Sha256 := ActualSha;
          RecordDesiredLock(NewLock);

          MaterializeAndTraversePackageDir(
            'archive:' + ActualSha + '#' + ADep.Subpath,
            PkgId,
            EffectiveDir,
            AChainPrefix,
            ADep,
            dskLocalArchive,
            '',
            '',
            '',
            ActualSha,
            AIsDirect,
            AWasOverridden or (ADep.Url <> '')
          );
        end;

      dskArchiveUrl:
        begin
          PkgId := BuildArchivePkgId(ADep.Url, ADep.Subpath);
          if (not AWasOverridden) and FindLocalOverride(Overrides, PkgId, ADep.Url, OverrideHit) then
          begin
            SubSpec := OverrideHit.OverrideSpec;
            SubSpec.Name := ADep.Name;
            if (SubSpec.Subpath = '') and (ADep.Subpath <> '') then
              SubSpec.Subpath := ADep.Subpath;
            VisitDependencyEdge(OverrideHit.BaseDir, AChainPrefix, SubSpec, AIsDirect, True);
            Exit;
          end;

          HasLockArch := FindLockedPackageById(ExistingLock, PkgId, LockedArch) and (LockedArch.Kind = lpkArchive);
          ExpectedSha := ADep.Sha256;
          if ExpectedSha = '' then
          begin
            if HasLockArch then
              ExpectedSha := LockedArch.Sha256
            else if AOptions.Locked then
              raise ENikError.CreateFmt(
                'nik.lock is missing entry for archive dependency ''%s'' (%s). Run ''nik pkg fetch'' without --locked.',
                [ADep.Name, PkgId]);
          end
          else if HasLockArch and (not SameText(ExpectedSha, LockedArch.Sha256)) then
          begin
            if AOptions.Locked then
              raise ENikError.CreateFmt(
                'nik.lock SHA-256 (%s) does not match nik.yaml sha256 (%s) for ''%s''.',
                [LockedArch.Sha256, ExpectedSha, PkgId]);
          end;

          if AOptions.Offline then
          begin
            if (ExpectedSha <> '') and FindCachedArchiveDir(ExpectedSha, CacheDir) then
              ActualSha := LowerCase(ExpectedSha)
            else if AOptions.SoftMissingForLsp then
            begin
              AppendUniqueStr(Result.MissingPackages, PkgId, False);
              Exit;
            end
            else
              raise ENikError.CreateFmt(
                'Archive dependency ''%s'' (%s) is not cached locally (offline mode). Run ''nik pkg fetch'' while online.',
                [ADep.Name, PkgId]);
          end
          else
            EnsureArchivePackageCached(ADep.Url, False, ExpectedSha, ActualSha, CacheDir);

          if ADep.Subpath <> '' then
            EffectiveDir := JoinPath(CacheDir, ADep.Subpath)
          else
            EffectiveDir := CacheDir;

          if not DirectoryExists(EffectiveDir) then
            raise ENikError.CreateFmt('Subpath ''%s'' not found inside archive ''%s''.', [ADep.Subpath, ADep.Url]);

          NewLock := Default(TLockedPackage);
          NewLock.Id := PkgId;
          NewLock.Kind := lpkArchive;
          NewLock.Url := ADep.Url;
          NewLock.Subpath := ADep.Subpath;
          NewLock.Sha256 := ActualSha;
          RecordDesiredLock(NewLock);

          MaterializeAndTraversePackageDir(
            PkgId,
            PkgId,
            EffectiveDir,
            AChainPrefix,
            ADep,
            dskArchiveUrl,
            ADep.Url,
            '',
            '',
            ActualSha,
            AIsDirect,
            False
          );
        end;

      dskGitRepo:
        begin
          PkgId := BuildGitPkgId(ADep.Url, ADep.Subpath);
          if (not AWasOverridden) and FindLocalOverride(Overrides, PkgId, ADep.Url, OverrideHit) then
          begin
            SubSpec := OverrideHit.OverrideSpec;
            SubSpec.Name := ADep.Name;
            if (SubSpec.Subpath = '') and (ADep.Subpath <> '') then
              SubSpec.Subpath := ADep.Subpath;
            VisitDependencyEdge(OverrideHit.BaseDir, AChainPrefix, SubSpec, AIsDirect, True);
            Exit;
          end;

          ReqIdx := FindOrCreateGitReq(GitTable, PkgId, ADep.Url, ADep.Subpath, ADep.Name);
          AddOriginToGitReq(GitTable[ReqIdx], ADep, AChainPrefix);

          WasChosen := GitTable[ReqIdx].HasChosen;
          PrevRev := GitTable[ReqIdx].ChosenRev40;

          if (not WasChosen) or
             (not SelectionSatisfiesAllOrigins(GitTable[ReqIdx],
                    GitTable[ReqIdx].ChosenVersion, GitTable[ReqIdx].ChosenRev40)) then
          begin
            if not ResolveGitRequirement(GitTable[ReqIdx], ExistingLock, AOptions,
                     InspectCache, Result.MissingPackages) then
              Exit; // SoftMissingForLsp recorded missing package

            if WasChosen and (GitTable[ReqIdx].ChosenRev40 <> PrevRev) then
            begin
              // Newly discovered transitive constraint upgraded an already-traversed package; restart MVS pass!
              NeedsRestart := True;
              Exit;
            end;
          end;

          if ADep.Subpath <> '' then
            EffectiveDir := JoinPath(GitTable[ReqIdx].ChosenCacheDir, ADep.Subpath)
          else
            EffectiveDir := GitTable[ReqIdx].ChosenCacheDir;

          if not DirectoryExists(EffectiveDir) then
            raise ENikError.CreateFmt(
              'Subpath ''%s'' does not exist in ''%s'' at commit %s.',
              [ADep.Subpath, ADep.Url, GitTable[ReqIdx].ChosenRev40]);

          NewLock := Default(TLockedPackage);
          NewLock.Id := PkgId;
          NewLock.Kind := lpkGit;
          NewLock.Url := ADep.Url;
          NewLock.Subpath := ADep.Subpath;
          NewLock.Version := GitTable[ReqIdx].ChosenVersion;
          NewLock.Rev := GitTable[ReqIdx].ChosenRev40;
          NewLock.Integrity := GitTable[ReqIdx].ChosenIntegrity;
          RecordDesiredLock(NewLock);

          MaterializeAndTraversePackageDir(
            PkgId,
            PkgId,
            EffectiveDir,
            AChainPrefix,
            ADep,
            dskGitRepo,
            ADep.Url,
            GitTable[ReqIdx].ChosenVersion,
            GitTable[ReqIdx].ChosenRev40,
            GitTable[ReqIdx].ChosenIntegrity,
            AIsDirect,
            False
          );
        end;
    else
      raise ENikError.Create('Internal error: unexpected TDependencySourceKind.');
    end;
  end;

begin
  Result := Default(TPackageResolutionResult);
  if Length(ADirectDeps) = 0 then
  begin
    // Still prune stale nik.lock if no remote deps remain anywhere in nik.yaml!
    ExistingLock := LoadLockFile(ARootProjectDir);
    if ExistingLock.ExistsOnDisk then
    begin
      DeclaredRootIds := CollectAllDeclaredRemoteIdsInParsed(AParsedRoot);
      if Length(DeclaredRootIds) = 0 then
      begin
        if AOptions.Locked and (Length(ExistingLock.Packages) > 0) then
          raise ENikError.Create('nik.lock contains stale packages that are no longer in nik.yaml (--locked).');
        if AOptions.AllowLockWrite and (not AOptions.Locked) then
          Result.LockUpdated := SyncLockFileOnDisk(ARootProjectDir, nil);
      end;
    end;
    Exit;
  end;

  ExistingLock := LoadLockFile(ARootProjectDir);
  Overrides := nil;
  CollectOverridesFromRootDeps(ARootProjectDir, ADirectDeps, Overrides);

  GitTable := nil;
  InspectCache := nil;

  for PassNo := 1 to MAX_MVS_PASSES do
  begin
    NeedsRestart := False;
    Result.UnitPaths := nil;
    Result.IncludePaths := nil;
    Result.LibraryPaths := nil;
    Result.ObjectPaths := nil;
    Result.LinkLibraries := nil;
    Result.ManifestFiles := nil;
    Result.MissingPackages := nil;
    DesiredLocks := nil;
    ResolvedList := nil;
    VisitedKeys := nil;
    ActiveStack := nil;

    for I := 0 to High(ADirectDeps) do
    begin
      VisitDependencyEdge(
        ARootProjectDir,
        ARootDisplayName + ' -> ' + ADirectDeps[I].Name,
        ADirectDeps[I],
        True,
        False
      );
      if NeedsRestart then
        Break;
    end;

    if not NeedsRestart then
      Break;

    if PassNo = MAX_MVS_PASSES then
      raise ENikError.Create('Dependency resolution exceeded maximum MVS iteration limit (64).');
  end;

  Result.Packages := ResolvedList;

  // A build resolves only the active target, but nik.lock covers every manifest overlay (other OS
  // targets, profiles, test.dependencies). The lock is a flat list without edges, so an entry cannot be
  // attributed to a section; keep every entry this closure did not produce, including the transitive
  // packages of other targets (dropping them made `--locked` builds on another OS fail). Entries that
  // nothing needs any more are pruned by `nik pkg fetch`, which resolves all sections.
  if APreserveOtherRootSectionsInLock and ExistingLock.ExistsOnDisk then
  begin
    for I := 0 to High(ExistingLock.Packages) do
    begin
      NeedsRestart := False;
      for PassNo := 0 to High(DesiredLocks) do
        if DesiredLocks[PassNo].Id = ExistingLock.Packages[I].Id then
        begin
          NeedsRestart := True;
          Break;
        end;
      if not NeedsRestart then
        RecordDesiredLock(ExistingLock.Packages[I]);
    end;
  end;

  if AOptions.Locked then
  begin
    if (Length(DesiredLocks) > 0) and (not ExistingLock.ExistsOnDisk) then
      raise ENikError.Create('nik.lock does not exist (--locked requires a committed nik.lock).');

    if APreserveOtherRootSectionsInLock then
    begin
      // Every package required by this target must match nik.lock identically
      for I := 0 to High(DesiredLocks) do
      begin
        NeedsRestart := False;
        for PassNo := 0 to High(ExistingLock.Packages) do
          if (ExistingLock.Packages[PassNo].Id = DesiredLocks[I].Id) and
             (ExistingLock.Packages[PassNo].Kind = DesiredLocks[I].Kind) and
             (ExistingLock.Packages[PassNo].Rev = DesiredLocks[I].Rev) and
             (ExistingLock.Packages[PassNo].Integrity = DesiredLocks[I].Integrity) and
             (ExistingLock.Packages[PassNo].Sha256 = DesiredLocks[I].Sha256) then
          begin
            NeedsRestart := True;
            Break;
          end;
        if not NeedsRestart then
          raise ENikError.CreateFmt(
            'nik.lock is out of sync for ''%s'' (--locked). Run ''nik pkg fetch'' to update nik.lock.',
            [DesiredLocks[I].Id]);
      end;
    end
    else if not LockedPackageSetsMatch(ExistingLock.Packages, DesiredLocks) then
      raise ENikError.Create('nik.lock is out of sync with nik.yaml (--locked). Run ''nik pkg fetch'' to update nik.lock.');
  end
  else if AOptions.AllowLockWrite and (Length(Result.MissingPackages) = 0) then
  begin
    Result.LockUpdated := SyncLockFileOnDisk(ARootProjectDir, DesiredLocks);
  end;

  if FileExists(JoinPath(ARootProjectDir, NIK_LOCK_FILENAME)) then
    AppendUniquePath(Result.ManifestFiles, ExpandFileName(JoinPath(ARootProjectDir, NIK_LOCK_FILENAME)));
end;

function ResolveProjectPackages(const AParsedRoot: TParsedManifest;
  const AResolvedRoot: TResolvedManifest;
  const ATargetCpu, ATargetOs: string;
  const AOptions: TPackageResolveOptions): TPackageResolutionResult;
var
  RootName: string;
begin
  RootName := Trim(AResolvedRoot.ProjectName);
  if RootName = '' then
    RootName := ExtractFileName(ExcludeTrailingPathDelimiter(AResolvedRoot.ProjectDir));
  if RootName = '' then
    RootName := 'project';

  Result := ExecuteGraphResolution(
    AParsedRoot,
    AResolvedRoot.ProjectDir,
    RootName,
    AResolvedRoot.Dependencies,
    ATargetCpu,
    ATargetOs,
    AOptions,
    True
  );
end;

procedure MergeAllSectionDeps(var ACombined: TDependencySpecArray; const ASectionDeps: TDependencySpecArray);
var
  I, J, N: Integer;
  Duplicate: Boolean;
begin
  for I := 0 to High(ASectionDeps) do
  begin
    Duplicate := False;
    for J := 0 to High(ACombined) do
    begin
      if SameText(ACombined[J].Name, ASectionDeps[I].Name) and
         (ACombined[J].Kind = ASectionDeps[I].Kind) and
         (ACombined[J].Url = ASectionDeps[I].Url) and
         (ACombined[J].Path = ASectionDeps[I].Path) and
         (ACombined[J].Subpath = ASectionDeps[I].Subpath) and
         (ACombined[J].VersionSpec = ASectionDeps[I].VersionSpec) and
         (ACombined[J].Rev = ASectionDeps[I].Rev) then
      begin
        Duplicate := True;
        Break;
      end;
    end;
    if not Duplicate then
    begin
      N := Length(ACombined);
      SetLength(ACombined, N + 1);
      ACombined[N] := ASectionDeps[I];
    end;
  end;
end;

function FetchAllManifestPackages(const AParsedRoot: TParsedManifest;
  const ATargetCpu, ATargetOs: string;
  const AOptions: TPackageResolveOptions): TPackageResolutionResult;
var
  CombinedDeps: TDependencySpecArray;
  RootName: string;
  I: Integer;
begin
  CombinedDeps := nil;
  if AParsedRoot.Base.HasDependencies then
    MergeAllSectionDeps(CombinedDeps, AParsedRoot.Base.Dependencies);
  if AParsedRoot.HasTest and AParsedRoot.Test.HasDependencies then
    MergeAllSectionDeps(CombinedDeps, AParsedRoot.Test.Dependencies);
  for I := 0 to High(AParsedRoot.Targets) do
    if AParsedRoot.Targets[I].Overlay.HasDependencies then
      MergeAllSectionDeps(CombinedDeps, AParsedRoot.Targets[I].Overlay.Dependencies);
  for I := 0 to High(AParsedRoot.Profiles) do
    if AParsedRoot.Profiles[I].Overlay.HasDependencies then
      MergeAllSectionDeps(CombinedDeps, AParsedRoot.Profiles[I].Overlay.Dependencies);

  if AParsedRoot.Base.HasName and (Trim(AParsedRoot.Base.Name) <> '') then
    RootName := Trim(AParsedRoot.Base.Name)
  else
    RootName := ExtractFileName(ExcludeTrailingPathDelimiter(AParsedRoot.ProjectDir));
  if RootName = '' then
    RootName := 'project';

  Result := ExecuteGraphResolution(
    AParsedRoot,
    AParsedRoot.ProjectDir,
    RootName,
    CombinedDeps,
    ATargetCpu,
    ATargetOs,
    AOptions,
    False
  );
end;

end.
