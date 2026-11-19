unit nik.test.discovery;

{$mode objfpc}{$H+}

{ Test unit discovery & static scanning for 'nik test' (see internal-notes/specs/nik-test.md).
  A test unit is a unit whose file name ends in _test.pas/_test.pp/.test.pas/.test.pp.
  The scanner is a lightweight tokenizer (comments, strings and directives are skipped) that
  extracts the unit name, TTestCase descendants, their published methods and source lines. }

interface

uses
  SysUtils, nik.types;

type
  TTestMethodInfo = record
    Name: string;
    DeclLine: Integer;
    ImplLine: Integer;
  end;
  TTestMethodInfoArray = array of TTestMethodInfo;

  TTestClassInfo = record
    Name: string;
    ParentName: string;
    IsTest: Boolean;
    Line: Integer;
    Methods: TTestMethodInfoArray;
  end;
  TTestClassInfoArray = array of TTestClassInfo;

  TTestUnitInfo = record
    FilePath: string;
    UnitName: string;
    UnitLine: Integer;
    HasRegisterTest: Boolean;
    Classes: TTestClassInfoArray;
  end;
  TTestUnitInfoArray = array of TTestUnitInfo;

  TTestWarning = record
    FilePath: string;
    Line: Integer;
    Message: string;
  end;
  TTestWarningArray = array of TTestWarning;

  TTestDiscoveryResult = record
    Units: TTestUnitInfoArray;
    Warnings: TTestWarningArray;
  end;

function IsTestUnitFileName(const AFileName: string): Boolean;
function MakeTestId(const AUnitName, AClassName, AMethodName: string): string;

{ Scans one unit source. Classes carry ParentName; IsTest is resolved by ResolveTestClasses. }
function ScanTestUnitSource(const AFilePath, ASource: string): TTestUnitInfo;

{ Marks classes deriving (transitively, across units) from TTestCase and drops the others. }
procedure ResolveTestClasses(var AUnits: TTestUnitInfoArray);

{ Discovers test units in ARoots (non-recursive, only inside AProjectDir). Raises ENikError on
  unit name / file name mismatch and duplicate unit names. }
function DiscoverTestUnits(const AProjectDir: string;
  const ARoots: TStringArray): TTestDiscoveryResult;

{ Case-insensitive; '*' wildcard. Without '*' a filter matches the full id or a prefix at a '.' boundary. }
function TestIdMatchesFilter(const AId, AFilter: string): Boolean;
function TestIdMatchesAnyFilter(const AId: string; const AFilters: TStringArray): Boolean;

implementation

uses
  nik.paths, nik.fs;

type
  TTok = record
    Text: string;
    Line: Integer;
    IsIdent: Boolean;
  end;
  TTokArray = array of TTok;

function IsTestUnitFileName(const AFileName: string): Boolean;
var
  Lower: string;
begin
  Lower := LowerCase(ExtractFileName(AFileName));
  Result :=
    ((Length(Lower) > Length('_test.pas')) and (Copy(Lower, Length(Lower) - 8, 9) = '_test.pas')) or
    ((Length(Lower) > Length('_test.pp')) and (Copy(Lower, Length(Lower) - 7, 8) = '_test.pp')) or
    ((Length(Lower) > Length('.test.pas')) and (Copy(Lower, Length(Lower) - 8, 9) = '.test.pas')) or
    ((Length(Lower) > Length('.test.pp')) and (Copy(Lower, Length(Lower) - 7, 8) = '.test.pp'));
end;

function MakeTestId(const AUnitName, AClassName, AMethodName: string): string;
begin
  Result := AUnitName + '.' + AClassName + '.' + AMethodName;
end;

function IsIdentStart(Ch: Char): Boolean; inline;
begin
  Result := (Ch in ['A'..'Z', 'a'..'z', '_']);
end;

function IsIdentChar(Ch: Char): Boolean; inline;
begin
  Result := (Ch in ['A'..'Z', 'a'..'z', '_', '0'..'9']);
end;

procedure AddTok(var AToks: TTokArray; var ACount: Integer; const AText: string;
  ALine: Integer; AIsIdent: Boolean);
