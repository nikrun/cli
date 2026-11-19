unit nik.pkg.fetch;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nik.types, nik.pkg.types, nik.pkg.semver;

function InspectGitRepository(const ANormRepoUrl: string): TGitRepoInspection;

function FindCachedGitPackageDir(const ANormRepoUrl, ACommitOrPrefix: string;
  out AResolvedCommit40, ACacheDir, AIntegrity: string): Boolean;

procedure EnsureGitPackageCached(const ANormRepoUrl, ACommitOrPrefix, AExpectedIntegrity: string;
  out AResolvedCommit40, ACacheDir, AActualIntegrity: string);

function FindCachedArchiveDir(const AExpectedSha256: string; out ACacheDir: string): Boolean;

procedure EnsureArchivePackageCached(const ASourceUrlOrLocalPath: string; AIsLocalFile: Boolean;
  const AExpectedSha256: string; out AActualSha256, ACacheDir: string);

implementation

uses
  Process, fpjson, jsonparser,
  nik.paths, nik.fs, nik.http, nik.sha256, nik.archive, nik.pkg.lock;

var
  GStagingSeq: QWord = 0;

function NextStagingDir(const APrefix: string): string;
begin
  Inc(GStagingSeq);
  Result := JoinPath(GetNikrunPkgCacheDir,
    Format('.staging-%s-%d-%d-%d', [APrefix, GetProcessID, GetTickCount64, GStagingSeq]));
  if DirectoryExists(Result) then
    DeleteDirectoryRecursive(Result);
  EnsureDirExists(Result);
end;

function StartsWithCI(const AText, APrefix: string): Boolean;
begin
  Result := (Length(AText) >= Length(APrefix)) and
            SameText(Copy(AText, 1, Length(APrefix)), APrefix);
end;

function MakeRepoSlug(const ANormRepoUrl: string): string;
var
  Clean, HashPart: string;
  SchemePos, I: Integer;
  Ch: Char;
begin
  Clean := ANormRepoUrl;
  SchemePos := Pos('://', Clean);
  if SchemePos > 0 then
    Delete(Clean, 1, SchemePos + 2);
  while (Length(Clean) > 0) and (Clean[1] = '/') do
    Delete(Clean, 1, 1);

  Result := '';
  for I := 1 to Length(Clean) do
  begin
    Ch := Clean[I];
    if ((Ch >= 'a') and (Ch <= 'z')) or
       ((Ch >= 'A') and (Ch <= 'Z')) or
       ((Ch >= '0') and (Ch <= '9')) or
       (Ch = '.') or (Ch = '-') then
      Result := Result + LowerCase(Ch)
    else
      Result := Result + '_';
    if Length(Result) >= 44 then
      Break;
  end;
  if Result = '' then
    Result := 'repo';

  HashPart := Copy(Sha256StringHex(RawByteString(ANormRepoUrl)), 1, 12);
  Result := Result + '-' + HashPart;
end;

function GetGitRepoCacheBaseDir(const ANormRepoUrl: string): string;
begin
  Result := JoinPath(JoinPath(GetNikrunPkgCacheDir, 'git'), MakeRepoSlug(ANormRepoUrl));
end;

procedure WriteMarkerFile(const ACacheDir, AIntegrity, ASha256: string);
var
  Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    if AIntegrity <> '' then
      Obj.Add('integrity', AIntegrity);
    if ASha256 <> '' then
      Obj.Add('sha256', ASha256);
    WriteFileTextUtf8(JoinPath(ACacheDir, NIK_PKG_MARKER), Obj.AsJSON);
  finally
    Obj.Free;
  end;
end;

function ReadMarkerField(const ACacheDir, AField: string): string;
var
  MarkerPath: string;
  Data: TJSONData;
  Obj: TJSONObject;
begin
  Result := '';
  MarkerPath := JoinPath(ACacheDir, NIK_PKG_MARKER);
  if not FileExists(MarkerPath) then
    Exit;
  try
    Data := GetJSON(ReadFileTextUtf8(MarkerPath));
    try
      if Data is TJSONObject then
      begin
        Obj := TJSONObject(Data);
        Result := Obj.Get(AField, '');
      end;
    finally
      Data.Free;
    end;
  except
    Result := '';
  end;
end;

