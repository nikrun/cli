unit nikrun.lsp.transport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ssockets,
  {$IFDEF WINDOWS}
  Windows, Winsock2,
  {$ENDIF}
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  nikrun.lsp.types;

const
  LSP_MAX_FRAME_BYTES = 64 * 1024 * 1024; // 64 MiB safety cap

type
  TLspTransport = class
  private
    FWriteLock: TRTLCriticalSection;
  protected
    procedure DoWriteMessage(const APayload: string); virtual; abstract;
  public
    constructor Create;
    destructor Destroy; override;
    { Waits up to ATimeoutMs for incoming bytes or EOF.
      ATimeoutMs < 0 indicates blocking mode and returns True immediately. }
    function WaitForInput(ATimeoutMs: Integer): Boolean; virtual;
    { Reads a single framed JSON-RPC UTF-8 payload. Returns False on clean EOF. }
    function ReadMessage(out APayload: string): Boolean; virtual; abstract;
    { Thread-safe: writes a single UTF-8 payload framed with Content-Length header. }
    procedure WriteMessage(const APayload: string);
  end;

  TLspStreamTransport = class(TLspTransport)
  private
    FInput: TStream;
    FOutput: TStream;
    FOwnsStreams: Boolean;
    function ReadByte(out AByte: Byte): Boolean;
    function ReadHeaderLine(out ALine: string; out AReachedEof: Boolean): Boolean;
    procedure ReadExactBytes(ABuffer: PByte; ACount: Integer);
    procedure WriteAllBytes(ABuffer: PByte; ACount: Integer);
  protected
    procedure DoWriteMessage(const APayload: string); override;
  public
    constructor Create(AInput, AOutput: TStream; AOwnsStreams: Boolean = False);
    destructor Destroy; override;
    function ReadMessage(out APayload: string): Boolean; override;
  end;

  { Binary stdio transport that reads/writes OS handles directly and optionally
    redirects standard Pascal Output (Write/WriteLn) to stderr so stray console
    writes cannot corrupt the JSON-RPC protocol stream. }
  TLspStdioTransport = class(TLspTransport)
  private
    FInHandle: THandle;
    FOutHandle: THandle;
    FSavedTextOutHandle: THandle;
    FGuardingStdout: Boolean;
    FInStream: THandleStream;
    FOutStream: THandleStream;
    FInner: TLspStreamTransport;
  protected
    procedure DoWriteMessage(const APayload: string); override;
  public
    constructor Create(AGuardStdout: Boolean = True);
    destructor Destroy; override;
    function WaitForInput(ATimeoutMs: Integer): Boolean; override;
    function ReadMessage(out APayload: string): Boolean; override;
  end;

  { Loopback TCP server transport (127.0.0.1:<port>) for live LSP/DAP debugging.
    Waits for a single client connection on first ReadMessage/WriteMessage. }
  TLspTcpServerTransport = class(TLspTransport)
  private
    FPort: Word;
    FServer: TInetServer;
    FClientStream: TSocketStream;
    FInner: TLspStreamTransport;
    procedure EnsureConnected;
  protected
    procedure DoWriteMessage(const APayload: string); override;
  public
    constructor Create(APort: Word);
    destructor Destroy; override;
    function WaitForInput(ATimeoutMs: Integer): Boolean; override;
    function ReadMessage(out APayload: string): Boolean; override;
    property Port: Word read FPort;
  end;

implementation

{ TLspTransport }

constructor TLspTransport.Create;
begin
  inherited Create;
  InitCriticalSection(FWriteLock);
end;

destructor TLspTransport.Destroy;
begin
  DoneCriticalSection(FWriteLock);
  inherited Destroy;
end;

function TLspTransport.WaitForInput(ATimeoutMs: Integer): Boolean;
begin
  Result := True;
end;

procedure TLspTransport.WriteMessage(const APayload: string);
begin
  EnterCriticalSection(FWriteLock);
  try
    DoWriteMessage(APayload);
  finally
    LeaveCriticalSection(FWriteLock);
  end;
end;

{ TLspStreamTransport }

