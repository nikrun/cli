unit nik.paths;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

procedure SetNikrunHomeOverride(const APath: string);
function GetUserHomeDir: string;
function GetNikrunHomeDir: string;
function GetNikrunSdksDir: string;
function GetNikrunCacheDir: string;
function GetNikrunPkgCacheDir: string;
function GetNikrunSdkIndexCacheFile: string;
function GetNikrunBinDir: string;
function GetNikrunTemplateFile: string;

function JoinPath(const ABase, ARelative: string): string;
function IsAbsolutePath(const APath: string): Boolean;
function ResolveRelativePath(const ABaseDir, APath: string): string;
function NormalizeForwardSlashes(const APath: string): string;
function NormalizeNativeSeparators(const APath: string): string;
function FindExecutableInPath(const AExeName: string): string;

{ True for a single file or directory name that cannot leave its parent directory:
  not empty, not made of dots only, no separators, drive colons, wildcards or control characters. }
function IsSafePathSegment(const AName: string): Boolean;
{ True for a relative path that stays below its base directory: not rooted, no drive,
  no '..' segment. Both '/' and '\' count as separators. }
function IsSafeRelativePath(const APath: string): Boolean;

implementation

uses
  nik.types;

var
  GNikrunHomeOverride: string = '';

procedure SetNikrunHomeOverride(const APath: string);
begin
  GNikrunHomeOverride := Trim(APath);
end;

function NormalizeNativeSeparators(const APath: string): string;
var
  I: Integer;
begin
  Result := APath;
  for I := 1 to Length(Result) do
  begin
    if (Result[I] = '/') or (Result[I] = '\') then
      Result[I] := DirectorySeparator;
  end;
end;

function NormalizeForwardSlashes(const APath: string): string;
var
  I: Integer;
begin
  Result := APath;
  for I := 1 to Length(Result) do
  begin
    if Result[I] = '\' then
      Result[I] := '/';
  end;
end;

function JoinPath(const ABase, ARelative: string): string;
var
  CleanBase, CleanRel: string;
begin
  if ABase = '' then
    Exit(NormalizeNativeSeparators(ARelative));
  if ARelative = '' then
    Exit(NormalizeNativeSeparators(ABase));

  CleanBase := ExcludeTrailingPathDelimiter(NormalizeNativeSeparators(ABase));
  CleanRel := NormalizeNativeSeparators(ARelative);
  while (Length(CleanRel) > 0) and (CleanRel[1] = DirectorySeparator) do
    Delete(CleanRel, 1, 1);

  Result := CleanBase + DirectorySeparator + CleanRel;
end;

function IsAbsolutePath(const APath: string): Boolean;
var
  S: string;
begin
  S := Trim(APath);
  if S = '' then
    Exit(False);
  if (S[1] = '/') or (S[1] = '\') then
    Exit(True);
  if (Length(S) >= 2) and (S[2] = ':') and
     (((S[1] >= 'A') and (S[1] <= 'Z')) or ((S[1] >= 'a') and (S[1] <= 'z'))) then
    Exit(True);
  Result := False;
end;

function ResolveRelativePath(const ABaseDir, APath: string): string;
var
  Trimmed: string;
begin
  Trimmed := Trim(APath);
  if Trimmed = '' then
    Exit(ABaseDir);
  if IsAbsolutePath(Trimmed) then
    Result := ExpandFileName(NormalizeNativeSeparators(Trimmed))
  else
    Result := ExpandFileName(JoinPath(ABaseDir, Trimmed));
end;

function FindExecutableInPath(const AExeName: string): string;
var
  ExeToFind: string;
begin
  ExeToFind := AExeName;
  {$IFDEF WINDOWS}
  if ExtractFileExt(ExeToFind) = '' then
    ExeToFind := ExeToFind + '.exe';
  {$ENDIF}
  Result := ExeSearch(ExeToFind, SysUtils.GetEnvironmentVariable('PATH'));
end;

function IsSafePathSegment(const AName: string): Boolean;
var
  I: Integer;
  OnlyDots: Boolean;
begin
  Result := False;
  if (AName = '') or (AName <> Trim(AName)) then
    Exit;

  OnlyDots := True;
  for I := 1 to Length(AName) do
  begin
    if AName[I] <> '.' then
      OnlyDots := False;
    if (AName[I] < #32) or (AName[I] in ['/', '\', ':', '*', '?', '"', '<', '>', '|']) then
      Exit;
  end;
  Result := not OnlyDots;
end;

function IsSafeRelativePath(const APath: string): Boolean;
var
  Norm, Seg: string;
  I, StartIdx: Integer;
begin
  Result := False;
  if (Trim(APath) = '') or IsAbsolutePath(APath) then
    Exit;

  Norm := NormalizeForwardSlashes(APath);
  StartIdx := 1;
  for I := 1 to Length(Norm) + 1 do
  begin
    if (I > Length(Norm)) or (Norm[I] = '/') then
    begin
      Seg := Copy(Norm, StartIdx, I - StartIdx);
      if (Seg = '..') or (Pos(':', Seg) > 0) then
        Exit;
      StartIdx := I + 1;
    end
    else if Norm[I] < #32 then
      Exit;
  end;
  Result := True;
end;

function GetUserHomeDir: string;
begin
{$IFDEF WINDOWS}
  Result := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if Result = '' then
  begin
    if (SysUtils.GetEnvironmentVariable('HOMEDRIVE') <> '') and (SysUtils.GetEnvironmentVariable('HOMEPATH') <> '') then
      Result := SysUtils.GetEnvironmentVariable('HOMEDRIVE') + SysUtils.GetEnvironmentVariable('HOMEPATH');
  end;
  if Result = '' then
    Result := SysUtils.GetEnvironmentVariable('HOME');
{$ELSE}
  Result := SysUtils.GetEnvironmentVariable('HOME');
{$ENDIF}
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(GetUserDir);
  if Result = '' then
    raise ENikError.Create('Unable to determine current user home directory.');
end;

function GetNikrunHomeDir: string;
var
  EnvHome: string;
begin
  if GNikrunHomeOverride <> '' then
    Exit(ExpandFileName(NormalizeNativeSeparators(GNikrunHomeOverride)));

  EnvHome := Trim(SysUtils.GetEnvironmentVariable(ENV_NIKRUN_HOME));
  if EnvHome <> '' then
    Exit(ExpandFileName(NormalizeNativeSeparators(EnvHome)));

  Result := JoinPath(GetUserHomeDir, '.nikrun');
end;

function GetNikrunSdksDir: string;
begin
  Result := JoinPath(GetNikrunHomeDir, 'sdks');
end;

function GetNikrunCacheDir: string;
begin
  Result := JoinPath(GetNikrunHomeDir, 'cache');
end;

function GetNikrunPkgCacheDir: string;
begin
  Result := JoinPath(GetNikrunCacheDir, 'pkg');
end;

function GetNikrunSdkIndexCacheFile: string;
begin
  Result := JoinPath(GetNikrunCacheDir, 'sdk-index.json');
end;

function GetNikrunBinDir: string;
begin
  Result := JoinPath(GetNikrunHomeDir, 'bin');
end;

function GetNikrunTemplateFile: string;
begin
  Result := JoinPath(GetNikrunHomeDir, 'template.yaml');
end;

end.
