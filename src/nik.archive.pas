unit nik.archive;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

procedure ExtractZipArchive(const AZipPath, ADestDir: string);
procedure EnsureBinariesExecutable(const ABinDir: string);

implementation

uses
  Process, Zipper, nik.types, nik.paths, nik.fs
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF};

function TryRunExtractor(const AExe: string; const AArgs: array of string): Boolean;
var
  Proc: TProcess;
  I: Integer;
begin
  Result := False;
  if (AExe = '') or (not FileExists(AExe)) then
    Exit;

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    for I := Low(AArgs) to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Options := [poWaitOnExit, poNoConsole, poUsePipes];
    try
      Proc.Execute;
      Result := (Proc.ExitStatus = 0);
    except
      Result := False;
    end;
  finally
    Proc.Free;
  end;
end;

procedure ExtractViaPasZlib(const AZipPath, ADestDir: string);
var
  UnZipper: TUnZipper;
begin
  UnZipper := TUnZipper.Create;
  try
    UnZipper.FileName := AZipPath;
    UnZipper.OutputPath := ADestDir;
    UnZipper.Examine;
    UnZipper.UnZipAllFiles;
  finally
    UnZipper.Free;
  end;
end;

procedure ExtractZipArchive(const AZipPath, ADestDir: string);
var
  ToolBin: string;
begin
  if not FileExists(AZipPath) then
    raise ENikError.CreateFmt('ZIP archive not found: %s', [AZipPath]);

  EnsureDirExists(ADestDir);

{$IFDEF WINDOWS}
  ToolBin := FindExecutableInPath('tar.exe');
  if (ToolBin = '') and FileExists('C:\Windows\System32\tar.exe') then
    ToolBin := 'C:\Windows\System32\tar.exe';

  if (ToolBin <> '') and TryRunExtractor(ToolBin, ['-xf', AZipPath, '-C', ADestDir]) then
    Exit;
{$ELSE}
  ToolBin := FindExecutableInPath('unzip');
  if (ToolBin <> '') and TryRunExtractor(ToolBin, ['-q', '-o', AZipPath, '-d', ADestDir]) then
    Exit;

  ToolBin := FindExecutableInPath('tar');
  if (ToolBin <> '') and TryRunExtractor(ToolBin, ['-xf', AZipPath, '-C', ADestDir]) then
    Exit;
{$ENDIF}

  try
    ExtractViaPasZlib(AZipPath, ADestDir);
  except
    on E: Exception do
      raise ENikError.CreateFmt('Failed to extract archive %s: %s', [AZipPath, E.Message]);
  end;
end;

procedure EnsureBinariesExecutable(const ABinDir: string);
{$IFDEF UNIX}
var
  Rec: TSearchRec;
  FullEntry: string;
  StatInfo: Stat;
begin
  if not DirectoryExists(ABinDir) then
    Exit;

  if FindFirst(IncludeTrailingPathDelimiter(ABinDir) + AllFilesMask, faAnyFile, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        if (Rec.Attr and faDirectory) <> 0 then
          Continue;
        if SameText(ExtractFileExt(Rec.Name), '.cfg') or SameText(ExtractFileExt(Rec.Name), '.h') then
          Continue;

        FullEntry := IncludeTrailingPathDelimiter(ABinDir) + Rec.Name;
        if fpStat(FullEntry, StatInfo) = 0 then
          fpChmod(FullEntry, StatInfo.st_mode or S_IXUSR or S_IXGRP or S_IXOTH);
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
  end;
end;
{$ELSE}
begin
  // No-op on Windows
  if ABinDir = '' then
    Exit;
end;
{$ENDIF}

end.
