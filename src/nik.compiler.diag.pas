unit nik.compiler.diag;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TDiagSeverity = (dsFatal, dsError, dsWarning, dsNote, dsHint);

  TCompilerDiagnostic = record
    FilePath: string;
    Line: Integer;
    Column: Integer;
    Severity: TDiagSeverity;
    Code: Integer;
    Message: string;
    RawLine: string;
  end;
  TCompilerDiagnosticArray = array of TCompilerDiagnostic;

  TParsedCompilerOutput = record
    Diagnostics: TCompilerDiagnosticArray;
    ErrorCount: Integer;   // Includes Fatal + Error
    WarningCount: Integer;
    NoteCount: Integer;
    HintCount: Integer;
    LinesCompiled: Int64;
  end;

function SeverityToString(ASev: TDiagSeverity): string;
function ParseFpcDiagnosticLine(const ARawLine, ABaseDir: string; out ADiag: TCompilerDiagnostic): Boolean;
function ParseFpcCompilerOutput(const ARawOutput, ABaseDir: string): TParsedCompilerOutput;

implementation

uses
  nik.types, nik.paths;

function SeverityToString(ASev: TDiagSeverity): string;
begin
  case ASev of
    dsFatal:   Result := 'fatal';
    dsError:   Result := 'error';
    dsWarning: Result := 'warning';
    dsNote:    Result := 'note';
    dsHint:    Result := 'hint';
  else
    raise ENikError.CreateFmt('Unsupported TDiagSeverity ordinal: %d', [Ord(ASev)]);
  end;
end;

procedure ExtractLeadingCode(var AMsg: string; out ACode: Integer);
var
  ClosePos, Parsed, ErrCode: Integer;
  NumStr: string;
begin
  ACode := 0;
  AMsg := TrimLeft(AMsg);
  if (Length(AMsg) >= 3) and (AMsg[1] = '(') then
  begin
    ClosePos := Pos(')', AMsg);
    if (ClosePos > 2) and (ClosePos <= 10) then
    begin
      NumStr := Copy(AMsg, 2, ClosePos - 2);
      Val(NumStr, Parsed, ErrCode);
      if (ErrCode = 0) and (Parsed > 0) then
      begin
        ACode := Parsed;
        AMsg := TrimLeft(Copy(AMsg, ClosePos + 1, MaxInt));
      end;
    end;
  end;
end;

function TryParseLineColSuffix(const APrefix: string; out AFile: string; out ALine, ACol: Integer): Boolean;
var
  Len, OpenPos, CommaPos, Err1, Err2: Integer;
  Inside, LineStr, ColStr: string;
begin
  Result := False;
  AFile := '';
  ALine := 0;
  ACol := 0;
  Len := Length(APrefix);
  if (Len < 3) or (APrefix[Len] <> ')') then
    Exit;

  OpenPos := Len - 1;
  while (OpenPos >= 1) and (APrefix[OpenPos] <> '(') do
    Dec(OpenPos);
  if OpenPos <= 1 then
    Exit;

  Inside := Copy(APrefix, OpenPos + 1, Len - OpenPos - 1);
  CommaPos := Pos(',', Inside);
  if CommaPos > 0 then
  begin
    LineStr := Copy(Inside, 1, CommaPos - 1);
    ColStr := Copy(Inside, CommaPos + 1, MaxInt);
    Val(LineStr, ALine, Err1);
    Val(ColStr, ACol, Err2);
    if (Err1 <> 0) or (Err2 <> 0) or (ALine < 0) or (ACol < 0) then
      Exit;
  end
  else
  begin
    Val(Inside, ALine, Err1);
    if (Err1 <> 0) or (ALine < 0) then
      Exit;
    ACol := 0;
  end;

  AFile := Trim(Copy(APrefix, 1, OpenPos - 1));
  Result := (AFile <> '');
end;

function ResolveDiagFilePath(const ARawFile, ABaseDir: string): string;
var
  Norm, Candidate: string;
begin
  if ARawFile = '' then
    Exit('');
  Norm := NormalizeNativeSeparators(ARawFile);
  if FileExists(Norm) then
    Exit(ExpandFileName(Norm));
  if ABaseDir <> '' then
  begin
    Candidate := JoinPath(ABaseDir, Norm);
    if FileExists(Candidate) then
      Exit(ExpandFileName(Candidate));
  end;
  Result := Norm;
end;

function MatchLocatedSeverity(const ALine, AMarker: string; ASev: TDiagSeverity;
  const ABaseDir: string; out ADiag: TCompilerDiagnostic): Boolean;
var
  MarkerPos: Integer;
  Prefix, RawFile, RestMsg: string;
  LineNo, ColNo, CodeNo: Integer;
