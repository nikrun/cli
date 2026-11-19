unit nik.sdk.config;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, nik.types;

function UtcNowIso8601: string;

function LoadSdkManifest(const ASdkDir: string): TSdkManifest;
function TryLoadSdkManifest(const ASdkDir: string; out AManifest: TSdkManifest): Boolean;

function ParseSdkIndexJson(const AJsonText: string): TSdkIndex;

function GenerateFpcCfgForSdk(const ASdkPath: string; const AManifest: TSdkManifest): string;

implementation

uses
  DateUtils, Process, nik.paths, nik.fs;

function UtcNowIso8601: string;
var
  UtcDt: TDateTime;
begin
  UtcDt := LocalTimeToUniversal(Now);
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', UtcDt);
end;

function GetJsonStr(AObj: TJSONObject; const AKey: string; const ADefault: string = ''): string;
var
  Item: TJSONData;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;
  Item := AObj.Find(AKey);
  if (Item <> nil) and (not Item.IsNull) then
    Result := Item.AsString;
end;

function GetJsonInt(AObj: TJSONObject; const AKey: string; ADefault: Integer = 0): Integer;
var
  Item: TJSONData;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;
  Item := AObj.Find(AKey);
  if (Item <> nil) and (Item.JSONType = jtNumber) then
    Result := Item.AsInteger;
end;

function GetJsonInt64(AObj: TJSONObject; const AKey: string; ADefault: Int64 = 0): Int64;
var
  Item: TJSONData;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;
  Item := AObj.Find(AKey);
  if (Item <> nil) and (Item.JSONType = jtNumber) then
    Result := Item.AsInt64;
end;

function LoadSdkManifest(const ASdkDir: string): TSdkManifest;
var
  ManifestFile: string;
  Data: TJSONData;
  Root, PathsObj: TJSONObject;
  PathsNode: TJSONData;
begin
  Result := Default(TSdkManifest);
  ManifestFile := JoinPath(ASdkDir, 'sdk-manifest.json');
  if not FileExists(ManifestFile) then
    raise ENikError.CreateFmt('Invalid SDK directory (sdk-manifest.json missing): %s', [ASdkDir]);

  try
    Data := GetJSON(ReadFileTextUtf8(ManifestFile));
  except
    on E: Exception do
      raise ENikError.CreateFmt('Failed to parse %s: %s', [ManifestFile, E.Message]);
  end;

  try
    if not (Data is TJSONObject) then
      raise ENikError.CreateFmt('Invalid JSON root in %s (expected object).', [ManifestFile]);

    Root := TJSONObject(Data);
    Result.SchemaVersion := GetJsonInt(Root, 'schemaVersion', 1);
    Result.SdkId         := GetJsonStr(Root, 'sdkId');
    Result.FpcVersion    := GetJsonStr(Root, 'fpcVersion');
    Result.GitRepo       := GetJsonStr(Root, 'gitRepo');
    Result.GitRef        := GetJsonStr(Root, 'gitRef');
    Result.GitCommit     := GetJsonStr(Root, 'gitCommit');
    Result.TargetOs      := GetJsonStr(Root, 'targetOs');
    Result.TargetCpu     := GetJsonStr(Root, 'targetCpu');
    Result.TargetTriplet := GetJsonStr(Root, 'targetTriplet');
    Result.BuiltAtUtc    := GetJsonStr(Root, 'builtAtUtc');

    PathsNode := Root.Find('paths');
    if (PathsNode <> nil) and (PathsNode is TJSONObject) then
    begin
      PathsObj := TJSONObject(PathsNode);
      Result.Paths.BinDir            := GetJsonStr(PathsObj, 'binDir');
      Result.Paths.FpcBinary         := GetJsonStr(PathsObj, 'fpcBinary');
      Result.Paths.PpcBinary         := GetJsonStr(PathsObj, 'ppcBinary');
      Result.Paths.FpcmkcfgBinary    := GetJsonStr(PathsObj, 'fpcmkcfgBinary');
      Result.Paths.UnitsDir          := GetJsonStr(PathsObj, 'unitsDir');
      Result.Paths.RtlSourceDir      := GetJsonStr(PathsObj, 'rtlSourceDir');
      Result.Paths.PackagesSourceDir := GetJsonStr(PathsObj, 'packagesSourceDir');
    end;

    if (Result.SdkId = '') or (Result.Paths.FpcBinary = '') then
      raise ENikError.CreateFmt('Incomplete SDK manifest in %s.', [ManifestFile]);
  finally
    Data.Free;
  end;
