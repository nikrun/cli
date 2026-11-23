unit nik.source;

{$mode objfpc}{$H+}

{ Resolves the optional SOURCE argument of 'nik build' / 'nik run' into a manifest the project
  pipeline can compile:
    - project  : a directory or nik.yaml path (same as --manifest)
    - file     : a single .pas/.pp/.lpr/.dpr file; a synthetic nik.yaml is generated in the cache
    - url      : a Git repository / file / directory URL; fetched with the same engine as 'nik pkg'
                 (Git Smart HTTP, forge archives, git CLI), verified via tree integrity and cached
                 immutably, then handled like a project or a file.
  Running code from a URL requires trust (prompt, --trust, or a previously trusted tree). }

interface

uses
  SysUtils, nik.types;

type
  TSourceKind = (skProject, skFile, skUrl);

  TSourceOptions = record
    Offline: Boolean;
    Trust: Boolean;     // --trust: accept untrusted URL sources without prompting
    ForRun: Boolean;    // execution requested -> trust check applies to URL sources
    Quiet: Boolean;     // no informational output (machine-readable modes)
  end;

  TResolvedSource = record
    Kind: TSourceKind;
    Display: string;
    ManifestPath: string;    // '' = discover from the current directory
    EntryOverride: string;   // '' = entry from the manifest
    DefaultOutputName: string; // base name for 'nik build <file|url>' outputs ('' = keep manifest output)
    Commit: string;
  end;

function ClassifySource(const ASource: string): TSourceKind;
function ResolveSource(const ASource: string; const AOpts: TSourceOptions): TResolvedSource;

function SanitizeProgramName(const ARaw: string): string;
function BuildSyntheticManifestText(const AName, AEntryAbs, AFpcVersion: string;
  const AUnitDirsAbs: array of string): string;

function GetTrustStoreFile: string;
function IsSourceTrusted(const ARepoUrl, ATreeIntegrity: string; out AKnownOtherVersion: Boolean): Boolean;
procedure RememberTrustedSource(const ARepoUrl, ATreeIntegrity, ACommit: string);

implementation

uses
  Classes, StrUtils, DateUtils, fpjson, jsonparser,
  nik.paths, nik.fs, nik.term, nik.sha256, nik.pkg.types, nik.pkg.fetch,
  nik.sdk.manager, nik.source.url;

function IsPascalSourceExt(const AExt: string): Boolean;
begin
  Result := SameText(AExt, '.pas') or SameText(AExt, '.pp') or
            SameText(AExt, '.lpr') or SameText(AExt, '.dpr');
end;

function ClassifySource(const ASource: string): TSourceKind;
var
  S, Ext: string;
begin
  S := Trim(ASource);
  if SameText(Copy(S, 1, 8), 'https://') then
    Exit(skUrl);
  if SameText(Copy(S, 1, 7), 'http://') then
    raise ENikError.CreateFmt('Source ''%s'' uses http://. Only https:// sources are supported.', [S]);
  if Pos('://', S) > 0 then
    raise ENikError.CreateFmt('Unsupported source scheme in ''%s'' (expected a path or an https:// URL).', [S]);

  if DirectoryExists(S) then
    Exit(skProject);
  if FileExists(S) then
  begin
    Ext := ExtractFileExt(S);
    if SameText(Ext, '.yaml') or SameText(Ext, '.yml') then
      Exit(skProject);
    if IsPascalSourceExt(Ext) then
      Exit(skFile);
    raise ENikError.CreateFmt(
      'Cannot use ''%s'' as a source: expected a directory, nik.yaml, a Pascal file (.pas, .pp, .lpr, .dpr) or an https:// URL.', [S]);
  end;
  raise ENikError.CreateFmt('Source ''%s'' does not exist.', [S]);
end;

