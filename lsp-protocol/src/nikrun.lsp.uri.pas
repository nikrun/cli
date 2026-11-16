unit nikrun.lsp.uri;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function FilePathToUri(const APath: string): string;
function TryUriToFilePath(const AUri: string; out APath: string): Boolean;
function UriToFilePath(const AUri: string): string;
function NormalizeDocumentUri(const AUri: string): string;

implementation

function IsUnreservedUriChar(ACh: Char): Boolean; inline;
begin
  Result :=
    ((ACh >= 'A') and (ACh <= 'Z')) or
    ((ACh >= 'a') and (ACh <= 'z')) or
    ((ACh >= '0') and (ACh <= '9')) or
    (ACh = '-') or (ACh = '.') or (ACh = '_') or (ACh = '~') or (ACh = '/');
end;

function HexVal(ACh: Char): Integer; inline;
begin
  if (ACh >= '0') and (ACh <= '9') then
    Result := Ord(ACh) - Ord('0')
  else if (ACh >= 'A') and (ACh <= 'F') then
    Result := Ord(ACh) - Ord('A') + 10
  else if (ACh >= 'a') and (ACh <= 'f') then
    Result := Ord(ACh) - Ord('a') + 10
  else
    Result := -1;
end;

function PercentEncodePath(const APath: string): string;
const
  HEX_DIGITS: array[0..15] of Char = '0123456789ABCDEF';
var
  I, OutLen: Integer;
  B: Byte;
  Ch: Char;
begin
  Result := '';
  SetLength(Result, Length(APath) * 3);
  OutLen := 0;
  for I := 1 to Length(APath) do
  begin
    Ch := APath[I];
    if IsUnreservedUriChar(Ch) then
    begin
      Inc(OutLen);
      Result[OutLen] := Ch;
    end
    else
    begin
      B := Byte(Ch);
      Inc(OutLen);
      Result[OutLen] := '%';
      Inc(OutLen);
      Result[OutLen] := HEX_DIGITS[(B shr 4) and $0F];
      Inc(OutLen);
      Result[OutLen] := HEX_DIGITS[B and $0F];
    end;
  end;
  SetLength(Result, OutLen);
end;

function PercentDecode(const AEncoded: string): string;
var
  I, OutLen, HiNibble, LoNibble: Integer;
begin
  Result := '';
  SetLength(Result, Length(AEncoded));
  OutLen := 0;
  I := 1;
  while I <= Length(AEncoded) do
  begin
    if (AEncoded[I] = '%') and (I + 2 <= Length(AEncoded)) then
    begin
      HiNibble := HexVal(AEncoded[I + 1]);
      LoNibble := HexVal(AEncoded[I + 2]);
      if (HiNibble >= 0) and (LoNibble >= 0) then
      begin
        Inc(OutLen);
        Result[OutLen] := Char((HiNibble shl 4) or LoNibble);
        Inc(I, 3);
        Continue;
      end;
    end;
    Inc(OutLen);
    Result[OutLen] := AEncoded[I];
    Inc(I);
  end;
  SetLength(Result, OutLen);
end;

function IsAsciiAlpha(ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= 'A') and (ACh <= 'Z')) or ((ACh >= 'a') and (ACh <= 'z'));
end;

function FilePathToUri(const APath: string): string;
var
  Normalized, Authority, PathPart: string;
  I, SlashPos: Integer;
  DriveLetter: Char;
begin
  if Trim(APath) = '' then
    Exit('');

  Normalized := APath;
  for I := 1 to Length(Normalized) do
    if Normalized[I] = '\' then
      Normalized[I] := '/';

  // Windows UNC path: //server/share/path -> file://server/share/path
  if (Length(Normalized) >= 3) and (Normalized[1] = '/') and (Normalized[2] = '/') and
     (Normalized[3] <> '/') then
  begin
    PathPart := Copy(Normalized, 3, MaxInt);
    SlashPos := Pos('/', PathPart);
    if SlashPos > 0 then
    begin
      Authority := Copy(PathPart, 1, SlashPos - 1);
      PathPart := Copy(PathPart, SlashPos, MaxInt);
    end
    else
    begin
      Authority := PathPart;
      PathPart := '/';
    end;
    Exit('file://' + LowerCase(Authority) + PercentEncodePath(PathPart));
  end;

  // Windows drive path: C:/dir/file.pas -> file:///c:/dir/file.pas
  if (Length(Normalized) >= 2) and IsAsciiAlpha(Normalized[1]) and (Normalized[2] = ':') then
  begin
    DriveLetter := LowerCase(Normalized[1]);
    PathPart := Copy(Normalized, 3, MaxInt);
    if (PathPart = '') or (PathPart[1] <> '/') then
      PathPart := '/' + PathPart;
    Exit('file:///' + DriveLetter + ':' + PercentEncodePath(PathPart));
  end;

  // POSIX absolute path: /home/user/file.pas -> file:///home/user/file.pas
  if Normalized[1] <> '/' then
    Normalized := '/' + Normalized;
  Result := 'file://' + PercentEncodePath(Normalized);
