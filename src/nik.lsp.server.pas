unit nik.lsp.server;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  nik.types,
  nik.lsp.index, nik.lsp.check,
  nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.utf16,
  nikrun.lsp.transport, nikrun.lsp.documents, nikrun.lsp.server;

const
  LSP_CHANGE_DEBOUNCE_MS = 250;
  LSP_ASYNC_POLL_MS      = 15;

type
  TNikQueuedValidation = record
    NormalizedKey: string;
    Uri: string;
    FilePath: string;
  end;

  TNikDocDiagReport = class
  public
    Seq: QWord;
    OwnerKey: string;
    OwnerUri: string;
    Targets: TNikFileDiagnosticsArray;
    function FindTargetIndex(const ATargetKey: string): Integer;
  end;

  TNikPascalLspServer = class(TLspServer)
  private
    FManifestOverride: string;
    FProfileName: string;
    FWorkspaceReady: Boolean;
    FWorkspace: TNikWorkspaceContext;
    FIndex: TNikSymbolIndex;

    FPublishedManifestUri: string;
    FReports: TFPList; // Owns TNikDocDiagReport instances
    FLastReportSeq: QWord;

    FActiveCheck: TNikAsyncCompilerCheck;
    FHasPendingDebounce: Boolean;
    FDebounceKey: string;
    FDebounceUri: string;
    FDebounceFilePath: string;
    FDebounceDeadlineMs: QWord;
    FPendingQueue: array of TNikQueuedValidation;

    function DetermineWorkspaceRootDir: string;
    function IsManifestFilePath(const AFilePath: string): Boolean;
    function IsPascalDocFilePath(const AFilePath: string): Boolean;
    function ResolvePreferredClientUri(const ANormKey, AFallbackUri: string): string;

    procedure ClearReports;
    function FindReportIndex(const AOwnerKey: string): Integer;
    function ShownDiagnosticsForKey(const ATargetKey: string; out AOutUri: string): TLspDiagnosticArray;
    procedure ApplyCompletedCheckReport(const AOwnerKey, AOwnerUri: string;
      const ABatches: TNikFileDiagnosticsArray);

    procedure RemoveFromPendingQueue(const ANormKey: string);
    procedure EnqueueValidation(const AUri, AFilePath: string; AFront: Boolean = False);
    procedure EnqueueUsersOfUnit(const AModifiedUri, AModifiedFilePath: string);
    procedure EnqueueAllOpenPascalDocuments;
    procedure StartNextQueuedCheck;
    procedure CompleteActiveCheck;
    procedure ScheduleImmediateValidation(const AUri, AFilePath: string);
    procedure ScheduleDebouncedValidation(const AUri, AFilePath: string);

    procedure ReloadWorkspaceConfiguration;
    procedure EnsureIndexedDoc(const AUri: string; ADoc: TLspDocument);
    function ResolveDocFilePath(const AUri: string; ADoc: TLspDocument): string;
  protected
    procedure ConfigureCapabilities(const AParams: TLspInitializeParams;
      var ACaps: TLspServerCapabilities); override;
    procedure DoInitialized; override;
    procedure DoShutdown; override;

    procedure DoDidOpen(ADoc: TLspDocument); override;
    procedure DoDidChange(ADoc: TLspDocument); override;
    procedure DoDidSave(ADoc: TLspDocument; const AHasSavedText: Boolean; const ASavedText: string); override;
    procedure DoDidClose(const AUri, AFilePath: string); override;
    procedure DoDidChangeWatchedFiles(const AChanges: TLspFileEventArray); override;

    function GetIdleTickTimeoutMs: Integer; override;
    procedure DoIdleTick; override;

    function DoDocumentSymbol(const AUri: string; ADoc: TLspDocument): TLspDocumentSymbolArray; override;
    function DoWorkspaceSymbol(const AQuery: string): TLspSymbolInformationArray; override;
    function DoDefinition(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspLocationArray; override;
    function DoDeclaration(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspLocationArray; override;
    function DoHover(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspHover; override;
    function DoCompletion(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition; const ATriggerChar: string): TLspCompletionList; override;
    function DoSignatureHelp(const AUri: string; ADoc: TLspDocument;
      const APos: TLspPosition; const ATriggerChar: string): TLspSignatureHelp; override;
  public
    constructor Create(ATransport: TLspTransport; const AManifestOverride, AProfileName: string;
      AOwnsTransport: Boolean = True);
    destructor Destroy; override;
  end;

implementation

{ TNikDocDiagReport }

function TNikDocDiagReport.FindTargetIndex(const ATargetKey: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Targets) do
    if Targets[I].NormalizedKey = ATargetKey then
      Exit(I);
  Result := -1;
end;

{ TNikPascalLspServer }

constructor TNikPascalLspServer.Create(ATransport: TLspTransport;
  const AManifestOverride, AProfileName: string; AOwnsTransport: Boolean);
begin
  inherited Create(ATransport, AOwnsTransport);
  FManifestOverride := AManifestOverride;
  FProfileName := Trim(AProfileName);
  if FProfileName = '' then
    FProfileName := 'debug';
  FWorkspaceReady := False;
  FIndex := TNikSymbolIndex.Create;
  FReports := TFPList.Create;
  FLastReportSeq := 0;
  FActiveCheck := nil;
  FHasPendingDebounce := False;
  FPendingQueue := nil;
end;

destructor TNikPascalLspServer.Destroy;
begin
  FreeAndNil(FActiveCheck);
  ClearReports;
  FreeAndNil(FReports);
  FreeAndNil(FIndex);
  inherited Destroy;
end;

procedure TNikPascalLspServer.ClearReports;
var
  I: Integer;
begin
  if FReports = nil then
    Exit;
  for I := 0 to FReports.Count - 1 do
    TObject(FReports[I]).Free;
  FReports.Clear;
end;

function TNikPascalLspServer.FindReportIndex(const AOwnerKey: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FReports.Count - 1 do
    if TNikDocDiagReport(FReports[I]).OwnerKey = AOwnerKey then
      Exit(I);
  Result := -1;
end;

function TNikPascalLspServer.ResolvePreferredClientUri(const ANormKey, AFallbackUri: string): string;
var
  I, TIdx: Integer;
  OpenDoc: TLspDocument;
  Rep: TNikDocDiagReport;
begin
  for I := 0 to Documents.Count - 1 do
  begin
    OpenDoc := Documents[I];
    if (OpenDoc <> nil) and (OpenDoc.NormalizedKey = ANormKey) then
      Exit(OpenDoc.Uri);
  end;

  for I := 0 to FReports.Count - 1 do
  begin
    Rep := TNikDocDiagReport(FReports[I]);
    if (Rep.OwnerKey = ANormKey) and (Rep.OwnerUri <> '') then
      Exit(Rep.OwnerUri);
    TIdx := Rep.FindTargetIndex(ANormKey);
    if (TIdx >= 0) and (Rep.Targets[TIdx].Uri <> '') then
      Exit(Rep.Targets[TIdx].Uri);
  end;

  Result := AFallbackUri;
end;

function TNikPascalLspServer.ShownDiagnosticsForKey(const ATargetKey: string;
  out AOutUri: string): TLspDiagnosticArray;
var
  OwnIdx, I, TIdx: Integer;
  Rep: TNikDocDiagReport;
  NewestSeq: QWord;
  FallbackUri: string;
begin
  Result := nil;
  FallbackUri := '';

  // 1. An open document's own report always governs its own diagnostics
  OwnIdx := FindReportIndex(ATargetKey);
  if OwnIdx >= 0 then
  begin
    Rep := TNikDocDiagReport(FReports[OwnIdx]);
    FallbackUri := Rep.OwnerUri;
    TIdx := Rep.FindTargetIndex(ATargetKey);
    if TIdx >= 0 then
    begin
      Result := Rep.Targets[TIdx].Diagnostics;
      if Rep.Targets[TIdx].Uri <> '' then
        FallbackUri := Rep.Targets[TIdx].Uri;
    end;
    AOutUri := ResolvePreferredClientUri(ATargetKey, FallbackUri);
    Exit;
  end;

  // 2. Otherwise show diagnostics from the newest open-document report that touched ATargetKey
  NewestSeq := 0;
  for I := 0 to FReports.Count - 1 do
  begin
    Rep := TNikDocDiagReport(FReports[I]);
    TIdx := Rep.FindTargetIndex(ATargetKey);
    if (TIdx >= 0) and (Rep.Seq > NewestSeq) then
    begin
      NewestSeq := Rep.Seq;
      Result := Rep.Targets[TIdx].Diagnostics;
      FallbackUri := Rep.Targets[TIdx].Uri;
    end;
  end;
  AOutUri := ResolvePreferredClientUri(ATargetKey, FallbackUri);
end;

procedure TNikPascalLspServer.ApplyCompletedCheckReport(const AOwnerKey, AOwnerUri: string;
  const ABatches: TNikFileDiagnosticsArray);
var
  Affected: TStringList;
  UriByKey: TStringList;
  RepIdx, I, OutCount, DummyIdx: Integer;
  Rep: TNikDocDiagReport;
  OwnerPresent: Boolean;
  Key, TargetUri: string;
  Diags: TLspDiagnosticArray;

  procedure AddAffected(const AKey, AUri: string);
  begin
    if AKey = '' then
      Exit;
    if not Affected.Find(AKey, DummyIdx) then
    begin
      Affected.Add(AKey);
      if AUri <> '' then
        UriByKey.Values[AKey] := AUri;
    end
    else if (AUri <> '') and (UriByKey.Values[AKey] = '') then
      UriByKey.Values[AKey] := AUri;
  end;

begin
  if AOwnerKey = '' then
    Exit;

  Affected := TStringList.Create;
  UriByKey := TStringList.Create;
  try
    Affected.Sorted := True;
    Affected.Duplicates := dupIgnore;

    AddAffected(AOwnerKey, ResolvePreferredClientUri(AOwnerKey, AOwnerUri));

    RepIdx := FindReportIndex(AOwnerKey);
    if RepIdx >= 0 then
    begin
      Rep := TNikDocDiagReport(FReports[RepIdx]);
      for I := 0 to High(Rep.Targets) do
        AddAffected(Rep.Targets[I].NormalizedKey, Rep.Targets[I].Uri);
    end
    else
    begin
      Rep := TNikDocDiagReport.Create;
      Rep.OwnerKey := AOwnerKey;
      FReports.Add(Rep);
    end;

    for I := 0 to High(ABatches) do
      AddAffected(ABatches[I].NormalizedKey, ABatches[I].Uri);

    Inc(FLastReportSeq);
    Rep.Seq := FLastReportSeq;
    Rep.OwnerUri := ResolvePreferredClientUri(AOwnerKey, AOwnerUri);

    // Build Rep.Targets ensuring OwnerKey is ALWAYS present (with empty diagnostics when clean)
    OwnerPresent := False;
    for I := 0 to High(ABatches) do
      if ABatches[I].NormalizedKey = AOwnerKey then
      begin
        OwnerPresent := True;
        Break;
      end;

    if OwnerPresent then
      SetLength(Rep.Targets, Length(ABatches))
    else
      SetLength(Rep.Targets, Length(ABatches) + 1);

    OutCount := 0;
    if not OwnerPresent then
    begin
      Rep.Targets[0].NormalizedKey := AOwnerKey;
      Rep.Targets[0].Uri := Rep.OwnerUri;
      Rep.Targets[0].Diagnostics := nil;
      OutCount := 1;
    end;

    for I := 0 to High(ABatches) do
    begin
      Rep.Targets[OutCount].NormalizedKey := ABatches[I].NormalizedKey;
      Rep.Targets[OutCount].Uri := ResolvePreferredClientUri(ABatches[I].NormalizedKey, ABatches[I].Uri);
      Rep.Targets[OutCount].Diagnostics := ABatches[I].Diagnostics;
      Inc(OutCount);
    end;

    for I := 0 to Affected.Count - 1 do
    begin
      Key := Affected[I];
      Diags := ShownDiagnosticsForKey(Key, TargetUri);
      if TargetUri = '' then
        TargetUri := UriByKey.Values[Key];
      if TargetUri <> '' then
        PublishDiagnostics(TargetUri, Diags);
    end;
  finally
    UriByKey.Free;
    Affected.Free;
  end;
end;

procedure TNikPascalLspServer.RemoveFromPendingQueue(const ANormKey: string);
var
  I, WriteIdx: Integer;
begin
  if (ANormKey = '') or (Length(FPendingQueue) = 0) then
    Exit;
  WriteIdx := 0;
  for I := 0 to High(FPendingQueue) do
    if FPendingQueue[I].NormalizedKey <> ANormKey then
    begin
      if WriteIdx <> I then
        FPendingQueue[WriteIdx] := FPendingQueue[I];
      Inc(WriteIdx);
    end;
  SetLength(FPendingQueue, WriteIdx);
end;

procedure TNikPascalLspServer.EnqueueValidation(const AUri, AFilePath: string; AFront: Boolean);
var
  Key: string;
  N, I: Integer;
  Item: TNikQueuedValidation;
begin
  if (AUri = '') and (AFilePath = '') then
    Exit;
  if AUri <> '' then
    Key := LowerCase(NormalizeDocumentUri(AUri))
  else
    Key := LowerCase(NormalizeDocumentUri(FilePathToUri(AFilePath)));

  RemoveFromPendingQueue(Key);

  Item.NormalizedKey := Key;
  if AUri <> '' then
    Item.Uri := AUri
  else
    Item.Uri := FilePathToUri(AFilePath);
  Item.FilePath := AFilePath;

  N := Length(FPendingQueue);
  SetLength(FPendingQueue, N + 1);
  if AFront and (N > 0) then
  begin
    for I := N downto 1 do
      FPendingQueue[I] := FPendingQueue[I - 1];
    FPendingQueue[0] := Item;
  end
  else
    FPendingQueue[N] := Item;
end;

procedure TNikPascalLspServer.EnqueueUsersOfUnit(const AModifiedUri, AModifiedFilePath: string);
var
  ModKey, UnitLower, Ext: string;
  Indexed: TPasIndexedFile;
  I: Integer;
  Doc: TLspDocument;
begin
  ModKey := LowerCase(NormalizeDocumentUri(AModifiedUri));
  Ext := LowerCase(ExtractFileExt(AModifiedFilePath));
  UnitLower := '';
  Indexed := FIndex.FindFileByUri(AModifiedUri);
  if (Indexed <> nil) and (Indexed.ModuleNameLower <> '') then
    UnitLower := Indexed.ModuleNameLower
  else if AModifiedFilePath <> '' then
    UnitLower := LowerCase(ChangeFileExt(ExtractFileName(AModifiedFilePath), ''));

  for I := 0 to Documents.Count - 1 do
  begin
    Doc := Documents[I];
    if (Doc = nil) or (Doc.NormalizedKey = ModKey) or (not IsPascalDocFilePath(Doc.FilePath)) then
      Continue;
    if (Ext = '.inc') or ((UnitLower <> '') and FIndex.DoesFileUseUnit(Doc.Uri, Doc.FilePath, UnitLower)) then
      EnqueueValidation(Doc.Uri, Doc.FilePath, False);
  end;
end;

procedure TNikPascalLspServer.EnqueueAllOpenPascalDocuments;
var
  I: Integer;
  Doc: TLspDocument;
begin
  for I := 0 to Documents.Count - 1 do
  begin
    Doc := Documents[I];
    if (Doc <> nil) and IsPascalDocFilePath(Doc.FilePath) then
      EnqueueValidation(Doc.Uri, Doc.FilePath, False);
  end;
end;

procedure TNikPascalLspServer.StartNextQueuedCheck;
var
  NextItem: TNikQueuedValidation;
  I: Integer;
begin
  if (not FWorkspaceReady) or (FActiveCheck <> nil) then
    Exit;

  while Length(FPendingQueue) > 0 do
  begin
    NextItem := FPendingQueue[0];
    for I := 0 to High(FPendingQueue) - 1 do
      FPendingQueue[I] := FPendingQueue[I + 1];
    SetLength(FPendingQueue, Length(FPendingQueue) - 1);

    try
      FActiveCheck := StartAsyncLspCompilerCheck(
        FWorkspace,
        ResolvePreferredClientUri(NextItem.NormalizedKey, NextItem.Uri),
        NextItem.FilePath,
        Documents
      );
      if FActiveCheck <> nil then
        Exit;
    except
      on E: Exception do
      begin
        FreeAndNil(FActiveCheck);
        SendLogMessage(lmtWarning, 'Background compiler check failed to start: ' + E.Message);
      end;
    end;
  end;
end;

procedure TNikPascalLspServer.CompleteActiveCheck;
var
  FinishedCheck: TNikAsyncCompilerCheck;
  Batches: TNikFileDiagnosticsArray;
begin
  if FActiveCheck = nil then
    Exit;

  FinishedCheck := FActiveCheck;
  FActiveCheck := nil;
  try
    Batches := FinishedCheck.CollectDiagnostics(Documents);
    // Only apply report if the owner document is still open (or if it resolved via EntryPath)
    if (Documents.FindDocument(FinishedCheck.OwnerUri) <> nil) or
       (FindReportIndex(FinishedCheck.OwnerKey) >= 0) then
      ApplyCompletedCheckReport(FinishedCheck.OwnerKey, FinishedCheck.OwnerUri, Batches);
  finally
    FinishedCheck.Free;
  end;
end;

procedure TNikPascalLspServer.ScheduleImmediateValidation(const AUri, AFilePath: string);
var
  Key: string;
begin
  if not FWorkspaceReady then
    Exit;

  Key := LowerCase(NormalizeDocumentUri(AUri));
  if FHasPendingDebounce and (FDebounceKey = Key) then
    FHasPendingDebounce := False;

  if (FActiveCheck <> nil) and (FActiveCheck.OwnerKey = Key) then
    FreeAndNil(FActiveCheck);

  EnqueueValidation(AUri, AFilePath, True);
  StartNextQueuedCheck;
end;

procedure TNikPascalLspServer.ScheduleDebouncedValidation(const AUri, AFilePath: string);
var
  Key: string;
begin
  if not FWorkspaceReady then
    Exit;

  Key := LowerCase(NormalizeDocumentUri(AUri));

  // Cancel obsolete in-flight compiler process for this exact document immediately
  if (FActiveCheck <> nil) and (FActiveCheck.OwnerKey = Key) then
    FreeAndNil(FActiveCheck);

  RemoveFromPendingQueue(Key);

  // Preserve any pending debounced check from another tab before retargeting the timer
  if FHasPendingDebounce and (FDebounceKey <> '') and (FDebounceKey <> Key) then
    EnqueueValidation(FDebounceUri, FDebounceFilePath, False);

  FHasPendingDebounce := True;
  FDebounceKey := Key;
  FDebounceUri := AUri;
  FDebounceFilePath := AFilePath;
  FDebounceDeadlineMs := GetTickCount64 + LSP_CHANGE_DEBOUNCE_MS;
end;

function TNikPascalLspServer.DetermineWorkspaceRootDir: string;
begin
  Result := '';
  if Length(InitParams.WorkspaceFolders) > 0 then
    Result := UriToFilePath(InitParams.WorkspaceFolders[0].Uri);
  if (Result = '') and (InitParams.RootUri <> '') then
    Result := UriToFilePath(InitParams.RootUri);
  if (Result = '') and (InitParams.RootPath <> '') then
    Result := InitParams.RootPath;
end;

procedure TNikPascalLspServer.ConfigureCapabilities(const AParams: TLspInitializeParams;
  var ACaps: TLspServerCapabilities);
begin
  ACaps.ServerName := 'nik lsp';
  ACaps.ServerVersion := NIK_VERSION;
  ACaps.TextDocumentSync := ltdskIncremental;
  ACaps.OpenCloseNotify := True;
  ACaps.SaveNotify := True;
  ACaps.SaveIncludeText := False;

  ACaps.HoverProvider := True;
  ACaps.DefinitionProvider := True;
  ACaps.DeclarationProvider := True;
  ACaps.DocumentSymbolProvider := True;
  ACaps.WorkspaceSymbolProvider := True;

  ACaps.CompletionProvider := True;
  SetLength(ACaps.CompletionTriggerChars, 1);
  ACaps.CompletionTriggerChars[0] := '.';

  ACaps.SignatureHelpProvider := True;
  SetLength(ACaps.SignatureTriggerChars, 2);
  ACaps.SignatureTriggerChars[0] := '(';
  ACaps.SignatureTriggerChars[1] := ',';
end;

function TNikPascalLspServer.IsManifestFilePath(const AFilePath: string): Boolean;
var
  Base: string;
begin
  Base := LowerCase(ExtractFileName(AFilePath));
  Result := (Base = 'nik.yaml') or (Base = 'nik.yml');
end;

function TNikPascalLspServer.IsPascalDocFilePath(const AFilePath: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFilePath));
  Result := (Ext = '.pas') or (Ext = '.pp') or (Ext = '.dpr') or (Ext = '.lpr') or (Ext = '.inc');
end;

procedure TNikPascalLspServer.ReloadWorkspaceConfiguration;
var
  RootDir, WarnMsg, ManifestUri: string;
  ManDiags: TLspDiagnosticArray;
  OpenManDoc, OpenPasDoc: TLspDocument;
  I: Integer;
begin
  FreeAndNil(FActiveCheck);
  RootDir := DetermineWorkspaceRootDir;
  FWorkspaceReady := ResolveLspWorkspace(RootDir, FManifestOverride, FProfileName, FWorkspace, WarnMsg);
  if FWorkspaceReady then
    EnsureFreshLspCompilerCache(FWorkspace);

  // Publish or clear diagnostics on nik.yaml (using open editor URI when nik.yaml is open)
  if FWorkspace.ManifestPath <> '' then
  begin
    OpenManDoc := Documents.FindByFilePath(FWorkspace.ManifestPath);
    if OpenManDoc <> nil then
      ManifestUri := OpenManDoc.Uri
    else
      ManifestUri := FilePathToUri(FWorkspace.ManifestPath);

    if FWorkspace.HasManifestError then
    begin
      ManDiags := nil;
      SetLength(ManDiags, 1);
      ManDiags[0] := Default(TLspDiagnostic);
      ManDiags[0].Range := TLspRange.SingleLine(FWorkspace.ManifestErrorLine, 0, 200);
      ManDiags[0].Severity := ldsError;
      ManDiags[0].Source := 'nik.yaml';
      ManDiags[0].Message := FWorkspace.ManifestErrorMessage;
      PublishDiagnostics(ManifestUri, ManDiags);
      FPublishedManifestUri := ManifestUri;
      SendLogMessage(lmtWarning, Format('Invalid nik.yaml (%s) — running with fallback SDK configuration.',
        [FWorkspace.ManifestErrorMessage]));
    end
    else
    begin
      if FPublishedManifestUri <> '' then
        ClearDiagnostics(FPublishedManifestUri);
      if (OpenManDoc <> nil) and (OpenManDoc.Uri <> FPublishedManifestUri) then
        ClearDiagnostics(OpenManDoc.Uri);
      FPublishedManifestUri := '';
    end;
  end;

  FIndex.ConfigureWorkspace(FWorkspace, FWorkspaceReady, RootDir);

  // Re-apply any unsaved open Pascal buffers on top of freshly scanned disk files
  for I := 0 to Documents.Count - 1 do
  begin
    OpenPasDoc := Documents[I];
    if (OpenPasDoc <> nil) and (not IsManifestFilePath(OpenPasDoc.FilePath)) then
      FIndex.SyncOpenDocument(OpenPasDoc.Uri, OpenPasDoc.FilePath, OpenPasDoc.Text);
  end;

  if FWorkspaceReady then
    SendLogMessage(lmtInfo, Format('nik lsp ready (SDK: %s, profile: %s, root: %s)',
      [FWorkspace.Sdk.Manifest.SdkId, FWorkspace.ProfileName, FWorkspace.ProjectDir]))
  else
    SendLogMessage(lmtWarning, 'nik lsp workspace fallback (no SDK/manifest resolved): ' + WarnMsg);
end;

procedure TNikPascalLspServer.DoInitialized;
begin
  ReloadWorkspaceConfiguration;
end;

procedure TNikPascalLspServer.DoShutdown;
begin
  FHasPendingDebounce := False;
  SetLength(FPendingQueue, 0);
  if FActiveCheck <> nil then
  begin
    if FActiveCheck.WaitUntilFinished(5000) then
      CompleteActiveCheck
    else
      FreeAndNil(FActiveCheck);
  end;
end;

function TNikPascalLspServer.ResolveDocFilePath(const AUri: string; ADoc: TLspDocument): string;
begin
  if (ADoc <> nil) and (ADoc.FilePath <> '') then
    Result := ADoc.FilePath
  else
    Result := UriToFilePath(AUri);
end;

procedure TNikPascalLspServer.EnsureIndexedDoc(const AUri: string; ADoc: TLspDocument);
var
  LocalPath: string;
begin
  if ADoc <> nil then
    FIndex.SyncOpenDocument(ADoc.Uri, ADoc.FilePath, ADoc.Text)
  else if FIndex.FindFileByUri(AUri) = nil then
  begin
    LocalPath := UriToFilePath(AUri);
    if (LocalPath <> '') and FileExists(LocalPath) then
      FIndex.RefreshDiskFile(LocalPath);
  end;
end;

procedure TNikPascalLspServer.DoDidOpen(ADoc: TLspDocument);
var
  ManDiags: TLspDiagnosticArray;
begin
  if ADoc = nil then
    Exit;
  if IsManifestFilePath(ADoc.FilePath) then
  begin
    ValidateManifestTextForLsp(ADoc.FilePath, ADoc.Text, FProfileName, ManDiags);
    PublishDiagnostics(ADoc.Uri, ManDiags);
    if Length(ManDiags) > 0 then
      FPublishedManifestUri := ADoc.Uri
    else if FPublishedManifestUri <> '' then
    begin
      if FPublishedManifestUri <> ADoc.Uri then
        ClearDiagnostics(FPublishedManifestUri);
      FPublishedManifestUri := '';
    end;
    Exit;
  end;

  FIndex.SyncOpenDocument(ADoc.Uri, ADoc.FilePath, ADoc.Text);
  if IsPascalDocFilePath(ADoc.FilePath) then
  begin
    ScheduleImmediateValidation(ADoc.Uri, ADoc.FilePath);
    EnqueueUsersOfUnit(ADoc.Uri, ADoc.FilePath);
  end;
end;

procedure TNikPascalLspServer.DoDidChange(ADoc: TLspDocument);
var
  ManDiags: TLspDiagnosticArray;
begin
  if ADoc = nil then
    Exit;
  if IsManifestFilePath(ADoc.FilePath) then
  begin
    ValidateManifestTextForLsp(ADoc.FilePath, ADoc.Text, FProfileName, ManDiags);
    PublishDiagnostics(ADoc.Uri, ManDiags);
    if Length(ManDiags) > 0 then
      FPublishedManifestUri := ADoc.Uri
    else if FPublishedManifestUri <> '' then
    begin
      if FPublishedManifestUri <> ADoc.Uri then
        ClearDiagnostics(FPublishedManifestUri);
      FPublishedManifestUri := '';
    end;
    Exit;
  end;

  FIndex.SyncOpenDocument(ADoc.Uri, ADoc.FilePath, ADoc.Text);
  if IsPascalDocFilePath(ADoc.FilePath) then
  begin
    ScheduleDebouncedValidation(ADoc.Uri, ADoc.FilePath);
    EnqueueUsersOfUnit(ADoc.Uri, ADoc.FilePath);
  end;
end;

procedure TNikPascalLspServer.DoDidSave(ADoc: TLspDocument;
  const AHasSavedText: Boolean; const ASavedText: string);
begin
  if ADoc = nil then
    Exit;
  if IsManifestFilePath(ADoc.FilePath) then
  begin
    ReloadWorkspaceConfiguration;
    EnqueueAllOpenPascalDocuments;
    StartNextQueuedCheck;
    Exit;
  end;

  FIndex.SyncOpenDocument(ADoc.Uri, ADoc.FilePath, ADoc.Text);
  if IsPascalDocFilePath(ADoc.FilePath) then
  begin
    ScheduleImmediateValidation(ADoc.Uri, ADoc.FilePath);
    EnqueueUsersOfUnit(ADoc.Uri, ADoc.FilePath);
  end;
end;

procedure TNikPascalLspServer.DoDidClose(const AUri, AFilePath: string);
var
  ClosedKey, TargetKey, TargetUri: string;
  RepIdx, I: Integer;
  Rep: TNikDocDiagReport;
  OtherTargets: TStringList;
  OverlayEntries: TNikOverlayFileEntryArray;
  Diags: TLspDiagnosticArray;
begin
  if IsManifestFilePath(AFilePath) then
  begin
    ReloadWorkspaceConfiguration;
    Exit;
  end;

  ClosedKey := LowerCase(NormalizeDocumentUri(AUri));
  if FHasPendingDebounce and (FDebounceKey = ClosedKey) then
    FHasPendingDebounce := False;
  RemoveFromPendingQueue(ClosedKey);
  if (FActiveCheck <> nil) and (FActiveCheck.OwnerKey = ClosedKey) then
    FreeAndNil(FActiveCheck);

  // Re-sync CodeTools buffer and overlay directory with saved disk state
  FIndex.CloseOpenDocument(AUri, AFilePath);
  if FWorkspaceReady then
    SyncOpenDocumentsOverlay(FWorkspace, Documents, OverlayEntries);

  // Forget closed document's report, clear its diagnostics, and refresh dependent targets
  OtherTargets := TStringList.Create;
  try
    RepIdx := FindReportIndex(ClosedKey);
    if RepIdx >= 0 then
    begin
      Rep := TNikDocDiagReport(FReports[RepIdx]);
      for I := 0 to High(Rep.Targets) do
        if Rep.Targets[I].NormalizedKey <> ClosedKey then
          OtherTargets.Add(Rep.Targets[I].NormalizedKey + '=' + Rep.Targets[I].Uri);
      FReports.Delete(RepIdx);
      Rep.Free;
    end;

    ClearDiagnostics(AUri);
    for I := 0 to OtherTargets.Count - 1 do
    begin
      TargetKey := OtherTargets.Names[I];
      Diags := ShownDiagnosticsForKey(TargetKey, TargetUri);
      if TargetUri = '' then
        TargetUri := OtherTargets.ValueFromIndex[I];
      if TargetUri <> '' then
        PublishDiagnostics(TargetUri, Diags);
    end;
  finally
    OtherTargets.Free;
  end;

  EnqueueUsersOfUnit(AUri, AFilePath);
  StartNextQueuedCheck;
end;

procedure TNikPascalLspServer.DoDidChangeWatchedFiles(const AChanges: TLspFileEventArray);
var
  I: Integer;
  LocalPath: string;
  ManifestTouched, SourceTouched: Boolean;
begin
  ManifestTouched := False;
  SourceTouched := False;

  for I := 0 to High(AChanges) do
  begin
    LocalPath := UriToFilePath(AChanges[I].Uri);
    if LocalPath = '' then
      Continue;

    if IsManifestFilePath(LocalPath) then
      ManifestTouched := True
    else if IsPascalDocFilePath(LocalPath) then
    begin
      // Ignore internal build/LSP overlay files inside .nik/
      if (Pos(PathDelim + '.nik' + PathDelim, LocalPath) > 0) or
         (Pos('/.nik/', LocalPath) > 0) then
        Continue;

      // Only re-index from disk if the file is not currently open in the editor
      if Documents.FindDocument(AChanges[I].Uri) = nil then
      begin
        if (AChanges[I].ChangeType <> lfctDeleted) and FileExists(LocalPath) then
          FIndex.RefreshDiskFile(LocalPath)
        else
          FIndex.CloseOpenDocument(AChanges[I].Uri, LocalPath);
        SourceTouched := True;
      end;
    end;
  end;

  if ManifestTouched then
  begin
    ReloadWorkspaceConfiguration;
    EnqueueAllOpenPascalDocuments;
    StartNextQueuedCheck;
  end
  else if SourceTouched then
  begin
    EnqueueAllOpenPascalDocuments;
    StartNextQueuedCheck;
  end;
end;

function TNikPascalLspServer.GetIdleTickTimeoutMs: Integer;
var
  NowMs: QWord;
  Remain: Int64;
begin
  if FActiveCheck <> nil then
    Exit(LSP_ASYNC_POLL_MS);

  if FHasPendingDebounce then
  begin
    NowMs := GetTickCount64;
    if NowMs >= FDebounceDeadlineMs then
      Exit(0);
    Remain := Int64(FDebounceDeadlineMs - NowMs);
    if Remain > LSP_CHANGE_DEBOUNCE_MS then
      Remain := LSP_CHANGE_DEBOUNCE_MS;
    Exit(Integer(Remain));
  end;

  if Length(FPendingQueue) > 0 then
    Exit(0);

  Result := -1;
end;

procedure TNikPascalLspServer.DoIdleTick;
var
  DebUri, DebPath: string;
begin
  if (FActiveCheck <> nil) and FActiveCheck.PollFinished then
    CompleteActiveCheck;

  if FHasPendingDebounce and (GetTickCount64 >= FDebounceDeadlineMs) then
  begin
    DebUri := FDebounceUri;
    DebPath := FDebounceFilePath;
    FHasPendingDebounce := False;
    EnqueueValidation(DebUri, DebPath, True);
  end;

  if (FActiveCheck = nil) and (Length(FPendingQueue) > 0) then
    StartNextQueuedCheck;
end;

function TNikPascalLspServer.DoDocumentSymbol(const AUri: string; ADoc: TLspDocument): TLspDocumentSymbolArray;
var
  DocPath: string;
begin
  DocPath := ResolveDocFilePath(AUri, ADoc);
  if IsManifestFilePath(DocPath) then
    Exit(nil);
  EnsureIndexedDoc(AUri, ADoc);
  Result := FIndex.BuildDocumentSymbols(AUri, DocPath);
end;

function TNikPascalLspServer.DoWorkspaceSymbol(const AQuery: string): TLspSymbolInformationArray;
begin
  Result := FIndex.SearchWorkspaceSymbols(AQuery);
end;

function TNikPascalLspServer.DoDefinition(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspLocationArray;
var
  DocPath: string;
  I: Integer;
  OpenDoc: TLspDocument;
begin
  Result := nil;
  DocPath := ResolveDocFilePath(AUri, ADoc);
  if IsManifestFilePath(DocPath) then
    Exit;
  EnsureIndexedDoc(AUri, ADoc);
  Result := FIndex.ResolveDefinitions(AUri, DocPath, ADoc, APos);
  for I := 0 to High(Result) do
  begin
    OpenDoc := Documents.FindDocument(Result[I].Uri);
    if OpenDoc <> nil then
      Result[I].Uri := OpenDoc.Uri;
  end;
end;

function TNikPascalLspServer.DoDeclaration(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspLocationArray;
var
  DocPath: string;
  I: Integer;
  OpenDoc: TLspDocument;
begin
  Result := nil;
  DocPath := ResolveDocFilePath(AUri, ADoc);
  if IsManifestFilePath(DocPath) then
    Exit;
  EnsureIndexedDoc(AUri, ADoc);
  Result := FIndex.ResolveDeclarations(AUri, DocPath, ADoc, APos);
  for I := 0 to High(Result) do
  begin
    OpenDoc := Documents.FindDocument(Result[I].Uri);
    if OpenDoc <> nil then
      Result[I].Uri := OpenDoc.Uri;
  end;
end;

function TNikPascalLspServer.DoHover(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspHover;
var
  DocPath: string;
begin
  Result := Default(TLspHover);
  DocPath := ResolveDocFilePath(AUri, ADoc);
  if IsManifestFilePath(DocPath) then
    Exit;
  EnsureIndexedDoc(AUri, ADoc);
  Result := FIndex.ResolveHover(AUri, DocPath, ADoc, APos);
end;

function TNikPascalLspServer.DoCompletion(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition; const ATriggerChar: string): TLspCompletionList;
var
  DocPath: string;
begin
  DocPath := ResolveDocFilePath(AUri, ADoc);
  if IsManifestFilePath(DocPath) then
    Exit(Default(TLspCompletionList));
  EnsureIndexedDoc(AUri, ADoc);
  Result := FIndex.ResolveCompletions(AUri, DocPath, ADoc, APos);
end;

function TNikPascalLspServer.DoSignatureHelp(const AUri: string; ADoc: TLspDocument;
  const APos: TLspPosition; const ATriggerChar: string): TLspSignatureHelp;
var
  DocPath: string;
begin
  Result := Default(TLspSignatureHelp);
  DocPath := ResolveDocFilePath(AUri, ADoc);
  if IsManifestFilePath(DocPath) then
    Exit;
  EnsureIndexedDoc(AUri, ADoc);
  Result := FIndex.ResolveSignatureHelp(AUri, DocPath, ADoc, APos);
end;

end.
