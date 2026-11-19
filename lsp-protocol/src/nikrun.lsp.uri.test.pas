unit nikrun.lsp.uri.test;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TUriTests = class(TTestCase)
  published
    procedure TestUriConversion;
  end;

implementation

uses
  SysUtils, Classes, fpjson, jsonparser,
  nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.utf16, nikrun.lsp.transport,
  nikrun.lsp.jsonrpc, nikrun.lsp.documents, nikrun.lsp.server;

procedure Chk(ACondition: Boolean; const AMessage: string);
begin
  TAssert.AssertTrue(AMessage, ACondition);
end;

procedure ChkEqStr(const AActual, AExpected, AContext: string);
begin
  TAssert.AssertEquals(AContext, AExpected, AActual);
end;

procedure ChkEqInt(AActual, AExpected: Int64; const AContext: string);
begin
  TAssert.AssertEquals(AContext, AExpected, AActual);
end;

procedure TUriTests.TestUriConversion;
var
  Uri, BackPath: string;
begin
  Uri := FilePathToUri('C:\Dev\my project\src\main.pas');
  ChkEqStr(Uri, 'file:///c:/Dev/my%20project/src/main.pas', 'Windows path -> URI');

  Chk(TryUriToFilePath('file:///c%3A/Dev/my%20project/src/main.pas', BackPath), 'VS Code encoded drive URI');
  {$IFDEF WINDOWS}
  ChkEqStr(BackPath, 'C:\Dev\my project\src\main.pas', 'Decoded Windows path');
  {$ELSE}
  ChkEqStr(BackPath, 'C:/Dev/my project/src/main.pas', 'Decoded Windows path on POSIX');
  {$ENDIF}

  ChkEqStr(FilePathToUri('/home/nik/src/unit1.pas'), 'file:///home/nik/src/unit1.pas', 'POSIX path -> URI');
  ChkEqStr(
    NormalizeDocumentUri('file:///C%3A/Foo/Bar.pas'),
    NormalizeDocumentUri('file:///c:/Foo/Bar.pas'),
    'Normalized Windows drive URI equality'
  );
  ChkEqStr(
    NormalizeDocumentUri('file:////tmp/test.pas'),
    NormalizeDocumentUri('file:///tmp/test.pas'),
    'Normalized redundant leading slashes in POSIX file URI'
  );
end;

initialization
  RegisterTest(TUriTests);
end.