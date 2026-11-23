unit nik.source.test;

{$mode objfpc}{$H+}

{ fpcunit tests for SOURCE handling of 'nik run' / 'nik build' (URL parsing, ref/path split,
  classification, synthetic manifest). Network-free. }

interface

uses
  SysUtils, Classes, fpcunit, testregistry, nik.types, nik.source.url, nik.source;

type
  TSourceTests = class(TTestCase)
  published
    procedure TestGitHubBlobUrl;
    procedure TestGitHubTreeUrlIsDirectory;
    procedure TestRawGitHubUrl;
    procedure TestGitLabUrl;
    procedure TestCodebergUrl;
    procedure TestRepoWithAtRef;
    procedure TestFragmentAndQueryAreDropped;
    procedure TestRejectsHttpAndGarbage;
    procedure TestSplitRefPrefersLongestKnownRef;
    procedure TestSplitRefAcceptsCommitId;
    procedure TestSplitRefRequiresPath;
    procedure TestClassifyUrl;
    procedure TestClassifyFileAndDirectory;
    procedure TestClassifyRejectsUnknown;
    procedure TestSanitizeProgramName;
    procedure TestSyntheticManifest;
    procedure TestTrustStoreRemembersSeveralVersions;
  end;

implementation

uses
  nik.paths, nik.fs;

function Parse(const AUrl: string): TSourceUrlParts;
var
  Err: string;
begin
  if not TryParseSourceUrl(AUrl, Result, Err) then
    raise Exception.CreateFmt('Parse failed for ''%s'': %s', [AUrl, Err]);
end;

procedure TSourceTests.TestGitHubBlobUrl;
var
  P: TSourceUrlParts;
begin
  P := Parse('https://github.com/RalliKam/TWIN/blob/main/twin.pas');
  AssertEquals('https://github.com/RalliKam/TWIN', P.RepoUrl);
  AssertEquals('main/twin.pas', P.RefAndPath);
  AssertFalse(P.IsTree);
  AssertEquals('', P.ExplicitRef);
end;

procedure TSourceTests.TestGitHubTreeUrlIsDirectory;
var
  P: TSourceUrlParts;
begin
  P := Parse('https://github.com/o/r/tree/v1.2.0/tools/gen');
  AssertEquals('https://github.com/o/r', P.RepoUrl);
  AssertEquals('v1.2.0/tools/gen', P.RefAndPath);
  AssertTrue(P.IsTree);
end;

procedure TSourceTests.TestRawGitHubUrl;
var
  P: TSourceUrlParts;
begin
  P := Parse('https://raw.githubusercontent.com/o/r/main/src/app.pas');
  AssertEquals('https://github.com/o/r', P.RepoUrl);
  AssertEquals('main/src/app.pas', P.RefAndPath);
end;

procedure TSourceTests.TestGitLabUrl;
var
  P: TSourceUrlParts;
begin
  P := Parse('https://gitlab.com/group/sub/repo/-/blob/main/x.pas');
  AssertEquals('https://gitlab.com/group/sub/repo', P.RepoUrl);
  AssertEquals('main/x.pas', P.RefAndPath);
end;

procedure TSourceTests.TestCodebergUrl;
var
  P: TSourceUrlParts;
begin
  P := Parse('https://codeberg.org/o/r/src/branch/main/x.pas');
  AssertEquals('https://codeberg.org/o/r', P.RepoUrl);
  AssertEquals('main/x.pas', P.RefAndPath);
end;

procedure TSourceTests.TestRepoWithAtRef;
var
  P: TSourceUrlParts;
begin
  P := Parse('https://github.com/o/r@v1.2.0');
  AssertEquals('https://github.com/o/r', P.RepoUrl);
  AssertEquals('v1.2.0', P.ExplicitRef);
  AssertEquals('', P.RefAndPath);

  P := Parse('https://github.com/o/r.git');
  AssertEquals('https://github.com/o/r', P.RepoUrl);
  AssertEquals('', P.ExplicitRef);
end;

procedure TSourceTests.TestFragmentAndQueryAreDropped;
var
  P: TSourceUrlParts;
begin
  P := Parse('https://github.com/o/r/blob/main/a.pas?plain=1#L10-L20');
  AssertEquals('main/a.pas', P.RefAndPath);
end;

procedure TSourceTests.TestRejectsHttpAndGarbage;
var
  P: TSourceUrlParts;
  Err: string;
begin
  AssertFalse(TryParseSourceUrl('http://github.com/o/r', P, Err));
  AssertFalse(TryParseSourceUrl('https://github.com', P, Err));
  AssertFalse(TryParseSourceUrl('https://user:pw@github.com/o/r', P, Err));
  AssertFalse(TryParseSourceUrl('https://github.com/o/r@', P, Err));
end;

procedure TSourceTests.TestSplitRefPrefersLongestKnownRef;
var
  Ref, Path: string;
