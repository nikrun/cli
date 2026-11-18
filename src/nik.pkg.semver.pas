unit nik.pkg.semver;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, nik.types;

type
  TSemVer = record
    Major: Int64;
    Minor: Int64;
    Patch: Int64;
    PreRelease: string;
    BuildMeta: string;
    RawTag: string;
  end;
  TSemVerArray = array of TSemVer;

  TSemVerOp = (svoEq, svoGt, svoGte, svoLt, svoLte);

  TSemVerComparator = record
    Op: TSemVerOp;
    Target: TSemVer;
  end;
  TSemVerComparatorArray = array of TSemVerComparator;

  TSemVerConstraint = record
    RawText: string;
    Comparators: TSemVerComparatorArray;
  end;
  TSemVerConstraintArray = array of TSemVerConstraint;

function IsHexCommitSpecifier(const ASpec: string): Boolean;
function NormalizeHexCommit(const ASpec: string): string;

function TryParseSemVer(const ARaw: string; out AVer: TSemVer; AAllowLeadingV: Boolean = True): Boolean;
function FormatSemVer(const AVer: TSemVer): string;
function CompareSemVer(const A, B: TSemVer): Integer;
procedure SortSemVersAscending(var AVersions: TSemVerArray);

function TryParseSemVerConstraint(const ARawSpec: string; out AConstraint: TSemVerConstraint;
  out AErrMsg: string): Boolean;
function SemVerSatisfiesConstraint(const AVer: TSemVer; const AConstraint: TSemVerConstraint): Boolean;
function SemVerSatisfiesAll(const AVer: TSemVer; const AConstraints: array of TSemVerConstraint): Boolean;

function SelectMinimalMatchingVersion(const ACandidates: array of TSemVer;
  const AConstraints: array of TSemVerConstraint; out AChosen: TSemVer): Boolean;
function SelectLatestMatchingVersion(const ACandidates: array of TSemVer;
  const AConstraints: array of TSemVerConstraint; out AChosen: TSemVer): Boolean;

implementation

function IsAsciiDigit(ACh: Char): Boolean; inline;
begin
  Result := (ACh >= '0') and (ACh <= '9');
end;

function IsHexChar(ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= '0') and (ACh <= '9')) or
            ((ACh >= 'a') and (ACh <= 'f')) or
            ((ACh >= 'A') and (ACh <= 'F'));
end;

function IsIdentChar(ACh: Char): Boolean; inline;
begin
  Result := IsAsciiDigit(ACh) or
            ((ACh >= 'a') and (ACh <= 'z')) or
            ((ACh >= 'A') and (ACh <= 'Z')) or
            (ACh = '-');
end;

function IsHexCommitSpecifier(const ASpec: string): Boolean;
var
  S: string;
  I: Integer;
begin
  S := Trim(ASpec);
  if (Length(S) < 7) or (Length(S) > 40) then
    Exit(False);
  for I := 1 to Length(S) do
    if not IsHexChar(S[I]) then
      Exit(False);
  Result := True;
end;

function NormalizeHexCommit(const ASpec: string): string;
begin
  Result := LowerCase(Trim(ASpec));
end;

function ParseStrictNonNegInt(const S: string; out AVal: Int64): Boolean;
var
  I: Integer;
  Acc: Int64;
begin
  Result := False;
  AVal := 0;
  if S = '' then
    Exit;
  if (Length(S) > 1) and (S[1] = '0') then
    Exit;
  Acc := 0;
  for I := 1 to Length(S) do
  begin
    if not IsAsciiDigit(S[I]) then
      Exit;
    if Acc > (High(Int64) - 9) div 10 then
      Exit;
    Acc := Acc * 10 + (Ord(S[I]) - Ord('0'));
  end;
  AVal := Acc;
  Result := True;
end;

function ValidateDotIdentifiers(const S: string; AForPreRelease: Boolean): Boolean;
var
  I, StartPos: Integer;
  Seg: string;
  AllDigits: Boolean;
  J: Integer;