end;

function TryLoadSdkManifest(const ASdkDir: string; out AManifest: TSdkManifest): Boolean;
begin
  Result := False;
  AManifest := Default(TSdkManifest);
  if not FileExists(JoinPath(ASdkDir, 'sdk-manifest.json')) then
    Exit;
  try
    AManifest := LoadSdkManifest(ASdkDir);
    Result := True;
  except
    Result := False;
  end;
end;

function CompareRemoteEntry(const A, B: TRemoteSdkEntry): Integer;
begin
  Result := CompareText(A.FpcVersion, B.FpcVersion);
  if Result <> 0 then Exit;
  Result := CompareText(A.TargetOs, B.TargetOs);
  if Result <> 0 then Exit;
  Result := CompareText(A.TargetCpu, B.TargetCpu);
  if Result <> 0 then Exit;
  // Prefer newer builds first when multiple snapshots exist for the same version/target
  Result := CompareText(B.BuiltAtUtc, A.BuiltAtUtc);
  if Result <> 0 then Exit;
  Result := CompareText(A.SdkId, B.SdkId);
end;

procedure SortRemoteEntries(var AEntries: TRemoteSdkArray);
var
  I, J: Integer;
  Tmp: TRemoteSdkEntry;
begin
  for I := 0 to High(AEntries) - 1 do
    for J := I + 1 to High(AEntries) do
      if CompareRemoteEntry(AEntries[J], AEntries[I]) < 0 then
      begin
        Tmp := AEntries[I];
        AEntries[I] := AEntries[J];
        AEntries[J] := Tmp;
      end;
end;

function ParseSdkIndexJson(const AJsonText: string): TSdkIndex;
var
  Data, SdksNode, ItemNode: TJSONData;
  Root, ItemObj: TJSONObject;
  Arr: TJSONArray;
  I, Count: Integer;
begin
  Result := Default(TSdkIndex);
  try
    Data := GetJSON(StripUtf8Bom(AJsonText));
  except
    on E: Exception do
      raise ENikError.CreateFmt('Failed to parse index.json: %s', [E.Message]);
  end;

  try
    if not (Data is TJSONObject) then
      raise ENikError.Create('Invalid index.json format (expected JSON object).');

    Root := TJSONObject(Data);
    Result.SchemaVersion := GetJsonInt(Root, 'schemaVersion', 1);
    Result.ReleaseTag    := GetJsonStr(Root, 'releaseTag');
    Result.UpdatedAtUtc  := GetJsonStr(Root, 'updatedAtUtc');

    SdksNode := Root.Find('sdks');
    if (SdksNode = nil) or (not (SdksNode is TJSONArray)) then
      raise ENikError.Create('Invalid index.json format (missing "sdks" array).');

    Arr := TJSONArray(SdksNode);
    SetLength(Result.Sdks, Arr.Count);
    Count := 0;
    for I := 0 to Arr.Count - 1 do
    begin
      ItemNode := Arr.Items[I];
      if not (ItemNode is TJSONObject) then
        Continue;
      ItemObj := TJSONObject(ItemNode);
      Result.Sdks[Count].SdkId         := GetJsonStr(ItemObj, 'sdkId');
      Result.Sdks[Count].FpcVersion    := GetJsonStr(ItemObj, 'fpcVersion');
      Result.Sdks[Count].GitRepo       := GetJsonStr(ItemObj, 'gitRepo');
      Result.Sdks[Count].GitRef        := GetJsonStr(ItemObj, 'gitRef');
      Result.Sdks[Count].GitCommit     := LowerCase(Trim(GetJsonStr(ItemObj, 'gitCommit')));
      Result.Sdks[Count].TargetOs      := GetJsonStr(ItemObj, 'targetOs');
      Result.Sdks[Count].TargetCpu     := GetJsonStr(ItemObj, 'targetCpu');
      Result.Sdks[Count].TargetTriplet := GetJsonStr(ItemObj, 'targetTriplet');
      Result.Sdks[Count].BuiltAtUtc    := GetJsonStr(ItemObj, 'builtAtUtc');
      Result.Sdks[Count].FileName      := GetJsonStr(ItemObj, 'fileName');
      Result.Sdks[Count].SizeBytes     := GetJsonInt64(ItemObj, 'sizeBytes', 0);
      Result.Sdks[Count].Sha256        := LowerCase(Trim(GetJsonStr(ItemObj, 'sha256')));
      Result.Sdks[Count].DownloadUrl   := GetJsonStr(ItemObj, 'downloadUrl');
      if Result.Sdks[Count].SdkId <> '' then
        Inc(Count);
    end;
    SetLength(Result.Sdks, Count);
    SortRemoteEntries(Result.Sdks);
  finally
    Data.Free;
  end;
