unit nik.pkg.semver.test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, nik.pkg.semver;

type
  TSemVerTests = class(TTestCase)
  published
    procedure TestParsesLeadingV;
    procedure TestRejectsLeadingVWhenDisallowed;
    procedure TestParsesPreReleaseAndBuildMetadata;
    procedure TestComparesNumerically;
    procedure TestPreReleaseSortsBeforeRelease;
    procedure TestCaretConstraint;
    procedure TestSelectsMinimalMatchingVersion;
    procedure TestRejectsGarbage;
  end;

implementation

function Ver(const ARaw: string): TSemVer;
begin
  if not TryParseSemVer(ARaw, Result) then
    raise Exception.CreateFmt('Invalid test version ''%s''', [ARaw]);
end;

procedure TSemVerTests.TestParsesLeadingV;
var
  V: TSemVer;
begin
  AssertTrue(TryParseSemVer('v1.2.3', V));
  AssertEquals(1, V.Major);
  AssertEquals(2, V.Minor);
  AssertEquals(3, V.Patch);
  AssertEquals('1.2.3', FormatSemVer(V));
end;

procedure TSemVerTests.TestRejectsLeadingVWhenDisallowed;
var
  V: TSemVer;
begin
  AssertFalse(TryParseSemVer('v1.2.3', V, False));
  AssertTrue(TryParseSemVer('1.2.3', V, False));
end;

procedure TSemVerTests.TestParsesPreReleaseAndBuildMetadata;
var
  V: TSemVer;
begin
  AssertTrue(TryParseSemVer('1.0.0-beta.1+build.5', V));
  AssertEquals('beta.1', V.PreRelease);
  AssertEquals('build.5', V.BuildMeta);
end;

procedure TSemVerTests.TestComparesNumerically;
begin
  AssertTrue(CompareSemVer(Ver('1.2.3'), Ver('1.10.0')) < 0);
  AssertTrue(CompareSemVer(Ver('2.0.0'), Ver('1.99.99')) > 0);
  AssertEquals(0, CompareSemVer(Ver('1.2.3'), Ver('1.2.3')));
end;

procedure TSemVerTests.TestPreReleaseSortsBeforeRelease;
begin
  AssertTrue(CompareSemVer(Ver('1.0.0-beta.1'), Ver('1.0.0')) < 0);
end;

procedure TSemVerTests.TestCaretConstraint;
var
  C: TSemVerConstraint;
  Err: string;
begin
  AssertTrue(TryParseSemVerConstraint('^1.2.0', C, Err));
  AssertTrue(SemVerSatisfiesConstraint(Ver('1.2.0'), C));
  AssertTrue(SemVerSatisfiesConstraint(Ver('1.9.4'), C));
  AssertFalse(SemVerSatisfiesConstraint(Ver('1.1.9'), C));
  AssertFalse(SemVerSatisfiesConstraint(Ver('2.0.0'), C));
end;

procedure TSemVerTests.TestSelectsMinimalMatchingVersion;
var
  C: TSemVerConstraint;
  Err: string;
  Chosen: TSemVer;
  Candidates: array of TSemVer;
begin
  AssertTrue(TryParseSemVerConstraint('^1.2.0', C, Err));
  SetLength(Candidates, 4);
  Candidates[0] := Ver('1.1.0');
  Candidates[1] := Ver('1.3.0');
  Candidates[2] := Ver('1.2.5');
  Candidates[3] := Ver('2.0.0');
  AssertTrue(SelectMinimalMatchingVersion(Candidates, [C], Chosen));
  AssertEquals('1.2.5', FormatSemVer(Chosen));
  AssertTrue(SelectLatestMatchingVersion(Candidates, [C], Chosen));
  AssertEquals('1.3.0', FormatSemVer(Chosen));
end;

procedure TSemVerTests.TestRejectsGarbage;
var
  V: TSemVer;
begin
  AssertFalse(TryParseSemVer('not-a-version', V));
  AssertFalse(TryParseSemVer('1.2', V));
  AssertFalse(TryParseSemVer('', V));
end;

initialization
  RegisterTest(TSemVerTests);
end.
