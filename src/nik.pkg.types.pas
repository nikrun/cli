unit nik.pkg.types;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, nik.types, nik.manifest.types, nik.pkg.semver;

type
  TLockedPackageKind = (lpkGit, lpkArchive);

  TLockedPackage = record
    Id: string;
    Kind: TLockedPackageKind;
    Url: string;
    Path: string;
    Subpath: string;
    Version: string;
    Rev: string;
    Integrity: string; // 'sha256-<64hex>' for lpkGit directory tree
    Sha256: string;    // '<64hex>' for lpkArchive file bytes
  end;
  TLockedPackageArray = array of TLockedPackage;

  TLockFile = record
    LockVersion: Integer;
    ExistsOnDisk: Boolean;
    FilePath: string;
    Packages: TLockedPackageArray;
  end;

  TGitRemoteRef = record
    RefName: string;
    ShortName: string;
    CommitSha: string;
    IsTag: Boolean;
    IsBranch: Boolean;
    HasSemVer: Boolean;
    SemVer: TSemVer;
  end;
  TGitRemoteRefArray = array of TGitRemoteRef;

  TGitRepoInspection = record
    NormalizedUrl: string;
    HeadCommit: string;
    DefaultBranch: string;
    Refs: TGitRemoteRefArray;
    HasLatestSemVer: Boolean;
    LatestSemVer: TSemVer;
    LatestSemVerCommit: string;
  end;

  TResolvedPackage = record
    Id: string;
    Name: string;
    SourceKind: TDependencySourceKind;
    Url: string;
    Subpath: string;
    Version: string;
    Rev: string;
    IntegrityOrSha256: string;
    RootDir: string;
    Direct: Boolean;
    OverriddenLocally: Boolean;
  end;
  TResolvedPackageArray = array of TResolvedPackage;

  TPackageResolveOptions = record
    Locked: Boolean;
    Offline: Boolean;
    AllowLockWrite: Boolean;
    SoftMissingForLsp: Boolean;
    UpdateAll: Boolean;
    UpdateTargetName: string;
    IncludeTestDeps: Boolean;
  end;

  TPackageResolutionResult = record
    Packages: TResolvedPackageArray;
    UnitPaths: TStringArray;
    IncludePaths: TStringArray;
    LibraryPaths: TStringArray;
    ObjectPaths: TStringArray;
    LinkLibraries: TStringArray;
    ManifestFiles: TStringArray;
    MissingPackages: TStringArray;
    LockUpdated: Boolean;
  end;

function HasExplicitUrlScheme(const S: string): Boolean;
function HasExplicitLocalPathPrefix(const S: string): Boolean;
function ValidateHexSha256(const ARaw: string; out ANormHex: string): Boolean;
function ValidateCleanSubpath(const ARaw: string; out AClean: string; out AErrMsg: string): Boolean;

function NormalizeRemoteUrlBase(const ARawUrl: string; AStripDotGit: Boolean;
  out ANormUrl: string; out AErrMsg: string): Boolean;
function BuildGitPkgId(const ANormRepoUrl, ACleanSubpath: string): string;
function BuildArchivePkgId(const ANormUrlOrRelPath, ACleanSubpath: string): string;
function DeriveSuggestedPkgName(const ANormUrl, ACleanSubpath: string): string;

implementation

uses
  nik.paths;

function StartsWithCI(const AText, APrefix: string): Boolean;
begin
  Result := (Length(AText) >= Length(APrefix)) and
            SameText(Copy(AText, 1, Length(APrefix)), APrefix);
end;

function EndsWithCI(const AText, ASuffix: string): Boolean;
begin
  Result := (Length(AText) >= Length(ASuffix)) and
            SameText(Copy(AText, Length(AText) - Length(ASuffix) + 1, Length(ASuffix)), ASuffix);
end;

function HasExplicitUrlScheme(const S: string): Boolean;
var
  T: string;
begin
  T := Trim(S);
  Result := StartsWithCI(T, 'https://') or
            StartsWithCI(T, 'http://') or
            StartsWithCI(T, 'ssh://') or
            StartsWithCI(T, 'file://');
end;

function HasExplicitLocalPathPrefix(const S: string): Boolean;
var
  T: string;
