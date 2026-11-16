unit nik.cmd.lsp;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

function ExecuteLspCommand(const AArgs: array of string): Integer;
procedure PrintLspHelp;

implementation

uses
  nik.types, nik.term, nik.paths, nik.fs,
  nik.lsp.server, nikrun.lsp.transport;

type
  TLspFileLogger = class
  private
    FStream: TFileStream;
  public
    constructor Create(const ALogPath: string);
    destructor Destroy; override;
    procedure WriteLogLine(const AMessage: string);
  end;

constructor TLspFileLogger.Create(const ALogPath: string);
var
  FullPath, DirPath: string;
  Mode: Word;
begin
  inherited Create;
  FullPath := ExpandFileName(NormalizeNativeSeparators(ALogPath));
  DirPath := ExtractFileDir(FullPath);
  if DirPath <> '' then
    EnsureDirExists(DirPath);
  if FileExists(FullPath) then
    Mode := fmOpenReadWrite or fmShareDenyNone
  else
    Mode := fmCreate or fmShareDenyNone;
  FStream := TFileStream.Create(FullPath, Mode);
  FStream.Seek(0, soEnd);
end;

destructor TLspFileLogger.Destroy;
begin
  FreeAndNil(FStream);
  inherited Destroy;
end;

procedure TLspFileLogger.WriteLogLine(const AMessage: string);
var
  Line: string;
begin
  if FStream = nil then
    Exit;
  Line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + AMessage + LineEnding;
  FStream.WriteBuffer(Line[1], Length(Line));
end;

procedure PrintLspHelp;
begin
  WriteLn(StyleBold('Start the Nikrun Free Pascal Language Server (LSP 3.17)'));
  WriteLn;
  WriteLn(StyleBold('USAGE:'));
  WriteLn('  nik lsp [OPTIONS]');
  WriteLn;
  WriteLn(StyleBold('OPTIONS:'));
  WriteLn('      --stdio            Communicate over standard input/output (default)');
  WriteLn('      --socket <PORT>    Listen for a single LSP client on 127.0.0.1:<PORT>');
  WriteLn('  -p, --profile <NAME>   Resolve nik.yaml using the named profile (default: debug)');
  WriteLn('  -m, --manifest <PATH>  Explicit path to nik.yaml or project directory');
  WriteLn('      --log-file <PATH>  Append JSON-RPC & server trace logs to a file');
  WriteLn('  -h, --help             Show this help message');
  WriteLn;
  WriteLn(StyleBold('EXAMPLES:'));
  WriteLn('  nik lsp');
  WriteLn('  nik lsp --stdio --profile debug');
  WriteLn('  nik lsp --socket 10090 --log-file .nik/lsp.log');
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

function ExecuteLspCommand(const AArgs: array of string): Integer;
var
  I, ParsedPort, ErrCode: Integer;
  Arg, Val, ProfileName, ManifestOverride, LogFilePath: string;
  UseSocket: Boolean;
  SocketPort: Word;
  Transport: TLspTransport;
  Server: TNikPascalLspServer;
  Logger: TLspFileLogger;
begin
  ProfileName := 'debug';
  ManifestOverride := '';
  LogFilePath := '';
  UseSocket := False;
  SocketPort := 0;

  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if (Arg = '-h') or (Arg = '--help') or (Arg = 'help') then
    begin
      PrintLspHelp;
      Exit(0);
    end
    else if Arg = '--stdio' then
      UseSocket := False
    else if (Arg = '--socket') then
    begin
      Val := NextOptValue(AArgs, I, Arg);
      System.Val(Val, ParsedPort, ErrCode);
      if (ErrCode <> 0) or (ParsedPort < 1) or (ParsedPort > 65535) then
        raise ENikError.CreateFmt('Invalid TCP port for --socket: ''%s'' (expected 1..65535).', [Val]);
      UseSocket := True;
      SocketPort := Word(ParsedPort);
    end
    else if SplitOptEq(Arg, '--socket', Val) then
    begin
      System.Val(Val, ParsedPort, ErrCode);
      if (ErrCode <> 0) or (ParsedPort < 1) or (ParsedPort > 65535) then
        raise ENikError.CreateFmt('Invalid TCP port for --socket: ''%s'' (expected 1..65535).', [Val]);
      UseSocket := True;
      SocketPort := Word(ParsedPort);
    end
    else if (Arg = '-p') or (Arg = '--profile') then
      ProfileName := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--profile', Val) then
      ProfileName := Val
    else if (Arg = '-m') or (Arg = '--manifest') then
      ManifestOverride := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--manifest', Val) then
      ManifestOverride := Val
    else if Arg = '--log-file' then
      LogFilePath := NextOptValue(AArgs, I, Arg)
    else if SplitOptEq(Arg, '--log-file', Val) then
      LogFilePath := Val
    else
      raise ENikError.CreateFmt('Unknown option ''%s'' for ''nik lsp''. Run ''nik lsp --help'' for usage.', [Arg]);

    Inc(I);
  end;

  Logger := nil;
  try
    if Trim(LogFilePath) <> '' then
      Logger := TLspFileLogger.Create(LogFilePath);

    if UseSocket then
      Transport := TLspTcpServerTransport.Create(SocketPort)
    else
      Transport := TLspStdioTransport.Create(True);

    Server := TNikPascalLspServer.Create(Transport, ManifestOverride, ProfileName, True);
    try
      if Logger <> nil then
      begin
        Server.OnLog := @Logger.WriteLogLine;
        Logger.WriteLogLine('=== nik lsp session started ===');
      end;
      Result := Server.Run;
    finally
      Server.Free;
    end;
  finally
    FreeAndNil(Logger);
  end;
end;

end.
