unit nik.cmd.sdk;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

function ExecuteSdkCommand(const AArgs: array of string): Integer;
procedure PrintSdkHelp;

implementation

uses
  fpjson, nik.types, nik.paths, nik.fs, nik.term, nik.sdk.manager;

procedure PrintSdkHelp;
begin
  WriteLn(StyleBold('Manage portable Free Pascal SDKs'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik sdk <SUBCOMMAND> [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('SUBCOMMANDS:'));
  WriteLn('  ' + PadRightStr('list', 14) + 'List locally installed SDKs (or remote SDKs with --remote)');
  WriteLn('  ' + PadRightStr('install', 14) + 'Download, verify, and install an SDK (version or local SDK)');
  WriteLn('  ' + PadRightStr('update', 14) + 'Update installed SDKs to the latest remote build');
  WriteLn('  ' + PadRightStr('uninstall', 14) + 'Remove a locally installed SDK by version');
  WriteLn('  ' + PadRightStr('info', 14) + 'Display details and verified paths of an installed SDK');
  WriteLn('  ' + PadRightStr('help', 14) + 'Show help for sdk commands');
  WriteLn;
  WriteLn(StyleBold('EXAMPLES:'));
  WriteLn('  nik sdk list');
  WriteLn('  nik sdk list --remote');
  WriteLn('  nik sdk install 3.2.2');
  WriteLn('  nik sdk install 3.3.1');
  WriteLn('  nik sdk update');
  WriteLn('  nik sdk update 3.3.1');
  WriteLn('  nik sdk install ./dist/nikrun-fpc-sdk-3.2.4-66940ee6-x86_64-win64.zip');
  WriteLn('  nik sdk info 3.2.2');
  WriteLn('  nik sdk uninstall 3.3.1');
end;

procedure PrintSdkListHelp;
begin
  WriteLn(StyleBold('List installed or available Free Pascal SDKs'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik sdk list [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('  -r, --remote           Fetch and list available prebuilt SDKs from index.json');
  WriteLn('      --version <VER>    Filter by FPC version (e.g. 3.2.2, 3.3.1)');
  WriteLn('      --os <OS>          Filter by target OS (win64, linux, darwin)');
  WriteLn('      --arch <CPU>       Filter by target CPU (x86_64, aarch64)');
  WriteLn('      --index-url <URL>  Override remote index.json URL or file path');
  WriteLn('      --no-check         Skip the remote update check for installed SDKs');
  WriteLn('      --json             Output machine-readable JSON');
  WriteLn('  -h, --help             Show this help message');
end;

procedure PrintSdkInstallHelp;
begin
  WriteLn(StyleBold('Download, verify SHA-256, and configure a Free Pascal SDK'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik sdk install <VERSION|PATH> [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('ARGUMENTS:'));
  WriteLn('  <VERSION|PATH>         Exact FPC version (e.g. 3.2.2, 3.3.1) or local SDK (.zip / directory)');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('  -f, --force            Reinstall even if the SDK is already installed');
  WriteLn('      --skip-verify      Skip SHA-256 checksum verification');
  WriteLn('      --os <OS>          Override target OS when resolving version');
  WriteLn('      --arch <CPU>       Override target CPU when resolving version');
  WriteLn('      --index-url <URL>  Override remote index.json URL or file path');
  WriteLn('  -h, --help             Show this help message');
end;

procedure PrintSdkUpdateHelp;
begin
  WriteLn(StyleBold('Update installed Free Pascal SDKs to the latest remote build'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik sdk update [<VERSION>] [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('ARGUMENTS:'));
  WriteLn('  [<VERSION>]            Installed FPC version to update (updates all installed SDKs when omitted)');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('      --skip-verify      Skip SHA-256 checksum verification');
  WriteLn('      --os <OS>          Filter target OS when updating (win64, linux, darwin)');
  WriteLn('      --arch <CPU>       Filter target CPU when updating (x86_64, aarch64)');
  WriteLn('      --index-url <URL>  Override remote index.json URL or file path');
  WriteLn('      --json             Output machine-readable JSON');
  WriteLn('  -h, --help             Show this help message');
end;

procedure PrintSdkUninstallHelp;
begin
  WriteLn(StyleBold('Remove a locally installed Free Pascal SDK'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik sdk uninstall <VERSION> [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('ARGUMENTS:'));
  WriteLn('  <VERSION>              Installed FPC version (e.g. 3.2.2, 3.3.1)');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('      --os <OS>          Target OS when multiple targets are installed (win64, linux, darwin)');
  WriteLn('      --arch <CPU>       Target CPU when multiple targets are installed (x86_64, aarch64)');
  WriteLn('  -h, --help             Show this help message');
end;

procedure PrintSdkInfoHelp;
begin
  WriteLn(StyleBold('Display details and verified paths of an installed SDK'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik sdk info <VERSION> [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('ARGUMENTS:'));
  WriteLn('  <VERSION>              Installed FPC version (e.g. 3.2.2, 3.3.1)');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('      --os <OS>          Target OS when multiple targets are installed (win64, linux, darwin)');
  WriteLn('      --arch <CPU>       Target CPU when multiple targets are installed (x86_64, aarch64)');
  WriteLn('      --json             Output machine-readable JSON');
  WriteLn('  -h, --help             Show this help message');
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

function MaxIntVal(A, B: Integer): Integer;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

function ShortCommitStr(const AGitCommit: string): string;
var
  Trimmed: string;
begin
  Trimmed := LowerCase(Trim(AGitCommit));
  if Trimmed <> '' then
    Result := Copy(Trimmed, 1, 8)
  else
    Result := 'unknown';
end;

type
  TSdkUpdateCommits = array of string;

// Best-effort: for each local SDK returns the newer remote commit (or '') when the remote index
// holds a different build for the same FPC version and target. Network errors are ignored.
function DetectSdkUpdates(const ASdks: TInstalledSdkArray; const AIndexUrl: string): TSdkUpdateCommits;
var
  Index: TSdkIndex;
  Single: TInstalledSdkArray;
  Matched: TInstalledSdk;
  I, J: Integer;
  UpdAvail: Boolean;
begin
  Result := nil;
  SetLength(Result, Length(ASdks));
  if Length(ASdks) = 0 then
    Exit;
  try
    Index := FetchRemoteSdkIndex(AIndexUrl);
  except
    Exit;
  end;
  Single := nil;
  SetLength(Single, 1);
  for I := 0 to High(ASdks) do
  begin
    Single[0] := ASdks[I];
    for J := 0 to High(Index.Sdks) do
      if SameText(Index.Sdks[J].FpcVersion, ASdks[I].Manifest.FpcVersion) and
         SameText(Index.Sdks[J].TargetTriplet, ASdks[I].Manifest.TargetTriplet) and
         MatchRemoteSdkInstallState(Single, Index.Sdks[J], Matched, UpdAvail) and UpdAvail then
      begin
        Result[I] := Index.Sdks[J].GitCommit;
        if Result[I] = '' then
          Result[I] := Index.Sdks[J].SdkId;
        Break;
      end;
  end;
end;

function HandleListLocal(const AVersionFilter, AOsFilter, AArchFilter, AIndexUrl: string;
  AJson, ANoCheck: Boolean): Integer;
var
  Updates: TSdkUpdateCommits;
  AnyUpdate: Boolean;
  WUpdate, WPath: Integer;
  UpdStr: string;
  AllInstalled, Filtered: TInstalledSdkArray;
  Sizes: array of Int64;
  TotalSizeBytes: Int64;
  I, Count, WVersion, WTarget, WCommit, WSize: Integer;
  CommitStr, SizeStr, SdkLabel: string;
  Root: TJSONObject;
  Arr: TJSONArray;
  ItemObj: TJSONObject;
begin
  Result := 0;
  AllInstalled := ListInstalledSdks;
  Filtered := nil;
  Sizes := nil;
  TotalSizeBytes := 0;
  Count := 0;

  for I := 0 to High(AllInstalled) do
  begin
    if (AVersionFilter <> '') and (not SameText(AllInstalled[I].Manifest.FpcVersion, AVersionFilter)) then
      Continue;
    if (AOsFilter <> '') and (not SameText(AllInstalled[I].Manifest.TargetOs, AOsFilter)) then
      Continue;
    if (AArchFilter <> '') and (not SameText(AllInstalled[I].Manifest.TargetCpu, AArchFilter)) then
      Continue;

    SetLength(Filtered, Count + 1);
    Filtered[Count] := AllInstalled[I];
    Inc(Count);
  end;

  Updates := nil;
  if ANoCheck then
    SetLength(Updates, Length(Filtered))
  else
    Updates := DetectSdkUpdates(Filtered, AIndexUrl);
  AnyUpdate := False;
  for I := 0 to High(Updates) do
    if Updates[I] <> '' then
      AnyUpdate := True;

  SetLength(Sizes, Length(Filtered));
  for I := 0 to High(Filtered) do
  begin
    Sizes[I] := GetDirectorySizeSafe(Filtered[I].InstallPath);
    Inc(TotalSizeBytes, Sizes[I]);
  end;

  if AJson then
  begin
    Root := TJSONObject.Create;
    Arr := TJSONArray.Create;
    try
      Root.Add('nikrunHome', GetNikrunHomeDir);
      Root.Add('totalSizeBytes', TotalSizeBytes);
      for I := 0 to High(Filtered) do
      begin
        ItemObj := TJSONObject.Create;
        ItemObj.Add('sdkId', Filtered[I].Manifest.SdkId);
        ItemObj.Add('fpcVersion', Filtered[I].Manifest.FpcVersion);
        ItemObj.Add('gitRef', Filtered[I].Manifest.GitRef);
        ItemObj.Add('gitCommit', Filtered[I].Manifest.GitCommit);
        ItemObj.Add('targetOs', Filtered[I].Manifest.TargetOs);
        ItemObj.Add('targetCpu', Filtered[I].Manifest.TargetCpu);
        ItemObj.Add('targetTriplet', Filtered[I].Manifest.TargetTriplet);
        ItemObj.Add('builtAtUtc', Filtered[I].Manifest.BuiltAtUtc);
        ItemObj.Add('installPath', Filtered[I].InstallPath);
        ItemObj.Add('sizeBytes', Sizes[I]);
        ItemObj.Add('updateAvailable', Updates[I] <> '');
        if Updates[I] <> '' then
          ItemObj.Add('latestCommit', Updates[I])
        else
          ItemObj.Add('latestCommit', TJSONNull.Create);
        Arr.Add(ItemObj);
      end;
      Root.Add('sdks', Arr);
      WriteJson(Root);
    finally
      Root.Free;
    end;
    Exit;
  end;

  if Length(Filtered) = 0 then
  begin
    WriteInfo('No Free Pascal SDKs installed in ' + GetNikrunSdksDir);
    WriteLn('    Run ' + StyleBold('nik sdk install 3.2.2') + ' to install FPC 3.2.2, or ' +
            StyleBold('nik sdk list --remote') + ' to browse all versions.');
    Exit;
  end;

  WVersion := Length('VERSION');
  WTarget  := Length('TARGET');
  WCommit  := Length('COMMIT');
  WSize    := Length('SIZE');
  WUpdate  := Length('UPDATE');
  WPath    := Length('PATH');

  for I := 0 to High(Filtered) do
  begin
    if Updates[I] <> '' then
      WUpdate := MaxIntVal(WUpdate, Length('-> ' + ShortCommitStr(Updates[I])));
    CommitStr := ShortCommitStr(Filtered[I].Manifest.GitCommit);
    SizeStr   := FormatByteSize(Sizes[I]);
    WVersion  := MaxIntVal(WVersion, Length(Filtered[I].Manifest.FpcVersion));
    WTarget   := MaxIntVal(WTarget, Length(Filtered[I].Manifest.TargetTriplet));
    WCommit   := MaxIntVal(WCommit, Length(CommitStr));
    WSize     := MaxIntVal(WSize, Length(SizeStr));
    WPath     := MaxIntVal(WPath, Length(Filtered[I].InstallPath));
  end;

  WriteLn(StyleBold(
    PadRightStr('VERSION', WVersion + 2) +
    PadRightStr('TARGET', WTarget + 2) +
    PadRightStr('COMMIT', WCommit + 2) +
    PadRightStr('UPDATE', WUpdate + 2) +
    PadRightStr('PATH', WPath + 2) +
    'SIZE'));

  for I := 0 to High(Filtered) do
  begin
    CommitStr := ShortCommitStr(Filtered[I].Manifest.GitCommit);
    SizeStr   := FormatByteSize(Sizes[I]);
    if Updates[I] <> '' then
      UpdStr := StyleYellow(PadRightStr('-> ' + ShortCommitStr(Updates[I]), WUpdate + 2))
    else
      UpdStr := PadRightStr('', WUpdate + 2);
    WriteLn(
      PadRightStr(Filtered[I].Manifest.FpcVersion, WVersion + 2) +
      PadRightStr(Filtered[I].Manifest.TargetTriplet, WTarget + 2) +
      StyleDim(PadRightStr(CommitStr, WCommit + 2)) +
      UpdStr +
      StyleDim(PadRightStr(Filtered[I].InstallPath, WPath + 2)) +
      SizeStr);
  end;

  if AnyUpdate then
  begin
    WriteLn;
    WriteInfo('Updates available. Run ' + StyleBold('nik sdk update') + ' to install them.');
  end;

  if Length(Filtered) = 1 then
    SdkLabel := 'SDK'
  else
    SdkLabel := 'SDKs';
  WriteLn;
  WriteLn(StyleDim(Format('%d %s installed (%s total)',
    [Length(Filtered), SdkLabel, FormatByteSize(TotalSizeBytes)])));
end;

function HandleListRemote(const AVersionFilter, AOsFilter, AArchFilter, AIndexUrl: string;
  AJson: Boolean): Integer;
var
  Index: TSdkIndex;
  Installed: TInstalledSdkArray;
  MatchedSdk: TInstalledSdk;
  Filtered: TRemoteSdkArray;
  I, Count, WVersion, WTarget, WCommit, WSize: Integer;
  HasInst, UpdateAvail: Boolean;
  CommitStr, SizeStr, InstCommitStr, InstLabel, UpdLabel: string;
  WInst, WUpd: Integer;
  Root, ItemObj: TJSONObject;
  Arr: TJSONArray;
begin
  Result := 0;
  Index := FetchRemoteSdkIndex(AIndexUrl);
  Installed := ListInstalledSdks;
  Filtered := nil;
  Count := 0;

  for I := 0 to High(Index.Sdks) do
  begin
    if (AVersionFilter <> '') and (not SameText(Index.Sdks[I].FpcVersion, AVersionFilter)) then
      Continue;
    if (AOsFilter <> '') and (not SameText(Index.Sdks[I].TargetOs, AOsFilter)) then
      Continue;
    if (AArchFilter <> '') and (not SameText(Index.Sdks[I].TargetCpu, AArchFilter)) then
      Continue;

    SetLength(Filtered, Count + 1);
    Filtered[Count] := Index.Sdks[I];
    Inc(Count);
  end;

  if AJson then
  begin
    Root := TJSONObject.Create;
    Arr := TJSONArray.Create;
    try
      Root.Add('schemaVersion', Index.SchemaVersion);
      Root.Add('releaseTag', Index.ReleaseTag);
      Root.Add('updatedAtUtc', Index.UpdatedAtUtc);
      for I := 0 to High(Filtered) do
      begin
        HasInst := MatchRemoteSdkInstallState(Installed, Filtered[I], MatchedSdk, UpdateAvail);
        ItemObj := TJSONObject.Create;
        ItemObj.Add('sdkId', Filtered[I].SdkId);
        ItemObj.Add('fpcVersion', Filtered[I].FpcVersion);
        ItemObj.Add('gitRef', Filtered[I].GitRef);
        ItemObj.Add('gitCommit', Filtered[I].GitCommit);
        ItemObj.Add('targetOs', Filtered[I].TargetOs);
        ItemObj.Add('targetCpu', Filtered[I].TargetCpu);
        ItemObj.Add('targetTriplet', Filtered[I].TargetTriplet);
        ItemObj.Add('builtAtUtc', Filtered[I].BuiltAtUtc);
        ItemObj.Add('fileName', Filtered[I].FileName);
        ItemObj.Add('sizeBytes', Filtered[I].SizeBytes);
        ItemObj.Add('sha256', Filtered[I].Sha256);
        ItemObj.Add('downloadUrl', Filtered[I].DownloadUrl);
        ItemObj.Add('installed', HasInst);
        ItemObj.Add('updateAvailable', UpdateAvail);
        if HasInst then
        begin
          ItemObj.Add('installedSdkId', MatchedSdk.Manifest.SdkId);
          if Trim(MatchedSdk.Manifest.GitCommit) <> '' then
            ItemObj.Add('installedCommit', MatchedSdk.Manifest.GitCommit)
          else
            ItemObj.Add('installedCommit', TJSONNull.Create);
        end
        else
        begin
          ItemObj.Add('installedSdkId', TJSONNull.Create);
          ItemObj.Add('installedCommit', TJSONNull.Create);
        end;
        Arr.Add(ItemObj);
      end;
      Root.Add('sdks', Arr);
      WriteJson(Root);
    finally
      Root.Free;
    end;
    Exit;
  end;

  if Length(Filtered) = 0 then
  begin
    WriteInfo('No remote SDKs matched the specified filters.');
    Exit;
  end;

  WVersion := Length('VERSION');
  WTarget  := Length('TARGET');
  WCommit  := Length('COMMIT');
  WSize    := Length('SIZE');
  WInst    := Length('INSTALLED');
  WUpd     := Length('UPDATE');

  for I := 0 to High(Filtered) do
  begin
    CommitStr := ShortCommitStr(Filtered[I].GitCommit);
    WInst     := MaxIntVal(WInst, Length(CommitStr));
    WUpd      := MaxIntVal(WUpd, Length('-> ' + CommitStr));
    SizeStr   := FormatByteSize(Filtered[I].SizeBytes);
    WVersion  := MaxIntVal(WVersion, Length(Filtered[I].FpcVersion));
    WTarget   := MaxIntVal(WTarget, Length(Filtered[I].TargetTriplet));
    WCommit   := MaxIntVal(WCommit, Length(CommitStr));
    WSize     := MaxIntVal(WSize, Length(SizeStr));
  end;

  WriteLn(StyleBold(
    PadRightStr('VERSION', WVersion + 2) +
    PadRightStr('TARGET', WTarget + 2) +
    PadRightStr('COMMIT', WCommit + 2) +
    PadRightStr('INSTALLED', WInst + 2) +
    PadRightStr('UPDATE', WUpd + 2) +
    'SIZE'));

  for I := 0 to High(Filtered) do
  begin
    HasInst := MatchRemoteSdkInstallState(Installed, Filtered[I], MatchedSdk, UpdateAvail);
    CommitStr := ShortCommitStr(Filtered[I].GitCommit);
    SizeStr   := FormatByteSize(Filtered[I].SizeBytes);

    InstLabel := PadRightStr('', WInst + 2);
    UpdLabel  := PadRightStr('', WUpd + 2);
    if HasInst then
    begin
      InstCommitStr := ShortCommitStr(MatchedSdk.Manifest.GitCommit);
      if UpdateAvail then
      begin
        InstLabel := PadRightStr(InstCommitStr, WInst + 2);
        UpdLabel  := StyleYellow(PadRightStr('-> ' + CommitStr, WUpd + 2));
      end
      else
        InstLabel := StyleGreen(PadRightStr(InstCommitStr, WInst + 2));
    end;

    WriteLn(
      PadRightStr(Filtered[I].FpcVersion, WVersion + 2) +
      PadRightStr(Filtered[I].TargetTriplet, WTarget + 2) +
      StyleDim(PadRightStr(CommitStr, WCommit + 2)) +
      InstLabel +
      UpdLabel +
      SizeStr);
  end;
end;

function ExecuteSdkList(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val, VersionFilter, OsFilter, ArchFilter, IndexUrl: string;
  IsRemote, IsJson, NoCheck: Boolean;
begin
  NoCheck := False;
  IsRemote := False;
  IsJson := False;
  VersionFilter := '';
  OsFilter := '';
  ArchFilter := '';
  IndexUrl := '';

  I := Low(AArgs);
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') then
    begin
      PrintSdkListHelp;
      Exit(0);
    end
    else if (Arg = '-r') or (Arg = '--remote') then
      IsRemote := True
    else if Arg = '--json' then
      IsJson := True
    else if Arg = '--no-check' then
      NoCheck := True
    else if Arg = '--version' then
      VersionFilter := NextOptValue(AArgs, I, '--version')
    else if SplitOptEq(Arg, '--version', Val) then
      VersionFilter := Val
    else if Arg = '--os' then
      OsFilter := NextOptValue(AArgs, I, '--os')
    else if SplitOptEq(Arg, '--os', Val) then
      OsFilter := Val
    else if Arg = '--arch' then
      ArchFilter := NextOptValue(AArgs, I, '--arch')
    else if SplitOptEq(Arg, '--arch', Val) then
      ArchFilter := Val
    else if Arg = '--index-url' then
      IndexUrl := NextOptValue(AArgs, I, '--index-url')
    else if SplitOptEq(Arg, '--index-url', Val) then
      IndexUrl := Val
    else
      raise ENikError.CreateFmt('Unknown option for ''nik sdk list'': %s', [Arg]);
    Inc(I);
  end;

  if IsRemote then
    Result := HandleListRemote(VersionFilter, OsFilter, ArchFilter, IndexUrl, IsJson)
  else
    Result := HandleListLocal(VersionFilter, OsFilter, ArchFilter, IndexUrl, IsJson, NoCheck);
end;

function ExecuteSdkInstall(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val, Spec, TargetOs, TargetCpu, IndexUrl: string;
  Force, SkipVerify, ExplicitArch: Boolean;
begin
  Spec := '';
  TargetOs := '';
  TargetCpu := '';
  IndexUrl := '';
  Force := False;
  SkipVerify := False;
  ExplicitArch := False;

  I := Low(AArgs);
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') then
    begin
      PrintSdkInstallHelp;
      Exit(0);
    end
    else if (Arg = '-f') or (Arg = '--force') then
      Force := True
    else if Arg = '--skip-verify' then
      SkipVerify := True
    else if Arg = '--os' then
      TargetOs := NextOptValue(AArgs, I, '--os')
    else if SplitOptEq(Arg, '--os', Val) then
      TargetOs := Val
    else if Arg = '--arch' then
    begin
      TargetCpu := NextOptValue(AArgs, I, '--arch');
      ExplicitArch := True;
    end
    else if SplitOptEq(Arg, '--arch', Val) then
    begin
      TargetCpu := Val;
      ExplicitArch := True;
    end
    else if Arg = '--index-url' then
      IndexUrl := NextOptValue(AArgs, I, '--index-url')
    else if SplitOptEq(Arg, '--index-url', Val) then
      IndexUrl := Val
    else if (Length(Arg) > 0) and (Arg[1] = '-') then
      raise ENikError.CreateFmt('Unknown option for ''nik sdk install'': %s', [Arg])
    else if Spec = '' then
      Spec := Arg
    else
      raise ENikError.CreateFmt('Unexpected extra argument for ''nik sdk install'': %s', [Arg]);
    Inc(I);
  end;

  InstallSdk(Spec, TargetOs, TargetCpu, IndexUrl, ExplicitArch, Force, SkipVerify);
  Result := 0;
end;

function ExecuteSdkUpdate(const AArgs: array of string): Integer;
var
  I, J, UpdatedCount, UpToDateCount: Integer;
  Arg, Val, Version, TargetOs, TargetCpu, IndexUrl, ActionStr: string;
  SkipVerify, IsJson: Boolean;
  Items: TSdkUpdateItemArray;
  Root, ItemObj: TJSONObject;
  Arr, RemArr: TJSONArray;
begin
  Version := '';
  TargetOs := '';
  TargetCpu := '';
  IndexUrl := '';
  SkipVerify := False;
  IsJson := False;

  I := Low(AArgs);
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') then
    begin
      PrintSdkUpdateHelp;
      Exit(0);
    end
    else if Arg = '--skip-verify' then
      SkipVerify := True
    else if Arg = '--json' then
      IsJson := True
    else if Arg = '--os' then
      TargetOs := NextOptValue(AArgs, I, '--os')
    else if SplitOptEq(Arg, '--os', Val) then
      TargetOs := Val
    else if Arg = '--arch' then
      TargetCpu := NextOptValue(AArgs, I, '--arch')
    else if SplitOptEq(Arg, '--arch', Val) then
      TargetCpu := Val
    else if Arg = '--index-url' then
      IndexUrl := NextOptValue(AArgs, I, '--index-url')
    else if SplitOptEq(Arg, '--index-url', Val) then
      IndexUrl := Val
    else if (Length(Arg) > 0) and (Arg[1] = '-') then
      raise ENikError.CreateFmt('Unknown option for ''nik sdk update'': %s', [Arg])
    else if Version = '' then
      Version := Arg
    else
      raise ENikError.CreateFmt('Unexpected extra argument for ''nik sdk update'': %s', [Arg]);
    Inc(I);
  end;

  Items := UpdateSdks(Version, TargetOs, TargetCpu, IndexUrl, SkipVerify, IsJson);

  UpdatedCount := 0;
  UpToDateCount := 0;
  for I := 0 to High(Items) do
    case Items[I].Action of
      suaUpdated:
        Inc(UpdatedCount);
      suaUpToDate:
        Inc(UpToDateCount);
      else
        raise ENikError.Create('Unexpected SDK update action.');
    end;

  if IsJson then
  begin
    Root := TJSONObject.Create;
    Arr := TJSONArray.Create;
    try
      Root.Add('nikrunHome', GetNikrunHomeDir);
      Root.Add('updatedCount', UpdatedCount);
      Root.Add('upToDateCount', UpToDateCount);
      for I := 0 to High(Items) do
      begin
        case Items[I].Action of
          suaUpdated:
            ActionStr := 'updated';
          suaUpToDate:
            ActionStr := 'up_to_date';
          else
            raise ENikError.Create('Unexpected SDK update action.');
        end;

        ItemObj := TJSONObject.Create;
        ItemObj.Add('fpcVersion', Items[I].FpcVersion);
        ItemObj.Add('targetOs', Items[I].TargetOs);
        ItemObj.Add('targetCpu', Items[I].TargetCpu);
        ItemObj.Add('targetTriplet', Items[I].TargetTriplet);
        ItemObj.Add('action', ActionStr);
        ItemObj.Add('previousSdkId', Items[I].PreviousSdkId);
        if Trim(Items[I].PreviousCommit) <> '' then
          ItemObj.Add('previousCommit', Items[I].PreviousCommit)
        else
          ItemObj.Add('previousCommit', TJSONNull.Create);
        ItemObj.Add('currentSdkId', Items[I].CurrentSdkId);
        if Trim(Items[I].CurrentCommit) <> '' then
          ItemObj.Add('currentCommit', Items[I].CurrentCommit)
        else
          ItemObj.Add('currentCommit', TJSONNull.Create);
        ItemObj.Add('installPath', Items[I].InstallPath);

        RemArr := TJSONArray.Create;
        for J := 0 to High(Items[I].RemovedPaths) do
          RemArr.Add(Items[I].RemovedPaths[J]);
        ItemObj.Add('removedPaths', RemArr);
        Arr.Add(ItemObj);
      end;
      Root.Add('sdks', Arr);
      WriteJson(Root);
    finally
      Root.Free;
    end;
    Exit(0);
  end;

  if Length(Items) = 0 then
  begin
    if Length(ListInstalledSdks) = 0 then
    begin
      WriteInfo('No Free Pascal SDKs installed in ' + GetNikrunSdksDir);
      WriteLn('    Run ' + StyleBold('nik sdk install 3.2.2') + ' to install an SDK first.');
    end
    else
      WriteInfo('No installed Free Pascal SDKs matched the specified filters.');
  end;

  Result := 0;
end;

function ExecuteSdkUninstall(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val, Version, TargetOs, TargetCpu: string;
begin
  Version := '';
  TargetOs := '';
  TargetCpu := '';

  I := Low(AArgs);
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') then
    begin
      PrintSdkUninstallHelp;
      Exit(0);
    end
    else if Arg = '--os' then
      TargetOs := NextOptValue(AArgs, I, '--os')
    else if SplitOptEq(Arg, '--os', Val) then
      TargetOs := Val
    else if Arg = '--arch' then
      TargetCpu := NextOptValue(AArgs, I, '--arch')
    else if SplitOptEq(Arg, '--arch', Val) then
      TargetCpu := Val
    else if (Length(Arg) > 0) and (Arg[1] = '-') then
      raise ENikError.CreateFmt('Unknown option for ''nik sdk uninstall'': %s', [Arg])
    else if Version = '' then
      Version := Arg
    else
      raise ENikError.CreateFmt('Unexpected extra argument for ''nik sdk uninstall'': %s', [Arg]);
    Inc(I);
  end;

  UninstallSdk(Version, BuildTargetTripletFilter(TargetOs, TargetCpu));
  Result := 0;
end;

function FormatPathStatus(const APath: string; AIsDir: Boolean): string;
var
  ExistsOk: Boolean;
begin
  if AIsDir then
    ExistsOk := DirectoryExists(APath)
  else
    ExistsOk := FileExists(APath);

  if ExistsOk then
    Result := APath + ' ' + StyleGreen('[OK]')
  else
    Result := APath + ' ' + StyleRed('[MISSING]');
end;

function ExecuteSdkInfo(const AArgs: array of string): Integer;
var
  I: Integer;
  Arg, Val, Version, TargetOs, TargetCpu: string;
  IsJson: Boolean;
  Sdk: TInstalledSdk;
  SdkSizeBytes: Int64;
  FpcBin, PpcBin, BinDir, FpcCfg, UnitsDir, RtlDir, PkgDir: string;
  Root, PathsObj: TJSONObject;
begin
  Version := '';
  TargetOs := '';
  TargetCpu := '';
  IsJson := False;

  I := Low(AArgs);
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') then
    begin
      PrintSdkInfoHelp;
      Exit(0);
    end
    else if Arg = '--json' then
      IsJson := True
    else if Arg = '--os' then
      TargetOs := NextOptValue(AArgs, I, '--os')
    else if SplitOptEq(Arg, '--os', Val) then
      TargetOs := Val
    else if Arg = '--arch' then
      TargetCpu := NextOptValue(AArgs, I, '--arch')
    else if SplitOptEq(Arg, '--arch', Val) then
      TargetCpu := Val
    else if (Length(Arg) > 0) and (Arg[1] = '-') then
      raise ENikError.CreateFmt('Unknown option for ''nik sdk info'': %s', [Arg])
    else if Version = '' then
      Version := Arg
    else
      raise ENikError.CreateFmt('Unexpected extra argument for ''nik sdk info'': %s', [Arg]);
    Inc(I);
  end;

  if Trim(Version) = '' then
    raise ENikError.Create('Missing Free Pascal SDK version. Example: ''nik sdk info 3.2.2''.');

  Sdk := RequireInstalledSdkForTarget(Version, BuildTargetTripletFilter(TargetOs, TargetCpu));
  SdkSizeBytes := GetDirectorySizeSafe(Sdk.InstallPath);
  BinDir   := JoinPath(Sdk.InstallPath, Sdk.Manifest.Paths.BinDir);
  FpcBin   := JoinPath(Sdk.InstallPath, Sdk.Manifest.Paths.FpcBinary);
  PpcBin   := JoinPath(Sdk.InstallPath, Sdk.Manifest.Paths.PpcBinary);
  FpcCfg   := JoinPath(BinDir, 'fpc.cfg');
  UnitsDir := JoinPath(Sdk.InstallPath, Sdk.Manifest.Paths.UnitsDir);
  RtlDir   := JoinPath(Sdk.InstallPath, Sdk.Manifest.Paths.RtlSourceDir);
  PkgDir   := JoinPath(Sdk.InstallPath, Sdk.Manifest.Paths.PackagesSourceDir);

  if IsJson then
  begin
    Root := TJSONObject.Create;
    PathsObj := TJSONObject.Create;
    try
      Root.Add('sdkId', Sdk.Manifest.SdkId);
      Root.Add('fpcVersion', Sdk.Manifest.FpcVersion);
      Root.Add('gitRef', Sdk.Manifest.GitRef);
      Root.Add('gitCommit', Sdk.Manifest.GitCommit);
      Root.Add('targetOs', Sdk.Manifest.TargetOs);
      Root.Add('targetCpu', Sdk.Manifest.TargetCpu);
      Root.Add('targetTriplet', Sdk.Manifest.TargetTriplet);
      Root.Add('builtAtUtc', Sdk.Manifest.BuiltAtUtc);
      Root.Add('installPath', Sdk.InstallPath);
      Root.Add('sizeBytes', SdkSizeBytes);

      PathsObj.Add('binDir', BinDir);
      PathsObj.Add('fpcBinary', FpcBin);
      PathsObj.Add('ppcBinary', PpcBin);
      PathsObj.Add('fpcCfg', FpcCfg);
      PathsObj.Add('unitsDir', UnitsDir);
      PathsObj.Add('rtlSourceDir', RtlDir);
      PathsObj.Add('packagesSourceDir', PkgDir);
      Root.Add('paths', PathsObj);

      Root.Add('healthy',
        FileExists(FpcBin) and FileExists(FpcCfg) and
        DirectoryExists(UnitsDir) and DirectoryExists(RtlDir) and DirectoryExists(PkgDir));

      WriteJson(Root);
    finally
      Root.Free;
    end;
    Exit(0);
  end;

  WriteLn(StyleBold(Sdk.Manifest.SdkId));
  WriteLn('  FPC Version     : ', Sdk.Manifest.FpcVersion);
  WriteLn('  Target Triplet  : ', Sdk.Manifest.TargetTriplet);
  if Sdk.Manifest.GitRef <> '' then
    WriteLn('  Git Reference   : ', Sdk.Manifest.GitRef);
  if Sdk.Manifest.GitCommit <> '' then
    WriteLn('  Git Commit      : ', Sdk.Manifest.GitCommit);
  if Sdk.Manifest.BuiltAtUtc <> '' then
    WriteLn('  Built At (UTC)  : ', Sdk.Manifest.BuiltAtUtc);
  WriteLn('  Install Size    : ', FormatByteSize(SdkSizeBytes));
  WriteLn('  Install Path    : ', FormatPathStatus(Sdk.InstallPath, True));
  WriteLn('  Compiler Binary : ', FormatPathStatus(FpcBin, False));
  WriteLn('  Compiler Config : ', FormatPathStatus(FpcCfg, False));
  WriteLn('  Units Directory : ', FormatPathStatus(UnitsDir, True));
  WriteLn('  RTL Sources     : ', FormatPathStatus(RtlDir, True));
  WriteLn('  Package Sources : ', FormatPathStatus(PkgDir, True));
  Result := 0;
end;

function ExecuteSdkCommand(const AArgs: array of string): Integer;
var
  SubCmd: string;
  SubArgs: array of string;
  I: Integer;
begin
  if Length(AArgs) = 0 then
  begin
    PrintSdkHelp;
    Exit(0);
  end;

  SubCmd := LowerCase(Trim(AArgs[0]));
  if (SubCmd = 'help') or (SubCmd = '-h') or (SubCmd = '--help') then
  begin
    PrintSdkHelp;
    Exit(0);
  end;

  SubArgs := nil;
  if Length(AArgs) > 1 then
  begin
    SetLength(SubArgs, Length(AArgs) - 1);
    for I := 1 to High(AArgs) do
      SubArgs[I - 1] := AArgs[I];
  end;

  if (SubCmd = 'list') or (SubCmd = 'ls') then
    Result := ExecuteSdkList(SubArgs)
  else if (SubCmd = 'install') or (SubCmd = 'i') or (SubCmd = 'add') then
    Result := ExecuteSdkInstall(SubArgs)
  else if (SubCmd = 'update') or (SubCmd = 'upgrade') or (SubCmd = 'up') then
    Result := ExecuteSdkUpdate(SubArgs)
  else if (SubCmd = 'uninstall') or (SubCmd = 'remove') or (SubCmd = 'rm') then
    Result := ExecuteSdkUninstall(SubArgs)
  else if (SubCmd = 'info') or (SubCmd = 'status') then
    Result := ExecuteSdkInfo(SubArgs)
  else
    raise ENikError.CreateFmt(
      'Unknown sdk subcommand ''%s''. Run ''nik sdk --help'' for usage.',
      [AArgs[0]]);
end;

end.
