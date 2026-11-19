unit nik.manifest.resolve.test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, nik.types, nik.manifest.types, nik.manifest.io,
  nik.manifest.resolve;

type
  TManifestResolveTests = class(TTestCase)
  published
    procedure TestDebugProfileDefaults;
    procedure TestReleaseProfileResetsDefines;
    procedure TestTargetOverlaysSelectByOs;
    procedure TestTestOverlayForcesHeaptrcAndDropsEntry;
    procedure TestTestOverlayEntryIsRejected;
    procedure TestTestOverlayOutputIsRejected;
    procedure TestUnknownProfileIsRejected;
    procedure TestMissingToolchainIsRejected;
  end;

implementation

const
  MANIFEST_TEXT =
    'program:' + LineEnding +
    '  name: demo' + LineEnding +
    '  entry: src/main.pas' + LineEnding +
    '  toolchain:' + LineEnding +
    '    fpc: 3.2.2' + LineEnding +
    '  build:' + LineEnding +
    '    defines: [BASE]' + LineEnding +
    '    unitPaths: [src]' + LineEnding +
    '  targets:' + LineEnding +
    '    unix:' + LineEnding +
    '      build:' + LineEnding +
    '        unitPaths: [src/unix]' + LineEnding +
    '    windows:' + LineEnding +
    '      build:' + LineEnding +
    '        unitPaths: [src/win]' + LineEnding +
    '  profiles:' + LineEnding +
    '    release:' + LineEnding +
    '      build:' + LineEnding +
    '        defines: ["$reset", ONLY_REL]' + LineEnding +
    '  test:' + LineEnding +
    '    build:' + LineEnding +
    '      defines: [TESTING]' + LineEnding;

function Parse(const AText: string): TParsedManifest;
begin
  Result := ParseManifestText(AText, 'c:\proj\nik.yaml', 'c:\proj');
end;

function Contains(const AList: TStringArray; const AValue: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AList) do
    if SameText(AList[I], AValue) then
      Exit(True);
  Result := False;
end;

procedure TManifestResolveTests.TestDebugProfileDefaults;
var
  R: TResolvedManifest;
begin
  R := ResolveManifestConfig(Parse(MANIFEST_TEXT), 'debug', 'x86_64', 'win64');
  AssertEquals('demo', R.ProjectName);
  AssertEquals('3.2.2', R.FpcSpec);
  AssertTrue(Contains(R.Defines, 'DEBUG'));
  AssertTrue(Contains(R.Defines, 'BASE'));
  AssertFalse(Contains(R.Defines, 'RELEASE'));
  AssertTrue(R.Assertions);
  AssertEquals('bin/demo', R.Output);
end;

procedure TManifestResolveTests.TestReleaseProfileResetsDefines;
var
  R: TResolvedManifest;
begin
  R := ResolveManifestConfig(Parse(MANIFEST_TEXT), 'release', 'x86_64', 'win64');
  AssertEquals(1, Length(R.Defines));
  AssertEquals('ONLY_REL', R.Defines[0]);
  AssertEquals('none', R.DebugInfo);
end;

procedure TManifestResolveTests.TestTargetOverlaysSelectByOs;
var
  Win, Lin: TResolvedManifest;
begin
  Win := ResolveManifestConfig(Parse(MANIFEST_TEXT), 'debug', 'x86_64', 'win64');
  Lin := ResolveManifestConfig(Parse(MANIFEST_TEXT), 'debug', 'x86_64', 'linux');
  AssertTrue(Contains(Win.UnitPaths, 'src/win'));
  AssertFalse(Contains(Win.UnitPaths, 'src/unix'));
  AssertTrue(Contains(Lin.UnitPaths, 'src/unix'));
  AssertFalse(Contains(Lin.UnitPaths, 'src/win'));
end;

procedure TManifestResolveTests.TestTestOverlayForcesHeaptrcAndDropsEntry;
var
  R: TResolvedManifest;
begin
  R := ResolveManifestConfig(Parse(MANIFEST_TEXT), 'debug', 'x86_64', 'win64', True, False);
  AssertTrue(R.ForTest);
  AssertTrue(R.Heaptrc);
  AssertTrue(R.Assertions);
  AssertEquals('', R.Entry);
  AssertEquals('', R.Output);
  AssertTrue(Contains(R.Defines, 'TESTING'));
end;

procedure TManifestResolveTests.TestTestOverlayEntryIsRejected;
begin
  try
    Parse('program:' + LineEnding + '  entry: m.pas' + LineEnding + '  test:' + LineEnding +
      '    entry: tests/all.pas' + LineEnding);
    Fail('Expected ENikError for test.entry');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('no longer supported', E.Message) > 0);
  end;
end;

procedure TManifestResolveTests.TestTestOverlayOutputIsRejected;
begin
  try
    Parse('package:' + LineEnding + '  test:' + LineEnding + '    output: bin/x' + LineEnding);
    Fail('Expected ENikError for test.output');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('no longer supported', E.Message) > 0);
  end;
end;

procedure TManifestResolveTests.TestUnknownProfileIsRejected;
begin
  try
    ResolveManifestConfig(Parse(MANIFEST_TEXT), 'nightly', 'x86_64', 'win64');
    Fail('Expected ENikError for an unknown profile');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('nightly', E.Message) > 0);
  end;
end;

procedure TManifestResolveTests.TestMissingToolchainIsRejected;
begin
  try
    ResolveManifestConfig(
      Parse('program:' + LineEnding + '  entry: main.pas' + LineEnding),
      'debug', 'x86_64', 'win64');
    Fail('Expected ENikError for a missing toolchain.fpc');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('toolchain.fpc', E.Message) > 0);
  end;
end;

initialization
  RegisterTest(TManifestResolveTests);
end.
