unit nik.lsp.manifest.test;

{$mode objfpc}{$H+}

{ fpcunit tests for the nik.yaml intelligence of nik lsp: the line structure it reads with
  VSoft.YAML, also while a line is still being typed (unclosed quotes and brackets). }

interface

uses
  SysUtils, fpcunit, testregistry, nikrun.lsp.types, nikrun.lsp.documents, nik.lsp.manifest;

type
  TLspManifestTests = class(TTestCase)
  private
    function Doc(const AText: string): TLspDocument;
    function HasLabel(const AList: TLspCompletionList; const ALabel: string): Boolean;
  published
    procedure TestDocumentSymbolsFollowTheNesting;
    procedure TestKeyCompletionWhileTyping;
    procedure TestEnumCompletionOfScalarValue;
    procedure TestEnumCompletionInsideUnclosedQuote;
    procedure TestListItemCompletion;
    procedure TestInlineListCompletionInsideUnclosedBracket;
    procedure TestNoCompletionInComment;
    procedure TestHoverOnKey;
  end;

implementation

const
  Manifest =
    'schemaVersion: 1'#10 +
    ''#10 +
    'program:'#10 +
    '  name: demo # the name'#10 +
    '  entry: src/demo.pas'#10 +
    '  toolchain:'#10 +
    '    fpc: 3.3.1'#10 +
    '  build:'#10 +
    '    mode: objfpc'#10 +
    '    unitPaths:'#10 +
    '      - src'#10;

function TLspManifestTests.Doc(const AText: string): TLspDocument;
begin
  Result := TLspDocument.Create('file:///tmp/nik.yaml', 'yaml', 1, AText);
end;

function TLspManifestTests.HasLabel(const AList: TLspCompletionList; const ALabel: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(AList.Items) do
    if AList.Items[I].LabelText = ALabel then
      Exit(True);
end;

procedure TLspManifestTests.TestDocumentSymbolsFollowTheNesting;
var
  D: TLspDocument;
  Syms: TLspDocumentSymbolArray;
  I, ProgramIdx, BuildIdx, ModeIdx: Integer;
begin
  D := Doc(Manifest);
  try
    Syms := BuildManifestDocumentSymbols(D);
    ProgramIdx := -1;
    BuildIdx := -1;
    ModeIdx := -1;
    for I := 0 to High(Syms) do
    begin
      if Syms[I].Name = 'program' then ProgramIdx := I;
      if Syms[I].Name = 'build' then BuildIdx := I;
      if Syms[I].Name = 'mode' then ModeIdx := I;
    end;
    AssertTrue('program symbol', ProgramIdx >= 0);
    AssertTrue('build symbol', BuildIdx >= 0);
    AssertTrue('mode symbol', ModeIdx >= 0);
    AssertEquals('build is under program', ProgramIdx, Syms[BuildIdx].ParentIndex);
    AssertEquals('mode is under build', BuildIdx, Syms[ModeIdx].ParentIndex);
    AssertEquals('mode is on line 8', 8, Syms[ModeIdx].SelectionRange.StartPos.Line);
  finally
    D.Free;
  end;
end;

procedure TLspManifestTests.TestKeyCompletionWhileTyping;
var
  D: TLspDocument;
  L: TLspCompletionList;
begin
  D := Doc('program:'#10'  build:'#10'    mo'#10);
  try
    L := ResolveManifestCompletions('/tmp/nik.yaml', D, TLspPosition.Create(2, 6), '');
    AssertTrue('mode is offered for a key being typed', HasLabel(L, 'mode'));
    AssertTrue('longStrings is offered', HasLabel(L, 'longStrings'));
  finally
    D.Free;
  end;
end;

procedure TLspManifestTests.TestEnumCompletionOfScalarValue;
var
  D: TLspDocument;
  L: TLspCompletionList;
begin
  D := Doc('program:'#10'  build:'#10'    mode: ');
  try
    L := ResolveManifestCompletions('/tmp/nik.yaml', D, TLspPosition.Create(2, 10), ' ');
    AssertTrue('objfpc is offered', HasLabel(L, 'objfpc'));
    AssertTrue('delphi is offered', HasLabel(L, 'delphi'));
  finally
    D.Free;
  end;
end;

procedure TLspManifestTests.TestEnumCompletionInsideUnclosedQuote;
var
  D: TLspDocument;
  L: TLspCompletionList;
begin
  D := Doc('program:'#10'  build:'#10'    mode: "ob'#10);
  try
    L := ResolveManifestCompletions('/tmp/nik.yaml', D, TLspPosition.Create(2, 13), '');
    AssertTrue('objfpc is offered inside an unclosed quote', HasLabel(L, 'objfpc'));
    AssertTrue('the replace range covers the typed token', L.Items[0].HasTextEdit);
    AssertEquals('replace starts after the quote', 11, L.Items[0].TextEdit.Range.StartPos.Character);
    AssertEquals('replace ends at the end of the line', 13, L.Items[0].TextEdit.Range.EndPos.Character);
  finally
    D.Free;
  end;
end;

procedure TLspManifestTests.TestListItemCompletion;
var
  D: TLspDocument;
  L: TLspCompletionList;
begin
  D := Doc('program:'#10'  build:'#10'    modeSwitches:'#10'      - ');
  try
    L := ResolveManifestCompletions('/tmp/nik.yaml', D, TLspPosition.Create(3, 8), ' ');
    AssertTrue('advancedRecords is offered for a list item', HasLabel(L, 'advancedRecords'));
  finally
    D.Free;
  end;
end;

procedure TLspManifestTests.TestInlineListCompletionInsideUnclosedBracket;
var
  D: TLspDocument;
  L: TLspCompletionList;
begin
  D := Doc('program:'#10'  build:'#10'    modeSwitches: [adv');
  try
    L := ResolveManifestCompletions('/tmp/nik.yaml', D, TLspPosition.Create(2, 21), '');
    AssertTrue('advancedRecords is offered inside an unclosed bracket', HasLabel(L, 'advancedRecords'));
  finally
    D.Free;
  end;
end;

procedure TLspManifestTests.TestNoCompletionInComment;
var
  D: TLspDocument;
  L: TLspCompletionList;
begin
  D := Doc('program:'#10'  build:'#10'    mode: objfpc # pick'#10);
  try
    L := ResolveManifestCompletions('/tmp/nik.yaml', D, TLspPosition.Create(2, 22), '');
    AssertEquals('no items in a comment', 0, Length(L.Items));
  finally
    D.Free;
  end;
end;

procedure TLspManifestTests.TestHoverOnKey;
var
  D: TLspDocument;
  H: TLspHover;
begin
  D := Doc(Manifest);
  try
    H := ResolveManifestHover('/tmp/nik.yaml', D, TLspPosition.Create(8, 6));
    AssertTrue('hover on mode', H.HasValue);
    AssertTrue('hover mentions the key', Pos('mode', H.Markdown) > 0);
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest(TLspManifestTests);

end.