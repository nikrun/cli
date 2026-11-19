unit nik.pkg.lock;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nik.types, nik.pkg.types;

const
  NIK_LOCK_FILENAME = 'nik.lock';
  NIK_PKG_MARKER    = '.nik-pkg.json';

function ComputeDirectoryTreeIntegrity(const ADirPath: string): string;
function LoadLockFile(const AProjectDir: string): TLockFile;
function FindLockedPackageById(const ALock: TLockFile; const AId: string; out AFound: TLockedPackage): Boolean;
procedure SortLockedPackages(var APackages: TLockedPackageArray);
function LockedPackageSetsMatch(const AExisting, ADesired: TLockedPackageArray): Boolean;
function FormatLockFileText(const APackages: TLockedPackageArray): string;
function SyncLockFileOnDisk(const AProjectDir: string; const ADesired: TLockedPackageArray): Boolean;

implementation

uses
  nik.paths, nik.fs, nik.sha256, nik.yaml;

type
  TTreeFileEntry = record
    RelSlashPath: string;
    FullPath: string;
  end;
  TTreeFileEntryArray = array of TTreeFileEntry;

function CompareAscii(const A, B: string): Integer;
var
  I, MinLen: Integer;
begin
  if Length(A) < Length(B) then
    MinLen := Length(A)
  else
    MinLen := Length(B);

  for I := 1 to MinLen do
    if Byte(A[I]) <> Byte(B[I]) then
    begin
      if Byte(A[I]) < Byte(B[I]) then
        Exit(-1)
      else
        Exit(1);
    end;

  if Length(A) < Length(B) then
    Result := -1
  else if Length(A) > Length(B) then
    Result := 1
  else
    Result := 0;
end;

{$PUSH}
{$WARN SYMBOL_PLATFORM OFF}
procedure CollectTreeFiles(const ARootDir, ACurRelSlash: string; var AOut: TTreeFileEntryArray);
var
  CurFull, ChildRel, ChildFull: string;
  Rec: TSearchRec;
  IsDir, IsSymLink: Boolean;
  N: Integer;
