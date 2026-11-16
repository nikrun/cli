unit nik.sha256;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, Classes;

type
  TSha256Digest = array[0..31] of Byte;

  TSha256Context = record
    State: array[0..7] of Cardinal;
    TotalBits: QWord;
    Buffer: array[0..63] of Byte;
    BufferLen: Cardinal;
  end;

procedure Sha256Init(out ACtx: TSha256Context);
procedure Sha256Update(var ACtx: TSha256Context; const AData; ALen: SizeUInt);
procedure Sha256Final(var ACtx: TSha256Context; out ADigest: TSha256Digest);

function Sha256DigestToHex(const ADigest: TSha256Digest): string;
function Sha256BytesHex(const AData; ALen: SizeUInt): string;
function Sha256StringHex(const AText: RawByteString): string;
function Sha256StreamHex(AStream: TStream): string;
function Sha256FileHex(const AFilePath: string): string;

implementation

uses
  nik.types;

const
  K256: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
  );

function Ror32(AValue: Cardinal; ABits: Cardinal): Cardinal; inline;
begin
  Result := (AValue shr ABits) or (AValue shl (32 - ABits));
end;

procedure Sha256TransformBlock(var AState: array of Cardinal; const ABlock: PByte);
var
  W: array[0..63] of Cardinal;
  A, B, C, D, E, F, G, H: Cardinal;
  S0, S1, Ch, Maj, Temp1, Temp2: Cardinal;
  I: Integer;
begin
  for I := 0 to 15 do
  begin
    W[I] := (Cardinal(ABlock[I * 4]) shl 24) or
            (Cardinal(ABlock[I * 4 + 1]) shl 16) or
            (Cardinal(ABlock[I * 4 + 2]) shl 8) or
            Cardinal(ABlock[I * 4 + 3]);
  end;

  for I := 16 to 63 do
  begin
    S0 := Ror32(W[I - 15], 7) xor Ror32(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := Ror32(W[I - 2], 17) xor Ror32(W[I - 2], 19) xor (W[I - 2] shr 10);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;

  A := AState[0];
  B := AState[1];
  C := AState[2];
  D := AState[3];
  E := AState[4];
  F := AState[5];
  G := AState[6];
  H := AState[7];

  for I := 0 to 63 do
  begin
    S1 := Ror32(E, 6) xor Ror32(E, 11) xor Ror32(E, 25);
    Ch := (E and F) xor ((not E) and G);
    Temp1 := H + S1 + Ch + K256[I] + W[I];
    S0 := Ror32(A, 2) xor Ror32(A, 13) xor Ror32(A, 22);
    Maj := (A and B) xor (A and C) xor (B and C);
    Temp2 := S0 + Maj;

    H := G;
    G := F;
    F := E;
    E := D + Temp1;
    D := C;
    C := B;
    B := A;
    A := Temp1 + Temp2;
  end;

  AState[0] := AState[0] + A;
  AState[1] := AState[1] + B;
  AState[2] := AState[2] + C;
  AState[3] := AState[3] + D;
  AState[4] := AState[4] + E;
  AState[5] := AState[5] + F;
  AState[6] := AState[6] + G;
  AState[7] := AState[7] + H;
end;

procedure Sha256Init(out ACtx: TSha256Context);
begin
  FillChar(ACtx, SizeOf(ACtx), 0);
  ACtx.State[0] := $6a09e667;
  ACtx.State[1] := $bb67ae85;
  ACtx.State[2] := $3c6ef372;
  ACtx.State[3] := $a54ff53a;
  ACtx.State[4] := $510e527f;
  ACtx.State[5] := $9b05688c;
  ACtx.State[6] := $1f83d9ab;
  ACtx.State[7] := $5be0cd19;
end;

procedure Sha256Update(var ACtx: TSha256Context; const AData; ALen: SizeUInt);
var
  Src: PByte;
  Take: SizeUInt;
begin
  if ALen = 0 then
    Exit;

  ACtx.TotalBits := ACtx.TotalBits + (QWord(ALen) * 8);
  Src := @AData;

  if ACtx.BufferLen > 0 then
  begin
    Take := 64 - ACtx.BufferLen;
    if Take > ALen then
      Take := ALen;
    Move(Src^, ACtx.Buffer[ACtx.BufferLen], Take);
    Inc(ACtx.BufferLen, Take);
    Inc(Src, Take);
    Dec(ALen, Take);

    if ACtx.BufferLen = 64 then
    begin
      Sha256TransformBlock(ACtx.State, @ACtx.Buffer[0]);
      ACtx.BufferLen := 0;
    end;
  end;

  while ALen >= 64 do
  begin
    Sha256TransformBlock(ACtx.State, Src);
    Inc(Src, 64);
    Dec(ALen, 64);
  end;

  if ALen > 0 then
  begin
    Move(Src^, ACtx.Buffer[0], ALen);
    ACtx.BufferLen := ALen;
  end;
end;

procedure Sha256Final(var ACtx: TSha256Context; out ADigest: TSha256Digest);
var
  I: Integer;
begin
  ACtx.Buffer[ACtx.BufferLen] := $80;
  Inc(ACtx.BufferLen);

  if ACtx.BufferLen > 56 then
  begin
    while ACtx.BufferLen < 64 do
    begin
      ACtx.Buffer[ACtx.BufferLen] := 0;
      Inc(ACtx.BufferLen);
    end;
    Sha256TransformBlock(ACtx.State, @ACtx.Buffer[0]);
    ACtx.BufferLen := 0;
  end;

  while ACtx.BufferLen < 56 do
  begin
    ACtx.Buffer[ACtx.BufferLen] := 0;
    Inc(ACtx.BufferLen);
  end;

  for I := 0 to 7 do
    ACtx.Buffer[56 + I] := Byte((ACtx.TotalBits shr ((7 - I) * 8)) and $FF);

  Sha256TransformBlock(ACtx.State, @ACtx.Buffer[0]);

  for I := 0 to 7 do
  begin
    ADigest[I * 4]     := Byte((ACtx.State[I] shr 24) and $FF);
    ADigest[I * 4 + 1] := Byte((ACtx.State[I] shr 16) and $FF);
    ADigest[I * 4 + 2] := Byte((ACtx.State[I] shr 8) and $FF);
    ADigest[I * 4 + 3] := Byte(ACtx.State[I] and $FF);
  end;

  FillChar(ACtx, SizeOf(ACtx), 0);
end;

function Sha256DigestToHex(const ADigest: TSha256Digest): string;
const
  HexChars: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, 64);
  for I := 0 to 31 do
  begin
    Result[I * 2 + 1] := HexChars[ADigest[I] shr 4];
    Result[I * 2 + 2] := HexChars[ADigest[I] and $0F];
  end;
