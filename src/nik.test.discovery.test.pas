unit nik.test.discovery.test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, nik.types, nik.test.discovery;

type
  TTestDiscoveryTests = class(TTestCase)
  private
    FTempDir: string;
    procedure WriteTemp(const ARelPath, AContent: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFileNameConvention;
    procedure TestScansUnitNameClassesAndMethods;
    procedure TestIgnoresCommentsAndStrings;
    procedure TestDetectsRegisterTest;
    procedure TestResolvesInheritedTestClassesAcrossUnits;
    procedure TestFilterMatching;
    procedure TestDiscoversFlatInRootsOnly;
    procedure TestRejectsUnitNameMismatch;
    procedure TestRejectsDuplicateUnitNames;
    procedure TestWarnsWhenRegisterTestIsMissing;
  end;

implementation

uses
  nik.paths, nik.fs;

const
  SAMPLE_UNIT =
    'unit sample.unit.test;' + LineEnding +
    'interface' + LineEnding +
    'uses fpcunit;' + LineEnding +
    'type' + LineEnding +
    '  TA = class(TTestCase)' + LineEnding +
    '  private' + LineEnding +
    '    procedure Helper;' + LineEnding +
    '  published' + LineEnding +
    '    procedure TestOne;' + LineEnding +
    '    procedure TestTwo(AValue: Integer);' + LineEnding +
    '    procedure TestThree;' + LineEnding +
    '  public' + LineEnding +
    '    procedure NotATest;' + LineEnding +
    '  end;' + LineEnding +
    'implementation' + LineEnding +
    'procedure TA.TestOne;' + LineEnding +
    'begin end;' + LineEnding +
    'procedure TA.TestThree;' + LineEnding +
    'begin end;' + LineEnding +
    'initialization' + LineEnding +
    '  RegisterTest(TA);' + LineEnding +
    'end.' + LineEnding;

procedure TTestDiscoveryTests.SetUp;
begin
  FTempDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'nik-discovery-test-' +
    IntToStr(GetTickCount64);
  EnsureDirExists(FTempDir);
end;

procedure TTestDiscoveryTests.TearDown;
begin
  if DirectoryExists(FTempDir) then
    DeleteDirectoryRecursive(FTempDir);
end;

procedure TTestDiscoveryTests.WriteTemp(const ARelPath, AContent: string);
var
  Path: string;
begin
  Path := JoinPath(FTempDir, ARelPath);
  EnsureDirExists(ExtractFileDir(Path));
  WriteFileTextUtf8(Path, AContent);
end;

procedure TTestDiscoveryTests.TestFileNameConvention;
begin
  AssertTrue(IsTestUnitFileName('semver_test.pas'));
  AssertTrue(IsTestUnitFileName('nik.pkg.semver.test.pas'));
  AssertTrue(IsTestUnitFileName('X_TEST.PP'));
  AssertTrue(IsTestUnitFileName('c:\proj\src\a.test.pp'));
  AssertFalse(IsTestUnitFileName('test.pas'));
  AssertFalse(IsTestUnitFileName('_test.pas'));
  AssertFalse(IsTestUnitFileName('semver.pas'));
  AssertFalse(IsTestUnitFileName('latest.pas'));
  AssertFalse(IsTestUnitFileName('semver_test.inc'));
end;

procedure TTestDiscoveryTests.TestScansUnitNameClassesAndMethods;
var
  Info: TTestUnitInfo;
begin
  Info := ScanTestUnitSource('sample.unit.test.pas', SAMPLE_UNIT);
  AssertEquals('sample.unit.test', Info.UnitName);
  AssertEquals(1, Info.UnitLine);
  AssertEquals(1, Length(Info.Classes));
  AssertEquals('TA', Info.Classes[0].Name);
  AssertEquals('TTestCase', Info.Classes[0].ParentName);
  AssertEquals(5, Info.Classes[0].Line);
  // Only parameterless published methods are tests
  AssertEquals(2, Length(Info.Classes[0].Methods));
  AssertEquals('TestOne', Info.Classes[0].Methods[0].Name);
  AssertEquals(9, Info.Classes[0].Methods[0].DeclLine);
  AssertEquals(16, Info.Classes[0].Methods[0].ImplLine);
  AssertEquals('TestThree', Info.Classes[0].Methods[1].Name);
  AssertEquals(11, Info.Classes[0].Methods[1].DeclLine);
  AssertEquals(18, Info.Classes[0].Methods[1].ImplLine);
end;

procedure TTestDiscoveryTests.TestIgnoresCommentsAndStrings;
var
  Info: TTestUnitInfo;
begin
  Info := ScanTestUnitSource('c.test.pas',
    'unit c.test;' + LineEnding +
    'interface' + LineEnding +
    '{ TFake = class(TTestCase) }' + LineEnding +
    '(* TFake2 = class(TTestCase) *)' + LineEnding +
    '// TFake3 = class(TTestCase)' + LineEnding +
    'const S = ''TFake4 = class(TTestCase)'';' + LineEnding +
    'type' + LineEnding +
    '  TReal = class(TTestCase)' + LineEnding +
    '  published' + LineEnding +
    '    procedure TestReal;' + LineEnding +
    '    // procedure TestHidden;' + LineEnding +
    '  end;' + LineEnding +
    'implementation' + LineEnding +
    'end.');
  AssertEquals('c.test', Info.UnitName);
  AssertEquals(1, Length(Info.Classes));
  AssertEquals('TReal', Info.Classes[0].Name);
  AssertEquals(1, Length(Info.Classes[0].Methods));
end;

procedure TTestDiscoveryTests.TestDetectsRegisterTest;
begin
  AssertTrue(ScanTestUnitSource('a.pas', SAMPLE_UNIT).HasRegisterTest);
  AssertFalse(ScanTestUnitSource('a.pas',
    'unit a.test; interface implementation end.').HasRegisterTest);
end;

procedure TTestDiscoveryTests.TestResolvesInheritedTestClassesAcrossUnits;
var
  Units: TTestUnitInfoArray;
begin
  SetLength(Units, 2);
  Units[0] := ScanTestUnitSource('base_test.pas',
    'unit base_test; interface type TBase = class(TTestCase) published procedure TestBase; end;' +
    ' TNotATest = class(TObject) published procedure Foo; end; implementation end.');
  Units[1] := ScanTestUnitSource('derived_test.pas',
    'unit derived_test; interface type TDerived = class(TBase) published procedure TestDerived; end;' +
    ' implementation end.');
  ResolveTestClasses(Units);
  AssertEquals(1, Length(Units[0].Classes));
  AssertEquals('TBase', Units[0].Classes[0].Name);
  AssertEquals(1, Length(Units[1].Classes));
  AssertEquals('TDerived', Units[1].Classes[0].Name);
end;

procedure TTestDiscoveryTests.TestFilterMatching;
var
  Filters: TStringArray;
const
  ID = 'nik.pkg.semver.test.TSemVerTests.TestCaretConstraint';
begin
  AssertTrue('full id', TestIdMatchesFilter(ID, ID));
  AssertTrue('unit prefix, case-insensitive', TestIdMatchesFilter(ID, 'NIK.PKG.SEMVER.TEST'));
  AssertTrue('class prefix', TestIdMatchesFilter(ID, 'nik.pkg.semver.test.TSemVerTests'));
  AssertTrue('prefix at a dot boundary inside the unit name', TestIdMatchesFilter(ID, 'nik.pkg.semver'));
  AssertFalse('prefix not at a dot boundary', TestIdMatchesFilter(ID, 'nik.pkg.sem'));
  AssertTrue('wildcard', TestIdMatchesFilter(ID, '*TestCaret*'));
  AssertTrue('wildcard in the middle', TestIdMatchesFilter(ID, 'nik.*.TSemVerTests.Test*'));
  AssertFalse('non matching wildcard', TestIdMatchesFilter(ID, '*TestOther*'));

  Filters := nil;
  AssertTrue('empty filter list matches everything', TestIdMatchesAnyFilter(ID, Filters));
  SetLength(Filters, 2);
  Filters[0] := 'other.unit';
  Filters[1] := '*Caret*';
  AssertTrue('filters are OR-ed', TestIdMatchesAnyFilter(ID, Filters));
  Filters[1] := '*Nothing*';
  AssertFalse('no filter matches', TestIdMatchesAnyFilter(ID, Filters));
end;

procedure TTestDiscoveryTests.TestDiscoversFlatInRootsOnly;
var
  Roots: TStringArray;
  Res: TTestDiscoveryResult;
begin
  WriteTemp('src' + PathDelim + 'a_test.pas', StringReplace(SAMPLE_UNIT, 'sample.unit.test', 'a_test', []));
  WriteTemp('src' + PathDelim + 'sub' + PathDelim + 'b_test.pas',
    StringReplace(SAMPLE_UNIT, 'sample.unit.test', 'b_test', []));
  WriteTemp('src' + PathDelim + 'plain.pas', 'unit plain; interface implementation end.');
  WriteTemp('outside_test.pas', StringReplace(SAMPLE_UNIT, 'sample.unit.test', 'outside_test', []));

  SetLength(Roots, 2);
  Roots[0] := JoinPath(FTempDir, 'src');
  Roots[1] := ExtractFileDir(FTempDir); // outside of the project directory
  Res := DiscoverTestUnits(JoinPath(FTempDir, 'src'), Roots);
  AssertEquals(1, Length(Res.Units));
  AssertEquals('a_test', Res.Units[0].UnitName);
end;

procedure TTestDiscoveryTests.TestRejectsUnitNameMismatch;
var
  Roots: TStringArray;
begin
  WriteTemp('wrong_test.pas', StringReplace(SAMPLE_UNIT, 'sample.unit.test', 'another_name', []));
  SetLength(Roots, 1);
  Roots[0] := FTempDir;
  try
    DiscoverTestUnits(FTempDir, Roots);
    Fail('Expected ENikError for a unit/file name mismatch');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('must match the file name', E.Message) > 0);
  end;
