unit nik.gen;

{$mode objfpc}{$H+}

{ Writes the files nik generates for a program/library build into the project build cache: the unit
  'nikmanifest' (always) and, for Windows targets with a 'windows' section, the compiled Windows resource
  windows.res that the unit links (see internal-notes/specs/nik-yaml.md, sections 5 and 6). }

interface

uses
  SysUtils, nik.types, nik.manifest.types;

type
  { Compiles the .rc/.res inputs into AOutputRes; the default runs the SDK's fpcres. Tests inject a stub. }
  TWinResCompileProc = procedure(const AFpcres, AWorkDir: string; const AInputs: TStringArray;
    const AOutputRes: string);

  TGeneratedFiles = record
    Generated: Boolean;      // False for packages (nothing is generated)
    Dir: string;             // directory to add to the unit search path
    HasResource: Boolean;    // windows.res was produced and nikmanifest links it
    // The unit text or the resource changed: the compiled nikmanifest.ppu/.o must be rebuilt (FPC compares
    // source and .ppu times with 2 s resolution and does not track {$R} files).
    UnitChanged: Boolean;
    Warnings: TStringArray;
  end;

function GenerateProjectFiles(const AManifest: TResolvedManifest; const ASdk: TInstalledSdk;
  const AGenDir: string; ACompile: TWinResCompileProc = nil): TGeneratedFiles;

{ Only the unit nikmanifest, never the Windows resource (for tools that parse the project but do not link it,
  such as nik lsp). The unit then has no {$R} line. }
function GenerateNikManifestUnit(const AManifest: TResolvedManifest; const ASdk: TInstalledSdk;
  const AGenDir: string): TGeneratedFiles;

{ Deletes the compiled nikmanifest unit (.ppu/.o) from the unit output directory so the compiler
  rebuilds it; used when TGeneratedFiles.UnitChanged is set. }
procedure DiscardCompiledNikManifest(const AUnitOutputDir: string);

implementation

uses
  Classes, nik.fs, nik.paths, nik.compiler, nik.gen.manifest, nik.gen.winres;

const
  WINDOWS_RC_FILE = 'windows.rc';

procedure AppendStr(var AList: TStringArray; const AValue: string);
var
  N: Integer;
begin
  N := Length(AList);
  SetLength(AList, N + 1);
  AList[N] := AValue;
end;

procedure DiscardCompiledNikManifest(const AUnitOutputDir: string);
begin
  DeleteFile(JoinPath(AUnitOutputDir, NIKMANIFEST_UNIT_NAME + '.ppu'));
  DeleteFile(JoinPath(AUnitOutputDir, NIKMANIFEST_UNIT_NAME + '.o'));
end;

{ Returns True when the file was (re)written. }
function WriteTextIfChanged(const APath, AContent: string): Boolean;
begin
  Result := not (FileExists(APath) and (ReadFileTextUtf8(APath) = AContent));
  if Result then
    WriteFileTextUtf8(APath, AContent);
end;

function SameFileContent(const APathA, APathB: string): Boolean;
var
  A, B: TFileStream;
  BufA, BufB: array[0..8191] of Byte;
  ReadA, ReadB: LongInt;
begin
  Result := False;
  if (not FileExists(APathA)) or (not FileExists(APathB)) then
    Exit;
  A := TFileStream.Create(APathA, fmOpenRead or fmShareDenyNone);
  try
    B := TFileStream.Create(APathB, fmOpenRead or fmShareDenyNone);
    try
      if A.Size <> B.Size then
        Exit;
      repeat
        ReadA := A.Read(BufA, SizeOf(BufA));
        ReadB := B.Read(BufB, SizeOf(BufB));
        if (ReadA <> ReadB) or ((ReadA > 0) and (not CompareMem(@BufA, @BufB, ReadA))) then
          Exit;
      until ReadA <= 0;
      Result := True;
    finally
      B.Free;
    end;
  finally
    A.Free;
  end;
end;

{ Returns True when the destination was (re)written. }
function CopyFileIfChanged(const ASource, ADest: string): Boolean;
var
  Src, Dst: TFileStream;
begin
  Result := not SameFileContent(ASource, ADest);
  if not Result then
    Exit;
  Src := TFileStream.Create(ASource, fmOpenRead or fmShareDenyNone);
  try
    Dst := TFileStream.Create(ADest, fmCreate);
    try
      Dst.CopyFrom(Src, 0);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

function NewestFileAge(const APaths: TStringArray): LongInt;
var
  I: Integer;
  Age: LongInt;
begin
  Result := 0;
  for I := 0 to High(APaths) do
  begin
    Age := FileAge(APaths[I]);
    if Age > Result then
      Result := Age;
  end;
end;

procedure RunFpcres(const AFpcres, AWorkDir: string; const AInputs: TStringArray;
  const AOutputRes: string);
var
  Args: TStringArray;
  I, Code: Integer;
  Output: string;
  DurationMs: Int64;
begin
  Args := nil;
  for I := 0 to High(AInputs) do
    AppendStr(Args, AInputs[I]);
  AppendStr(Args, '-o');
  AppendStr(Args, AOutputRes);
  AppendStr(Args, '-of');
  AppendStr(Args, 'res');
  Code := ExecuteCompilerProcess(AFpcres, ExtractFileDir(AFpcres), AWorkDir, Args, Output, DurationMs);
  if (Code <> 0) or (not FileExists(JoinPath(AWorkDir, AOutputRes))) then
    raise ENikError.CreateFmt('fpcres failed to compile the Windows resource (exit %d):%s%s',
      [Code, LineEnding, Trim(Output)]);
end;

function FpcresPath(const ASdk: TInstalledSdk): string;
begin
  Result := JoinPath(JoinPath(ASdk.InstallPath, ASdk.Manifest.Paths.BinDir),
    {$IFDEF WINDOWS}'fpcres.exe'{$ELSE}'fpcres'{$ENDIF});
  if not FileExists(Result) then
    raise ENikError.CreateFmt('SDK ''%s'' does not contain fpcres (%s), which is needed to build the ''windows'' resource.',
      [ASdk.Manifest.SdkId, Result]);
end;

{ Returns True when windows.res was (re)compiled. }
function BuildWindowsResource(const AManifest: TResolvedManifest; const ASdk: TInstalledSdk;
  const AGenDir, AVersionText: string; ACompile: TWinResCompileProc): Boolean;
var
  Win: TResolvedWindows;
  IconSrc, ManifestSrc, IconDst, ManifestDst, RcPath, ResPath, Extra: string;
  HasIcon, HasManifest, Rewritten: Boolean;
  Inputs, Dependencies: TStringArray;
  I: Integer;
begin
  Result := False;
  Rewritten := False;
  Win := AManifest.Windows;
  Inputs := nil;
  Dependencies := nil;
  RcPath := JoinPath(AGenDir, WINDOWS_RC_FILE);
  ResPath := JoinPath(AGenDir, NIKMANIFEST_RESOURCE_FILE);

  HasIcon := Trim(Win.Icon) <> '';
  if HasIcon then
  begin
    IconSrc := ResolveRelativePath(AManifest.ProjectDir, Win.Icon);
    if not FileExists(IconSrc) then
      raise ENikError.CreateFmt('%s: windows.icon file not found: %s', [AManifest.ManifestPath, IconSrc]);
    IconDst := JoinPath(AGenDir, WINRES_ICON_FILE);
    if CopyFileIfChanged(IconSrc, IconDst) then
      Rewritten := True;
    AppendStr(Dependencies, IconDst);
  end;

  HasManifest := Win.HasManifest;
  if HasManifest then
  begin
    ManifestDst := JoinPath(AGenDir, WINRES_MANIFEST_FILE);
    if Trim(Win.ManifestFile) <> '' then
    begin
      ManifestSrc := ResolveRelativePath(AManifest.ProjectDir, Win.ManifestFile);
      if not FileExists(ManifestSrc) then
        raise ENikError.CreateFmt('%s: windows.manifest.file not found: %s',
          [AManifest.ManifestPath, ManifestSrc]);
      if CopyFileIfChanged(ManifestSrc, ManifestDst) then
        Rewritten := True;
    end
    else if WriteTextIfChanged(ManifestDst, BuildWindowsManifestXml(Win)) then
      Rewritten := True;
    AppendStr(Dependencies, ManifestDst);
  end;

  if WriteTextIfChanged(RcPath, BuildWindowsRcSource(AManifest, AVersionText, HasIcon, HasManifest)) then
    Rewritten := True;
  AppendStr(Dependencies, RcPath);
  AppendStr(Inputs, WINDOWS_RC_FILE);

  for I := 0 to High(Win.Resources) do
  begin
    Extra := ResolveRelativePath(AManifest.ProjectDir, Win.Resources[I]);
    if not FileExists(Extra) then
      raise ENikError.CreateFmt('%s: windows.resources file not found: %s', [AManifest.ManifestPath, Extra]);
    AppendStr(Inputs, Extra);
    AppendStr(Dependencies, Extra);
  end;

  // Recompile when nik rewrote one of its own inputs (file times only have second resolution) or when an
  // extra resource file is newer than the existing resource; otherwise keep incremental builds cheap.
  if (not Rewritten) and FileExists(ResPath) and (FileAge(ResPath) >= NewestFileAge(Dependencies)) then
    Exit;

  if Assigned(ACompile) then
    ACompile(FpcresPath(ASdk), AGenDir, Inputs, NIKMANIFEST_RESOURCE_FILE)
  else
    RunFpcres(FpcresPath(ASdk), AGenDir, Inputs, NIKMANIFEST_RESOURCE_FILE);
  Result := True;
end;

function SourceMentionsNikManifest(const APath: string): Boolean;
begin
  Result := FileExists(APath) and (Pos(NIKMANIFEST_UNIT_NAME, LowerCase(ReadFileTextUtf8(APath))) > 0);
end;

function ProjectUsesNikManifest(const AManifest: TResolvedManifest): Boolean;
var
  I: Integer;
  Dir, EntryPath: string;
  SR: TSearchRec;
  Dirs: TStringArray;
begin
  Result := False;
  EntryPath := ResolveRelativePath(AManifest.ProjectDir, AManifest.Entry);
  if SourceMentionsNikManifest(EntryPath) then
    Exit(True);

  Dirs := nil;
  AppendStr(Dirs, ExtractFileDir(EntryPath));
  for I := 0 to High(AManifest.UnitPaths) do
    AppendStr(Dirs, ResolveRelativePath(AManifest.ProjectDir, AManifest.UnitPaths[I]));

  for I := 0 to High(Dirs) do
  begin
    Dir := Dirs[I];
    if (Dir = '') or (not DirectoryExists(Dir)) then
      Continue;
    if FindFirst(JoinPath(Dir, '*.pas'), faAnyFile and (not faDirectory), SR) = 0 then
    try
      repeat
        if SourceMentionsNikManifest(JoinPath(Dir, SR.Name)) then
          Exit(True);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

function GenerateCore(const AManifest: TResolvedManifest; const ASdk: TInstalledSdk;
  const AGenDir: string; ABuildResource: Boolean; ACompile: TWinResCompileProc): TGeneratedFiles;
var
  VersionText: string;
begin
  Result := Default(TGeneratedFiles);
  Result.Dir := AGenDir;
  if AManifest.Kind = mkPackage then
    Exit;

  Result.Generated := True;
  EnsureDirExists(AGenDir);

  VersionText := Trim(AManifest.ProjectVersion);
  if VersionText = '' then
    VersionText := '0.1.0';

  Result.HasResource := ABuildResource and AManifest.Windows.Present
    and SameText(ASdk.Manifest.TargetOs, 'win64') and (not AManifest.ForTest);

  if Result.HasResource then
  begin
    if BuildWindowsResource(AManifest, ASdk, AGenDir, VersionText, ACompile) then
      Result.UnitChanged := True;
    if (Trim(AManifest.Entry) <> '') and (not ProjectUsesNikManifest(AManifest)) then
      AppendStr(Result.Warnings, Format(
        'windows section is set, but no source of this project mentions the unit ''%s'': the Windows resource is only linked when a unit named %s is used (add ''uses %s;'' to the program).',
        [NIKMANIFEST_UNIT_NAME, NIKMANIFEST_UNIT_NAME, NIKMANIFEST_UNIT_NAME]));
  end;

  if WriteTextIfChanged(JoinPath(AGenDir, NIKMANIFEST_UNIT_FILE),
       BuildNikManifestUnitSource(AManifest, VersionText, ASdk.Manifest.TargetTriplet,
         ASdk.Manifest.FpcVersion, Result.HasResource)) then
    Result.UnitChanged := True;
end;

function GenerateProjectFiles(const AManifest: TResolvedManifest; const ASdk: TInstalledSdk;
  const AGenDir: string; ACompile: TWinResCompileProc): TGeneratedFiles;
begin
  Result := GenerateCore(AManifest, ASdk, AGenDir, True, ACompile);
end;

function GenerateNikManifestUnit(const AManifest: TResolvedManifest; const ASdk: TInstalledSdk;
  const AGenDir: string): TGeneratedFiles;
begin
  Result := GenerateCore(AManifest, ASdk, AGenDir, False, nil);
end;

end.
