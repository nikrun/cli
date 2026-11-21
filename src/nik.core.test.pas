unit nik.core.test;

{$mode objfpc}{$H+}

{ fpcunit tests for the nik CLI core units (YAML, lockfile, fetch, SDK index/manifest, manifest names,
  starter identifiers, filesystem helpers, archives, output paths). Ported from the former
  tests/nik_unit_tests.pas; run with 
ik test (heaptrc leak checking is part of the test overlay). }

interface

uses
  fpcunit, testregistry;

type
  TNikCoreTests = class(TTestCase)
  published
    procedure TestApostropheInsidePlainScalar;
    procedure TestRealQuotesStillWork;
    procedure TestTabsOnlyBreakRealContent;
    procedure TestAsInteger;
    procedure TestAnchorsAliasesAndTagsAreRejected;
    procedure TestFlowNestingIsBounded;
    procedure TestScalarWriterRoundTrip;
    procedure TestLockFileWithApostrophesRoundTrips;
    procedure TestLockRejectsNonHexRev;
    procedure TestGitFetchRejectsNonHexCommit;
    procedure TestManifestNameRules;
    procedure TestManifestRejectsUnsafeName;
    procedure TestStarterIdentifiers;
    procedure TestWriteFileReplacesAtomically;
    procedure TestMoveDirectoryFailsFastOnPermanentErrors;
    procedure TestDeleteDoesNotFollowDirectoryLinks;
    procedure TestTarGzExtraction;
    procedure TestTarGzRejectsTraversal;
    procedure TestZipExtraction;
    procedure TestZipRejectsTraversal;
    procedure TestUnsupportedArchiveFormat;
    procedure TestOutputPathExtensions;
    procedure TestSafePathHelpers;
    procedure TestSdkIndexRejectsUnsafeNames;
    procedure TestRemoteEntryNeedsChecksum;
    procedure TestSdkManifestRejectsEscapingPaths;
  end;

implementation

uses
  SysUtils, Classes, Process, Contnrs, Zipper, zstream, libtar,
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  nik.types,
  nik.fs,
  nik.paths,
  nik.yaml,
  nik.pkg.types,
  nik.pkg.lock,
  nik.pkg.fetch,
  nik.sdk.config,
  nik.manifest.types,
  nik.manifest.io,
  nik.archive,
  nik.compiler.types,
  nik.project,
  nik.cmd.init;

type
  TTestProc = procedure;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  TAssert.AssertTrue(AMessage, ACondition);
end;

procedure CheckEqStr(const AActual, AExpected, AContext: string);
begin
  TAssert.AssertEquals(AContext, AExpected, AActual);
end;

{ ---- nik.yaml helpers ---- }

function ScalarOf(ARoot: TYamlNode; const AKey: string): string;
var
  Node: TYamlNode;
begin
  Node := ARoot.Find(AKey);
  if (Node = nil) or (Node.Kind <> ynkScalar) then
    raise Exception.CreateFmt('Key ''%s'' is missing or not a scalar.', [AKey]);
  Result := Node.ScalarValue;
end;

function ParseScalarValue(const ALine: string; out AQuoted: Boolean): string;
var
  Root: TYamlNode;
begin
  Root := ParseYamlText(ALine, 'test.yaml');
  try
    Result := ScalarOf(Root, 'k');
    AQuoted := Root.Find('k').Quoted;
  finally
    Root.Free;
  end;
end;

procedure CheckParsesTo(const AText, AKey, AExpected, AContext: string);
var
  Root: TYamlNode;
begin
  Root := ParseYamlText(AText, 'test.yaml');
  try
    CheckEqStr(ScalarOf(Root, AKey), AExpected, AContext);
  finally
    Root.Free;
  end;
end;

procedure CheckParseError(const AText, AMessagePart, AContext: string);
var
  Root: TYamlNode;
  Msg: string;
begin
  Msg := '';
  Root := nil;
  try
    try
      Root := ParseYamlText(AText, 'test.yaml');
    except
      on E: ENikError do
        Msg := E.Message;
    end;
  finally
    Root.Free;
  end;
  Check(Msg <> '', AContext + ': parse error expected');
  Check(Pos(AMessagePart, Msg) > 0, AContext + ': message "' + Msg + '" should contain "' + AMessagePart + '"');
end;

{ ---- nik.yaml: quotes inside plain scalars ---- }

procedure TNikCoreTests.TestApostropheInsidePlainScalar;
var
  Root, Authors: TYamlNode;