begin
  Result := False;
  MarkerPos := Pos(AMarker, ALine);
  while MarkerPos > 0 do
  begin
    // Include the ')' at the start of AMarker in Prefix
    Prefix := Copy(ALine, 1, MarkerPos);
    if TryParseLineColSuffix(Prefix, RawFile, LineNo, ColNo) then
    begin
      RestMsg := Copy(ALine, MarkerPos + Length(AMarker), MaxInt);
      ExtractLeadingCode(RestMsg, CodeNo);
      ADiag := Default(TCompilerDiagnostic);
      ADiag.FilePath := ResolveDiagFilePath(RawFile, ABaseDir);
      ADiag.Line := LineNo;
      ADiag.Column := ColNo;
      ADiag.Severity := ASev;
      ADiag.Code := CodeNo;
      ADiag.Message := TrimRight(RestMsg);
      ADiag.RawLine := ALine;
      Exit(True);
    end;
    MarkerPos := Pos(AMarker, Copy(ALine, MarkerPos + 1, MaxInt));
    if MarkerPos > 0 then
      MarkerPos := MarkerPos + Length(Prefix);
  end;
end;

function MatchHeadlessSeverity(const ALine, APrefix: string; ASev: TDiagSeverity;
  out ADiag: TCompilerDiagnostic): Boolean;
var
  RestMsg: string;
  CodeNo: Integer;
begin
  Result := False;
  if (Length(ALine) >= Length(APrefix)) and
     SameText(Copy(ALine, 1, Length(APrefix)), APrefix) then
  begin
    RestMsg := Copy(ALine, Length(APrefix) + 1, MaxInt);
    ExtractLeadingCode(RestMsg, CodeNo);
    ADiag := Default(TCompilerDiagnostic);
    ADiag.Severity := ASev;
    ADiag.Code := CodeNo;
    ADiag.Message := TrimRight(RestMsg);
    ADiag.RawLine := ALine;
    Result := True;
  end;
end;

function ParseFpcDiagnosticLine(const ARawLine, ABaseDir: string; out ADiag: TCompilerDiagnostic): Boolean;
var
  Trimmed: string;
begin
  ADiag := Default(TCompilerDiagnostic);
  Trimmed := Trim(ARawLine);
  if Trimmed = '' then
    Exit(False);

  if MatchLocatedSeverity(Trimmed, ') Fatal: ', dsFatal, ABaseDir, ADiag) then Exit(True);
  if MatchLocatedSeverity(Trimmed, ') Error: ', dsError, ABaseDir, ADiag) then Exit(True);
  if MatchLocatedSeverity(Trimmed, ') Warning: ', dsWarning, ABaseDir, ADiag) then Exit(True);
  if MatchLocatedSeverity(Trimmed, ') Note: ', dsNote, ABaseDir, ADiag) then Exit(True);
  if MatchLocatedSeverity(Trimmed, ') Hint: ', dsHint, ABaseDir, ADiag) then Exit(True);

  if MatchHeadlessSeverity(Trimmed, 'Fatal: ', dsFatal, ADiag) then Exit(True);
  if MatchHeadlessSeverity(Trimmed, 'Error: ', dsError, ADiag) then Exit(True);
  if MatchHeadlessSeverity(Trimmed, 'Warning: ', dsWarning, ADiag) then Exit(True);
  if MatchHeadlessSeverity(Trimmed, 'Note: ', dsNote, ADiag) then Exit(True);
  if MatchHeadlessSeverity(Trimmed, 'Hint: ', dsHint, ADiag) then Exit(True);

  Result := False;
end;

procedure TryExtractLinesCompiled(const ALine: string; var ALinesCompiled: Int64);
var
  S, NumPart: string;
  DummyCode: Integer;
  MarkerPos, ErrCode: Integer;
  Parsed: Int64;
begin
  S := Trim(ALine);
  ExtractLeadingCode(S, DummyCode);
  MarkerPos := Pos(' lines compiled,', S);
  if MarkerPos > 1 then
  begin
    NumPart := Trim(Copy(S, 1, MarkerPos - 1));
    Val(NumPart, Parsed, ErrCode);
    if (ErrCode = 0) and (Parsed >= 0) then
      ALinesCompiled := Parsed;
  end;
end;

function ParseFpcCompilerOutput(const ARawOutput, ABaseDir: string): TParsedCompilerOutput;
var
  SL: TStringList;
  I, Count: Integer;
  Diag: TCompilerDiagnostic;
  LineText: string;
begin
  Result := Default(TParsedCompilerOutput);
  SL := TStringList.Create;
  try
    SL.Text := ARawOutput;
    Count := 0;
    for I := 0 to SL.Count - 1 do
    begin
      LineText := SL[I];
      TryExtractLinesCompiled(LineText, Result.LinesCompiled);
      if ParseFpcDiagnosticLine(LineText, ABaseDir, Diag) then
      begin
        // Skip noisy synthetic wrapper abort line and config-reading hint lines
        if (Diag.FilePath = '') and (Diag.Code = 1018) and (Result.ErrorCount > 0) then
          Continue;
        if (Diag.FilePath = '') and ((Diag.Code = 11030) or (Diag.Code = 11031)) then
          Continue;

        SetLength(Result.Diagnostics, Count + 1);
        Result.Diagnostics[Count] := Diag;
        Inc(Count);

        case Diag.Severity of
          dsFatal, dsError: Inc(Result.ErrorCount);
          dsWarning:        Inc(Result.WarningCount);
          dsNote:           Inc(Result.NoteCount);
          dsHint:           Inc(Result.HintCount);
        else
          raise ENikError.CreateFmt('Unsupported TDiagSeverity ordinal: %d', [Ord(Diag.Severity)]);
        end;
      end;
    end;
  finally
    SL.Free;
  end;
end;

end.
