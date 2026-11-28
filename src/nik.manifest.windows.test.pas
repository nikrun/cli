unit nik.manifest.windows.test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, nik.types, nik.manifest.types, nik.manifest.io,
  nik.manifest.resolve;

type
  TWindowsSectionTests = class(TTestCase)
  published
    procedure TestSectionIsParsedAndResolved;
    procedure TestEmptySectionIsPresent;
    procedure TestNoSectionIsNotPresent;
    procedure TestOverlaysMergeFieldByField;
    procedure TestFlagsMergeAdditivelyAndHonourReset;
    procedure TestChoicesAreCanonicalised;
    procedure TestUnknownKeyIsRejected;
    procedure TestInvalidVersionIsRejected;
    procedure TestInvalidIconExtensionIsRejected;
    procedure TestInvalidResourceExtensionIsRejected;
    procedure TestInvalidChoicesAreRejected;
    procedure TestManifestFileExcludesOtherKeys;
    procedure TestManifestFileConflictAcrossOverlaysIsRejected;
    procedure TestPackageRejectsWindowsSection;
    procedure TestTestOverlayRejectsWindowsSection;
    procedure TestNonMappingSectionsAreRejected;
  end;

implementation

const
  HEAD =
    'program:' + LineEnding +
    '  name: demo' + LineEnding +
    '  entry: src/main.pas' + LineEnding +
    '  toolchain:' + LineEnding +
    '    fpc: 3.3.1' + LineEnding;

  FULL_SECTION =
    '  windows:' + LineEnding +
    '    icon: assets/demo.ico' + LineEnding +
    '    version: 1.4.2.0' + LineEnding +
    '    info:' + LineEnding +
    '      company: Example GmbH' + LineEnding +
    '      product: Demo App' + LineEnding +
    '      description: "A demo"' + LineEnding +
    '      copyright: "Copyright 2026"' + LineEnding +
    '      comments: ""' + LineEnding +
    '      internalName: demo-int' + LineEnding +
    '      originalFilename: demo.exe' + LineEnding +
    '      flags: [prerelease]' + LineEnding +
    '    manifest:' + LineEnding +
    '      executionLevel: asInvoker' + LineEnding +
    '      dpiAwareness: perMonitorV2' + LineEnding +
    '      longPaths: true' + LineEnding +
    '      utf8: true' + LineEnding +
    '      supportedOS: [win10]' + LineEnding +
    '    resources:' + LineEnding +
    '      - assets/extra.rc' + LineEnding;

function Resolve(const AText, AProfile, AOs: string): TResolvedManifest;
begin
  Result := ResolveManifestConfig(ParseManifestText(AText, 'c:\proj\nik.yaml', 'c:\proj'),
    AProfile, 'x86_64', AOs);
end;

procedure ExpectError(const AText, AFragment: string);
begin
  try
    ResolveManifestConfig(ParseManifestText(AText, 'c:\proj\nik.yaml', 'c:\proj'),
      'debug', 'x86_64', 'win64', False, False, False);
    TAssert.Fail('Expected ENikError containing "' + AFragment + '"');
  except
    on E: ENikError do
      TAssert.AssertTrue(E.Message, Pos(AFragment, E.Message) > 0);
  end;
end;

procedure TWindowsSectionTests.TestSectionIsParsedAndResolved;
var
  W: TResolvedWindows;
begin
  W := Resolve(HEAD + FULL_SECTION, 'debug', 'win64').Windows;
  AssertTrue(W.Present);
  AssertEquals('assets/demo.ico', W.Icon);
  AssertEquals('1.4.2.0', W.Version);
  AssertEquals('Example GmbH', W.Company);
  AssertEquals('Demo App', W.Product);
  AssertEquals('A demo', W.Description);
  AssertEquals('Copyright 2026', W.Copyright);
  AssertEquals('', W.Comments);
  AssertEquals('demo-int', W.InternalName);
  AssertEquals('demo.exe', W.OriginalFilename);
  AssertEquals(1, Length(W.Flags));
  AssertEquals('prerelease', W.Flags[0]);
  AssertTrue(W.HasManifest);
  AssertEquals('asInvoker', W.ExecutionLevel);
  AssertEquals('perMonitorV2', W.DpiAwareness);
  AssertTrue(W.HasLongPaths and W.LongPaths);
  AssertTrue(W.HasUtf8 and W.Utf8);
  AssertEquals(1, Length(W.SupportedOS));
  AssertEquals('win10', W.SupportedOS[0]);
  AssertEquals('', W.ManifestFile);
  AssertEquals(1, Length(W.Resources));
  AssertEquals('assets/extra.rc', W.Resources[0]);
end;