begin
  if ACount >= Length(AToks) then
    SetLength(AToks, (Length(AToks) * 2) + 256);
  AToks[ACount].Text := AText;
  AToks[ACount].Line := ALine;
  AToks[ACount].IsIdent := AIsIdent;
  Inc(ACount);
end;

function Tokenize(const ASource: string): TTokArray;
var
  I, N, Line, Count, Start: Integer;
  Ch: Char;
begin
  Result := nil;
  Count := 0;
  Line := 1;
  I := 1;
  N := Length(ASource);
  while I <= N do
  begin
    Ch := ASource[I];
    if Ch = #10 then
    begin
      Inc(Line);
      Inc(I);
    end
    else if Ch in [' ', #9, #13] then
      Inc(I)
    else if Ch = '{' then
    begin
      // { comment } or {$directive}
      while (I <= N) and (ASource[I] <> '}') do
      begin
        if ASource[I] = #10 then
          Inc(Line);
        Inc(I);
      end;
      Inc(I);
    end
    else if (Ch = '(') and (I < N) and (ASource[I + 1] = '*') then
    begin
      Inc(I, 2);
      while (I < N) and not ((ASource[I] = '*') and (ASource[I + 1] = ')')) do
      begin
        if ASource[I] = #10 then
          Inc(Line);
        Inc(I);
      end;
      Inc(I, 2);
    end
    else if (Ch = '/') and (I < N) and (ASource[I + 1] = '/') then
    begin
      while (I <= N) and (ASource[I] <> #10) do
        Inc(I);
    end
    else if Ch = '''' then
    begin
      Inc(I);
      while I <= N do
      begin
        if ASource[I] = '''' then
        begin
          if (I < N) and (ASource[I + 1] = '''') then
            Inc(I, 2)
          else
          begin
            Inc(I);
            Break;
          end;
        end
        else
        begin
          if ASource[I] = #10 then
            Inc(Line);
          Inc(I);
        end;
      end;
      AddTok(Result, Count, '''''', Line, False);
    end
    else if IsIdentStart(Ch) then
    begin
      Start := I;
      while (I <= N) and IsIdentChar(ASource[I]) do
        Inc(I);
      AddTok(Result, Count, Copy(ASource, Start, I - Start), Line, True);
    end
    else if Ch = '&' then
      Inc(I)
    else
    begin
      AddTok(Result, Count, Ch, Line, False);
      Inc(I);
    end;
  end;
  SetLength(Result, Count);
end;

function TokIs(const AToks: TTokArray; AIndex: Integer; const AText: string): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < Length(AToks)) and SameText(AToks[AIndex].Text, AText);
end;

function TokIsIdent(const AToks: TTokArray; AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < Length(AToks)) and AToks[AIndex].IsIdent;
end;

function IsVisibilityKeyword(const AText: string): Boolean;
begin
  Result := SameText(AText, 'published') or SameText(AText, 'public') or
    SameText(AText, 'private') or SameText(AText, 'protected');
end;

procedure AddMethod(var AClass: TTestClassInfo; const AName: string; ALine: Integer);
var
  N, I: Integer;
begin
  for I := 0 to High(AClass.Methods) do
    if SameText(AClass.Methods[I].Name, AName) then
      Exit;
  N := Length(AClass.Methods);
  SetLength(AClass.Methods, N + 1);
  AClass.Methods[N].Name := AName;
  AClass.Methods[N].DeclLine := ALine;
  AClass.Methods[N].ImplLine := 0;
end;

{ Parses a class body starting after the ')' of the ancestor list; returns the index after the closing 'end'. }
function ParseClassBody(const AToks: TTokArray; AStart: Integer; var AClass: TTestClassInfo): Integer;
var
  I, Depth: Integer;
  Published: Boolean;
  Tok: string;
begin
  I := AStart;
  Depth := 0;
  // fpcunit declares TTestCase with {$M+}: members without a visibility section are published.
  Published := True;
  while I < Length(AToks) do
  begin
    Tok := AToks[I].Text;
    if AToks[I].IsIdent then
    begin
      if SameText(Tok, 'end') then
      begin
        if Depth = 0 then
          Exit(I + 1);
        Dec(Depth);
      end
      else if SameText(Tok, 'record') then
        Inc(Depth)
      else if SameText(Tok, 'object') and (not TokIs(AToks, I - 1, 'of')) then
        Inc(Depth)
      else if (Depth = 0) and IsVisibilityKeyword(Tok) then
      begin
        Published := SameText(Tok, 'published');
        if TokIs(AToks, I - 1, 'strict') then
          Published := False;
      end
      else if (Depth = 0) and Published and
              (SameText(Tok, 'procedure') or SameText(Tok, 'function')) and
              TokIsIdent(AToks, I + 1) and (not TokIs(AToks, I + 2, '.')) then
      begin
        // Only parameterless procedures are runnable fpcunit tests
        if SameText(Tok, 'procedure') and (not TokIs(AToks, I + 2, '(')) and
           (not TokIs(AToks, I - 1, 'class')) and
           (not SameText(AToks[I + 1].Text, 'SetUp')) and
           (not SameText(AToks[I + 1].Text, 'TearDown')) then
          AddMethod(AClass, AToks[I + 1].Text, AToks[I + 1].Line);
      end;
    end;
    Inc(I);
  end;
  Result := I;
end;

function ScanTestUnitSource(const AFilePath, ASource: string): TTestUnitInfo;
var
  Toks: TTokArray;
  I, J, K, N, M: Integer;
  Cls: TTestClassInfo;
  ClassIdx: Integer;
begin
  Result := Default(TTestUnitInfo);
  Result.FilePath := AFilePath;
  Toks := Tokenize(ASource);

  // unit <name>;
  for I := 0 to High(Toks) do
    if TokIs(Toks, I, 'unit') and TokIsIdent(Toks, I + 1) then
    begin
      Result.UnitLine := Toks[I].Line;
      Result.UnitName := Toks[I + 1].Text;
      J := I + 2;
      while TokIs(Toks, J, '.') and TokIsIdent(Toks, J + 1) do
      begin
        Result.UnitName := Result.UnitName + '.' + Toks[J + 1].Text;
        Inc(J, 2);
      end;
      Break;
    end;

  // TFoo = class(TBar) ... end;
  I := 0;
  while I < Length(Toks) do
  begin
    if Toks[I].IsIdent and TokIs(Toks, I + 1, '=') and TokIs(Toks, I + 2, 'class') and
       TokIs(Toks, I + 3, '(') and TokIsIdent(Toks, I + 4) then
    begin
      Cls := Default(TTestClassInfo);
      Cls.Name := Toks[I].Text;
      Cls.Line := Toks[I].Line;
      Cls.ParentName := Toks[I + 4].Text;
      J := I + 4;
      // Skip ancestor list (possibly 'TBar, IFoo') and unit-qualified names
      while (J < Length(Toks)) and (not TokIs(Toks, J, ')')) do
        Inc(J);
      I := ParseClassBody(Toks, J + 1, Cls);
      N := Length(Result.Classes);
      SetLength(Result.Classes, N + 1);
      Result.Classes[N] := Cls;
      Continue;
    end;
    Inc(I);
  end;

  // procedure TFoo.TestBar;  -> implementation line
  for I := 0 to High(Toks) - 3 do
    if (TokIs(Toks, I, 'procedure') or TokIs(Toks, I, 'function')) and
       TokIsIdent(Toks, I + 1) and TokIs(Toks, I + 2, '.') and TokIsIdent(Toks, I + 3) then
      for ClassIdx := 0 to High(Result.Classes) do
        if SameText(Result.Classes[ClassIdx].Name, Toks[I + 1].Text) then
          for M := 0 to High(Result.Classes[ClassIdx].Methods) do
            if SameText(Result.Classes[ClassIdx].Methods[M].Name, Toks[I + 3].Text) then
              Result.Classes[ClassIdx].Methods[M].ImplLine := Toks[I + 3].Line;

  // RegisterTest / RegisterTests anywhere in the unit
  for K := 0 to High(Toks) do
    if TokIs(Toks, K, 'RegisterTest') or TokIs(Toks, K, 'RegisterTests') then
    begin
      Result.HasRegisterTest := True;
      Break;
    end;
end;

procedure ResolveTestClasses(var AUnits: TTestUnitInfoArray);
var
  Known: array of string;
  Changed: Boolean;
  U, C, K, N: Integer;
  IsKnown: Boolean;
  Kept: TTestClassInfoArray;

  function InKnown(const AName: string): Boolean;
  var
    X: Integer;
  begin
    Result := False;
    for X := 0 to High(Known) do
      if SameText(Known[X], AName) then
        Exit(True);
  end;

begin
  Known := nil;
  SetLength(Known, 1);
  Known[0] := 'TTestCase';

  repeat
    Changed := False;
    for U := 0 to High(AUnits) do
      for C := 0 to High(AUnits[U].Classes) do
      begin
        if AUnits[U].Classes[C].IsTest then
          Continue;
        if InKnown(AUnits[U].Classes[C].ParentName) then
        begin
          AUnits[U].Classes[C].IsTest := True;
          N := Length(Known);
          SetLength(Known, N + 1);
          Known[N] := AUnits[U].Classes[C].Name;
          Changed := True;
        end;
      end;
  until not Changed;

  for U := 0 to High(AUnits) do
  begin
    Kept := nil;
    for C := 0 to High(AUnits[U].Classes) do
    begin
      IsKnown := AUnits[U].Classes[C].IsTest;
      if IsKnown then
      begin
        K := Length(Kept);
        SetLength(Kept, K + 1);
        Kept[K] := AUnits[U].Classes[C];
      end;
    end;
    AUnits[U].Classes := Kept;
  end;
end;

function IsPathInside(const ADir, ABase: string): Boolean;
var
  D, B: string;
begin
  D := IncludeTrailingPathDelimiter(ExpandFileName(NormalizeNativeSeparators(ADir)));
  B := IncludeTrailingPathDelimiter(ExpandFileName(NormalizeNativeSeparators(ABase)));
  {$IFDEF WINDOWS}
  Result := (Length(D) >= Length(B)) and SameText(Copy(D, 1, Length(B)), B);
  {$ELSE}
  Result := (Length(D) >= Length(B)) and (Copy(D, 1, Length(B)) = B);
  {$ENDIF}
end;

function IsExcludedDir(const ADir: string): Boolean;
var
  Norm: string;
begin
  Norm := '/' + LowerCase(NormalizeForwardSlashes(IncludeTrailingPathDelimiter(ADir)));
  Result := (Pos('/.nik/', Norm) > 0) or (Pos('/.git/', Norm) > 0) or
    (Pos('/node_modules/', Norm) > 0);
end;

procedure AddWarning(var AResult: TTestDiscoveryResult; const AFile: string;
  ALine: Integer; const AMsg: string);
var
  N: Integer;
begin
  N := Length(AResult.Warnings);
  SetLength(AResult.Warnings, N + 1);
  AResult.Warnings[N].FilePath := AFile;
  AResult.Warnings[N].Line := ALine;
  AResult.Warnings[N].Message := AMsg;
end;

function DiscoverTestUnits(const AProjectDir: string;
  const ARoots: TStringArray): TTestDiscoveryResult;
var
  Seen: array of string;
  R, I, J, N, ClassCount: Integer;
  RootDir, FilePath, Expected: string;
  SR: TSearchRec;
  Info: TTestUnitInfo;
  Files: array of string;

  function AlreadySeen(const AValue: string): Boolean;
  var
    X: Integer;
  begin
    Result := False;
    for X := 0 to High(Seen) do
    begin
      {$IFDEF WINDOWS}
      if SameText(Seen[X], AValue) then
      {$ELSE}
      if Seen[X] = AValue then
      {$ENDIF}
        Exit(True);
    end;
  end;

begin
  Result := Default(TTestDiscoveryResult);
  Seen := nil;
  Files := nil;

  for R := 0 to High(ARoots) do
  begin
    RootDir := ExcludeTrailingPathDelimiter(ExpandFileName(NormalizeNativeSeparators(ARoots[R])));
    if (RootDir = '') or (not DirectoryExists(RootDir)) then
      Continue;
    if not IsPathInside(RootDir, AProjectDir) then
      Continue;
    if IsExcludedDir(RootDir) or AlreadySeen(RootDir) then
      Continue;
    N := Length(Seen);
    SetLength(Seen, N + 1);
    Seen[N] := RootDir;

    if FindFirst(JoinPath(RootDir, '*'), faAnyFile and (not faDirectory), SR) = 0 then
    begin
      try
        repeat
          if IsTestUnitFileName(SR.Name) then
          begin
            N := Length(Files);
            SetLength(Files, N + 1);
            Files[N] := JoinPath(RootDir, SR.Name);
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
  end;

  for I := 0 to High(Files) do
  begin
    FilePath := Files[I];
    Info := ScanTestUnitSource(FilePath, ReadFileTextUtf8(FilePath));
    Expected := ChangeFileExt(ExtractFileName(FilePath), '');
    if Info.UnitName = '' then
      raise ENikError.CreateFmt('%s:1: Test file does not declare a unit.', [FilePath]);
    if not SameText(Info.UnitName, Expected) then
      raise ENikError.CreateFmt('%s:%d: Unit name ''%s'' must match the file name (expected ''%s'').',
        [FilePath, Info.UnitLine, Info.UnitName, Expected]);
    for J := 0 to High(Result.Units) do
      if SameText(Result.Units[J].UnitName, Info.UnitName) then
        raise ENikError.CreateFmt('Duplicate test unit ''%s'': %s and %s',
          [Info.UnitName, Result.Units[J].FilePath, FilePath]);
    N := Length(Result.Units);
    SetLength(Result.Units, N + 1);
    Result.Units[N] := Info;
  end;

  ResolveTestClasses(Result.Units);

  // Stable order by unit name
  for I := 0 to High(Result.Units) - 1 do
    for J := I + 1 to High(Result.Units) do
      if CompareText(Result.Units[J].UnitName, Result.Units[I].UnitName) < 0 then
      begin
        Info := Result.Units[I];
        Result.Units[I] := Result.Units[J];
        Result.Units[J] := Info;
      end;

  for I := 0 to High(Result.Units) do
  begin
    ClassCount := Length(Result.Units[I].Classes);
    if ClassCount = 0 then
      AddWarning(Result, Result.Units[I].FilePath, Result.Units[I].UnitLine,
        Format('Test unit ''%s'' declares no TTestCase descendants.', [Result.Units[I].UnitName]))
    else if not Result.Units[I].HasRegisterTest then
      AddWarning(Result, Result.Units[I].FilePath, Result.Units[I].UnitLine,
        Format('Test unit ''%s'' declares test classes but never calls RegisterTest in its initialization section.',
          [Result.Units[I].UnitName]));
  end;
end;

function GlobMatch(const APattern, AText: string): Boolean;
var
  P, T, StarP, StarT: Integer;
begin
  P := 1;
  T := 1;
  StarP := 0;
  StarT := 0;
  while T <= Length(AText) do
  begin
    if (P <= Length(APattern)) and (APattern[P] = '*') then
    begin
      StarP := P;
      StarT := T;
      Inc(P);
    end
    else if (P <= Length(APattern)) and (APattern[P] = AText[T]) then
    begin
      Inc(P);
      Inc(T);
    end
    else if StarP > 0 then
    begin
      P := StarP + 1;
      Inc(StarT);
      T := StarT;
    end
    else
      Exit(False);
  end;
  while (P <= Length(APattern)) and (APattern[P] = '*') do
    Inc(P);
  Result := P > Length(APattern);
end;

function TestIdMatchesFilter(const AId, AFilter: string): Boolean;
var
  Id, Flt: string;
begin
  Id := LowerCase(AId);
  Flt := LowerCase(Trim(AFilter));
  if Flt = '' then
    Exit(True);
  if Pos('*', Flt) > 0 then
    Exit(GlobMatch(Flt, Id));
  Result := (Id = Flt) or ((Length(Id) > Length(Flt)) and (Copy(Id, 1, Length(Flt) + 1) = Flt + '.'));
end;

function TestIdMatchesAnyFilter(const AId: string; const AFilters: TStringArray): Boolean;
var
  I: Integer;
begin
  if Length(AFilters) = 0 then
    Exit(True);
  for I := 0 to High(AFilters) do
    if TestIdMatchesFilter(AId, AFilters[I]) then
      Exit(True);
  Result := False;
end;

end.
