unit nik.compiler;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nik.types, nik.compiler.types, nik.compiler.diag;

procedure AssembleCompilerArgs(const ASpec: TCompileSpec; out AArgs: TStringArray);
function PrepareCompile(const ASpec: TCompileSpec): TPreparedCompile;
function ExecuteCompile(const APrepared: TPreparedCompile): TCompileResult;
function RunCompile(const ASpec: TCompileSpec): TCompileResult;

implementation

uses
  Process, nik.fs, nik.paths, nik.sha256;

procedure AppendArg(var AArgs: TStringArray; const AArg: string);
var
  N: Integer;
begin
  N := Length(AArgs);
  SetLength(AArgs, N + 1);
  AArgs[N] := AArg;
end;

procedure ConfigureProcessEnvironmentWithBinDir(AProc: TProcess; const ABinDir: string);
var
  Count, I, EqPos: Integer;
  Entry, Key, CurPath, Sep: string;
  PathUpdated: Boolean;
begin
  {$IFDEF WINDOWS}
  Sep := ';';
  {$ELSE}
  Sep := ':';
  {$ENDIF}

  AProc.Environment.Clear;
  PathUpdated := False;
  Count := GetEnvironmentVariableCount;
  for I := 1 to Count do
  begin
    Entry := GetEnvironmentString(I);
    if Entry = '' then
      Continue;
    // Preserve Windows drive working-directory pseudo-vars like '=C:=C:\...'
    if Entry[1] = '=' then
    begin
      AProc.Environment.Add(Entry);
      Continue;
    end;
    EqPos := Pos('=', Entry);
    if EqPos > 1 then
    begin
      Key := Copy(Entry, 1, EqPos - 1);
      if (ABinDir <> '') and SameText(Key, 'PATH') then
      begin
        CurPath := Copy(Entry, EqPos + 1, MaxInt);
        if CurPath <> '' then
          AProc.Environment.Add(Key + '=' + ABinDir + Sep + CurPath)
        else
          AProc.Environment.Add(Key + '=' + ABinDir);
        PathUpdated := True;
        Continue;
      end;
    end;
    AProc.Environment.Add(Entry);
  end;

  if (ABinDir <> '') and (not PathUpdated) then
    AProc.Environment.Add('PATH=' + ABinDir);
end;

function NormalizeProcessExitCode(AProc: TProcess): Integer;
var
  Code, RawStatus: Integer;
begin
  AProc.WaitOnExit;
  Code := AProc.ExitCode;
  RawStatus := AProc.ExitStatus;
  if Code <> 0 then
    Result := Code
  else if RawStatus <> 0 then
    Result := 128 + (RawStatus and $7F)
  else
    Result := 0;
end;

function ExecuteCompilerProcess(const ACompilerBin, ACompilerBinDir, AWorkDir: string;
  const AArgs: TStringArray; out ARawOutput: string; out ADurationMs: Int64): Integer;
var
  Proc: TProcess;
  OutStream: TMemoryStream;
  Buf: array[0..4095] of Byte;
  BytesRead: LongInt;
  I: Integer;
  StartTick, EndTick: QWord;
  RawBytes: RawByteString;