end;

procedure TTestDiscoveryTests.TestRejectsDuplicateUnitNames;
var
  Roots: TStringArray;
begin
  WriteTemp('one' + PathDelim + 'dup_test.pas', StringReplace(SAMPLE_UNIT, 'sample.unit.test', 'dup_test', []));
  WriteTemp('two' + PathDelim + 'dup_test.pas', StringReplace(SAMPLE_UNIT, 'sample.unit.test', 'dup_test', []));
  SetLength(Roots, 2);
  Roots[0] := JoinPath(FTempDir, 'one');
  Roots[1] := JoinPath(FTempDir, 'two');
  try
    DiscoverTestUnits(FTempDir, Roots);
    Fail('Expected ENikError for duplicate test units');
  except
    on E: ENikError do
      AssertTrue(E.Message, Pos('Duplicate test unit', E.Message) > 0);
  end;
end;

procedure TTestDiscoveryTests.TestWarnsWhenRegisterTestIsMissing;
var
  Roots: TStringArray;
  Res: TTestDiscoveryResult;
begin
  WriteTemp('noreg_test.pas',
    StringReplace(StringReplace(SAMPLE_UNIT, 'sample.unit.test', 'noreg_test', []),
      'RegisterTest(TA);', '', []));
  SetLength(Roots, 1);
  Roots[0] := FTempDir;
  Res := DiscoverTestUnits(FTempDir, Roots);
  AssertEquals(1, Length(Res.Units));
  AssertEquals(1, Length(Res.Warnings));
  AssertTrue(Res.Warnings[0].Message, Pos('RegisterTest', Res.Warnings[0].Message) > 0);
end;

initialization
  RegisterTest(TTestDiscoveryTests);
end.