begin
  CheckParsesTo('description: Don''t panic', 'description', 'Don''t panic', 'apostrophe in plain value');
  CheckParsesTo('description: say "hi" there', 'description', 'say "hi" there', 'double quotes inside plain value');
  CheckParsesTo('description: it''s fine # trailing comment', 'description', 'it''s fine', 'comment after apostrophe');
  CheckParsesTo('a: x'#10'description: rock ''n'' roll', 'description', 'rock ''n'' roll', 'apostrophes after blanks');

  Root := ParseYamlText('authors: [Tino O''Brien, "Dan, Jr.", ''Zoe''''s'']', 'test.yaml');
  try
    Authors := Root.Find('authors');
    Check((Authors <> nil) and (Authors.Kind = ynkSequence) and (Authors.Count = 3), 'flow sequence with apostrophe has 3 items');
    CheckEqStr(Authors.GetItem(0).ScalarValue, 'Tino O''Brien', 'flow item with apostrophe');
    CheckEqStr(Authors.GetItem(1).ScalarValue, 'Dan, Jr.', 'quoted flow item keeps comma');
    CheckEqStr(Authors.GetItem(2).ScalarValue, 'Zoe''s', 'single-quoted flow item with doubled apostrophe');
  finally
    Root.Free;
  end;

  Root := ParseYamlText('people:'#10'  - Tino O''Brien'#10'  - ''quoted # not a comment'''#10'  - name: D''Arcy', 'test.yaml');
  try
    Authors := Root.Find('people');
    Check((Authors <> nil) and (Authors.Count = 3), 'block sequence has 3 items');
    CheckEqStr(Authors.GetItem(0).ScalarValue, 'Tino O''Brien', 'block item with apostrophe');
    CheckEqStr(Authors.GetItem(1).ScalarValue, 'quoted # not a comment', 'quoted block item keeps hash');
    CheckEqStr(ScalarOf(Authors.GetItem(2), 'name'), 'D''Arcy', 'mapping item with apostrophe');
  finally
    Root.Free;
  end;

  Root := ParseYamlText('m: {who: O''Neil, "k": ''v''}', 'test.yaml');
  try
    CheckEqStr(ScalarOf(Root.Find('m'), 'who'), 'O''Neil', 'flow mapping value with apostrophe');
    CheckEqStr(ScalarOf(Root.Find('m'), 'k'), 'v', 'flow mapping quoted key and value');
  finally
    Root.Free;
  end;
end;

procedure TNikCoreTests.TestRealQuotesStillWork;
begin
  CheckParsesTo('k: ''it''''s''', 'k', 'it''s', 'single-quoted with doubled apostrophe');
  CheckParsesTo('k: "x # y"', 'k', 'x # y', 'double-quoted keeps hash');
  CheckParsesTo('k: ''x # y'' # comment', 'k', 'x # y', 'single-quoted keeps hash, comment stripped');
  CheckParsesTo('"quoted key": v', 'quoted key', 'v', 'double-quoted key');
  CheckParsesTo('k: "a\tb\n"', 'k', 'a'#9'b'#10, 'escapes in double quotes');
  CheckParseError('k: ''oops', 'quoted scalar', 'unterminated single quote');
  CheckParseError('k: "oops', 'quoted scalar', 'unterminated double quote');
  CheckParseError('k: [''oops, b]', 'quoted scalar', 'unterminated quote in flow sequence');
end;

{ ---- nik.yaml: tabs, integers, anchors, depth ---- }

procedure TNikCoreTests.TestTabsOnlyBreakRealContent;
begin
  CheckParsesTo('a: 1'#10#9#10'b: 2', 'b', '2', 'tab-only blank line');
  CheckParsesTo('a: 1'#10#9'# comment'#10'b: 2', 'b', '2', 'tab-indented comment line');
  CheckParseError('a:'#10#9'b: 2', 'Tabs are not allowed', 'tab-indented content');
end;

procedure TNikCoreTests.TestAsInteger;
  procedure CheckInt(const AValue: string; AExpectOk: Boolean; AExpected: Integer);
  var
    Root: TYamlNode;
    N: Integer;
    Ok: Boolean;
  begin
    Root := ParseYamlText('k: ' + AValue, 'test.yaml');
    try
      N := 0;
      Ok := Root.Find('k').AsInteger(N);
      Check(Ok = AExpectOk, 'AsInteger(' + AValue + ') acceptance');
      if AExpectOk then
        Check(N = AExpected, 'AsInteger(' + AValue + ') value');
    finally
      Root.Free;
    end;
  end;
begin
  CheckInt('17', True, 17);
  CheckInt('-3', True, -3);
  CheckInt('+5', True, 5);
  CheckInt('0', True, 0);
  CheckInt('$FF', False, 0);
  CheckInt('0x1', False, 0);
  CheckInt('1.5', False, 0);
  CheckInt('12abc', False, 0);
  CheckInt('''17''', False, 0);
end;

procedure TNikCoreTests.TestAnchorsAliasesAndTagsAreRejected;
begin
  CheckParseError('k: *main', 'alias', 'alias');
  CheckParsesTo('k: &anchor value', 'k', 'value', 'anchor on a scalar');
  CheckParseError('k: !!str 5', 'tags are not supported', 'tag');
  CheckParsesTo('k: ''*main''', 'k', '*main', 'quoted alias-like text stays literal');
  CheckParsesTo('k: a*b&c!d', 'k', 'a*b&c!d', 'indicator characters inside a scalar');
end;

procedure TNikCoreTests.TestFlowNestingIsBounded;
var
  Deep, Shallow: string;
  Root: TYamlNode;
begin
  Shallow := 'k: ' + StringOfChar('[', 10) + StringOfChar(']', 10);
  Root := ParseYamlText(Shallow, 'test.yaml');
  Root.Free;
  Check(True, 'moderate flow nesting parses');

  Deep := 'k: ' + StringOfChar('[', 5000) + StringOfChar(']', 5000);
  CheckParseError(Deep, 'nested more than', 'deep flow nesting');
end;

{ ---- nik.yaml: writer round trip ---- }

procedure TNikCoreTests.TestScalarWriterRoundTrip;
const
  Samples: array[0..30] of string = (
    'plain', 'Don''t', 'it''s a "test"', 'a: b', 'a:b', 'foo:', ':', ': x', '# c', 'x #y', 'x#y',
    '-', '- a', '-a', '?', '? a', 'null', 'Null', '~', '', ' lead', 'trail ', 'tab'#9'inside', #9'lead',
    'line'#10'break', 'cr'#13'x', '"q"', '''q''', 'back\slash', '*x', '&x');
  More: array[0..9] of string = (
    '!x', '@x', '%x', '|x', '>x', 'a,b', '[x]', '{y}', 'https://github.com/o/r.git', 'C:\Users\x\y');
var
  I: Integer;
  Written: string;

  procedure RoundTrip(const AValue: string);
  var
    Root: TYamlNode;
    Node: TYamlNode;
  begin
    if YamlPlainScalarSafe(AValue) then
      Written := AValue
    else
      Written := YamlQuoteDouble(AValue);
    Root := ParseYamlText('k: ' + Written, 'test.yaml');
    try
      Node := Root.Find('k');
      Check((Node <> nil) and (Node.Kind = ynkScalar), 'scalar kind for "' + Written + '"');
      CheckEqStr(Node.ScalarValue, AValue, 'round trip of ' + Written);
    finally
      Root.Free;
    end;
  end;

begin
  for I := Low(Samples) to High(Samples) do
    RoundTrip(Samples[I]);
  for I := Low(More) to High(More) do
    RoundTrip(More[I]);

  Check(YamlPlainScalarSafe('https://github.com/o/r.git'), 'URLs stay unquoted');
  Check(YamlPlainScalarSafe('Don''t'), 'inner apostrophe stays unquoted');
  Check(YamlPlainScalarSafe('a-b'), 'inner dash stays unquoted');
  Check(not YamlPlainScalarSafe(''), 'empty value needs quotes');
  Check(not YamlPlainScalarSafe('null'), 'null needs quotes');
  Check(not YamlPlainScalarSafe('a: b'), 'colon-space needs quotes');
  Check(not YamlPlainScalarSafe('x #y'), 'space-hash needs quotes');
end;

{ ---- nik.pkg.lock: a lock file with apostrophes stays readable ---- }

procedure TNikCoreTests.TestLockFileWithApostrophesRoundTrips;
var
  Dir, Text: string;
  Pkgs: TLockedPackageArray;
  Loaded: TLockFile;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + Format('nik-unit-lock-%d', [GetProcessID]);
  DeleteDirectoryRecursive(Dir);
  EnsureDirExists(Dir);
  try
    SetLength(Pkgs, 2);
    Pkgs[0] := Default(TLockedPackage);
    Pkgs[0].Id := 'github.com/o''brien/lib';
    Pkgs[0].Kind := lpkGit;
    Pkgs[0].Url := 'https://github.com/o''brien/lib.git';
    Pkgs[0].Subpath := 'it''s here';
    Pkgs[0].Version := '1.2.3';
    Pkgs[0].Rev := StringOfChar('a', 40);
    Pkgs[0].Integrity := 'sha256-' + StringOfChar('b', 64);
    Pkgs[1] := Default(TLockedPackage);
    Pkgs[1].Id := '*odd # id';
    Pkgs[1].Kind := lpkArchive;
    Pkgs[1].Url := 'https://example.com/d''arcy.zip';
    Pkgs[1].Sha256 := StringOfChar('c', 64);

    Text := FormatLockFileText(Pkgs);
    WriteFileTextUtf8(IncludeTrailingPathDelimiter(Dir) + NIK_LOCK_FILENAME, Text);

    Loaded := LoadLockFile(Dir);
    Check(Length(Loaded.Packages) = 2, 'both lock entries load');
    Check(LockedPackageSetsMatch(Loaded.Packages, Pkgs), 'loaded lock matches the written packages');
  finally
    DeleteDirectoryRecursive(Dir);
  end;
end;

{ ---- nik.paths: safe names and relative paths ---- }

procedure TNikCoreTests.TestSafePathHelpers;
begin
  Check(IsSafePathSegment('nikrun-fpc-sdk-3.2.2-0d122c49-x86_64-win64'), 'regular sdk id is a safe segment');
  Check(IsSafePathSegment('sdk.zip'), 'file name is a safe segment');
  Check(IsSafePathSegment('my sdk'), 'inner space is allowed');
  Check(not IsSafePathSegment(''), 'empty segment');
  Check(not IsSafePathSegment('.'), 'dot segment');
  Check(not IsSafePathSegment('..'), 'dot-dot segment');
  Check(not IsSafePathSegment('...'), 'dots-only segment');
  Check(not IsSafePathSegment('a/b'), 'slash in segment');
  Check(not IsSafePathSegment('a\b'), 'backslash in segment');
  Check(not IsSafePathSegment('../x'), 'parent traversal in segment');
  Check(not IsSafePathSegment('C:'), 'drive colon in segment');
  Check(not IsSafePathSegment('a:stream'), 'alternate data stream in segment');
  Check(not IsSafePathSegment(' lead'), 'leading blank');
  Check(not IsSafePathSegment('a*b'), 'wildcard');
  Check(not IsSafePathSegment('a'#10'b'), 'control character');

  Check(IsSafeRelativePath('bin/x86_64-win64'), 'plain relative path');
  Check(IsSafeRelativePath('bin\x86_64-win64\fpc.exe'), 'backslash relative path');
  Check(IsSafeRelativePath('./source/rtl'), 'dot-prefixed relative path');
  Check(not IsSafeRelativePath(''), 'empty path');
  Check(not IsSafeRelativePath('../x'), 'leading parent segment');
  Check(not IsSafeRelativePath('a/../../x'), 'parent segment in the middle');
  Check(not IsSafeRelativePath('a\..\x'), 'backslash parent segment');
  Check(not IsSafeRelativePath('/etc/passwd'), 'rooted path');
  Check(not IsSafeRelativePath('\Windows'), 'rooted backslash path');
  Check(not IsSafeRelativePath('C:\Windows'), 'drive path');
end;

{ ---- nik.sdk.config: index and manifest hardening ---- }

procedure CheckEnikError(const AMessagePart, AContext: string; AProc: TTestProc);
var
  Msg: string;
begin
  Msg := '';
  try
    AProc;
  except
    on E: ENikError do
      Msg := E.Message;
  end;
  Check(Msg <> '', AContext + ': ENikError expected');
  Check(Pos(AMessagePart, Msg) > 0, AContext + ': message "' + Msg + '" should contain "' + AMessagePart + '"');
end;

var
  GIndexJson: string;
  GEntry: TRemoteSdkEntry;
  GSkipVerify: Boolean;
  GManifestDir: string;

procedure DoParseIndex;
begin
  ParseSdkIndexJson(GIndexJson);
end;

procedure DoValidateEntry;
begin
  ValidateRemoteSdkEntryForInstall(GEntry, GSkipVerify);
end;

procedure DoLoadManifest;
begin
  LoadSdkManifest(GManifestDir);
end;

function SdkIndexJson(const ASdkId, AFileName: string): string;
begin
  Result := '{"schemaVersion":1,"sdks":[{"sdkId":"' + ASdkId + '","fpcVersion":"3.2.2",' +
    '"targetOs":"win64","targetCpu":"x86_64","targetTriplet":"x86_64-win64",' +
    '"fileName":"' + AFileName + '","sha256":"' + StringOfChar('A', 64) + '",' +
    '"downloadUrl":"https://example.com/sdk.zip"}]}';
end;

procedure TNikCoreTests.TestSdkIndexRejectsUnsafeNames;
var
  Index: TSdkIndex;
begin
  Index := ParseSdkIndexJson(SdkIndexJson('nikrun-fpc-sdk-3.2.2-x86_64-win64', 'sdk.zip'));
  Check(Length(Index.Sdks) = 1, 'valid index entry parses');
  CheckEqStr(Index.Sdks[0].Sha256, StringOfChar('a', 64), 'sha256 is normalized to lower case');

  GIndexJson := SdkIndexJson('..', 'sdk.zip');
  CheckEnikError('sdkId', 'sdkId ..', @DoParseIndex);
  GIndexJson := SdkIndexJson('a/b', 'sdk.zip');
  CheckEnikError('sdkId', 'sdkId with slash', @DoParseIndex);
  GIndexJson := SdkIndexJson('good-id', '../../x');
  CheckEnikError('fileName', 'fileName traversal', @DoParseIndex);
  GIndexJson := SdkIndexJson('good-id', 'C:/x.zip');
  CheckEnikError('fileName', 'fileName with drive', @DoParseIndex);
end;

procedure TNikCoreTests.TestRemoteEntryNeedsChecksum;
begin
  GEntry := Default(TRemoteSdkEntry);
  GEntry.SdkId := 'sdk-1';
  GEntry.FileName := 'sdk-1.zip';
  GEntry.DownloadUrl := 'https://example.com/sdk-1.zip';
  GEntry.Sha256 := StringOfChar('a', 64);
  GSkipVerify := False;
  ValidateRemoteSdkEntryForInstall(GEntry, GSkipVerify);
  Check(True, 'complete entry is accepted');

  GEntry.Sha256 := '';
  CheckEnikError('no sha256', 'missing checksum', @DoValidateEntry);
  GEntry.Sha256 := '   ';
  CheckEnikError('no sha256', 'blank checksum', @DoValidateEntry);

  GSkipVerify := True;
  ValidateRemoteSdkEntryForInstall(GEntry, GSkipVerify);
  Check(True, '--skip-verify accepts an entry without checksum');

  GSkipVerify := False;
  GEntry.Sha256 := StringOfChar('a', 64);
  GEntry.DownloadUrl := '';
  CheckEnikError('no downloadUrl', 'missing url', @DoValidateEntry);
  GEntry.DownloadUrl := 'https://example.com/sdk-1.zip';
  GEntry.FileName := '';
  CheckEnikError('no valid fileName', 'missing file name', @DoValidateEntry);
  GEntry.FileName := '../sdk-1.zip';
  CheckEnikError('no valid fileName', 'traversing file name', @DoValidateEntry);
end;

function SdkManifestJson(const ASdkId, ABinDir, AFpcBinary: string): string;
begin
  Result := '{"schemaVersion":1,"sdkId":"' + ASdkId + '","fpcVersion":"3.2.2",' +
    '"targetOs":"win64","targetCpu":"x86_64","targetTriplet":"x86_64-win64",' +
    '"paths":{"binDir":"' + ABinDir + '","fpcBinary":"' + AFpcBinary + '",' +
    '"unitsDir":"units/x86_64-win64","rtlSourceDir":"source/rtl"}}';
end;

procedure TNikCoreTests.TestSdkManifestRejectsEscapingPaths;
var
  Manifest: TSdkManifest;
begin
  GManifestDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + Format('nik-unit-sdk-%d', [GetProcessID]);
  DeleteDirectoryRecursive(GManifestDir);
  EnsureDirExists(GManifestDir);
  try
    WriteFileTextUtf8(JoinPath(GManifestDir, 'sdk-manifest.json'),
      SdkManifestJson('nikrun-fpc-sdk-3.2.2-x86_64-win64', 'bin/x86_64-win64', 'bin/x86_64-win64/fpc.exe'));
    Manifest := LoadSdkManifest(GManifestDir);
    CheckEqStr(Manifest.SdkId, 'nikrun-fpc-sdk-3.2.2-x86_64-win64', 'valid manifest loads');

    WriteFileTextUtf8(JoinPath(GManifestDir, 'sdk-manifest.json'),
      SdkManifestJson('..', 'bin/x86_64-win64', 'bin/x86_64-win64/fpc.exe'));
    CheckEnikError('Invalid sdkId', 'sdkId ..', @DoLoadManifest);

    WriteFileTextUtf8(JoinPath(GManifestDir, 'sdk-manifest.json'),
      SdkManifestJson('.', 'bin/x86_64-win64', 'bin/x86_64-win64/fpc.exe'));
    CheckEnikError('Invalid sdkId', 'sdkId .', @DoLoadManifest);

    WriteFileTextUtf8(JoinPath(GManifestDir, 'sdk-manifest.json'),
      SdkManifestJson('good-id', '../outside', 'bin/x86_64-win64/fpc.exe'));
    CheckEnikError('paths.binDir', 'binDir traversal', @DoLoadManifest);

    WriteFileTextUtf8(JoinPath(GManifestDir, 'sdk-manifest.json'),
      SdkManifestJson('good-id', 'bin/x86_64-win64', '/usr/bin/fpc'));
    CheckEnikError('paths.fpcBinary', 'rooted fpcBinary', @DoLoadManifest);
  finally
    DeleteDirectoryRecursive(GManifestDir);
  end;
end;

{ ---- nik.pkg.lock / nik.pkg.fetch: commit hashes never reach git or the cache unchecked ---- }

var
  GLockDir: string;
  GEvilRev: string;

procedure DoLoadLock;
begin
  LoadLockFile(GLockDir);
end;

procedure DoEnsureGitPackage;
var
  Commit, CacheDir, Integrity: string;
begin
  EnsureGitPackageCached('https://example.com/lib.git', GEvilRev, '', Commit, CacheDir, Integrity);
end;

function GitLockText(const ARev: string): string;
begin
  Result := 'lockVersion: 1'#10 +
    'packages:'#10 +
    '  - id: example.com/lib'#10 +
    '    kind: git'#10 +
    '    url: https://example.com/lib.git'#10 +
    '    rev: "' + ARev + '"'#10 +
    '    integrity: sha256-' + StringOfChar('b', 64) + #10;
end;

procedure TNikCoreTests.TestLockRejectsNonHexRev;
var
  Loaded: TLockFile;
begin
  GLockDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + Format('nik-unit-rev-%d', [GetProcessID]);
  DeleteDirectoryRecursive(GLockDir);
  EnsureDirExists(GLockDir);
  try
    WriteFileTextUtf8(JoinPath(GLockDir, NIK_LOCK_FILENAME), GitLockText(StringOfChar('a', 40)));
    Loaded := LoadLockFile(GLockDir);
    Check((Length(Loaded.Packages) = 1) and (Loaded.Packages[0].Rev = StringOfChar('a', 40)), 'hex rev loads');

    // 40 characters, so the old length check let it through
    WriteFileTextUtf8(JoinPath(GLockDir, NIK_LOCK_FILENAME), GitLockText('--upload-pack=' + StringOfChar('x', 26)));
    CheckEnikError('hexadecimal', 'git option as rev', @DoLoadLock);

    WriteFileTextUtf8(JoinPath(GLockDir, NIK_LOCK_FILENAME), GitLockText('..\\..\\..\\..\\..\\..\\..\\..\\..\\..\\..\\..\\x'));
    CheckEnikError('hexadecimal', 'path traversal as rev', @DoLoadLock);

    WriteFileTextUtf8(JoinPath(GLockDir, NIK_LOCK_FILENAME), GitLockText(StringOfChar('g', 40)));
    CheckEnikError('hexadecimal', 'non-hex letters as rev', @DoLoadLock);
  finally
    DeleteDirectoryRecursive(GLockDir);
  end;
end;

procedure TNikCoreTests.TestGitFetchRejectsNonHexCommit;
var
  Commit, CacheDir, Integrity: string;
begin
  Check(not FindCachedGitPackageDir('https://example.com/lib.git', '..\..\..\x1234567890',
    Commit, CacheDir, Integrity), 'cache lookup ignores a traversing commit');
  Check(not FindCachedGitPackageDir('https://example.com/lib.git', '--upload-pack=x',
    Commit, CacheDir, Integrity), 'cache lookup ignores a git option as commit');

  GEvilRev := '--upload-pack=touch-pwned';
  CheckEnikError('Invalid commit', 'fetch with a git option as commit', @DoEnsureGitPackage);
  GEvilRev := '';
  CheckEnikError('Invalid commit', 'fetch with an empty commit', @DoEnsureGitPackage);
end;

{ ---- project names and starter identifiers (nik.manifest.types, nik.manifest.io, nik.cmd.init) ---- }

procedure TNikCoreTests.TestManifestNameRules;
begin
  Check(IsValidManifestName(mkProgram, 'my-app'), 'program name with dash');
  Check(IsValidManifestName(mkProgram, 'Acme.Tools'), 'program name with dot');
  Check(IsValidManifestName(mkProgram, 'my app'), 'program name with space');
  Check(not IsValidManifestName(mkProgram, ''), 'empty program name');
  Check(not IsValidManifestName(mkProgram, '../../x'), 'program name with traversal');
  Check(not IsValidManifestName(mkProgram, 'a/b'), 'program name with slash');
  Check(not IsValidManifestName(mkLibrary, 'a\b'), 'library name with backslash');
  Check(not IsValidManifestName(mkLibrary, 'C:x'), 'library name with drive colon');
  Check(not IsValidManifestName(mkLibrary, 'lib*'), 'library name with wildcard');
  Check(IsValidManifestName(mkPackage, 'my-pkg'), 'package name');
  Check(IsValidManifestName(mkPackage, 'owner/pkg'), 'package name with owner prefix');
  Check(not IsValidManifestName(mkPackage, '../pkg'), 'package name with traversal');
  Check(not IsValidManifestName(mkPackage, '/abs/pkg'), 'rooted package name');
end;

var
  GManifestText: string;

procedure DoParseManifest;
var
  Parsed: TParsedManifest;
begin
  Parsed := ParseManifestText(GManifestText, 'nik.yaml', GetTempDir(False));
  if Parsed.ManifestPath = '<never>' then
    raise Exception.Create('unreachable');
end;

function ProgramManifestText(const AName: string): string;
begin
  Result := 'schemaVersion: 1'#10 +
    'program:'#10 +
    '  name: ' + AName + #10 +
    '  entry: src/main.pas'#10 +
    '  toolchain:'#10 +
    '    fpc: 3.2.2'#10;
end;

procedure TNikCoreTests.TestManifestRejectsUnsafeName;
begin
  GManifestText := ProgramManifestText('Acme.Tools');
  DoParseManifest;
  Check(True, 'manifest with a dotted program name parses');

  GManifestText := ProgramManifestText('../../x');
  CheckEnikError('Invalid ''program.name''', 'program name traversal', @DoParseManifest);
  GManifestText := ProgramManifestText('"a/b"');
  CheckEnikError('Invalid ''program.name''', 'program name with slash', @DoParseManifest);
end;

procedure TNikCoreTests.TestStarterIdentifiers;
begin
  CheckEqStr(DeriveStarterIdentifier(mkProgram, 'my-app'), 'MyApp', 'camel case');
  CheckEqStr(DeriveStarterIdentifier(mkProgram, 'end'), 'EndApp', 'reserved word as program name');
  CheckEqStr(DeriveStarterIdentifier(mkLibrary, 'unit'), 'UnitUnit', 'reserved word as library name');
  CheckEqStr(DeriveStarterIdentifier(mkPackage, 'types'), 'TypesUnit', 'RTL unit name as package unit');
  CheckEqStr(DeriveStarterIdentifier(mkPackage, 'Math'), 'MathUnit', 'RTL unit name keeps no case');
  CheckEqStr(DeriveStarterIdentifier(mkLibrary, 'System'), 'SystemUnit', 'System as library unit');
  CheckEqStr(DeriveStarterIdentifier(mkProgram, 'math'), 'Math', 'a program may share a unit name');
  CheckEqStr(DeriveStarterIdentifier(mkPackage, 'strutils-extra'), 'StrutilsExtra', 'longer names are untouched');
  CheckEqStr(DeriveStarterIdentifier(mkProgram, '1st app'), 'Project1stApp', 'leading digit');
end;

{ ---- nik.fs: atomic writes, permanent move failures, directory links ---- }

var
  GMoveSrc, GMoveDest: string;

procedure DoMoveDirectory;
begin
  MoveDirectoryAtomic(GMoveSrc, GMoveDest);
end;

function NewTempTestDir(const APrefix: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + Format('%s-%d', [APrefix, GetProcessID]);
  DeleteDirectoryRecursive(Result);
  EnsureDirExists(Result);
end;

function CountDirectoryEntries(const ADir: string): Integer;
var
  Rec: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, Rec) = 0 then
  begin
    repeat
      if (Rec.Name <> '.') and (Rec.Name <> '..') then
        Inc(Result);
    until FindNext(Rec) <> 0;
    FindClose(Rec);
  end;
end;

procedure TNikCoreTests.TestWriteFileReplacesAtomically;
var
  Dir, Target: string;
begin
  Dir := NewTempTestDir('nik-unit-write');
  try
    Target := JoinPath(Dir, 'config.json');
    WriteFileTextUtf8(Target, 'first');
    WriteFileTextUtf8(Target, 'second and longer');
    CheckEqStr(ReadFileTextUtf8(Target), 'second and longer', 'second write replaces the content');
    WriteFileTextUtf8(Target, 'x');
    CheckEqStr(ReadFileTextUtf8(Target), 'x', 'a shorter write leaves nothing of the old content');
    WriteFileTextUtf8(Target, '');
    CheckEqStr(ReadFileTextUtf8(Target), '', 'an empty write empties the file');
    Check(CountDirectoryEntries(Dir) = 1, 'no temporary file is left behind');
    WriteFileTextUtf8(JoinPath(JoinPath(Dir, 'sub'), 'new.txt'), 'in a new directory');
    CheckEqStr(ReadFileTextUtf8(JoinPath(JoinPath(Dir, 'sub'), 'new.txt')), 'in a new directory', 'missing directories are created');
  finally
    DeleteDirectoryRecursive(Dir);
  end;
end;

procedure TNikCoreTests.TestMoveDirectoryFailsFastOnPermanentErrors;
var
  Dir: string;
  Started: QWord;
begin
  Dir := NewTempTestDir('nik-unit-move');
  try
    GMoveSrc := JoinPath(Dir, 'src');
    GMoveDest := JoinPath(Dir, 'dest');
    EnsureDirExists(GMoveSrc);
    EnsureDirExists(GMoveDest);
    WriteFileTextUtf8(JoinPath(GMoveSrc, 'a.txt'), 'a');
    WriteFileTextUtf8(JoinPath(GMoveDest, 'b.txt'), 'b');

    Started := GetTickCount64;
    // The destination exists and is not empty: retrying cannot help, so the error must come at once
    // and carry the reason from the operating system.
    CheckEnikError('Failed to move directory', 'move onto an existing directory', @DoMoveDirectory);
    Check(GetTickCount64 - Started < 1500, 'a permanent move failure is reported without retrying for seconds');

    DeleteDirectoryRecursive(GMoveDest);
    MoveDirectoryAtomic(GMoveSrc, GMoveDest);
    Check(FileExists(JoinPath(GMoveDest, 'a.txt')) and (not DirectoryExists(GMoveSrc)), 'a normal move still works');
  finally
    DeleteDirectoryRecursive(Dir);
  end;
end;

procedure TNikCoreTests.TestDeleteDoesNotFollowDirectoryLinks;
var
  Dir, Root, Victim, Link: string;
  Proc: TProcess;
begin
  Dir := NewTempTestDir('nik-unit-link');
  try
    Root := JoinPath(Dir, 'root');
    Victim := JoinPath(Dir, 'victim');
    Link := JoinPath(Root, 'link');
    EnsureDirExists(Root);
    EnsureDirExists(Victim);
    WriteFileTextUtf8(JoinPath(Victim, 'keep.txt'), 'keep me');
    WriteFileTextUtf8(JoinPath(Root, 'own.txt'), 'own');

    {$IFDEF WINDOWS}
    Proc := TProcess.Create(nil);
    try
      Proc.Executable := 'cmd.exe';
      Proc.Parameters.Add('/c');
      Proc.Parameters.Add('mklink');
      Proc.Parameters.Add('/J');
      Proc.Parameters.Add(Link);
      Proc.Parameters.Add(Victim);
      Proc.Options := [poWaitOnExit, poNoConsole];
      Proc.Execute;
      Check(Proc.ExitStatus = 0, 'junction was created');
    finally
      Proc.Free;
    end;
    {$ELSE}
    Proc := nil;
    Check(fpSymlink(PChar(Victim), PChar(Link)) = 0, 'directory symlink was created');
    {$ENDIF}

    Check(DirectoryExists(Link), 'the link resolves to the victim directory');
    DeleteDirectoryRecursive(Root);
    Check(not DirectoryExists(Root), 'the tree with the link is removed');
    Check(FileExists(JoinPath(Victim, 'keep.txt')), 'the link target and its files are not touched');
  finally
    DeleteDirectoryRecursive(Dir);
  end;
end;

{ ---- nik.archive: extraction and traversal protection ---- }

var
  GArchivePath, GArchiveDest: string;

procedure DoExtractPackage;
begin
  ExtractPackageArchive(GArchivePath, GArchiveDest, True);
end;

procedure BuildTarGz(const AArchivePath: string; const ANames, AContents: array of string);
var
  TarMem: TMemoryStream;
  Writer: TTarWriter;
  Gz: TGZFileStream;
  I: Integer;
begin
  TarMem := TMemoryStream.Create;
  try
    Writer := TTarWriter.Create(TarMem);
    try
      for I := Low(ANames) to High(ANames) do
        Writer.AddString(AContents[I], ANames[I], Now);
    finally
      Writer.Free;
    end;
    Gz := TGZFileStream.Create(AArchivePath, gzOpenWrite);
    try
      if TarMem.Size > 0 then
        Gz.WriteBuffer(TarMem.Memory^, TarMem.Size);
    finally
      Gz.Free;
    end;
  finally
    TarMem.Free;
  end;
end;

procedure BuildZip(const AArchivePath: string; const ANames, AContents: array of string);
var
  Zip: TZipper;
  Streams: TObjectList;
  S: TStringStream;
  I: Integer;
begin
  Streams := TObjectList.Create(True);
  Zip := TZipper.Create;
  try
    Zip.FileName := AArchivePath;
    for I := Low(ANames) to High(ANames) do
    begin
      S := TStringStream.Create(AContents[I]);
      Streams.Add(S);
      Zip.Entries.AddFileEntry(S, ANames[I]);
    end;
    Zip.ZipAllFiles;
  finally
    Zip.Free;
    Streams.Free;
  end;
end;

procedure CheckPackageExtracts(const AArchivePath, ADest: string; const AContext: string);
begin
  GArchivePath := AArchivePath;
  GArchiveDest := ADest;
  DoExtractPackage;
  Check(FileExists(JoinPath(ADest, 'a.txt')), AContext + ': file at the archive root after unwrapping');
  CheckEqStr(ReadFileTextUtf8(JoinPath(ADest, 'a.txt')), 'alpha', AContext + ': file content');
  CheckEqStr(ReadFileTextUtf8(JoinPath(JoinPath(ADest, 'sub'), 'b.txt')), 'beta', AContext + ': nested file content');
  Check(not DirectoryExists(JoinPath(ADest, 'pkg-1.0')), AContext + ': single wrapper directory is gone');
end;

procedure TNikCoreTests.TestTarGzExtraction;
var
  Dir, Archive, Dest: string;
begin
  Dir := NewTempTestDir('nik-unit-targz');
  try
    Archive := JoinPath(Dir, 'pkg.tar.gz');
    Dest := JoinPath(Dir, 'out');
    BuildTarGz(Archive, ['pkg-1.0/a.txt', 'pkg-1.0/sub/b.txt'], ['alpha', 'beta']);
    CheckPackageExtracts(Archive, Dest, 'tar.gz');
    Check(CountDirectoryEntries(Dest) = 2, 'tar.gz: nothing but the two extracted entries');
  finally
    DeleteDirectoryRecursive(Dir);
  end;
end;

procedure TNikCoreTests.TestTarGzRejectsTraversal;
var
  Dir: string;
begin
  Dir := NewTempTestDir('nik-unit-targz-evil');
  try
    GArchivePath := JoinPath(Dir, 'evil.tar.gz');
    GArchiveDest := JoinPath(Dir, 'out');
    BuildTarGz(GArchivePath, ['pkg/ok.txt', '../evil.txt'], ['fine', 'owned']);
    CheckEnikError('Unsafe tar archive entry', 'tar.gz with a parent-directory entry', @DoExtractPackage);
    Check(not FileExists(JoinPath(Dir, 'evil.txt')), 'nothing was written outside the destination');
  finally
    DeleteDirectoryRecursive(Dir);
  end;
end;

procedure TNikCoreTests.TestZipExtraction;
var
  Dir, Archive, Dest: string;
begin
  Dir := NewTempTestDir('nik-unit-zip');
  try
    Archive := JoinPath(Dir, 'pkg.zip');
    Dest := JoinPath(Dir, 'out');
    BuildZip(Archive, ['pkg-1.0/a.txt', 'pkg-1.0/sub/b.txt'], ['alpha', 'beta']);
    CheckPackageExtracts(Archive, Dest, 'zip');
  finally
    DeleteDirectoryRecursive(Dir);
  end;
end;

procedure TNikCoreTests.TestZipRejectsTraversal;
var
  Dir: string;
begin
  Dir := NewTempTestDir('nik-unit-zip-evil');
  try
    GArchivePath := JoinPath(Dir, 'evil.zip');
    GArchiveDest := JoinPath(Dir, 'out');
    BuildZip(GArchivePath, ['pkg/ok.txt', '../evil.txt'], ['fine', 'owned']);
    CheckEnikError('Unsafe archive entry', 'zip with a parent-directory entry', @DoExtractPackage);
    Check(not FileExists(JoinPath(Dir, 'evil.txt')), 'zip: nothing was written outside the destination');
  finally
    DeleteDirectoryRecursive(Dir);
  end;
end;

procedure TNikCoreTests.TestUnsupportedArchiveFormat;
begin
  GArchivePath := 'package.rar';
  GArchiveDest := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'nik-unit-never';
  CheckEnikError('Unsupported package archive format', 'unknown archive extension', @DoExtractPackage);
end;

{ ---- nik.project: output file names ---- }

procedure TNikCoreTests.TestOutputPathExtensions;
var
  Dir: string;

  function Out(const ARaw, AOs: string; AKind: TCompileArtifactKind): string;
  begin
    Result := ExtractFileName(ResolveOutputBinaryPath(Dir, ARaw, AOs, AKind));
  end;

begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'nik-unit-project';

  CheckEqStr(Out('bin/app', 'win64', cakExecutable), 'app.exe', 'plain executable name gets .exe on Windows');
  CheckEqStr(Out('bin/app.exe', 'win64', cakExecutable), 'app.exe', 'an explicit .exe stays');
  CheckEqStr(Out('bin/Acme.Tools', 'win64', cakExecutable), 'Acme.Tools.exe', 'a dot inside the name is not an extension (executable)');
  CheckEqStr(Out('bin/Acme.Tools', 'linux', cakExecutable), 'Acme.Tools', 'executables on Linux keep their name');
  CheckEqStr(Out('bin/tool.bin', 'linux', cakExecutable), 'tool.bin', 'a known artifact extension stays');

  CheckEqStr(Out('bin/foo', 'win64', cakSharedLibrary), 'foo.dll', 'library on Windows');
  CheckEqStr(Out('bin/foo.bar', 'win64', cakSharedLibrary), 'foo.bar.dll', 'a dot inside a library name is not an extension');
  CheckEqStr(Out('bin/foo', 'linux', cakSharedLibrary), 'libfoo.so', 'library on Linux gets prefix and suffix');
  CheckEqStr(Out('bin/foo.bar', 'linux', cakSharedLibrary), 'libfoo.bar.so', 'dotted library name on Linux');
  CheckEqStr(Out('bin/libfoo.so', 'linux', cakSharedLibrary), 'libfoo.so', 'an explicit .so stays');
  CheckEqStr(Out('bin/foo', 'darwin', cakSharedLibrary), 'libfoo.dylib', 'library on macOS');

  CheckEqStr(ResolveOutputBinaryPath(Dir, '', 'win64', cakCheckOnly), '', 'check-only without output has no file');
end;

initialization
  RegisterTest(TNikCoreTests);
end.
