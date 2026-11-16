unit nik.http;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, nik.types;

function HttpGetText(const AUrl: string): string;
procedure HttpDownloadFile(const AUrl, ADestPath: string;
  AProgress: TDownloadProgressProc = nil; AExpectedSize: Int64 = 0);

implementation

uses
  nik.paths, nik.fs
  {$IFDEF WINDOWS}
  , Windows, WinInet
  {$ELSE}
  , Process
  {$ENDIF};

function StartsWithIgnoreCase(const AText, APrefix: string): Boolean;
begin
  Result := (Length(AText) >= Length(APrefix)) and
            SameText(Copy(AText, 1, Length(APrefix)), APrefix);
end;

function DecodePercentUri(const AValue: string): string;
var
  I, HexVal, Code: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(AValue) do
  begin
    if (AValue[I] = '%') and (I + 2 <= Length(AValue)) then
    begin
      Val('$' + Copy(AValue, I + 1, 2), HexVal, Code);
      if Code = 0 then
      begin
        Result := Result + Char(Byte(HexVal));
        Inc(I, 3);
        Continue;
      end;
    end;
    Result := Result + AValue[I];
    Inc(I);
  end;
end;

function TryResolveLocalFileUrl(const AUrl: string; out ALocalPath: string): Boolean;
var
  RawPath: string;
begin
  ALocalPath := '';
  if StartsWithIgnoreCase(AUrl, 'http://') or StartsWithIgnoreCase(AUrl, 'https://') then
    Exit(False);

  if StartsWithIgnoreCase(AUrl, 'file://') then
  begin
    RawPath := Copy(AUrl, 8, MaxInt);
    {$IFDEF WINDOWS}
    if StartsWithIgnoreCase(RawPath, 'localhost/') then
      Delete(RawPath, 1, 10)
    else if (Length(RawPath) >= 3) and (RawPath[1] = '/') and (RawPath[3] = ':') then
      Delete(RawPath, 1, 1);
    {$ELSE}
    if StartsWithIgnoreCase(RawPath, 'localhost/') then
      Delete(RawPath, 1, 9);
    {$ENDIF}
    ALocalPath := NormalizeNativeSeparators(DecodePercentUri(RawPath));
    Exit(True);
  end;

  ALocalPath := NormalizeNativeSeparators(AUrl);
  Result := True;
end;

procedure CopyLocalFileWithProgress(const ASrcPath, ADestPath: string;
  AProgress: TDownloadProgressProc);
const
  BUF_SIZE = 65536;
var
  InStream, OutStream: TFileStream;
  Buf: array[0..BUF_SIZE - 1] of Byte;
  BytesRead: LongInt;
  TotalRead, TotalSize: Int64;
  LastTick, NowTick: QWord;
begin
  if not FileExists(ASrcPath) then
    raise ENikError.CreateFmt('File not found: %s', [ASrcPath]);

  EnsureDirExists(ExtractFileDir(ADestPath));
  InStream := TFileStream.Create(ASrcPath, fmOpenRead or fmShareDenyWrite);
  try
    TotalSize := InStream.Size;
    OutStream := TFileStream.Create(ADestPath, fmCreate);
    try
      TotalRead := 0;
      LastTick := 0;
      repeat
        BytesRead := InStream.Read(Buf[0], BUF_SIZE);
        if BytesRead > 0 then
        begin
          OutStream.WriteBuffer(Buf[0], BytesRead);
          Inc(TotalRead, BytesRead);
          if Assigned(AProgress) then
          begin
            NowTick := GetTickCount64;
            if (NowTick - LastTick >= 60) or (TotalRead = TotalSize) then
            begin
              AProgress(TotalRead, TotalSize);
              LastTick := NowTick;
            end;
          end;
        end;
      until BytesRead <= 0;
    finally
      OutStream.Free;
    end;
  finally
    InStream.Free;
  end;
end;

{$IFDEF WINDOWS}
const
  WININET_FLAG_RELOAD         = DWORD($80000000);
  WININET_FLAG_NO_CACHE_WRITE = DWORD($04000000);
  WININET_FLAG_SECURE         = DWORD($00800000);
  WININET_FLAG_NO_COOKIES     = DWORD($00080000);
  WININET_FLAG_NO_UI          = DWORD($00000200);

procedure WinInetDownloadToStream(const AUrl: string; AOutStream: TStream;
  AProgress: TDownloadProgressProc; AExpectedSize: Int64);
const
  BUF_SIZE = 65536;