begin
  AssertTrue(TrySplitRefAndPath('feature/x/src/app.pas', ['main', 'feature', 'feature/x'], True, Ref, Path));
  AssertEquals('feature/x', Ref);
  AssertEquals('src/app.pas', Path);

  AssertTrue(TrySplitRefAndPath('main/tools', ['main'], False, Ref, Path));
  AssertEquals('main', Ref);
  AssertEquals('tools', Path);

  AssertTrue(TrySplitRefAndPath('main', ['main'], False, Ref, Path));
  AssertEquals('main', Ref);
  AssertEquals('', Path);

  AssertFalse(TrySplitRefAndPath('unknown/a.pas', ['main'], True, Ref, Path));
end;

procedure TSourceTests.TestSplitRefAcceptsCommitId;
var
  Ref, Path: string;
begin
  AssertTrue(TrySplitRefAndPath('6800b774dd43/src/a.pas', ['main'], True, Ref, Path));
  AssertEquals('6800b774dd43', Ref);
  AssertEquals('src/a.pas', Path);
end;

procedure TSourceTests.TestSplitRefRequiresPath;
var
  Ref, Path: string;
begin
  AssertFalse(TrySplitRefAndPath('main', ['main'], True, Ref, Path));
end;

procedure TSourceTests.TestClassifyUrl;
begin
  AssertTrue(ClassifySource('https://github.com/o/r') = skUrl);
  try
    ClassifySource('http://github.com/o/r');
    Fail('http:// must be rejected');
  except
    on E: ENikError do;
  end;
  try
    ClassifySource('ftp://host/x.pas');
    Fail('ftp:// must be rejected');
  except
    on E: ENikError do;
  end;
end;

procedure TSourceTests.TestClassifyFileAndDirectory;
var
  Dir, PasFile, YamlFile, TxtFile: string;
  L: TStringList;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'niksource_test_' + IntToStr(GetProcessID);
  ForceDirectories(Dir);
  PasFile := Dir + PathDelim + 'a.pas';
  YamlFile := Dir + PathDelim + 'nik.yaml';
  TxtFile := Dir + PathDelim + 'a.txt';
  L := TStringList.Create;
  try
    L.Text := 'x';
    L.SaveToFile(PasFile);
    L.SaveToFile(YamlFile);
    L.SaveToFile(TxtFile);
    try
      AssertTrue(ClassifySource(Dir) = skProject);
      AssertTrue(ClassifySource(YamlFile) = skProject);
      AssertTrue(ClassifySource(PasFile) = skFile);
      try
        ClassifySource(TxtFile);
        Fail('.txt must be rejected');
      except
        on E: ENikError do;
      end;
    finally
      DeleteFile(PasFile);
      DeleteFile(YamlFile);
      DeleteFile(TxtFile);
      RemoveDir(Dir);
    end;
  finally
    L.Free;
  end;
end;

procedure TSourceTests.TestClassifyRejectsUnknown;
begin
  try
    ClassifySource('definitely/not/here.pas');
    Fail('missing path must be rejected');
  except
    on E: ENikError do;
  end;
end;

procedure TSourceTests.TestSanitizeProgramName;
begin
  AssertEquals('my-app_1', SanitizeProgramName('my-app_1'));
  AssertEquals('my_app', SanitizeProgramName('my app'));
  AssertEquals('app', SanitizeProgramName(''));
  AssertEquals('app', SanitizeProgramName('...'));
end;

procedure TSourceTests.TestSyntheticManifest;
var
  Text: string;
begin
  Text := BuildSyntheticManifestText('hello', 'C:\x\hello.pas', '3.2.2', ['C:\x', 'C:\x\repo']);
  AssertTrue(Pos('name: hello', Text) > 0);
  AssertTrue(Pos('entry: "C:/x/hello.pas"', Text) > 0);
  AssertTrue(Pos('fpc: 3.2.2', Text) > 0);
  AssertTrue(Pos('- "C:/x/repo"', Text) > 0);
end;

procedure TSourceTests.TestTrustStoreRemembersSeveralVersions;
var
  Home, StoreFile: string;
  Other: Boolean;
begin
  Home := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'niktrust_test_' + IntToStr(GetProcessID);
  ForceDirectories(Home);
  SetNikrunHomeOverride(Home);
  StoreFile := GetTrustStoreFile;
  try
    AssertFalse(IsSourceTrusted('https://github.com/o/r', 'sha256-aaa', Other));
    AssertFalse(Other);

    RememberTrustedSource('https://github.com/o/r', 'sha256-aaa', 'c1');
    RememberTrustedSource('https://github.com/o/r', 'sha256-bbb', 'c2');
    RememberTrustedSource('https://github.com/o/r', 'sha256-bbb', 'c2'); // idempotent

    AssertTrue(IsSourceTrusted('https://github.com/o/r', 'sha256-aaa', Other));
    AssertTrue(IsSourceTrusted('https://github.com/o/r', 'sha256-bbb', Other));
    AssertFalse(IsSourceTrusted('https://github.com/o/r', 'sha256-ccc', Other));
    AssertTrue('a changed tree of a known repository is reported as such', Other);
    AssertFalse(IsSourceTrusted('https://github.com/o/other', 'sha256-aaa', Other));
    AssertFalse(Other);
  finally
    SetNikrunHomeOverride('');
    DeleteFile(StoreFile);
    RemoveDir(Home);
  end;
end;

initialization
  RegisterTest(TSourceTests);
end.