end;

function CaptureCommandFirstLine(const AExe: string; const AArgs: array of string): string;
var
  Proc: TProcess;
  OutStream: TMemoryStream;
  Buf: array[0..1023] of Byte;
  N: LongInt;
  Raw: RawByteString;
  SL: TStringList;
  I: Integer;
begin
  Result := '';
  if (AExe = '') or (not FileExists(AExe)) then
    Exit;

  Proc := TProcess.Create(nil);
  OutStream := TMemoryStream.Create;
  try
    Proc.Executable := AExe;
    for I := Low(AArgs) to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Options := [poUsePipes, poNoConsole];
    try
      Proc.Execute;
      while Proc.Running or (Proc.Output.NumBytesAvailable > 0) do
      begin
        while Proc.Output.NumBytesAvailable > 0 do
        begin
          N := Proc.Output.Read(Buf[0], SizeOf(Buf));
          if N > 0 then
            OutStream.WriteBuffer(Buf[0], N);
        end;
        if Proc.Running then
          Sleep(10);
      end;
      if Proc.ExitStatus = 0 then
      begin
        SetLength(Raw, OutStream.Size);
        if OutStream.Size > 0 then
        begin
          OutStream.Position := 0;
          OutStream.ReadBuffer(Raw[1], OutStream.Size);
        end;
        SL := TStringList.Create;
        try
          SL.Text := string(Raw);
          if SL.Count > 0 then
            Result := Trim(SL[0]);
        finally
          SL.Free;
        end;
      end;
    except
      Result := '';
    end;
  finally
    OutStream.Free;
    Proc.Free;
  end;
end;

function BuildExtraPlatformFpcCfg(const AManifest: TSdkManifest): string;
var
  Lines: TStringList;
  MinMacOs, XcrunBin, MacSdk, GccBin, CrtBegin, GccLibDir, Candidate: string;
  LinuxCandidates: array[0..5] of string;
  I: Integer;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    if SameText(AManifest.TargetOs, 'darwin') then
    begin
      if SameText(AManifest.TargetCpu, 'aarch64') then
        MinMacOs := '11.0'
      else
        MinMacOs := '10.15';
      Lines.Add('-WM' + MinMacOs);

      XcrunBin := FindExecutableInPath('xcrun');
      if XcrunBin <> '' then
      begin
        MacSdk := CaptureCommandFirstLine(XcrunBin, ['--show-sdk-path']);
        if MacSdk <> '' then
        begin
          Lines.Add('-XR' + MacSdk);
          if DirectoryExists(MacSdk + '/usr/lib') then
            Lines.Add('-Fl' + MacSdk + '/usr/lib');
        end;
      end;

      if DirectoryExists('/Library/Developer/CommandLineTools/usr/bin') then
        Lines.Add('-FD/Library/Developer/CommandLineTools/usr/bin');

      if Lines.Count > 0 then
        Result := LineEnding + '# macOS SDK sysroot, library stubs, and toolchain paths' +
                  LineEnding + TrimRight(Lines.Text);
    end
    else if SameText(AManifest.TargetOs, 'linux') then
    begin
      LinuxCandidates[0] := '/lib/' + AManifest.TargetCpu + '-linux-gnu';
      LinuxCandidates[1] := '/usr/lib/' + AManifest.TargetCpu + '-linux-gnu';
      LinuxCandidates[2] := '/lib64';
      LinuxCandidates[3] := '/usr/lib64';
      LinuxCandidates[4] := '/lib';
      LinuxCandidates[5] := '/usr/lib';
      for I := Low(LinuxCandidates) to High(LinuxCandidates) do
      begin
        Candidate := LinuxCandidates[I];
        if DirectoryExists(Candidate) then
          Lines.Add('-Fl' + Candidate);
      end;

      GccBin := FindExecutableInPath('gcc');
      if GccBin <> '' then
      begin
        CrtBegin := CaptureCommandFirstLine(GccBin, ['-print-file-name=crtbegin.o']);
        if (CrtBegin <> '') and FileExists(CrtBegin) then
        begin
          GccLibDir := ExtractFileDir(CrtBegin);
          if GccLibDir <> '' then
            Lines.Add('-Fl' + NormalizeForwardSlashes(GccLibDir));
        end;
      end;

      if SameText(AManifest.TargetCpu, 'aarch64') then
      begin
        Lines.Add('-k--defsym=__libc_csu_init=0');
        Lines.Add('-k--defsym=__libc_csu_fini=0');
      end;

      if Lines.Count > 0 then
        Result := LineEnding + '# System C library search paths' +
                  LineEnding + TrimRight(Lines.Text);
    end;
  finally
    Lines.Free;
  end;
