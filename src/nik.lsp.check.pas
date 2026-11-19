unit nik.lsp.check;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Process,
  nik.types, nik.manifest.types, nik.compiler.diag,
  nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.documents;

type
  TNikWorkspaceContext = record
    HasManifest: Boolean;
    ManifestPath: string;
    HasManifestError: Boolean;
    ManifestErrorLine: Integer; // 0-based line index
    ManifestErrorMessage: string;
    ProjectDir: string;
    ProfileName: string;
    ManifestKind: TManifestKind;
    EntryPath: string;
    Sdk: TInstalledSdk;
    SdkBinDir: string;
    CompilerBinary: string;
    FpcCfgPath: string;
    RtlSourceDir: string;
    PackagesSourceDir: string;
    UnitPaths: TStringArray;
    IncludePaths: TStringArray;
    Defines: TStringArray;
    Undefines: TStringArray;
    Mode: string;
    ModeSwitches: TStringArray;
    LongStrings: Boolean;
    ManifestFiles: TStringArray;
    ConfigFingerprint: string;
    CacheDir: string;
  end;

  TNikFileDiagnostics = record
    NormalizedKey: string;
    Uri: string;
    Diagnostics: TLspDiagnosticArray;
  end;
  TNikFileDiagnosticsArray = array of TNikFileDiagnostics;

  TNikOverlayFileEntry = record
    RelSlashSuffix: string; // Lowercase '/overlay/<relpath>' with forward slashes
    OverlayPath: string;
    OrigPath: string;
    ClientUri: string;
  end;
  TNikOverlayFileEntryArray = array of TNikOverlayFileEntry;

  { Non-blocking child ppc* -Cn semantic/syntax checker with unsaved editor buffer overlay. }
  TNikAsyncCompilerCheck = class
  private
    FProc: TProcess;
    FOutStream: TMemoryStream;
    FProjectDir: string;
    FOwnerKey: string;
    FOwnerUri: string;
    FOwnerFilePath: string;
    FOverlayEntries: TNikOverlayFileEntryArray;
    procedure DrainAvailableOutput;
    function MapOverlayPathToRealPath(const ADiagFilePath: string; out AClientUri: string): string;
  public
    constructor Create(const AOwnerKey, AOwnerUri, AOwnerFilePath, AProjectDir: string;
      const AOverlayEntries: TNikOverlayFileEntryArray; AProc: TProcess);
    destructor Destroy; override;

    { Drains pipe output without blocking; returns True once child compiler has exited. }
    function PollFinished: Boolean;
    { Waits up to AMaxWaitMs for completion (used during graceful LSP shutdown). }
    function WaitUntilFinished(AMaxWaitMs: Integer): Boolean;
    { Terminates an obsolete in-flight compiler check immediately. }
    procedure Abort;
    { Parses compiler output and maps diagnostics back to real files & open client URIs. }
    function CollectDiagnostics(ADocStore: TLspDocumentStore): TNikFileDiagnosticsArray;

    property OwnerKey: string read FOwnerKey;
    property OwnerUri: string read FOwnerUri;
    property OwnerFilePath: string read FOwnerFilePath;
  end;

function ResolveLspWorkspace(const ARootDir, AManifestOverride, AProfileName: string;
  out AContext: TNikWorkspaceContext; out AWarningMsg: string): Boolean;

{ Same as ResolveLspWorkspace but resolved for the 'test' overlay (test.build + test.dependencies) used for
  *_test.pas / *.test.pas documents (see internal-notes/specs/nik-test.md, section 6). }
function ResolveLspTestWorkspace(const ARootDir, AManifestOverride, AProfileName: string;
  out AContext: TNikWorkspaceContext; out AWarningMsg: string): Boolean;

{ True when AFilePath follows the test unit naming convention and is analyzed in the test context. }
function IsLspTestDocument(const AFilePath: string): Boolean;

function ValidateManifestTextForLsp(const AManifestPath, AText, AProfileName: string;
  out ADiagnostics: TLspDiagnosticArray): Boolean;

procedure EnsureFreshLspCompilerCache(const AContext: TNikWorkspaceContext);

procedure SyncOpenDocumentsOverlay(const AContext: TNikWorkspaceContext;
  ADocStore: TLspDocumentStore; out AEntries: TNikOverlayFileEntryArray);

function StartAsyncLspCompilerCheck(const AContext: TNikWorkspaceContext;
  const AOwnerUri, AActiveFilePath: string;
  ADocStore: TLspDocumentStore): TNikAsyncCompilerCheck;

function RunLspSyntaxAndSemanticCheck(const AContext: TNikWorkspaceContext;
  const AActiveFilePath: string; ADocStore: TLspDocumentStore): TNikFileDiagnosticsArray;

implementation

uses
  StrUtils, nik.platform, nik.paths, nik.fs, nik.sha256, nik.sdk.config, nik.sdk.manager,
  nik.test.discovery,
  nik.manifest.io, nik.manifest.resolve, nik.project,
  nik.pkg.types, nik.pkg.resolve, nikrun.lsp.utf16;

procedure AppendArg(var AArgs: TStringArray; const AArg: string);
var
  N: Integer;
begin
  N := Length(AArgs);
  SetLength(AArgs, N + 1);
  AArgs[N] := AArg;
end;

procedure AppendUniqueDir(var ADirs: TStringArray; const ADir: string);
var
  Clean: string;
  I, N: Integer;
begin
  Clean := ExcludeTrailingPathDelimiter(Trim(ADir));
  if Clean = '' then
    Exit;
  for I := 0 to High(ADirs) do
  begin
    {$IFDEF WINDOWS}
    if SameText(ADirs[I], Clean) then
      Exit;
    {$ELSE}
    if ADirs[I] = Clean then
      Exit;
    {$ENDIF}
  end;
  N := Length(ADirs);
  SetLength(ADirs, N + 1);
  ADirs[N] := Clean;
end;

