unit nik.gen.test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, nik.types, nik.manifest.types, nik.gen;

type
  TGenTests = class(TTestCase)
  private
    FRoot: string;
    FProjectDir: string;
    FGenDir: string;
    FSdk: TInstalledSdk;
    function NewManifest: TResolvedManifest;
    function FpcresStubPath: string;
    procedure WriteProjectFile(const ARelPath, AContent: string);
    function ReadGenFile(const AName: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestPackageGeneratesNothing;
    procedure TestProgramWithoutWindowsSectionGetsOnlyTheUnit;
    procedure TestUnitIsRewrittenOnlyWhenItsContentChanges;
    procedure TestWindowsSectionBuildsResourceThroughTheCompiler;
    procedure TestUnchangedInputsSkipTheResourceCompiler;
    procedure TestChangedVersionRecompilesTheResource;
    procedure TestChangedIconRecompilesTheResource;
    procedure TestExtraResourcesAreCompiledAlongside;
    procedure TestManifestFileIsCopiedUnchanged;
    procedure TestNoResourceOnNonWindowsTargets;
    procedure TestNoResourceForTestBuilds;
    procedure TestMissingFilesAreReported;
    procedure TestMissingFpcresIsReported;
    procedure TestWarnsWhenNikManifestIsNotUsed;
    procedure TestNoWarningWhenEntryOrSiblingUsesNikManifest;
    procedure TestDiscardCompiledNikManifest;
  end;

implementation

var
  GStubCalls: Integer;
  GStubInputs: TStringArray;

procedure StubCompile(const AFpcres, AWorkDir: string; const AInputs: TStringArray;
  const AOutputRes: string);
var
  F: TStringList;
begin
  Inc(GStubCalls);
  GStubInputs := Copy(AInputs);
  F := TStringList.Create;
  try
    F.Add('stub resource ' + IntToStr(GStubCalls));
    F.SaveToFile(IncludeTrailingPathDelimiter(AWorkDir) + AOutputRes);
  finally
    F.Free;
  end;
end;

function Contains(const AList: TStringArray; const AValue: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AList) do
    if AList[I] = AValue then
      Exit(True);
  Result := False;
end;

procedure TGenTests.SetUp;
begin
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'nik-gen-test-' + IntToStr(GetTickCount64);
  FProjectDir := FRoot + PathDelim + 'proj';
  FGenDir := FRoot + PathDelim + 'gen';
  ForceDirectories(FProjectDir);
  GStubCalls := 0;
  GStubInputs := nil;

  FSdk := Default(TInstalledSdk);
  FSdk.InstallPath := FRoot + PathDelim + 'sdk';
  FSdk.Manifest.SdkId := 'test-sdk';
  FSdk.Manifest.FpcVersion := '3.3.1';
  FSdk.Manifest.TargetOs := 'win64';
  FSdk.Manifest.TargetCpu := 'x86_64';
  FSdk.Manifest.TargetTriplet := 'x86_64-win64';
  FSdk.Manifest.Paths.BinDir := 'bin';
  ForceDirectories(FSdk.InstallPath + PathDelim + 'bin');
  // The compiler is stubbed, but the SDK must still contain a file called fpcres.
  with TStringList.Create do
  try
    Add('stub');
    SaveToFile(FpcresStubPath);
  finally
    Free;
  end;
end;

function TGenTests.FpcresStubPath: string;
begin
  Result := FSdk.InstallPath + PathDelim + 'bin' + PathDelim +
    {$IFDEF WINDOWS}'fpcres.exe'{$ELSE}'fpcres'{$ENDIF};
end;

procedure TGenTests.TearDown;

  procedure RemoveTree(const ADir: string);
  var
    SR: TSearchRec;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        if (SR.Attr and faDirectory) <> 0 then
          RemoveTree(IncludeTrailingPathDelimiter(ADir) + SR.Name)
        else
          DeleteFile(IncludeTrailingPathDelimiter(ADir) + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    RemoveDir(ADir);
  end;

begin
  RemoveTree(FRoot);
end;

function TGenTests.NewManifest: TResolvedManifest;
begin
  Result := Default(TResolvedManifest);
  Result.Kind := mkProgram;
  Result.ProjectDir := FProjectDir;
  Result.ManifestPath := FProjectDir + PathDelim + 'nik.yaml';
  Result.ProjectName := 'demo';
  Result.ProjectVersion := '1.2.3';
  Result.ProfileName := 'debug';
  Result.Entry := 'src/demo.pas';
  Result.Output := 'bin/demo';
end;

procedure TGenTests.WriteProjectFile(const ARelPath, AContent: string);
var
  Path: string;
  F: TStringList;
begin
  Path := FProjectDir + PathDelim + StringReplace(ARelPath, '/', PathDelim, [rfReplaceAll]);
  ForceDirectories(ExtractFileDir(Path));
  F := TStringList.Create;
  try
    F.Text := AContent;
    F.SaveToFile(Path);
  finally
    F.Free;
  end;
end;

function TGenTests.ReadGenFile(const AName: string): string;
var
  F: TStringList;
begin
  F := TStringList.Create;
  try
    F.LoadFromFile(FGenDir + PathDelim + AName);
    Result := F.Text;
  finally
    F.Free;
  end;
end;

procedure TGenTests.TestPackageGeneratesNothing;
var
  M: TResolvedManifest;
  G: TGeneratedFiles;
begin
  M := NewManifest;
  M.Kind := mkPackage;
  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertFalse(G.Generated);
  AssertFalse(G.HasResource);
  AssertFalse(DirectoryExists(FGenDir));
end;

procedure TGenTests.TestProgramWithoutWindowsSectionGetsOnlyTheUnit;
var
  G: TGeneratedFiles;
  Src: string;
begin
  G := GenerateProjectFiles(NewManifest, FSdk, FGenDir, @StubCompile);
  AssertTrue(G.Generated);
  AssertFalse(G.HasResource);
  AssertTrue(G.UnitChanged);
  AssertEquals(FGenDir, G.Dir);
  AssertEquals(0, GStubCalls);
  AssertTrue(FileExists(FGenDir + PathDelim + 'nikmanifest.pas'));
  AssertFalse(FileExists(FGenDir + PathDelim + 'windows.rc'));
  Src := ReadGenFile('nikmanifest.pas');
  AssertTrue(Pos('ProjectName = ''demo''', Src) > 0);
  AssertTrue(Pos('ProjectVersion = ''1.2.3''', Src) > 0);
  AssertTrue(Pos('BuildTarget = ''x86_64-win64''', Src) > 0);
  AssertEquals(0, Pos('{$R', Src));
end;

procedure TGenTests.TestUnitIsRewrittenOnlyWhenItsContentChanges;
var
  M: TResolvedManifest;
  G: TGeneratedFiles;
begin
  M := NewManifest;
  GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertFalse('same content: nothing to rebuild', G.UnitChanged);
  M.ProjectVersion := '2.0.0';
  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertTrue(G.UnitChanged);
  AssertTrue(Pos('ProjectVersion = ''2.0.0''', ReadGenFile('nikmanifest.pas')) > 0);

  M.ProjectVersion := '   ';
  GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertTrue('blank version falls back to 0.1.0', Pos('ProjectVersion = ''0.1.0''', ReadGenFile('nikmanifest.pas')) > 0);
end;

procedure TGenTests.TestWindowsSectionBuildsResourceThroughTheCompiler;
var
  M: TResolvedManifest;
  G: TGeneratedFiles;
begin
  WriteProjectFile('assets/demo.ico', 'ICON');
  M := NewManifest;
  M.Windows.Present := True;
  M.Windows.Icon := 'assets/demo.ico';
  M.Windows.HasManifest := True;
  M.Windows.ExecutionLevel := 'requireAdministrator';
  WriteProjectFile('src/demo.pas', 'program demo; uses nikmanifest; begin end.');

  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertTrue(G.HasResource);
  AssertTrue(G.UnitChanged);
  AssertEquals(1, GStubCalls);
  AssertEquals(1, Length(GStubInputs));
  AssertEquals('windows.rc', GStubInputs[0]);
  AssertTrue(FileExists(FGenDir + PathDelim + 'windows.res'));
  AssertTrue(FileExists(FGenDir + PathDelim + 'icon.ico'));
  AssertTrue(Pos('requireAdministrator', ReadGenFile('app.manifest')) > 0);
  AssertTrue(Pos('1 ICON "icon.ico"', ReadGenFile('windows.rc')) > 0);
  AssertTrue(Pos('1 24 "app.manifest"', ReadGenFile('windows.rc')) > 0);
  AssertTrue(Pos('{$R windows.res}', ReadGenFile('nikmanifest.pas')) > 0);
  AssertEquals(0, Length(G.Warnings));
end;

procedure TGenTests.TestUnchangedInputsSkipTheResourceCompiler;
var
  M: TResolvedManifest;
  G: TGeneratedFiles;
begin
  WriteProjectFile('assets/demo.ico', 'ICON');
  WriteProjectFile('src/demo.pas', 'program demo; uses nikmanifest; begin end.');
  M := NewManifest;
  M.Windows.Present := True;
  M.Windows.Icon := 'assets/demo.ico';
  GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertEquals(1, GStubCalls);
  AssertFalse(G.UnitChanged);
  AssertTrue(G.HasResource);
end;

procedure TGenTests.TestChangedVersionRecompilesTheResource;
var
  M: TResolvedManifest;
  G: TGeneratedFiles;
begin
  WriteProjectFile('src/demo.pas', 'program demo; uses nikmanifest; begin end.');
  M := NewManifest;
  M.Windows.Present := True;
  GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  M.ProjectVersion := 'v0.2.0-build.16-channel.stable';
  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertEquals(2, GStubCalls);
  AssertTrue(G.UnitChanged);
  AssertTrue(Pos('FILEVERSION 0,2,0,16', ReadGenFile('windows.rc')) > 0);
end;

procedure TGenTests.TestChangedIconRecompilesTheResource;
var
  M: TResolvedManifest;
begin
  WriteProjectFile('assets/demo.ico', 'ICON ONE');
  WriteProjectFile('src/demo.pas', 'program demo; uses nikmanifest; begin end.');
  M := NewManifest;
  M.Windows.Present := True;
  M.Windows.Icon := 'assets/demo.ico';
  GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  WriteProjectFile('assets/demo.ico', 'ICON TWO, longer');
  GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertEquals(2, GStubCalls);
end;

procedure TGenTests.TestExtraResourcesAreCompiledAlongside;
var
  M: TResolvedManifest;
begin
  WriteProjectFile('assets/extra.rc', '2 RCDATA { "x" }');
  WriteProjectFile('src/demo.pas', 'program demo; uses nikmanifest; begin end.');
  M := NewManifest;
  M.Windows.Present := True;
  SetLength(M.Windows.Resources, 1);
  M.Windows.Resources[0] := 'assets/extra.rc';
  GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertEquals(2, Length(GStubInputs));
  AssertEquals('windows.rc', GStubInputs[0]);
  AssertTrue(Pos('extra.rc', GStubInputs[1]) > 0);
  AssertEquals('extra resources are passed as absolute paths', ExpandFileName(GStubInputs[1]), GStubInputs[1]);
end;

procedure TGenTests.TestManifestFileIsCopiedUnchanged;
var
  M: TResolvedManifest;
begin
  WriteProjectFile('assets/custom.manifest', '<assembly custom="yes"/>');
  WriteProjectFile('src/demo.pas', 'program demo; uses nikmanifest; begin end.');
  M := NewManifest;
  M.Windows.Present := True;
  M.Windows.HasManifest := True;
  M.Windows.ManifestFile := 'assets/custom.manifest';
  GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertTrue(Pos('<assembly custom="yes"/>', ReadGenFile('app.manifest')) > 0);
  AssertEquals(0, Pos('requestedExecutionLevel', ReadGenFile('app.manifest')));
end;

procedure TGenTests.TestNoResourceOnNonWindowsTargets;
var
  M: TResolvedManifest;
  G: TGeneratedFiles;
begin
  M := NewManifest;
  M.Windows.Present := True;
  FSdk.Manifest.TargetOs := 'linux';
  FSdk.Manifest.TargetTriplet := 'x86_64-linux';
  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertTrue(G.Generated);
  AssertFalse(G.HasResource);
  AssertEquals(0, GStubCalls);
  AssertFalse(FileExists(FGenDir + PathDelim + 'windows.rc'));
  AssertEquals(0, Length(G.Warnings));
end;

procedure TGenTests.TestNoResourceForTestBuilds;
var
  M: TResolvedManifest;
  G: TGeneratedFiles;
begin
  M := NewManifest;
  M.ForTest := True;
  M.Windows.Present := True;
  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertTrue(G.Generated);
  AssertFalse(G.HasResource);
  AssertEquals(0, GStubCalls);
end;

procedure TGenTests.TestMissingFilesAreReported;
var
  M: TResolvedManifest;

  procedure ExpectFailure(const AFragment: string);
  begin
    try
      GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
      Fail('Expected ENikError containing "' + AFragment + '"');
    except
      on E: ENikError do
        AssertTrue(E.Message, Pos(AFragment, E.Message) > 0);
    end;
  end;

begin
  M := NewManifest;
  M.Windows.Present := True;
  M.Windows.Icon := 'assets/missing.ico';
  ExpectFailure('windows.icon file not found');

  M.Windows.Icon := '';
  M.Windows.HasManifest := True;
  M.Windows.ManifestFile := 'assets/missing.manifest';
  ExpectFailure('windows.manifest.file not found');

  M.Windows.HasManifest := False;
  M.Windows.ManifestFile := '';
  SetLength(M.Windows.Resources, 1);
  M.Windows.Resources[0] := 'assets/missing.rc';
  ExpectFailure('windows.resources file not found');
end;

procedure TGenTests.TestMissingFpcresIsReported;
var
  M: TResolvedManifest;
begin
  M := NewManifest;
  M.Windows.Present := True;
  DeleteFile(FpcresStubPath);
  try
    GenerateProjectFiles(M, FSdk, FGenDir);
    Fail('Expected ENikError for a SDK without fpcres');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('does not contain fpcres', E.Message) > 0);
  end;
end;

procedure TGenTests.TestWarnsWhenNikManifestIsNotUsed;
var
  M: TResolvedManifest;
  G: TGeneratedFiles;
begin
  WriteProjectFile('src/demo.pas', 'program demo; begin end.');
  M := NewManifest;
  M.Windows.Present := True;
  G := GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile);
  AssertEquals(1, Length(G.Warnings));
  AssertTrue(G.Warnings[0], Pos('uses nikmanifest', G.Warnings[0]) > 0);