procedure UpsertRemoteRef(var ARefs: TGitRemoteRefArray; const ASha, ARefName: string; APeeled: Boolean);
var
  I, N: Integer;
  CleanRef, ShortStr: string;
  IsTag, IsBranch: Boolean;
  ParsedVer: TSemVer;
begin
  if Length(ASha) <> 40 then
    Exit;

  CleanRef := Trim(ARefName);
  if APeeled then
  begin
    for I := 0 to High(ARefs) do
      if ARefs[I].RefName = CleanRef then
      begin
        ARefs[I].CommitSha := LowerCase(ASha);
        Exit;
      end;
  end;

  for I := 0 to High(ARefs) do
    if ARefs[I].RefName = CleanRef then
      Exit;

  IsTag := StartsWithCI(CleanRef, 'refs/tags/');
  IsBranch := StartsWithCI(CleanRef, 'refs/heads/');
  if IsTag then
    ShortStr := Copy(CleanRef, Length('refs/tags/') + 1, MaxInt)
  else if IsBranch then
    ShortStr := Copy(CleanRef, Length('refs/heads/') + 1, MaxInt)
  else
    ShortStr := CleanRef;

  N := Length(ARefs);
  SetLength(ARefs, N + 1);
  ARefs[N] := Default(TGitRemoteRef);
  ARefs[N].RefName := CleanRef;
  ARefs[N].ShortName := ShortStr;
  ARefs[N].CommitSha := LowerCase(ASha);
  ARefs[N].IsTag := IsTag;
  ARefs[N].IsBranch := IsBranch;
  if IsTag and TryParseSemVer(ShortStr, ParsedVer, True) then
  begin
    ARefs[N].HasSemVer := True;
    ARefs[N].SemVer := ParsedVer;
  end;
end;

procedure FinalizeRepoInspection(var AInfo: TGitRepoInspection);
var
  I: Integer;
  BestSet: Boolean;
begin
  BestSet := False;
  for I := 0 to High(AInfo.Refs) do
  begin
    if AInfo.Refs[I].RefName = 'HEAD' then
      AInfo.HeadCommit := AInfo.Refs[I].CommitSha;

    if AInfo.Refs[I].IsTag and AInfo.Refs[I].HasSemVer and (AInfo.Refs[I].SemVer.PreRelease = '') then
    begin
      if (not BestSet) or (CompareSemVer(AInfo.Refs[I].SemVer, AInfo.LatestSemVer) > 0) then
      begin
        BestSet := True;
        AInfo.HasLatestSemVer := True;
        AInfo.LatestSemVer := AInfo.Refs[I].SemVer;
        AInfo.LatestSemVerCommit := AInfo.Refs[I].CommitSha;
      end;
    end;
  end;

  if (AInfo.DefaultBranch <> '') and (AInfo.HeadCommit = '') then
  begin
    for I := 0 to High(AInfo.Refs) do
      if AInfo.Refs[I].IsBranch and (AInfo.Refs[I].ShortName = AInfo.DefaultBranch) then
      begin
        AInfo.HeadCommit := AInfo.Refs[I].CommitSha;
        Break;
      end;
  end;
end;

procedure ExtractSymrefDefaultBranch(const ACaps: string; var ADefaultBranch: string);
const
  KEY = 'symref=HEAD:refs/heads/';
var
  P, EndPos: Integer;
  Sub: string;
