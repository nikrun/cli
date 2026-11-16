unit nik.fs;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

procedure EnsureDirExists(const ADir: string);
procedure CopyDirectoryRecursive(const ASrcDir, ADestDir: string);
procedure MoveDirectoryAtomic(const ASrcDir, ADestDir: string);
procedure DeleteDirectoryRecursive(const ADir: string);

function StripUtf8Bom(const AText: string): string;
function ReadFileTextUtf8(const AFilePath: string): string;
procedure WriteFileTextUtf8(const AFilePath, AContent: string);
function GetFileSizeSafe(const AFilePath: string): Int64;

implementation

uses
  nik.types
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF};

procedure EnsureDirExists(const ADir: string);
begin
  if (ADir <> '') and (not DirectoryExists(ADir)) then
  begin
    if not ForceDirectories(ADir) then
      raise ENikError.CreateFmt('Failed to create directory: %s', [ADir]);
  end;
end;

procedure CopyFileBinary(const ASrcFile, ADestFile: string);
var
  InStream, OutStream: TFileStream;
begin
  EnsureDirExists(ExtractFileDir(ADestFile));
  InStream := TFileStream.Create(ASrcFile, fmOpenRead or fmShareDenyWrite);
  try
    OutStream := TFileStream.Create(ADestFile, fmCreate);
    try
      if InStream.Size > 0 then
        OutStream.CopyFrom(InStream, InStream.Size);
    finally
      OutStream.Free;
    end;
  finally
    InStream.Free;
  end;
end;

{$PUSH}
{$WARN SYMBOL_PLATFORM OFF}
procedure CopyDirectoryRecursive(const ASrcDir, ADestDir: string);
var
  Rec: TSearchRec;
  SrcEntry, DestEntry: string;
  IsDir, IsSymLink: Boolean;
begin
  if not DirectoryExists(ASrcDir) then
    raise ENikError.CreateFmt('Source directory not found: %s', [ASrcDir]);

  EnsureDirExists(ADestDir);

  if FindFirst(IncludeTrailingPathDelimiter(ASrcDir) + AllFilesMask, faAnyFile or faSymLink, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;

        SrcEntry := IncludeTrailingPathDelimiter(ASrcDir) + Rec.Name;
        DestEntry := IncludeTrailingPathDelimiter(ADestDir) + Rec.Name;
        IsSymLink := (Rec.Attr and faSymLink) <> 0;
        IsDir := ((Rec.Attr and faDirectory) <> 0) and (not IsSymLink);

        if IsDir then
          CopyDirectoryRecursive(SrcEntry, DestEntry)
        else
          CopyFileBinary(SrcEntry, DestEntry);
      until SysUtils.FindNext(Rec) <> 0;
    finally
      SysUtils.FindClose(Rec);
    end;
  end;
end;
{$POP}

procedure MoveDirectoryAtomic(const ASrcDir, ADestDir: string);
var
  Attempt: Integer;
begin
  // On Windows, real-time antivirus (Defender) briefly holds scan handles on newly
  // extracted .exe/.dll binaries, causing directory renames to transiently fail with
  // ERROR_ACCESS_DENIED. Retry with short backoff before giving up.
  for Attempt := 1 to 25 do
  begin
    if RenameFile(ASrcDir, ADestDir) then
      Exit;
    Sleep(100);
  end;

  raise ENikError.CreateFmt('Failed to move directory from %s to %s.', [ASrcDir, ADestDir]);
end;

{$PUSH}
{$WARN SYMBOL_PLATFORM OFF}
procedure DeleteDirectoryRecursive(const ADir: string);
var
  Rec: TSearchRec;
  FullEntry: string;
  IsDir, IsSymLink: Boolean;
begin
  if (ADir = '') or (not DirectoryExists(ADir)) then
    Exit;

  if FindFirst(IncludeTrailingPathDelimiter(ADir) + AllFilesMask, faAnyFile or faSymLink, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;

        FullEntry := IncludeTrailingPathDelimiter(ADir) + Rec.Name;
        IsSymLink := (Rec.Attr and faSymLink) <> 0;
        IsDir := ((Rec.Attr and faDirectory) <> 0) and (not IsSymLink);

        if IsDir then
          DeleteDirectoryRecursive(FullEntry)
        else
        begin
          {$IFDEF WINDOWS}
          if (Rec.Attr and faReadOnly) <> 0 then
            FileSetAttr(FullEntry, Rec.Attr and (not faReadOnly));
          {$ENDIF}
          if not SysUtils.DeleteFile(FullEntry) then
          begin
            {$IFDEF UNIX}
            if fpUnlink(FullEntry) <> 0 then
            {$ENDIF}
              raise ENikError.CreateFmt('Failed to delete file: %s', [FullEntry]);
          end;
        end;
      until SysUtils.FindNext(Rec) <> 0;
    finally
      SysUtils.FindClose(Rec);
    end;
  end;

  {$IFDEF WINDOWS}
  FileSetAttr(ADir, faDirectory);
  {$ENDIF}
  if not RemoveDir(ADir) then
    raise ENikError.CreateFmt('Failed to remove directory: %s', [ADir]);
end;
{$POP}

function StripUtf8Bom(const AText: string): string;
begin
  if (Length(AText) >= 3) and
     (Byte(AText[1]) = $EF) and
     (Byte(AText[2]) = $BB) and
     (Byte(AText[3]) = $BF) then
    Result := Copy(AText, 4, MaxInt)
  else
    Result := AText;
end;

function ReadFileTextUtf8(const AFilePath: string): string;
var
  FS: TFileStream;
  Raw: RawByteString;
begin
  if not FileExists(AFilePath) then
    raise ENikError.CreateFmt('File not found: %s', [AFilePath]);

  FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Raw, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Raw[1], FS.Size);
  finally
    FS.Free;
  end;
  Result := StripUtf8Bom(string(Raw));
end;

procedure WriteFileTextUtf8(const AFilePath, AContent: string);
var
  FS: TFileStream;
begin
  EnsureDirExists(ExtractFileDir(AFilePath));
  FS := TFileStream.Create(AFilePath, fmCreate);
  try
    if Length(AContent) > 0 then
      FS.WriteBuffer(AContent[1], Length(AContent));
  finally
    FS.Free;
  end;
end;

function GetFileSizeSafe(const AFilePath: string): Int64;
var
  FS: TFileStream;
begin
  Result := 0;
  if not FileExists(AFilePath) then
    Exit;
  try
    FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      Result := FS.Size;
    finally
      FS.Free;
    end;
  except
    Result := 0;
  end;
end;

end.
