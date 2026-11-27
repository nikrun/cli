unit nik.yaml.test;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, nik.types, nik.yaml;

type
  TYamlTests = class(TTestCase)
  published
    procedure TestParsesNestedMappingAndLines;
    procedure TestParsesFlowAndBlockSequences;
    procedure TestQuotedScalarsAndComments;
    procedure TestDuplicateKeyIsRejectedWithLine;
    procedure TestQuoteDoubleRoundTrip;
  end;

implementation

procedure TYamlTests.TestParsesNestedMappingAndLines;
var
  Root: TYamlNode;
begin
  Root := ParseYamlText('a: 1' + LineEnding + 'b:' + LineEnding + '  c: hello' + LineEnding);
  try
    AssertTrue(Root.Kind = ynkMapping);
    AssertEquals('1', Root.Find('a').ScalarValue);
    AssertEquals('hello', Root.Find('b').Find('c').ScalarValue);
    AssertEquals(1, Root.GetEntry(0).KeyLine);
    AssertEquals(2, Root.GetEntry(1).KeyLine);
    AssertTrue(Root.HasKey('b'));
    AssertFalse(Root.HasKey('missing'));
  finally
    Root.Free;
  end;
end;

procedure TYamlTests.TestParsesFlowAndBlockSequences;
var
  Root: TYamlNode;
begin
  Root := ParseYamlText(
    'flow: [x, y]' + LineEnding +
    'block:' + LineEnding +
    '  - one' + LineEnding +
    '  - two' + LineEnding +
    '  - three' + LineEnding);
  try
    AssertTrue(Root.Find('flow').Kind = ynkSequence);
    AssertEquals(2, Root.Find('flow').Count);
    AssertEquals('y', Root.Find('flow').GetItem(1).ScalarValue);
    AssertEquals(3, Root.Find('block').Count);
    AssertEquals('one', Root.Find('block').GetItem(0).ScalarValue);
  finally
    Root.Free;
  end;
end;

procedure TYamlTests.TestQuotedScalarsAndComments;
var
  Root: TYamlNode;
begin
  Root := ParseYamlText(
    'name: "hello world" # trailing comment' + LineEnding +
    'plain: value # another comment' + LineEnding);
  try
    AssertEquals('hello world', Root.Find('name').ScalarValue);
    AssertTrue(Root.Find('name').Quoted);
    AssertEquals('value', Root.Find('plain').ScalarValue);
    AssertFalse(Root.Find('plain').Quoted);
  finally
    Root.Free;
  end;
end;

procedure TYamlTests.TestDuplicateKeyIsRejectedWithLine;
var
  Root: TYamlNode;
begin
  Root := nil;
  try
    Root := ParseYamlText('a: 1' + LineEnding + 'a: 2' + LineEnding, 'test.yaml');
    Fail('Expected ENikError for a duplicate key');
  except
    on E: ENikError do
    begin
      AssertTrue(E.Message, Pos('test.yaml:2', E.Message) > 0);
      AssertTrue(E.Message, Pos('Duplicate key', E.Message) > 0);
    end;
  end;
  Root.Free;
end;

procedure TYamlTests.TestQuoteDoubleRoundTrip;
var
  Root: TYamlNode;
  Raw: string;
begin
  Raw := 'a "b" \ c: d';
  Root := ParseYamlText('k: ' + YamlQuoteDouble(Raw));
  try
    AssertEquals(Raw, Root.Find('k').ScalarValue);
  finally
    Root.Free;
  end;
end;

initialization
  RegisterTest(TYamlTests);
end.
