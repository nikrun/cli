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

    Dependencies: TDependencySpecArray;
  end;

function ManifestKindToString(AKind: TManifestKind): string;
procedure RaiseManifestError(const APath: string; ALine: Integer; const AMsg: string);

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