begin
  if ACurRelSlash = '' then
    CurFull := ARootDir
  else
    CurFull := JoinPath(ARootDir, ACurRelSlash);

  if FindFirst(IncludeTrailingPathDelimiter(CurFull) + AllFilesMask, faAnyFile or faSymLink, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        if (ACurRelSlash = '') and ((Rec.Name = NIK_PKG_MARKER) or (Rec.Name = '.git')) then
          Continue;

        if ACurRelSlash = '' then
          ChildRel := Rec.Name
        else
          ChildRel := ACurRelSlash + '/' + Rec.Name;

        ChildFull := IncludeTrailingPathDelimiter(CurFull) + Rec.Name;
        IsSymLink := (Rec.Attr and faSymLink) <> 0;
        IsDir := ((Rec.Attr and faDirectory) <> 0) and (not IsSymLink);

        if IsDir then
          CollectTreeFiles(ARootDir, ChildRel, AOut)
        else if not IsSymLink then
        begin
          N := Length(AOut);
          SetLength(AOut, N + 1);
          AOut[N].RelSlashPath := ChildRel;
          AOut[N].FullPath := ChildFull;
        end;
      until SysUtils.FindNext(Rec) <> 0;
    finally
      SysUtils.FindClose(Rec);
    end;
  end;
end;
{$POP}

procedure SortTreeFiles(var AEntries: TTreeFileEntryArray);
var
  I, J: Integer;
  Tmp: TTreeFileEntry;
begin
  for I := 0 to High(AEntries) - 1 do
    for J := I + 1 to High(AEntries) do
      if CompareAscii(AEntries[J].RelSlashPath, AEntries[I].RelSlashPath) < 0 then
      begin
        Tmp := AEntries[I];
        AEntries[I] := AEntries[J];
        AEntries[J] := Tmp;
      end;
end;

function ComputeDirectoryTreeIntegrity(const ADirPath: string): string;
const
  BUF_SIZE = 65536;
var
  Entries: TTreeFileEntryArray;
  Ctx: TSha256Context;
  Digest: TSha256Digest;
  I: Integer;
  FS: TFileStream;
  Header: RawByteString;
  TrailLf: Byte;
  Buf: array[0..BUF_SIZE - 1] of Byte;
  ReadBytes: LongInt;
begin
  if not DirectoryExists(ADirPath) then
    raise ENikError.CreateFmt('Cannot compute package tree integrity; directory not found: %s', [ADirPath]);

  Entries := nil;
  CollectTreeFiles(ADirPath, '', Entries);
  SortTreeFiles(Entries);

  Sha256Init(Ctx);
  TrailLf := 10;

  for I := 0 to High(Entries) do
  begin
    FS := TFileStream.Create(Entries[I].FullPath, fmOpenRead or fmShareDenyWrite);
    try
      Header := RawByteString('file:' + Entries[I].RelSlashPath + #0 + IntToStr(FS.Size) + #0);
      Sha256Update(Ctx, Header[1], Length(Header));
      repeat
        ReadBytes := FS.Read(Buf[0], BUF_SIZE);
        if ReadBytes > 0 then
          Sha256Update(Ctx, Buf[0], SizeUInt(ReadBytes));
      until ReadBytes = 0;
      Sha256Update(Ctx, TrailLf, 1);
    finally
      FS.Free;
    end;
  end;

  Sha256Final(Ctx, Digest);
  Result := 'sha256-' + Sha256DigestToHex(Digest);
end;

function ExpectLockStr(AMap: TYamlNode; const AKey, ALockPath: string; ARequired: Boolean): string;
var
  Sub: TYamlNode;
begin
  Result := '';
  Sub := AMap.Find(AKey);
  if (Sub = nil) or (Sub.Kind = ynkNull) then
  begin
    if ARequired then
      raise ENikError.CreateFmt('%s:%d: Missing required lockfile field ''%s''.', [ALockPath, AMap.Line, AKey]);
    Exit;
  end;
  if Sub.Kind <> ynkScalar then
    raise ENikError.CreateFmt('%s:%d: Field ''%s'' in nik.lock must be a string.', [ALockPath, Sub.Line, AKey]);
  Result := Trim(Sub.ScalarValue);
  if ARequired and (Result = '') then
    raise ENikError.CreateFmt('%s:%d: Field ''%s'' in nik.lock cannot be empty.', [ALockPath, Sub.Line, AKey]);
end;

function LoadLockFile(const AProjectDir: string): TLockFile;
var
  LockPath, KindStr, NormHex: string;
  Root, VerNode, PkgsNode, ItemNode: TYamlNode;
  VerVal, I: Integer;
  Pkg: TLockedPackage;
begin
  Result := Default(TLockFile);
  Result.LockVersion := 1;
  LockPath := JoinPath(AProjectDir, NIK_LOCK_FILENAME);
  Result.FilePath := LockPath;
  if not FileExists(LockPath) then
    Exit;

  Result.ExistsOnDisk := True;
  Root := ParseYamlFile(LockPath);
  try
    if Root.Kind = ynkNull then
      Exit;
    if Root.Kind <> ynkMapping then
      raise ENikError.CreateFmt('%s:%d: Top-level nik.lock document must be a mapping.', [LockPath, Root.Line]);

    VerNode := Root.Find('lockVersion');
    if (VerNode = nil) or (not VerNode.AsInteger(VerVal)) or (VerVal <> 1) then
      raise ENikError.CreateFmt('%s: Unsupported or missing ''lockVersion'' (expected 1).', [LockPath]);

    PkgsNode := Root.Find('packages');
    if (PkgsNode = nil) or (PkgsNode.Kind = ynkNull) then
      Exit;
    if PkgsNode.Kind <> ynkSequence then
      raise ENikError.CreateFmt('%s:%d: ''packages'' in nik.lock must be a sequence.', [LockPath, PkgsNode.Line]);

    SetLength(Result.Packages, PkgsNode.Count);
    for I := 0 to PkgsNode.Count - 1 do
    begin
      ItemNode := PkgsNode.GetItem(I);
      if ItemNode.Kind <> ynkMapping then
        raise ENikError.CreateFmt('%s:%d: Package entry in nik.lock must be a mapping.', [LockPath, ItemNode.Line]);

      Pkg := Default(TLockedPackage);
      Pkg.Id := ExpectLockStr(ItemNode, 'id', LockPath, True);
      KindStr := LowerCase(ExpectLockStr(ItemNode, 'kind', LockPath, True));
      if KindStr = 'git' then
        Pkg.Kind := lpkGit
      else if KindStr = 'archive' then
        Pkg.Kind := lpkArchive
      else
        raise ENikError.CreateFmt('%s:%d: Unknown package kind ''%s'' in nik.lock.', [LockPath, ItemNode.Line, KindStr]);

      Pkg.Url := ExpectLockStr(ItemNode, 'url', LockPath, False);
      Pkg.Path := ExpectLockStr(ItemNode, 'path', LockPath, False);
      Pkg.Subpath := ExpectLockStr(ItemNode, 'subpath', LockPath, False);
      Pkg.Version := ExpectLockStr(ItemNode, 'version', LockPath, False);
      Pkg.Rev := LowerCase(ExpectLockStr(ItemNode, 'rev', LockPath, False));
      Pkg.Integrity := LowerCase(ExpectLockStr(ItemNode, 'integrity', LockPath, False));
      Pkg.Sha256 := LowerCase(ExpectLockStr(ItemNode, 'sha256', LockPath, False));

      case Pkg.Kind of
        lpkGit:
          begin
            if (Pkg.Url = '') or (Length(Pkg.Rev) <> 40) then
              raise ENikError.CreateFmt('%s:%d: Git entry ''%s'' in nik.lock requires ''url'' and 40-char ''rev''.',
                [LockPath, ItemNode.Line, Pkg.Id]);
            if (Pkg.Integrity = '') or (not ValidateHexSha256(Pkg.Integrity, NormHex)) then
              raise ENikError.CreateFmt('%s:%d: Git entry ''%s'' in nik.lock has invalid ''integrity''.',
                [LockPath, ItemNode.Line, Pkg.Id]);
            Pkg.Integrity := 'sha256-' + NormHex;
          end;
        lpkArchive:
          begin
            if ((Pkg.Url = '') and (Pkg.Path = '')) or (not ValidateHexSha256(Pkg.Sha256, NormHex)) then
              raise ENikError.CreateFmt('%s:%d: Archive entry ''%s'' in nik.lock requires ''url''/''path'' and 64-char ''sha256''.',
                [LockPath, ItemNode.Line, Pkg.Id]);
            Pkg.Sha256 := NormHex;
          end;
      else
        raise ENikError.Create('Internal error: unexpected TLockedPackageKind.');
      end;

      Result.Packages[I] := Pkg;
    end;
  finally
    Root.Free;
  end;
end;

function FindLockedPackageById(const ALock: TLockFile; const AId: string; out AFound: TLockedPackage): Boolean;
var
  I: Integer;
begin
  Result := False;
  AFound := Default(TLockedPackage);
  for I := 0 to High(ALock.Packages) do
    if ALock.Packages[I].Id = AId then
    begin
      AFound := ALock.Packages[I];
      Exit(True);
    end;
end;

procedure SortLockedPackages(var APackages: TLockedPackageArray);
var
  I, J: Integer;
  Tmp: TLockedPackage;
begin
  for I := 0 to High(APackages) - 1 do
    for J := I + 1 to High(APackages) do
      if CompareAscii(APackages[J].Id, APackages[I].Id) < 0 then
      begin
        Tmp := APackages[I];
        APackages[I] := APackages[J];
        APackages[J] := Tmp;
      end;
end;

function LockedPackageEquals(const A, B: TLockedPackage): Boolean;
begin
  Result := (A.Id = B.Id) and
            (A.Kind = B.Kind) and
            (A.Url = B.Url) and
            (A.Path = B.Path) and
            (A.Subpath = B.Subpath) and
            (A.Version = B.Version) and
            (A.Rev = B.Rev) and
            (A.Integrity = B.Integrity) and
            (A.Sha256 = B.Sha256);
end;

function LockedPackageSetsMatch(const AExisting, ADesired: TLockedPackageArray): Boolean;
var
  SortedA, SortedB: TLockedPackageArray;
  I: Integer;
begin
  if Length(AExisting) <> Length(ADesired) then
    Exit(False);

  SetLength(SortedA, Length(AExisting));
  for I := 0 to High(AExisting) do
    SortedA[I] := AExisting[I];
  SortLockedPackages(SortedA);

  SetLength(SortedB, Length(ADesired));
  for I := 0 to High(ADesired) do
    SortedB[I] := ADesired[I];
  SortLockedPackages(SortedB);

  for I := 0 to High(SortedA) do
    if not LockedPackageEquals(SortedA[I], SortedB[I]) then
      Exit(False);

  Result := True;
end;

function QuoteYamlScalarIfNeeded(const S: string): string;
begin
  if YamlPlainScalarSafe(S) then
    Result := S
  else
    Result := YamlQuoteDouble(S);
end;

function FormatLockFileText(const APackages: TLockedPackageArray): string;
var
  Sorted: TLockedPackageArray;
  SB: TStringList;
  I: Integer;
  P: TLockedPackage;
begin
  SetLength(Sorted, Length(APackages));
  for I := 0 to High(APackages) do
    Sorted[I] := APackages[I];
  SortLockedPackages(Sorted);

  SB := TStringList.Create;
  try
    SB.LineBreak := #10;
    SB.Add('# Auto-generated by nik. Commit this file to version control.');
    SB.Add('lockVersion: 1');
    SB.Add('');
    if Length(Sorted) = 0 then
      SB.Add('packages: []')
    else
    begin
      SB.Add('packages:');
      for I := 0 to High(Sorted) do
      begin
        P := Sorted[I];
        SB.Add('  - id: ' + QuoteYamlScalarIfNeeded(P.Id));
        case P.Kind of
          lpkGit:
            begin
              SB.Add('    kind: git');
              SB.Add('    url: ' + QuoteYamlScalarIfNeeded(P.Url));
              if P.Subpath <> '' then
                SB.Add('    subpath: ' + QuoteYamlScalarIfNeeded(P.Subpath));
              if P.Version <> '' then
                SB.Add('    version: ' + QuoteYamlScalarIfNeeded(P.Version));
              SB.Add('    rev: ' + P.Rev);
              SB.Add('    integrity: ' + P.Integrity);
            end;
          lpkArchive:
            begin
              SB.Add('    kind: archive');
              if P.Url <> '' then
                SB.Add('    url: ' + QuoteYamlScalarIfNeeded(P.Url));
              if P.Path <> '' then
                SB.Add('    path: ' + QuoteYamlScalarIfNeeded(P.Path));
              if P.Subpath <> '' then
                SB.Add('    subpath: ' + QuoteYamlScalarIfNeeded(P.Subpath));
              SB.Add('    sha256: ' + P.Sha256);
            end;
        else
          raise ENikError.Create('Internal error: unexpected TLockedPackageKind.');
        end;
      end;
    end;
    Result := SB.Text;
  finally
    SB.Free;
  end;
end;

function SyncLockFileOnDisk(const AProjectDir: string; const ADesired: TLockedPackageArray): Boolean;
var
  LockPath, NewText, ExistingText: string;
begin
  Result := False;
  LockPath := JoinPath(AProjectDir, NIK_LOCK_FILENAME);

  if Length(ADesired) = 0 then
  begin
    if FileExists(LockPath) then
    begin
      SysUtils.DeleteFile(LockPath);
      Result := True;
    end;
    Exit;
  end;

  NewText := FormatLockFileText(ADesired);
  if FileExists(LockPath) then
  begin
    ExistingText := StringReplace(ReadFileTextUtf8(LockPath), #13#10, #10, [rfReplaceAll]);
    if ExistingText = NewText then
      Exit(False);
  end;

  WriteFileTextUtf8(LockPath, NewText);
  Result := True;
end;

end.