begin
  T := Trim(S);
  if T = '' then
    Exit(False);
  if (T = '.') or (T = '..') then
    Exit(True);
  if (Copy(T, 1, 2) = './') or (Copy(T, 1, 2) = '.\') or
     (Copy(T, 1, 3) = '../') or (Copy(T, 1, 3) = '..\') then
    Exit(True);
  if (T[1] = '/') or (T[1] = '\') then
    Exit(True);
  if (Length(T) >= 3) and (T[2] = ':') and ((T[3] = '/') or (T[3] = '\')) and
     (((T[1] >= 'A') and (T[1] <= 'Z')) or ((T[1] >= 'a') and (T[1] <= 'z'))) then
    Exit(True);
  Result := False;
end;

function ValidateHexSha256(const ARaw: string; out ANormHex: string): Boolean;
var
  S: string;
  I: Integer;
  Ch: Char;
begin
  Result := False;
  ANormHex := '';
  S := LowerCase(Trim(ARaw));
  if StartsWithCI(S, 'sha256-') then
    Delete(S, 1, 7)
  else if StartsWithCI(S, 'sha256:') then
    Delete(S, 1, 7);

  if Length(S) <> 64 then
    Exit;
  for I := 1 to 64 do
  begin
    Ch := S[I];
    if not (((Ch >= '0') and (Ch <= '9')) or ((Ch >= 'a') and (Ch <= 'f'))) then
      Exit;
  end;
  ANormHex := S;
  Result := True;
end;

function ValidateCleanSubpath(const ARaw: string; out AClean: string; out AErrMsg: string): Boolean;
var
  Norm, Seg: string;
  I, StartIdx: Integer;
begin
  Result := False;
  AClean := '';
  AErrMsg := '';
  Norm := NormalizeForwardSlashes(Trim(ARaw));
  while (Length(Norm) >= 2) and (Copy(Norm, 1, 2) = './') do
    Delete(Norm, 1, 2);

  if Norm = '' then
  begin
    AErrMsg := '''subpath'' cannot be empty.';
    Exit;
  end;

  if (Norm[1] = '/') or ((Length(Norm) >= 2) and (Norm[2] = ':')) then
  begin
    AErrMsg := Format('''subpath'' must be a relative directory inside the package, got ''%s''.', [ARaw]);
    Exit;
  end;

  while (Length(Norm) > 0) and (Norm[Length(Norm)] = '/') do
    Delete(Norm, Length(Norm), 1);

  if Norm = '' then
  begin
    AErrMsg := '''subpath'' cannot point to root ''/''.';
    Exit;
  end;

  StartIdx := 1;
  for I := 1 to Length(Norm) + 1 do
  begin
    if (I > Length(Norm)) or (Norm[I] = '/') then
    begin
      Seg := Copy(Norm, StartIdx, I - StartIdx);
      if (Seg = '') or (Seg = '.') or (Seg = '..') then
      begin
        AErrMsg := Format('''subpath'' cannot contain empty, ''.'', or ''..'' segments: ''%s''.', [ARaw]);
        Exit;
      end;
      StartIdx := I + 1;
    end;
  end;

  AClean := Norm;
  Result := True;
end;

function NormalizeRemoteUrlBase(const ARawUrl: string; AStripDotGit: Boolean;
  out ANormUrl: string; out AErrMsg: string): Boolean;
var
  S, Scheme, Rest, Authority, PathPart: string;
  SchemeSep, SlashPos: Integer;
begin
  Result := False;
  ANormUrl := '';
  AErrMsg := '';
  S := Trim(ARawUrl);
  if S = '' then
  begin
    AErrMsg := 'URL cannot be empty.';
    Exit;
  end;

  SchemeSep := Pos('://', S);
  if SchemeSep <= 1 then
  begin
    AErrMsg := Format('URL ''%s'' must start with https://, http://, or ssh://.', [S]);
    Exit;
  end;

  Scheme := LowerCase(Copy(S, 1, SchemeSep - 1));
  if (Scheme <> 'https') and (Scheme <> 'http') and (Scheme <> 'ssh') and (Scheme <> 'file') then
  begin
    AErrMsg := Format('Unsupported URL scheme ''%s://'' in ''%s'' (expected https://, http://, or ssh://).',
      [Scheme, S]);
    Exit;
  end;

  Rest := Copy(S, SchemeSep + 3, MaxInt);
  if Scheme = 'file' then
  begin
    // RFC 8089: file:///abs/path or file://localhost/abs/path; reject relative file://../foo
    if (Rest = '') or ((Rest[1] <> '/') and (not StartsWithCI(Rest, 'localhost/'))) then
    begin
      AErrMsg := Format(
        'Relative file:// URLs (''%s'') are invalid. Use ''./'' or ''../'' directly for local paths.',
        [S]);
      Exit;
    end;
    PathPart := NormalizeForwardSlashes(Rest);
    while (Length(PathPart) > 1) and (PathPart[Length(PathPart)] = '/') do
      Delete(PathPart, Length(PathPart), 1);
    if AStripDotGit and EndsWithCI(PathPart, '.git') and (Length(PathPart) > 4) then
      Delete(PathPart, Length(PathPart) - 3, 4);
    ANormUrl := 'file://' + PathPart;
    Exit(True);
  end;

  SlashPos := Pos('/', Rest);
  if SlashPos <= 1 then
  begin
    AErrMsg := Format('URL ''%s'' must include a host and path (e.g. https://github.com/owner/repo).', [S]);
    Exit;
  end;

  Authority := Copy(Rest, 1, SlashPos - 1);
  if Pos('@', Authority) > 0 then
  begin
    if (Scheme = 'ssh') and (Pos(':', Copy(Authority, 1, Pos('@', Authority) - 1)) = 0) then
      Authority := Copy(Authority, 1, Pos('@', Authority)) +
                   LowerCase(Copy(Authority, Pos('@', Authority) + 1, MaxInt))
    else
    begin
      AErrMsg := Format('Embedding credentials in nik.yaml URL ''%s'' is disallowed for security.', [S]);
      Exit;
    end;
  end
  else
    Authority := LowerCase(Authority);

  PathPart := Copy(Rest, SlashPos, MaxInt);
  while (Length(PathPart) > 1) and (PathPart[Length(PathPart)] = '/') do
    Delete(PathPart, Length(PathPart), 1);

  if (PathPart = '') or (PathPart = '/') then
  begin
    AErrMsg := Format('URL ''%s'' is missing a repository or archive path.', [S]);
    Exit;
  end;

  if AStripDotGit and EndsWithCI(PathPart, '.git') and (Length(PathPart) > 5) then
    Delete(PathPart, Length(PathPart) - 3, 4);

  ANormUrl := Scheme + '://' + Authority + PathPart;
  Result := True;
end;

function BuildGitPkgId(const ANormRepoUrl, ACleanSubpath: string): string;
begin
  if ACleanSubpath <> '' then
    Result := ANormRepoUrl + '#' + ACleanSubpath
  else
    Result := ANormRepoUrl;
end;

function BuildArchivePkgId(const ANormUrlOrRelPath, ACleanSubpath: string): string;
begin
  if ACleanSubpath <> '' then
    Result := ANormUrlOrRelPath + '#' + ACleanSubpath
  else
    Result := ANormUrlOrRelPath;
end;

function DeriveSuggestedPkgName(const ANormUrl, ACleanSubpath: string): string;
var
  Candidate: string;
  SlashPos: Integer;
begin
  if ACleanSubpath <> '' then
    Candidate := ACleanSubpath
  else
    Candidate := ANormUrl;

  while (Length(Candidate) > 0) and (Candidate[Length(Candidate)] = '/') do
    Delete(Candidate, Length(Candidate), 1);

  SlashPos := LastDelimiter('/', Candidate);
  if SlashPos > 0 then
    Candidate := Copy(Candidate, SlashPos + 1, MaxInt);

  if EndsWithCI(Candidate, '.tar.gz') then
    Delete(Candidate, Length(Candidate) - 6, 7)
  else if EndsWithCI(Candidate, '.tgz') or EndsWithCI(Candidate, '.zip') or EndsWithCI(Candidate, '.git') then
    Delete(Candidate, Length(Candidate) - 3, 4);

  if Candidate = '' then
    Candidate := 'package';
  Result := LowerCase(Candidate);
end;

end.
