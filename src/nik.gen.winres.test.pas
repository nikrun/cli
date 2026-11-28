unit nik.gen.winres.test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, nik.types, nik.manifest.types, nik.gen.winres;

type
  TWinResTests = class(TTestCase)
  published
    procedure TestWideStringKeepsPlainAsciiAndEscapesTheRest;
    procedure TestWideStringEscapesHexDigitAfterEscape;
    procedure TestWideStringDecodesUtf8;
    procedure TestEffectiveVersionPrefersExplicitWindowsVersion;
    procedure TestEffectiveVersionDerivesFromVersionText;
    procedure TestEffectiveVersionFallsBackToZero;
    procedure TestManifestXmlDefaults;
    procedure TestManifestXmlDpiAndSwitches;
    procedure TestManifestXmlSupportedSystems;
    procedure TestRcSourceDerivesDefaults;
    procedure TestRcSourceUsesExplicitValuesAndFlags;
    procedure TestRcSourceForLibrary;
    procedure TestRcSourceWithoutIconAndManifest;
  end;

implementation

function Manifest(AKind: TManifestKind = mkProgram): TResolvedManifest;
begin
  Result := Default(TResolvedManifest);
  Result.Kind := AKind;
  Result.ProjectName := 'my-app';
  Result.Description := 'Sample app';
  Result.Output := 'bin/my-app';
end;

