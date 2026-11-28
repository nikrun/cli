unit nik.manifest.types;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, nik.types;

type
  TManifestKind = (mkProgram, mkLibrary, mkPackage);
  TPicMode = (pmAuto, pmOn, pmOff);
  TAppSubsystem = (asConsole, asGui);
  TDependencySourceKind = (dskLocalPath, dskLocalArchive, dskGitRepo, dskArchiveUrl);

  TDependencySpec = record
    Name: string;
    Kind: TDependencySourceKind;
    Path: string;
    Url: string;
    VersionSpec: string;
    Rev: string;
    Subpath: string;
    Sha256: string;
    UnitPaths: TStringArray;
    IncludePaths: TStringArray;
    DefinedLine: Integer;
  end;
  TDependencySpecArray = array of TDependencySpec;

  TToolchainOverlay = record
    HasFpcVersion: Boolean;
    FpcVersion: string;
    HasTarget: Boolean;
    Target: string;
  end;

  TWarningsOverlay = record
    HasAsErrors: Boolean;
    AsErrors: Boolean;
    HasHints: Boolean;
    Hints: Boolean;
    HasNotes: Boolean;
    Notes: Boolean;
    HasSuppress: Boolean;
    Suppress: TStringArray;
  end;

  TBuildOverlay = record
    // Dialect & syntax
    HasMode: Boolean;
    Mode: string;
    HasLongStrings: Boolean;
    LongStrings: Boolean;
    HasCOperators: Boolean;
    COperators: Boolean;
    HasModeSwitches: Boolean;
    ModeSwitches: TStringArray;

    // Subsystem & code generation
    HasSubsystem: Boolean;
    Subsystem: TAppSubsystem;
    HasPic: Boolean;
    Pic: TPicMode;
    HasCpuType: Boolean;
    CpuType: string;
    HasFpuType: Boolean;
    FpuType: string;
    HasStackSize: Boolean;
    StackSize: Integer;

    // Search paths & resources
    HasUnitPaths: Boolean;
    UnitPaths: TStringArray;
    HasIncludePaths: Boolean;
    IncludePaths: TStringArray;
    HasLibraryPaths: Boolean;
    LibraryPaths: TStringArray;
    HasObjectPaths: Boolean;
    ObjectPaths: TStringArray;
    HasResourcePaths: Boolean;
    ResourcePaths: TStringArray;

    // Conditional compilation
    HasDefines: Boolean;
    Defines: TStringArray;
    HasUndefines: Boolean;
    Undefines: TStringArray;

    // Debugging, assertions & runtime checks
    HasDebugInfo: Boolean;
    DebugInfo: string;
    HasHeaptrc: Boolean;
    Heaptrc: Boolean;
    HasAssertions: Boolean;
    Assertions: Boolean;
    HasChecks: Boolean;
    Checks: TStringArray;

    // Warnings & diagnostics
    Warnings: TWarningsOverlay;

    // Optimization & linking
    HasOptimization: Boolean;
    Optimization: Integer;
    HasSmartLink: Boolean;
    SmartLink: Boolean;
    HasStripSymbols: Boolean;
    StripSymbols: Boolean;
    HasLinkLibraries: Boolean;
    LinkLibraries: TStringArray;
    HasLinkerArgs: Boolean;
    LinkerArgs: TStringArray;

    // Escape hatch
    HasFpcArgs: Boolean;
    FpcArgs: TStringArray;
  end;

  // 'windows' section: VERSIONINFO strings, application manifest switches, icon and extra resources
  TWindowsInfoOverlay = record
    HasCompany: Boolean;
    Company: string;
    HasProduct: Boolean;
    Product: string;
    HasDescription: Boolean;
    Description: string;
    HasCopyright: Boolean;
    Copyright: string;
    HasComments: Boolean;
    Comments: string;
    HasInternalName: Boolean;
    InternalName: string;
    HasOriginalFilename: Boolean;
    OriginalFilename: string;
    HasFlags: Boolean;
    Flags: TStringArray;
  end;

  TWindowsManifestOverlay = record
    Present: Boolean;
    HasExecutionLevel: Boolean;
    ExecutionLevel: string;
    HasDpiAwareness: Boolean;
    DpiAwareness: string;
    HasLongPaths: Boolean;
    LongPaths: Boolean;
    HasUtf8: Boolean;
    Utf8: Boolean;
    HasSupportedOS: Boolean;
    SupportedOS: TStringArray;
    HasManifestFile: Boolean;
    ManifestFile: string;
  end;

  TWindowsOverlay = record
    Present: Boolean;
    HasIcon: Boolean;
    Icon: string;
    HasVersion: Boolean;
    Version: string;
    Info: TWindowsInfoOverlay;
    Manifest: TWindowsManifestOverlay;
    HasResources: Boolean;
    Resources: TStringArray;
  end;

  TManifestOverlay = record
    // Artifact metadata & entry/output
    HasName: Boolean;
    Name: string;
    HasVersion: Boolean;
    Version: string;
    HasDescription: Boolean;
    Description: string;
    HasLicense: Boolean;
    License: string;
    HasRepository: Boolean;
    Repository: string;
    HasAuthors: Boolean;
    Authors: TStringArray;
    HasEntry: Boolean;
    Entry: string;
    EntryLine: Integer;
    HasOutput: Boolean;
    Output: string;
    OutputLine: Integer;

    Toolchain: TToolchainOverlay;
    Build: TBuildOverlay;
    Windows: TWindowsOverlay;

    HasDependencies: Boolean;
    Dependencies: TDependencySpecArray;
  end;

  TNamedOverlay = record
    Name: string;
    Line: Integer;
    Overlay: TManifestOverlay;
  end;
  TNamedOverlayArray = array of TNamedOverlay;

  TParsedManifest = record
    ManifestPath: string;
    ProjectDir: string;
    SchemaVersion: Integer;
    Kind: TManifestKind;
    RootLine: Integer;

    Base: TManifestOverlay;
    HasTest: Boolean;
    TestLine: Integer;
    Test: TManifestOverlay;
    Targets: TNamedOverlayArray;
    Profiles: TNamedOverlayArray;
  end;

  TParsedTemplate = record
    TemplatePath: string;
    SchemaVersion: Integer;
    RootLine: Integer;
    Base: TManifestOverlay;
    Targets: TNamedOverlayArray;
    Profiles: TNamedOverlayArray;
  end;

  TWarningsConfig = record
    AsErrors: Boolean;
    HasHints: Boolean;
    Hints: Boolean;
    Notes: Boolean;
    Suppress: TStringArray;
  end;

  // Effective 'windows' section after all overlays; empty strings mean "not set" (defaults are
  // derived by the resource generator from the rest of the resolved manifest).
  TResolvedWindows = record
    Present: Boolean;
    Icon: string;
    Version: string;
    Company: string;
    Product: string;
    Description: string;
    Copyright: string;
    Comments: string;
    InternalName: string;
    OriginalFilename: string;
    Flags: TStringArray;
    HasManifest: Boolean;
    ExecutionLevel: string;
    DpiAwareness: string;
    HasLongPaths: Boolean;
    LongPaths: Boolean;
    HasUtf8: Boolean;
    Utf8: Boolean;
    SupportedOS: TStringArray;
    ManifestFile: string;
    Resources: TStringArray;
  end;

  TResolvedManifest = record
    ManifestPath: string;
    ProjectDir: string;
    Kind: TManifestKind;
    ForTest: Boolean;
    ProfileName: string;

    ProjectName: string;
    ProjectVersion: string;
    Description: string;
    License: string;
    Repository: string;
    Authors: TStringArray;
    Entry: string;
    Output: string;

    FpcSpec: string;
    TargetSpec: string;

    Mode: string;
    LongStrings: Boolean;
    HasCOperators: Boolean;
    COperators: Boolean;
    ModeSwitches: TStringArray;

    HasSubsystem: Boolean;
    Subsystem: TAppSubsystem;
    Pic: TPicMode;
    CpuType: string;
    FpuType: string;
    StackSize: Integer;

    UnitPaths: TStringArray;
    IncludePaths: TStringArray;
    LibraryPaths: TStringArray;
    ObjectPaths: TStringArray;
    ResourcePaths: TStringArray;

    Defines: TStringArray;
    Undefines: TStringArray;

    DebugInfo: string;
    Heaptrc: Boolean;
    HasAssertions: Boolean;
    Assertions: Boolean;
    HasExplicitChecks: Boolean;
    Checks: TStringArray;

    Warnings: TWarningsConfig;

    HasOptimization: Boolean;
    Optimization: Integer;
    HasSmartLink: Boolean;
    SmartLink: Boolean;
    HasStripSymbols: Boolean;
    StripSymbols: Boolean;
    LinkLibraries: TStringArray;
    LinkerArgs: TStringArray;
    FpcArgs: TStringArray;

    Windows: TResolvedWindows;

    Dependencies: TDependencySpecArray;
  end;