end;

procedure TGenTests.TestNoWarningWhenEntryOrSiblingUsesNikManifest;
var
  M: TResolvedManifest;
begin
  M := NewManifest;
  M.Windows.Present := True;

  WriteProjectFile('src/demo.pas', 'program demo; uses NikManifest; begin end.');
  AssertEquals('entry mentions it (case-insensitive)', 0,
    Length(GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile).Warnings));

  WriteProjectFile('src/demo.pas', 'program demo; uses helper; begin end.');
  WriteProjectFile('src/helper.pas', 'unit helper; interface uses nikmanifest; implementation end.');
  AssertEquals('a sibling unit of the entry mentions it', 0,
    Length(GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile).Warnings));

  DeleteFile(FProjectDir + PathDelim + 'src' + PathDelim + 'helper.pas');
  WriteProjectFile('lib/other.pas', 'unit other; interface uses nikmanifest; implementation end.');
  AssertEquals(1, Length(GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile).Warnings));
  SetLength(M.UnitPaths, 1);
  M.UnitPaths[0] := 'lib';
  AssertEquals('a unit path of the manifest mentions it', 0,
    Length(GenerateProjectFiles(M, FSdk, FGenDir, @StubCompile).Warnings));
end;

procedure TGenTests.TestDiscardCompiledNikManifest;
var
  F: TStringList;
begin
  ForceDirectories(FGenDir);
  F := TStringList.Create;
  try
    F.Add('x');
    F.SaveToFile(FGenDir + PathDelim + 'nikmanifest.ppu');
    F.SaveToFile(FGenDir + PathDelim + 'nikmanifest.o');
    F.SaveToFile(FGenDir + PathDelim + 'other.ppu');
  finally
    F.Free;
  end;
  DiscardCompiledNikManifest(FGenDir);
  AssertFalse(FileExists(FGenDir + PathDelim + 'nikmanifest.ppu'));
  AssertFalse(FileExists(FGenDir + PathDelim + 'nikmanifest.o'));
  AssertTrue('other units stay', FileExists(FGenDir + PathDelim + 'other.ppu'));
  DiscardCompiledNikManifest(FGenDir + PathDelim + 'does-not-exist');
end;

initialization
  RegisterTest(TGenTests);
end.
