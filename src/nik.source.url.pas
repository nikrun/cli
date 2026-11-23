unit nik.source.url;

{$mode objfpc}{$H+}

{ Pure (network-free) parsing of web source URLs accepted by 'nik run' / 'nik build':
    https://github.com/owner/repo                      repository (default branch)
    https://github.com/owner/repo@v1.2.0               repository pinned to a tag, branch or commit
    https://github.com/owner/repo/blob/main/src/x.pas  file inside a repository
    https://github.com/owner/repo/tree/main/tools      directory inside a repository
    https://raw.githubusercontent.com/owner/repo/main/x.pas
    https://gitlab.com/group/sub/repo/-/blob/main/x.pas
    https://codeberg.org/owner/repo/src/branch/main/x.pas
  The Git ref and the path of a 'blob' / 'tree' URL are ambiguous ('feature/x/file.pas'), so they are
  kept together in RefAndPath and split later against the refs the remote actually advertises. }

interface

uses
  SysUtils, nik.types;

type
  TSourceUrlParts = record
    RepoUrl: string;      // normalized https repository URL without '.git'
    RefAndPath: string;   // '<ref>/<path>' of a blob/tree/raw URL; '' for plain repository URLs
    IsTree: Boolean;      // RefAndPath addresses a directory
    ExplicitRef: string;  // '@<ref>' suffix of a plain repository URL; '' otherwise
  end;

function TryParseSourceUrl(const ARaw: string; out AParts: TSourceUrlParts;
  out AErrMsg: string): Boolean;

{ Splits '<ref>/<path>' using the longest prefix that is a known ref name (or a hex commit id).
  When ARequirePath is set the path must not be empty. }
function TrySplitRefAndPath(const ARefAndPath: string; const ARefNames: array of string;
  ARequirePath: Boolean; out ARef, APath: string): Boolean;

function IsHexCommitLike(const S: string): Boolean;

implementation

uses
  nik.pkg.types;

function IsHexCommitLike(const S: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(S) >= 7) and (Length(S) <= 40);
  if not Result then
    Exit;
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
end;

function SplitSegments(const APath: string): TStringArray;
var
  Start, I, N: Integer;
  Seg: string;
begin
  Result := nil;
  Start := 1;
  for I := 1 to Length(APath) + 1 do
    if (I > Length(APath)) or (APath[I] = '/') then
    begin
      Seg := Copy(APath, Start, I - Start);
      Start := I + 1;
      if Seg = '' then
        Continue;
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := Seg;
    end;
end;

