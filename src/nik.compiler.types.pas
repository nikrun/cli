unit nik.compiler.types;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, nik.types, nik.compiler.diag;

type
  TCompileArtifactKind = (cakExecutable, cakSharedLibrary, cakCheckOnly);
  TCompileSubsystem = (csConsole, csGui);
  TCompilePicMode = (cpmAuto, cpmOn, cpmOff);

  TCompileWarnings = record
    AsErrors: Boolean;
    HasHints: Boolean;
    Hints: Boolean;
    Notes: Boolean;
    Suppress: TStringArray;
  end;

  TCompileSpec = record
    // Toolchain backend & execution context
    CompilerBinary: string;
    CompilerBinDir: string;
    FpcCfgPath: string;
    TargetCpu: string;
    TargetOs: string;
    WorkingDir: string;

    // Input, artifact kind, cache & output
    ArtifactKind: TCompileArtifactKind;
    EntryPath: string;
    OutputBinaryPath: string;
    UnitOutputDir: string;
    ManifestFiles: TStringArray;
    CleanRebuild: Boolean;

    // Dialect & syntax
    Mode: string;
    LongStrings: Boolean;
    HasCOperators: Boolean;
    COperators: Boolean;
    ModeSwitches: TStringArray;

    // Subsystem & code generation
    HasSubsystem: Boolean;
    Subsystem: TCompileSubsystem;
    Pic: TCompilePicMode;
    CpuType: string;
    FpuType: string;
    StackSize: Integer;

    // Resolved filesystem search paths
    UnitPaths: TStringArray;
    IncludePaths: TStringArray;
    LibraryPaths: TStringArray;
    ObjectPaths: TStringArray;

    // Conditional compilation
    Defines: TStringArray;
    Undefines: TStringArray;

    // Debugging, assertions & runtime checks
    DebugInfo: string;
    Heaptrc: Boolean;
    HasAssertions: Boolean;
    Assertions: Boolean;
    HasExplicitChecks: Boolean;
    Checks: TStringArray;

    // Diagnostics & warnings
    Warnings: TCompileWarnings;

    // Optimization & linking
    HasOptimization: Boolean;
    Optimization: Integer;
    HasSmartLink: Boolean;
    SmartLink: Boolean;
    HasStripSymbols: Boolean;
    StripSymbols: Boolean;
    LinkLibraries: TStringArray;
    LinkerArgs: TStringArray;

    // Escape-hatch raw compiler arguments
    ExtraArgs: TStringArray;
  end;

  TPreparedCompile = record
    Spec: TCompileSpec;
    CompilerArgs: TStringArray;
  end;

  TCompileResult = record
    Success: Boolean;
    ExitCode: Integer;
    DurationMs: Int64;

    Spec: TCompileSpec;
    CompilerArgs: TStringArray;
    OutputSizeBytes: Int64;

    RawCompilerOutput: string;
    ParsedOutput: TParsedCompilerOutput;
  end;

function CompileArtifactKindToString(AKind: TCompileArtifactKind): string;

implementation

function CompileArtifactKindToString(AKind: TCompileArtifactKind): string;
begin
  case AKind of
    cakExecutable:    Result := 'executable';
    cakSharedLibrary: Result := 'shared-library';
    cakCheckOnly:     Result := 'check-only';
  else
    raise ENikError.CreateFmt('Unsupported TCompileArtifactKind ordinal: %d', [Ord(AKind)]);
  end;
end;

end.