begin
  P := Pos(KEY, ACaps);
  if P <= 0 then
    Exit;
  Sub := Copy(ACaps, P + Length(KEY), MaxInt);
  EndPos := 1;
  while (EndPos <= Length(Sub)) and (Sub[EndPos] <> ' ') and (Sub[EndPos] <> #9) and
        (Sub[EndPos] <> #10) and (Sub[EndPos] <> #13) and (Sub[EndPos] <> #0) do
    Inc(EndPos);
  ADefaultBranch := Copy(Sub, 1, EndPos - 1);
end;

function ParseGitSmartHttpRefs(const ABody: string; var AInfo: TGitRepoInspection): Boolean;
var
  PosIdx, BodyLen, PktLen, Code, SpacePos, NulPos: Integer;
  HexLen, Payload, ShaStr, Rest, RefPart, CapsPart: string;
  SawAnyPacket, Peeled: Boolean;
begin
  Result := False;
  SawAnyPacket := False;
  BodyLen := Length(ABody);
  PosIdx := 1;

  while PosIdx + 3 <= BodyLen do
  begin
    HexLen := Copy(ABody, PosIdx, 4);
    Val('$' + HexLen, PktLen, Code);
    if Code <> 0 then
      Exit(False);

    if PktLen = 0 then
    begin
      SawAnyPacket := True;
      Inc(PosIdx, 4);
      Continue;
    end;

    if (PktLen < 4) or (PosIdx + PktLen - 1 > BodyLen) then
      Exit(False);

    SawAnyPacket := True;
    Payload := Copy(ABody, PosIdx + 4, PktLen - 4);
    Inc(PosIdx, PktLen);

    while (Length(Payload) > 0) and ((Payload[Length(Payload)] = #10) or (Payload[Length(Payload)] = #13)) do
      Delete(Payload, Length(Payload), 1);

    if (Payload = '') or (Payload[1] = '#') then
      Continue;

    NulPos := Pos(#0, Payload);
    if NulPos > 0 then
    begin
      CapsPart := Copy(Payload, NulPos + 1, MaxInt);
      ExtractSymrefDefaultBranch(CapsPart, AInfo.DefaultBranch);
      Payload := Copy(Payload, 1, NulPos - 1);
    end;

    SpacePos := Pos(' ', Payload);
    if SpacePos <> 41 then
      Continue;

    ShaStr := Copy(Payload, 1, 40);
    if not IsHexCommitSpecifier(ShaStr) then
      Continue;

    Rest := Trim(Copy(Payload, 42, MaxInt));
    Peeled := False;
    if (Length(Rest) > 3) and (Copy(Rest, Length(Rest) - 2, 3) = '^{}') then
    begin
      Peeled := True;
      RefPart := Copy(Rest, 1, Length(Rest) - 3);
    end
    else
      RefPart := Rest;

    UpsertRemoteRef(AInfo.Refs, ShaStr, RefPart, Peeled);
  end;

  Result := SawAnyPacket;
end;

function RunGitCapture(const AWorkDir: string; const AArgs: array of string;
  out AStdOut, AStdErr: string): Integer;
var
  GitBin: string;
  Proc: TProcess;
  OutMem, ErrMem: TMemoryStream;
  Buf: array[0..8191] of Byte;
  N, I: Integer;
  RawOut, RawErr: RawByteString;
begin
  AStdOut := '';
  AStdErr := '';
  GitBin := FindExecutableInPath('git');
  if GitBin = '' then
    raise ENikError.Create('Git executable not found in PATH (required for non-HTTP or custom Git servers).');

  Proc := TProcess.Create(nil);
  OutMem := TMemoryStream.Create;
  ErrMem := TMemoryStream.Create;
  try
    Proc.Executable := GitBin;
    if AWorkDir <> '' then
      Proc.CurrentDirectory := AWorkDir;
    Proc.Parameters.Add('-c');
    Proc.Parameters.Add('core.autocrlf=false');
    Proc.Parameters.Add('-c');
    Proc.Parameters.Add('credential.interactive=never');
    for I := Low(AArgs) to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);

    // Copy current environment + enforce non-interactive GIT_TERMINAL_PROMPT=0
    for I := 1 to GetEnvironmentVariableCount do
      Proc.Environment.Add(GetEnvironmentString(I));
    Proc.Environment.Add('GIT_TERMINAL_PROMPT=0');

    Proc.Options := [poUsePipes, poNoConsole];
    Proc.Execute;

    while Proc.Running do
    begin
      while Proc.Output.NumBytesAvailable > 0 do
      begin
        N := Proc.Output.Read(Buf[0], SizeOf(Buf));
        if N > 0 then OutMem.WriteBuffer(Buf[0], N);
      end;
      while Proc.Stderr.NumBytesAvailable > 0 do
      begin
        N := Proc.Stderr.Read(Buf[0], SizeOf(Buf));
        if N > 0 then ErrMem.WriteBuffer(Buf[0], N);
      end;
      Sleep(5);
    end;

    repeat
      N := Proc.Output.Read(Buf[0], SizeOf(Buf));
      if N > 0 then OutMem.WriteBuffer(Buf[0], N);
    until N = 0;
    repeat
      N := Proc.Stderr.Read(Buf[0], SizeOf(Buf));
      if N > 0 then ErrMem.WriteBuffer(Buf[0], N);
    until N = 0;

    Result := Proc.ExitStatus;
    SetLength(RawOut, OutMem.Size);
    if OutMem.Size > 0 then
    begin
      OutMem.Position := 0;
      OutMem.ReadBuffer(RawOut[1], OutMem.Size);
    end;
    SetLength(RawErr, ErrMem.Size);
    if ErrMem.Size > 0 then
    begin
      ErrMem.Position := 0;
      ErrMem.ReadBuffer(RawErr[1], ErrMem.Size);
    end;
    AStdOut := string(RawOut);
    AStdErr := Trim(string(RawErr));
  finally
    ErrMem.Free;
    OutMem.Free;
    Proc.Free;
  end;
end;

function ResolveFileUrlToGitPath(const ANormRepoUrl: string): string;
var
  Rest: string;
begin
  Result := ANormRepoUrl;
  if not StartsWithCI(ANormRepoUrl, 'file://') then
    Exit;
  Rest := Copy(ANormRepoUrl, 8, MaxInt);
  if StartsWithCI(Rest, 'localhost/') then
    Delete(Rest, 1, 9);
  {$IFDEF WINDOWS}
  if (Length(Rest) >= 3) and (Rest[1] = '/') and (Rest[3] = ':') then
    Delete(Rest, 1, 1);
  {$ENDIF}
  Result := NormalizeNativeSeparators(Rest);
  if (not DirectoryExists(Result)) and DirectoryExists(Result + '.git') then
    Result := Result + '.git';
end;

function TryInspectViaGitCli(const ANormRepoUrl: string; var AInfo: TGitRepoInspection;
  out AErrMsg: string): Boolean;
var
  Target, OutText, ErrText, Line, LeftPart, RightPart: string;
  Lines: TStringList;
  I, TabPos: Integer;
  Peeled: Boolean;
begin
  Result := False;
  AErrMsg := '';
  Target := ResolveFileUrlToGitPath(ANormRepoUrl);
  try
    if RunGitCapture('', ['ls-remote', '--symref', Target], OutText, ErrText) <> 0 then
    begin
      AErrMsg := ErrText;
      Exit(False);
    end;
  except
    on E: Exception do
    begin
      AErrMsg := E.Message;
      Exit(False);
    end;
  end;

  Lines := TStringList.Create;
  try
    Lines.Text := OutText;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Line = '' then
        Continue;
      TabPos := Pos(#9, Line);
      if TabPos <= 0 then
        TabPos := Pos(' ', Line);
      if TabPos <= 0 then
        Continue;

      LeftPart := Trim(Copy(Line, 1, TabPos - 1));
      RightPart := Trim(Copy(Line, TabPos + 1, MaxInt));

      if StartsWithCI(LeftPart, 'ref: refs/heads/') and (RightPart = 'HEAD') then
      begin
        AInfo.DefaultBranch := Copy(LeftPart, Length('ref: refs/heads/') + 1, MaxInt);
        Continue;
      end;

      if (Length(LeftPart) = 40) and IsHexCommitSpecifier(LeftPart) then
      begin
        Peeled := False;
        if (Length(RightPart) > 3) and (Copy(RightPart, Length(RightPart) - 2, 3) = '^{}') then
        begin
          Peeled := True;
          RightPart := Copy(RightPart, 1, Length(RightPart) - 3);
        end;
        UpsertRemoteRef(AInfo.Refs, LeftPart, RightPart, Peeled);
      end;
    end;
  finally
    Lines.Free;
  end;

  Result := True;
end;

function InspectGitRepository(const ANormRepoUrl: string): TGitRepoInspection;
var
  SmartBody, FallbackErr, HttpErr: string;
  UsedSmartHttp: Boolean;
begin
  Result := Default(TGitRepoInspection);
  Result.NormalizedUrl := ANormRepoUrl;
  UsedSmartHttp := False;
  HttpErr := '';

  if StartsWithCI(ANormRepoUrl, 'https://') or StartsWithCI(ANormRepoUrl, 'http://') then
  begin
    try
      SmartBody := HttpGetText(ANormRepoUrl + '.git/info/refs?service=git-upload-pack');
      UsedSmartHttp := ParseGitSmartHttpRefs(SmartBody, Result);
    except
      on E: Exception do
        HttpErr := E.Message;
    end;

    if not UsedSmartHttp then
    begin
      try
        SmartBody := HttpGetText(ANormRepoUrl + '/info/refs?service=git-upload-pack');
        UsedSmartHttp := ParseGitSmartHttpRefs(SmartBody, Result);
      except
        on E: Exception do
          if HttpErr = '' then
            HttpErr := E.Message;
      end;
    end;
  end;

  if not UsedSmartHttp then
  begin
    if not TryInspectViaGitCli(ANormRepoUrl, Result, FallbackErr) then
    begin
      if HttpErr <> '' then
        raise ENikError.CreateFmt('Failed to query Git repository ''%s'': %s', [ANormRepoUrl, HttpErr])
      else
        raise ENikError.CreateFmt('Failed to query Git repository ''%s'': %s', [ANormRepoUrl, FallbackErr]);
    end;
  end;

  FinalizeRepoInspection(Result);
end;

{$PUSH}
{$WARN SYMBOL_PLATFORM OFF}
function FindCachedGitPackageDir(const ANormRepoUrl, ACommitOrPrefix: string;
  out AResolvedCommit40, ACacheDir, AIntegrity: string): Boolean;
var
  RepoCacheBase, PrefixLower, CandidateDir, MarkerIntegrity: string;
  Rec: TSearchRec;
begin
  Result := False;
  AResolvedCommit40 := '';
  ACacheDir := '';
  AIntegrity := '';

  PrefixLower := LowerCase(Trim(ACommitOrPrefix));
  if not IsHexCommitSpecifier(PrefixLower) then
    Exit;

  RepoCacheBase := GetGitRepoCacheBaseDir(ANormRepoUrl);
  if not DirectoryExists(RepoCacheBase) then
    Exit;

  if Length(PrefixLower) = 40 then
  begin
    CandidateDir := JoinPath(RepoCacheBase, PrefixLower);
    MarkerIntegrity := ReadMarkerField(CandidateDir, 'integrity');
    if MarkerIntegrity <> '' then
    begin
      AResolvedCommit40 := PrefixLower;
      ACacheDir := CandidateDir;
      AIntegrity := MarkerIntegrity;
      Exit(True);
    end;
    Exit(False);
  end;

  if FindFirst(IncludeTrailingPathDelimiter(RepoCacheBase) + AllFilesMask, faDirectory, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        if ((Rec.Attr and faDirectory) <> 0) and (Length(Rec.Name) = 40) and
           StartsWithCI(Rec.Name, PrefixLower) then
        begin
          CandidateDir := IncludeTrailingPathDelimiter(RepoCacheBase) + Rec.Name;
          MarkerIntegrity := ReadMarkerField(CandidateDir, 'integrity');
          if MarkerIntegrity <> '' then
          begin
            AResolvedCommit40 := LowerCase(Rec.Name);
            ACacheDir := CandidateDir;
            AIntegrity := MarkerIntegrity;
            Exit(True);
          end;
        end;
      until SysUtils.FindNext(Rec) <> 0;
    finally
      SysUtils.FindClose(Rec);
    end;
  end;
end;
{$POP}

function TryBuildForgeArchiveUrl(const ANormRepoUrl, ACommitOrPrefix: string; out AArchiveUrl: string): Boolean;
var
  SchemeSep, SlashPos: Integer;
  Scheme, Rest, Host, PathPart: string;
begin
  Result := False;
  AArchiveUrl := '';
  SchemeSep := Pos('://', ANormRepoUrl);
  if SchemeSep <= 0 then
    Exit;
  Scheme := LowerCase(Copy(ANormRepoUrl, 1, SchemeSep - 1));
  if (Scheme <> 'https') and (Scheme <> 'http') then
    Exit;

  Rest := Copy(ANormRepoUrl, SchemeSep + 3, MaxInt);
  SlashPos := Pos('/', Rest);
  if SlashPos <= 1 then
    Exit;

  Host := LowerCase(Copy(Rest, 1, SlashPos - 1));
  PathPart := Copy(Rest, SlashPos, MaxInt);

  if Host = 'github.com' then
  begin
    AArchiveUrl := Scheme + '://' + Host + PathPart + '/archive/' + ACommitOrPrefix + '.zip';
    Exit(True);
  end;

  if (Host = 'gitlab.com') or (Pos('gitlab.', Host) > 0) then
  begin
    AArchiveUrl := Scheme + '://' + Host + PathPart + '/-/archive/' + ACommitOrPrefix + '/archive.zip';
    Exit(True);
  end;

  if (Host = 'codeberg.org') or (Pos('gitea.', Host) > 0) or (Pos('forgejo.', Host) > 0) then
  begin
    AArchiveUrl := Scheme + '://' + Host + PathPart + '/archive/' + ACommitOrPrefix + '.zip';
    Exit(True);
  end;
end;

{$PUSH}
{$WARN SYMBOL_PLATFORM OFF}
function InspectSingleTopFolderSuffix40(const AExtractedDir: string): string;
var
  Rec: TSearchRec;
  DashPos: Integer;
  Tail: string;
begin
  Result := '';
  if FindFirst(IncludeTrailingPathDelimiter(AExtractedDir) + AllFilesMask, faDirectory, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') or SameText(Rec.Name, '__MACOSX') then
          Continue;
        if (Rec.Attr and faDirectory) <> 0 then
        begin
          DashPos := LastDelimiter('-', Rec.Name);
          if DashPos > 0 then
          begin
            Tail := Copy(Rec.Name, DashPos + 1, MaxInt);
            if (Length(Tail) = 40) and IsHexCommitSpecifier(Tail) then
              Exit(LowerCase(Tail));
          end;
        end;
      until SysUtils.FindNext(Rec) <> 0;
    finally
      SysUtils.FindClose(Rec);
    end;
  end;
end;
{$POP}

function TryFetchGitViaForgeArchive(const ANormRepoUrl, ACommitOrPrefix, AStagingTreeDir: string;
  out AFullCommit40: string): Boolean;
var
  ArchiveUrl, TempZipPath, Detected40: string;
begin
  Result := False;
  AFullCommit40 := '';
  if not TryBuildForgeArchiveUrl(ANormRepoUrl, ACommitOrPrefix, ArchiveUrl) then
    Exit;

  TempZipPath := AStagingTreeDir + '.zip';
  try
    try
      HttpDownloadFile(ArchiveUrl, TempZipPath);
    except
      if FileExists(TempZipPath) then
        SysUtils.DeleteFile(TempZipPath);
      Exit(False);
    end;

    // Inspect outer <repo>-<40sha>/ folder before unwrapping so short commit prefixes resolve to 40-char SHA
    ExtractPackageArchive(TempZipPath, AStagingTreeDir, False);
    Detected40 := InspectSingleTopFolderSuffix40(AStagingTreeDir);
    if Length(ACommitOrPrefix) = 40 then
      AFullCommit40 := LowerCase(ACommitOrPrefix)
    else if (Length(Detected40) = 40) and StartsWithCI(Detected40, ACommitOrPrefix) then
      AFullCommit40 := Detected40
    else
    begin
      // Cannot confirm full 40-char commit SHA from archive wrapper; let git CLI fallback resolve it
      DeleteDirectoryRecursive(AStagingTreeDir);
      EnsureDirExists(AStagingTreeDir);
      Exit(False);
    end;

    // Now unwrap single root folder cleanly
    DeleteDirectoryRecursive(AStagingTreeDir);
    EnsureDirExists(AStagingTreeDir);
    ExtractPackageArchive(TempZipPath, AStagingTreeDir, True);
    Result := True;
  finally
    if FileExists(TempZipPath) then
      SysUtils.DeleteFile(TempZipPath);
  end;
end;

procedure FetchGitViaCli(const ANormRepoUrl, ACommitOrPrefix, AStagingTreeDir: string;
  out AFullCommit40: string);
var
  Target, OutText, ErrText: string;
  FetchOk: Boolean;
begin
  Target := ResolveFileUrlToGitPath(ANormRepoUrl);
  FetchOk := False;

  if RunGitCapture(AStagingTreeDir, ['init', '-q'], OutText, ErrText) = 0 then
  begin
    if RunGitCapture(AStagingTreeDir, ['remote', 'add', 'origin', Target], OutText, ErrText) = 0 then
    begin
      if RunGitCapture(AStagingTreeDir, ['fetch', '--depth', '1', 'origin', ACommitOrPrefix], OutText, ErrText) = 0 then
      begin
        if RunGitCapture(AStagingTreeDir, ['checkout', '-q', '--detach', 'FETCH_HEAD'], OutText, ErrText) = 0 then
          FetchOk := True;
      end;
    end;
  end;

  if not FetchOk then
  begin
    DeleteDirectoryRecursive(AStagingTreeDir);
    EnsureDirExists(AStagingTreeDir);
    if RunGitCapture('', ['clone', '-q', '--no-checkout', Target, AStagingTreeDir], OutText, ErrText) <> 0 then
      raise ENikError.CreateFmt('Failed to clone Git dependency ''%s'': %s', [ANormRepoUrl, ErrText]);
    if RunGitCapture(AStagingTreeDir, ['checkout', '-q', '--detach', ACommitOrPrefix], OutText, ErrText) <> 0 then
      raise ENikError.CreateFmt('Commit ''%s'' not found in ''%s'': %s', [ACommitOrPrefix, ANormRepoUrl, ErrText]);
  end;

  if RunGitCapture(AStagingTreeDir, ['rev-parse', 'HEAD'], OutText, ErrText) <> 0 then
    raise ENikError.CreateFmt('Failed to resolve HEAD commit for ''%s'': %s', [ANormRepoUrl, ErrText]);

  AFullCommit40 := LowerCase(Trim(OutText));
  if (Length(AFullCommit40) <> 40) or (not IsHexCommitSpecifier(AFullCommit40)) then
    raise ENikError.CreateFmt('Unexpected commit hash ''%s'' resolved from ''%s''.', [AFullCommit40, ANormRepoUrl]);

  DeleteDirectoryRecursive(JoinPath(AStagingTreeDir, '.git'));
end;

procedure EnsureGitPackageCached(const ANormRepoUrl, ACommitOrPrefix, AExpectedIntegrity: string;
  out AResolvedCommit40, ACacheDir, AActualIntegrity: string);
var
  StagingDir, FinalDir, ExistingIntegrity: string;
begin
  // Last line of defence before the value is handed to git or used as a cache directory name.
  if not IsHexCommitSpecifier(ACommitOrPrefix) then
    raise ENikError.CreateFmt('Invalid commit ''%s'' for Git dependency ''%s'' (expected 7 to 40 hexadecimal digits).',
      [ACommitOrPrefix, ANormRepoUrl]);

  if FindCachedGitPackageDir(ANormRepoUrl, ACommitOrPrefix, AResolvedCommit40, ACacheDir, AActualIntegrity) then
  begin
    if (AExpectedIntegrity <> '') and (not SameText(AActualIntegrity, AExpectedIntegrity)) then
      raise ENikError.CreateFmt(
        'Package integrity mismatch for ''%s'' (%s): nik.lock expects %s, but cached tree computed %s.',
        [ANormRepoUrl, AResolvedCommit40, AExpectedIntegrity, AActualIntegrity]);
    Exit;
  end;

  StagingDir := NextStagingDir('git');
  try
    if not TryFetchGitViaForgeArchive(ANormRepoUrl, ACommitOrPrefix, StagingDir, AResolvedCommit40) then
      FetchGitViaCli(ANormRepoUrl, ACommitOrPrefix, StagingDir, AResolvedCommit40);

    AActualIntegrity := ComputeDirectoryTreeIntegrity(StagingDir);
    if (AExpectedIntegrity <> '') and (not SameText(AActualIntegrity, AExpectedIntegrity)) then
      raise ENikError.CreateFmt(
        'Package integrity mismatch for ''%s'' (%s): nik.lock expects %s, but fetched tree computed %s.',
        [ANormRepoUrl, AResolvedCommit40, AExpectedIntegrity, AActualIntegrity]);

    WriteMarkerFile(StagingDir, AActualIntegrity, '');

    FinalDir := JoinPath(GetGitRepoCacheBaseDir(ANormRepoUrl), AResolvedCommit40);
    EnsureDirExists(ExtractFileDir(FinalDir));

    if DirectoryExists(FinalDir) then
    begin
      ExistingIntegrity := ReadMarkerField(FinalDir, 'integrity');
      if ExistingIntegrity <> '' then
      begin
        ACacheDir := FinalDir;
        Exit;
      end;
      DeleteDirectoryRecursive(FinalDir);
    end;

    MoveDirectoryAtomic(StagingDir, FinalDir);
    ACacheDir := FinalDir;
  finally
    if DirectoryExists(StagingDir) then
      DeleteDirectoryRecursive(StagingDir);
  end;
end;

function FindCachedArchiveDir(const AExpectedSha256: string; out ACacheDir: string): Boolean;
var
  NormHex, CandidateDir: string;
begin
  Result := False;
  ACacheDir := '';
  if not ValidateHexSha256(AExpectedSha256, NormHex) then
    Exit;

  CandidateDir := JoinPath(JoinPath(GetNikrunPkgCacheDir, 'archive'), NormHex);
  if SameText(ReadMarkerField(CandidateDir, 'sha256'), NormHex) then
  begin
    ACacheDir := CandidateDir;
    Result := True;
  end;
end;

procedure EnsureArchivePackageCached(const ASourceUrlOrLocalPath: string; AIsLocalFile: Boolean;
  const AExpectedSha256: string; out AActualSha256, ACacheDir: string);
var
  StagingRoot, ArchiveFile, ExtractDir, FinalDir, Ext: string;
begin
  // Fast cache hit for remote archives when SHA-256 is already pinned in nik.lock / nik.yaml
  if (not AIsLocalFile) and (AExpectedSha256 <> '') and FindCachedArchiveDir(AExpectedSha256, ACacheDir) then
  begin
    AActualSha256 := LowerCase(AExpectedSha256);
    Exit;
  end;

  if AIsLocalFile then
  begin
    if not FileExists(ASourceUrlOrLocalPath) then
      raise ENikError.CreateFmt('Local dependency archive not found: %s', [ASourceUrlOrLocalPath]);
    AActualSha256 := LowerCase(Sha256FileHex(ASourceUrlOrLocalPath));
    if (AExpectedSha256 <> '') and (not SameText(AActualSha256, AExpectedSha256)) then
      raise ENikError.CreateFmt(
        'Archive SHA-256 mismatch for ''%s'': expected %s, got %s.',
        [ASourceUrlOrLocalPath, LowerCase(AExpectedSha256), AActualSha256]);
    if FindCachedArchiveDir(AActualSha256, ACacheDir) then
      Exit;
  end;

  StagingRoot := NextStagingDir('archive');
  try
    if AIsLocalFile then
      ArchiveFile := ASourceUrlOrLocalPath
    else
    begin
      Ext := GetSupportedArchiveExt(ASourceUrlOrLocalPath);
      if Ext = '' then
        Ext := '.zip';
      ArchiveFile := JoinPath(StagingRoot, 'download' + Ext);
      HttpDownloadFile(ASourceUrlOrLocalPath, ArchiveFile);
      AActualSha256 := LowerCase(Sha256FileHex(ArchiveFile));
      if (AExpectedSha256 <> '') and (not SameText(AActualSha256, AExpectedSha256)) then
        raise ENikError.CreateFmt(
          'Archive SHA-256 mismatch for ''%s'': expected %s, got %s.',
          [ASourceUrlOrLocalPath, LowerCase(AExpectedSha256), AActualSha256]);
      if FindCachedArchiveDir(AActualSha256, ACacheDir) then
        Exit;
    end;

    ExtractDir := JoinPath(StagingRoot, 'extracted');
    EnsureDirExists(ExtractDir);
    ExtractPackageArchive(ArchiveFile, ExtractDir, True);
    WriteMarkerFile(ExtractDir, '', AActualSha256);

    FinalDir := JoinPath(JoinPath(GetNikrunPkgCacheDir, 'archive'), AActualSha256);
    EnsureDirExists(ExtractFileDir(FinalDir));
    if DirectoryExists(FinalDir) then
    begin
      if SameText(ReadMarkerField(FinalDir, 'sha256'), AActualSha256) then
      begin
        ACacheDir := FinalDir;
        Exit;
      end;
      DeleteDirectoryRecursive(FinalDir);
    end;

    MoveDirectoryAtomic(ExtractDir, FinalDir);
    ACacheDir := FinalDir;
  finally
    if DirectoryExists(StagingRoot) then
      DeleteDirectoryRecursive(StagingRoot);
  end;
end;

end.