function SameFilePathNative(const A, B: string): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := SameText(NormalizeNativeSeparators(A), NormalizeNativeSeparators(B));
  {$ELSE}
  Result := NormalizeNativeSeparators(A) = NormalizeNativeSeparators(B);
  {$ENDIF}
end;

function ToForwardSlashLower(const APath: string): string;
var
  I: Integer;
begin
  Result := LowerCase(APath);
  for I := 1 to Length(Result) do
    if Result[I] = '\' then
      Result[I] := '/';
end;

function IsPascalOrIncludeExt(const AFilePath: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFilePath));
  Result := (Ext = '.pas') or (Ext = '.pp') or (Ext = '.dpr') or (Ext = '.lpr') or (Ext = '.inc');
end;

function IsCompilableMainOrUnitExt(const AFilePath: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFilePath));
  Result := (Ext = '.pas') or (Ext = '.pp') or (Ext = '.dpr') or (Ext = '.lpr');
end;

function Fnv1aHex32(const AText: string): string;
var
  H: Cardinal;
  I: Integer;
  S: string;
begin
  {$IFDEF WINDOWS}
  S := LowerCase(NormalizeNativeSeparators(AText));
  {$ELSE}
  S := NormalizeNativeSeparators(AText);
  {$ENDIF}
  H := Cardinal($811C9DC5);
  for I := 1 to Length(S) do
  begin
    H := H xor Byte(S[I]);
    H := Cardinal(QWord(H) * QWord($01000193));
  end;
  Result := IntToHex(H, 8);
end;

function DiskFileHasUtf8Bom(const AFilePath: string): Boolean;
var
  FS: TFileStream;
  Bom: array[0..2] of Byte;
begin
  Result := False;
  if (AFilePath = '') or (not FileExists(AFilePath)) then
    Exit;
  try
    FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      if FS.Size < 3 then
        Exit(False);
      FS.ReadBuffer(Bom[0], 3);
      Result := (Bom[0] = $EF) and (Bom[1] = $BB) and (Bom[2] = $BF);
    finally
      FS.Free;
    end;
  except
    Result := False;
  end;
end;

function FileContentEquals(const AFilePath, AExpectedText: string): Boolean;
var
  FS: TFileStream;
  DiskBytes: RawByteString;
begin
  Result := False;
  if not FileExists(AFilePath) then
    Exit;
  try
    FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      if FS.Size <> Length(AExpectedText) then
        Exit(False);
      if FS.Size = 0 then
        Exit(True);
      DiskBytes := '';
      SetLength(DiskBytes, FS.Size);
      FS.ReadBuffer(DiskBytes[1], FS.Size);
      Result := CompareByte(DiskBytes[1], AExpectedText[1], Length(AExpectedText)) = 0;
    finally
      FS.Free;
    end;
  except
    Result := False;
  end;
end;

procedure WriteOverlayFileUtf8(const AFilePath, AText: string);
var
  FS: TFileStream;
begin
  EnsureDirExists(ExtractFileDir(AFilePath));
  FS := TFileStream.Create(AFilePath, fmCreate);
  try
    if Length(AText) > 0 then
      FS.WriteBuffer(AText[1], Length(AText));
  finally
    FS.Free;
  end;
end;

procedure PruneOverlayDirRecursive(const ADir: string; const AActiveEntries: TNikOverlayFileEntryArray);
var
  SR: TSearchRec;
  CleanDir, FullItem: string;
  I: Integer;
  KeepFile: Boolean;
