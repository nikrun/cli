program nik_unit_tests;

{$mode objfpc}{$H+}

{ Unit tests for the nik CLI core units (src/nik.*.pas). Run through test-units.ps1,
  which compiles this program with heaptrc and fails on any unfreed memory block. }

uses
  SysUtils, Classes,
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
  nik.cmd.init;

type
  TTestProc = procedure;

var
  TestsPassed: Integer = 0;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise Exception.Create('Assertion failed: ' + AMessage);
  Inc(TestsPassed);
end;

procedure CheckEqStr(const AActual, AExpected, AContext: string);
begin
  if AActual <> AExpected then
    raise Exception.CreateFmt('%s: expected "%s", got "%s"', [AContext, AExpected, AActual]);
  Inc(TestsPassed);
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

procedure TestApostropheInsidePlainScalar;
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

procedure TestRealQuotesStillWork;
begin
  CheckParsesTo('k: ''it''''s''', 'k', 'it''s', 'single-quoted with doubled apostrophe');
  CheckParsesTo('k: "x # y"', 'k', 'x # y', 'double-quoted keeps hash');
  CheckParsesTo('k: ''x # y'' # comment', 'k', 'x # y', 'single-quoted keeps hash, comment stripped');
  CheckParsesTo('"quoted key": v', 'quoted key', 'v', 'double-quoted key');
  CheckParsesTo('k: "a\tb\n"', 'k', 'a'#9'b'#10, 'escapes in double quotes');
  CheckParseError('k: ''oops', 'Unterminated quoted string', 'unterminated single quote');
  CheckParseError('k: "oops', 'Unterminated quoted string', 'unterminated double quote');
  CheckParseError('k: [''oops, b]', 'Unterminated', 'unterminated quote in flow sequence');
end;

{ ---- nik.yaml: tabs, integers, anchors, depth ---- }

procedure TestTabsOnlyBreakRealContent;
begin
  CheckParsesTo('a: 1'#10#9#10'b: 2', 'b', '2', 'tab-only blank line');
  CheckParsesTo('a: 1'#10#9'# comment'#10'b: 2', 'b', '2', 'tab-indented comment line');
  CheckParseError('a:'#10#9'b: 2', 'Tab characters are not allowed', 'tab-indented content');
end;

procedure TestAsInteger;
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
  CheckInt('%101', False, 0);
  CheckInt('1.5', False, 0);
  CheckInt('-', False, 0);
  CheckInt('12abc', False, 0);
  CheckInt('''17''', False, 0);
end;

procedure TestAnchorsAliasesAndTagsAreRejected;
begin
  CheckParseError('k: *main', 'anchors, aliases and tags are not supported', 'alias');
  CheckParseError('k: &anchor value', 'anchors, aliases and tags are not supported', 'anchor');
  CheckParseError('k: !!str 5', 'anchors, aliases and tags are not supported', 'tag');
  CheckParsesTo('k: ''*main''', 'k', '*main', 'quoted alias-like text stays literal');
  CheckParsesTo('k: a*b&c!d', 'k', 'a*b&c!d', 'indicator characters inside a scalar');
end;

procedure TestFlowNestingIsBounded;
var
  Deep, Shallow: string;
  Root: TYamlNode;
begin
  Shallow := 'k: ' + StringOfChar('[', 10) + StringOfChar(']', 10);
  Root := ParseYamlText(Shallow, 'test.yaml');
  Root.Free;
  Check(True, 'moderate flow nesting parses');

  Deep := 'k: ' + StringOfChar('[', 5000) + StringOfChar(']', 5000);
  CheckParseError(Deep, 'nested too deeply', 'deep flow nesting');
end;

{ ---- nik.yaml: writer round trip ---- }

procedure TestScalarWriterRoundTrip;
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

procedure TestLockFileWithApostrophesRoundTrips;
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

procedure TestSafePathHelpers;
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

procedure TestSdkIndexRejectsUnsafeNames;
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

procedure TestRemoteEntryNeedsChecksum;
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

procedure TestSdkManifestRejectsEscapingPaths;
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

procedure TestLockRejectsNonHexRev;
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

    WriteFileTextUtf8(JoinPath(GLockDir, NIK_LOCK_FILENAME), GitLockText('..\..\..\..\..\..\..\..\..\..\..\..\x'));
    CheckEnikError('hexadecimal', 'path traversal as rev', @DoLoadLock);

    WriteFileTextUtf8(JoinPath(GLockDir, NIK_LOCK_FILENAME), GitLockText(StringOfChar('g', 40)));
    CheckEnikError('hexadecimal', 'non-hex letters as rev', @DoLoadLock);
  finally
    DeleteDirectoryRecursive(GLockDir);
  end;
end;

procedure TestGitFetchRejectsNonHexCommit;
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

procedure TestManifestNameRules;
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

procedure TestManifestRejectsUnsafeName;
begin
  GManifestText := ProgramManifestText('Acme.Tools');
  DoParseManifest;
  Check(True, 'manifest with a dotted program name parses');

  GManifestText := ProgramManifestText('../../x');
  CheckEnikError('Invalid ''program.name''', 'program name traversal', @DoParseManifest);
  GManifestText := ProgramManifestText('"a/b"');
  CheckEnikError('Invalid ''program.name''', 'program name with slash', @DoParseManifest);
end;

procedure TestStarterIdentifiers;
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

{ ---- runner ---- }

procedure RunTest(const AName: string; AProc: TTestProc);
begin
  Write(AName, ' ... ');
  AProc;
  WriteLn('ok');
end;

begin
  try
    RunTest('yaml: apostrophes inside plain scalars', @TestApostropheInsidePlainScalar);
    RunTest('yaml: real quotes still work', @TestRealQuotesStillWork);
    RunTest('yaml: tabs only break real content', @TestTabsOnlyBreakRealContent);
    RunTest('yaml: AsInteger accepts plain decimals only', @TestAsInteger);
    RunTest('yaml: anchors, aliases and tags are rejected', @TestAnchorsAliasesAndTagsAreRejected);
    RunTest('yaml: flow nesting is bounded', @TestFlowNestingIsBounded);
    RunTest('yaml: scalar writer round trip', @TestScalarWriterRoundTrip);
    RunTest('lock: apostrophes round trip', @TestLockFileWithApostrophesRoundTrips);
    RunTest('lock: non-hex rev is rejected', @TestLockRejectsNonHexRev);
    RunTest('fetch: non-hex commit never reaches git', @TestGitFetchRejectsNonHexCommit);
    RunTest('manifest: name rules', @TestManifestNameRules);
    RunTest('manifest: unsafe names are rejected', @TestManifestRejectsUnsafeName);
    RunTest('init: starter identifiers', @TestStarterIdentifiers);
    RunTest('paths: safe segments and relative paths', @TestSafePathHelpers);
    RunTest('sdk: index rejects unsafe names', @TestSdkIndexRejectsUnsafeNames);
    RunTest('sdk: remote entries need a checksum', @TestRemoteEntryNeedsChecksum);
    RunTest('sdk: manifest rejects escaping paths', @TestSdkManifestRejectsEscapingPaths);
    WriteLn(Format('nik unit tests: %d checks passed.', [TestsPassed]));
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAILED: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
