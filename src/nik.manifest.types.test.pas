unit nik.manifest.types.test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, nik.manifest.types;

type
  TWindowsVersionTests = class(TTestCase)
  published
    procedure TestParseThreeAndFourParts;
    procedure TestParseRejectsMalformedText;
    procedure TestParseRejectsOutOfRangeParts;
    procedure TestDeriveFromPlainVersion;
    procedure TestDeriveTakesBuildNumberFromCiTag;
    procedure TestDeriveKeepsFourPartCore;
    procedure TestDeriveRejectsTextWithoutVersionPrefix;
  end;

implementation

procedure AssertVersion(const AMsg: string; const AActual: TWindowsVersion; A, B, C, D: Word);
begin
  TAssert.AssertEquals(AMsg + ' major', A, AActual[0]);
  TAssert.AssertEquals(AMsg + ' minor', B, AActual[1]);
  TAssert.AssertEquals(AMsg + ' patch', C, AActual[2]);
  TAssert.AssertEquals(AMsg + ' build', D, AActual[3]);
end;

procedure TWindowsVersionTests.TestParseThreeAndFourParts;
var
  V: TWindowsVersion;
begin
  AssertTrue(TryParseWindowsVersion('1.4.2', V));
  AssertVersion('three parts', V, 1, 4, 2, 0);
  AssertTrue(TryParseWindowsVersion('1.4.2.9', V));
  AssertVersion('four parts', V, 1, 4, 2, 9);
  AssertTrue(TryParseWindowsVersion('65535.0.0.65535', V));
  AssertVersion('limits', V, 65535, 0, 0, 65535);
end;

procedure TWindowsVersionTests.TestParseRejectsMalformedText;
var
  V: TWindowsVersion;
  Samples: array[0..7] of string;
  I: Integer;
begin
  Samples[0] := '';
  Samples[1] := '1';
  Samples[2] := '1.2';
  Samples[3] := '1.2.3.4.5';
  Samples[4] := '1..3';
  Samples[5] := '1.2.3.';
  Samples[6] := '1.2.x';
  Samples[7] := 'v1.2.3';
  for I := 0 to High(Samples) do
  begin
    AssertFalse('"' + Samples[I] + '" must be rejected', TryParseWindowsVersion(Samples[I], V));
    AssertVersion('reset after "' + Samples[I] + '"', V, 0, 0, 0, 0);
  end;
end;

procedure TWindowsVersionTests.TestParseRejectsOutOfRangeParts;
var
  V: TWindowsVersion;
begin
  AssertFalse(TryParseWindowsVersion('65536.0.0', V));
  AssertFalse(TryParseWindowsVersion('1.2.3.99999999999', V));
end;

procedure TWindowsVersionTests.TestDeriveFromPlainVersion;
var
  V: TWindowsVersion;
begin
  AssertTrue(TryDeriveWindowsVersion('1.4.2', V));
  AssertVersion('plain', V, 1, 4, 2, 0);
  AssertTrue(TryDeriveWindowsVersion('  V2.0.1  ', V));
  AssertVersion('upper-case v and spaces', V, 2, 0, 1, 0);
end;

procedure TWindowsVersionTests.TestDeriveTakesBuildNumberFromCiTag;
var
  V: TWindowsVersion;
begin
  AssertTrue(TryDeriveWindowsVersion('v0.2.0-build.16-channel.stable', V));
  AssertVersion('ci tag', V, 0, 2, 0, 16);
  AssertTrue(TryDeriveWindowsVersion('0.2.0-BUILD.7', V));
  AssertVersion('upper-case marker', V, 0, 2, 0, 7);
  AssertTrue(TryDeriveWindowsVersion('1.0.0-build.70000', V));
  AssertVersion('build number out of range is ignored', V, 1, 0, 0, 0);
  AssertTrue(TryDeriveWindowsVersion('1.0.0-build.', V));
  AssertVersion('missing build digits', V, 1, 0, 0, 0);
  AssertTrue(TryDeriveWindowsVersion('1.0.0-beta', V));
  AssertVersion('other suffix', V, 1, 0, 0, 0);
end;

procedure TWindowsVersionTests.TestDeriveKeepsFourPartCore;
var
  V: TWindowsVersion;
begin
  AssertTrue(TryDeriveWindowsVersion('1.2.3.4-build.99', V));
  AssertVersion('four-part core wins over build number', V, 1, 2, 3, 4);
end;

procedure TWindowsVersionTests.TestDeriveRejectsTextWithoutVersionPrefix;
var
  V: TWindowsVersion;
begin
  AssertFalse(TryDeriveWindowsVersion('', V));
  AssertFalse(TryDeriveWindowsVersion('latest', V));
  AssertFalse(TryDeriveWindowsVersion('1.2', V));
  AssertVersion('reset', V, 0, 0, 0, 0);
end;

initialization
  RegisterTest(TWindowsVersionTests);
end.
