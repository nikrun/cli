unit nikrun.lsp.utf16.test;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TUtf16Tests = class(TTestCase)
  published
    procedure TestUtf16Mapping;
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

procedure TUtf16Tests.TestUtf16Mapping;
var
  Line: string;
begin
  // 'ä' = 2 UTF-8 bytes (1 UTF-16 unit), '🚀' = 4 UTF-8 bytes (2 UTF-16 units)
  Line := 'aä🚀b';
  ChkEqInt(Length(Line), 8, 'UTF-8 byte length');
  ChkEqInt(Utf8LineLengthUtf16(Line), 5, 'UTF-16 length of a + ä + 🚀(2) + b');

  ChkEqInt(Utf16ColToByteIndex(Line, 0), 1, 'Col 0 -> byte 1 (a)');
  ChkEqInt(Utf16ColToByteIndex(Line, 1), 2, 'Col 1 -> byte 2 (ä)');
  ChkEqInt(Utf16ColToByteIndex(Line, 2), 4, 'Col 2 -> byte 4 (🚀)');
  ChkEqInt(Utf16ColToByteIndex(Line, 4), 8, 'Col 4 -> byte 8 (b)');
  ChkEqInt(Utf16ColToByteIndex(Line, 5), 9, 'Col 5 -> byte 9 (EOL)');

  ChkEqInt(ByteIndexToUtf16Col(Line, 1), 0, 'Byte 1 -> col 0');
  ChkEqInt(ByteIndexToUtf16Col(Line, 2), 1, 'Byte 2 -> col 1');
  ChkEqInt(ByteIndexToUtf16Col(Line, 4), 2, 'Byte 4 -> col 2');
  ChkEqInt(ByteIndexToUtf16Col(Line, 8), 4, 'Byte 8 -> col 4');
end;

initialization
  RegisterTest(TUtf16Tests);
end.