begin
  if S = '' then
    Exit(False);

  StartPos := 1;
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = '.') then
    begin
      Seg := Copy(S, StartPos, I - StartPos);
      if Seg = '' then
        Exit(False);
      AllDigits := True;
      for J := 1 to Length(Seg) do
      begin
        if not IsIdentChar(Seg[J]) then
          Exit(False);
        if not IsAsciiDigit(Seg[J]) then
          AllDigits := False;
      end;
      // SemVer 2.0: numeric pre-release identifiers must not include leading zeroes
      if AForPreRelease and AllDigits and (Length(Seg) > 1) and (Seg[1] = '0') then
        Exit(False);
      StartPos := I + 1;
    end;
  end;
  Result := True;
end;

function TryParseSemVer(const ARaw: string; out AVer: TSemVer; AAllowLeadingV: Boolean): Boolean;
var
  S, CorePart: string;
  PlusPos, DashPos, Dot1, Dot2: Integer;
  MajStr, MinStr, PatStr: string;
begin
  Result := False;
  AVer := Default(TSemVer);
  S := Trim(ARaw);
  if S = '' then
    Exit;

  AVer.RawTag := S;
  if AAllowLeadingV and ((S[1] = 'v') or (S[1] = 'V')) then
    Delete(S, 1, 1);

  if S = '' then
    Exit;

  PlusPos := Pos('+', S);
  if PlusPos > 0 then
  begin
    AVer.BuildMeta := Copy(S, PlusPos + 1, MaxInt);
    if not ValidateDotIdentifiers(AVer.BuildMeta, False) then
      Exit;
    S := Copy(S, 1, PlusPos - 1);
  end;

  DashPos := Pos('-', S);
  if DashPos > 0 then
  begin
    AVer.PreRelease := Copy(S, DashPos + 1, MaxInt);
    if not ValidateDotIdentifiers(AVer.PreRelease, True) then
      Exit;
    CorePart := Copy(S, 1, DashPos - 1);
  end
  else
    CorePart := S;

  Dot1 := Pos('.', CorePart);
  if Dot1 <= 1 then
    Exit;
  MajStr := Copy(CorePart, 1, Dot1 - 1);
  CorePart := Copy(CorePart, Dot1 + 1, MaxInt);

  Dot2 := Pos('.', CorePart);
  if Dot2 <= 1 then
    Exit;
  MinStr := Copy(CorePart, 1, Dot2 - 1);
  PatStr := Copy(CorePart, Dot2 + 1, MaxInt);
  if Pos('.', PatStr) > 0 then
    Exit;

  if not ParseStrictNonNegInt(MajStr, AVer.Major) then
    Exit;
  if not ParseStrictNonNegInt(MinStr, AVer.Minor) then
    Exit;
  if not ParseStrictNonNegInt(PatStr, AVer.Patch) then
    Exit;

  Result := True;
end;

function FormatSemVer(const AVer: TSemVer): string;
begin
  Result := Format('%d.%d.%d', [AVer.Major, AVer.Minor, AVer.Patch]);
  if AVer.PreRelease <> '' then
    Result := Result + '-' + AVer.PreRelease;
end;

function SplitDots(const S: string): TStringArray;
var
  I, StartPos, Count: Integer;
begin
  Result := nil;
  if S = '' then
    Exit;
  StartPos := 1;
  Count := 0;
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = '.') then
    begin
      SetLength(Result, Count + 1);
      Result[Count] := Copy(S, StartPos, I - StartPos);
      Inc(Count);
      StartPos := I + 1;
    end;
  end;
end;

function IsDigitsOnly(const S: string): Boolean;
var
  I: Integer;
begin
  if S = '' then
    Exit(False);
  for I := 1 to Length(S) do
    if not IsAsciiDigit(S[I]) then
      Exit(False);
  Result := True;
end;

function ComparePreRelease(const A, B: string): Integer;
var
  PartsA, PartsB: TStringArray;
  I, MinLen: Integer;
  NumA, NumB: Boolean;
  ValA, ValB: Int64;
