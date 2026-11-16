unit nik.sdk.manager;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nik.types;

function IsExactFpcVersion(const ARaw: string): Boolean;
function BuildTargetTripletFilter(const ATargetOs, ATargetCpu: string): string;

function GetEffectiveSdkIndexUrl(const AOverrideUrl: string = ''): string;

function ListInstalledSdks: TInstalledSdkArray;
function FetchRemoteSdkIndex(const AOverrideUrl: string = ''): TSdkIndex;

function TryDetectInstalledHostVersion(out AFpcVersion: string): Boolean;

function TryResolveInstalledSdk(const AVersion: string; out AFound: TInstalledSdk): Boolean;
function TryResolveInstalledSdkForTarget(const AVersion, ATargetSpec: string; out AFound: TInstalledSdk): Boolean;
function RequireInstalledSdk(const AVersion: string): TInstalledSdk;
function RequireInstalledSdkForTarget(const AVersion, ATargetSpec: string): TInstalledSdk;

function ResolveRemoteSdkSpec(const AIndex: TSdkIndex;
  const AVersion, ATargetOs, ATargetCpu: string;
  AExplicitArch: Boolean;
  out AUsedWinArmFallback: Boolean): TRemoteSdkEntry;

function InstallSdk(const ASpec, ATargetOs, ATargetCpu, AIndexUrl: string;
  AExplicitArch, AForce, ASkipVerify: Boolean): TInstalledSdk;

procedure UninstallSdk(const AVersion: string; const ATargetSpec: string = '');

implementation

uses
  nik.platform, nik.paths, nik.fs, nik.term, nik.sha256, nik.http, nik.archive, nik.sdk.config;

function IsAllAsciiDigits(const S: string): Boolean;
var
  I: Integer;
begin
  if S = '' then
    Exit(False);
  for I := 1 to Length(S) do
    if (S[I] < '0') or (S[I] > '9') then
      Exit(False);
  Result := True;
end;

function TryParseExactVersionParts(const ARaw: string; out AMaj, AMin, APat: Integer): Boolean;
var
  S, MajStr, Rest, MinStr, PatStr: string;
  Dot1, Dot2, Err1, Err2, Err3: Integer;
begin
  Result := False;
  AMaj := 0;
  AMin := 0;
  APat := 0;

  S := Trim(ARaw);
  Dot1 := Pos('.', S);
  if Dot1 <= 1 then
    Exit;
  MajStr := Copy(S, 1, Dot1 - 1);
  Rest := Copy(S, Dot1 + 1, MaxInt);

  Dot2 := Pos('.', Rest);
  if Dot2 <= 1 then
    Exit;
  MinStr := Copy(Rest, 1, Dot2 - 1);
  PatStr := Copy(Rest, Dot2 + 1, MaxInt);

  if Pos('.', PatStr) > 0 then
    Exit;

  if (not IsAllAsciiDigits(MajStr)) or (not IsAllAsciiDigits(MinStr)) or (not IsAllAsciiDigits(PatStr)) then
    Exit;

  Val(MajStr, AMaj, Err1);
  Val(MinStr, AMin, Err2);
  Val(PatStr, APat, Err3);
  Result := (Err1 = 0) and (Err2 = 0) and (Err3 = 0);
end;

function IsExactFpcVersion(const ARaw: string): Boolean;
var
  Maj, Min, Pat: Integer;
begin
  Result := TryParseExactVersionParts(ARaw, Maj, Min, Pat);
end;

function BuildTargetTripletFilter(const ATargetOs, ATargetCpu: string): string;
var
  EffOs, EffCpu: string;
begin
  if (Trim(ATargetOs) = '') and (Trim(ATargetCpu) = '') then
    Exit('');

  if Trim(ATargetOs) <> '' then
    EffOs := LowerCase(Trim(ATargetOs))
  else
    EffOs := GetHostOs;

  if Trim(ATargetCpu) <> '' then
    EffCpu := LowerCase(Trim(ATargetCpu))
  else
    EffCpu := GetHostCpu;

  Result := EffCpu + '-' + EffOs;
end;

function CompareVersionDesc(const AVerA, AVerB: string): Integer;
var
  MajA, MinA, PatA, MajB, MinB, PatB: Integer;