procedure TWinResTests.TestWideStringKeepsPlainAsciiAndEscapesTheRest;
begin
  AssertEquals('L"Hello, World 1.2"', RcWideString('Hello, World 1.2'));
  AssertEquals('L"a\x005Cz\x0022y"', RcWideString('a\z"y'));
  // 'b' and 'c' are hex digits and directly follow an escape, so they are escaped as well
  AssertEquals('L"a\x005C\x0062\x0022\x0063"', RcWideString('a\b"c'));
  AssertEquals('L"line\x000Anext"', RcWideString('line' + #10 + 'next'));
  AssertEquals('L""', RcWideString(''));
end;

procedure TWinResTests.TestWideStringEscapesHexDigitAfterEscape;
begin
  // 'B' directly after \x00A9 would be read as part of the escape
  AssertEquals('L"\x00A9\x0042 and"', RcWideString(#$C2#$A9'B and'));
  AssertEquals('L"\x00A9 B"', RcWideString(#$C2#$A9' B'));
end;

procedure TWinResTests.TestWideStringDecodesUtf8;
begin
  AssertEquals('L"\x00E4\x00F6\x00FC"', RcWideString(#$C3#$A4#$C3#$B6#$C3#$BC));
  AssertEquals('L"\x20AC"', RcWideString(#$E2#$82#$AC));
end;

procedure TWinResTests.TestEffectiveVersionPrefersExplicitWindowsVersion;
var
  W: TResolvedWindows;
  V: TWindowsVersion;
begin
  W := Default(TResolvedWindows);
  W.Version := '9.8.7.6';
  V := EffectiveWindowsVersion(W, '1.2.3');
  AssertEquals(9, V[0]);
  AssertEquals(6, V[3]);
end;

procedure TWinResTests.TestEffectiveVersionDerivesFromVersionText;
var
  V: TWindowsVersion;
begin
  V := EffectiveWindowsVersion(Default(TResolvedWindows), 'v0.2.0-build.16-channel.stable');
  AssertEquals(0, V[0]);
  AssertEquals(2, V[1]);
  AssertEquals(0, V[2]);
  AssertEquals(16, V[3]);
end;

procedure TWinResTests.TestEffectiveVersionFallsBackToZero;
var
  V: TWindowsVersion;
begin
  V := EffectiveWindowsVersion(Default(TResolvedWindows), 'latest');
  AssertEquals(0, V[0] + V[1] + V[2] + V[3]);
end;

procedure TWinResTests.TestManifestXmlDefaults;
var
  Xml: string;
begin
  Xml := BuildWindowsManifestXml(Default(TResolvedWindows));
  AssertTrue(Pos('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>', Xml) = 1);
  AssertTrue(Pos('requestedExecutionLevel level="asInvoker" uiAccess="false"', Xml) > 0);
  AssertTrue('win10 is the default supported OS', Pos('{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}', Xml) > 0);
  AssertEquals('no windowsSettings without switches', 0, Pos('windowsSettings', Xml));
  AssertTrue(Pos('</assembly>', Xml) > 0);
end;

procedure TWinResTests.TestManifestXmlDpiAndSwitches;
var
  W: TResolvedWindows;
  Xml: string;
begin
  W := Default(TResolvedWindows);
  W.ExecutionLevel := 'requireAdministrator';
  W.DpiAwareness := 'perMonitorV2';
  W.HasLongPaths := True;
  W.LongPaths := True;
  W.HasUtf8 := True;
  W.Utf8 := True;
  Xml := BuildWindowsManifestXml(W);
  AssertTrue(Pos('level="requireAdministrator"', Xml) > 0);
  AssertTrue(Pos('>true/pm</dpiAware>', Xml) > 0);
  AssertTrue(Pos('>PerMonitorV2,PerMonitor</dpiAwareness>', Xml) > 0);
  AssertTrue(Pos('<longPathAware', Xml) > 0);
  AssertTrue(Pos('>UTF-8</activeCodePage>', Xml) > 0);

  W.DpiAwareness := 'system';
  W.HasLongPaths := False;
  W.HasUtf8 := False;
  Xml := BuildWindowsManifestXml(W);
  AssertTrue(Pos('>true</dpiAware>', Xml) > 0);
  AssertTrue(Pos('>System</dpiAwareness>', Xml) > 0);
  AssertEquals(0, Pos('longPathAware', Xml));
  AssertEquals(0, Pos('activeCodePage', Xml));

  W.DpiAwareness := 'perMonitor';
  Xml := BuildWindowsManifestXml(W);
  AssertTrue(Pos('>true/pm</dpiAware>', Xml) > 0);
  AssertTrue(Pos('>PerMonitor</dpiAwareness>', Xml) > 0);

  W.DpiAwareness := 'none';
  AssertEquals(0, Pos('dpiAware', BuildWindowsManifestXml(W)));

  W.HasLongPaths := True;
  W.LongPaths := False;
  AssertEquals('longPaths: false emits nothing', 0, Pos('longPathAware', BuildWindowsManifestXml(W)));
end;

procedure TWinResTests.TestManifestXmlSupportedSystems;
var
  W: TResolvedWindows;
  Xml: string;
begin
  W := Default(TResolvedWindows);
  SetLength(W.SupportedOS, 4);
  W.SupportedOS[0] := 'win7';
  W.SupportedOS[1] := 'win8';
  W.SupportedOS[2] := 'win81';
  W.SupportedOS[3] := 'win10';
  Xml := BuildWindowsManifestXml(W);
  AssertTrue(Pos('{35138b9a-5d96-4fbd-8e2d-a2440225f93a}', Xml) > 0);
  AssertTrue(Pos('{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}', Xml) > 0);
  AssertTrue(Pos('{1f676c76-80e1-4239-95bb-83d0f6d0da78}', Xml) > 0);
  AssertTrue(Pos('{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}', Xml) > 0);

  W.SupportedOS[0] := 'win95';
  try
    BuildWindowsManifestXml(W);
    Fail('Expected ENikError for an unknown supportedOS');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('win95', E.Message) > 0);
  end;
end;

procedure TWinResTests.TestRcSourceDerivesDefaults;
var
  Rc: string;
  M: TResolvedManifest;
begin
  M := Manifest;
  M.Windows.Present := True;
  Rc := BuildWindowsRcSource(M, 'v0.2.0-build.16-channel.stable', True, True);
  AssertTrue(Pos('1 ICON "icon.ico"', Rc) > 0);
  AssertTrue(Pos('1 24 "app.manifest"', Rc) > 0);
  AssertTrue(Pos('FILEVERSION 0,2,0,16', Rc) > 0);
  AssertTrue(Pos('PRODUCTVERSION 0,2,0,16', Rc) > 0);
  AssertTrue(Pos('FILEFLAGS 0x0L', Rc) > 0);
  AssertTrue(Pos('FILETYPE 0x1L', Rc) > 0);
  AssertTrue(Pos('VALUE "FileDescription", ' + RcWideString('Sample app'), Rc) > 0);
  AssertTrue(Pos('VALUE "FileVersion", ' + RcWideString('v0.2.0-build.16-channel.stable'), Rc) > 0);
  AssertTrue(Pos('VALUE "InternalName", ' + RcWideString('my-app'), Rc) > 0);
  AssertTrue(Pos('VALUE "OriginalFilename", ' + RcWideString('my-app.exe'), Rc) > 0);
  AssertTrue(Pos('VALUE "ProductName", ' + RcWideString('my-app'), Rc) > 0);
  AssertTrue(Pos('VALUE "ProductVersion"', Rc) > 0);
  AssertEquals('empty optional strings are omitted', 0, Pos('CompanyName', Rc));
  AssertEquals(0, Pos('LegalCopyright', Rc));
  AssertEquals(0, Pos('Comments', Rc));
  AssertTrue(Pos('VALUE "Translation", 0x0409, 1200', Rc) > 0);

  M.Description := '';
  AssertTrue('description falls back to the product name',
    Pos('VALUE "FileDescription", ' + RcWideString('my-app'), BuildWindowsRcSource(M, '1.0.0', False, False)) > 0);
end;

procedure TWinResTests.TestRcSourceUsesExplicitValuesAndFlags;
var
  Rc: string;
  M: TResolvedManifest;
begin
  M := Manifest;
  M.Windows.Present := True;
  M.Windows.Version := '3.1.4.1';
  M.Windows.Company := 'Example GmbH';
  M.Windows.Product := 'My App';
  M.Windows.Description := 'Does things';
  M.Windows.Copyright := #$C2#$A9' 2026';
  M.Windows.Comments := 'hello';
  M.Windows.InternalName := 'internal';
  M.Windows.OriginalFilename := 'orig.exe';
  SetLength(M.Windows.Flags, 3);
  M.Windows.Flags[0] := 'debug';
  M.Windows.Flags[1] := 'prerelease';
  M.Windows.Flags[2] := 'privateBuild';
  Rc := BuildWindowsRcSource(M, '1.0.0', False, False);
  AssertTrue(Pos('FILEVERSION 3,1,4,1', Rc) > 0);
  AssertTrue(Pos('FILEFLAGS 0xBL', Rc) > 0);
  AssertEquals(0, Pos('ICON', Rc));
  AssertEquals(0, Pos(' 24 ', Rc));
  AssertTrue(Pos('VALUE "CompanyName", L"Example GmbH"', Rc) > 0);
  AssertTrue(Pos('VALUE "LegalCopyright", L"\x00A9 2026"', Rc) > 0);
  AssertTrue(Pos('VALUE "Comments", L"hello"', Rc) > 0);
  AssertTrue(Pos('VALUE "InternalName", L"internal"', Rc) > 0);
  AssertTrue(Pos('VALUE "OriginalFilename", L"orig.exe"', Rc) > 0);
  AssertTrue(Pos('VALUE "ProductName", L"My App"', Rc) > 0);
  AssertTrue(Pos('VALUE "FileDescription", L"Does things"', Rc) > 0);

  M.Windows.Flags[0] := 'beta';
  try
    BuildWindowsRcSource(M, '1.0.0', False, False);
    Fail('Expected ENikError for an unknown flag');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('beta', E.Message) > 0);
  end;
end;

procedure TWinResTests.TestRcSourceForLibrary;
var
  Rc: string;
  M: TResolvedManifest;
begin
  M := Manifest(mkLibrary);
  M.Windows.Present := True;
  Rc := BuildWindowsRcSource(M, '1.0.0', True, True);
  AssertTrue(Pos('2 24 "app.manifest"', Rc) > 0);
  AssertTrue(Pos('FILETYPE 0x2L', Rc) > 0);
  AssertTrue(Pos('VALUE "OriginalFilename", ' + RcWideString('my-app.dll'), Rc) > 0);

  M.Output := 'out\native.dll';
  AssertTrue('an explicit extension is kept',
    Pos('VALUE "OriginalFilename", ' + RcWideString('native.dll'), BuildWindowsRcSource(M, '1.0.0', False, False)) > 0);
end;

procedure TWinResTests.TestRcSourceWithoutIconAndManifest;
var
  Rc: string;
  M: TResolvedManifest;
begin
  M := Manifest;
  M.Output := '';
  M.Windows.Present := True;
  Rc := BuildWindowsRcSource(M, '', False, False);
  AssertEquals(0, Pos('ICON', Rc));
  AssertEquals(0, Pos(' 24 ', Rc));
  AssertTrue('without any version the zero version is used', Pos('FILEVERSION 0,0,0,0', Rc) > 0);
  AssertTrue(Pos('VALUE "FileVersion", ' + RcWideString('0.0.0.0'), Rc) > 0);
  AssertTrue('output defaults to the project name', Pos(RcWideString('my-app.exe'), Rc) > 0);
end;

initialization
  RegisterTest(TWinResTests);
end.