begin
  if (ADir = '') or (not DirectoryExists(ADir)) then
    Exit;

  CleanDir := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(CleanDir + AllFilesMask, faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        FullItem := CleanDir + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
        begin
          PruneOverlayDirRecursive(FullItem, AActiveEntries);
          {$I-}
          RemoveDir(FullItem);
          {$I+}
          if IOResult <> 0 then
            ; // Non-empty directory stays
        end
        else
        begin
          KeepFile := False;
          for I := 0 to High(AActiveEntries) do
            if SameFilePathNative(FullItem, AActiveEntries[I].OverlayPath) then
            begin
              KeepFile := True;
              Break;
            end;
          if not KeepFile then
            SysUtils.DeleteFile(FullItem);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

function ComputeLspContextFingerprint(const AContext: TNikWorkspaceContext): string;
var
  Payload, MPath, MHash: string;
  I: Integer;
begin
  Payload := 'nik-lsp-cache-v1' + #10 +
             'compiler=' + AContext.CompilerBinary + #10 +
             'fpccfg=' + AContext.FpcCfgPath + #10 +
             'profile=' + AContext.ProfileName + #10 +
             'mode=' + AContext.Mode + #10 +
             'longstrings=' + BoolToStr(AContext.LongStrings, True) + #10;

  for I := 0 to High(AContext.ManifestFiles) do
  begin
    MPath := AContext.ManifestFiles[I];
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

  for I := 0 to High(AContext.ModeSwitches) do
    Payload := Payload + 'modeswitch:' + AContext.ModeSwitches[I] + #10;
  for I := 0 to High(AContext.Defines) do
    Payload := Payload + 'define:' + AContext.Defines[I] + #10;
  for I := 0 to High(AContext.Undefines) do
    Payload := Payload + 'undefine:' + AContext.Undefines[I] + #10;
  for I := 0 to High(AContext.IncludePaths) do
    Payload := Payload + 'inc:' + AContext.IncludePaths[I] + #10;
  for I := 0 to High(AContext.UnitPaths) do
    Payload := Payload + 'unit:' + AContext.UnitPaths[I] + #10;

  Result := Sha256StringHex(RawByteString(Payload));
end;

procedure PurgeLspCompiledUnits(const ACacheDir: string);
var
  SR: TSearchRec;
  FullItem: string;
begin
  if (ACacheDir = '') or (not DirectoryExists(ACacheDir)) then
    Exit;

  if FindFirst(IncludeTrailingPathDelimiter(ACacheDir) + AllFilesMask, faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        if (SR.Attr and faDirectory) <> 0 then
          Continue;
        // Preserve CodeTools probe/cache files inside the shared -lsp cache directory
        if SameText(SR.Name, 'codetools-config.xml') or
           SameText(SR.Name, '_nik_ct_probe.pas') or
           SameText(SR.Name, '.nik-cache-fingerprint') then
          Continue;
        FullItem := IncludeTrailingPathDelimiter(ACacheDir) + SR.Name;
        SysUtils.DeleteFile(FullItem);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

procedure EnsureFreshLspCompilerCache(const AContext: TNikWorkspaceContext);
var
  ExpectedFp, FingerprintPath, ExistingFp: string;
begin
  if AContext.CacheDir = '' then
    Exit;

  ExpectedFp := AContext.ConfigFingerprint;
  if ExpectedFp = '' then
    ExpectedFp := ComputeLspContextFingerprint(AContext);

  EnsureDirExists(AContext.CacheDir);
  FingerprintPath := JoinPath(AContext.CacheDir, '.nik-cache-fingerprint');
  ExistingFp := '';
  if FileExists(FingerprintPath) then
  begin
    try
      ExistingFp := Trim(ReadFileTextUtf8(FingerprintPath));
    except
      ExistingFp := '';
    end;
  end;

  if ExistingFp = ExpectedFp then
    Exit;

  PurgeLspCompiledUnits(AContext.CacheDir);
  try
    WriteFileTextUtf8(FingerprintPath, ExpectedFp + LineEnding);
  except
    // Non-fatal if fingerprint metadata cannot be written
  end;
end;

procedure SyncOpenDocumentsOverlay(const AContext: TNikWorkspaceContext;
  ADocStore: TLspDocumentStore; out AEntries: TNikOverlayFileEntryArray);
var
  OverlayRoot, ProjPrefix, OrigPath, RelSubpath, OverlayPath, EffectiveOverlayBytes: string;
  I, OutCount: Integer;
  Doc: TLspDocument;
  InsideProject, HasLeadingBom: Boolean;
begin
  AEntries := nil;
  if AContext.CacheDir = '' then
    Exit;

  OverlayRoot := JoinPath(AContext.CacheDir, 'overlay');
  OutCount := 0;

  if (ADocStore <> nil) and (ADocStore.Count > 0) then
  begin
    ProjPrefix := IncludeTrailingPathDelimiter(ExpandFileName(AContext.ProjectDir));
    SetLength(AEntries, ADocStore.Count);

    for I := 0 to ADocStore.Count - 1 do
    begin
      Doc := ADocStore[I];
      if (Doc = nil) or (Trim(Doc.FilePath) = '') or (not IsPascalOrIncludeExt(Doc.FilePath)) then
        Continue;

      OrigPath := ExpandFileName(NormalizeNativeSeparators(Doc.FilePath));
      {$IFDEF WINDOWS}
      InsideProject := (Length(OrigPath) > Length(ProjPrefix)) and
                       SameText(Copy(OrigPath, 1, Length(ProjPrefix)), ProjPrefix);
      {$ELSE}
      InsideProject := (Length(OrigPath) > Length(ProjPrefix)) and
                       (Copy(OrigPath, 1, Length(ProjPrefix)) = ProjPrefix);
      {$ENDIF}

      if InsideProject then
        RelSubpath := Copy(OrigPath, Length(ProjPrefix) + 1, MaxInt)
      else
        RelSubpath := JoinPath(JoinPath('_ext', Fnv1aHex32(ExtractFileDir(OrigPath))), ExtractFileName(OrigPath));

      // Preserve original disk UTF-8 BOM on overlay files (VS Code strips BOM in didOpen/didChange,
      // which otherwise triggers FPC error 2089 when an open unit includes a BOM-prefixed .inc file on disk).
      HasLeadingBom := (Length(Doc.Text) >= 3) and
                       (Doc.Text[1] = #$EF) and (Doc.Text[2] = #$BB) and (Doc.Text[3] = #$BF);
      if (not HasLeadingBom) and DiskFileHasUtf8Bom(OrigPath) then
        EffectiveOverlayBytes := #$EF#$BB#$BF + Doc.Text
      else
        EffectiveOverlayBytes := Doc.Text;

      OverlayPath := JoinPath(OverlayRoot, RelSubpath);
      if not FileContentEquals(OverlayPath, EffectiveOverlayBytes) then
      begin
        try
          WriteOverlayFileUtf8(OverlayPath, EffectiveOverlayBytes);
        except
          Continue;
        end;
      end;

      AEntries[OutCount].RelSlashSuffix := '/overlay/' + ToForwardSlashLower(RelSubpath);
      AEntries[OutCount].OverlayPath := OverlayPath;
      AEntries[OutCount].OrigPath := OrigPath;
      AEntries[OutCount].ClientUri := Doc.Uri;
      Inc(OutCount);
    end;
    SetLength(AEntries, OutCount);
  end;

  if DirectoryExists(OverlayRoot) then
    PruneOverlayDirRecursive(OverlayRoot, AEntries);
end;

function FindManifestNear(const ARootDir, AManifestOverride: string): string;
var
  CandYml, CandYaml: string;
begin
  Result := '';
  if Trim(AManifestOverride) <> '' then
  begin
    Result := FindManifestFile(AManifestOverride);
    Exit;
  end;

  if (ARootDir <> '') and DirectoryExists(ARootDir) then
  begin
    CandYaml := JoinPath(ARootDir, 'nik.yaml');
    if FileExists(CandYaml) then
      Exit(CandYaml);
    CandYml := JoinPath(ARootDir, 'nik.yml');
    if FileExists(CandYml) then
      Exit(CandYml);
  end;

  try
    Result := FindManifestFile('');
  except
    Result := '';
  end;
end;

function ParseManifestExceptionLocation(const AManifestPath, ARawMsg: string;
  out ALine0: Integer; out ACleanMsg: string): Boolean;
var
  Prefix, Rest, NumStr: string;
  ColonPos, ParsedLine, ErrCode: Integer;
begin
  ALine0 := 0;
  ACleanMsg := Trim(ARawMsg);
  Result := False;
  if AManifestPath = '' then
    Exit;

  Prefix := AManifestPath + ':';
  if (Length(ACleanMsg) > Length(Prefix)) and
     SameText(Copy(ACleanMsg, 1, Length(Prefix)), Prefix) then
  begin
    Rest := Copy(ACleanMsg, Length(Prefix) + 1, MaxInt);
    ColonPos := Pos(':', Rest);
    if (ColonPos > 1) and (ColonPos <= 10) then
    begin
      NumStr := Copy(Rest, 1, ColonPos - 1);
      System.Val(NumStr, ParsedLine, ErrCode);
      if (ErrCode = 0) and (ParsedLine >= 1) then
      begin
        ALine0 := ParsedLine - 1;
        ACleanMsg := Trim(Copy(Rest, ColonPos + 1, MaxInt));
        Exit(True);
      end;
    end;
    ACleanMsg := Trim(Rest);
    Result := True;
  end;
end;

function ValidateManifestTextForLsp(const AManifestPath, AText, AProfileName: string;
  out ADiagnostics: TLspDiagnosticArray): Boolean;
var
  ProjDir, EffProfile, CleanMsg: string;
  Parsed: TParsedManifest;
  Line0: Integer;
begin
  ADiagnostics := nil;
  ProjDir := ExcludeTrailingPathDelimiter(ExtractFileDir(ExpandFileName(AManifestPath)));
  EffProfile := Trim(AProfileName);
  if EffProfile = '' then
    EffProfile := 'debug';

  try
    Parsed := ParseManifestText(AText, AManifestPath, ProjDir);
    ResolveManifestConfig(Parsed, EffProfile, GetHostCpu, GetHostOs,
      (Parsed.Kind = mkPackage) and Parsed.HasTest, Parsed.Kind <> mkPackage);
    Result := True;
  except
    on E: Exception do
    begin
      ParseManifestExceptionLocation(AManifestPath, E.Message, Line0, CleanMsg);
      SetLength(ADiagnostics, 1);
      ADiagnostics[0] := Default(TLspDiagnostic);
      ADiagnostics[0].Range := TLspRange.SingleLine(Line0, 0, 200);
      ADiagnostics[0].Severity := ldsError;
      ADiagnostics[0].Source := 'nik.yaml';
      ADiagnostics[0].Message := CleanMsg;
      Result := False;
    end;
  end;
end;

function ResolveLspWorkspaceCore(const ARootDir, AManifestOverride, AProfileName: string;
  AForTest: Boolean; out AContext: TNikWorkspaceContext; out AWarningMsg: string): Boolean;
var
  ManifestFile, EffProfile, CleanErr, FallbackHostVer: string;
  Parsed: TParsedManifest;
  ResolvedCfg: TResolvedManifest;
  ForTestFlag, LoadedFromManifest, DummyAutoInstalled: Boolean;
  I, ErrLine0: Integer;
  PkgOpts: TPackageResolveOptions;
  PkgRes: TPackageResolutionResult;
begin
  AContext := Default(TNikWorkspaceContext);
  AWarningMsg := '';
  EffProfile := Trim(AProfileName);
  if EffProfile = '' then
    EffProfile := 'debug';
  AContext.ProfileName := EffProfile;

  ManifestFile := '';
  try
    ManifestFile := FindManifestNear(ARootDir, AManifestOverride);
  except
    on E: Exception do
      AWarningMsg := E.Message;
  end;

  LoadedFromManifest := False;
  if ManifestFile <> '' then
  begin
    AContext.ManifestPath := ExpandFileName(NormalizeNativeSeparators(ManifestFile));
    AppendArg(AContext.ManifestFiles, AContext.ManifestPath);
    AContext.ProjectDir := ExcludeTrailingPathDelimiter(ExtractFileDir(AContext.ManifestPath));
    try
      Parsed := LoadManifestFile(AContext.ManifestPath);
      AContext.HasManifest := True;
      AContext.ManifestKind := Parsed.Kind;

      ForTestFlag := AForTest or ((Parsed.Kind = mkPackage) and Parsed.HasTest);

      // Pre-validate manifest resolution (reports line-numbered missing entry / toolchain.fpc before SDK lookup)
      ResolvedCfg := ResolveManifestConfig(
        Parsed, EffProfile, GetHostCpu, GetHostOs, ForTestFlag, Parsed.Kind <> mkPackage
      );

      if (Trim(ResolvedCfg.FpcSpec) = '') and TryDetectInstalledHostVersion(FallbackHostVer) then
        ResolvedCfg.FpcSpec := FallbackHostVer;
      // Never auto-install SDKs silently inside nik lsp (AutoInstallSdk = False, Offline = True)
      AContext.Sdk := ResolveProjectSdk(
        ResolvedCfg.FpcSpec, ResolvedCfg.TargetSpec,
        False, True, True, DummyAutoInstalled
      );
      ResolvedCfg := ResolveManifestConfig(
        Parsed, EffProfile,
        AContext.Sdk.Manifest.TargetCpu, AContext.Sdk.Manifest.TargetOs, ForTestFlag,
        Parsed.Kind <> mkPackage
      );

      if Trim(ResolvedCfg.Entry) <> '' then
        AContext.EntryPath := ResolveRelativePath(AContext.ProjectDir, ResolvedCfg.Entry);

      AContext.Mode := ResolvedCfg.Mode;
      AContext.ModeSwitches := ResolvedCfg.ModeSwitches;
      AContext.LongStrings := ResolvedCfg.LongStrings;
      AContext.Defines := ResolvedCfg.Defines;
      AContext.Undefines := ResolvedCfg.Undefines;

      if AContext.EntryPath <> '' then
        AppendUniqueDir(AContext.UnitPaths, ExtractFileDir(AContext.EntryPath));
      for I := 0 to High(ResolvedCfg.UnitPaths) do
        AppendUniqueDir(AContext.UnitPaths, ResolveRelativePath(AContext.ProjectDir, ResolvedCfg.UnitPaths[I]));
      for I := 0 to High(ResolvedCfg.IncludePaths) do
        AppendUniqueDir(AContext.IncludePaths, ResolveRelativePath(AContext.ProjectDir, ResolvedCfg.IncludePaths[I]));

      // Resolve direct & transitive local/cached packages non-blockingly (never stall LSP on network I/O)
      PkgOpts := Default(TPackageResolveOptions);
      PkgOpts.Offline := True;
      PkgOpts.AllowLockWrite := False;
      PkgOpts.SoftMissingForLsp := True;
      PkgOpts.IncludeTestDeps := ForTestFlag;
      try
        PkgRes := ResolveProjectPackages(
          Parsed, ResolvedCfg,
          AContext.Sdk.Manifest.TargetCpu, AContext.Sdk.Manifest.TargetOs,
          PkgOpts
        );
        for I := 0 to High(PkgRes.UnitPaths) do
          AppendUniqueDir(AContext.UnitPaths, PkgRes.UnitPaths[I]);
        for I := 0 to High(PkgRes.IncludePaths) do
          AppendUniqueDir(AContext.IncludePaths, PkgRes.IncludePaths[I]);
        for I := 0 to High(PkgRes.ManifestFiles) do
          AppendArg(AContext.ManifestFiles, PkgRes.ManifestFiles[I]);

        if Length(PkgRes.MissingPackages) > 0 then
          AWarningMsg := Format(
            'Uncached dependencies (%s) — run ''nik pkg fetch'' or ''nik build'' to populate ~/.nikrun/cache/pkg.',
            [PkgRes.MissingPackages[0]]);
      except
        on E: Exception do
          AWarningMsg := E.Message;
      end;

      LoadedFromManifest := True;
    except
      on E: Exception do
      begin
        ParseManifestExceptionLocation(AContext.ManifestPath, E.Message, ErrLine0, CleanErr);
        AContext.HasManifestError := True;
        AContext.ManifestErrorLine := ErrLine0;
        AContext.ManifestErrorMessage := CleanErr;
        AWarningMsg := E.Message;
      end;
    end;
  end;

  if not LoadedFromManifest then
  begin
    if AWarningMsg = '' then
      AWarningMsg := 'No nik.yaml found in workspace (run ''nik init'' to configure toolchain and build settings).';
    Exit(False);
  end;

  try
    AContext.SdkBinDir := JoinPath(AContext.Sdk.InstallPath, AContext.Sdk.Manifest.Paths.BinDir);
    AContext.CompilerBinary := JoinPath(AContext.Sdk.InstallPath, AContext.Sdk.Manifest.Paths.PpcBinary);
    AContext.FpcCfgPath := JoinPath(AContext.SdkBinDir, 'fpc.cfg');
    if not FileExists(AContext.FpcCfgPath) then
      AContext.FpcCfgPath := GenerateFpcCfgForSdk(AContext.Sdk.InstallPath, AContext.Sdk.Manifest);

    if AContext.Sdk.Manifest.Paths.RtlSourceDir <> '' then
      AContext.RtlSourceDir := JoinPath(AContext.Sdk.InstallPath, AContext.Sdk.Manifest.Paths.RtlSourceDir);
    if AContext.Sdk.Manifest.Paths.PackagesSourceDir <> '' then
      AContext.PackagesSourceDir := JoinPath(AContext.Sdk.InstallPath, AContext.Sdk.Manifest.Paths.PackagesSourceDir);

    AContext.CacheDir := JoinPath(
      JoinPath(JoinPath(AContext.ProjectDir, '.nik'), 'cache'),
      SanitizeCacheKey(AContext.Sdk.Manifest.SdkId + '-' + AContext.ProfileName + '-lsp' +
        IfThen(AForTest, '-test', ''))
    );
    AContext.ConfigFingerprint := ComputeLspContextFingerprint(AContext);
    Result := FileExists(AContext.CompilerBinary);
  except
    on E: Exception do
    begin
      if AWarningMsg = '' then
        AWarningMsg := E.Message;
      Result := False;
    end;
  end;
end;

function ResolveLspWorkspace(const ARootDir, AManifestOverride, AProfileName: string;
  out AContext: TNikWorkspaceContext; out AWarningMsg: string): Boolean;
begin
  Result := ResolveLspWorkspaceCore(ARootDir, AManifestOverride, AProfileName, False, AContext, AWarningMsg);
end;

function ResolveLspTestWorkspace(const ARootDir, AManifestOverride, AProfileName: string;
  out AContext: TNikWorkspaceContext; out AWarningMsg: string): Boolean;
begin
  Result := ResolveLspWorkspaceCore(ARootDir, AManifestOverride, AProfileName, True, AContext, AWarningMsg);
end;

function IsLspTestDocument(const AFilePath: string): Boolean;
begin
  Result := IsTestUnitFileName(AFilePath);
end;

function MapSeverity(ASev: TDiagSeverity): TLspDiagnosticSeverity;
begin
  case ASev of
    dsFatal, dsError: Result := ldsError;
    dsWarning:        Result := ldsWarning;
    dsNote:           Result := ldsInformation;
    dsHint:           Result := ldsHint;
  else
    raise ENikError.CreateFmt('Unexpected TDiagSeverity ordinal: %d', [Ord(ASev)]);
  end;
end;

function SpawnCompilerProcess(const ACompilerBin, ASdkBinDir, AWorkDir: string;
  const AArgs: TStringArray): TProcess;
var
  I, EnvCount, EqPos: Integer;
  Entry, Key, CurPath, Sep: string;
  PathUpdated: Boolean;
begin
  {$IFDEF WINDOWS}
  Sep := ';';
  {$ELSE}
  Sep := ':';
  {$ENDIF}

  Result := TProcess.Create(nil);
  try
    Result.Executable := ACompilerBin;
    Result.CurrentDirectory := AWorkDir;
    for I := 0 to High(AArgs) do
      Result.Parameters.Add(AArgs[I]);

    PathUpdated := False;
    EnvCount := GetEnvironmentVariableCount;
    for I := 1 to EnvCount do
    begin
      Entry := GetEnvironmentString(I);
      if Entry = '' then
        Continue;
      if Entry[1] = '=' then
      begin
        Result.Environment.Add(Entry);
        Continue;
      end;
      EqPos := Pos('=', Entry);
      if EqPos > 1 then
      begin
        Key := Copy(Entry, 1, EqPos - 1);
        if SameText(Key, 'PATH') then
        begin
          CurPath := Copy(Entry, EqPos + 1, MaxInt);
          if CurPath <> '' then
            Result.Environment.Add(Key + '=' + ASdkBinDir + Sep + CurPath)
          else
            Result.Environment.Add(Key + '=' + ASdkBinDir);
          PathUpdated := True;
          Continue;
        end;
      end;
      Result.Environment.Add(Entry);
    end;
    if not PathUpdated then
      Result.Environment.Add('PATH=' + ASdkBinDir);

    Result.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    Result.Execute;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function IsIdentOrTokenByte(ACh: Char): Boolean; inline;
begin
  Result :=
    ((ACh >= 'A') and (ACh <= 'Z')) or
    ((ACh >= 'a') and (ACh <= 'z')) or
    ((ACh >= '0') and (ACh <= '9')) or
    (ACh = '_') or (ACh = '&') or (ACh = '$');
end;

function ComputeTokenEndByte(const ALineStr: string; ACol1Byte: Integer): Integer;
var
  Len, B: Integer;
begin
  Len := Length(ALineStr);
  if (ACol1Byte < 1) or (ACol1Byte > Len) then
    Exit(ACol1Byte + 1);

  B := ACol1Byte;
  if IsIdentOrTokenByte(ALineStr[B]) then
  begin
    while (B <= Len) and IsIdentOrTokenByte(ALineStr[B]) do
      Inc(B);
    Exit(B);
  end;

  // Highlight non-whitespace operator/punctuation run or fallback to 1 char
  if not (ALineStr[B] in [' ', #9]) then
  begin
    Inc(B);
    Exit(B);
  end;

  Result := Len + 1;
end;

{ TNikAsyncCompilerCheck }

constructor TNikAsyncCompilerCheck.Create(const AOwnerKey, AOwnerUri, AOwnerFilePath, AProjectDir: string;
  const AOverlayEntries: TNikOverlayFileEntryArray; AProc: TProcess);
begin
  inherited Create;
  FOwnerKey := AOwnerKey;
  FOwnerUri := AOwnerUri;
  FOwnerFilePath := AOwnerFilePath;
  FProjectDir := AProjectDir;
  FOverlayEntries := AOverlayEntries;
  FProc := AProc;
  FOutStream := TMemoryStream.Create;
end;

destructor TNikAsyncCompilerCheck.Destroy;
begin
  Abort;
  FreeAndNil(FProc);
  FreeAndNil(FOutStream);
  inherited Destroy;
end;

procedure TNikAsyncCompilerCheck.DrainAvailableOutput;
var
  Buf: array[0..4095] of Byte;
  BytesRead: LongInt;
begin
  if (FProc = nil) or (FProc.Output = nil) then
    Exit;

  while FProc.Output.NumBytesAvailable > 0 do
  begin
    BytesRead := FProc.Output.Read(Buf[0], SizeOf(Buf));
    if BytesRead > 0 then
      FOutStream.WriteBuffer(Buf[0], BytesRead)
    else
      Break;
  end;
end;

function TNikAsyncCompilerCheck.PollFinished: Boolean;
var
  Buf: array[0..4095] of Byte;
  BytesRead: LongInt;
begin
  if FProc = nil then
    Exit(True);

  DrainAvailableOutput;
  if FProc.Running then
    Exit(False);

  // Process has exited: drain any final buffered bytes from stdout/stderr pipe
  if FProc.Output <> nil then
  begin
    repeat
      BytesRead := FProc.Output.Read(Buf[0], SizeOf(Buf));
      if BytesRead > 0 then
        FOutStream.WriteBuffer(Buf[0], BytesRead);
    until BytesRead <= 0;
  end;
  Result := True;
end;

function TNikAsyncCompilerCheck.WaitUntilFinished(AMaxWaitMs: Integer): Boolean;
var
  StartTick: QWord;
begin
  StartTick := GetTickCount64;
  while not PollFinished do
  begin
    if (AMaxWaitMs >= 0) and ((GetTickCount64 - StartTick) >= QWord(AMaxWaitMs)) then
      Exit(False);
    Sleep(5);
  end;
  Result := True;
end;

procedure TNikAsyncCompilerCheck.Abort;
begin
  if (FProc <> nil) and FProc.Running then
  begin
    try
      FProc.Terminate(0);
    except
      // Ignore termination errors if child already exited concurrently
    end;
  end;
end;

function TNikAsyncCompilerCheck.MapOverlayPathToRealPath(const ADiagFilePath: string;
  out AClientUri: string): string;
var
  SlashLower, Suffix, BaseName: string;
  I, MatchIdx, MatchCount: Integer;
begin
  AClientUri := '';
  Result := ADiagFilePath;
  if ADiagFilePath = '' then
    Exit;

  SlashLower := ToForwardSlashLower(ADiagFilePath);
  for I := 0 to High(FOverlayEntries) do
  begin
    if SameFilePathNative(ADiagFilePath, FOverlayEntries[I].OverlayPath) then
    begin
      AClientUri := FOverlayEntries[I].ClientUri;
      Exit(FOverlayEntries[I].OrigPath);
    end;

    Suffix := FOverlayEntries[I].RelSlashSuffix;
    if (Suffix <> '') and (Length(SlashLower) >= Length(Suffix)) and
       (Copy(SlashLower, Length(SlashLower) - Length(Suffix) + 1, Length(Suffix)) = Suffix) then
    begin
      AClientUri := FOverlayEntries[I].ClientUri;
      Exit(FOverlayEntries[I].OrigPath);
    end;
  end;

  // Fallback when FPC omits directory paths on module-level fatal lines (e.g. bare 'OrderDomain.pas')
  if not FileExists(Result) then
  begin
    BaseName := ExtractFileName(ADiagFilePath);
    if BaseName <> '' then
    begin
      if (FOwnerFilePath <> '') and SameText(BaseName, ExtractFileName(FOwnerFilePath)) then
      begin
        AClientUri := FOwnerUri;
        Exit(FOwnerFilePath);
      end;
      MatchIdx := -1;
      MatchCount := 0;
      for I := 0 to High(FOverlayEntries) do
        if SameText(BaseName, ExtractFileName(FOverlayEntries[I].OrigPath)) then
        begin
          MatchIdx := I;
          Inc(MatchCount);
        end;
      if MatchCount = 1 then
      begin
        AClientUri := FOverlayEntries[MatchIdx].ClientUri;
        Exit(FOverlayEntries[MatchIdx].OrigPath);
      end;
    end;
  end;
end;

function TNikAsyncCompilerCheck.CollectDiagnostics(ADocStore: TLspDocumentStore): TNikFileDiagnosticsArray;
var
  Buckets: TNikFileDiagnosticsArray;
  RawBytes: RawByteString;
  RawOut, RealPath, OverlayClientUri, DiagUri, DiagKey, LineStr: string;
  Parsed: TParsedCompilerOutput;
  I, BucketIdx, Line0, Col1Byte, EndByte1, Col0, EndCol0: Integer;
  D: TCompilerDiagnostic;
  LspD: TLspDiagnostic;
  OpenDoc: TLspDocument;

  function FindOrAddBucket(const ANormKey, AUri: string): Integer;
  var
    K: Integer;
  begin
    for K := 0 to High(Buckets) do
      if Buckets[K].NormalizedKey = ANormKey then
        Exit(K);
    Result := Length(Buckets);
    SetLength(Buckets, Result + 1);
    Buckets[Result].NormalizedKey := ANormKey;
    Buckets[Result].Uri := AUri;
    Buckets[Result].Diagnostics := nil;
  end;

begin
  Result := nil;
  Buckets := nil;

  RawBytes := '';
  SetLength(RawBytes, FOutStream.Size);
  if FOutStream.Size > 0 then
  begin
    FOutStream.Position := 0;
    FOutStream.ReadBuffer(RawBytes[1], FOutStream.Size);
  end;
  RawOut := string(RawBytes);

  Parsed := ParseFpcCompilerOutput(RawOut, FProjectDir);
  for I := 0 to High(Parsed.Diagnostics) do
  begin
    D := Parsed.Diagnostics[I];
    if D.FilePath = '' then
      Continue;
    // Suppress redundant FPC stop-summary line ("There were N errors compiling module, stopping")
    if (D.Code = 10026) and (Length(Parsed.Diagnostics) > 1) then
      Continue;

    RealPath := MapOverlayPathToRealPath(D.FilePath, OverlayClientUri);

    OpenDoc := nil;
    if ADocStore <> nil then
    begin
      if OverlayClientUri <> '' then
        OpenDoc := ADocStore.FindDocument(OverlayClientUri);
      if OpenDoc = nil then
        OpenDoc := ADocStore.FindByFilePath(RealPath);
    end;

    // Always prefer the exact client-supplied URI when the document is open in the editor
    if OpenDoc <> nil then
      DiagUri := OpenDoc.Uri
    else if OverlayClientUri <> '' then
      DiagUri := OverlayClientUri
    else
      DiagUri := FilePathToUri(RealPath);

    DiagKey := LowerCase(NormalizeDocumentUri(DiagUri));

    Line0 := D.Line - 1;
    if Line0 < 0 then
      Line0 := 0;

    Col1Byte := D.Column;
    if Col1Byte < 1 then
      Col1Byte := 1;

    if OpenDoc <> nil then
    begin
      LineStr := OpenDoc.GetLineText(Line0);
      Col0 := ByteIndexToUtf16Col(LineStr, Col1Byte);
      EndByte1 := ComputeTokenEndByte(LineStr, Col1Byte);
      EndCol0 := ByteIndexToUtf16Col(LineStr, EndByte1);
      if EndCol0 <= Col0 then
        EndCol0 := Col0 + 1;
    end
    else
    begin
      Col0 := Col1Byte - 1;
      if Col0 < 0 then
        Col0 := 0;
      EndCol0 := Col0 + 1;
    end;

    LspD := Default(TLspDiagnostic);
    LspD.Range := TLspRange.SingleLine(Line0, Col0, EndCol0);
    LspD.Severity := MapSeverity(D.Severity);
    if D.Code > 0 then
    begin
      LspD.HasCode := True;
      LspD.IntCode := D.Code;
    end;
    LspD.Source := 'fpc';
    LspD.Message := D.Message;

    BucketIdx := FindOrAddBucket(DiagKey, DiagUri);
    SetLength(Buckets[BucketIdx].Diagnostics, Length(Buckets[BucketIdx].Diagnostics) + 1);
    Buckets[BucketIdx].Diagnostics[High(Buckets[BucketIdx].Diagnostics)] := LspD;
  end;

  Result := Buckets;
end;

function StartAsyncLspCompilerCheck(const AContext: TNikWorkspaceContext;
  const AOwnerUri, AActiveFilePath: string;
  ADocStore: TLspDocumentStore): TNikAsyncCompilerCheck;
var
  OverlayEntries: TNikOverlayFileEntryArray;
  OverlayDirs, IncludeDirs, UnitDirs, Args: TStringArray;
  TargetFile, ActiveOrigPath, EffectiveOwnerUri, OwnerKey: string;
  I: Integer;
  Proc: TProcess;
begin
  Result := nil;
  if (AContext.CompilerBinary = '') or (not FileExists(AContext.CompilerBinary)) then
    Exit;

  EnsureDirExists(AContext.CacheDir);
  EnsureFreshLspCompilerCache(AContext);
  SyncOpenDocumentsOverlay(AContext, ADocStore, OverlayEntries);

  TargetFile := '';
  ActiveOrigPath := '';
  if Trim(AActiveFilePath) <> '' then
    ActiveOrigPath := ExpandFileName(NormalizeNativeSeparators(AActiveFilePath));

  // 1. Prefer checking the active compilable Pascal unit/program (using its live overlay buffer if open)
  if (ActiveOrigPath <> '') and IsCompilableMainOrUnitExt(ActiveOrigPath) then
  begin
    for I := 0 to High(OverlayEntries) do
      if SameFilePathNative(ActiveOrigPath, OverlayEntries[I].OrigPath) then
      begin
        TargetFile := OverlayEntries[I].OverlayPath;
        Break;
      end;
    if (TargetFile = '') and FileExists(ActiveOrigPath) then
      TargetFile := ActiveOrigPath;
  end;

  // 2. Fallback to EntryPath (e.g. when editing an .inc include file)
  if (TargetFile = '') and (AContext.EntryPath <> '') then
  begin
    for I := 0 to High(OverlayEntries) do
      if SameFilePathNative(AContext.EntryPath, OverlayEntries[I].OrigPath) then
      begin
        TargetFile := OverlayEntries[I].OverlayPath;
        Break;
      end;
    if (TargetFile = '') and FileExists(AContext.EntryPath) then
      TargetFile := AContext.EntryPath;
  end;

  if TargetFile = '' then
    Exit;

  OverlayDirs := nil;
  IncludeDirs := nil;
  UnitDirs := nil;
  for I := 0 to High(OverlayEntries) do
    AppendUniqueDir(OverlayDirs, ExtractFileDir(OverlayEntries[I].OverlayPath));

  // Overlay directories MUST precede disk directories so unsaved open units/includes win resolution
  for I := 0 to High(OverlayDirs) do
  begin
    AppendUniqueDir(IncludeDirs, OverlayDirs[I]);
    AppendUniqueDir(UnitDirs, OverlayDirs[I]);
  end;

  AppendUniqueDir(IncludeDirs, ExtractFileDir(TargetFile));
  AppendUniqueDir(UnitDirs, ExtractFileDir(TargetFile));
  if ActiveOrigPath <> '' then
  begin
    AppendUniqueDir(IncludeDirs, ExtractFileDir(ActiveOrigPath));
    AppendUniqueDir(UnitDirs, ExtractFileDir(ActiveOrigPath));
  end;

  for I := 0 to High(AContext.IncludePaths) do
    AppendUniqueDir(IncludeDirs, AContext.IncludePaths[I]);
  for I := 0 to High(AContext.UnitPaths) do
    AppendUniqueDir(UnitDirs, AContext.UnitPaths[I]);

  Args := nil;
  AppendArg(Args, '-n');
  AppendArg(Args, '@' + AContext.FpcCfgPath);
  AppendArg(Args, '-Cn');
  AppendArg(Args, '-vq');
  AppendArg(Args, '-viwn');
  AppendArg(Args, '-vb');
  AppendArg(Args, '-l-');

  if AContext.Mode <> '' then
    AppendArg(Args, '-M' + AContext.Mode);
  for I := 0 to High(AContext.ModeSwitches) do
    AppendArg(Args, '-M' + AContext.ModeSwitches[I]);
  if AContext.LongStrings then
    AppendArg(Args, '-Sh')
  else
    AppendArg(Args, '-Sh-');

  for I := 0 to High(AContext.Undefines) do
    AppendArg(Args, '-u' + AContext.Undefines[I]);
  for I := 0 to High(AContext.Defines) do
    AppendArg(Args, '-d' + AContext.Defines[I]);

  for I := 0 to High(IncludeDirs) do
    AppendArg(Args, '-Fi' + IncludeDirs[I]);
  for I := 0 to High(UnitDirs) do
    AppendArg(Args, '-Fu' + UnitDirs[I]);

  AppendArg(Args, '-FU' + AContext.CacheDir);
  AppendArg(Args, '-FE' + AContext.CacheDir);
  AppendArg(Args, TargetFile);

  EffectiveOwnerUri := AOwnerUri;
  if (EffectiveOwnerUri = '') and (ActiveOrigPath <> '') then
    EffectiveOwnerUri := FilePathToUri(ActiveOrigPath);
  if EffectiveOwnerUri = '' then
    EffectiveOwnerUri := FilePathToUri(TargetFile);
  OwnerKey := LowerCase(NormalizeDocumentUri(EffectiveOwnerUri));

  Proc := SpawnCompilerProcess(
    AContext.CompilerBinary, AContext.SdkBinDir, AContext.ProjectDir, Args
  );
  Result := TNikAsyncCompilerCheck.Create(
    OwnerKey, EffectiveOwnerUri, ActiveOrigPath, AContext.ProjectDir, OverlayEntries, Proc
  );
end;

function RunLspSyntaxAndSemanticCheck(const AContext: TNikWorkspaceContext;
  const AActiveFilePath: string; ADocStore: TLspDocumentStore): TNikFileDiagnosticsArray;
var
  OwnerUri: string;
  OpenDoc: TLspDocument;
  Runner: TNikAsyncCompilerCheck;
begin
  Result := nil;
  OwnerUri := '';
  if (ADocStore <> nil) and (AActiveFilePath <> '') then
  begin
    OpenDoc := ADocStore.FindByFilePath(AActiveFilePath);
    if OpenDoc <> nil then
      OwnerUri := OpenDoc.Uri;
  end;
  if (OwnerUri = '') and (AActiveFilePath <> '') then
    OwnerUri := FilePathToUri(AActiveFilePath);

  Runner := StartAsyncLspCompilerCheck(AContext, OwnerUri, AActiveFilePath, ADocStore);
  if Runner = nil then
    Exit;
  try
    Runner.WaitUntilFinished(30000);
    Result := Runner.CollectDiagnostics(ADocStore);
  finally
    Runner.Free;
  end;
end;

end.
