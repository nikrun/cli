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
  nik.pkg.lock;

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

{ ---- runner ---- }

type
  TTestProc = procedure;

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
    WriteLn(Format('nik unit tests: %d checks passed.', [TestsPassed]));
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAILED: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
