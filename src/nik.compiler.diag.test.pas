unit nik.compiler.diag.test;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, nik.compiler.diag;

type
  TCompilerDiagTests = class(TTestCase)
  published
    procedure TestLocatedErrorWithLineAndColumn;
    procedure TestLocatedWarningWithoutColumn;
    procedure TestLeadingMessageCodeIsExtracted;
    procedure TestHeadlessFatal;
    procedure TestUnrelatedLineIsIgnored;
    procedure TestCompilerOutputCountsAndLinesCompiled;
  end;

implementation

procedure TCompilerDiagTests.TestLocatedErrorWithLineAndColumn;
var
  D: TCompilerDiagnostic;
begin
  AssertTrue(ParseFpcDiagnosticLine('main.pas(10,5) Error: Identifier not found "Foo"', '', D));
  AssertTrue(D.Severity = dsError);
  AssertEquals(10, D.Line);
  AssertEquals(5, D.Column);
  AssertEquals('Identifier not found "Foo"', D.Message);
end;

procedure TCompilerDiagTests.TestLocatedWarningWithoutColumn;
var
  D: TCompilerDiagnostic;
begin
  AssertTrue(ParseFpcDiagnosticLine('unit1.pas(7) Warning: Unit "x" not used', '', D));
  AssertTrue(D.Severity = dsWarning);
  AssertEquals(7, D.Line);
  AssertEquals(0, D.Column);
end;

procedure TCompilerDiagTests.TestLeadingMessageCodeIsExtracted;
var
  D: TCompilerDiagnostic;
begin
  AssertTrue(ParseFpcDiagnosticLine('a.pas(3,1) Hint: (5024) Parameter "X" not used', '', D));
  AssertTrue(D.Severity = dsHint);
  AssertEquals(5024, D.Code);
  AssertEquals('Parameter "X" not used', D.Message);
end;

procedure TCompilerDiagTests.TestHeadlessFatal;
var
  D: TCompilerDiagnostic;
begin
  AssertTrue(ParseFpcDiagnosticLine('Fatal: Can''t find unit Bar used by Main', '', D));
  AssertTrue(D.Severity = dsFatal);
  AssertEquals('', D.FilePath);
end;

procedure TCompilerDiagTests.TestUnrelatedLineIsIgnored;
var
  D: TCompilerDiagnostic;
begin
  AssertFalse(ParseFpcDiagnosticLine('Compiling main.pas', '', D));
  AssertFalse(ParseFpcDiagnosticLine('', '', D));
end;

procedure TCompilerDiagTests.TestCompilerOutputCountsAndLinesCompiled;
var
  Out: TParsedCompilerOutput;
begin
  Out := ParseFpcCompilerOutput(
    'a.pas(1,1) Error: first' + LineEnding +
    'a.pas(2,1) Warning: second' + LineEnding +
    'a.pas(3,1) Note: third' + LineEnding +
    '120 lines compiled, 0.1 sec' + LineEnding, '');
  AssertEquals(1, Out.ErrorCount);
  AssertEquals(1, Out.WarningCount);
  AssertEquals(1, Out.NoteCount);
  AssertEquals(3, Length(Out.Diagnostics));
  AssertEquals(120, Out.LinesCompiled);
end;

initialization
  RegisterTest(TCompilerDiagTests);
end.