end;

function GenerateFpcCfgForSdk(const ASdkPath: string; const AManifest: TSdkManifest): string;
var
  BinDir, UnitsDir, NormalizedBin, NormalizedUnits, ExtraCfg, CfgPath, UnixEtcDir: string;
  SL: TStringList;
begin
  BinDir := JoinPath(ASdkPath, AManifest.Paths.BinDir);
  UnitsDir := JoinPath(ASdkPath, AManifest.Paths.UnitsDir);
  NormalizedBin := NormalizeForwardSlashes(BinDir);
  NormalizedUnits := NormalizeForwardSlashes(UnitsDir);
  ExtraCfg := BuildExtraPlatformFpcCfg(AManifest);

  SL := TStringList.Create;
  try
    SL.Add('# ==============================================================================');
    SL.Add('# Nikrun Portable Free Pascal SDK Configuration (Auto-generated)');
    SL.Add(Format('# SDK: %s (FPC %s, %s)', [AManifest.SdkId, AManifest.FpcVersion, AManifest.TargetTriplet]));
    SL.Add('# ==============================================================================');
    SL.Add('');
    SL.Add('# Default to Object Pascal mode with AnsiStrings unless overridden in source');
    SL.Add('-Mobjfpc');
    SL.Add('-Sh');
    SL.Add('-Sc');
    SL.Add('-Si');
    SL.Add('');
    SL.Add('# Enable DWARF debug info & line info when -dDEBUG is passed, strip in -dRELEASE');
    SL.Add('#IFDEF DEBUG');
    SL.Add('-gl');
    SL.Add('-gw2');
    SL.Add('-Cr');
    SL.Add('-Ci');
    SL.Add('-Co');
    SL.Add('#ENDIF');
    SL.Add('');
    SL.Add('#IFDEF RELEASE');
    SL.Add('-O2');
    SL.Add('-Xs');
    SL.Add('-CX');
    SL.Add('-XX');
    SL.Add('#ENDIF');
    SL.Add('');
    SL.Add('# Unit search paths (RTL & Packages)');
    SL.Add('-Fu' + NormalizedUnits);
    SL.Add('-Fu' + NormalizedUnits + '/*');
    SL.Add('-Fu' + NormalizedUnits + '/rtl');
    SL.Add('');
    SL.Add('# Binary & Binutils search path (ld, as, ar, windres)');
    SL.Add('-FD' + NormalizedBin);
    SL.Add('');
    SL.Add('# Library search path');
    SL.Add('-Fl' + NormalizedUnits + ExtraCfg);
    SL.Add('');
    SL.Add('# Display errors, warnings, and notes with full file paths for IDE Problem Matchers');
    SL.Add('-viwn');
    SL.Add('-vb');
    SL.Add('-l-');

    CfgPath := JoinPath(BinDir, 'fpc.cfg');
    WriteFileTextUtf8(CfgPath, SL.Text);

    // Also populate bin/etc/fpc.cfg so Unix FPC resolves ../etc/fpc.cfg automatically
    UnixEtcDir := JoinPath(ExtractFileDir(ExcludeTrailingPathDelimiter(BinDir)), 'etc');
    EnsureDirExists(UnixEtcDir);
    WriteFileTextUtf8(JoinPath(UnixEtcDir, 'fpc.cfg'), SL.Text);

    Result := CfgPath;
  finally
    SL.Free;
  end;
end;

end.