function JoinSegments(const ASegs: TStringArray; AFrom, ATo: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := AFrom to ATo do
  begin
    if Result <> '' then
      Result := Result + '/';
    Result := Result + ASegs[I];
  end;
end;

function TryParseSourceUrl(const ARaw: string; out AParts: TSourceUrlParts;
  out AErrMsg: string): Boolean;
var
  S, Host, PathPart, RepoPath, Kind: string;
  P, AtPos, I, Marker: Integer;
  Segs: TStringArray;
  NormUrl: string;
begin
  Result := False;
  AParts := Default(TSourceUrlParts);
  AErrMsg := '';

  S := Trim(ARaw);
  // Drop query string and fragment ('#L10-L20' of a GitHub permalink)
  P := Pos('#', S);
  if P > 0 then
    S := Copy(S, 1, P - 1);
  P := Pos('?', S);
  if P > 0 then
    S := Copy(S, 1, P - 1);

  if not SameText(Copy(S, 1, 8), 'https://') then
  begin
    AErrMsg := Format('Source URL ''%s'' must start with https://.', [ARaw]);
    Exit;
  end;

  S := Copy(S, 9, MaxInt);
  P := Pos('/', S);
  if P <= 1 then
  begin
    AErrMsg := Format('Source URL ''%s'' must include a host and a repository path.', [ARaw]);
    Exit;
  end;
  Host := LowerCase(Copy(S, 1, P - 1));
  PathPart := Copy(S, P + 1, MaxInt);
  while (PathPart <> '') and (PathPart[Length(PathPart)] = '/') do
    Delete(PathPart, Length(PathPart), 1);

  Segs := SplitSegments(PathPart);
  RepoPath := '';
  Kind := '';

  if Host = 'raw.githubusercontent.com' then
  begin
    if Length(Segs) < 4 then
    begin
      AErrMsg := Format('Raw URL ''%s'' must look like https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>.', [ARaw]);
      Exit;
    end;
    Host := 'github.com';
    RepoPath := Segs[0] + '/' + Segs[1];
    AParts.RefAndPath := JoinSegments(Segs, 2, High(Segs));
  end
  else
  begin
    // GitLab: <group>/<sub>/<repo>/-/(blob|tree|raw)/<ref>/<path>
    Marker := -1;
    for I := 0 to High(Segs) - 2 do
      if (Segs[I] = '-') and ((Segs[I + 1] = 'blob') or (Segs[I + 1] = 'tree') or (Segs[I + 1] = 'raw')) then
      begin
        Marker := I;
        Break;
      end;
    if Marker >= 1 then
    begin
      RepoPath := JoinSegments(Segs, 0, Marker - 1);
      Kind := Segs[Marker + 1];
      if Marker + 2 <= High(Segs) then
        AParts.RefAndPath := JoinSegments(Segs, Marker + 2, High(Segs));
    end
    else if (Length(Segs) >= 4) and ((Segs[2] = 'blob') or (Segs[2] = 'tree') or (Segs[2] = 'raw')) then
    begin
      // GitHub: <owner>/<repo>/(blob|tree|raw)/<ref>/<path>
      RepoPath := Segs[0] + '/' + Segs[1];
      Kind := Segs[2];
      AParts.RefAndPath := JoinSegments(Segs, 3, High(Segs));
    end
    else if (Length(Segs) >= 5) and ((Segs[2] = 'src') or (Segs[2] = 'raw')) and
            ((Segs[3] = 'branch') or (Segs[3] = 'tag') or (Segs[3] = 'commit')) then
    begin
      // Codeberg / Gitea / Forgejo: <owner>/<repo>/(src|raw)/(branch|tag|commit)/<ref>/<path>
      RepoPath := Segs[0] + '/' + Segs[1];
      Kind := Segs[2];
      if Kind = 'src' then
        Kind := 'blob';
      AParts.RefAndPath := JoinSegments(Segs, 4, High(Segs));
    end
    else
      RepoPath := PathPart;
  end;

  AParts.IsTree := (Kind = 'tree');

  // '@<ref>' pins a plain repository URL
  if AParts.RefAndPath = '' then
  begin
    AtPos := LastDelimiter('@', RepoPath);
    if AtPos > 0 then
    begin
      AParts.ExplicitRef := Copy(RepoPath, AtPos + 1, MaxInt);
      RepoPath := Copy(RepoPath, 1, AtPos - 1);
      if AParts.ExplicitRef = '' then
      begin
        AErrMsg := Format('Source URL ''%s'' has an empty ''@'' reference.', [ARaw]);
        Exit;
      end;
    end;
  end;

  if not NormalizeRemoteUrlBase('https://' + Host + '/' + RepoPath, True, NormUrl, AErrMsg) then
    Exit;
  AParts.RepoUrl := NormUrl;
  Result := True;
end;

function TrySplitRefAndPath(const ARefAndPath: string; const ARefNames: array of string;
  ARequirePath: Boolean; out ARef, APath: string): Boolean;
var
  Segs: TStringArray;
  K, J, MaxK: Integer;
  Cand: string;
begin
  Result := False;
  ARef := '';
  APath := '';
  Segs := SplitSegments(ARefAndPath);
  if Length(Segs) = 0 then
    Exit;

  MaxK := Length(Segs);
  if ARequirePath then
    MaxK := Length(Segs) - 1;

  for K := MaxK downto 1 do
  begin
    Cand := JoinSegments(Segs, 0, K - 1);
    for J := 0 to High(ARefNames) do
      if ARefNames[J] = Cand then
      begin
        ARef := Cand;
        if K <= High(Segs) then
          APath := JoinSegments(Segs, K, High(Segs));
        Exit(True);
      end;
    if (K = 1) and IsHexCommitLike(Cand) then
    begin
      ARef := Cand;
      if K <= High(Segs) then
        APath := JoinSegments(Segs, K, High(Segs));
      Exit(True);
    end;
  end;
end;

end.