procedure TWindowsSectionTests.TestEmptySectionIsPresent;
var
  W: TResolvedWindows;
begin
  W := Resolve(HEAD + '  windows:' + LineEnding, 'debug', 'win64').Windows;
  AssertTrue(W.Present);
  AssertFalse(W.HasManifest);
  AssertEquals('', W.Icon);

  W := Resolve(HEAD + '  windows:' + LineEnding + '    manifest:' + LineEnding, 'debug', 'win64').Windows;
  AssertTrue('an empty manifest mapping still asks for a manifest', W.HasManifest);
end;

procedure TWindowsSectionTests.TestNoSectionIsNotPresent;
begin
  AssertFalse(Resolve(HEAD, 'debug', 'win64').Windows.Present);
end;

procedure TWindowsSectionTests.TestOverlaysMergeFieldByField;
const
  TEXT =
    '  windows:' + LineEnding +
    '    icon: a.ico' + LineEnding +
    '    info:' + LineEnding +
    '      company: Base Co' + LineEnding +
    '      comments: base' + LineEnding +
    '    manifest:' + LineEnding +
    '      utf8: false' + LineEnding +
    '  targets:' + LineEnding +
    '    aarch64-win64:' + LineEnding +
    '      windows:' + LineEnding +
    '        info:' + LineEnding +
    '          comments: arm64' + LineEnding +
    '    windows:' + LineEnding +
    '      windows:' + LineEnding +
    '        manifest:' + LineEnding +
    '          utf8: true' + LineEnding +
    '  profiles:' + LineEnding +
    '    release:' + LineEnding +
    '      windows:' + LineEnding +
    '        icon: release.ico' + LineEnding;
var
  Dbg, Rel, Arm: TResolvedWindows;
begin
  Dbg := Resolve(HEAD + TEXT, 'debug', 'win64').Windows;
  AssertEquals('a.ico', Dbg.Icon);
  AssertEquals('Base Co', Dbg.Company);
  AssertEquals('base', Dbg.Comments);
  AssertTrue('targets.windows.windows overrides the base value', Dbg.Utf8);

  Rel := Resolve(HEAD + TEXT, 'release', 'win64').Windows;
  AssertEquals('release.ico', Rel.Icon);
  AssertEquals('Base Co', Rel.Company);

  Arm := ResolveManifestConfig(ParseManifestText(HEAD + TEXT, 'c:\proj\nik.yaml', 'c:\proj'),
    'debug', 'aarch64', 'win64').Windows;
  AssertEquals('arm64', Arm.Comments);
  AssertEquals('Base Co', Arm.Company);

  AssertEquals('base', Resolve(HEAD + TEXT, 'debug', 'linux').Windows.Comments);
end;

procedure TWindowsSectionTests.TestFlagsMergeAdditivelyAndHonourReset;
const
  TEXT =
    '  windows:' + LineEnding +
    '    info:' + LineEnding +
    '      flags: [prerelease]' + LineEnding +
    '  profiles:' + LineEnding +
    '    debug:' + LineEnding +
    '      windows:' + LineEnding +
    '        info:' + LineEnding +
    '          flags: [debug]' + LineEnding +
    '    release:' + LineEnding +
    '      windows:' + LineEnding +
    '        info:' + LineEnding +
    '          flags: ["$reset", privateBuild]' + LineEnding;
var
  Dbg, Rel: TResolvedWindows;
begin
  Dbg := Resolve(HEAD + TEXT, 'debug', 'win64').Windows;
  AssertEquals(2, Length(Dbg.Flags));
  AssertEquals('prerelease', Dbg.Flags[0]);
  AssertEquals('debug', Dbg.Flags[1]);

  Rel := Resolve(HEAD + TEXT, 'release', 'win64').Windows;
  AssertEquals(1, Length(Rel.Flags));
  AssertEquals('privateBuild', Rel.Flags[0]);
end;

procedure TWindowsSectionTests.TestChoicesAreCanonicalised;
var
  W: TResolvedWindows;
begin
  W := Resolve(HEAD +
    '  windows:' + LineEnding +
    '    info:' + LineEnding +
    '      flags: [PRIVATEBUILD, Debug]' + LineEnding +
    '    manifest:' + LineEnding +
    '      executionLevel: ASINVOKER' + LineEnding +
    '      dpiAwareness: permonitorv2' + LineEnding +
    '      supportedOS: [WIN81]' + LineEnding, 'debug', 'win64').Windows;
  AssertEquals('privateBuild', W.Flags[0]);
  AssertEquals('debug', W.Flags[1]);
  AssertEquals('asInvoker', W.ExecutionLevel);
  AssertEquals('perMonitorV2', W.DpiAwareness);
  AssertEquals('win81', W.SupportedOS[0]);
