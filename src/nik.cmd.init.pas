unit nik.cmd.init;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nik.manifest.types;

function ExecuteInitCommand(const AArgs: array of string): Integer;
procedure PrintInitHelp;

{ Pascal identifier used for the generated program or unit: a CamelCase form of the project name
  that is never a reserved word and, for libraries and packages, never a standard unit name. }
function DeriveStarterIdentifier(AKind: TManifestKind; const AProjectName: string): string;

implementation

uses
  fpjson,
  nik.types,
  nik.platform,
  nik.paths,
  nik.fs,
  nik.term,
  nik.sdk.manager,
  nik.manifest.io,
  nik.manifest.resolve,
  nik.pkg.types,
  nik.yaml;

procedure PrintInitHelp;
begin
  WriteLn(StyleBold('Initialize a new Free Pascal project (nik.yaml)'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik init [<DIR>] [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('ARGUMENTS:'));
  WriteLn('  [<DIR>]                Target project directory (defaults to current directory)');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('      --program          Initialize an executable application (default)');
  WriteLn('      --lib, --library   Initialize a native shared library (.dll / .so / .dylib)');
  WriteLn('      --pkg, --package   Initialize a reusable Object Pascal source unit package');
  WriteLn('      --name <NAME>      Project/package name (defaults to directory name)');
  WriteLn('      --fpc <VERSION>    Exact Free Pascal SDK version (e.g. 3.2.2, 3.3.1)');
  WriteLn('      --template <FILE>  Template YAML file (defaults to ~/.nikrun/template.yaml if present)');
  WriteLn('  -f, --force            Overwrite an existing nik.yaml file');
  WriteLn('      --json             Emit structured JSON initialization summary');
  WriteLn('  -h, --help             Show this help message');
  WriteLn;
  WriteLn(StyleBold('EXAMPLES:'));
  WriteLn('  nik init');
  WriteLn('  nik init my-app --fpc 3.2.2');
  WriteLn('  nik init my-lib --lib');
  WriteLn('  nik init my-units --pkg');
end;

function SplitOptEq(const AArg, AOptName: string; out AVal: string): Boolean;
var
  Prefix: string;
begin
  AVal := '';
  Prefix := AOptName + '=';
  if (Length(AArg) >= Length(Prefix)) and SameText(Copy(AArg, 1, Length(Prefix)), Prefix) then
  begin
    AVal := Copy(AArg, Length(Prefix) + 1, MaxInt);
    Exit(True);
  end;
  Result := False;
end;

function NextOptValue(const AArgs: array of string; var AIndex: Integer; const AOptName: string): string;
begin
  if AIndex + 1 > High(AArgs) then
    raise ENikError.CreateFmt('Option %s requires a value.', [AOptName]);
  Inc(AIndex);
  Result := AArgs[AIndex];
end;

function PreScanInitJsonFlag(const AArgs: array of string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(AArgs) to High(AArgs) do
    if AArgs[I] = '--json' then
      Exit(True);
end;

function SanitizePascalIdentifier(const ARawName: string): string;
var
  I: Integer;
  Ch: Char;
  CapNext: Boolean;
begin
  Result := '';
  CapNext := True;
  for I := 1 to Length(ARawName) do
  begin
    Ch := ARawName[I];
    if ((Ch >= 'A') and (Ch <= 'Z')) or ((Ch >= 'a') and (Ch <= 'z')) or
       ((Ch >= '0') and (Ch <= '9')) then
    begin
      if (Result = '') and (Ch >= '0') and (Ch <= '9') then
        Result := 'Project' + Ch
      else if CapNext and (Ch >= 'a') and (Ch <= 'z') then
        Result := Result + UpCase(Ch)
      else
        Result := Result + Ch;
      CapNext := False;
    end
    else
      CapNext := True;
  end;

  if Result = '' then
    Result := 'MainProject';
end;

function IsReservedPascalWord(const AIdent: string): Boolean;
const
  RESERVED: array[0..57] of string = (
    'and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const', 'constructor', 'destructor',
    'div', 'do', 'downto', 'else', 'end', 'except', 'exports', 'file', 'finalization', 'finally',
    'for', 'function', 'goto', 'if', 'implementation', 'in', 'inherited', 'initialization', 'inline',
    'interface', 'is', 'label', 'library', 'mod', 'nil', 'not', 'object', 'of', 'on', 'operator', 'or',
    'packed', 'procedure', 'program', 'property', 'raise', 'record', 'repeat', 'resourcestring', 'set',
    'shl', 'shr', 'string', 'then', 'threadvar', 'to', 'try', 'type');
var
  Lower: string;
  I: Integer;
begin
  Lower := LowerCase(AIdent);
  for I := Low(RESERVED) to High(RESERVED) do
    if RESERVED[I] = Lower then
      Exit(True);
  Result := (Lower = 'unit') or (Lower = 'uses') or (Lower = 'var') or (Lower = 'while') or
            (Lower = 'with') or (Lower = 'xor');
end;

function IsStandardUnitName(const AIdent: string): Boolean;
const
  UNITS: array[0..23] of string = (
    'system', 'sysutils', 'classes', 'types', 'math', 'strings', 'strutils', 'dateutils', 'variants',
    'contnrs', 'character', 'typinfo', 'process', 'fpjson', 'jsonparser', 'sockets', 'syncobjs',
    'windows', 'unix', 'baseunix', 'objpas', 'ctypes', 'getopts', 'inifiles');
var
  Lower: string;
  I: Integer;
begin
  Lower := LowerCase(AIdent);
  for I := Low(UNITS) to High(UNITS) do
    if UNITS[I] = Lower then
      Exit(True);
  Result := False;
end;

function DeriveStarterIdentifier(AKind: TManifestKind; const AProjectName: string): string;
begin
  Result := SanitizePascalIdentifier(AProjectName);
  // A reserved word cannot name a program or unit, and a library or package unit named like a
  // standard unit would hide it from every `uses` clause of the project.
  if IsReservedPascalWord(Result) or ((AKind <> mkProgram) and IsStandardUnitName(Result)) then
  begin
    if AKind = mkProgram then
      Result := Result + 'App'
    else
      Result := Result + 'Unit';
  end;
end;

function NeedsYamlQuoting(const S: string): Boolean;
var
  I: Integer;
  Ch: Char;
  Lower: string;
begin
  if S = '' then
    Exit(True);
  if (S[1] = ' ') or (S[Length(S)] = ' ') then
    Exit(True);

  Lower := LowerCase(S);
  if (Lower = 'true') or (Lower = 'false') or (Lower = 'null') or (Lower = '~') or
     (Lower = 'yes') or (Lower = 'no') or (Lower = 'on') or (Lower = 'off') then
    Exit(True);

  // Strings starting with YAML indicators or looking purely numeric/version-like where quoting avoids ambiguity
  if S[1] in ['''', '"', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '%', '@', '`', '-', '?', ':'] then
    Exit(True);

  for I := 1 to Length(S) do
  begin
    Ch := S[I];
    if (Ch < #32) or (Ch in [':', '#', '[', ']', '{', '}', ',']) then
      Exit(True);
  end;

  Result := False;
end;

function FormatYamlScalar(const S: string; AForceQuote: Boolean = False): string;
begin
  if (not AForceQuote) and (not NeedsYamlQuoting(S)) then
    Exit(S);
  Result := YamlQuoteDouble(S);
end;

function FormatYamlBool(B: Boolean): string;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

function FormatYamlInlineList(const AItems: TStringArray): string;
var
  I: Integer;
begin
  Result := '[';
  for I := 0 to High(AItems) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + FormatYamlScalar(AItems[I]);
  end;
  Result := Result + ']';
end;

function FormatRawInlineList(const AItems: TStringArray): string;
var
  I: Integer;
begin
  Result := '[';
  for I := 0 to High(AItems) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + AItems[I];
  end;
  Result := Result + ']';
end;

function HasAnyWarningsOverlay(const AWarn: TWarningsOverlay): Boolean;
begin
  Result := AWarn.HasAsErrors or AWarn.HasHints or AWarn.HasNotes or AWarn.HasSuppress;
end;

function HasAnyBuildOverlay(const ABuild: TBuildOverlay): Boolean;
begin
  Result :=
    ABuild.HasMode or ABuild.HasLongStrings or ABuild.HasCOperators or ABuild.HasModeSwitches or
    ABuild.HasSubsystem or ABuild.HasPic or ABuild.HasCpuType or ABuild.HasFpuType or ABuild.HasStackSize or
    ABuild.HasUnitPaths or ABuild.HasIncludePaths or ABuild.HasLibraryPaths or
    ABuild.HasObjectPaths or ABuild.HasResourcePaths or
    ABuild.HasDefines or ABuild.HasUndefines or
    ABuild.HasDebugInfo or ABuild.HasHeaptrc or ABuild.HasAssertions or ABuild.HasChecks or
    HasAnyWarningsOverlay(ABuild.Warnings) or
    ABuild.HasOptimization or ABuild.HasSmartLink or ABuild.HasStripSymbols or
    ABuild.HasLinkLibraries or ABuild.HasLinkerArgs or ABuild.HasFpcArgs;
end;

procedure EmitBuildSectionLines(ALines: TStringList; const AIndent: string;
  const ABuild: TBuildOverlay; AForceDefaultModeAndSrc: Boolean);
var
  SubIndent, WarnIndent, SubStr, PicStr: string;
begin
  if (not AForceDefaultModeAndSrc) and (not HasAnyBuildOverlay(ABuild)) then
    Exit;

  ALines.Add(AIndent + 'build:');
  SubIndent := AIndent + '  ';

  if ABuild.HasMode then
    ALines.Add(SubIndent + 'mode: ' + FormatYamlScalar(ABuild.Mode))
  else if AForceDefaultModeAndSrc then
    ALines.Add(SubIndent + 'mode: objfpc');

  if ABuild.HasLongStrings then
    ALines.Add(SubIndent + 'longStrings: ' + FormatYamlBool(ABuild.LongStrings));
  if ABuild.HasCOperators then
    ALines.Add(SubIndent + 'cOperators: ' + FormatYamlBool(ABuild.COperators));
  if ABuild.HasModeSwitches then
    ALines.Add(SubIndent + 'modeSwitches: ' + FormatYamlInlineList(ABuild.ModeSwitches));

  if ABuild.HasSubsystem then
  begin
    case ABuild.Subsystem of
      asConsole: SubStr := 'console';
      asGui:     SubStr := 'gui';
    else
      raise ENikError.CreateFmt('Unsupported TAppSubsystem ordinal: %d', [Ord(ABuild.Subsystem)]);
    end;
    ALines.Add(SubIndent + 'subsystem: ' + SubStr);
  end;

  if ABuild.HasPic then
  begin
    case ABuild.Pic of
      pmAuto: PicStr := 'auto';
      pmOn:   PicStr := 'true';
      pmOff:  PicStr := 'false';
    else
      raise ENikError.CreateFmt('Unsupported TPicMode ordinal: %d', [Ord(ABuild.Pic)]);
    end;
    ALines.Add(SubIndent + 'pic: ' + PicStr);
  end;

  if ABuild.HasCpuType then
    ALines.Add(SubIndent + 'cpuType: ' + FormatYamlScalar(ABuild.CpuType));
  if ABuild.HasFpuType then
    ALines.Add(SubIndent + 'fpuType: ' + FormatYamlScalar(ABuild.FpuType));
  if ABuild.HasStackSize then
    ALines.Add(SubIndent + 'stackSize: ' + IntToStr(ABuild.StackSize));

  if ABuild.HasUnitPaths then
    ALines.Add(SubIndent + 'unitPaths: ' + FormatYamlInlineList(ABuild.UnitPaths))
  else if AForceDefaultModeAndSrc then
    ALines.Add(SubIndent + 'unitPaths: [src]');

  if ABuild.HasIncludePaths then
    ALines.Add(SubIndent + 'includePaths: ' + FormatYamlInlineList(ABuild.IncludePaths));
  if ABuild.HasLibraryPaths then
    ALines.Add(SubIndent + 'libraryPaths: ' + FormatYamlInlineList(ABuild.LibraryPaths));
  if ABuild.HasObjectPaths then
    ALines.Add(SubIndent + 'objectPaths: ' + FormatYamlInlineList(ABuild.ObjectPaths));
  if ABuild.HasResourcePaths then
    ALines.Add(SubIndent + 'resourcePaths: ' + FormatYamlInlineList(ABuild.ResourcePaths));

  if ABuild.HasDefines then
    ALines.Add(SubIndent + 'defines: ' + FormatYamlInlineList(ABuild.Defines));
  if ABuild.HasUndefines then
    ALines.Add(SubIndent + 'undefines: ' + FormatYamlInlineList(ABuild.Undefines));

  if ABuild.HasDebugInfo then
    ALines.Add(SubIndent + 'debugInfo: ' + FormatYamlScalar(ABuild.DebugInfo));
  if ABuild.HasHeaptrc then
    ALines.Add(SubIndent + 'heaptrc: ' + FormatYamlBool(ABuild.Heaptrc));
  if ABuild.HasAssertions then
    ALines.Add(SubIndent + 'assertions: ' + FormatYamlBool(ABuild.Assertions));
  if ABuild.HasChecks then
    ALines.Add(SubIndent + 'checks: ' + FormatYamlInlineList(ABuild.Checks));

  if HasAnyWarningsOverlay(ABuild.Warnings) then
  begin
    ALines.Add(SubIndent + 'warnings:');
    WarnIndent := SubIndent + '  ';
    if ABuild.Warnings.HasAsErrors then
      ALines.Add(WarnIndent + 'asErrors: ' + FormatYamlBool(ABuild.Warnings.AsErrors));
    if ABuild.Warnings.HasHints then
      ALines.Add(WarnIndent + 'hints: ' + FormatYamlBool(ABuild.Warnings.Hints));
    if ABuild.Warnings.HasNotes then
      ALines.Add(WarnIndent + 'notes: ' + FormatYamlBool(ABuild.Warnings.Notes));
    if ABuild.Warnings.HasSuppress then
      ALines.Add(WarnIndent + 'suppress: ' + FormatRawInlineList(ABuild.Warnings.Suppress));
  end;

  if ABuild.HasOptimization then
    ALines.Add(SubIndent + 'optimization: ' + IntToStr(ABuild.Optimization));
  if ABuild.HasSmartLink then
    ALines.Add(SubIndent + 'smartLink: ' + FormatYamlBool(ABuild.SmartLink));
  if ABuild.HasStripSymbols then
    ALines.Add(SubIndent + 'stripSymbols: ' + FormatYamlBool(ABuild.StripSymbols));
  if ABuild.HasLinkLibraries then
    ALines.Add(SubIndent + 'linkLibraries: ' + FormatYamlInlineList(ABuild.LinkLibraries));
  if ABuild.HasLinkerArgs then
    ALines.Add(SubIndent + 'linkerArgs: ' + FormatYamlInlineList(ABuild.LinkerArgs));
  if ABuild.HasFpcArgs then
    ALines.Add(SubIndent + 'fpcArgs: ' + FormatYamlInlineList(ABuild.FpcArgs));
end;

procedure EmitDependenciesSectionLines(ALines: TStringList; const AIndent: string;
  const ADeps: TDependencySpecArray);
var
  I: Integer;
  DepIndent, SubIndent, CompactVal: string;
  HasExtraFields: Boolean;
begin
  if Length(ADeps) = 0 then
    Exit;

  ALines.Add(AIndent + 'dependencies:');
  DepIndent := AIndent + '  ';
  SubIndent := DepIndent + '  ';
  for I := 0 to High(ADeps) do
  begin
    HasExtraFields := (ADeps[I].Subpath <> '') or
                      (ADeps[I].Sha256 <> '') or
                      (Length(ADeps[I].UnitPaths) > 0) or
                      (Length(ADeps[I].IncludePaths) > 0) or
                      ((ADeps[I].Path <> '') and (ADeps[I].Url <> ''));

    CompactVal := '';
    if not HasExtraFields then
    begin
      case ADeps[I].Kind of
        dskLocalPath, dskLocalArchive:
          if HasExplicitLocalPathPrefix(ADeps[I].Path) then
            CompactVal := ADeps[I].Path;
        dskArchiveUrl:
          CompactVal := ADeps[I].Url;
        dskGitRepo:
          if ADeps[I].Rev <> '' then
            CompactVal := ADeps[I].Url + '@' + ADeps[I].Rev
          else
            CompactVal := ADeps[I].Url + '@' + ADeps[I].VersionSpec;
      else
        CompactVal := '';
      end;
    end;

    if CompactVal <> '' then
      ALines.Add(DepIndent + FormatYamlScalar(ADeps[I].Name) + ': ' + FormatYamlScalar(CompactVal))
    else
    begin
      ALines.Add(DepIndent + FormatYamlScalar(ADeps[I].Name) + ':');
      if ADeps[I].Url <> '' then
        ALines.Add(SubIndent + 'url: ' + FormatYamlScalar(ADeps[I].Url));
      if ADeps[I].Path <> '' then
        ALines.Add(SubIndent + 'path: ' + FormatYamlScalar(ADeps[I].Path));
      if ADeps[I].VersionSpec <> '' then
        ALines.Add(SubIndent + 'version: ' + FormatYamlScalar(ADeps[I].VersionSpec, True));
      if ADeps[I].Rev <> '' then
        ALines.Add(SubIndent + 'rev: ' + FormatYamlScalar(ADeps[I].Rev));
      if ADeps[I].Subpath <> '' then
        ALines.Add(SubIndent + 'subpath: ' + FormatYamlScalar(ADeps[I].Subpath));
      if ADeps[I].Sha256 <> '' then
        ALines.Add(SubIndent + 'sha256: ' + FormatYamlScalar(ADeps[I].Sha256));
      if Length(ADeps[I].UnitPaths) > 0 then
        ALines.Add(SubIndent + 'unitPaths: ' + FormatYamlInlineList(ADeps[I].UnitPaths));
      if Length(ADeps[I].IncludePaths) > 0 then
        ALines.Add(SubIndent + 'includePaths: ' + FormatYamlInlineList(ADeps[I].IncludePaths));
    end;
  end;
end;

procedure EmitSubOverlayLines(ALines: TStringList; const AIndent: string;
  const AOverlay: TManifestOverlay);
var
  HasTc: Boolean;
begin
  if AOverlay.HasVersion then
    ALines.Add(AIndent + 'version: ' + FormatYamlScalar(AOverlay.Version));

  HasTc := AOverlay.Toolchain.HasFpcVersion or AOverlay.Toolchain.HasTarget;
  if HasTc then
  begin
    ALines.Add(AIndent + 'toolchain:');
    if AOverlay.Toolchain.HasFpcVersion then
      ALines.Add(AIndent + '  fpc: ' + FormatYamlScalar(AOverlay.Toolchain.FpcVersion));
    if AOverlay.Toolchain.HasTarget then
      ALines.Add(AIndent + '  target: ' + FormatYamlScalar(AOverlay.Toolchain.Target));
  end;

  EmitBuildSectionLines(ALines, AIndent, AOverlay.Build, False);
  if AOverlay.HasDependencies then
    EmitDependenciesSectionLines(ALines, AIndent, AOverlay.Dependencies);
end;

function RenderInitializedManifestYaml(AKind: TManifestKind;
  const AProjectName, AEntryRelPath, AFpcVersion: string;
  AHasTemplate: Boolean; const ATemplate: TParsedTemplate): string;
var
  Lines: TStringList;
  RootKey, ProjVer: string;
  Base: TManifestOverlay;
  I: Integer;
begin
  RootKey := ManifestKindToString(AKind);
  if AHasTemplate then
    Base := ATemplate.Base
  else
    Base := Default(TManifestOverlay);

  if Base.HasVersion and (Trim(Base.Version) <> '') then
    ProjVer := Base.Version
  else
    ProjVer := '0.1.0';

  Lines := TStringList.Create;
  try
    Lines.Add('schemaVersion: 1');
    Lines.Add('');
    Lines.Add(RootKey + ':');
    Lines.Add('  name: ' + FormatYamlScalar(AProjectName));
    Lines.Add('  version: ' + FormatYamlScalar(ProjVer));

    if Base.HasDescription and (Trim(Base.Description) <> '') then
      Lines.Add('  description: ' + FormatYamlScalar(Base.Description, True));
    if Base.HasLicense and (Trim(Base.License) <> '') then
      Lines.Add('  license: ' + FormatYamlScalar(Base.License));
    if Base.HasRepository and (Trim(Base.Repository) <> '') then
      Lines.Add('  repository: ' + FormatYamlScalar(Base.Repository, True));
    if Base.HasAuthors and (Length(Base.Authors) > 0) then
      Lines.Add('  authors: ' + FormatYamlInlineList(Base.Authors));

    if AKind <> mkPackage then
      Lines.Add('  entry: ' + FormatYamlScalar(AEntryRelPath));

    Lines.Add('');
    Lines.Add('  toolchain:');
    Lines.Add('    fpc: ' + FormatYamlScalar(AFpcVersion));
    if Base.Toolchain.HasTarget and (Trim(Base.Toolchain.Target) <> '') and
       (not SameText(Base.Toolchain.Target, 'native')) then
      Lines.Add('    target: ' + FormatYamlScalar(Base.Toolchain.Target));

    Lines.Add('');
    EmitBuildSectionLines(Lines, '  ', Base.Build, True);

    if Base.HasDependencies and (Length(Base.Dependencies) > 0) then
    begin
      Lines.Add('');
      EmitDependenciesSectionLines(Lines, '  ', Base.Dependencies);
    end;

    if AHasTemplate and (Length(ATemplate.Targets) > 0) then
    begin
      Lines.Add('');
      Lines.Add('  targets:');
      for I := 0 to High(ATemplate.Targets) do
      begin
        Lines.Add('    ' + FormatYamlScalar(ATemplate.Targets[I].Name) + ':');
        EmitSubOverlayLines(Lines, '      ', ATemplate.Targets[I].Overlay);
      end;
    end;

    if AHasTemplate and (Length(ATemplate.Profiles) > 0) then
    begin
      Lines.Add('');
      Lines.Add('  profiles:');
      for I := 0 to High(ATemplate.Profiles) do
      begin
        Lines.Add('    ' + FormatYamlScalar(ATemplate.Profiles[I].Name) + ':');
        EmitSubOverlayLines(Lines, '      ', ATemplate.Profiles[I].Overlay);
      end;
    end;

    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function RenderStarterPascalSource(AKind: TManifestKind;
  const APasIdent, AProjectName, AMode: string): string;
var
  ModeDir: string;
begin
  if SameText(AMode, 'delphi') then
    ModeDir := '{$mode delphi}{$H+}'
  else if SameText(AMode, 'delphiunicode') then
    ModeDir := '{$mode delphiunicode}'
  else
    ModeDir := '{$mode objfpc}{$H+}';

  case AKind of
    mkProgram:
      Result :=
        'program ' + APasIdent + ';' + LineEnding +
        LineEnding +
        ModeDir + LineEnding +
        LineEnding +
        'begin' + LineEnding +
        '  WriteLn(''Hello from ' + StringReplace(AProjectName, '''', '''''', [rfReplaceAll]) + '!'');' + LineEnding +
        'end.' + LineEnding;
    mkLibrary:
      Result :=
        'library ' + APasIdent + ';' + LineEnding +
        LineEnding +
        ModeDir + LineEnding +
        LineEnding +
        'function AddInts(A, B: Int32): Int32; cdecl;' + LineEnding +
        'begin' + LineEnding +
        '  Result := A + B;' + LineEnding +
        'end;' + LineEnding +
        LineEnding +
        'exports' + LineEnding +
        '  AddInts;' + LineEnding +
        LineEnding +
        'begin' + LineEnding +
        'end.' + LineEnding;
    mkPackage:
      Result :=
        'unit ' + APasIdent + ';' + LineEnding +
        LineEnding +
        ModeDir + LineEnding +
        LineEnding +
        'interface' + LineEnding +
        LineEnding +
        'function Greeting: string;' + LineEnding +
        LineEnding +
        'implementation' + LineEnding +
        LineEnding +
        'function Greeting: string;' + LineEnding +
        'begin' + LineEnding +
        '  Result := ''Hello from ' + StringReplace(AProjectName, '''', '''''', [rfReplaceAll]) + ''';' + LineEnding +
        'end;' + LineEnding +
        LineEnding +
        'end.' + LineEnding;
  else
    raise ENikError.CreateFmt('Unsupported TManifestKind ordinal: %d', [Ord(AKind)]);
  end;
end;

procedure PrintInitErrorJson(const AMsg: string);
var
  Root: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('success', False);
    Root.Add('error', AMsg);
    WriteJson(Root);
  finally
    Root.Free;
  end;
end;

function ExecuteInitCommand(const AArgs: array of string): Integer;
var
  I, KindCount: Integer;
  Arg, Val, DirArg, NameOverride, FpcOverride, TemplateOverride: string;
  IsJson, Force, HasTemplate: Boolean;
  Kind: TManifestKind;
  TargetDir, ProjectName, PasIdent, ExistingYaml, ExistingYml, ManifestPath: string;
  TemplatePath, EffFpcVersion, EffMode, EntryRel, StarterPath, GitIgnorePath, YamlText: string;
  Template: TParsedTemplate;
  Validated: TParsedManifest;
  CreatedFiles: array of string;
  Root: TJSONObject;
  CreatedArr: TJSONArray;

  procedure RecordCreatedFile(const AFilePath: string);
  var
    N: Integer;
  begin
    N := Length(CreatedFiles);
    SetLength(CreatedFiles, N + 1);
    CreatedFiles[N] := AFilePath;
  end;

begin
  IsJson := PreScanInitJsonFlag(AArgs);
  Force := False;
  Kind := mkProgram;
  KindCount := 0;
  DirArg := '';
  NameOverride := '';
  FpcOverride := '';
  TemplateOverride := '';
  CreatedFiles := nil;

  try
    I := Low(AArgs);
    while I <= High(AArgs) do
    begin
      Arg := AArgs[I];
      if (Arg = '-h') or (Arg = '--help') then
      begin
        PrintInitHelp;
        Exit(0);
      end
      else if (Arg = '--program') or (Arg = '--bin') then
      begin
        Kind := mkProgram;
        Inc(KindCount);
      end
      else if (Arg = '--lib') or (Arg = '--library') then
      begin
        Kind := mkLibrary;
        Inc(KindCount);
      end
      else if (Arg = '--pkg') or (Arg = '--package') then
      begin
        Kind := mkPackage;
        Inc(KindCount);
      end
      else if Arg = '--name' then
        NameOverride := NextOptValue(AArgs, I, '--name')
      else if SplitOptEq(Arg, '--name', Val) then
        NameOverride := Val
      else if Arg = '--fpc' then
        FpcOverride := NextOptValue(AArgs, I, '--fpc')
      else if SplitOptEq(Arg, '--fpc', Val) then
        FpcOverride := Val
      else if Arg = '--template' then
        TemplateOverride := NextOptValue(AArgs, I, '--template')
      else if SplitOptEq(Arg, '--template', Val) then
        TemplateOverride := Val
      else if (Arg = '-f') or (Arg = '--force') then
        Force := True
      else if Arg = '--json' then
        IsJson := True
      else if (Length(Arg) > 0) and (Arg[1] = '-') then
        raise ENikError.CreateFmt('Unknown option for ''nik init'': %s', [Arg])
      else if DirArg = '' then
        DirArg := Arg
      else
        raise ENikError.CreateFmt('Unexpected extra argument for ''nik init'': %s', [Arg]);
      Inc(I);
    end;

    if KindCount > 1 then
      raise ENikError.Create('Cannot combine --program, --lib, and --pkg in a single ''nik init'' command.');

    if Trim(FpcOverride) <> '' then
    begin
      FpcOverride := Trim(FpcOverride);
      if not IsExactFpcVersion(FpcOverride) then
        raise ENikError.CreateFmt(
          'Invalid --fpc version ''%s'' (expected exact Free Pascal version such as ''3.2.2'' or ''3.3.1'').',
          [FpcOverride]);
    end;

    if Trim(DirArg) <> '' then
      TargetDir := ExcludeTrailingPathDelimiter(ExpandFileName(NormalizeNativeSeparators(Trim(DirArg))))
    else
      TargetDir := ExcludeTrailingPathDelimiter(ExpandFileName(GetCurrentDir));

    ExistingYaml := JoinPath(TargetDir, 'nik.yaml');
    ExistingYml := JoinPath(TargetDir, 'nik.yml');
    if (not Force) and (FileExists(ExistingYaml) or FileExists(ExistingYml)) then
      raise ENikError.CreateFmt(
        'Project manifest already exists in %s (pass --force to overwrite nik.yaml).',
        [TargetDir]);

    // Decide and check the project name before anything is detected, read or created.
    if Trim(NameOverride) <> '' then
      ProjectName := Trim(NameOverride)
    else
      ProjectName := ExtractFileName(TargetDir);
    if Trim(ProjectName) = '' then
      ProjectName := 'my-app';
    if not IsValidManifestName(Kind, ProjectName) then
      raise ENikError.CreateFmt(
        'Invalid project name ''%s'': use a plain name without path separators, ''..'', '':'' or wildcard characters (pass --name <NAME> to choose another).',
        [ProjectName]);

    // Load optional template (~/.nikrun/template.yaml or explicit --template)
    HasTemplate := False;
    Template := Default(TParsedTemplate);
    TemplatePath := '';
    if Trim(TemplateOverride) <> '' then
    begin
      Template := LoadTemplateFile(TemplateOverride);
      TemplatePath := Template.TemplatePath;
      HasTemplate := True;
    end
    else if FileExists(GetNikrunTemplateFile) then
    begin
      Template := LoadTemplateFile(GetNikrunTemplateFile);
      TemplatePath := Template.TemplatePath;
      HasTemplate := True;
    end;

    // Resolve concrete FPC version for nik.yaml
    if FpcOverride <> '' then
      EffFpcVersion := FpcOverride
    else if HasTemplate and Template.Base.Toolchain.HasFpcVersion then
      EffFpcVersion := Template.Base.Toolchain.FpcVersion
    else if not TryDetectInstalledHostVersion(EffFpcVersion) then
      raise ENikError.CreateFmt(
        'Cannot determine Free Pascal version for nik.yaml (no SDK installed in %s and no toolchain.fpc in %s). Run ''nik sdk install 3.2.2'' first or pass ''--fpc <version>''.',
        [GetNikrunSdksDir, GetNikrunTemplateFile]);

    PasIdent := DeriveStarterIdentifier(Kind, ProjectName);
    case Kind of
      mkProgram:
        begin
          EntryRel := 'src/main.pas';
          StarterPath := JoinPath(JoinPath(TargetDir, 'src'), 'main.pas');
        end;
      mkLibrary:
        begin
          EntryRel := 'src/' + PasIdent + '.pas';
          StarterPath := JoinPath(JoinPath(TargetDir, 'src'), PasIdent + '.pas');
        end;
      mkPackage:
        begin
          EntryRel := '';
          StarterPath := JoinPath(JoinPath(TargetDir, 'src'), PasIdent + '.pas');
        end;
    else
      raise ENikError.CreateFmt('Unsupported TManifestKind ordinal: %d', [Ord(Kind)]);
    end;

    ManifestPath := ExistingYaml;
    YamlText := RenderInitializedManifestYaml(Kind, ProjectName, EntryRel, EffFpcVersion, HasTemplate, Template);

    // Self-verify generated nik.yaml against strict manifest schema + resolver before writing
    Validated := ParseManifestText(YamlText, ManifestPath, TargetDir);
    ResolveManifestConfig(Validated, 'debug', GetHostCpu, GetHostOs, False, Kind <> mkPackage);

    // Everything is validated: only now touch the file system.
    EnsureDirExists(TargetDir);

    if HasTemplate and Template.Base.Build.HasMode then
      EffMode := Template.Base.Build.Mode
    else
      EffMode := 'objfpc';

    if not FileExists(StarterPath) then
    begin
      EnsureDirExists(ExtractFileDir(StarterPath));
      WriteFileTextUtf8(StarterPath, RenderStarterPascalSource(Kind, PasIdent, ProjectName, EffMode));
      RecordCreatedFile(StarterPath);
    end;

    GitIgnorePath := JoinPath(TargetDir, '.gitignore');
    if not FileExists(GitIgnorePath) then
    begin
      WriteFileTextUtf8(GitIgnorePath, '.nik/' + LineEnding + 'bin/' + LineEnding);
      RecordCreatedFile(GitIgnorePath);
    end;

    WriteFileTextUtf8(ManifestPath, YamlText);
    RecordCreatedFile(ManifestPath);

    if IsJson then
    begin
      Root := TJSONObject.Create;
      CreatedArr := TJSONArray.Create;
      try
        Root.Add('success', True);
        Root.Add('projectDir', TargetDir);
        Root.Add('manifestPath', ManifestPath);
        Root.Add('kind', ManifestKindToString(Kind));
        Root.Add('name', ProjectName);
        Root.Add('fpcVersion', EffFpcVersion);
        Root.Add('usedTemplate', HasTemplate);
        if HasTemplate then
          Root.Add('templatePath', TemplatePath)
        else
          Root.Add('templatePath', TJSONNull.Create);
        for I := 0 to High(CreatedFiles) do
          CreatedArr.Add(CreatedFiles[I]);
        Root.Add('createdFiles', CreatedArr);
        WriteJson(Root);
      finally
        Root.Free;
      end;
      Exit(0);
    end;

    WriteSuccess(Format('Initialized %s project ''%s'' (FPC %s) at %s',
      [ManifestKindToString(Kind), ProjectName, EffFpcVersion, ManifestPath]));
    if HasTemplate then
      WriteInfo('Applied template: ' + TemplatePath);
    Result := 0;
  except
    on E: ENikError do
    begin
      if IsJson then
      begin
        PrintInitErrorJson(E.Message);
        Exit(E.ExitCode);
      end;
      raise;
    end;
    on E: Exception do
    begin
      if IsJson then
      begin
        PrintInitErrorJson(E.Message);
        Exit(1);
      end;
      raise;
    end;
  end;
end;

end.
