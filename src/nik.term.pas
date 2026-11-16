unit nik.term;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

procedure InitTerminal(AForceNoColor: Boolean = False);
function IsInteractiveOutput: Boolean;
function ColorsEnabled: Boolean;

function StyleBold(const AText: string): string;
function StyleDim(const AText: string): string;
function StyleCyan(const AText: string): string;
function StyleGreen(const AText: string): string;
function StyleYellow(const AText: string): string;
function StyleRed(const AText: string): string;

procedure WriteStep(const AMsg: string);
procedure WriteSuccess(const AMsg: string);
procedure WriteInfo(const AMsg: string);
procedure WriteWarn(const AMsg: string);
procedure WriteError(const AMsg: string);
procedure WriteProgress(const ALabel: string; ABytesRead, ATotalBytes: Int64);
procedure FinishProgress;

function FormatByteSize(ABytes: Int64): string;
function PadRightStr(const AText: string; AWidth: Integer): string;

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ELSE}
uses
  termio;
{$ENDIF}

const
  ESC = #27;
  ANSI_RESET  = ESC + '[0m';
  ANSI_BOLD   = ESC + '[1m';
  ANSI_DIM    = ESC + '[2m';
  ANSI_RED    = ESC + '[31m';
  ANSI_GREEN  = ESC + '[32m';
  ANSI_YELLOW = ESC + '[33m';
  ANSI_CYAN   = ESC + '[36m';

var
  GColorsEnabled: Boolean = False;
  GInteractiveOut: Boolean = False;
  GProgressActive: Boolean = False;
  GLastProgressLen: Integer = 0;

{$IFDEF WINDOWS}
const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = $0004;
{$ENDIF}

procedure InitTerminal(AForceNoColor: Boolean);
var
  NoColorEnv, TermEnv, CiEnv: string;
  IsCiEnv: Boolean;
{$IFDEF WINDOWS}
  OutHandle: THandle;
  ConsoleMode: DWORD;
{$ENDIF}
begin
  NoColorEnv := SysUtils.GetEnvironmentVariable('NO_COLOR');
  TermEnv := LowerCase(SysUtils.GetEnvironmentVariable('TERM'));
  CiEnv := LowerCase(Trim(SysUtils.GetEnvironmentVariable('CI')));
  IsCiEnv := (CiEnv <> '') and (CiEnv <> '0') and (CiEnv <> 'false');

{$IFDEF WINDOWS}
  SetConsoleOutputCP(CP_UTF8);
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(StdErr, CP_UTF8);

  OutHandle := GetStdHandle(STD_OUTPUT_HANDLE);
  GInteractiveOut := (not IsCiEnv) and
                     (OutHandle <> INVALID_HANDLE_VALUE) and
                     (OutHandle <> 0) and
                     (GetFileType(OutHandle) = FILE_TYPE_CHAR);

  if GInteractiveOut and (not AForceNoColor) and (NoColorEnv = '') and (TermEnv <> 'dumb') then
  begin
    ConsoleMode := 0;
    if GetConsoleMode(OutHandle, ConsoleMode) then
    begin
      if SetConsoleMode(OutHandle, ConsoleMode or ENABLE_VIRTUAL_TERMINAL_PROCESSING) then
        GColorsEnabled := True;
    end;
  end
  else
    GColorsEnabled := False;
{$ELSE}
  GInteractiveOut := (not IsCiEnv) and (isatty(StdOutputHandle) = 1);
  GColorsEnabled := GInteractiveOut and
                    (not AForceNoColor) and
                    (NoColorEnv = '') and
                    (TermEnv <> 'dumb');
{$ENDIF}
end;

function IsInteractiveOutput: Boolean;
begin
  Result := GInteractiveOut;
end;

function ColorsEnabled: Boolean;
begin
  Result := GColorsEnabled;
end;

function WrapAnsi(const ACode, AText: string): string;
begin
  if GColorsEnabled and (AText <> '') then
    Result := ACode + AText + ANSI_RESET
  else
    Result := AText;
end;

function StyleBold(const AText: string): string;
begin
  Result := WrapAnsi(ANSI_BOLD, AText);
end;

function StyleDim(const AText: string): string;
begin
  Result := WrapAnsi(ANSI_DIM, AText);
end;

function StyleCyan(const AText: string): string;
begin
  Result := WrapAnsi(ANSI_CYAN, AText);
end;

function StyleGreen(const AText: string): string;
begin
  Result := WrapAnsi(ANSI_GREEN, AText);
end;

function StyleYellow(const AText: string): string;
begin
  Result := WrapAnsi(ANSI_YELLOW, AText);
end;

function StyleRed(const AText: string): string;
begin
  Result := WrapAnsi(ANSI_RED, AText);
end;

procedure WriteStep(const AMsg: string);
begin
  FinishProgress;
  WriteLn(StyleCyan('==> ') + StyleBold(AMsg));
end;

procedure WriteSuccess(const AMsg: string);
begin
  FinishProgress;
  WriteLn(' ' + StyleGreen('[OK]') + ' ' + AMsg);
end;

procedure WriteInfo(const AMsg: string);
begin
  FinishProgress;
  WriteLn(' ' + StyleCyan('[i]') + ' ' + AMsg);
end;

procedure WriteWarn(const AMsg: string);
begin
  FinishProgress;
  WriteLn(StdErr, ' ' + StyleYellow('[WARN]') + ' ' + AMsg);
end;

procedure WriteError(const AMsg: string);
begin
  FinishProgress;
  WriteLn(StdErr, StyleRed('error:') + ' ' + AMsg);
end;

function FormatByteSize(ABytes: Int64): string;
var
  Fmt: TFormatSettings;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  if ABytes < 1024 then
    Result := IntToStr(ABytes) + ' B'
  else if ABytes < 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / 1024.0, Fmt) + ' KB'
  else if ABytes < Int64(1024) * 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / (1024.0 * 1024.0), Fmt) + ' MB'
  else
    Result := FormatFloat('0.00', ABytes / (1024.0 * 1024.0 * 1024.0), Fmt) + ' GB';
end;

procedure WriteProgress(const ALabel: string; ABytesRead, ATotalBytes: Int64);
var
  Line: string;
  Pct: Integer;
  PadCount: Integer;
begin
  if not GInteractiveOut then
    Exit;

  if ATotalBytes > 0 then
  begin
    Pct := Round((ABytesRead * 100.0) / ATotalBytes);
    if Pct > 100 then
      Pct := 100;
    Line := Format('    %s: %s / %s (%d%%)',
      [ALabel, FormatByteSize(ABytesRead), FormatByteSize(ATotalBytes), Pct]);
  end
  else
    Line := Format('    %s: %s', [ALabel, FormatByteSize(ABytesRead)]);

  PadCount := GLastProgressLen - Length(Line);
  GLastProgressLen := Length(Line);
  if PadCount > 0 then
    Line := Line + StringOfChar(' ', PadCount);

  Write(#13 + Line);
  Flush(Output);
  GProgressActive := True;
end;

procedure FinishProgress;
begin
  if GProgressActive then
  begin
    WriteLn;
    GProgressActive := False;
    GLastProgressLen := 0;
  end;
end;

function PadRightStr(const AText: string; AWidth: Integer): string;
var
  Len: Integer;
begin
  Len := Length(AText);
  if Len >= AWidth then
    Result := AText
  else
    Result := AText + StringOfChar(' ', AWidth - Len);
end;

end.