var
  AgentW, UrlW: UnicodeString;
  HInet, HUrl: HINTERNET;
  Flags: DWORD;
  StatusCode, StatusSize, HeaderIdx: DWORD;
  LenBuf: array[0..63] of WideChar;
  LenBufSize: DWORD;
  TotalBytes, TotalRead: Int64;
  Buf: array[0..BUF_SIZE - 1] of Byte;
  ChunkRead: DWORD;
  LastTick, NowTick: QWord;
  WinErr: DWORD;
begin
  AgentW := UnicodeString('nik-cli/' + NIK_VERSION);
  UrlW := UnicodeString(AUrl);

  HInet := InternetOpenW(PWideChar(AgentW), INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if HInet = nil then
    raise ENikError.CreateFmt('Failed to initialize HTTP client (WinInet error %d).', [GetLastError]);

  try
    Flags := WININET_FLAG_RELOAD or WININET_FLAG_NO_CACHE_WRITE or
             WININET_FLAG_NO_COOKIES or WININET_FLAG_NO_UI;
    if StartsWithIgnoreCase(AUrl, 'https://') then
      Flags := Flags or WININET_FLAG_SECURE;

    HUrl := InternetOpenUrlW(HInet, PWideChar(UrlW), nil, 0, Flags, 0);
    if HUrl = nil then
    begin
      WinErr := GetLastError;
      raise ENikError.CreateFmt('Network request failed for %s (WinInet error %d).', [AUrl, WinErr]);
    end;

    try
      StatusCode := 0;
      StatusSize := SizeOf(StatusCode);
      HeaderIdx := 0;
      if HttpQueryInfoW(HUrl, HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER,
                        @StatusCode, @StatusSize, @HeaderIdx) then
      begin
        if (StatusCode < 200) or (StatusCode >= 300) then
          raise ENikError.CreateFmt('HTTP %d while fetching %s', [StatusCode, AUrl]);
      end;

      TotalBytes := AExpectedSize;
      FillChar(LenBuf, SizeOf(LenBuf), 0);
      LenBufSize := SizeOf(LenBuf) - SizeOf(WideChar);
      HeaderIdx := 0;
      if HttpQueryInfoW(HUrl, HTTP_QUERY_CONTENT_LENGTH, @LenBuf[0], @LenBufSize, @HeaderIdx) then
        TotalBytes := StrToInt64Def(Trim(UTF8Encode(UnicodeString(PWideChar(@LenBuf[0])))), AExpectedSize);

      TotalRead := 0;
      LastTick := 0;
      while True do
      begin
        ChunkRead := 0;
        if not InternetReadFile(HUrl, @Buf[0], BUF_SIZE, @ChunkRead) then
          raise ENikError.CreateFmt('Error while reading HTTP stream from %s (WinInet error %d).',
            [AUrl, GetLastError]);

        if ChunkRead = 0 then
          Break;

        AOutStream.WriteBuffer(Buf[0], ChunkRead);
        Inc(TotalRead, ChunkRead);

        if Assigned(AProgress) then
        begin
          NowTick := GetTickCount64;
          if (NowTick - LastTick >= 60) then
          begin
            AProgress(TotalRead, TotalBytes);
            LastTick := NowTick;
          end;
        end;
      end;

      if Assigned(AProgress) then
        AProgress(TotalRead, TotalBytes);
    finally
      InternetCloseHandle(HUrl);
    end;
  finally
    InternetCloseHandle(HInet);
  end;
end;
{$ELSE}
procedure UnixDownloadToFile(const AUrl, ADestPath: string; AShowProgress: Boolean);
var
  CurlBin, WgetBin: string;
  Proc: TProcess;
  ErrStream: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N: LongInt;
  ErrMsg: RawByteString;
begin
  EnsureDirExists(ExtractFileDir(ADestPath));
  CurlBin := FindExecutableInPath('curl');
  WgetBin := '';
  if CurlBin = '' then
    WgetBin := FindExecutableInPath('wget');

  if (CurlBin = '') and (WgetBin = '') then
    raise ENikError.Create('Neither ''curl'' nor ''wget'' was found in PATH to perform HTTPS downloads.');

  Proc := TProcess.Create(nil);
  ErrStream := TMemoryStream.Create;
  try
    if CurlBin <> '' then
    begin
      Proc.Executable := CurlBin;
      Proc.Parameters.Add('-fSL');
      if not AShowProgress then
        Proc.Parameters.Add('-s')
      else
        Proc.Parameters.Add('-#');
      Proc.Parameters.Add('-A');
      Proc.Parameters.Add('nik-cli/' + NIK_VERSION);
      Proc.Parameters.Add('-o');
      Proc.Parameters.Add(ADestPath);
      Proc.Parameters.Add(AUrl);
    end
    else
    begin
      Proc.Executable := WgetBin;
      if not AShowProgress then
        Proc.Parameters.Add('-q');
      Proc.Parameters.Add('-U');
      Proc.Parameters.Add('nik-cli/' + NIK_VERSION);
      Proc.Parameters.Add('-O');
      Proc.Parameters.Add(ADestPath);
      Proc.Parameters.Add(AUrl);
    end;

    if AShowProgress then
      Proc.Options := [poWaitOnExit]
    else
      Proc.Options := [poUsePipes];

    Proc.Execute;
    if not AShowProgress then
    begin
      while Proc.Running or (Proc.Stderr.NumBytesAvailable > 0) do
      begin
        while Proc.Stderr.NumBytesAvailable > 0 do
        begin
          N := Proc.Stderr.Read(Buf[0], SizeOf(Buf));
          if N > 0 then
            ErrStream.WriteBuffer(Buf[0], N);
        end;
        if Proc.Running then
          Sleep(15);
      end;
    end;

    Proc.WaitOnExit;
    if (Proc.ExitCode <> 0) or (Proc.ExitStatus <> 0) then
    begin
      SetLength(ErrMsg, ErrStream.Size);
      if ErrStream.Size > 0 then
      begin
        ErrStream.Position := 0;
        ErrStream.ReadBuffer(ErrMsg[1], ErrStream.Size);
      end;
      ErrMsg := Trim(ErrMsg);
      if ErrMsg <> '' then
        raise ENikError.CreateFmt('Download failed for %s: %s', [AUrl, ErrMsg])
      else if Proc.ExitCode <> 0 then
        raise ENikError.CreateFmt('Download failed for %s (exit code %d).', [AUrl, Proc.ExitCode])
      else
        raise ENikError.CreateFmt('Download failed for %s (signal %d).', [AUrl, Proc.ExitStatus and $7F]);
    end;
  finally
    ErrStream.Free;
    Proc.Free;
  end;
end;
{$ENDIF}

function HttpGetText(const AUrl: string): string;
var
  LocalPath: string;
  SL: TStringList;
{$IFDEF WINDOWS}
  MS: TMemoryStream;
  Raw: RawByteString;
{$ELSE}
  TmpFile: string;
{$ENDIF}
begin
  if TryResolveLocalFileUrl(AUrl, LocalPath) then
  begin
    if not FileExists(LocalPath) then
      raise ENikError.CreateFmt('File not found: %s', [LocalPath]);
    SL := TStringList.Create;
    try
      SL.LoadFromFile(LocalPath);
      Result := SL.Text;
    finally
      SL.Free;
    end;
    Exit;
  end;

{$IFDEF WINDOWS}
  MS := TMemoryStream.Create;
  try
    WinInetDownloadToStream(AUrl, MS, nil, 0);
    SetLength(Raw, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.ReadBuffer(Raw[1], MS.Size);
    end;
    Result := string(Raw);
  finally
    MS.Free;
  end;
{$ELSE}
  EnsureDirExists(GetNikrunCacheDir);
  TmpFile := JoinPath(GetNikrunCacheDir, Format('http-get-%d-%d.tmp', [GetProcessID, GetTickCount64]));
  try
    UnixDownloadToFile(AUrl, TmpFile, False);
    SL := TStringList.Create;
    try
      SL.LoadFromFile(TmpFile);
      Result := SL.Text;
    finally
      SL.Free;
    end;
  finally
    if FileExists(TmpFile) then
      DeleteFile(TmpFile);
  end;
{$ENDIF}
end;

procedure HttpDownloadFile(const AUrl, ADestPath: string;
  AProgress: TDownloadProgressProc; AExpectedSize: Int64);
var
  LocalPath: string;
{$IFDEF WINDOWS}
  FS: TFileStream;
{$ENDIF}
begin
  if TryResolveLocalFileUrl(AUrl, LocalPath) then
  begin
    CopyLocalFileWithProgress(LocalPath, ADestPath, AProgress);
    Exit;
  end;

  EnsureDirExists(ExtractFileDir(ADestPath));
{$IFDEF WINDOWS}
  FS := TFileStream.Create(ADestPath, fmCreate);
  try
    WinInetDownloadToStream(AUrl, FS, AProgress, AExpectedSize);
  except
    FS.Free;
    if FileExists(ADestPath) then
      SysUtils.DeleteFile(ADestPath);
    raise;
  end;
  FS.Free;
{$ELSE}
  try
    UnixDownloadToFile(AUrl, ADestPath, Assigned(AProgress));
  except
    if FileExists(ADestPath) then
      DeleteFile(ADestPath);
    raise;
  end;
{$ENDIF}
end;

end.