function SanitizeProgramName(const ARaw: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(ARaw) do
    if ARaw[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.'] then
      Result := Result + ARaw[I]
    else
      Result := Result + '_';
  while (Result <> '') and (Result[1] = '.') do
    Delete(Result, 1, 1);
  if Result = '' then
    Result := 'app';
end;

function YamlQuote(const S: string): string;
begin
  Result := '"' + StringReplace(StringReplace(NormalizeForwardSlashes(S), '\', '\\', [rfReplaceAll]),
    '"', '\"', [rfReplaceAll]) + '"';
end;

function BuildSyntheticManifestText(const AName, AEntryAbs, AFpcVersion: string;
  const AUnitDirsAbs: array of string): string;
var
  I: Integer;
begin
  Result :=
    'schemaVersion: 1' + LineEnding + LineEnding +
    'program:' + LineEnding +
    '  name: ' + AName + LineEnding +
    '  entry: ' + YamlQuote(AEntryAbs) + LineEnding +
    '  toolchain:' + LineEnding +
    '    fpc: ' + AFpcVersion + LineEnding +
    '  build:' + LineEnding +
    '    unitPaths:' + LineEnding;
  for I := 0 to High(AUnitDirsAbs) do
    Result := Result + '      - ' + YamlQuote(AUnitDirsAbs[I]) + LineEnding;
end;

// ---------------------------------------------------------------- trust store

function GetTrustStoreFile: string;
begin
  Result := JoinPath(GetNikrunHomeDir, 'trust.json');
end;

function LoadTrustStore: TJSONObject;
var
  Data: TJSONData;
begin
  Result := nil;
  if FileExists(GetTrustStoreFile) then
  begin
    try
      Data := GetJSON(ReadFileTextUtf8(GetTrustStoreFile));
      if Data is TJSONObject then
        Result := TJSONObject(Data)
      else
        Data.Free;
    except
      Result := nil;
    end;
  end;
  if Result = nil then
    Result := TJSONObject.Create;
  if Result.Find('sources', jtObject) = nil then
    Result.Objects['sources'] := TJSONObject.Create;
end;

function IsSourceTrusted(const ARepoUrl, ATreeIntegrity: string; out AKnownOtherVersion: Boolean): Boolean;
var
  Store: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Result := False;
  AKnownOtherVersion := False;
  Store := LoadTrustStore;
  try
    Arr := Store.Objects['sources'].Find(ARepoUrl, jtArray) as TJSONArray;
    if Arr = nil then
      Exit;
    AKnownOtherVersion := Arr.Count > 0;
    for I := 0 to Arr.Count - 1 do
      if (Arr.Items[I] is TJSONObject) and
         SameText(TJSONObject(Arr.Items[I]).Get('integrity', ''), ATreeIntegrity) then
        Exit(True);
  finally
    Store.Free;
  end;
end;

procedure RememberTrustedSource(const ARepoUrl, ATreeIntegrity, ACommit: string);
var
  Store: TJSONObject;
  Arr: TJSONArray;
  Entry: TJSONObject;
  Known: Boolean;
begin
  if IsSourceTrusted(ARepoUrl, ATreeIntegrity, Known) then
    Exit;
  Store := LoadTrustStore;
  try
    Arr := Store.Objects['sources'].Find(ARepoUrl, jtArray) as TJSONArray;
    if Arr = nil then
    begin
      Arr := TJSONArray.Create;
      Store.Objects['sources'].Add(ARepoUrl, Arr);
    end;
    Entry := TJSONObject.Create;
    Entry.Add('integrity', ATreeIntegrity);
    Entry.Add('commit', ACommit);
    Entry.Add('trustedAt', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', LocalTimeToUniversal(Now)));
    Arr.Add(Entry);
    Store.Integers['version'] := 1;
    EnsureDirExists(ExtractFileDir(GetTrustStoreFile));
    WriteFileTextUtf8(GetTrustStoreFile, Store.FormatJSON);
  finally
    Store.Free;
  end;
end;

procedure RequireTrust(const AOpts: TSourceOptions; const ARepoUrl, ARefLabel, ACommit,
  AIntegrity, AWhat: string);
var
  KnownOther: Boolean;
  Answer: string;
begin
  if not AOpts.ForRun then
    Exit;
  if IsSourceTrusted(ARepoUrl, AIntegrity, KnownOther) then
    Exit;

  if not AOpts.Trust then
  begin
    if not IsInteractiveInput then
      raise ENikError.CreateFmt(
        'Refusing to run untrusted source %s (%s) without a terminal to confirm. ' +
        'Re-run with --trust to accept it, or confirm it once in an interactive terminal.',
        [ARepoUrl, Copy(ACommit, 1, 12)]);

    // The prompt goes to stderr: stdout belongs to the program that is about to run.
    WriteLn(StdErr);
    if KnownOther then
      WriteWarn(Format('%s has changed since you last trusted it.', [ARepoUrl]))
    else
      WriteWarn(Format('%s is not trusted yet.', [ARepoUrl]));
    WriteLn(StdErr, '  Ref     : ' + ARefLabel);
    WriteLn(StdErr, '  Commit  : ' + ACommit);
    WriteLn(StdErr, '  Runs    : ' + AWhat);
    WriteLn(StdErr, '  nik compiles and runs this code natively with your user permissions (no sandbox).');
    Write(StdErr, 'Trust and run it? [y/N] ');
    Answer := '';
    ReadLn(Answer);
    Answer := LowerCase(Trim(Answer));
    if (Answer <> 'y') and (Answer <> 'yes') then
      raise ENikError.Create('Source not trusted; nothing was run.');
  end;
  RememberTrustedSource(ARepoUrl, AIntegrity, ACommit);
end;

// ------------------------------------------------------------------- resolve

function RunCacheRoot: string;
begin
  Result := JoinPath(GetNikrunCacheDir, 'run');
end;

function FindManifestIn(const ADir: string): string;
begin
  Result := JoinPath(ADir, 'nik.yaml');
  if FileExists(Result) then
    Exit;
  Result := JoinPath(ADir, 'nik.yml');
  if FileExists(Result) then
    Exit;
  Result := '';
end;

function DetectInstalledFpc: string;
begin
  if not TryDetectInstalledHostVersion(Result) then
    raise ENikError.Create(
      'No Free Pascal SDK is installed, and a single file has no nik.yaml to pin one. ' +
      'Run ''nik sdk install'' first.');
end;

function WriteSyntheticManifest(const AKeyDir, AName, AEntryAbs: string;
  const AUnitDirsAbs: array of string): string;
begin
  EnsureDirExists(AKeyDir);
  Result := JoinPath(AKeyDir, 'nik.yaml');
  WriteFileTextUtf8(Result,
    BuildSyntheticManifestText(AName, AEntryAbs, DetectInstalledFpc, AUnitDirsAbs));
end;

function ResolveLocalFile(const ASource: string): TResolvedSource;
var
  Abs, Name, KeyDir: string;
begin
  Abs := ExpandFileName(ASource);
  Name := SanitizeProgramName(ChangeFileExt(ExtractFileName(Abs), ''));
  KeyDir := JoinPath(RunCacheRoot, 'file-' + Copy(Sha256StringHex(LowerCase(Abs)), 1, 16));

  Result := Default(TResolvedSource);
  Result.Kind := skFile;
  Result.Display := Abs;
  Result.DefaultOutputName := Name;
  Result.ManifestPath := WriteSyntheticManifest(KeyDir, Name, Abs, [ExtractFileDir(Abs)]);
end;

function ResolveUrl(const ASource: string; const AOpts: TSourceOptions): TResolvedSource;
var
  Parts: TSourceUrlParts;
  Err, Ref, SubPath, Commit, CacheDir, Integrity, Commit40, KeyDir, SrcDir, Staging: string;
  Insp: TGitRepoInspection;
  Names: array of string;
  I: Integer;
  Found: Boolean;
  FullPath, Manifest, RepoName, What: string;
  IsFile: Boolean;
begin
  if not TryParseSourceUrl(ASource, Parts, Err) then
    raise ENikError.Create(Err);

  Ref := '';
  SubPath := '';
  Commit := '';

  if AOpts.Offline then
  begin
    Ref := Parts.ExplicitRef;
    if Parts.RefAndPath <> '' then
      if not TrySplitRefAndPath(Parts.RefAndPath, [], not Parts.IsTree, Ref, SubPath) then
        raise ENikError.CreateFmt('Cannot resolve ''%s'' offline: use a commit id as reference.', [ASource]);
    if not IsHexCommitLike(Ref) then
      raise ENikError.CreateFmt('Cannot resolve ''%s'' offline: only a cached commit id can be used with --offline.', [ASource]);
    Commit := Ref;
    if not FindCachedGitPackageDir(Parts.RepoUrl, Commit, Commit40, CacheDir, Integrity) then
      raise ENikError.CreateFmt('%s @ %s is not in the local package cache (offline mode).', [Parts.RepoUrl, Commit]);
  end
  else
  begin
    Insp := InspectGitRepository(Parts.RepoUrl);
    SetLength(Names, Length(Insp.Refs));
    for I := 0 to High(Insp.Refs) do
      Names[I] := Insp.Refs[I].ShortName;

    if Parts.RefAndPath <> '' then
    begin
      if not TrySplitRefAndPath(Parts.RefAndPath, Names, not Parts.IsTree, Ref, SubPath) then
        raise ENikError.CreateFmt('Cannot find a branch, tag or commit at the start of ''%s'' in %s.',
          [Parts.RefAndPath, Parts.RepoUrl]);
    end
    else
      Ref := Parts.ExplicitRef;

    if Ref = '' then
      Commit := Insp.HeadCommit
    else
    begin
      Found := False;
      for I := 0 to High(Insp.Refs) do
        if Insp.Refs[I].ShortName = Ref then
        begin
          Commit := Insp.Refs[I].CommitSha;
          Found := True;
          Break;
        end;
      if (not Found) and IsHexCommitLike(Ref) then
        Commit := Ref
      else if not Found then
        raise ENikError.CreateFmt('Reference ''%s'' not found in %s.', [Ref, Parts.RepoUrl]);
    end;

    if not IsSafeRelativePath(NormalizeForwardSlashes(SubPath)) and (SubPath <> '') then
      raise ENikError.CreateFmt('Unsafe path ''%s'' in source URL.', [SubPath]);

    if not AOpts.Quiet then
      WriteInfo(Format('Fetching %s @ %s...', [Parts.RepoUrl, Copy(Commit, 1, 12)]));
    EnsureGitPackageCached(Parts.RepoUrl, Commit, '', Commit40, CacheDir, Integrity);
  end;

  if (SubPath <> '') and (not IsSafeRelativePath(NormalizeForwardSlashes(SubPath))) then
    raise ENikError.CreateFmt('Unsafe path ''%s'' in source URL.', [SubPath]);

  // Work copy: the package cache stays immutable, builds write .nik/ and bin/ elsewhere.
  KeyDir := JoinPath(RunCacheRoot, 'url-' + Copy(Sha256StringHex(Parts.RepoUrl), 1, 10) + '-' + Copy(Commit40, 1, 12));
  SrcDir := JoinPath(KeyDir, 'src');
  if not DirectoryExists(SrcDir) then
  begin
    EnsureDirExists(KeyDir);
    Staging := SrcDir + '.tmp' + IntToStr(GetProcessID);
    if DirectoryExists(Staging) then
      DeleteDirectoryRecursive(Staging);
    try
      CopyDirectoryRecursive(CacheDir, Staging);
      MoveDirectoryAtomic(Staging, SrcDir);
    finally
      if DirectoryExists(Staging) then
        DeleteDirectoryRecursive(Staging);
    end;
  end;

  FullPath := SrcDir;
  if SubPath <> '' then
    FullPath := JoinPath(SrcDir, NormalizeNativeSeparators(SubPath));
  IsFile := (SubPath <> '') and FileExists(FullPath);
  if (SubPath <> '') and (not IsFile) and (not DirectoryExists(FullPath)) then
    raise ENikError.CreateFmt('''%s'' does not exist in %s @ %s.', [SubPath, Parts.RepoUrl, Copy(Commit40, 1, 12)]);

  RepoName := SanitizeProgramName(DeriveSuggestedPkgName(Parts.RepoUrl, ''));
  Result := Default(TResolvedSource);
  Result.Kind := skUrl;
  Result.Display := ASource;
  Result.Commit := Commit40;

  if IsFile then
  begin
    if not IsPascalSourceExt(ExtractFileExt(FullPath)) then
      raise ENikError.CreateFmt('''%s'' is not a Pascal source file (.pas, .pp, .lpr, .dpr).', [SubPath]);
    Result.DefaultOutputName := SanitizeProgramName(ChangeFileExt(ExtractFileName(FullPath), ''));
    What := SubPath;
    RequireTrust(AOpts, Parts.RepoUrl, IfThen(Ref = '', '(default branch)', Ref), Commit40, Integrity, What);
    Manifest := FindManifestIn(SrcDir);
    if Manifest <> '' then
    begin
      // The repository's own nik.yaml supplies toolchain, paths and dependencies; the URL picks the entry.
      Result.ManifestPath := Manifest;
      Result.EntryOverride := SubPath;
    end
    else
      Result.ManifestPath := WriteSyntheticManifest(KeyDir, Result.DefaultOutputName, FullPath,
        [ExtractFileDir(FullPath), SrcDir]);
  end
  else
  begin
    Manifest := FindManifestIn(FullPath);
    if Manifest = '' then
      raise ENikError.CreateFmt(
        'No nik.yaml found in %s%s. Point the URL at a Pascal file (…/blob/<ref>/<file>.pas) instead.',
        [Parts.RepoUrl, IfThen(SubPath = '', '', '/' + SubPath)]);
    What := 'program from nik.yaml';
    RequireTrust(AOpts, Parts.RepoUrl, IfThen(Ref = '', '(default branch)', Ref), Commit40, Integrity, What);
    Result.ManifestPath := Manifest;
    Result.DefaultOutputName := RepoName;
  end;
end;

function ResolveSource(const ASource: string; const AOpts: TSourceOptions): TResolvedSource;
begin
  case ClassifySource(ASource) of
    skProject:
      begin
        Result := Default(TResolvedSource);
        Result.Kind := skProject;
        Result.Display := ASource;
        Result.ManifestPath := ASource;
      end;
    skFile: Result := ResolveLocalFile(ASource);
    skUrl: Result := ResolveUrl(ASource, AOpts);
  end;
end;

end.