end;

procedure TWindowsSectionTests.TestUnknownKeyIsRejected;
begin
  ExpectError(HEAD + '  windows:' + LineEnding + '    icons: a.ico' + LineEnding, 'did you mean ''icon''');
  ExpectError(HEAD + '  windows:' + LineEnding + '    info:' + LineEnding + '      compny: x' + LineEnding,
    'did you mean ''company''');
  ExpectError(HEAD + '  windows:' + LineEnding + '    manifest:' + LineEnding + '      utf: true' + LineEnding,
    'did you mean ''utf8''');
end;

procedure TWindowsSectionTests.TestInvalidVersionIsRejected;
begin
  ExpectError(HEAD + '  windows:' + LineEnding + '    version: 1.2' + LineEnding, 'windows.version');
  ExpectError(HEAD + '  windows:' + LineEnding + '    version: 1.2.3.4.5' + LineEnding, 'windows.version');
  ExpectError(HEAD + '  windows:' + LineEnding + '    version: 70000.0.0' + LineEnding, 'windows.version');
end;

procedure TWindowsSectionTests.TestInvalidIconExtensionIsRejected;
begin
  ExpectError(HEAD + '  windows:' + LineEnding + '    icon: app.png' + LineEnding, 'must point to an .ico file');
end;

procedure TWindowsSectionTests.TestInvalidResourceExtensionIsRejected;
begin
  ExpectError(HEAD + '  windows:' + LineEnding + '    resources: [extra.txt]' + LineEnding,
    'must be .rc or .res files');
end;

procedure TWindowsSectionTests.TestInvalidChoicesAreRejected;
begin
  ExpectError(HEAD + '  windows:' + LineEnding + '    manifest:' + LineEnding +
    '      executionLevel: root' + LineEnding, 'asInvoker | highestAvailable | requireAdministrator');
  ExpectError(HEAD + '  windows:' + LineEnding + '    manifest:' + LineEnding +
    '      dpiAwareness: high' + LineEnding, 'perMonitorV2');
  ExpectError(HEAD + '  windows:' + LineEnding + '    manifest:' + LineEnding +
    '      supportedOS: [win95]' + LineEnding, 'win7 | win8 | win81 | win10');
  ExpectError(HEAD + '  windows:' + LineEnding + '    info:' + LineEnding +
    '      flags: [beta]' + LineEnding, 'debug | prerelease | privateBuild');
end;

procedure TWindowsSectionTests.TestManifestFileExcludesOtherKeys;
var
  W: TResolvedWindows;
begin
  W := Resolve(HEAD + '  windows:' + LineEnding + '    manifest:' + LineEnding +
    '      file: assets/custom.manifest' + LineEnding, 'debug', 'win64').Windows;
  AssertEquals('assets/custom.manifest', W.ManifestFile);
  AssertTrue(W.HasManifest);

  ExpectError(HEAD + '  windows:' + LineEnding + '    manifest:' + LineEnding +
    '      file: assets/custom.manifest' + LineEnding + '      utf8: true' + LineEnding,
    'cannot be combined');
end;

procedure TWindowsSectionTests.TestManifestFileConflictAcrossOverlaysIsRejected;
begin
  ExpectError(HEAD +
    '  windows:' + LineEnding +
    '    manifest:' + LineEnding +
    '      file: assets/custom.manifest' + LineEnding +
    '  profiles:' + LineEnding +
    '    debug:' + LineEnding +
    '      windows:' + LineEnding +
    '        manifest:' + LineEnding +
    '          dpiAwareness: system' + LineEnding,
    'cannot be combined');
end;

procedure TWindowsSectionTests.TestPackageRejectsWindowsSection;
begin
  ExpectError('package:' + LineEnding + '  windows:' + LineEnding + '    icon: a.ico' + LineEnding,
    'cannot specify ''windows''');
end;

procedure TWindowsSectionTests.TestTestOverlayRejectsWindowsSection;
begin
  ExpectError(HEAD + '  test:' + LineEnding + '    windows:' + LineEnding + '      icon: a.ico' + LineEnding,
    'Unknown key ''windows''');
end;

procedure TWindowsSectionTests.TestNonMappingSectionsAreRejected;
begin
  ExpectError(HEAD + '  windows: yes' + LineEnding, '''program.windows'' must be a mapping');
  ExpectError(HEAD + '  windows:' + LineEnding + '    info: yes' + LineEnding,
    '''program.windows.info'' must be a mapping');
  ExpectError(HEAD + '  windows:' + LineEnding + '    manifest: yes' + LineEnding,
    '''program.windows.manifest'' must be a mapping');
end;

initialization
  RegisterTest(TWindowsSectionTests);
end.