end;

function TryUriToFilePath(const AUri: string; out APath: string): Boolean;
const
  FILE_SCHEME = 'file://';
var
  Rest, Authority, RawPath, Decoded: string;
  SlashPos, QueryPos, FragPos, I: Integer;
  {$IFNDEF WINDOWS}
  IsWinStylePath: Boolean;
  {$ENDIF}
begin
  APath := '';
  Result := False;
  if Length(AUri) < Length(FILE_SCHEME) then
    Exit;
  if not SameText(Copy(AUri, 1, Length(FILE_SCHEME)), FILE_SCHEME) then
    Exit;

  Rest := Copy(AUri, Length(FILE_SCHEME) + 1, MaxInt);
  FragPos := Pos('#', Rest);
  if FragPos > 0 then
    Rest := Copy(Rest, 1, FragPos - 1);
  QueryPos := Pos('?', Rest);
  if QueryPos > 0 then
    Rest := Copy(Rest, 1, QueryPos - 1);

  if Rest = '' then
    Exit;

  if Rest[1] = '/' then
  begin
    Authority := '';
    RawPath := Rest;
  end
  else
  begin
    SlashPos := Pos('/', Rest);
    if SlashPos > 0 then
    begin
      Authority := PercentDecode(Copy(Rest, 1, SlashPos - 1));
      RawPath := Copy(Rest, SlashPos, MaxInt);
    end
    else
    begin
      Authority := PercentDecode(Rest);
      RawPath := '/';
    end;
    if SameText(Authority, 'localhost') then
      Authority := '';
  end;

  Decoded := PercentDecode(RawPath);
  if Authority = '' then
  begin
    while (Length(Decoded) > 1) and (Decoded[1] = '/') and (Decoded[2] = '/') do
      Delete(Decoded, 1, 1);
  end;

  // Strip leading '/' before a Windows drive letter: /c:/foo or /C:/foo -> C:/foo
  {$IFNDEF WINDOWS}
  IsWinStylePath := False;
  {$ENDIF}
  if (Authority = '') and (Length(Decoded) >= 3) and (Decoded[1] = '/') and
     IsAsciiAlpha(Decoded[2]) and (Decoded[3] = ':') then
  begin
    Delete(Decoded, 1, 1);
    Decoded[1] := UpCase(Decoded[1]);
    {$IFNDEF WINDOWS}
    IsWinStylePath := True;
    {$ENDIF}
  end;

  if Authority <> '' then
  begin
    // UNC path
    {$IFDEF WINDOWS}
    APath := '\\' + Authority + Decoded;
    for I := 1 to Length(APath) do
      if APath[I] = '/' then
        APath[I] := '\';
    {$ELSE}
    APath := '//' + Authority + Decoded;
    {$ENDIF}
    Exit(True);
  end;

  {$IFDEF WINDOWS}
  for I := 1 to Length(Decoded) do
    if Decoded[I] = '/' then
      Decoded[I] := '\';
  {$ELSE}
  if IsWinStylePath then
  begin
    // Preserve clean forward slashes when testing Windows URIs on POSIX hosts
    for I := 1 to Length(Decoded) do
      if Decoded[I] = '\' then
        Decoded[I] := '/';
  end;
  {$ENDIF}

  APath := Decoded;
  Result := APath <> '';
end;

function UriToFilePath(const AUri: string): string;
begin
  if not TryUriToFilePath(AUri, Result) then
    Result := '';
end;

function NormalizeDocumentUri(const AUri: string): string;
var
  LocalPath: string;
begin
  if TryUriToFilePath(AUri, LocalPath) then
    Result := FilePathToUri(LocalPath)
  else
    Result := Trim(AUri);
end;

end.