begin
  ARawOutput := '';
  StartTick := GetTickCount64;
  Proc := TProcess.Create(nil);
  OutStream := TMemoryStream.Create;
  try
    Proc.Executable := ACompilerBin;
    if AWorkDir <> '' then
      Proc.CurrentDirectory := AWorkDir;
    for I := 0 to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);

    ConfigureProcessEnvironmentWithBinDir(Proc, ACompilerBinDir);
    Proc.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    Proc.Execute;

    while Proc.Running or (Proc.Output.NumBytesAvailable > 0) do
    begin
      while Proc.Output.NumBytesAvailable > 0 do
      begin
        BytesRead := Proc.Output.Read(Buf[0], SizeOf(Buf));
        if BytesRead > 0 then
          OutStream.WriteBuffer(Buf[0], BytesRead);
      end;
      if Proc.Running then
        Sleep(5);
    end;

    repeat
      BytesRead := Proc.Output.Read(Buf[0], SizeOf(Buf));
      if BytesRead > 0 then
        OutStream.WriteBuffer(Buf[0], BytesRead);
    until BytesRead <= 0;

    Result := NormalizeProcessExitCode(Proc);
    EndTick := GetTickCount64;
    ADurationMs := Int64(EndTick - StartTick);

    RawBytes := '';
    SetLength(RawBytes, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(RawBytes[1], OutStream.Size);
    end;
    ARawOutput := string(RawBytes);
  finally
    OutStream.Free;
    Proc.Free;
  end;
end;

procedure AssembleCompilerArgs(const ASpec: TCompileSpec; out AArgs: TStringArray);
var
  I: Integer;
  ChkRange, ChkOverflow, ChkIo, ChkStack, ChkObject: Boolean;
  ChkLower, OutDir, OutName, SuppressCsv, LibItem: string;
begin
  AArgs := nil;

  // Hermetic SDK configuration
  AppendArg(AArgs, '-n');
  if ASpec.FpcCfgPath <> '' then
    AppendArg(AArgs, '@' + ASpec.FpcCfgPath);

  // Machine-parseable message numbers + full file paths + quiet banner
  AppendArg(AArgs, '-vq');
  AppendArg(AArgs, '-viwn');
  AppendArg(AArgs, '-vb');
  AppendArg(AArgs, '-l-');

  // Structured warning/hint/note & message suppression controls
  if ASpec.Warnings.HasHints then
  begin
    if ASpec.Warnings.Hints then
      AppendArg(AArgs, '-vh')
    else
      AppendArg(AArgs, '-vh-');
  end;
  if not ASpec.Warnings.Notes then
    AppendArg(AArgs, '-vn-');
  if ASpec.Warnings.AsErrors then
    AppendArg(AArgs, '-Sew');
  if Length(ASpec.Warnings.Suppress) > 0 then
  begin
    SuppressCsv := '';
    for I := 0 to High(ASpec.Warnings.Suppress) do
    begin
      if SuppressCsv <> '' then
        SuppressCsv := SuppressCsv + ',';
      SuppressCsv := SuppressCsv + ASpec.Warnings.Suppress[I];
    end;
    AppendArg(AArgs, '-vm' + SuppressCsv);
  end;

  if ASpec.CleanRebuild then
    AppendArg(AArgs, '-B');

  // Dialect, modeswitches, strings & C-style operators
  if ASpec.Mode <> '' then
    AppendArg(AArgs, '-M' + ASpec.Mode);
  for I := 0 to High(ASpec.ModeSwitches) do
    AppendArg(AArgs, '-M' + ASpec.ModeSwitches[I]);

  if ASpec.LongStrings then
    AppendArg(AArgs, '-Sh')
  else
    AppendArg(AArgs, '-Sh-');

  if ASpec.HasCOperators then
  begin
    if ASpec.COperators then
      AppendArg(AArgs, '-Sc')
    else
      AppendArg(AArgs, '-Sc-');
  end;

  // Subsystem, PIC, CPU/FPU & stack size
  if (ASpec.ArtifactKind = cakExecutable) and
     SameText(ASpec.TargetOs, 'win64') and ASpec.HasSubsystem then
  begin
    case ASpec.Subsystem of
      csGui:     AppendArg(AArgs, '-WG');
      csConsole: AppendArg(AArgs, '-WG-');
    else
      raise ENikError.CreateFmt('Unsupported TCompileSubsystem ordinal: %d', [Ord(ASpec.Subsystem)]);
    end;
  end;

  case ASpec.Pic of
    cpmOn:  AppendArg(AArgs, '-Cg');
    cpmOff: AppendArg(AArgs, '-Cg-');
    cpmAuto:
      if (ASpec.ArtifactKind = cakSharedLibrary) and
         (not SameText(ASpec.TargetOs, 'win64')) then
        AppendArg(AArgs, '-Cg');
  else
    raise ENikError.CreateFmt('Unsupported TCompilePicMode ordinal: %d', [Ord(ASpec.Pic)]);
  end;

  if (ASpec.CpuType <> '') and
     (not SameText(ASpec.CpuType, 'native')) and
     (not SameText(ASpec.CpuType, 'default')) then
    AppendArg(AArgs, '-Cp' + ASpec.CpuType);

  if (ASpec.FpuType <> '') and (not SameText(ASpec.FpuType, 'default')) then
    AppendArg(AArgs, '-Cf' + ASpec.FpuType);

  if ASpec.StackSize > 0 then
    AppendArg(AArgs, '-Cs' + IntToStr(ASpec.StackSize));

  // Undefines before defines
  for I := 0 to High(ASpec.Undefines) do
    AppendArg(AArgs, '-u' + ASpec.Undefines[I]);
  for I := 0 to High(ASpec.Defines) do
    AppendArg(AArgs, '-d' + ASpec.Defines[I]);

  // Debug info (placed after defines so explicit settings override fpc.cfg #IFDEF blocks)
  if ASpec.DebugInfo = 'none' then
    AppendArg(AArgs, '-g-')
  else if ASpec.DebugInfo = 'lineinfo' then
    AppendArg(AArgs, '-gl')
  else if ASpec.DebugInfo = 'stabs' then
  begin
    AppendArg(AArgs, '-gl');
    AppendArg(AArgs, '-gs');
  end
  else if ASpec.DebugInfo = 'dwarf2' then
  begin
    AppendArg(AArgs, '-gl');
    AppendArg(AArgs, '-gw2');
  end
  else if ASpec.DebugInfo = 'dwarf3' then
  begin
    AppendArg(AArgs, '-gl');
    AppendArg(AArgs, '-gw3');
  end
  else if ASpec.DebugInfo = 'external' then
  begin
    AppendArg(AArgs, '-gl');
    AppendArg(AArgs, '-gw2');
    AppendArg(AArgs, '-Xg');
  end;

  if ASpec.Heaptrc then
  begin
    AppendArg(AArgs, '-gh');
    AppendArg(AArgs, '-gl');
  end;

  if ASpec.HasAssertions then
  begin
    if ASpec.Assertions then
      AppendArg(AArgs, '-Sa')
    else
      AppendArg(AArgs, '-Sa-');
  end;

  // Runtime checks
  if ASpec.HasExplicitChecks then
  begin
    ChkRange := False;
    ChkOverflow := False;
    ChkIo := False;
    ChkStack := False;
    ChkObject := False;

    for I := 0 to High(ASpec.Checks) do
    begin
      ChkLower := LowerCase(ASpec.Checks[I]);
      if ChkLower = 'none' then
      begin
        ChkRange := False;
        ChkOverflow := False;
        ChkIo := False;
        ChkStack := False;
        ChkObject := False;
      end
      else if ChkLower = 'all' then
      begin
        ChkRange := True;
        ChkOverflow := True;
        ChkIo := True;
        ChkStack := True;
      end
      else if ChkLower = 'range' then
        ChkRange := True
      else if ChkLower = 'overflow' then
        ChkOverflow := True
      else if ChkLower = 'io' then
        ChkIo := True
      else if ChkLower = 'stack' then
        ChkStack := True
      else if ChkLower = 'object' then
        ChkObject := True;
    end;

    if ChkRange then AppendArg(AArgs, '-Cr') else AppendArg(AArgs, '-Cr-');
    if ChkOverflow then AppendArg(AArgs, '-Co') else AppendArg(AArgs, '-Co-');
    if ChkIo then AppendArg(AArgs, '-Ci') else AppendArg(AArgs, '-Ci-');
    if ChkStack then AppendArg(AArgs, '-Ct') else AppendArg(AArgs, '-Ct-');
    if ChkObject then AppendArg(AArgs, '-CR') else AppendArg(AArgs, '-CR-');
  end;

  // Optimization, smart-linking & symbol stripping
  if ASpec.HasOptimization then
  begin
    if ASpec.Optimization <= 0 then
      AppendArg(AArgs, '-O-')
    else
      AppendArg(AArgs, '-O' + IntToStr(ASpec.Optimization));
  end;

  if ASpec.HasSmartLink then
  begin
    if ASpec.SmartLink then
    begin
      AppendArg(AArgs, '-CX');
      AppendArg(AArgs, '-XX');
    end
    else
    begin
      AppendArg(AArgs, '-CX-');
      AppendArg(AArgs, '-XX-');
    end;
  end;

  if ASpec.HasStripSymbols then
  begin
    if ASpec.StripSymbols then
      AppendArg(AArgs, '-Xs')
    else
      AppendArg(AArgs, '-Xs-');
  end;

  // Search paths
  for I := 0 to High(ASpec.IncludePaths) do
    AppendArg(AArgs, '-Fi' + ASpec.IncludePaths[I]);
  for I := 0 to High(ASpec.UnitPaths) do
    AppendArg(AArgs, '-Fu' + ASpec.UnitPaths[I]);
  for I := 0 to High(ASpec.LibraryPaths) do
    AppendArg(AArgs, '-Fl' + ASpec.LibraryPaths[I]);
  for I := 0 to High(ASpec.ObjectPaths) do
    AppendArg(AArgs, '-Fo' + ASpec.ObjectPaths[I]);

  // Unit output directory & binary/check-only output flags
  if ASpec.UnitOutputDir <> '' then
    AppendArg(AArgs, '-FU' + ASpec.UnitOutputDir);

  case ASpec.ArtifactKind of
    cakExecutable, cakSharedLibrary:
      begin
        OutDir := ExcludeTrailingPathDelimiter(ExtractFileDir(ASpec.OutputBinaryPath));
        OutName := ExtractFileName(ASpec.OutputBinaryPath);
        if OutDir <> '' then
          AppendArg(AArgs, '-FE' + OutDir);
        if OutName <> '' then
          AppendArg(AArgs, '-o' + OutName);
      end;
    cakCheckOnly:
      AppendArg(AArgs, '-Cn');
  else
    raise ENikError.CreateFmt('Unsupported TCompileArtifactKind ordinal: %d', [Ord(ASpec.ArtifactKind)]);
  end;

  // Linked libraries & explicit linker arguments (when linking)
  if ASpec.ArtifactKind <> cakCheckOnly then
  begin
    for I := 0 to High(ASpec.LinkLibraries) do
    begin
      LibItem := ASpec.LinkLibraries[I];
      if (Length(LibItem) > 0) and (LibItem[1] = '-') then
        AppendArg(AArgs, '-k' + LibItem)
      else
        AppendArg(AArgs, '-k-l' + LibItem);
    end;
    for I := 0 to High(ASpec.LinkerArgs) do
      AppendArg(AArgs, '-k' + ASpec.LinkerArgs[I]);
  end;

  // Escape-hatch extra compiler arguments
  for I := 0 to High(ASpec.ExtraArgs) do
    AppendArg(AArgs, ASpec.ExtraArgs[I]);

  // Entry source file
  AppendArg(AArgs, ASpec.EntryPath);
end;

function PrepareCompile(const ASpec: TCompileSpec): TPreparedCompile;
begin
  if Trim(ASpec.CompilerBinary) = '' then
    raise ENikError.Create('Compiler binary path is required in TCompileSpec.');
  if not FileExists(ASpec.CompilerBinary) then
    raise ENikError.CreateFmt('Compiler backend binary not found: %s', [ASpec.CompilerBinary]);

  if (ASpec.FpcCfgPath <> '') and (not FileExists(ASpec.FpcCfgPath)) then
    raise ENikError.CreateFmt('Compiler configuration file not found: %s', [ASpec.FpcCfgPath]);

  if Trim(ASpec.EntryPath) = '' then
    raise ENikError.Create('Entry source file path is required in TCompileSpec.');
  if not FileExists(ASpec.EntryPath) then
    raise ENikError.CreateFmt('Entry source file not found: %s', [ASpec.EntryPath]);

  if (ASpec.ArtifactKind <> cakCheckOnly) and (Trim(ASpec.OutputBinaryPath) = '') then
    raise ENikError.Create('Output binary path is required when compiling a linked artifact.');

  Result := Default(TPreparedCompile);
  Result.Spec := ASpec;
  AssembleCompilerArgs(Result.Spec, Result.CompilerArgs);
end;

function ComputeCompileCacheFingerprint(const APrepared: TPreparedCompile): string;
var
  Payload, MPath, MHash: string;
  I: Integer;
begin
  Payload := 'nik-compile-cache-v1' + #10 +
             'compiler=' + APrepared.Spec.CompilerBinary + #10 +
             'fpccfg=' + APrepared.Spec.FpcCfgPath + #10 +
             'target=' + APrepared.Spec.TargetCpu + '-' + APrepared.Spec.TargetOs + #10;

  for I := 0 to High(APrepared.Spec.ManifestFiles) do
  begin
    MPath := APrepared.Spec.ManifestFiles[I];
    if (MPath <> '') and FileExists(MPath) then
    begin
      try
        MHash := Sha256FileHex(MPath);
      except
        MHash := 'unreadable';
      end;
    end
    else
      MHash := 'missing';
    Payload := Payload + 'manifest:' + MPath + '=' + MHash + #10;
  end;

  for I := 0 to High(APrepared.CompilerArgs) do
  begin
    if APrepared.CompilerArgs[I] = '-B' then
      Continue;
    Payload := Payload + 'arg:' + APrepared.CompilerArgs[I] + #10;
  end;

  Result := Sha256StringHex(RawByteString(Payload));
end;

function ExecuteCompile(const APrepared: TPreparedCompile): TCompileResult;
var
  NeedPurge: Boolean;
  Fingerprint, FingerprintPath, ExistingFp: string;
begin
  Result := Default(TCompileResult);
  Result.Spec := APrepared.Spec;
  Result.CompilerArgs := APrepared.CompilerArgs;

  if Result.Spec.UnitOutputDir <> '' then
  begin
    Fingerprint := ComputeCompileCacheFingerprint(APrepared);
    FingerprintPath := JoinPath(Result.Spec.UnitOutputDir, '.nik-cache-fingerprint');
    NeedPurge := Result.Spec.CleanRebuild;

    if (not NeedPurge) and DirectoryExists(Result.Spec.UnitOutputDir) then
    begin
      if not FileExists(FingerprintPath) then
        NeedPurge := True
      else
      begin
        try
          ExistingFp := Trim(ReadFileTextUtf8(FingerprintPath));
        except
          ExistingFp := '';
        end;
        if ExistingFp <> Fingerprint then
          NeedPurge := True;
      end;
    end;

    if NeedPurge and DirectoryExists(Result.Spec.UnitOutputDir) then
      DeleteDirectoryRecursive(Result.Spec.UnitOutputDir);

    EnsureDirExists(Result.Spec.UnitOutputDir);
    try
      WriteFileTextUtf8(FingerprintPath, Fingerprint + LineEnding);
    except
      // Non-fatal if cache metadata cannot be persisted
    end;
  end;

  if (Result.Spec.ArtifactKind <> cakCheckOnly) and (Result.Spec.OutputBinaryPath <> '') then
    EnsureDirExists(ExtractFileDir(Result.Spec.OutputBinaryPath));

  Result.ExitCode := ExecuteCompilerProcess(
    Result.Spec.CompilerBinary, Result.Spec.CompilerBinDir, Result.Spec.WorkingDir,
    Result.CompilerArgs, Result.RawCompilerOutput, Result.DurationMs);

  Result.ParsedOutput := ParseFpcCompilerOutput(Result.RawCompilerOutput, Result.Spec.WorkingDir);

  case Result.Spec.ArtifactKind of
    cakExecutable, cakSharedLibrary:
      Result.Success := (Result.ExitCode = 0) and
                        (Result.ParsedOutput.ErrorCount = 0) and
                        FileExists(Result.Spec.OutputBinaryPath);
    cakCheckOnly:
      Result.Success := (Result.ExitCode = 0) and
                        (Result.ParsedOutput.ErrorCount = 0);
  else
    raise ENikError.CreateFmt('Unsupported TCompileArtifactKind ordinal: %d', [Ord(Result.Spec.ArtifactKind)]);
  end;

  if (not Result.Success) and (Result.ExitCode = 0) then
    Result.ExitCode := 1;

  if Result.Success and (Result.Spec.ArtifactKind <> cakCheckOnly) then
    Result.OutputSizeBytes := GetFileSizeSafe(Result.Spec.OutputBinaryPath);
end;

function RunCompile(const ASpec: TCompileSpec): TCompileResult;
begin
  Result := ExecuteCompile(PrepareCompile(ASpec));
end;

end.
