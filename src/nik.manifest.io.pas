unit nik.manifest.io;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, nik.manifest.types;

function FindManifestFile(const AExplicitPath: string = ''): string;
function LoadManifestFile(const AManifestPath: string): TParsedManifest;
function ParseManifestText(const AText, AManifestPath, AProjectDir: string): TParsedManifest;

function LoadTemplateFile(const ATemplatePath: string): TParsedTemplate;
function ParseTemplateText(const AText, ATemplatePath: string): TParsedTemplate;

implementation

uses
  nik.types, nik.paths, nik.fs, nik.yaml, nik.archive, nik.sdk.manager, nik.pkg.types, nik.pkg.semver;

type
  TOverlayScope = (osRoot, osTest, osTarget, osProfile, osTemplateRoot, osTemplateSub);

function EditDistance(const A, B: string): Integer;
var
  LA, LB, I, J, Cost: Integer;
  D: array of array of Integer;
  SA, SB: string;
begin
  SA := LowerCase(A);
  SB := LowerCase(B);
  LA := Length(SA);
  LB := Length(SB);
  D := nil;
  SetLength(D, LA + 1, LB + 1);
  for I := 0 to LA do
    D[I][0] := I;
  for J := 0 to LB do
    D[0][J] := J;
  for I := 1 to LA do
    for J := 1 to LB do
    begin
      if SA[I] = SB[J] then
        Cost := 0
      else
        Cost := 1;
      D[I][J] := D[I - 1][J] + 1;
      if D[I][J - 1] + 1 < D[I][J] then
        D[I][J] := D[I][J - 1] + 1;
      if D[I - 1][J - 1] + Cost < D[I][J] then
        D[I][J] := D[I - 1][J - 1] + Cost;
    end;
  Result := D[LA][LB];
end;

function SuggestClosestKey(const AUnknown: string; const AAllowed: array of string): string;
var
  I, Dist, BestDist: Integer;
begin
  Result := '';
  BestDist := 3; // Suggest within distance <= 2
  for I := Low(AAllowed) to High(AAllowed) do
  begin
    Dist := EditDistance(AUnknown, AAllowed[I]);
    if Dist < BestDist then
    begin
      BestDist := Dist;
      Result := AAllowed[I];
    end;
  end;
end;

procedure ValidateAllowedKeys(AMap: TYamlNode; const AAllowed: array of string;
  const AContext, AManifestPath: string);
var
  I, J: Integer;
  Entry: TYamlKeyValue;
  Found: Boolean;
  Hint: string;
begin
  if (AMap = nil) or (AMap.Kind <> ynkMapping) then
    Exit;

  for I := 0 to AMap.EntryCount - 1 do
  begin
    Entry := AMap.GetEntry(I);
    Found := False;
    for J := Low(AAllowed) to High(AAllowed) do
      if Entry.Key = AAllowed[J] then
      begin
        Found := True;
        Break;
      end;

    if not Found then
    begin
      if (AContext = 'manifest root') and (Entry.Key = 'project') then
        RaiseManifestError(AManifestPath, Entry.KeyLine,
          'Unknown key ''project'' in manifest root (use ''program'', ''library'', or ''package'').');
      Hint := SuggestClosestKey(Entry.Key, AAllowed);
      if Hint <> '' then
        RaiseManifestError(AManifestPath, Entry.KeyLine,
          Format('Unknown key ''%s'' in %s (did you mean ''%s''?).', [Entry.Key, AContext, Hint]))
      else
        RaiseManifestError(AManifestPath, Entry.KeyLine,
          Format('Unknown key ''%s'' in %s.', [Entry.Key, AContext]));
    end;
  end;
end;

function ExpectScalarString(ANode: TYamlNode; const AFieldName, AManifestPath: string;
  AAllowEmpty: Boolean = False): string;