function ManifestKindToString(AKind: TManifestKind): string;
procedure RaiseManifestError(const APath: string; ALine: Integer; const AMsg: string);

type
  { Numeric Windows file/product version (FILEVERSION major.minor.patch.build, each 0..65535). }
  TWindowsVersion = array[0..3] of Word;

{ Parses 'A.B.C' or 'A.B.C.D' where every part is a number from 0 to 65535. }
function TryParseWindowsVersion(const AText: string; out AVersion: TWindowsVersion): Boolean;

{ Derives the numeric version from a version string such as '1.4.2' (-> 1.4.2.0) or a CI tag such as
  'v0.2.0-build.16-channel.stable' (-> 0.2.0.16). Returns False (and 0.0.0.0) when no
  MAJOR.MINOR.PATCH prefix can be read. }
function TryDeriveWindowsVersion(const AVersionText: string; out AVersion: TWindowsVersion): Boolean;

{ A program or library name becomes a file name (default output bin/<name>), so it must be a
  plain name. A package name may be a relative path like owner/pkg but must not leave its base. }
function IsValidManifestName(AKind: TManifestKind; const AName: string): Boolean;

implementation

uses
  nik.paths;

function ManifestKindToString(AKind: TManifestKind): string;
begin
  case AKind of
    mkProgram: Result := 'program';
    mkLibrary: Result := 'library';
    mkPackage: Result := 'package';
  else
    raise ENikError.CreateFmt('Unsupported TManifestKind ordinal: %d', [Ord(AKind)]);
  end;
