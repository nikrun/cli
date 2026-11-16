unit nikrun.lsp.utf16;

{$mode objfpc}{$H+}

interface

{ Converts a 0-based UTF-16 code unit column (LSP Position.character) into a
  1-based UTF-8 byte index within ALineUtf8. Returns Length(ALineUtf8) + 1 when
  AUtf16Col points at or past the end of the line. }
function Utf16ColToByteIndex(const ALineUtf8: string; AUtf16Col: Integer): Integer;

{ Converts a 1-based UTF-8 byte index within ALineUtf8 (1 .. Length + 1) into a
  0-based UTF-16 code unit column (LSP Position.character). }
function ByteIndexToUtf16Col(const ALineUtf8: string; AByteIndex: Integer): Integer;

{ Returns the total length of ALineUtf8 measured in UTF-16 code units. }
function Utf8LineLengthUtf16(const ALineUtf8: string): Integer;

implementation

procedure DecodeUtf8Step(const S: string; AIndex: Integer; out AByteStep, AUtf16Step: Integer); inline;
var
  B0: Byte;
  Remaining: Integer;
begin
  B0 := Byte(S[AIndex]);
  Remaining := Length(S) - AIndex + 1;
  if B0 < $80 then
  begin
    AByteStep := 1;
    AUtf16Step := 1;
  end
  else if (B0 and $E0) = $C0 then
  begin
    if Remaining >= 2 then
      AByteStep := 2
    else
      AByteStep := 1;
    AUtf16Step := 1;
  end
  else if (B0 and $F0) = $E0 then
  begin
    if Remaining >= 3 then
      AByteStep := 3
    else
      AByteStep := 1;
    AUtf16Step := 1;
  end
  else if (B0 and $F8) = $F0 then
  begin
    // Supplementary plane code point (U+10000..U+10FFFF) -> UTF-16 surrogate pair (2 units)
    if Remaining >= 4 then
    begin
      AByteStep := 4;
      AUtf16Step := 2;
    end
    else
    begin
      AByteStep := 1;
      AUtf16Step := 1;
    end;
  end
  else
  begin
    // Invalid / continuation byte fallback
    AByteStep := 1;
    AUtf16Step := 1;
  end;
end;

function Utf16ColToByteIndex(const ALineUtf8: string; AUtf16Col: Integer): Integer;
var
  Len, CurByte, CurUtf16, ByteStep, Utf16Step: Integer;
begin
  if AUtf16Col <= 0 then
    Exit(1);

  Len := Length(ALineUtf8);
  CurByte := 1;
  CurUtf16 := 0;
  while (CurByte <= Len) and (CurUtf16 < AUtf16Col) do
  begin
    DecodeUtf8Step(ALineUtf8, CurByte, ByteStep, Utf16Step);
    if CurUtf16 + Utf16Step > AUtf16Col then
      Break;
    Inc(CurByte, ByteStep);
    Inc(CurUtf16, Utf16Step);
  end;
  Result := CurByte;
end;

function ByteIndexToUtf16Col(const ALineUtf8: string; AByteIndex: Integer): Integer;
var
  TargetByte, CurByte, CurUtf16, ByteStep, Utf16Step: Integer;
begin
  if AByteIndex <= 1 then
    Exit(0);

  TargetByte := AByteIndex;
  if TargetByte > Length(ALineUtf8) + 1 then
    TargetByte := Length(ALineUtf8) + 1;

  CurByte := 1;
  CurUtf16 := 0;
  while CurByte < TargetByte do
  begin
    DecodeUtf8Step(ALineUtf8, CurByte, ByteStep, Utf16Step);
    if CurByte + ByteStep > TargetByte then
      Break;
    Inc(CurByte, ByteStep);
    Inc(CurUtf16, Utf16Step);
  end;
  Result := CurUtf16;
end;

function Utf8LineLengthUtf16(const ALineUtf8: string): Integer;
begin
  Result := ByteIndexToUtf16Col(ALineUtf8, Length(ALineUtf8) + 1);
end;

end.
