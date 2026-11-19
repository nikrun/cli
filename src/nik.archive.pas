unit nik.archive;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

function IsSupportedArchivePath(const APathOrUrl: string): Boolean;
function GetSupportedArchiveExt(const APathOrUrl: string): string;
procedure ExtractZipArchive(const AZipPath, ADestDir: string);
procedure ExtractPackageArchive(const AArchivePath, ADestDir: string; AStripSingleRoot: Boolean);
procedure EnsureBinariesExecutable(const ABinDir: string);

implementation

uses
  Process, Zipper, zstream, libtar, nik.types, nik.paths, nik.fs
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF};

function StripQueryAndFragment(const APathOrUrl: string): string;
var
  P: Integer;
begin
  Result := Trim(APathOrUrl);
  P := Pos('#', Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
  P := Pos('?', Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
end;

function EndsWithIgnoreCase(const AText, ASuffix: string): Boolean;
begin
  Result := (Length(AText) >= Length(ASuffix)) and
            SameText(Copy(AText, Length(AText) - Length(ASuffix) + 1, Length(ASuffix)), ASuffix);
end;

function GetSupportedArchiveExt(const APathOrUrl: string): string;
var
  Clean: string;
begin
  Clean := StripQueryAndFragment(APathOrUrl);
  if EndsWithIgnoreCase(Clean, '.tar.gz') then
    Result := '.tar.gz'
  else if EndsWithIgnoreCase(Clean, '.tgz') then
    Result := '.tgz'
  else if EndsWithIgnoreCase(Clean, '.zip') then
    Result := '.zip'
  else
    Result := '';
end;

function IsSupportedArchivePath(const APathOrUrl: string): Boolean;
begin
  Result := GetSupportedArchiveExt(APathOrUrl) <> '';
end;

function SanitizeRelativeArchiveEntry(const ARawName: string; out ACleanRel: string): Boolean;
var
  Norm, Seg: string;
  I, StartIdx: Integer;
begin
  Result := False;
  ACleanRel := '';
  Norm := NormalizeForwardSlashes(Trim(ARawName));
  while (Length(Norm) >= 2) and (Copy(Norm, 1, 2) = './') do
    Delete(Norm, 1, 2);

  if Norm = '' then
    Exit(True);

  // Reject rooted paths or drive letters (Zip-Slip / Tar-Slip protection)
  if (Norm[1] = '/') or ((Length(Norm) >= 2) and (Norm[2] = ':')) then
    Exit(False);

  StartIdx := 1;
  for I := 1 to Length(Norm) + 1 do
  begin
    if (I > Length(Norm)) or (Norm[I] = '/') then
    begin
      Seg := Copy(Norm, StartIdx, I - StartIdx);
      if Seg = '..' then
        Exit(False);
      StartIdx := I + 1;
    end;
  end;

  while (Length(Norm) > 0) and (Norm[Length(Norm)] = '/') do
    Delete(Norm, Length(Norm), 1);

  ACleanRel := Norm;
  Result := True;
end;

function TryRunExtractor(const AExe: string; const AArgs: array of string): Boolean;
var
  Proc: TProcess;
  I: Integer;
  DrainBuf: array[0..4095] of Byte;
begin
  Result := False;
  if (AExe = '') or (not FileExists(AExe)) then
    Exit;

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    for I := Low(AArgs) to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    // Merge stderr into stdout and drain it: with unread pipes a tool that prints many warnings
    // (tar.exe on many entries) fills the pipe buffer and blocks forever.
    Proc.Options := [poNoConsole, poUsePipes, poStderrToOutPut];
    try
      Proc.Execute;
      while Proc.Running or (Proc.Output.NumBytesAvailable > 0) do
      begin
        if Proc.Output.NumBytesAvailable > 0 then
          Proc.Output.Read(DrainBuf[0], SizeOf(DrainBuf))
        else
          Sleep(10);
      end;
      Proc.WaitOnExit;
      Result := (Proc.ExitStatus = 0);
    except
      Result := False;
    end;
  finally
    Proc.Free;
  end;
end;

procedure ValidateZipEntriesSafe(const AZipPath: string);
var
  UnZipper: TUnZipper;
  I: Integer;
  CleanRel: string;
begin
  UnZipper := TUnZipper.Create;
  try
    UnZipper.FileName := AZipPath;
    UnZipper.Examine;
    for I := 0 to UnZipper.Entries.Count - 1 do
    begin
      if not SanitizeRelativeArchiveEntry(UnZipper.Entries[I].ArchiveFileName, CleanRel) then
        raise ENikError.CreateFmt('Unsafe archive entry ''%s'' in %s.',
          [UnZipper.Entries[I].ArchiveFileName, AZipPath]);
    end;
  finally
    UnZipper.Free;
  end;
end;

procedure ExtractViaPasZlib(const AZipPath, ADestDir: string);
var
  UnZipper: TUnZipper;
begin
  ValidateZipEntriesSafe(AZipPath);
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

const
  // A package archive that unpacks to more than this is treated as a decompression bomb.
  MAX_UNPACKED_TAR_BYTES: Int64 = 2147483648; // 2 GiB

procedure ExtractTarGzViaFcl(const ATarGzPath, ADestDir: string);
var
  GzStream: TGZFileStream;
  TarFile: TFileStream;
  TarPath: string;
  TarArch: TTarArchive;
  DirRec: TTarDirRec;
  CleanRel, OutPath: string;
  OutFile: TFileStream;
  Buf: array[0..65535] of Byte;
  ReadCount: LongInt;
  Total: Int64;
begin
  // The tar reader needs a seekable stream, which the gzip stream is not. Unpack to a temporary
  // file rather than into memory, so a large archive costs disk space instead of RAM.
  TarPath := Format('%s%s.%d.tar.tmp', [IncludeTrailingPathDelimiter(GetTempDir(False)),
    ChangeFileExt(ExtractFileName(ATarGzPath), ''), GetProcessID]);
  TarFile := nil;
  try
    GzStream := TGZFileStream.Create(ATarGzPath, gzOpenRead);
    try
      TarFile := TFileStream.Create(TarPath, fmCreate);
      try
        Total := 0;
        repeat
          ReadCount := GzStream.Read(Buf[0], SizeOf(Buf));
          if ReadCount > 0 then
          begin
            Inc(Total, ReadCount);
            if Total > MAX_UNPACKED_TAR_BYTES then
              raise ENikError.CreateFmt('Archive %s unpacks to more than %d bytes; refusing to extract it.',
                [ATarGzPath, MAX_UNPACKED_TAR_BYTES]);
            TarFile.WriteBuffer(Buf[0], ReadCount);
          end;
        until ReadCount = 0;
      finally
        FreeAndNil(TarFile);
      end;
    finally
      GzStream.Free;
    end;

    TarFile := TFileStream.Create(TarPath, fmOpenRead or fmShareDenyWrite);
    TarArch := TTarArchive.Create(TarFile);
    try
      TarArch.Reset;
      while TarArch.FindNext(DirRec) do
      begin
        if not SanitizeRelativeArchiveEntry(DirRec.Name, CleanRel) then
          raise ENikError.CreateFmt('Unsafe tar archive entry ''%s'' in %s.', [DirRec.Name, ATarGzPath]);
        if CleanRel = '' then
          Continue;

        // Skip PAX global/extended metadata headers ('g' / 'x' mapped to ftNormal or special names)
        if (CleanRel = 'pax_global_header') or (Pos('/PaxHeaders.', '/' + CleanRel) > 0) then
          Continue;

        OutPath := JoinPath(ADestDir, CleanRel);
        case DirRec.FileType of
          ftDirectory:
            EnsureDirExists(OutPath);
          ftNormal, ftContiguous:
            begin
              EnsureDirExists(ExtractFileDir(OutPath));
              OutFile := TFileStream.Create(OutPath, fmCreate);
              try
                TarArch.ReadFile(OutFile);
              finally
                OutFile.Free;
              end;
            end;
        else
          // Ignore symlinks/FIFO/device special entries for cross-platform safety
        end;
      end;
    finally
      TarArch.Free;
    end;
  finally
    TarFile.Free;
    if FileExists(TarPath) then
      SysUtils.DeleteFile(TarPath);
  end;
end;

procedure ExtractZipArchive(const AZipPath, ADestDir: string);
var
  ToolBin: string;
begin
  if not FileExists(AZipPath) then
    raise ENikError.CreateFmt('ZIP archive not found: %s', [AZipPath]);

  ValidateZipEntriesSafe(AZipPath);
  EnsureDirExists(ADestDir);

{$IFDEF WINDOWS}
  // The bsdtar shipped with Windows reads zip files. A tar.exe earlier in PATH (Git for Windows
  // ships GNU tar) neither does nor is trustworthy, so the system copy goes first.
  ToolBin := '';
  if SysUtils.GetEnvironmentVariable('SystemRoot') <> '' then
    ToolBin := JoinPath(JoinPath(SysUtils.GetEnvironmentVariable('SystemRoot'), 'System32'), 'tar.exe');
  if (ToolBin = '') or (not FileExists(ToolBin)) then
    ToolBin := FindExecutableInPath('tar.exe');

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

procedure ExtractTarGzArchive(const ATarGzPath, ADestDir: string);
begin
  if not FileExists(ATarGzPath) then
    raise ENikError.CreateFmt('Archive not found: %s', [ATarGzPath]);

  EnsureDirExists(ADestDir);
  try
    // Always use our validated FCL extractor first so path-traversal and PAX headers are strictly checked
    ExtractTarGzViaFcl(ATarGzPath, ADestDir);
  except
    on E: ENikError do
      raise;
    on E: Exception do
      raise ENikError.CreateFmt('Failed to extract archive %s: %s', [ATarGzPath, E.Message]);
  end;
end;

{$PUSH}
{$WARN SYMBOL_PLATFORM OFF}
procedure UnwrapSingleRootDirectory(const ADestDir: string);
var
  Rec: TSearchRec;
  DirCount, FileCount: Integer;
  SingleSubDir, TempLiftDir, ChildSrc, ChildDst: string;
begin
  DirCount := 0;
  FileCount := 0;
  SingleSubDir := '';

  if FindFirst(IncludeTrailingPathDelimiter(ADestDir) + AllFilesMask, faAnyFile or faSymLink, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        // Ignore macOS Finder metadata folder if bundled alongside single root folder
        if SameText(Rec.Name, '__MACOSX') then
          Continue;

        if ((Rec.Attr and faDirectory) <> 0) and ((Rec.Attr and faSymLink) = 0) then
        begin
          Inc(DirCount);
          SingleSubDir := IncludeTrailingPathDelimiter(ADestDir) + Rec.Name;
        end
        else
          Inc(FileCount);
      until SysUtils.FindNext(Rec) <> 0;
    finally
      SysUtils.FindClose(Rec);
    end;
  end;

  if (DirCount <> 1) or (FileCount <> 0) or (SingleSubDir = '') then
    Exit;

  // Move single root directory to a sibling temp name inside ADestDir first (handles case where child has same name as parent)
  TempLiftDir := JoinPath(ADestDir, '.nik-unwrap-' + IntToStr(GetTickCount64));
  MoveDirectoryAtomic(SingleSubDir, TempLiftDir);

  if FindFirst(IncludeTrailingPathDelimiter(TempLiftDir) + AllFilesMask, faAnyFile or faSymLink, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        ChildSrc := IncludeTrailingPathDelimiter(TempLiftDir) + Rec.Name;
        ChildDst := IncludeTrailingPathDelimiter(ADestDir) + Rec.Name;
        if ((Rec.Attr and faDirectory) <> 0) and ((Rec.Attr and faSymLink) = 0) then
          MoveDirectoryAtomic(ChildSrc, ChildDst)
        else if not RenameFile(ChildSrc, ChildDst) then
          raise ENikError.CreateFmt('Failed to unwrap archive entry %s.', [Rec.Name]);
      until SysUtils.FindNext(Rec) <> 0;
    finally
      SysUtils.FindClose(Rec);
    end;
  end;

  DeleteDirectoryRecursive(TempLiftDir);
  if DirectoryExists(JoinPath(ADestDir, '__MACOSX')) then
    DeleteDirectoryRecursive(JoinPath(ADestDir, '__MACOSX'));
end;
{$POP}

procedure ExtractPackageArchive(const AArchivePath, ADestDir: string; AStripSingleRoot: Boolean);
var
  Ext: string;
begin
  Ext := GetSupportedArchiveExt(AArchivePath);
  if Ext = '.zip' then
    ExtractZipArchive(AArchivePath, ADestDir)
  else if (Ext = '.tar.gz') or (Ext = '.tgz') then
    ExtractTarGzArchive(AArchivePath, ADestDir)
  else
    raise ENikError.CreateFmt('Unsupported package archive format: %s (expected .zip, .tar.gz, or .tgz).', [AArchivePath]);

  if AStripSingleRoot then
    UnwrapSingleRootDirectory(ADestDir);
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
