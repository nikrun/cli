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
function GetNikrunBinDir: string;
function GetNikrunTemplateFile: string;

function JoinPath(const ABase, ARelative: string): string;
function IsAbsolutePath(const APath: string): Boolean;
function ResolveRelativePath(const ABaseDir, APath: string): string;
function NormalizeForwardSlashes(const APath: string): string;
function NormalizeNativeSeparators(const APath: string): string;
function FindExecutableInPath(const AExeName: string): string;

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

function GetNikrunBinDir: string;
begin
  Result := JoinPath(GetNikrunHomeDir, 'bin');
end;

function GetNikrunTemplateFile: string;
begin
  Result := JoinPath(GetNikrunHomeDir, 'template.yaml');
end;

end.