begin
  if (A = '') and (B = '') then
    Exit(0);
  // Normal version has higher precedence than pre-release
  if A = '' then
    Exit(1);
  if B = '' then
    Exit(-1);

  PartsA := SplitDots(A);
  PartsB := SplitDots(B);
  if Length(PartsA) < Length(PartsB) then
    MinLen := Length(PartsA)
  else
    MinLen := Length(PartsB);

  for I := 0 to MinLen - 1 do
  begin
    if PartsA[I] = PartsB[I] then
      Continue;

    NumA := IsDigitsOnly(PartsA[I]);
    NumB := IsDigitsOnly(PartsB[I]);
    if NumA and NumB then
    begin
      if ParseStrictNonNegInt(PartsA[I], ValA) and ParseStrictNonNegInt(PartsB[I], ValB) then
      begin
        if ValA < ValB then
          Exit(-1)
        else
          Exit(1);
      end;
      // Fallback for arbitrarily long digit sequences: shorter string is smaller
      if Length(PartsA[I]) <> Length(PartsB[I]) then
      begin
        if Length(PartsA[I]) < Length(PartsB[I]) then
          Exit(-1)
        else
          Exit(1);
      end;
    end
    else if NumA and (not NumB) then
      Exit(-1) // Numeric identifiers always have lower precedence than non-numeric
    else if (not NumA) and NumB then
      Exit(1);

    if PartsA[I] < PartsB[I] then
      Exit(-1)
    else
      Exit(1);
  end;

  if Length(PartsA) < Length(PartsB) then
    Result := -1
  else if Length(PartsA) > Length(PartsB) then
    Result := 1
  else
    Result := 0;
end;

function CompareSemVer(const A, B: TSemVer): Integer;
begin
  if A.Major <> B.Major then
  begin
    if A.Major < B.Major then Exit(-1) else Exit(1);
  end;
  if A.Minor <> B.Minor then
  begin
    if A.Minor < B.Minor then Exit(-1) else Exit(1);
  end;
  if A.Patch <> B.Patch then
  begin
    if A.Patch < B.Patch then Exit(-1) else Exit(1);
  end;
  Result := ComparePreRelease(A.PreRelease, B.PreRelease);
end;

procedure SortSemVersAscending(var AVersions: TSemVerArray);
var
  I, J: Integer;
  Tmp: TSemVer;
begin
  for I := 0 to High(AVersions) - 1 do
    for J := I + 1 to High(AVersions) do
      if CompareSemVer(AVersions[J], AVersions[I]) < 0 then
      begin
        Tmp := AVersions[I];
        AVersions[I] := AVersions[J];
        AVersions[J] := Tmp;
      end;
end;

procedure AppendComparator(var AList: TSemVerComparatorArray; AOp: TSemVerOp; const ATarget: TSemVer);
var
  N: Integer;
begin
  N := Length(AList);
  SetLength(AList, N + 1);
  AList[N].Op := AOp;
  AList[N].Target := ATarget;
end;

function MakeCoreSemVer(AMajor, AMinor, APatch: Int64): TSemVer;
begin
  Result := Default(TSemVer);
  Result.Major := AMajor;
  Result.Minor := AMinor;
  Result.Patch := APatch;
end;

function SplitConstraintTokens(const ARaw: string): TStringArray;
var
  S, Tok: string;
  I, StartPos, Count: Integer;