begin
  if TryParseExactVersionParts(AVerA, MajA, MinA, PatA) and
     TryParseExactVersionParts(AVerB, MajB, MinB, PatB) then
  begin
    if MajA <> MajB then
      Exit(MajB - MajA);
    if MinA <> MinB then
      Exit(MinB - MinA);
    Exit(PatB - PatA);
  end;
  Result := CompareText(AVerB, AVerA);
end;

function GetEffectiveSdkIndexUrl(const AOverrideUrl: string): string;
var
  EnvUrl: string;
begin
  if Trim(AOverrideUrl) <> '' then
    Exit(Trim(AOverrideUrl));

  EnvUrl := Trim(GetEnvironmentVariable(ENV_SDK_INDEX_URL));
  if EnvUrl <> '' then
    Exit(EnvUrl);

  Result := DEFAULT_SDK_INDEX_URL;
end;

procedure SortInstalledSdks(var AList: TInstalledSdkArray);
var
  I, J, Cmp: Integer;
  Tmp: TInstalledSdk;
begin
  // Sort by version ascending for human tables, but newest BuiltAtUtc first within the same version
  for I := 0 to High(AList) - 1 do
    for J := I + 1 to High(AList) do
    begin
      Cmp := -CompareVersionDesc(AList[I].Manifest.FpcVersion, AList[J].Manifest.FpcVersion);
      if Cmp = 0 then
        Cmp := CompareText(AList[J].Manifest.BuiltAtUtc, AList[I].Manifest.BuiltAtUtc);
      if Cmp = 0 then
        Cmp := CompareText(AList[I].Manifest.SdkId, AList[J].Manifest.SdkId);
      if Cmp > 0 then
      begin
        Tmp := AList[I];
        AList[I] := AList[J];
        AList[J] := Tmp;
      end;
    end;
end;

function ListInstalledSdks: TInstalledSdkArray;
var
  SdksDir, CandidateDir: string;
  Rec: TSearchRec;
  Manifest: TSdkManifest;
  Count: Integer;