end;

function TryParseWindowsVersion(const AText: string; out AVersion: TWindowsVersion): Boolean;
var
  I, Part: Integer;
  Value: Int64;
  HasDigits, Failed: Boolean;
  Ch: Char;
begin
  for I := 0 to High(AVersion) do
    AVersion[I] := 0;
  Part := 0;
  Value := 0;
  HasDigits := False;
  Failed := False;
  // The end of the text acts as the final separator.
  for I := 1 to Length(AText) + 1 do
  begin
    if I <= Length(AText) then
      Ch := AText[I]
    else
      Ch := '.';
    if Ch = '.' then
    begin
      Failed := (not HasDigits) or (Part > High(AVersion));
      if Failed then
        Break;
      AVersion[Part] := Word(Value);
      Inc(Part);
      Value := 0;
      HasDigits := False;
    end
    else if (Ch >= '0') and (Ch <= '9') then
    begin
      Value := Value * 10 + (Ord(Ch) - Ord('0'));
      HasDigits := True;
      Failed := Value > High(Word);
      if Failed then
        Break;
    end
    else
    begin
      Failed := True;
      Break;
    end;
  end;
  Result := (not Failed) and ((Part = 3) or (Part = 4));
  if not Result then
    for I := 0 to High(AVersion) do
      AVersion[I] := 0;
end;

function TryDeriveWindowsVersion(const AVersionText: string; out AVersion: TWindowsVersion): Boolean;
const
  BUILD_MARKER = '-build.';
var
  Text, Core, Rest, Digits: string;
  I, P: Integer;
  BuildNumber: Int64;
begin
  Text := Trim(AVersionText);
  if (Text <> '') and ((Text[1] = 'v') or (Text[1] = 'V')) then
    Delete(Text, 1, 1);

  I := 1;
  while (I <= Length(Text)) and (Text[I] in ['0'..'9', '.']) do
    Inc(I);
  Core := Copy(Text, 1, I - 1);
  Rest := Copy(Text, I, MaxInt);

  Result := TryParseWindowsVersion(Core, AVersion);
  if not Result then
    Exit;

  // A three-part core takes the CI build number ('-build.N') as its fourth part.
  P := Pos(BUILD_MARKER, LowerCase(Rest));
  if (P = 1) and (Length(Core) - Length(StringReplace(Core, '.', '', [rfReplaceAll])) = 2) then
  begin
    Digits := '';
    I := P + Length(BUILD_MARKER);
    while (I <= Length(Rest)) and (Rest[I] in ['0'..'9']) do
    begin
      Digits := Digits + Rest[I];
      Inc(I);
    end;
    if (Digits <> '') and (Length(Digits) <= 5) then
    begin
      BuildNumber := StrToInt64(Digits);
      if BuildNumber <= High(Word) then
        AVersion[3] := Word(BuildNumber);
    end;
  end;
end;

procedure RaiseManifestError(const APath: string; ALine: Integer; const AMsg: string);
begin
  if ALine > 0 then
    raise ENikError.CreateFmt('%s:%d: %s', [APath, ALine, AMsg])
  else
    raise ENikError.CreateFmt('%s: %s', [APath, AMsg]);
end;

function IsValidManifestName(AKind: TManifestKind; const AName: string): Boolean;
begin
  case AKind of
    mkProgram, mkLibrary: Result := IsSafePathSegment(AName);
    mkPackage: Result := IsSafeRelativePath(AName) and (AName = Trim(AName));
  else
    raise ENikError.CreateFmt('Unsupported TManifestKind ordinal: %d', [Ord(AKind)]);
  end;
end;

end.