begin
  Result := nil;
  // Normalize operator spacing (e.g. '>= 1.2.0' -> '>=1.2.0', '^ 1.0.0' -> '^1.0.0')
  S := StringReplace(ARaw, ',', ' ', [rfReplaceAll]);
  S := Trim(S);
  if S = '' then
    Exit;

  StartPos := 1;
  Count := 0;
  I := 1;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and ((S[I] = ' ') or (S[I] = #9)) do
      Inc(I);
    if I > Length(S) then
      Break;

    StartPos := I;
    while (I <= Length(S)) and (S[I] <> ' ') and (S[I] <> #9) do
      Inc(I);
    Tok := Copy(S, StartPos, I - StartPos);

    // Join standalone operator token ('>=', '<=', '>', '<', '=', '^', '~') with next version token
    if ((Tok = '>=') or (Tok = '<=') or (Tok = '>') or (Tok = '<') or
        (Tok = '=') or (Tok = '^') or (Tok = '~')) then
    begin
      while (I <= Length(S)) and ((S[I] = ' ') or (S[I] = #9)) do
        Inc(I);
      StartPos := I;
      while (I <= Length(S)) and (S[I] <> ' ') and (S[I] <> #9) do
        Inc(I);
      Tok := Tok + Copy(S, StartPos, I - StartPos);
    end;

    SetLength(Result, Count + 1);
    Result[Count] := Tok;
    Inc(Count);
  end;
end;

function TryParseSingleToken(const AToken: string; var AComps: TSemVerComparatorArray;
  out AErrMsg: string): Boolean;
var
  VerStr: string;
  BaseVer, UpperVer: TSemVer;
begin
  Result := False;
  AErrMsg := '';

  if AToken = '*' then
  begin
    AppendComparator(AComps, svoGte, MakeCoreSemVer(0, 0, 0));
    Exit(True);
  end;

  if Copy(AToken, 1, 1) = '^' then
  begin
    VerStr := Copy(AToken, 2, MaxInt);
    if not TryParseSemVer(VerStr, BaseVer, True) then
    begin
      AErrMsg := Format('Invalid SemVer version in caret constraint ''%s'' (expected ^MAJOR.MINOR.PATCH).', [AToken]);
      Exit(False);
    end;
    if BaseVer.Major > 0 then
      UpperVer := MakeCoreSemVer(BaseVer.Major + 1, 0, 0)
    else if BaseVer.Minor > 0 then
      UpperVer := MakeCoreSemVer(0, BaseVer.Minor + 1, 0)
    else
      UpperVer := MakeCoreSemVer(0, 0, BaseVer.Patch + 1);

    AppendComparator(AComps, svoGte, BaseVer);
    AppendComparator(AComps, svoLt, UpperVer);
    Exit(True);
  end;

  if Copy(AToken, 1, 1) = '~' then
  begin
    VerStr := Copy(AToken, 2, MaxInt);
    if not TryParseSemVer(VerStr, BaseVer, True) then
    begin
      AErrMsg := Format('Invalid SemVer version in tilde constraint ''%s'' (expected ~MAJOR.MINOR.PATCH).', [AToken]);
      Exit(False);
    end;
    UpperVer := MakeCoreSemVer(BaseVer.Major, BaseVer.Minor + 1, 0);
    AppendComparator(AComps, svoGte, BaseVer);
    AppendComparator(AComps, svoLt, UpperVer);
    Exit(True);
  end;

  if Copy(AToken, 1, 2) = '>=' then
  begin
    if not TryParseSemVer(Copy(AToken, 3, MaxInt), BaseVer, True) then
    begin
      AErrMsg := Format('Invalid SemVer version in constraint ''%s''.', [AToken]);
      Exit(False);
    end;
    AppendComparator(AComps, svoGte, BaseVer);
    Exit(True);
  end;

  if Copy(AToken, 1, 2) = '<=' then
  begin
    if not TryParseSemVer(Copy(AToken, 3, MaxInt), BaseVer, True) then
    begin
      AErrMsg := Format('Invalid SemVer version in constraint ''%s''.', [AToken]);
      Exit(False);
    end;
    AppendComparator(AComps, svoLte, BaseVer);
    Exit(True);
  end;

  if Copy(AToken, 1, 1) = '>' then
  begin
    if not TryParseSemVer(Copy(AToken, 2, MaxInt), BaseVer, True) then
    begin
      AErrMsg := Format('Invalid SemVer version in constraint ''%s''.', [AToken]);
      Exit(False);
    end;
    AppendComparator(AComps, svoGt, BaseVer);
    Exit(True);
  end;

  if Copy(AToken, 1, 1) = '<' then
  begin
    if not TryParseSemVer(Copy(AToken, 2, MaxInt), BaseVer, True) then
    begin
      AErrMsg := Format('Invalid SemVer version in constraint ''%s''.', [AToken]);
      Exit(False);
    end;
    AppendComparator(AComps, svoLt, BaseVer);
    Exit(True);
  end;

  if Copy(AToken, 1, 1) = '=' then
    VerStr := Copy(AToken, 2, MaxInt)
  else
    VerStr := AToken;

  if not TryParseSemVer(VerStr, BaseVer, True) then
  begin
    AErrMsg := Format(
      'Invalid version or commit specifier ''%s''. Moving branch names are disallowed in nik.yaml; use SemVer (e.g. ^0.1.0, ~1.2.0, 1.2.3) or a 7..40 char commit hash (run ''nik pkg info <url>'' to inspect tags and HEAD commit).',
      [AToken]);
    Exit(False);
  end;

  AppendComparator(AComps, svoEq, BaseVer);
  Result := True;
end;

function TryParseSemVerConstraint(const ARawSpec: string; out AConstraint: TSemVerConstraint;
  out AErrMsg: string): Boolean;
var
  Tokens: TStringArray;
  I: Integer;
begin
  Result := False;
  AConstraint := Default(TSemVerConstraint);
  AConstraint.RawText := Trim(ARawSpec);
  AErrMsg := '';

  Tokens := SplitConstraintTokens(ARawSpec);
  if Length(Tokens) = 0 then
  begin
    AErrMsg := 'Version constraint cannot be empty.';
    Exit(False);
  end;

  for I := 0 to High(Tokens) do
    if not TryParseSingleToken(Tokens[I], AConstraint.Comparators, AErrMsg) then
      Exit(False);

  Result := True;
end;

function SemVerSatisfiesComparator(const AVer: TSemVer; const AComp: TSemVerComparator): Boolean;
var
  Cmp: Integer;
begin
  Cmp := CompareSemVer(AVer, AComp.Target);
  case AComp.Op of
    svoEq:  Result := (Cmp = 0);
    svoGt:  Result := (Cmp > 0);
    svoGte: Result := (Cmp >= 0);
    svoLt:  Result := (Cmp < 0);
    svoLte: Result := (Cmp <= 0);
  else
    raise ENikError.Create('Internal error: unexpected SemVer comparator operator.');
  end;
end;

function SemVerSatisfiesConstraint(const AVer: TSemVer; const AConstraint: TSemVerConstraint): Boolean;
var
  I: Integer;
  AllowsPre: Boolean;
begin
  if Length(AConstraint.Comparators) = 0 then
    Exit(False);

  // Pre-release versions only match if at least one comparator explicitly targets a pre-release on the same M.m.p
  if AVer.PreRelease <> '' then
  begin
    AllowsPre := False;
    for I := 0 to High(AConstraint.Comparators) do
    begin
      if (AConstraint.Comparators[I].Target.PreRelease <> '') and
         (AConstraint.Comparators[I].Target.Major = AVer.Major) and
         (AConstraint.Comparators[I].Target.Minor = AVer.Minor) and
         (AConstraint.Comparators[I].Target.Patch = AVer.Patch) then
      begin
        AllowsPre := True;
        Break;
      end;
    end;
    if not AllowsPre then
      Exit(False);
  end;

  for I := 0 to High(AConstraint.Comparators) do
    if not SemVerSatisfiesComparator(AVer, AConstraint.Comparators[I]) then
      Exit(False);

  Result := True;
end;

function SemVerSatisfiesAll(const AVer: TSemVer; const AConstraints: array of TSemVerConstraint): Boolean;
var
  I: Integer;
begin
  for I := Low(AConstraints) to High(AConstraints) do
    if not SemVerSatisfiesConstraint(AVer, AConstraints[I]) then
      Exit(False);
  Result := True;
end;

function SelectMinimalMatchingVersion(const ACandidates: array of TSemVer;
  const AConstraints: array of TSemVerConstraint; out AChosen: TSemVer): Boolean;
var
  Sorted: TSemVerArray;
  I: Integer;
begin
  Result := False;
  AChosen := Default(TSemVer);
  if Length(ACandidates) = 0 then
    Exit;

  SetLength(Sorted, Length(ACandidates));
  for I := 0 to High(ACandidates) do
    Sorted[I] := ACandidates[I];
  SortSemVersAscending(Sorted);

  for I := 0 to High(Sorted) do
    if SemVerSatisfiesAll(Sorted[I], AConstraints) then
    begin
      AChosen := Sorted[I];
      Exit(True);
    end;
end;

function SelectLatestMatchingVersion(const ACandidates: array of TSemVer;
  const AConstraints: array of TSemVerConstraint; out AChosen: TSemVer): Boolean;
var
  Sorted: TSemVerArray;
  I: Integer;
begin
  Result := False;
  AChosen := Default(TSemVer);
  if Length(ACandidates) = 0 then
    Exit;

  SetLength(Sorted, Length(ACandidates));
  for I := 0 to High(ACandidates) do
    Sorted[I] := ACandidates[I];
  SortSemVersAscending(Sorted);

  for I := High(Sorted) downto 0 do
    if SemVerSatisfiesAll(Sorted[I], AConstraints) then
    begin
      AChosen := Sorted[I];
      Exit(True);
    end;
end;

end.
