unit nikrun.lsp.documents.test;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TDocumentStoreTests = class(TTestCase)
  published
    procedure TestDocumentStoreIncrementalSync;
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

procedure TDocumentStoreTests.TestDocumentStoreIncrementalSync;
var
  Store: TLspDocumentStore;
  Doc: TLspDocument;
  Changes: TLspContentChangeArray;
  Ident: string;
  IdentRange: TLspRange;
begin
  Store := TLspDocumentStore.Create;
  try
    Doc := Store.OpenDocument(
      'file:///c%3A/proj/main.pas',
      'objectpascal',
      1,
      'program demo;' + #13#10 + 'var Grütze: Integer;' + #13#10 + 'begin' + #13#10 + 'end.'
    );
    ChkEqInt(Doc.LineCount, 4, 'Initial line count');
    ChkEqStr(Doc.GetLineText(1), 'var Grütze: Integer;', 'Line 1 text');

    // Replace 'Integer' (after 'var Grütze: ' -> 12 UTF-16 units, 13 UTF-8 bytes) with 'String'
    Changes := nil;
    SetLength(Changes, 1);
    Changes[0].HasRange := True;
    Changes[0].Range := TLspRange.SingleLine(1, 12, 19);
    Changes[0].Text := 'String';
    Store.ChangeDocument('file:///c:/proj/main.pas', 2, Changes);

    ChkEqInt(Doc.Version, 2, 'Updated version');
    ChkEqStr(Doc.GetLineText(1), 'var Grütze: String;', 'Line 1 after UTF-16 incremental edit');

    Chk(Doc.ExtractIdentifierAt(TLspPosition.Create(1, 14), Ident, IdentRange), 'Extract identifier String');
    ChkEqStr(Ident, 'String', 'Extracted identifier text');
    ChkEqInt(IdentRange.StartPos.Character, 12, 'Extracted identifier start col');
    ChkEqInt(IdentRange.EndPos.Character, 18, 'Extracted identifier end col');

    Chk(Store.CloseDocument('file:///C:/proj/main.pas'), 'Close document via case/encoding variant');
    ChkEqInt(Store.Count, 0, 'Store empty after close');
  finally
    Store.Free;
  end;
end;

initialization
  RegisterTest(TDocumentStoreTests);
end.