end;

function Sha256BytesHex(const AData; ALen: SizeUInt): string;
var
  Ctx: TSha256Context;
  Digest: TSha256Digest;
begin
  Sha256Init(Ctx);
  Sha256Update(Ctx, AData, ALen);
  Sha256Final(Ctx, Digest);
  Result := Sha256DigestToHex(Digest);
end;

function Sha256StringHex(const AText: RawByteString): string;
begin
  if Length(AText) = 0 then
    Result := Sha256BytesHex(Pointer(nil)^, 0)
  else
    Result := Sha256BytesHex(AText[1], Length(AText));
end;

function Sha256StreamHex(AStream: TStream): string;
const
  CHUNK_SIZE = 65536;
var
  Ctx: TSha256Context;
  Digest: TSha256Digest;
  Buf: array[0..CHUNK_SIZE - 1] of Byte;
  BytesRead: LongInt;
begin
  Sha256Init(Ctx);
  repeat
    BytesRead := AStream.Read(Buf[0], CHUNK_SIZE);
    if BytesRead > 0 then
      Sha256Update(Ctx, Buf[0], SizeUInt(BytesRead));
  until BytesRead <= 0;
  Sha256Final(Ctx, Digest);
  Result := Sha256DigestToHex(Digest);
end;

function Sha256FileHex(const AFilePath: string): string;
var
  FS: TFileStream;
begin
  if not FileExists(AFilePath) then
    raise ENikError.CreateFmt('Cannot compute SHA256, file not found: %s', [AFilePath]);

  FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyWrite);
  try
    Result := Sha256StreamHex(FS);
  finally
    FS.Free;
  end;
end;

end.