begin
  Result := nil;
  SdksDir := GetNikrunSdksDir;
  if not DirectoryExists(SdksDir) then
    Exit;

  Count := 0;
  if FindFirst(IncludeTrailingPathDelimiter(SdksDir) + AllFilesMask, faDirectory, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        if (Rec.Attr and faDirectory) = 0 then
          Continue;
        if (Length(Rec.Name) > 0) and (Rec.Name[1] = '.') then
          Continue;

        CandidateDir := JoinPath(SdksDir, Rec.Name);
        if TryLoadSdkManifest(CandidateDir, Manifest) then
        begin
          SetLength(Result, Count + 1);
          Result[Count].Manifest := Manifest;
          Result[Count].InstallPath := CandidateDir;
          Inc(Count);
        end;
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
  end;

  SortInstalledSdks(Result);
end;

function FetchRemoteSdkIndex(const AOverrideUrl: string): TSdkIndex;
var
  Url, JsonText: string;
begin
  Url := GetEffectiveSdkIndexUrl(AOverrideUrl);
  JsonText := HttpGetText(Url);
  Result := ParseSdkIndexJson(JsonText);
end;

function IsHostCompatibleSdk(const AManifest: TSdkManifest): Boolean;
begin
  if not SameText(AManifest.TargetOs, GetHostOs) then
    Exit(False);
  if SameText(AManifest.TargetCpu, GetHostCpu) then
    Exit(True);
  if SameText(GetHostOs, 'win64') and SameText(GetHostCpu, 'aarch64') and
     SameText(AManifest.TargetCpu, 'x86_64') then
    Exit(True);
  Result := False;
end;

function TryDetectInstalledHostVersion(out AFpcVersion: string): Boolean;
var
  Installed: TInstalledSdkArray;
  I, BestIdx: Integer;
begin
  Result := False;
  AFpcVersion := '';
  Installed := ListInstalledSdks;
  if Length(Installed) = 0 then
    Exit;

  // Prefer exact host CPU+OS with highest installed version
  BestIdx := -1;
  for I := 0 to High(Installed) do
  begin
    if SameText(Installed[I].Manifest.TargetOs, GetHostOs) and
       SameText(Installed[I].Manifest.TargetCpu, GetHostCpu) and
       IsExactFpcVersion(Installed[I].Manifest.FpcVersion) then
    begin
      if (BestIdx < 0) or
         (CompareVersionDesc(Installed[I].Manifest.FpcVersion, Installed[BestIdx].Manifest.FpcVersion) < 0) then
        BestIdx := I;
    end;
  end;

  // Fallback to host-compatible SDK (e.g. x86_64-win64 on Windows ARM64)
  if BestIdx < 0 then
  begin
    for I := 0 to High(Installed) do
      if IsHostCompatibleSdk(Installed[I].Manifest) and IsExactFpcVersion(Installed[I].Manifest.FpcVersion) then
      begin
        if (BestIdx < 0) or
           (CompareVersionDesc(Installed[I].Manifest.FpcVersion, Installed[BestIdx].Manifest.FpcVersion) < 0) then
          BestIdx := I;
      end;
  end;

  if BestIdx >= 0 then
  begin
    AFpcVersion := Installed[BestIdx].Manifest.FpcVersion;
    Result := True;
  end;
end;

function TryResolveInstalledSdkForTarget(const AVersion, ATargetSpec: string; out AFound: TInstalledSdk): Boolean;
var
  Installed: TInstalledSdkArray;
  I: Integer;
  TrimmedVer, EffTarget: string;
begin
  Result := False;
  AFound := Default(TInstalledSdk);
  TrimmedVer := Trim(AVersion);
  if not IsExactFpcVersion(TrimmedVer) then
    Exit(False);

  EffTarget := LowerCase(Trim(ATargetSpec));
  if EffTarget = 'native' then
    EffTarget := '';

  Installed := ListInstalledSdks;

  // Explicit <cpu>-<os> target triplet
  if EffTarget <> '' then
  begin
    for I := 0 to High(Installed) do
      if SameText(Installed[I].Manifest.FpcVersion, TrimmedVer) and
         SameText(Installed[I].Manifest.TargetTriplet, EffTarget) then
      begin
        AFound := Installed[I];
        Exit(True);
      end;
    Exit(False);
  end;

  // 1. Exact host CPU + OS match
  for I := 0 to High(Installed) do
    if SameText(Installed[I].Manifest.FpcVersion, TrimmedVer) and
       SameText(Installed[I].Manifest.TargetOs, GetHostOs) and
       SameText(Installed[I].Manifest.TargetCpu, GetHostCpu) then
    begin
      AFound := Installed[I];
      Exit(True);
    end;

  // 2. Host-compatible match (e.g. x86_64-win64 on Windows ARM64)
  for I := 0 to High(Installed) do
    if SameText(Installed[I].Manifest.FpcVersion, TrimmedVer) and
       IsHostCompatibleSdk(Installed[I].Manifest) then
    begin
      AFound := Installed[I];
      Exit(True);
    end;
end;

function TryResolveInstalledSdk(const AVersion: string; out AFound: TInstalledSdk): Boolean;
begin
  Result := TryResolveInstalledSdkForTarget(AVersion, '', AFound);
end;

function RequireInstalledSdkForTarget(const AVersion, ATargetSpec: string): TInstalledSdk;
var
  TrimmedVer, EffTarget: string;
begin
  TrimmedVer := Trim(AVersion);
  if TrimmedVer = '' then
    raise ENikError.Create('Missing Free Pascal SDK version (expected exact version such as ''3.2.2'' or ''3.3.1'').');

  if not IsExactFpcVersion(TrimmedVer) then
    raise ENikError.CreateFmt(
      'Invalid Free Pascal SDK version ''%s'' (expected exact <major>.<minor>.<patch> version such as ''3.2.2'' or ''3.3.1'').',
      [TrimmedVer]);

  if not TryResolveInstalledSdkForTarget(TrimmedVer, ATargetSpec, Result) then
  begin
    EffTarget := LowerCase(Trim(ATargetSpec));
    if EffTarget = 'native' then
      EffTarget := '';

    if EffTarget <> '' then
      raise ENikError.CreateFmt(
        'Installed Free Pascal SDK ''%s'' for target ''%s'' not found. Run ''nik sdk list'' or install it with ''nik sdk install %s''.',
        [TrimmedVer, EffTarget, TrimmedVer])
    else
      raise ENikError.CreateFmt(
        'Installed Free Pascal SDK ''%s'' not found. Run ''nik sdk install %s'' first.',
        [TrimmedVer, TrimmedVer]);
  end;
end;

function RequireInstalledSdk(const AVersion: string): TInstalledSdk;
begin
  Result := RequireInstalledSdkForTarget(AVersion, '');
end;

function ResolveRemoteSdkSpec(const AIndex: TSdkIndex;
  const AVersion, ATargetOs, ATargetCpu: string;
  AExplicitArch: Boolean;
  out AUsedWinArmFallback: Boolean): TRemoteSdkEntry;
var
  EffOs, EffCpu, TrimmedVer: string;
  I: Integer;
begin
  AUsedWinArmFallback := False;
  TrimmedVer := Trim(AVersion);
  if TrimmedVer = '' then
    raise ENikError.Create('Missing SDK version or local path (e.g., ''3.2.2'', ''3.3.1'', or path to a local SDK).');

  if not IsExactFpcVersion(TrimmedVer) then
    raise ENikError.CreateFmt(
      'Invalid Free Pascal SDK version ''%s'' (expected exact version such as ''3.2.2'' or ''3.3.1'', or path to a local SDK).',
      [TrimmedVer]);

  if ATargetOs <> '' then
    EffOs := LowerCase(Trim(ATargetOs))
  else
    EffOs := GetHostOs;

  if ATargetCpu <> '' then
    EffCpu := LowerCase(Trim(ATargetCpu))
  else
    EffCpu := GetHostCpu;

  // 1. Match by FPC version for target OS/CPU
  for I := 0 to High(AIndex.Sdks) do
  begin
    if SameText(AIndex.Sdks[I].FpcVersion, TrimmedVer) and
       SameText(AIndex.Sdks[I].TargetOs, EffOs) and
       SameText(AIndex.Sdks[I].TargetCpu, EffCpu) then
      Exit(AIndex.Sdks[I]);
  end;

  // 2. Fallback on Windows ARM64 -> x86_64 when native ARM64 archive is unavailable (e.g. FPC 3.2.x)
  if (not AExplicitArch) and SameText(EffOs, 'win64') and SameText(EffCpu, 'aarch64') then
  begin
    for I := 0 to High(AIndex.Sdks) do
    begin
      if SameText(AIndex.Sdks[I].FpcVersion, TrimmedVer) and
         SameText(AIndex.Sdks[I].TargetOs, 'win64') and
         SameText(AIndex.Sdks[I].TargetCpu, 'x86_64') then
      begin
        AUsedWinArmFallback := True;
        Exit(AIndex.Sdks[I]);
      end;
    end;
  end;

  raise ENikError.CreateFmt(
    'No prebuilt SDK version ''%s'' found for target %s-%s. Run ''nik sdk list --remote'' to inspect available versions.',
    [TrimmedVer, EffCpu, EffOs]);
end;

procedure OnSdkDownloadProgress(ABytesRead, ATotalBytes: Int64);
begin
  WriteProgress('Downloading', ABytesRead, ATotalBytes);
end;

function ReadFirstHexTokenFromShaFile(const AShaFilePath: string): string;
var
  Raw: string;
  I: Integer;
begin
  Raw := Trim(ReadFileTextUtf8(AShaFilePath));
  Result := '';
  for I := 1 to Length(Raw) do
  begin
    if Raw[I] in [' ', #9, #10, #13] then
      Break;
    Result := Result + LowerCase(Raw[I]);
  end;
end;

function LocateExtractedSdkRoot(const AStagingDir: string): string;
var
  Rec: TSearchRec;
  SingleDir: string;
  SubDirCount, FileCount: Integer;
begin
  if FileExists(JoinPath(AStagingDir, 'sdk-manifest.json')) then
    Exit(AStagingDir);

  SubDirCount := 0;
  FileCount := 0;
  SingleDir := '';
  if FindFirst(IncludeTrailingPathDelimiter(AStagingDir) + AllFilesMask, faAnyFile, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        if (Rec.Attr and faDirectory) <> 0 then
        begin
          Inc(SubDirCount);
          SingleDir := JoinPath(AStagingDir, Rec.Name);
        end
        else
          Inc(FileCount);
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
  end;

  if (FileCount = 0) and (SubDirCount = 1) and FileExists(JoinPath(SingleDir, 'sdk-manifest.json')) then
    Exit(SingleDir);

  raise ENikError.Create('Invalid FPC SDK archive: sdk-manifest.json missing at archive root.');
end;

function IsValidInstalledSdkDir(const ASdkDir: string; out AManifest: TSdkManifest): Boolean;
begin
  Result := TryLoadSdkManifest(ASdkDir, AManifest) and
            FileExists(JoinPath(ASdkDir, AManifest.Paths.FpcBinary));
end;

function FinalizeSdkFromZip(const AZipPath, AExpectedSha256: string;
  AForce, ASkipVerify: Boolean): TInstalledSdk;
var
  ExpectedHash, ActualHash, SidecarShaFile: string;
  StagingDir, ExtractedRoot, DestDir, FpcBinPath, CfgPath: string;
  Manifest: TSdkManifest;
begin
  if not FileExists(AZipPath) then
    raise ENikError.CreateFmt('SDK archive not found: %s', [AZipPath]);

  ExpectedHash := LowerCase(Trim(AExpectedSha256));
  if (ExpectedHash = '') and (not ASkipVerify) then
  begin
    SidecarShaFile := AZipPath + '.sha256';
    if FileExists(SidecarShaFile) then
      ExpectedHash := ReadFirstHexTokenFromShaFile(SidecarShaFile);
  end;

  if not ASkipVerify then
  begin
    ActualHash := Sha256FileHex(AZipPath);
    if ExpectedHash <> '' then
    begin
      if not SameText(ActualHash, ExpectedHash) then
        raise ENikError.CreateFmt(
          'SHA-256 checksum mismatch for %s!' + LineEnding +
          '  Expected: %s' + LineEnding +
          '  Actual  : %s',
          [ExtractFileName(AZipPath), ExpectedHash, ActualHash]);
      WriteSuccess(Format('Verified SHA-256 checksum (%s...)', [Copy(ActualHash, 1, 16)]));
    end
    else
      WriteInfo(Format('Archive SHA-256: %s', [ActualHash]));
  end;

  EnsureDirExists(GetNikrunSdksDir);
  StagingDir := JoinPath(GetNikrunSdksDir, Format('.staging-%d-%d', [GetProcessID, GetTickCount64]));
  if DirectoryExists(StagingDir) then
    DeleteDirectoryRecursive(StagingDir);

  try
    WriteStep('Extracting SDK archive...');
    ExtractZipArchive(AZipPath, StagingDir);
    ExtractedRoot := LocateExtractedSdkRoot(StagingDir);
    Manifest := LoadSdkManifest(ExtractedRoot);

    FpcBinPath := JoinPath(ExtractedRoot, Manifest.Paths.FpcBinary);
    if not FileExists(FpcBinPath) then
      raise ENikError.CreateFmt('Corrupted SDK archive: compiler binary missing (%s).', [Manifest.Paths.FpcBinary]);

    DestDir := JoinPath(GetNikrunSdksDir, Manifest.SdkId);
    if DirectoryExists(DestDir) then
    begin
      if not AForce then
      begin
        WriteInfo(Format('SDK ''%s'' is already installed at %s (use --force to reinstall).',
          [Manifest.SdkId, DestDir]));
        Result.Manifest := Manifest;
        Result.InstallPath := DestDir;
        Exit;
      end;

      DeleteDirectoryRecursive(DestDir);
    end;

    MoveDirectoryAtomic(ExtractedRoot, DestDir);

    if not SameText(Manifest.TargetOs, 'win64') then
      EnsureBinariesExecutable(JoinPath(DestDir, Manifest.Paths.BinDir));

    CfgPath := GenerateFpcCfgForSdk(DestDir, Manifest);
    WriteSuccess('Installed SDK to: ' + DestDir);
    WriteSuccess('Generated isolated fpc.cfg: ' + CfgPath);

    Result.Manifest := Manifest;
    Result.InstallPath := DestDir;
  finally
    if DirectoryExists(StagingDir) then
      DeleteDirectoryRecursive(StagingDir);
  end;
end;

function FinalizeSdkFromDirectory(const ASourceDir: string; AForce: Boolean): TInstalledSdk;
var
  StagingDir, DestDir, FpcBinPath, CfgPath, NormSrc, NormDest: string;
  Manifest: TSdkManifest;
begin
  if not DirectoryExists(ASourceDir) then
    raise ENikError.CreateFmt('Local SDK directory not found: %s', [ASourceDir]);

  Manifest := LoadSdkManifest(ASourceDir);
  FpcBinPath := JoinPath(ASourceDir, Manifest.Paths.FpcBinary);
  if not FileExists(FpcBinPath) then
    raise ENikError.CreateFmt('Invalid local SDK directory: compiler binary missing (%s).', [Manifest.Paths.FpcBinary]);

  EnsureDirExists(GetNikrunSdksDir);
  DestDir := JoinPath(GetNikrunSdksDir, Manifest.SdkId);
  NormSrc := ExcludeTrailingPathDelimiter(ExpandFileName(ASourceDir));
  NormDest := ExcludeTrailingPathDelimiter(ExpandFileName(DestDir));

  if not SameText(NormSrc, NormDest) then
  begin
    if DirectoryExists(DestDir) then
    begin
      if not AForce then
      begin
        WriteInfo(Format('SDK ''%s'' is already installed at %s (use --force to reinstall).',
          [Manifest.SdkId, DestDir]));
        Result.Manifest := Manifest;
        Result.InstallPath := DestDir;
        Exit;
      end;
      DeleteDirectoryRecursive(DestDir);
    end;

    StagingDir := JoinPath(GetNikrunSdksDir, Format('.staging-%d-%d', [GetProcessID, GetTickCount64]));
    if DirectoryExists(StagingDir) then
      DeleteDirectoryRecursive(StagingDir);

    try
      WriteStep('Copying local SDK directory...');
      CopyDirectoryRecursive(ASourceDir, StagingDir);
      MoveDirectoryAtomic(StagingDir, DestDir);
    finally
      if DirectoryExists(StagingDir) then
        DeleteDirectoryRecursive(StagingDir);
    end;
  end;

  if not SameText(Manifest.TargetOs, 'win64') then
    EnsureBinariesExecutable(JoinPath(DestDir, Manifest.Paths.BinDir));

  CfgPath := GenerateFpcCfgForSdk(DestDir, Manifest);
  WriteSuccess('Installed SDK to: ' + DestDir);
  WriteSuccess('Generated isolated fpc.cfg: ' + CfgPath);

  Result.Manifest := Manifest;
  Result.InstallPath := DestDir;
end;

function LooksLikeLocalSdkSpec(const ASpec: string): Boolean;
var
  Trimmed, Lower, Norm: string;
  HasSep: Boolean;
begin
  Trimmed := Trim(ASpec);
  if Trimmed = '' then
    Exit(False);

  Lower := LowerCase(Trimmed);
  Norm := NormalizeNativeSeparators(Trimmed);
  HasSep := (Pos('/', Trimmed) > 0) or (Pos('\', Trimmed) > 0);

  if ((Length(Lower) > 4) and (Copy(Lower, Length(Lower) - 3, 4) = '.zip')) or
     HasSep or (Trimmed = '.') or (Trimmed = '..') then
    Exit(True);

  if FileExists(Norm) then
    Exit(True);

  if DirectoryExists(Norm) and FileExists(JoinPath(Norm, 'sdk-manifest.json')) then
    Exit(True);

  Result := False;
end;

function InstallSdk(const ASpec, ATargetOs, ATargetCpu, AIndexUrl: string;
  AExplicitArch, AForce, ASkipVerify: Boolean): TInstalledSdk;
var
  LocalPath, DestDir, CacheDir, PartFile, DownloadedZip, CfgPath: string;
  Index: TSdkIndex;
  Entry: TRemoteSdkEntry;
  UsedFallback: Boolean;
  ExistingManifest: TSdkManifest;
begin
  if Trim(ASpec) = '' then
    raise ENikError.Create('Missing SDK version or local SDK path. Example: ''nik sdk install 3.2.2''.');

  // Case 1: Local SDK installation (.zip archive or extracted SDK directory)
  if LooksLikeLocalSdkSpec(ASpec) then
  begin
    LocalPath := ExpandFileName(NormalizeNativeSeparators(Trim(ASpec)));
    if DirectoryExists(LocalPath) then
    begin
      WriteStep(Format('Installing Free Pascal SDK from local directory: %s', [LocalPath]));
      Result := FinalizeSdkFromDirectory(LocalPath, AForce);
      Exit;
    end;

    if FileExists(LocalPath) then
    begin
      WriteStep(Format('Installing Free Pascal SDK from local archive: %s', [ExtractFileName(LocalPath)]));
      Result := FinalizeSdkFromZip(LocalPath, '', AForce, ASkipVerify);
      Exit;
    end;

    raise ENikError.CreateFmt('Local SDK archive or directory not found: %s', [LocalPath]);
  end;

  // Validate exact FPC version before making remote HTTP requests
  if not IsExactFpcVersion(ASpec) then
    raise ENikError.CreateFmt(
      'Invalid Free Pascal SDK version ''%s'' (expected exact version such as ''3.2.2'' or ''3.3.1'', or path to a local SDK).',
      [Trim(ASpec)]);

  // Case 2: Remote resolution by FPC version via index.json
  WriteStep('Fetching remote SDK index...');
  Index := FetchRemoteSdkIndex(AIndexUrl);
  Entry := ResolveRemoteSdkSpec(Index, ASpec, ATargetOs, ATargetCpu, AExplicitArch, UsedFallback);

  if UsedFallback then
    WriteInfo('Note: Using x86_64-win64 SDK on Windows ARM64 (runs seamlessly under emulation).');

  DestDir := JoinPath(GetNikrunSdksDir, Entry.SdkId);
  if (not AForce) and DirectoryExists(DestDir) and IsValidInstalledSdkDir(DestDir, ExistingManifest) then
  begin
    CfgPath := JoinPath(JoinPath(DestDir, ExistingManifest.Paths.BinDir), 'fpc.cfg');
    if not FileExists(CfgPath) then
      GenerateFpcCfgForSdk(DestDir, ExistingManifest);

    WriteSuccess(Format('SDK ''%s'' is already installed at %s', [Entry.SdkId, DestDir]));
    WriteInfo('Pass --force to re-download and reinstall.');

    Result.Manifest := ExistingManifest;
    Result.InstallPath := DestDir;
    Exit;
  end;

  CacheDir := GetNikrunCacheDir;
  EnsureDirExists(CacheDir);
  DownloadedZip := JoinPath(CacheDir, Entry.FileName);
  PartFile := DownloadedZip + '.part';
  if FileExists(PartFile) then
    DeleteFile(PartFile);

  WriteStep(Format('Downloading %s (%s)...', [Entry.SdkId, FormatByteSize(Entry.SizeBytes)]));
  try
    HttpDownloadFile(Entry.DownloadUrl, PartFile, @OnSdkDownloadProgress, Entry.SizeBytes);
    FinishProgress;

    if FileExists(DownloadedZip) then
      DeleteFile(DownloadedZip);
    if not RenameFile(PartFile, DownloadedZip) then
      raise ENikError.CreateFmt('Failed to finalize downloaded file: %s', [DownloadedZip]);

    Result := FinalizeSdkFromZip(DownloadedZip, Entry.Sha256, AForce, ASkipVerify);
  finally
    FinishProgress;
    if FileExists(PartFile) then
      DeleteFile(PartFile);
    if FileExists(DownloadedZip) then
      DeleteFile(DownloadedZip);
  end;
end;

procedure UninstallSdk(const AVersion: string; const ATargetSpec: string);
var
  TrimmedVer, EffTarget: string;
  Target: TInstalledSdk;
  Installed: TInstalledSdkArray;
  I: Integer;
begin
  TrimmedVer := Trim(AVersion);
  if TrimmedVer = '' then
    raise ENikError.Create('Missing Free Pascal SDK version to uninstall. Example: ''nik sdk uninstall 3.3.1''.');

  Target := RequireInstalledSdkForTarget(TrimmedVer, ATargetSpec);
  EffTarget := Target.Manifest.TargetTriplet;

  // Remove all installed snapshots matching this (FpcVersion, TargetTriplet)
  Installed := ListInstalledSdks;
  for I := 0 to High(Installed) do
  begin
    if SameText(Installed[I].Manifest.FpcVersion, TrimmedVer) and
       SameText(Installed[I].Manifest.TargetTriplet, EffTarget) then
    begin
      WriteStep(Format('Uninstalling SDK ''%s''...', [Installed[I].Manifest.SdkId]));
      DeleteDirectoryRecursive(Installed[I].InstallPath);
      WriteSuccess('Removed directory: ' + Installed[I].InstallPath);
    end;
  end;
end;

end.