begin
  if ANode.Kind = ynkNull then
  begin
    if AAllowEmpty then
      Exit('');
    RaiseManifestError(AManifestPath, ANode.Line, Format('''%s'' cannot be empty.', [AFieldName]));
  end;
  if ANode.Kind <> ynkScalar then
    RaiseManifestError(AManifestPath, ANode.Line, Format('''%s'' must be a string value.', [AFieldName]));
  Result := Trim(ANode.ScalarValue);
  if (not AAllowEmpty) and (Result = '') then
    RaiseManifestError(AManifestPath, ANode.Line, Format('''%s'' cannot be empty.', [AFieldName]));
end;

function ExpectBoolean(ANode: TYamlNode; const AFieldName, AManifestPath: string): Boolean;
begin
  if not ANode.AsBoolean(Result) then
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('''%s'' must be a boolean (true or false).', [AFieldName]));
end;

function ExpectNonNegativeInt(ANode: TYamlNode; const AFieldName, AManifestPath: string): Integer;
begin
  if (not ANode.AsInteger(Result)) or (Result < 0) then
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('''%s'' must be a non-negative integer.', [AFieldName]));
end;

function ExpectStringList(ANode: TYamlNode; const AFieldName, AManifestPath: string): TStringArray;
var
  I: Integer;
  Item: TYamlNode;
begin
  Result := nil;
  if ANode.Kind = ynkNull then
    Exit;
  if ANode.Kind <> ynkSequence then
    RaiseManifestError(AManifestPath, ANode.Line, Format('''%s'' must be a list of strings.', [AFieldName]));

  SetLength(Result, ANode.Count);
  for I := 0 to ANode.Count - 1 do
  begin
    Item := ANode.GetItem(I);
    if (Item.Kind <> ynkScalar) or (Trim(Item.ScalarValue) = '') then
      RaiseManifestError(AManifestPath, Item.Line,
        Format('All items in ''%s'' must be non-empty strings.', [AFieldName]));
    Result[I] := Trim(Item.ScalarValue);
  end;
end;

procedure ReadOptStr(AMap: TYamlNode; const AKey, AContext, AManifestPath: string;
  AAllowEmpty: Boolean; var AHas: Boolean; var AVal: string);
var
  Sub: TYamlNode;
begin
  Sub := AMap.Find(AKey);
  if Sub <> nil then
  begin
    AHas := True;
    AVal := ExpectScalarString(Sub, AContext + '.' + AKey, AManifestPath, AAllowEmpty);
  end;
end;

procedure ReadOptBool(AMap: TYamlNode; const AKey, AContext, AManifestPath: string;
  var AHas: Boolean; var AVal: Boolean);
var
  Sub: TYamlNode;
begin
  Sub := AMap.Find(AKey);
  if Sub <> nil then
  begin
    AHas := True;
    AVal := ExpectBoolean(Sub, AContext + '.' + AKey, AManifestPath);
  end;
end;

procedure ReadOptNonNegInt(AMap: TYamlNode; const AKey, AContext, AManifestPath: string;
  var AHas: Boolean; var AVal: Integer);
var
  Sub: TYamlNode;
begin
  Sub := AMap.Find(AKey);
  if Sub <> nil then
  begin
    AHas := True;
    AVal := ExpectNonNegativeInt(Sub, AContext + '.' + AKey, AManifestPath);
  end;
end;

procedure ReadOptStrList(AMap: TYamlNode; const AKey, AContext, AManifestPath: string;
  var AHas: Boolean; var AVal: TStringArray);
var
  Sub: TYamlNode;
begin
  Sub := AMap.Find(AKey);
  if Sub <> nil then
  begin
    AHas := True;
    AVal := ExpectStringList(Sub, AContext + '.' + AKey, AManifestPath);
  end;
end;

function ParseSuppressCodeList(ANode: TYamlNode; const AFieldName, AManifestPath: string): TStringArray;
var
  I, CodeVal: Integer;
  Item: TYamlNode;
  RawItem: string;
begin
  Result := nil;
  if ANode.Kind = ynkNull then
    Exit;
  if ANode.Kind <> ynkSequence then
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('''%s'' must be a list of FPC message numbers (e.g. [5024, 5028]).', [AFieldName]));

  SetLength(Result, ANode.Count);
  for I := 0 to ANode.Count - 1 do
  begin
    Item := ANode.GetItem(I);
    if Item.Kind <> ynkScalar then
      RaiseManifestError(AManifestPath, Item.Line,
        Format('Items in ''%s'' must be integer FPC message numbers.', [AFieldName]));
    RawItem := Trim(Item.ScalarValue);
    if (I = 0) and SameText(RawItem, '$reset') then
    begin
      Result[I] := '$reset';
      Continue;
    end;
    if (not Item.AsInteger(CodeVal)) or (CodeVal <= 0) then
      RaiseManifestError(AManifestPath, Item.Line,
        Format('Invalid FPC message number ''%s'' in ''%s'' (expected positive integer such as 5024).',
          [RawItem, AFieldName]));
    Result[I] := IntToStr(CodeVal);
  end;
end;

function NormalizeMode(const ARaw: string; ALine: Integer; const AManifestPath: string): string;
var
  Lower: string;
begin
  Lower := LowerCase(Trim(ARaw));
  if (Lower = 'objfpc') or (Lower = 'delphi') or (Lower = 'delphiunicode') or
     (Lower = 'fpc') or (Lower = 'tp') or (Lower = 'macpas') or (Lower = 'iso') or
     (Lower = 'extendedpascal') then
    Result := Lower
  else
    RaiseManifestError(AManifestPath, ALine,
      Format('Invalid build.mode ''%s'' (expected objfpc, delphi, delphiunicode, fpc, tp, macpas, iso, or extendedpascal).',
        [ARaw]));
end;

procedure ValidateModeSwitches(const ASwitches: TStringArray; ALine: Integer;
  const AFieldName, AManifestPath: string);
var
  I, J: Integer;
  S: string;
  Ch: Char;
begin
  for I := 0 to High(ASwitches) do
  begin
    S := ASwitches[I];
    if (I = 0) and SameText(S, '$reset') then
      Continue;
    for J := 1 to Length(S) do
    begin
      Ch := S[J];
      if not (((Ch >= 'A') and (Ch <= 'Z')) or
              ((Ch >= 'a') and (Ch <= 'z')) or
              ((Ch >= '0') and (Ch <= '9')) or
              (Ch = '_') or (Ch = '-')) then
        RaiseManifestError(AManifestPath, ALine,
          Format('Invalid modeSwitch ''%s'' in ''%s''.', [S, AFieldName]));
    end;
  end;
end;

function ParseSubsystem(ANode: TYamlNode; const AFieldName, AManifestPath: string): TAppSubsystem;
var
  Lower: string;
begin
  Lower := LowerCase(ExpectScalarString(ANode, AFieldName, AManifestPath));
  if Lower = 'console' then
    Result := asConsole
  else if Lower = 'gui' then
    Result := asGui
  else
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('Invalid %s ''%s'' (expected console or gui).', [AFieldName, ANode.ScalarValue]));
end;

function ParsePicMode(ANode: TYamlNode; const AFieldName, AManifestPath: string): TPicMode;
var
  B: Boolean;
  Lower: string;
begin
  if ANode.AsBoolean(B) then
  begin
    if B then
      Exit(pmOn)
    else
      Exit(pmOff);
  end;

  Lower := LowerCase(ExpectScalarString(ANode, AFieldName, AManifestPath));
  if Lower = 'auto' then
    Result := pmAuto
  else if Lower = 'on' then
    Result := pmOn
  else if Lower = 'off' then
    Result := pmOff
  else
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('Invalid %s ''%s'' (expected auto, true, or false).', [AFieldName, ANode.ScalarValue]));
end;

function NormalizeToolchainTarget(const ARaw: string; ALine: Integer;
  const AFieldName, AManifestPath: string): string;
var
  Lower: string;
begin
  Lower := LowerCase(Trim(ARaw));
  if (Lower = '') or (Lower = 'native') then
    Exit('native');
  if Lower = 'x86_64-windows' then
    Exit('x86_64-win64');
  if Lower = 'aarch64-windows' then
    Exit('aarch64-win64');
  if Lower = 'x86_64-macos' then
    Exit('x86_64-darwin');
  if Lower = 'aarch64-macos' then
    Exit('aarch64-darwin');

  if (Lower = 'x86_64-win64') or (Lower = 'aarch64-win64') or
     (Lower = 'x86_64-linux') or (Lower = 'aarch64-linux') or
     (Lower = 'x86_64-darwin') or (Lower = 'aarch64-darwin') then
    Result := Lower
  else
    RaiseManifestError(AManifestPath, ALine,
      Format('Invalid %s ''%s'' (expected native, x86_64-win64, aarch64-win64, x86_64-linux, aarch64-linux, x86_64-darwin, or aarch64-darwin).',
        [AFieldName, ARaw]));
end;

procedure ValidateTargetSelector(const ASelector: string; ALine: Integer;
  const AContext, AManifestPath: string);
const
  ALLOWED_TARGETS: array[0..13] of string = (
    'unix', 'windows', 'win64', 'linux', 'darwin', 'macos',
    'x86_64', 'aarch64',
    'x86_64-win64', 'aarch64-win64',
    'x86_64-linux', 'aarch64-linux',
    'x86_64-darwin', 'aarch64-darwin'
  );
var
  I: Integer;
  Lower, Hint: string;
begin
  Lower := LowerCase(Trim(ASelector));
  for I := Low(ALLOWED_TARGETS) to High(ALLOWED_TARGETS) do
    if Lower = ALLOWED_TARGETS[I] then
      Exit;

  Hint := SuggestClosestKey(Lower, ALLOWED_TARGETS);
  if Hint <> '' then
    RaiseManifestError(AManifestPath, ALine,
      Format('Unknown target selector ''%s'' in %s (did you mean ''%s''?).',
        [ASelector, AContext, Hint]))
  else
    RaiseManifestError(AManifestPath, ALine,
      Format('Unknown target selector ''%s'' in %s (expected windows, linux, darwin, unix, x86_64, aarch64, or <cpu>-<os>).',
        [ASelector, AContext]));
end;

function NormalizeDebugInfo(ANode: TYamlNode; const AFieldName, AManifestPath: string): string;
var
  B: Boolean;
  Lower: string;
begin
  if ANode.AsBoolean(B) then
  begin
    if B then
      Exit('dwarf2')
    else
      Exit('none');
  end;

  Lower := LowerCase(ExpectScalarString(ANode, AFieldName, AManifestPath));
  if (Lower = 'none') or (Lower = 'off') then
    Result := 'none'
  else if (Lower = 'dwarf') or (Lower = 'dwarf2') then
    Result := 'dwarf2'
  else if Lower = 'dwarf3' then
    Result := 'dwarf3'
  else if Lower = 'stabs' then
    Result := 'stabs'
  else if Lower = 'lineinfo' then
    Result := 'lineinfo'
  else if Lower = 'external' then
    Result := 'external'
  else
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('Invalid %s ''%s'' (expected none, lineinfo, dwarf2, dwarf3, stabs, or external).',
        [AFieldName, ANode.ScalarValue]));
end;

function ParseOptimization(ANode: TYamlNode; const AFieldName, AManifestPath: string): Integer;
var
  N: Integer;
  B: Boolean;
  Lower: string;
begin
  if ANode.AsInteger(N) then
  begin
    if (N >= 0) and (N <= 4) then
      Exit(N);
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('%s integer level must be between 0 and 4.', [AFieldName]));
  end;

  if ANode.AsBoolean(B) then
  begin
    if B then
      Exit(2)
    else
      Exit(0);
  end;

  Lower := LowerCase(ExpectScalarString(ANode, AFieldName, AManifestPath));
  if (Lower = 'none') or (Lower = '0') then
    Result := 0
  else if Lower = '1' then
    Result := 1
  else if (Lower = 'default') or (Lower = '2') then
    Result := 2
  else if Lower = '3' then
    Result := 3
  else if Lower = '4' then
    Result := 4
  else
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('Invalid %s ''%s'' (expected 0..4 or none).', [AFieldName, ANode.ScalarValue]));
end;

procedure ValidateChecksList(const AChecks: TStringArray; ALine: Integer;
  const AFieldName, AManifestPath: string);
var
  I: Integer;
  Lower: string;
begin
  for I := 0 to High(AChecks) do
  begin
    Lower := LowerCase(AChecks[I]);
    if (Lower <> 'range') and (Lower <> 'overflow') and (Lower <> 'io') and
       (Lower <> 'stack') and (Lower <> 'object') and (Lower <> 'all') and
       (Lower <> 'none') and (Lower <> '$reset') then
      RaiseManifestError(AManifestPath, ALine,
        Format('Invalid check ''%s'' in %s (expected range, overflow, io, stack, object, all, or none).',
          [AChecks[I], AFieldName]));
  end;
end;

function FindUrlPathAtSeparator(const ARawUrl: string): Integer;
var
  SchemeSep, RestSlash, PathStart, I: Integer;
  Scheme, Rest: string;
begin
  Result := 0;
  SchemeSep := Pos('://', ARawUrl);
  if SchemeSep <= 1 then
    Exit;
  Scheme := LowerCase(Copy(ARawUrl, 1, SchemeSep - 1));
  Rest := Copy(ARawUrl, SchemeSep + 3, MaxInt);
  if Scheme = 'file' then
    PathStart := SchemeSep + 3
  else
  begin
    RestSlash := Pos('/', Rest);
    if RestSlash <= 0 then
      Exit;
    PathStart := SchemeSep + 2 + RestSlash;
  end;

  for I := Length(ARawUrl) downto PathStart + 1 do
    if ARawUrl[I] = '@' then
      Exit(I);
end;

procedure ParseScalarDependencySpec(const AName, ARaw: string; ALine: Integer;
  const AManifestPath: string; var ASpec: TDependencySpec);
var
  Raw, BaseUrl, SpecPart, ErrMsg: string;
  AtPos: Integer;
  DummyConstraint: TSemVerConstraint;
begin
  Raw := Trim(ARaw);
  if HasExplicitLocalPathPrefix(Raw) then
  begin
    ASpec.Path := Raw;
    if IsSupportedArchivePath(Raw) then
      ASpec.Kind := dskLocalArchive
    else
      ASpec.Kind := dskLocalPath;
    Exit;
  end;

  if HasExplicitUrlScheme(Raw) then
  begin
    AtPos := FindUrlPathAtSeparator(Raw);
    if AtPos > 0 then
    begin
      BaseUrl := Copy(Raw, 1, AtPos - 1);
      SpecPart := Trim(Copy(Raw, AtPos + 1, MaxInt));
      if SpecPart = '' then
        RaiseManifestError(AManifestPath, ALine,
          Format('Dependency ''%s'' has an empty version/commit specifier after ''@''.', [AName]));

      if not NormalizeRemoteUrlBase(BaseUrl, True, ASpec.Url, ErrMsg) then
        RaiseManifestError(AManifestPath, ALine, ErrMsg);

      if IsHexCommitSpecifier(SpecPart) then
        ASpec.Rev := NormalizeHexCommit(SpecPart)
      else if TryParseSemVerConstraint(SpecPart, DummyConstraint, ErrMsg) then
        ASpec.VersionSpec := SpecPart
      else
        RaiseManifestError(AManifestPath, ALine, ErrMsg);

      ASpec.Kind := dskGitRepo;
      Exit;
    end;

    if IsSupportedArchivePath(Raw) then
    begin
      if not NormalizeRemoteUrlBase(Raw, False, ASpec.Url, ErrMsg) then
        RaiseManifestError(AManifestPath, ALine, ErrMsg);
      ASpec.Kind := dskArchiveUrl;
      Exit;
    end;

    if not NormalizeRemoteUrlBase(Raw, True, ASpec.Url, ErrMsg) then
      RaiseManifestError(AManifestPath, ALine, ErrMsg);

    RaiseManifestError(AManifestPath, ALine,
      Format('Git dependency ''%s'' URL ''%s'' must include ''@<version>'' or ''@<commit>'' (e.g. %s@^0.1.0), or end in .zip/.tar.gz/.tgz.',
        [AName, Raw, ASpec.Url]));
  end;

  RaiseManifestError(AManifestPath, ALine,
    Format('Ambiguous dependency ''%s'' value ''%s'': prefix remote URLs with ''https://'' (e.g. https://github.com/owner/repo@^0.1.0) or local paths with ''./'' or ''../''.',
      [AName, Raw]));
end;

procedure ParseDependenciesSection(ANode: TYamlNode; const AContext, AManifestPath: string;
  out ADeps: TDependencySpecArray);
const
  ALLOWED_DEP_KEYS: array[0..7] of string = (
    'path', 'url', 'version', 'rev', 'subpath', 'sha256', 'unitPaths', 'includePaths'
  );
var
  I: Integer;
  Entry: TYamlKeyValue;
  ValNode: TYamlNode;
  Spec: TDependencySpec;
  DepCtx, RawPath, RawUrl, RawVer, RawRev, RawSubpath, RawSha256, ErrMsg: string;
  DummyHas: Boolean;
  DummyConstraint: TSemVerConstraint;
begin
  ADeps := nil;
  if ANode.Kind = ynkNull then
    Exit;
  if ANode.Kind <> ynkMapping then
    RaiseManifestError(AManifestPath, ANode.Line,
      Format('''%s'' must be a mapping of package names.', [AContext]));

  SetLength(ADeps, ANode.EntryCount);
  for I := 0 to ANode.EntryCount - 1 do
  begin
    Entry := ANode.GetEntry(I);
    ValNode := Entry.Value;
    Spec := Default(TDependencySpec);
    Spec.Name := Entry.Key;
    Spec.DefinedLine := Entry.KeyLine;
    DepCtx := AContext + '.' + Entry.Key;
    DummyHas := False;

    if ValNode.Kind = ynkScalar then
    begin
      ParseScalarDependencySpec(
        Entry.Key,
        ExpectScalarString(ValNode, DepCtx, AManifestPath),
        ValNode.Line,
        AManifestPath,
        Spec
      );
    end
    else if ValNode.Kind = ynkMapping then
    begin
      ValidateAllowedKeys(ValNode, ALLOWED_DEP_KEYS, DepCtx, AManifestPath);
      RawPath := '';
      RawUrl := '';
      RawVer := '';
      RawRev := '';
      RawSubpath := '';
      RawSha256 := '';

      ReadOptStr(ValNode, 'path', DepCtx, AManifestPath, False, DummyHas, RawPath);
      ReadOptStr(ValNode, 'url', DepCtx, AManifestPath, False, DummyHas, RawUrl);
      ReadOptStr(ValNode, 'version', DepCtx, AManifestPath, False, DummyHas, RawVer);
      ReadOptStr(ValNode, 'rev', DepCtx, AManifestPath, False, DummyHas, RawRev);
      ReadOptStr(ValNode, 'subpath', DepCtx, AManifestPath, False, DummyHas, RawSubpath);
      ReadOptStr(ValNode, 'sha256', DepCtx, AManifestPath, False, DummyHas, RawSha256);
      ReadOptStrList(ValNode, 'unitPaths', DepCtx, AManifestPath, DummyHas, Spec.UnitPaths);
      ReadOptStrList(ValNode, 'includePaths', DepCtx, AManifestPath, DummyHas, Spec.IncludePaths);

      if RawSubpath <> '' then
      begin
        if not ValidateCleanSubpath(RawSubpath, Spec.Subpath, ErrMsg) then
          RaiseManifestError(AManifestPath, ValNode.Find('subpath').Line, ErrMsg);
      end;

      if RawSha256 <> '' then
      begin
        if not ValidateHexSha256(RawSha256, Spec.Sha256) then
          RaiseManifestError(AManifestPath, ValNode.Find('sha256').Line,
            Format('Invalid SHA-256 hex digest ''%s'' in ''%s.sha256'' (expected 64 hex characters).', [RawSha256, DepCtx]));
      end;

      if (RawVer <> '') and (RawRev <> '') then
        RaiseManifestError(AManifestPath, Entry.KeyLine,
          Format('Dependency ''%s'' cannot specify both ''version'' and ''rev''.', [Entry.Key]));

      if RawVer <> '' then
      begin
        if not TryParseSemVerConstraint(RawVer, DummyConstraint, ErrMsg) then
          RaiseManifestError(AManifestPath, ValNode.Find('version').Line, ErrMsg);
        Spec.VersionSpec := Trim(RawVer);
      end;

      if RawRev <> '' then
      begin
        if not IsHexCommitSpecifier(RawRev) then
          RaiseManifestError(AManifestPath, ValNode.Find('rev').Line,
            Format('Invalid commit hash ''%s'' in ''%s.rev''. Moving branch names are disallowed; use a 7..40 char hex commit hash.',
              [RawRev, DepCtx]));
        Spec.Rev := NormalizeHexCommit(RawRev);
      end;

      if (RawPath = '') and (RawUrl = '') then
        RaiseManifestError(AManifestPath, Entry.KeyLine,
          Format('Dependency ''%s'' must specify ''path'' or ''url''.', [Entry.Key]));

      if RawPath <> '' then
      begin
        if HasExplicitUrlScheme(RawPath) then
          RaiseManifestError(AManifestPath, ValNode.Find('path').Line,
            Format('''%s.path'' must be a local filesystem path, not a URL (use ''url'' for remote sources).', [DepCtx]));
        Spec.Path := Trim(RawPath);
      end;

      if RawUrl <> '' then
      begin
        if FindUrlPathAtSeparator(RawUrl) > 0 then
          RaiseManifestError(AManifestPath, ValNode.Find('url').Line,
            Format('In mapping form, specify ''version'' or ''rev'' as separate keys instead of ''@...'' inside ''%s.url''.', [DepCtx]));
      end;

      if (RawPath <> '') and (RawUrl = '') then
      begin
        if (Spec.VersionSpec <> '') or (Spec.Rev <> '') then
          RaiseManifestError(AManifestPath, Entry.KeyLine,
            Format('Local dependency ''%s'' cannot specify ''version'' or ''rev'' without ''url''.', [Entry.Key]));

        if IsSupportedArchivePath(Spec.Path) then
          Spec.Kind := dskLocalArchive
        else
        begin
          if Spec.Sha256 <> '' then
            RaiseManifestError(AManifestPath, ValNode.Find('sha256').Line,
              Format('''%s.sha256'' is only valid on archive dependencies (.zip, .tar.gz, .tgz).', [DepCtx]));
          Spec.Kind := dskLocalPath;
        end;
      end
      else if (RawUrl <> '') and (RawPath = '') then
      begin
        if IsSupportedArchivePath(RawUrl) and (Spec.VersionSpec = '') and (Spec.Rev = '') then
        begin
          if not NormalizeRemoteUrlBase(RawUrl, False, Spec.Url, ErrMsg) then
            RaiseManifestError(AManifestPath, ValNode.Find('url').Line, ErrMsg);
          Spec.Kind := dskArchiveUrl;
        end
        else
        begin
          if not NormalizeRemoteUrlBase(RawUrl, True, Spec.Url, ErrMsg) then
            RaiseManifestError(AManifestPath, ValNode.Find('url').Line, ErrMsg);
          if (Spec.VersionSpec = '') and (Spec.Rev = '') then
            RaiseManifestError(AManifestPath, Entry.KeyLine,
              Format('Git dependency ''%s'' with ''url'' must specify ''version'' or ''rev''.', [Entry.Key]));
          if Spec.Sha256 <> '' then
            RaiseManifestError(AManifestPath, ValNode.Find('sha256').Line,
              Format('''%s.sha256'' is only supported on direct archive dependencies (Git dependencies verify tree integrity via nik.lock).', [DepCtx]));
          Spec.Kind := dskGitRepo;
        end;
      end
      else
      begin
        // Both 'url' and 'path' specified: local checkout/archive overriding a remote URL across the dependency tree
        if not NormalizeRemoteUrlBase(RawUrl, not IsSupportedArchivePath(RawUrl), Spec.Url, ErrMsg) then
          RaiseManifestError(AManifestPath, ValNode.Find('url').Line, ErrMsg);
        if IsSupportedArchivePath(Spec.Path) then
          Spec.Kind := dskLocalArchive
        else
          Spec.Kind := dskLocalPath;
      end;
    end
    else
      RaiseManifestError(AManifestPath, Entry.KeyLine,
        Format('Dependency ''%s'' must be a compact path/URL string or a mapping.', [Entry.Key]));

    ADeps[I] := Spec;
  end;
end;

procedure ParseWarningsSection(ANode: TYamlNode; const AContext, AManifestPath: string;
  out AWarnings: TWarningsOverlay);
const
  WARNINGS_KEYS: array[0..3] of string = (
    'asErrors', 'hints', 'notes', 'suppress'
  );
var
  Sub: TYamlNode;
begin
  AWarnings := Default(TWarningsOverlay);
  if (ANode = nil) or (ANode.Kind = ynkNull) then
    Exit;
  if ANode.Kind <> ynkMapping then
    RaiseManifestError(AManifestPath, ANode.Line, Format('''%s'' must be a mapping.', [AContext]));

  ValidateAllowedKeys(ANode, WARNINGS_KEYS, AContext, AManifestPath);
  ReadOptBool(ANode, 'asErrors', AContext, AManifestPath, AWarnings.HasAsErrors, AWarnings.AsErrors);
  ReadOptBool(ANode, 'hints', AContext, AManifestPath, AWarnings.HasHints, AWarnings.Hints);
  ReadOptBool(ANode, 'notes', AContext, AManifestPath, AWarnings.HasNotes, AWarnings.Notes);

  Sub := ANode.Find('suppress');
  if Sub <> nil then
  begin
    AWarnings.HasSuppress := True;
    AWarnings.Suppress := ParseSuppressCodeList(Sub, AContext + '.suppress', AManifestPath);
  end;
end;

procedure ParseBuildSection(ASec: TYamlNode; const AContext, AManifestPath: string;
  out ABuild: TBuildOverlay);
const
  BUILD_KEYS: array[0..26] of string = (
    'mode', 'longStrings', 'cOperators', 'modeSwitches',
    'subsystem', 'pic', 'cpuType', 'fpuType', 'stackSize',
    'unitPaths', 'includePaths', 'libraryPaths', 'objectPaths', 'resourcePaths',
    'defines', 'undefines',
    'debugInfo', 'heaptrc', 'assertions', 'checks',
    'warnings',
    'optimization', 'smartLink', 'stripSymbols', 'linkLibraries', 'linkerArgs', 'fpcArgs'
  );
var
  Sub: TYamlNode;
begin
  ABuild := Default(TBuildOverlay);
  if (ASec = nil) or (ASec.Kind = ynkNull) then
    Exit;
  if ASec.Kind <> ynkMapping then
    RaiseManifestError(AManifestPath, ASec.Line, Format('''%s'' must be a mapping.', [AContext]));

  ValidateAllowedKeys(ASec, BUILD_KEYS, AContext, AManifestPath);

  Sub := ASec.Find('mode');
  if Sub <> nil then
  begin
    ABuild.HasMode := True;
    ABuild.Mode := NormalizeMode(ExpectScalarString(Sub, AContext + '.mode', AManifestPath), Sub.Line, AManifestPath);
  end;
  ReadOptBool(ASec, 'longStrings', AContext, AManifestPath, ABuild.HasLongStrings, ABuild.LongStrings);
  ReadOptBool(ASec, 'cOperators', AContext, AManifestPath, ABuild.HasCOperators, ABuild.COperators);
  ReadOptStrList(ASec, 'modeSwitches', AContext, AManifestPath, ABuild.HasModeSwitches, ABuild.ModeSwitches);
  if ABuild.HasModeSwitches then
    ValidateModeSwitches(ABuild.ModeSwitches, ASec.Find('modeSwitches').Line, AContext + '.modeSwitches', AManifestPath);

  Sub := ASec.Find('subsystem');
  if Sub <> nil then
  begin
    ABuild.HasSubsystem := True;
    ABuild.Subsystem := ParseSubsystem(Sub, AContext + '.subsystem', AManifestPath);
  end;
  Sub := ASec.Find('pic');
  if Sub <> nil then
  begin
    ABuild.HasPic := True;
    ABuild.Pic := ParsePicMode(Sub, AContext + '.pic', AManifestPath);
  end;
  ReadOptStr(ASec, 'cpuType', AContext, AManifestPath, True, ABuild.HasCpuType, ABuild.CpuType);
  ReadOptStr(ASec, 'fpuType', AContext, AManifestPath, True, ABuild.HasFpuType, ABuild.FpuType);
  ReadOptNonNegInt(ASec, 'stackSize', AContext, AManifestPath, ABuild.HasStackSize, ABuild.StackSize);

  ReadOptStrList(ASec, 'unitPaths', AContext, AManifestPath, ABuild.HasUnitPaths, ABuild.UnitPaths);
  ReadOptStrList(ASec, 'includePaths', AContext, AManifestPath, ABuild.HasIncludePaths, ABuild.IncludePaths);
  ReadOptStrList(ASec, 'libraryPaths', AContext, AManifestPath, ABuild.HasLibraryPaths, ABuild.LibraryPaths);
  ReadOptStrList(ASec, 'objectPaths', AContext, AManifestPath, ABuild.HasObjectPaths, ABuild.ObjectPaths);
  ReadOptStrList(ASec, 'resourcePaths', AContext, AManifestPath, ABuild.HasResourcePaths, ABuild.ResourcePaths);

  ReadOptStrList(ASec, 'defines', AContext, AManifestPath, ABuild.HasDefines, ABuild.Defines);
  ReadOptStrList(ASec, 'undefines', AContext, AManifestPath, ABuild.HasUndefines, ABuild.Undefines);

  Sub := ASec.Find('debugInfo');
  if Sub <> nil then
  begin
    ABuild.HasDebugInfo := True;
    ABuild.DebugInfo := NormalizeDebugInfo(Sub, AContext + '.debugInfo', AManifestPath);
  end;
  ReadOptBool(ASec, 'heaptrc', AContext, AManifestPath, ABuild.HasHeaptrc, ABuild.Heaptrc);
  ReadOptBool(ASec, 'assertions', AContext, AManifestPath, ABuild.HasAssertions, ABuild.Assertions);
  ReadOptStrList(ASec, 'checks', AContext, AManifestPath, ABuild.HasChecks, ABuild.Checks);
  if ABuild.HasChecks then
    ValidateChecksList(ABuild.Checks, ASec.Find('checks').Line, AContext + '.checks', AManifestPath);

  Sub := ASec.Find('warnings');
  if Sub <> nil then
    ParseWarningsSection(Sub, AContext + '.warnings', AManifestPath, ABuild.Warnings);

  Sub := ASec.Find('optimization');
  if Sub <> nil then
  begin
    ABuild.HasOptimization := True;
    ABuild.Optimization := ParseOptimization(Sub, AContext + '.optimization', AManifestPath);
  end;
  ReadOptBool(ASec, 'smartLink', AContext, AManifestPath, ABuild.HasSmartLink, ABuild.SmartLink);
  ReadOptBool(ASec, 'stripSymbols', AContext, AManifestPath, ABuild.HasStripSymbols, ABuild.StripSymbols);
  ReadOptStrList(ASec, 'linkLibraries', AContext, AManifestPath, ABuild.HasLinkLibraries, ABuild.LinkLibraries);
  ReadOptStrList(ASec, 'linkerArgs', AContext, AManifestPath, ABuild.HasLinkerArgs, ABuild.LinkerArgs);
  ReadOptStrList(ASec, 'fpcArgs', AContext, AManifestPath, ABuild.HasFpcArgs, ABuild.FpcArgs);
end;

procedure ParseOverlayNode(AMap: TYamlNode; AKind: TManifestKind; AScope: TOverlayScope;
  const AContextPrefix, AManifestPath: string; out AOverlay: TManifestOverlay);
const
  ROOT_ARTIFACT_KEYS: array[0..13] of string = (
    'name', 'version', 'description', 'license', 'repository', 'authors',
    'entry', 'output',
    'toolchain', 'build', 'dependencies', 'test', 'targets', 'profiles'
  );
  TEST_OVERLAY_KEYS: array[0..4] of string = (
    'entry', 'output', 'toolchain', 'build', 'dependencies'
  );
  SUB_OVERLAY_KEYS: array[0..6] of string = (
    'name', 'version', 'entry', 'output', 'toolchain', 'build', 'dependencies'
  );
  TEMPLATE_ROOT_KEYS: array[0..9] of string = (
    'version', 'description', 'license', 'repository', 'authors',
    'toolchain', 'build', 'dependencies', 'targets', 'profiles'
  );
  TEMPLATE_SUB_KEYS: array[0..3] of string = (
    'version', 'toolchain', 'build', 'dependencies'
  );
  TOOLCHAIN_KEYS: array[0..1] of string = (
    'fpc', 'target'
  );
var
  Sec, Sub: TYamlNode;
begin
  AOverlay := Default(TManifestOverlay);
  if AMap.Kind = ynkNull then
    Exit;
  if AMap.Kind <> ynkMapping then
    RaiseManifestError(AManifestPath, AMap.Line, Format('Expected mapping in ''%s''.', [AContextPrefix]));

  case AScope of
    osRoot:
      ValidateAllowedKeys(AMap, ROOT_ARTIFACT_KEYS, AContextPrefix, AManifestPath);
    osTemplateRoot:
      ValidateAllowedKeys(AMap, TEMPLATE_ROOT_KEYS, AContextPrefix, AManifestPath);
    osTest, osTarget, osProfile, osTemplateSub:
      begin
        if AMap.HasKey('profiles') then
          RaiseManifestError(AManifestPath, AMap.Find('profiles').Line,
            Format('''profiles'' cannot be nested inside ''%s''.', [AContextPrefix]));
        if AMap.HasKey('targets') then
          RaiseManifestError(AManifestPath, AMap.Find('targets').Line,
            Format('''targets'' cannot be nested inside ''%s''.', [AContextPrefix]));
        if AMap.HasKey('test') then
          RaiseManifestError(AManifestPath, AMap.Find('test').Line,
            Format('''test'' cannot be nested inside ''%s''.', [AContextPrefix]));

        if AScope = osTest then
          ValidateAllowedKeys(AMap, TEST_OVERLAY_KEYS, AContextPrefix, AManifestPath)
        else if AScope = osTemplateSub then
          ValidateAllowedKeys(AMap, TEMPLATE_SUB_KEYS, AContextPrefix, AManifestPath)
        else
          ValidateAllowedKeys(AMap, SUB_OVERLAY_KEYS, AContextPrefix, AManifestPath);
      end;
  else
    raise ENikError.CreateFmt('Unsupported TOverlayScope ordinal: %d', [Ord(AScope)]);
  end;

  ReadOptStr(AMap, 'name', AContextPrefix, AManifestPath, False, AOverlay.HasName, AOverlay.Name);
  ReadOptStr(AMap, 'version', AContextPrefix, AManifestPath, False, AOverlay.HasVersion, AOverlay.Version);
  ReadOptStr(AMap, 'description', AContextPrefix, AManifestPath, True, AOverlay.HasDescription, AOverlay.Description);
  ReadOptStr(AMap, 'license', AContextPrefix, AManifestPath, False, AOverlay.HasLicense, AOverlay.License);
  ReadOptStr(AMap, 'repository', AContextPrefix, AManifestPath, False, AOverlay.HasRepository, AOverlay.Repository);
  ReadOptStrList(AMap, 'authors', AContextPrefix, AManifestPath, AOverlay.HasAuthors, AOverlay.Authors);

  // Entry & output validation (disallowed on 'package' outside 'test')
  Sub := AMap.Find('entry');
  if Sub <> nil then
  begin
    if (AKind = mkPackage) and (AScope <> osTest) then
      RaiseManifestError(AManifestPath, Sub.Line,
        '''package'' defines a source unit package without a binary and cannot specify ''entry'' (use ''program'' for an executable, ''library'' for a shared library, or ''test.entry'' for package tests).');
    AOverlay.HasEntry := True;
    AOverlay.EntryLine := Sub.Line;
    AOverlay.Entry := ExpectScalarString(Sub, AContextPrefix + '.entry', AManifestPath);
  end;

  Sub := AMap.Find('output');
  if Sub <> nil then
  begin
    if (AKind = mkPackage) and (AScope <> osTest) then
      RaiseManifestError(AManifestPath, Sub.Line,
        '''package'' defines a source unit package without a binary and cannot specify ''output'' (use ''program'' for an executable, ''library'' for a shared library, or ''test.output'' for package tests).');
    AOverlay.HasOutput := True;
    AOverlay.OutputLine := Sub.Line;
    AOverlay.Output := ExpectScalarString(Sub, AContextPrefix + '.output', AManifestPath);
  end;

  // toolchain
  Sec := AMap.Find('toolchain');
  if (Sec <> nil) and (Sec.Kind <> ynkNull) then
  begin
    if Sec.Kind <> ynkMapping then
      RaiseManifestError(AManifestPath, Sec.Line, Format('''%s.toolchain'' must be a mapping.', [AContextPrefix]));
    ValidateAllowedKeys(Sec, TOOLCHAIN_KEYS, AContextPrefix + '.toolchain', AManifestPath);

    Sub := Sec.Find('fpc');
    if Sub <> nil then
    begin
      AOverlay.Toolchain.HasFpcVersion := True;
      AOverlay.Toolchain.FpcVersion := ExpectScalarString(Sub, AContextPrefix + '.toolchain.fpc', AManifestPath, False);
      if not IsExactFpcVersion(AOverlay.Toolchain.FpcVersion) then
        RaiseManifestError(AManifestPath, Sub.Line,
          Format('Invalid %s.toolchain.fpc ''%s'' (expected exact Free Pascal version such as ''3.2.2'' or ''3.3.1'').',
            [AContextPrefix, AOverlay.Toolchain.FpcVersion]));
    end;

    Sub := Sec.Find('target');
    if Sub <> nil then
    begin
      AOverlay.Toolchain.HasTarget := True;
      AOverlay.Toolchain.Target := NormalizeToolchainTarget(
        ExpectScalarString(Sub, AContextPrefix + '.toolchain.target', AManifestPath, True),
        Sub.Line, AContextPrefix + '.toolchain.target', AManifestPath);
    end;
  end;

  // build
  Sec := AMap.Find('build');
  if (Sec <> nil) and (Sec.Kind <> ynkNull) then
    ParseBuildSection(Sec, AContextPrefix + '.build', AManifestPath, AOverlay.Build);

  // dependencies
  Sec := AMap.Find('dependencies');
  if Sec <> nil then
  begin
    AOverlay.HasDependencies := True;
    ParseDependenciesSection(Sec, AContextPrefix + '.dependencies', AManifestPath, AOverlay.Dependencies);
  end;
end;

function FindManifestFile(const AExplicitPath: string): string;
var
  Candidate, CurDir, ParentDir, FileYaml, FileYml: string;
begin
  if Trim(AExplicitPath) <> '' then
  begin
    Candidate := ExpandFileName(NormalizeNativeSeparators(Trim(AExplicitPath)));
    if DirectoryExists(Candidate) then
    begin
      FileYaml := JoinPath(Candidate, 'nik.yaml');
      if FileExists(FileYaml) then
        Exit(FileYaml);
      FileYml := JoinPath(Candidate, 'nik.yml');
      if FileExists(FileYml) then
        Exit(FileYml);
      raise ENikError.CreateFmt('No nik.yaml found in directory: %s (run ''nik init'' to initialize a project)', [Candidate]);
    end;
    if FileExists(Candidate) then
      Exit(Candidate);
    raise ENikError.CreateFmt('Manifest file not found: %s', [Candidate]);
  end;

  CurDir := ExcludeTrailingPathDelimiter(ExpandFileName(GetCurrentDir));
  while CurDir <> '' do
  begin
    FileYaml := JoinPath(CurDir, 'nik.yaml');
    if FileExists(FileYaml) then
      Exit(FileYaml);
    FileYml := JoinPath(CurDir, 'nik.yml');
    if FileExists(FileYml) then
      Exit(FileYml);

    ParentDir := ExcludeTrailingPathDelimiter(ExtractFileDir(CurDir));
    if (ParentDir = '') or (ParentDir = CurDir) then
      Break;
    CurDir := ParentDir;
  end;

  raise ENikError.Create('No nik.yaml found in the current directory (or any parent directory). Run ''nik init'' to initialize a project.');
end;

function ParseManifestText(const AText, AManifestPath, AProjectDir: string): TParsedManifest;
const
  DOC_ROOT_KEYS: array[0..3] of string = (
    'schemaVersion', 'program', 'library', 'package'
  );
var
  Root, SchemaNode, ArtifactNode, TestNode, TargetsNode, ProfilesNode: TYamlNode;
  VerInt, I: Integer;
  Entry: TYamlKeyValue;
  FoundArtifactKey: string;
begin
  Result := Default(TParsedManifest);
  Result.ManifestPath := AManifestPath;
  Result.ProjectDir := ExcludeTrailingPathDelimiter(AProjectDir);
  Result.SchemaVersion := 1;

  Root := ParseYamlText(AText, AManifestPath);
  try
    if Root.Kind <> ynkMapping then
      RaiseManifestError(AManifestPath, Root.Line, 'Manifest root must be a YAML mapping.');

    ValidateAllowedKeys(Root, DOC_ROOT_KEYS, 'manifest root', AManifestPath);

    SchemaNode := Root.Find('schemaVersion');
    if SchemaNode <> nil then
    begin
      if (not SchemaNode.AsInteger(VerInt)) or (VerInt <> 1) then
        RaiseManifestError(AManifestPath, SchemaNode.Line,
          Format('Unsupported schemaVersion ''%s'' (expected 1).', [SchemaNode.ScalarValue]));
      Result.SchemaVersion := VerInt;
    end;

    FoundArtifactKey := '';
    ArtifactNode := nil;
    for I := 0 to Root.EntryCount - 1 do
    begin
      Entry := Root.GetEntry(I);
      if (Entry.Key = 'program') or (Entry.Key = 'library') or (Entry.Key = 'package') then
      begin
        if FoundArtifactKey <> '' then
          RaiseManifestError(AManifestPath, Entry.KeyLine,
            Format('Manifest can only declare one artifact root (found both ''%s'' and ''%s'').',
              [FoundArtifactKey, Entry.Key]));
        FoundArtifactKey := Entry.Key;
        ArtifactNode := Entry.Value;
        Result.RootLine := Entry.KeyLine;
        if Entry.Key = 'program' then
          Result.Kind := mkProgram
        else if Entry.Key = 'library' then
          Result.Kind := mkLibrary
        else
          Result.Kind := mkPackage;
      end;
    end;

    if FoundArtifactKey = '' then
      RaiseManifestError(AManifestPath, Root.Line,
        'Manifest must declare ''program'', ''library'', or ''package'' as its top-level artifact key.');

    if ArtifactNode.Kind <> ynkMapping then
      RaiseManifestError(AManifestPath, Result.RootLine,
        Format('''%s'' must be a YAML mapping.', [FoundArtifactKey]));

    ParseOverlayNode(ArtifactNode, Result.Kind, osRoot, FoundArtifactKey, AManifestPath, Result.Base);

    // Nested test section
    TestNode := ArtifactNode.Find('test');
    if (TestNode <> nil) and (TestNode.Kind <> ynkNull) then
    begin
      Result.HasTest := True;
      Result.TestLine := TestNode.Line;
      ParseOverlayNode(TestNode, Result.Kind, osTest, FoundArtifactKey + '.test', AManifestPath, Result.Test);
    end;

    // Nested targets section
    TargetsNode := ArtifactNode.Find('targets');
    if (TargetsNode <> nil) and (TargetsNode.Kind <> ynkNull) then
    begin
      if TargetsNode.Kind <> ynkMapping then
        RaiseManifestError(AManifestPath, TargetsNode.Line,
          Format('''%s.targets'' must be a mapping of target selectors.', [FoundArtifactKey]));

      SetLength(Result.Targets, TargetsNode.EntryCount);
      for I := 0 to TargetsNode.EntryCount - 1 do
      begin
        Entry := TargetsNode.GetEntry(I);
        ValidateTargetSelector(Entry.Key, Entry.KeyLine, FoundArtifactKey + '.targets', AManifestPath);
        Result.Targets[I].Name := LowerCase(Trim(Entry.Key));
        Result.Targets[I].Line := Entry.KeyLine;
        ParseOverlayNode(Entry.Value, Result.Kind, osTarget,
          FoundArtifactKey + '.targets.' + Entry.Key, AManifestPath, Result.Targets[I].Overlay);
      end;
    end;

    // Nested profiles section
    ProfilesNode := ArtifactNode.Find('profiles');
    if (ProfilesNode <> nil) and (ProfilesNode.Kind <> ynkNull) then
    begin
      if ProfilesNode.Kind <> ynkMapping then
        RaiseManifestError(AManifestPath, ProfilesNode.Line,
          Format('''%s.profiles'' must be a mapping of profile names.', [FoundArtifactKey]));

      SetLength(Result.Profiles, ProfilesNode.EntryCount);
      for I := 0 to ProfilesNode.EntryCount - 1 do
      begin
        Entry := ProfilesNode.GetEntry(I);
        Result.Profiles[I].Name := Entry.Key;
        Result.Profiles[I].Line := Entry.KeyLine;
        ParseOverlayNode(Entry.Value, Result.Kind, osProfile,
          FoundArtifactKey + '.profiles.' + Entry.Key, AManifestPath, Result.Profiles[I].Overlay);
      end;
    end;
  finally
    Root.Free;
  end;
end;

function LoadManifestFile(const AManifestPath: string): TParsedManifest;
var
  FullPath, ProjDir: string;
begin
  FullPath := ExpandFileName(NormalizeNativeSeparators(AManifestPath));
  ProjDir := ExcludeTrailingPathDelimiter(ExtractFileDir(FullPath));
  Result := ParseManifestText(ReadFileTextUtf8(FullPath), FullPath, ProjDir);
end;

function ParseTemplateText(const AText, ATemplatePath: string): TParsedTemplate;
const
  TEMPLATE_DOC_ROOT_KEYS: array[0..1] of string = (
    'schemaVersion', 'template'
  );
var
  Root, SchemaNode, TemplateNode, TargetsNode, ProfilesNode: TYamlNode;
  VerInt, I: Integer;
  Entry: TYamlKeyValue;
begin
  Result := Default(TParsedTemplate);
  Result.TemplatePath := ATemplatePath;
  Result.SchemaVersion := 1;

  Root := ParseYamlText(AText, ATemplatePath);
  try
    if Root.Kind <> ynkMapping then
      RaiseManifestError(ATemplatePath, Root.Line, 'Template root must be a YAML mapping.');

    ValidateAllowedKeys(Root, TEMPLATE_DOC_ROOT_KEYS, 'template root', ATemplatePath);

    SchemaNode := Root.Find('schemaVersion');
    if SchemaNode <> nil then
    begin
      if (not SchemaNode.AsInteger(VerInt)) or (VerInt <> 1) then
        RaiseManifestError(ATemplatePath, SchemaNode.Line,
          Format('Unsupported schemaVersion ''%s'' (expected 1).', [SchemaNode.ScalarValue]));
      Result.SchemaVersion := VerInt;
    end;

    TemplateNode := Root.Find('template');
    if TemplateNode = nil then
      RaiseManifestError(ATemplatePath, Root.Line,
        'Template file must declare ''template'' as its top-level mapping key.');
    Result.RootLine := TemplateNode.Line;
    if TemplateNode.Kind <> ynkMapping then
      RaiseManifestError(ATemplatePath, Result.RootLine, '''template'' must be a YAML mapping.');

    ParseOverlayNode(TemplateNode, mkProgram, osTemplateRoot, 'template', ATemplatePath, Result.Base);

    TargetsNode := TemplateNode.Find('targets');
    if (TargetsNode <> nil) and (TargetsNode.Kind <> ynkNull) then
    begin
      if TargetsNode.Kind <> ynkMapping then
        RaiseManifestError(ATemplatePath, TargetsNode.Line,
          '''template.targets'' must be a mapping of target selectors.');

      SetLength(Result.Targets, TargetsNode.EntryCount);
      for I := 0 to TargetsNode.EntryCount - 1 do
      begin
        Entry := TargetsNode.GetEntry(I);
        ValidateTargetSelector(Entry.Key, Entry.KeyLine, 'template.targets', ATemplatePath);
        Result.Targets[I].Name := LowerCase(Trim(Entry.Key));
        Result.Targets[I].Line := Entry.KeyLine;
        ParseOverlayNode(Entry.Value, mkProgram, osTemplateSub,
          'template.targets.' + Entry.Key, ATemplatePath, Result.Targets[I].Overlay);
      end;
    end;

    ProfilesNode := TemplateNode.Find('profiles');
    if (ProfilesNode <> nil) and (ProfilesNode.Kind <> ynkNull) then
    begin
      if ProfilesNode.Kind <> ynkMapping then
        RaiseManifestError(ATemplatePath, ProfilesNode.Line,
          '''template.profiles'' must be a mapping of profile names.');

      SetLength(Result.Profiles, ProfilesNode.EntryCount);
      for I := 0 to ProfilesNode.EntryCount - 1 do
      begin
        Entry := ProfilesNode.GetEntry(I);
        Result.Profiles[I].Name := Entry.Key;
        Result.Profiles[I].Line := Entry.KeyLine;
        ParseOverlayNode(Entry.Value, mkProgram, osTemplateSub,
          'template.profiles.' + Entry.Key, ATemplatePath, Result.Profiles[I].Overlay);
      end;
    end;
  finally
    Root.Free;
  end;
end;

function LoadTemplateFile(const ATemplatePath: string): TParsedTemplate;
var
  FullPath: string;
begin
  FullPath := ExpandFileName(NormalizeNativeSeparators(Trim(ATemplatePath)));
  if not FileExists(FullPath) then
    raise ENikError.CreateFmt('Template file not found: %s', [FullPath]);
  Result := ParseTemplateText(ReadFileTextUtf8(FullPath), FullPath);
end;

end.