constructor TLspStreamTransport.Create(AInput, AOutput: TStream; AOwnsStreams: Boolean);
begin
  inherited Create;
  if (AInput = nil) and (AOutput = nil) then
    raise ELspError.Create('TLspStreamTransport requires at least an input or output stream.');
  FInput := AInput;
  FOutput := AOutput;
  FOwnsStreams := AOwnsStreams;
end;

destructor TLspStreamTransport.Destroy;
begin
  if FOwnsStreams then
  begin
    if FOutput = FInput then
      FOutput := nil;
    FreeAndNil(FInput);
    FreeAndNil(FOutput);
  end;
  inherited Destroy;
end;

function TLspStreamTransport.ReadByte(out AByte: Byte): Boolean;
var
  N: LongInt;
begin
  AByte := 0;
  if FInput = nil then
    Exit(False);
  N := FInput.Read(AByte, 1);
  Result := N = 1;
end;

function TLspStreamTransport.ReadHeaderLine(out ALine: string; out AReachedEof: Boolean): Boolean;
var
  B: Byte;
  Len, Cap: Integer;
begin
  ALine := '';
  AReachedEof := False;
  Len := 0;
  Cap := 0;

  while True do
  begin
    if not ReadByte(B) then
    begin
      if Len = 0 then
      begin
        AReachedEof := True;
        Exit(False);
      end;
      SetLength(ALine, Len);
      Exit(True);
    end;

    if B = 10 then // LF
    begin
      if (Len > 0) and (ALine[Len] = #13) then
        Dec(Len);
      SetLength(ALine, Len);
      Exit(True);
    end;

    Inc(Len);
    if Len > 8192 then
      raise ELspProtocolError.Create(LSP_ERR_PARSE_ERROR, 'LSP header line exceeds 8192 bytes.');
    if Len > Cap then
    begin
      Cap := Cap + 128;
      SetLength(ALine, Cap);
    end;
    ALine[Len] := Char(B);
  end;
end;

procedure TLspStreamTransport.ReadExactBytes(ABuffer: PByte; ACount: Integer);
var
  TotalRead, N: LongInt;
begin
  TotalRead := 0;
  while TotalRead < ACount do
  begin
    N := FInput.Read(ABuffer[TotalRead], ACount - TotalRead);
    if N <= 0 then
      raise ELspProtocolError.Create(LSP_ERR_PARSE_ERROR,
        Format('Unexpected EOF while reading JSON-RPC payload (%d of %d bytes read).',
          [TotalRead, ACount]));
    Inc(TotalRead, N);
  end;
end;

procedure TLspStreamTransport.WriteAllBytes(ABuffer: PByte; ACount: Integer);
var
  TotalWritten, N: LongInt;
begin
  if FOutput = nil then
    raise ELspError.Create('Cannot write JSON-RPC message: output stream is nil.');
  TotalWritten := 0;
  while TotalWritten < ACount do
  begin
    N := FOutput.Write(ABuffer[TotalWritten], ACount - TotalWritten);
    if N <= 0 then
      raise ELspError.Create('Failed to write JSON-RPC frame to output stream.');
    Inc(TotalWritten, N);
  end;
end;

function TLspStreamTransport.ReadMessage(out APayload: string): Boolean;
var
  Line, HeaderName, HeaderVal: string;
  ReachedEof, SawAnyHeader: Boolean;
  ColonPos, ContentLen, ErrCode: Integer;
begin
  APayload := '';
  ContentLen := -1;
  SawAnyHeader := False;

  while True do
  begin
    if not ReadHeaderLine(Line, ReachedEof) then
    begin
      if ReachedEof and (not SawAnyHeader) then
        Exit(False);
      raise ELspProtocolError.Create(LSP_ERR_PARSE_ERROR, 'Incomplete JSON-RPC header block.');
    end;

    // Ignore leading blank lines before headers if any
    if (Line = '') and (not SawAnyHeader) then
      Continue;

    if Line = '' then
      Break;

    SawAnyHeader := True;
    ColonPos := Pos(':', Line);
    if ColonPos <= 1 then
      raise ELspProtocolError.Create(LSP_ERR_PARSE_ERROR,
        Format('Malformed JSON-RPC header line: ''%s''', [Line]));

    HeaderName := LowerCase(Trim(Copy(Line, 1, ColonPos - 1)));
    HeaderVal := Trim(Copy(Line, ColonPos + 1, MaxInt));
    if HeaderName = 'content-length' then
    begin
      Val(HeaderVal, ContentLen, ErrCode);
      if (ErrCode <> 0) or (ContentLen < 0) or (ContentLen > LSP_MAX_FRAME_BYTES) then
        raise ELspProtocolError.Create(LSP_ERR_PARSE_ERROR,
          Format('Invalid Content-Length value: ''%s''', [HeaderVal]));
    end;
  end;

  if ContentLen < 0 then
    raise ELspProtocolError.Create(LSP_ERR_PARSE_ERROR, 'Missing Content-Length header in JSON-RPC frame.');

  SetLength(APayload, ContentLen);
  if ContentLen > 0 then
    ReadExactBytes(PByte(@APayload[1]), ContentLen);
  Result := True;
end;

procedure TLspStreamTransport.DoWriteMessage(const APayload: string);
var
  Frame: string;
begin
  Frame := 'Content-Length: ' + IntToStr(Length(APayload)) + #13#10#13#10 + APayload;
  WriteAllBytes(PByte(@Frame[1]), Length(Frame));
end;

{ TLspStdioTransport }

constructor TLspStdioTransport.Create(AGuardStdout: Boolean);
begin
  inherited Create;
  FInHandle := StdInputHandle;
  FOutHandle := TTextRec(Output).Handle;
  if FOutHandle = UnusedHandle then
    FOutHandle := StdOutputHandle;

  FGuardingStdout := AGuardStdout and (StdErrorHandle <> UnusedHandle);
  if FGuardingStdout then
  begin
    Flush(Output);
    FSavedTextOutHandle := TTextRec(Output).Handle;
    TTextRec(Output).Handle := StdErrorHandle;
  end;

  FInStream := THandleStream.Create(FInHandle);
  FOutStream := THandleStream.Create(FOutHandle);
  FInner := TLspStreamTransport.Create(FInStream, FOutStream, False);
end;

destructor TLspStdioTransport.Destroy;
begin
  FreeAndNil(FInner);
  FreeAndNil(FOutStream);
  FreeAndNil(FInStream);
  if FGuardingStdout then
  begin
    Flush(Output);
    TTextRec(Output).Handle := FSavedTextOutHandle;
  end;
  inherited Destroy;
end;

function TLspStdioTransport.WaitForInput(ATimeoutMs: Integer): Boolean;
{$IFDEF WINDOWS}
var
  StartTick, Elapsed, Remain: QWord;
  TotalAvail: DWORD;
begin
  if ATimeoutMs < 0 then
    Exit(True);

  StartTick := GetTickCount64;
  while True do
  begin
    TotalAvail := 0;
    if not PeekNamedPipe(FInHandle, nil, 0, nil, @TotalAvail, nil) then
      Exit(True); // Broken pipe (EOF) or redirected file handle -> ReadMessage handles immediately
    if TotalAvail > 0 then
      Exit(True);

    Elapsed := GetTickCount64 - StartTick;
    if Elapsed >= QWord(ATimeoutMs) then
      Exit(False);

    Remain := QWord(ATimeoutMs) - Elapsed;
    if Remain > 10 then
      Sleep(10)
    else
      Sleep(DWORD(Remain));
  end;
end;
{$ELSE}
var
  FDSet: TFDSet;
  TimeVal: TTimeVal;
  SelRes: cint;
begin
  if ATimeoutMs < 0 then
    Exit(True);

  fpFD_ZERO(FDSet);
  fpFD_SET(FInHandle, FDSet);
  TimeVal.tv_sec := ATimeoutMs div 1000;
  TimeVal.tv_usec := (ATimeoutMs mod 1000) * 1000;
  SelRes := fpSelect(FInHandle + 1, @FDSet, nil, nil, @TimeVal);
  if SelRes < 0 then
    Result := fpgeterrno <> ESysEINTR
  else
    Result := SelRes > 0;
end;
{$ENDIF}

function TLspStdioTransport.ReadMessage(out APayload: string): Boolean;
begin
  Result := FInner.ReadMessage(APayload);
end;

procedure TLspStdioTransport.DoWriteMessage(const APayload: string);
begin
  FInner.WriteMessage(APayload);
end;

{ TLspTcpServerTransport }

type
  TSingleClientInetServer = class(TInetServer)
  private
    FAcceptedStream: TSocketStream;
    procedure HandleConnect(Sender: TObject; Data: TSocketStream);
  public
    constructor CreateBound(const AHost: string; APort: Word);
    function AcceptSingleClient: TSocketStream;
  end;

constructor TSingleClientInetServer.CreateBound(const AHost: string; APort: Word);
begin
  inherited Create(AHost, APort);
  ReuseAddress := True;
  MaxConnections := 1;
  OnConnect := @HandleConnect;
end;

procedure TSingleClientInetServer.HandleConnect(Sender: TObject; Data: TSocketStream);
begin
  FAcceptedStream := Data;
  StopAccepting(False);
end;

function TSingleClientInetServer.AcceptSingleClient: TSocketStream;
begin
  FAcceptedStream := nil;
  Bind;
  Listen;
  StartAccepting;
  Result := FAcceptedStream;
end;

constructor TLspTcpServerTransport.Create(APort: Word);
begin
  inherited Create;
  if APort = 0 then
    raise ELspError.Create('TCP server transport requires a non-zero port.');
  FPort := APort;
  FServer := TSingleClientInetServer.CreateBound('127.0.0.1', FPort);
end;

destructor TLspTcpServerTransport.Destroy;
begin
  FreeAndNil(FInner);
  FreeAndNil(FClientStream);
  FreeAndNil(FServer);
  inherited Destroy;
end;

procedure TLspTcpServerTransport.EnsureConnected;
begin
  if FInner <> nil then
    Exit;
  FClientStream := TSingleClientInetServer(FServer).AcceptSingleClient;
  if FClientStream = nil then
    raise ELspError.CreateFmt('Failed to accept LSP client connection on 127.0.0.1:%d.', [FPort]);
  FInner := TLspStreamTransport.Create(FClientStream, FClientStream, False);
end;

function TLspTcpServerTransport.WaitForInput(ATimeoutMs: Integer): Boolean;
{$IFDEF WINDOWS}
var
  FDSet: Winsock2.TFDSet;
  TimeVal: Winsock2.TTimeVal;
  SelRes: LongInt;
begin
  if (FInner = nil) or (FClientStream = nil) or (ATimeoutMs < 0) then
    Exit(True);

  Winsock2.FD_ZERO(FDSet);
  Winsock2.FD_SET(TSocket(FClientStream.Handle), FDSet);
  TimeVal.tv_sec := ATimeoutMs div 1000;
  TimeVal.tv_usec := (ATimeoutMs mod 1000) * 1000;
  SelRes := Winsock2.select(0, @FDSet, nil, nil, @TimeVal);
  Result := SelRes <> 0;
end;
{$ELSE}
var
  FDSet: TFDSet;
  TimeVal: TTimeVal;
  SelRes: cint;
begin
  if (FInner = nil) or (FClientStream = nil) or (ATimeoutMs < 0) then
    Exit(True);

  fpFD_ZERO(FDSet);
  fpFD_SET(FClientStream.Handle, FDSet);
  TimeVal.tv_sec := ATimeoutMs div 1000;
  TimeVal.tv_usec := (ATimeoutMs mod 1000) * 1000;
  SelRes := fpSelect(FClientStream.Handle + 1, @FDSet, nil, nil, @TimeVal);
  if SelRes < 0 then
    Result := fpgeterrno <> ESysEINTR
  else
    Result := SelRes > 0;
end;
{$ENDIF}

function TLspTcpServerTransport.ReadMessage(out APayload: string): Boolean;
begin
  EnsureConnected;
  Result := FInner.ReadMessage(APayload);
end;

procedure TLspTcpServerTransport.DoWriteMessage(const APayload: string);
begin
  EnsureConnected;
  FInner.WriteMessage(APayload);
end;

end.
