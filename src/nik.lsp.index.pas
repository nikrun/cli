unit nik.lsp.index;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Contnrs,
  nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.utf16;

type
  TPasUnitSymbol = record
    Name: string;
    NameLower: string;
    ContainerName: string;
    Detail: string;
    Signature: string;
    DocComment: string;
    Params: TLspStringArray;
    Kind: TLspSymbolKind;
    CompletionKind: TLspCompletionItemKind;
    IsInterfaceSection: Boolean;
    ParentSymbolIndex: Integer; // -1 for root
    Range: TLspRange;
    SelectionRange: TLspRange;
  end;
  TPasUnitSymbolArray = array of TPasUnitSymbol;

  TPasIndexedFile = class
  public
    Uri: string;
    NormalizedKey: string;
    FilePath: string;
    ModuleName: string;
    ModuleNameLower: string;
    UsedUnits: TLspStringArray;
    Symbols: TPasUnitSymbolArray;
  end;

  TNikSymbolIndex = class
  private
    FFiles: TFPList;            // Owns TPasIndexedFile
    FFileKeyHash: TFPHashList;  // O(1) NormalizedKey -> Pointer(PtrInt(FileIndex + 1))
    FSearchDirs: TStringList;   // Project unit paths + SDK rtl/packages source dirs
    FUnitPathsPool: TStringList;// Stores full path strings indexed by FUnitHash
    FUnitHash: TFPHashList;     // O(1) unitname_lower -> Pointer(PtrInt(PoolIndex + 1))
    procedure SetUnitMapEntry(const AUnitLower, AFullPath: string; AOverwrite: Boolean);
    function GetUnitMapEntry(const AUnitLower: string): string;
    procedure RebuildUnitFileMap;
    procedure ScanDirectoryForUnits(const ADir: string; AMaxDepth: Integer);
    function FindIndexedByKey(const ANormalizedKey: string): Integer;
    function FindIndexedByUnitLower(const AUnitLower: string): TPasIndexedFile;
    function EnsureUnitIndexed(const AUnitName: string): TPasIndexedFile;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    procedure ConfigureSearchPaths(const AProjectUnitDirs: array of string;
      const ARtlSourceDir, APackagesSourceDir: string);
    procedure IndexProjectUnitDirs(const AProjectUnitDirs: array of string);

    function IndexText(const AUri, AFilePath, ASourceText: string): TPasIndexedFile;
    function IndexDiskFile(const AFilePath: string): TPasIndexedFile;
    function FindFileByUri(const AUri: string): TPasIndexedFile;
    function DoesFileUseUnit(const AUri, AUnitNameLower: string): Boolean;

    function BuildDocumentSymbols(const AUri: string): TLspDocumentSymbolArray;
    function SearchWorkspaceSymbols(const AQuery: string; AMaxResults: Integer = 100): TLspSymbolInformationArray;
    function ResolveDefinitions(const AUri, AIdent: string): TLspLocationArray;
    function ResolveHover(const AUri, AIdent: string; const AWordRange: TLspRange): TLspHover;
    function ResolveCompletions(const AUri, ALinePrefix: string): TLspCompletionList;
    function ResolveSignatureHelp(const AUri, ACalleeIdent: string; AActiveParam: Integer): TLspSignatureHelp;
  end;

function ParsePascalSourceSymbols(const AUri, AFilePath, AText: string): TPasIndexedFile;

implementation

uses
  nik.types, nik.paths;

type
  TTokKind = (ttkEof, ttkIdent, ttkSymbol, ttkString, ttkNumber);

  TToken = record
    Kind: TTokKind;
    Text: string;
    Lower: string;
    Line: Integer;     // 0-based
    StartCol: Integer; // 0-based UTF-16 col
    EndCol: Integer;   // 0-based UTF-16 col
    PrecedingDoc: string;
  end;
  TTokenArray = array of TToken;

function IsIdentStart(ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= 'A') and (ACh <= 'Z')) or ((ACh >= 'a') and (ACh <= 'z')) or (ACh = '_');
end;

function IsIdentCont(ACh: Char): Boolean; inline;
begin
  Result := IsIdentStart(ACh) or ((ACh >= '0') and (ACh <= '9'));
end;

procedure AppendStr(var AArr: TLspStringArray; const AVal: string);
var
  I, N: Integer;
begin
  if AVal = '' then
    Exit;
  for I := 0 to High(AArr) do
    if SameText(AArr[I], AVal) then
      Exit;
  N := Length(AArr);
  SetLength(AArr, N + 1);
  AArr[N] := AVal;
end;

function CleanCommentText(const ARaw: string): string;
var
  Lines: TStringList;
  I: Integer;
  L: string;
begin
  Result := Trim(ARaw);
  if Result = '' then
    Exit('');
  // Ignore compiler directives {$...}
  if (Result[1] = '$') then
    Exit('');

  Lines := TStringList.Create;
  try
    Lines.Text := Result;
    Result := '';
    for I := 0 to Lines.Count - 1 do
    begin
      L := Trim(Lines[I]);
      if (Length(L) > 0) and (L[1] = '*') then
        L := TrimLeft(Copy(L, 2, MaxInt));
      if L <> '' then
      begin
        if Result <> '' then
          Result := Result + #10;
        Result := Result + L;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TokenizePascal(const AText: string; out ATokens: TTokenArray);
var
  Len, PosIdx, LineNum, CurColUtf16, TokStart, Count, Cap, BlankLines: Integer;
  PendingDoc, CommentBody: string;
  Ch: Char;

  procedure StepChar; inline;
  var
    B0: Byte;
    Rem: Integer;
  begin
    B0 := Byte(AText[PosIdx]);
    if B0 < $80 then
    begin
      Inc(PosIdx);
      Inc(CurColUtf16);
      Exit;
    end;
    Rem := Len - PosIdx + 1;
    if ((B0 and $E0) = $C0) and (Rem >= 2) then
    begin
      Inc(PosIdx, 2);
      Inc(CurColUtf16);
    end
    else if ((B0 and $F0) = $E0) and (Rem >= 3) then
    begin
      Inc(PosIdx, 3);
      Inc(CurColUtf16);
    end
    else if ((B0 and $F8) = $F0) and (Rem >= 4) then
    begin
      Inc(PosIdx, 4);
      Inc(CurColUtf16, 2);
    end
    else
    begin
      Inc(PosIdx);
      Inc(CurColUtf16);
    end;
  end;

  procedure StepAscii(ACount: Integer = 1); inline;
  begin
    Inc(PosIdx, ACount);
    Inc(CurColUtf16, ACount);
  end;

  procedure PushToken(AKind: TTokKind; const AVal: string; ALine, AStartCol, AEndCol: Integer);
  begin
    if Count >= Cap then
    begin
      Cap := Cap * 2;
      SetLength(ATokens, Cap);
    end;
    ATokens[Count].Kind := AKind;
    ATokens[Count].Text := AVal;
    ATokens[Count].Lower := LowerCase(AVal);
    ATokens[Count].Line := ALine;
    ATokens[Count].StartCol := AStartCol;
    ATokens[Count].EndCol := AEndCol;
    ATokens[Count].PrecedingDoc := PendingDoc;
    PendingDoc := '';
    BlankLines := 0;
    Inc(Count);
  end;

  procedure AdvanceNewline; inline;
  begin
    if (PosIdx <= Len) and (AText[PosIdx] = #13) then
    begin
      Inc(PosIdx);
      if (PosIdx <= Len) and (AText[PosIdx] = #10) then
        Inc(PosIdx);
    end
    else if (PosIdx <= Len) and (AText[PosIdx] = #10) then
      Inc(PosIdx);
    Inc(LineNum);
    CurColUtf16 := 0;
  end;

var
  StartLine, StartCol, EndCol: Integer;
begin
  ATokens := nil;
  Len := Length(AText);
  Cap := 256;
  SetLength(ATokens, Cap);
  Count := 0;
  PosIdx := 1;
  LineNum := 0;
  CurColUtf16 := 0;
  PendingDoc := '';
  BlankLines := 0;

  while PosIdx <= Len do
  begin
    Ch := AText[PosIdx];

    // Whitespace & line breaks
    if (Ch = #13) or (Ch = #10) then
    begin
      AdvanceNewline;
      Inc(BlankLines);
      if BlankLines > 2 then
        PendingDoc := '';
      Continue;
    end;

    if Ch in [' ', #9, #11, #12] then
    begin
      StepAscii(1);
      Continue;
    end;

    // Line comment // or ///
    if (Ch = '/') and (PosIdx + 1 <= Len) and (AText[PosIdx + 1] = '/') then
    begin
      StepAscii(2);
      if (PosIdx <= Len) and (AText[PosIdx] = '/') then
        StepAscii(1);
      TokStart := PosIdx;
      while (PosIdx <= Len) and (AText[PosIdx] <> #13) and (AText[PosIdx] <> #10) do
        StepChar;
      CommentBody := Trim(Copy(AText, TokStart, PosIdx - TokStart));
      if CommentBody <> '' then
      begin
        if PendingDoc <> '' then
          PendingDoc := PendingDoc + #10 + CommentBody
        else
          PendingDoc := CommentBody;
      end;
      BlankLines := 0;
      Continue;
    end;

    // Brace comment { ... }
    if Ch = '{' then
    begin
      StepAscii(1);
      TokStart := PosIdx;
      while (PosIdx <= Len) and (AText[PosIdx] <> '}') do
      begin
        if (AText[PosIdx] = #13) or (AText[PosIdx] = #10) then
          AdvanceNewline
        else
          StepChar;
      end;
      CommentBody := CleanCommentText(Copy(AText, TokStart, PosIdx - TokStart));
      if PosIdx <= Len then
        StepAscii(1);
      if CommentBody <> '' then
        PendingDoc := CommentBody;
      BlankLines := 0;
      Continue;
    end;

    // Paren-star comment (* ... *)
    if (Ch = '(') and (PosIdx + 1 <= Len) and (AText[PosIdx + 1] = '*') then
    begin
      StepAscii(2);
      TokStart := PosIdx;
      while PosIdx <= Len do
      begin
        if (AText[PosIdx] = '*') and (PosIdx + 1 <= Len) and (AText[PosIdx + 1] = ')') then
          Break;
        if (AText[PosIdx] = #13) or (AText[PosIdx] = #10) then
          AdvanceNewline
        else
          StepChar;
      end;
      CommentBody := CleanCommentText(Copy(AText, TokStart, PosIdx - TokStart));
      if PosIdx + 1 <= Len then
        StepAscii(2)
      else
        PosIdx := Len + 1;
      if CommentBody <> '' then
        PendingDoc := CommentBody;
      BlankLines := 0;
      Continue;
    end;

    // String literal '...'
    if Ch = '''' then
    begin
      StartLine := LineNum;
      StartCol := CurColUtf16;
      TokStart := PosIdx;
      StepAscii(1);
      while PosIdx <= Len do
      begin
        if (AText[PosIdx] = #13) or (AText[PosIdx] = #10) then
          Break;
        if AText[PosIdx] = '''' then
        begin
          StepAscii(1);
          if (PosIdx <= Len) and (AText[PosIdx] = '''') then
            StepAscii(1)
          else
            Break;
        end
        else
          StepChar;
      end;
      EndCol := CurColUtf16;
      PushToken(ttkString, Copy(AText, TokStart, PosIdx - TokStart), StartLine, StartCol, EndCol);
      Continue;
    end;

    // Identifier (including escaped &ident)
    if IsIdentStart(Ch) or ((Ch = '&') and (PosIdx + 1 <= Len) and IsIdentStart(AText[PosIdx + 1])) then
    begin
      StartLine := LineNum;
      StartCol := CurColUtf16;
      if Ch = '&' then
        StepAscii(1);
      TokStart := PosIdx;
      while (PosIdx <= Len) and IsIdentCont(AText[PosIdx]) do
        StepAscii(1);
      EndCol := CurColUtf16;
      PushToken(ttkIdent, Copy(AText, TokStart, PosIdx - TokStart), StartLine, StartCol, EndCol);
      Continue;
    end;

    // Numbers ($hex, %bin, &oct, decimal)
    if (Ch in ['0'..'9']) or ((Ch = '$') and (PosIdx + 1 <= Len) and (AText[PosIdx + 1] in ['0'..'9', 'A'..'F', 'a'..'f'])) then
    begin
      StartLine := LineNum;
      StartCol := CurColUtf16;
      TokStart := PosIdx;
      StepAscii(1);
      while (PosIdx <= Len) and (AText[PosIdx] in ['0'..'9', 'A'..'F', 'a'..'f', '_']) do
        StepAscii(1);
      EndCol := CurColUtf16;
      PushToken(ttkNumber, Copy(AText, TokStart, PosIdx - TokStart), StartLine, StartCol, EndCol);
      Continue;
    end;

    // Multi-char or single-char punctuation
    StartLine := LineNum;
    StartCol := CurColUtf16;
    if (PosIdx + 1 <= Len) and
       (((Ch = ':') and (AText[PosIdx + 1] = '=')) or
        ((Ch = '<') and (AText[PosIdx + 1] in ['=', '>'])) or
        ((Ch = '>') and (AText[PosIdx + 1] = '=')) or
        ((Ch = '.') and (AText[PosIdx + 1] = '.'))) then
    begin
      PushToken(ttkSymbol, Copy(AText, PosIdx, 2), StartLine, StartCol, StartCol + 2);
      StepAscii(2);
    end
    else
    begin
      PushToken(ttkSymbol, Ch, StartLine, StartCol, StartCol + 1);
      StepChar;
    end;
  end;

  if Count >= Cap then
    SetLength(ATokens, Count + 1);
  ATokens[Count].Kind := ttkEof;
  ATokens[Count].Text := '';
  ATokens[Count].Lower := '';
  ATokens[Count].Line := LineNum;
  ATokens[Count].StartCol := 0;
  ATokens[Count].EndCol := 0;
  Inc(Count);
  SetLength(ATokens, Count);
end;

function ParsePascalSourceSymbols(const AUri, AFilePath, AText: string): TPasIndexedFile;
type
  TDeclSection = (dsNone, dsType, dsConst, dsVar);
var
  Toks: TTokenArray;
  Idx, SymCount: Integer;
  InInterface: Boolean;
  CurSection: TDeclSection;

  function Cur: TToken; inline;
  begin
    if Idx <= High(Toks) then
      Result := Toks[Idx]
    else
      Result := Toks[High(Toks)];
  end;

  function Peek(AOffset: Integer): TToken; inline;
  begin
    if (Idx + AOffset >= 0) and (Idx + AOffset <= High(Toks)) then
      Result := Toks[Idx + AOffset]
    else
      Result := Toks[High(Toks)];
  end;

var
  ResultObj: TPasIndexedFile;

  function PushSymbol(const AName, AContainer, ADetail, ASig, ADoc: string;
    AKind: TLspSymbolKind; ACompKind: TLspCompletionItemKind;
    AParentIdx: Integer; const ASelRange, AFullRange: TLspRange;
    const AParams: TLspStringArray): Integer;
  begin
    Result := SymCount;
    Inc(SymCount);
    SetLength(ResultObj.Symbols, SymCount);
    ResultObj.Symbols[Result].Name := AName;
    ResultObj.Symbols[Result].NameLower := LowerCase(AName);
    ResultObj.Symbols[Result].ContainerName := AContainer;
    ResultObj.Symbols[Result].Detail := ADetail;
    ResultObj.Symbols[Result].Signature := ASig;
    ResultObj.Symbols[Result].DocComment := ADoc;
    ResultObj.Symbols[Result].Params := AParams;
    ResultObj.Symbols[Result].Kind := AKind;
    ResultObj.Symbols[Result].CompletionKind := ACompKind;
    ResultObj.Symbols[Result].IsInterfaceSection := InInterface;
    ResultObj.Symbols[Result].ParentSymbolIndex := AParentIdx;
    ResultObj.Symbols[Result].SelectionRange := ASelRange;
    ResultObj.Symbols[Result].Range := AFullRange;
  end;

  function ReadDottedIdent(out AStartTok, AEndTok: TToken): string;
  begin
    Result := '';
    AStartTok := Cur;
    AEndTok := Cur;
    if Cur.Kind <> ttkIdent then
      Exit;
    Result := Cur.Text;
    AEndTok := Cur;
    Inc(Idx);
    while (Cur.Text = '.') and (Peek(1).Kind = ttkIdent) do
    begin
      Inc(Idx); // '.'
      Result := Result + '.' + Cur.Text;
      AEndTok := Cur;
      Inc(Idx);
    end;
  end;

  procedure SkipToSemicolon;
  var
    ParenDepth: Integer;
  begin
    ParenDepth := 0;
    while Cur.Kind <> ttkEof do
    begin
      if (Cur.Text = '(') or (Cur.Text = '[') then
        Inc(ParenDepth)
      else if (Cur.Text = ')') or (Cur.Text = ']') then
      begin
        if ParenDepth > 0 then
          Dec(ParenDepth);
      end
      else if (ParenDepth = 0) and (Cur.Text = ';') then
      begin
        Inc(Idx);
        Break;
      end
      else if (ParenDepth = 0) and
              ((Cur.Lower = 'implementation') or (Cur.Lower = 'begin') or
               (Cur.Lower = 'end') or (Cur.Lower = 'initialization') or
               (Cur.Lower = 'finalization')) then
        Break;
      Inc(Idx);
    end;
  end;

  procedure SkipRoutineBodyIfPresent;
  var
    BlockDepth: Integer;
  begin
    // Skip routine modifiers (overload; virtual; inline; etc.) until either 'begin'/'asm' or next top-level keyword
    while Cur.Kind <> ttkEof do
    begin
      if (Cur.Lower = 'overload') or (Cur.Lower = 'virtual') or (Cur.Lower = 'override') or
         (Cur.Lower = 'abstract') or (Cur.Lower = 'reintroduce') or (Cur.Lower = 'inline') or
         (Cur.Lower = 'static') or (Cur.Lower = 'cdecl') or (Cur.Lower = 'stdcall') or
         (Cur.Lower = 'register') or (Cur.Lower = 'safecall') or (Cur.Lower = 'noreturn') or
         (Cur.Lower = 'public') or (Cur.Lower = 'deprecated') or (Cur.Lower = 'platform') or
         (Cur.Lower = 'experimental') then
      begin
        SkipToSemicolon;
        Continue;
      end;

      if (Cur.Lower = 'forward') or (Cur.Lower = 'external') then
      begin
        SkipToSemicolon;
        Exit;
      end;

      Break;
    end;

    if InInterface then
      Exit;

    // In implementation/program, skip local var/const/type/nested procs + begin..end;
    while (Cur.Kind <> ttkEof) and
          ((Cur.Lower = 'var') or (Cur.Lower = 'const') or (Cur.Lower = 'type') or
           (Cur.Lower = 'resourcestring') or (Cur.Lower = 'label')) do
    begin
      Inc(Idx);
      while (Cur.Kind <> ttkEof) and (Cur.Lower <> 'begin') and (Cur.Lower <> 'asm') and
            (Cur.Lower <> 'procedure') and (Cur.Lower <> 'function') and
            (Cur.Lower <> 'constructor') and (Cur.Lower <> 'destructor') do
      begin
        if (Cur.Lower = 'record') or (Cur.Lower = 'case') then
        begin
          Inc(Idx);
          BlockDepth := 1;
          while (Cur.Kind <> ttkEof) and (BlockDepth > 0) do
          begin
            if (Cur.Lower = 'record') or (Cur.Lower = 'case') then
              Inc(BlockDepth)
            else if Cur.Lower = 'end' then
              Dec(BlockDepth);
            Inc(Idx);
          end;
        end
        else
          Inc(Idx);
      end;
    end;

    if (Cur.Lower = 'begin') or (Cur.Lower = 'asm') then
    begin
      BlockDepth := 1;
      Inc(Idx);
      while (Cur.Kind <> ttkEof) and (BlockDepth > 0) do
      begin
        if (Cur.Lower = 'begin') or (Cur.Lower = 'try') or (Cur.Lower = 'case') or (Cur.Lower = 'asm') then
          Inc(BlockDepth)
        else if Cur.Lower = 'end' then
          Dec(BlockDepth);
        Inc(Idx);
      end;
      if Cur.Text = ';' then
        Inc(Idx);
    end;
  end;

  procedure ParseRoutineDeclaration(AParentStructIdx: Integer; const AOwnerTypeName, ALeadingPrefix: string);
  var
    KwTok, NameTok, EndSigTok: TToken;
    Kw, ProcName, Container, SigText, ParamAccum, RetType, Doc: string;
    Params: TLspStringArray;
    ParenDepth: Integer;
    SymKind: TLspSymbolKind;
    CompKind: TLspCompletionItemKind;
    SelRange, FullRange: TLspRange;
  begin
    KwTok := Cur;
    Kw := KwTok.Lower;
    Doc := KwTok.PrecedingDoc;
    Inc(Idx);

    // Optional 'generic' before function name is handled before calling, or handle here
    if Cur.Kind <> ttkIdent then
    begin
      SkipToSemicolon;
      Exit;
    end;

    Container := AOwnerTypeName;
    NameTok := Cur;
    ProcName := Cur.Text;
    Inc(Idx);

    // Qualified method implementation: TMyClass.MyMethod
    if (Cur.Text = '.') and (Peek(1).Kind = ttkIdent) then
    begin
      Container := ProcName;
      Inc(Idx); // '.'
      NameTok := Cur;
      ProcName := Cur.Text;
      Inc(Idx);
    end;

    // Optional generic <T>
    if Cur.Text = '<' then
    begin
      ParenDepth := 1;
      Inc(Idx);
      while (Cur.Kind <> ttkEof) and (ParenDepth > 0) do
      begin
        if Cur.Text = '<' then Inc(ParenDepth)
        else if Cur.Text = '>' then Dec(ParenDepth);
        Inc(Idx);
      end;
    end;

    Params := nil;
    SigText := Trim(ALeadingPrefix + ' ' + Kw + ' ');
    if Container <> '' then
      SigText := SigText + Container + '.' + ProcName
    else
      SigText := SigText + ProcName;

    // Parameter list (...)
    if Cur.Text = '(' then
    begin
      SigText := SigText + '(';
      Inc(Idx);
      ParenDepth := 1;
      ParamAccum := '';
      while (Cur.Kind <> ttkEof) and (ParenDepth > 0) do
      begin
        if Cur.Text = '(' then
        begin
          Inc(ParenDepth);
          ParamAccum := ParamAccum + '(';
        end
        else if Cur.Text = ')' then
        begin
          Dec(ParenDepth);
          if ParenDepth > 0 then
            ParamAccum := ParamAccum + ')'
          else
          begin
            if Trim(ParamAccum) <> '' then
              AppendStr(Params, Trim(ParamAccum));
          end;
        end
        else if (ParenDepth = 1) and (Cur.Text = ';') then
        begin
          if Trim(ParamAccum) <> '' then
            AppendStr(Params, Trim(ParamAccum));
          SigText := SigText + Trim(ParamAccum) + '; ';
          ParamAccum := '';
        end
        else
        begin
          if (ParamAccum <> '') and (Cur.Text <> ':') and (Cur.Text <> ',') and
             (ParamAccum[Length(ParamAccum)] <> '(') and (ParamAccum[Length(ParamAccum)] <> '[') then
            ParamAccum := ParamAccum + ' ';
          ParamAccum := ParamAccum + Cur.Text;
        end;
        Inc(Idx);
      end;
      if Trim(ParamAccum) <> '' then
        SigText := SigText + Trim(ParamAccum);
      SigText := SigText + ')';
    end;

    // Return type ': TResult'
    RetType := '';
    if (Cur.Text = ':') then
    begin
      Inc(Idx);
      while (Cur.Kind <> ttkEof) and (Cur.Text <> ';') do
      begin
        if (RetType <> '') and (Cur.Text <> '.') and (RetType[Length(RetType)] <> '.') then
          RetType := RetType + ' ';
        RetType := RetType + Cur.Text;
        Inc(Idx);
      end;
      if RetType <> '' then
        SigText := SigText + ': ' + RetType;
    end;

    EndSigTok := Peek(-1);
    if Cur.Text = ';' then
    begin
      EndSigTok := Cur;
      Inc(Idx);
    end;

    if Kw = 'constructor' then
    begin
      SymKind := lskConstructor;
      CompKind := lcikConstructor;
    end
    else if (Container <> '') or (AParentStructIdx >= 0) then
    begin
      SymKind := lskMethod;
      CompKind := lcikMethod;
    end
    else
    begin
      SymKind := lskFunction;
      CompKind := lcikFunction;
    end;

    SelRange := TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol);
    FullRange := TLspRange.Create(
      TLspPosition.Create(KwTok.Line, KwTok.StartCol),
      TLspPosition.Create(EndSigTok.Line, EndSigTok.EndCol)
    );

    PushSymbol(ProcName, Container, RetType, SigText + ';', Doc,
      SymKind, CompKind, AParentStructIdx, SelRange, FullRange, Params);

    if AParentStructIdx < 0 then
      SkipRoutineBodyIfPresent;
  end;

  procedure ParseStructuredTypeMembers(AParentIdx: Integer; const ATypeName: string);
  var
    MemberTok, TypeTok: TToken;
    FieldNames: array of TToken;
    I: Integer;
    FieldType, Doc: string;
    EmptyParams: TLspStringArray;
  begin
    EmptyParams := nil;
    while (Cur.Kind <> ttkEof) and (Cur.Lower <> 'end') do
    begin
      // Visibility specifiers
      if (Cur.Lower = 'private') or (Cur.Lower = 'protected') or (Cur.Lower = 'public') or
         (Cur.Lower = 'published') then
      begin
        Inc(Idx);
        Continue;
      end;
      if (Cur.Lower = 'strict') and ((Peek(1).Lower = 'private') or (Peek(1).Lower = 'protected')) then
      begin
        Inc(Idx, 2);
        Continue;
      end;

      if Cur.Lower = 'class' then
      begin
        if (Peek(1).Lower = 'function') or (Peek(1).Lower = 'procedure') or
           (Peek(1).Lower = 'constructor') or (Peek(1).Lower = 'destructor') then
        begin
          Inc(Idx); // 'class'
          ParseRoutineDeclaration(AParentIdx, ATypeName, 'class');
          Continue;
        end;
        Inc(Idx);
        Continue;
      end;

      if (Cur.Lower = 'procedure') or (Cur.Lower = 'function') or
         (Cur.Lower = 'constructor') or (Cur.Lower = 'destructor') then
      begin
        ParseRoutineDeclaration(AParentIdx, ATypeName, '');
        Continue;
      end;

      if Cur.Lower = 'property' then
      begin
        Doc := Cur.PrecedingDoc;
        Inc(Idx);
        if Cur.Kind = ttkIdent then
        begin
          MemberTok := Cur;
          Inc(Idx);
          FieldType := '';
          if Cur.Text = '[' then
          begin
            while (Cur.Kind <> ttkEof) and (Cur.Text <> ']') do
              Inc(Idx);
            if Cur.Text = ']' then
              Inc(Idx);
          end;
          if Cur.Text = ':' then
          begin
            Inc(Idx);
            if Cur.Kind = ttkIdent then
              FieldType := Cur.Text;
          end;
          SkipToSemicolon;
          PushSymbol(
            MemberTok.Text, ATypeName, FieldType,
            'property ' + ATypeName + '.' + MemberTok.Text + ': ' + FieldType,
            Doc, lskProperty, lcikProperty, AParentIdx,
            TLspRange.SingleLine(MemberTok.Line, MemberTok.StartCol, MemberTok.EndCol),
            TLspRange.SingleLine(MemberTok.Line, MemberTok.StartCol, MemberTok.EndCol),
            EmptyParams
          );
        end
        else
          SkipToSemicolon;
        Continue;
      end;

      // Field declarations: FName1, FName2: TType;
      if (Cur.Kind = ttkIdent) and ((Peek(1).Text = ':') or (Peek(1).Text = ',')) then
      begin
        Doc := Cur.PrecedingDoc;
        FieldNames := nil;
        while Cur.Kind = ttkIdent do
        begin
          SetLength(FieldNames, Length(FieldNames) + 1);
          FieldNames[High(FieldNames)] := Cur;
          Inc(Idx);
          if Cur.Text = ',' then
            Inc(Idx)
          else
            Break;
        end;
        FieldType := '';
        if Cur.Text = ':' then
        begin
          Inc(Idx);
          TypeTok := Cur;
          if TypeTok.Kind = ttkIdent then
            FieldType := TypeTok.Text;
        end;
        SkipToSemicolon;
        for I := 0 to High(FieldNames) do
        begin
          PushSymbol(
            FieldNames[I].Text, ATypeName, FieldType,
            FieldNames[I].Text + ': ' + FieldType,
            Doc, lskField, lcikField, AParentIdx,
            TLspRange.SingleLine(FieldNames[I].Line, FieldNames[I].StartCol, FieldNames[I].EndCol),
            TLspRange.SingleLine(FieldNames[I].Line, FieldNames[I].StartCol, FieldNames[I].EndCol),
            EmptyParams
          );
        end;
        Continue;
      end;

      // Skip nested case/var/const/other tokens inside record/class safely
      if Cur.Lower = 'case' then
      begin
        SkipToSemicolon;
        Continue;
      end;

      Inc(Idx);
    end;

    // Update parent full range end to 'end'
    if (AParentIdx >= 0) and (AParentIdx < Length(ResultObj.Symbols)) and (Cur.Lower = 'end') then
    begin
      ResultObj.Symbols[AParentIdx].Range.EndPos := TLspPosition.Create(Cur.Line, Cur.EndCol);
      Inc(Idx); // 'end'
      if Cur.Text = ';' then
        Inc(Idx);
    end;
  end;

  procedure ParseTypeDeclaration;
  var
    NameTok, KwTok, EnumTok: TToken;
    TypeName, Doc, KindDetail: string;
    SymKind: TLspSymbolKind;
    CompKind: TLspCompletionItemKind;
    StructIdx, ParenDepth: Integer;
    EmptyParams: TLspStringArray;
  begin
    EmptyParams := nil;
    Doc := Cur.PrecedingDoc;
    if Cur.Lower = 'generic' then
      Inc(Idx);
    if Cur.Kind <> ttkIdent then
    begin
      Inc(Idx);
      Exit;
    end;

    NameTok := Cur;
    TypeName := NameTok.Text;
    Inc(Idx);

    // Optional generic <T>
    if Cur.Text = '<' then
    begin
      ParenDepth := 1;
      Inc(Idx);
      while (Cur.Kind <> ttkEof) and (ParenDepth > 0) do
      begin
        if Cur.Text = '<' then Inc(ParenDepth)
        else if Cur.Text = '>' then Dec(ParenDepth);
        Inc(Idx);
      end;
    end;

    if Cur.Text <> '=' then
    begin
      SkipToSemicolon;
      Exit;
    end;
    Inc(Idx); // '='

    if Cur.Lower = 'packed' then
      Inc(Idx);

    KwTok := Cur;

    // Enum type: TMyEnum = (evOne, evTwo);
    if KwTok.Text = '(' then
    begin
      StructIdx := PushSymbol(
        TypeName, '', 'enum', 'type ' + TypeName + ' = (...)', Doc,
        lskEnum, lcikEnum, -1,
        TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
        TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
        EmptyParams
      );
      Inc(Idx); // '('
      while (Cur.Kind <> ttkEof) and (Cur.Text <> ')') do
      begin
        if Cur.Kind = ttkIdent then
        begin
          EnumTok := Cur;
          PushSymbol(
            EnumTok.Text, TypeName, TypeName, EnumTok.Text + ': ' + TypeName, '',
            lskEnumMember, lcikEnumMember, StructIdx,
            TLspRange.SingleLine(EnumTok.Line, EnumTok.StartCol, EnumTok.EndCol),
            TLspRange.SingleLine(EnumTok.Line, EnumTok.StartCol, EnumTok.EndCol),
            EmptyParams
          );
          Inc(Idx);
          while (Cur.Kind <> ttkEof) and (Cur.Text <> ',') and (Cur.Text <> ')') do
            Inc(Idx);
        end
        else
          Inc(Idx);
        if Cur.Text = ',' then
          Inc(Idx);
      end;
      if Cur.Text = ')' then
      begin
        ResultObj.Symbols[StructIdx].Range.EndPos := TLspPosition.Create(Cur.Line, Cur.EndCol);
        Inc(Idx);
      end;
      if Cur.Text = ';' then
        Inc(Idx);
      Exit;
    end;

    // Class / Record / Interface / Object
    if (KwTok.Lower = 'class') or (KwTok.Lower = 'record') or
       (KwTok.Lower = 'interface') or (KwTok.Lower = 'object') then
    begin
      // Forward declaration 'TMyClass = class;' or 'class of ...'
      if (KwTok.Lower = 'class') and ((Peek(1).Text = ';') or (Peek(1).Lower = 'of')) then
      begin
        SkipToSemicolon;
        PushSymbol(
          TypeName, '', 'class reference', 'type ' + TypeName, Doc,
          lskClass, lcikClass, -1,
          TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
          TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
          EmptyParams
        );
        Exit;
      end;

      if KwTok.Lower = 'record' then
      begin
        SymKind := lskStruct;
        CompKind := lcikStruct;
        KindDetail := 'record';
      end
      else if KwTok.Lower = 'interface' then
      begin
        SymKind := lskInterface;
        CompKind := lcikInterface;
        KindDetail := 'interface';
      end
      else
      begin
        SymKind := lskClass;
        CompKind := lcikClass;
        KindDetail := KwTok.Lower;
      end;

      Inc(Idx); // 'class' / 'record' / 'interface'

      // Optional ancestor list (...) and GUID [...]
      if Cur.Text = '(' then
      begin
        ParenDepth := 1;
        Inc(Idx);
        while (Cur.Kind <> ttkEof) and (ParenDepth > 0) do
        begin
          if Cur.Text = '(' then Inc(ParenDepth)
          else if Cur.Text = ')' then Dec(ParenDepth);
          Inc(Idx);
        end;
      end;
      if Cur.Text = '[' then
      begin
        while (Cur.Kind <> ttkEof) and (Cur.Text <> ']') do
          Inc(Idx);
        if Cur.Text = ']' then
          Inc(Idx);
      end;

      // Empty class definition without members: TMyErr = class(Exception);
      if Cur.Text = ';' then
      begin
        PushSymbol(
          TypeName, '', KindDetail, 'type ' + TypeName + ' = ' + KindDetail, Doc,
          SymKind, CompKind, -1,
          TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
          TLspRange.Create(TLspPosition.Create(NameTok.Line, NameTok.StartCol), TLspPosition.Create(Cur.Line, Cur.EndCol)),
          EmptyParams
        );
        Inc(Idx);
        Exit;
      end;

      StructIdx := PushSymbol(
        TypeName, '', KindDetail, 'type ' + TypeName + ' = ' + KindDetail, Doc,
        SymKind, CompKind, -1,
        TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
        TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
        EmptyParams
      );
      ParseStructuredTypeMembers(StructIdx, TypeName);
      Exit;
    end;

    // Alias / array / pointer / procedural type
    KindDetail := KwTok.Text;
    SkipToSemicolon;
    PushSymbol(
      TypeName, '', KindDetail, 'type ' + TypeName + ' = ' + KindDetail, Doc,
      lskClass, lcikTypeParameter, -1,
      TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
      TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
      EmptyParams
    );
  end;

  procedure ParseConstDeclaration;
  var
    NameTok: TToken;
    Doc, ValPreview: string;
    EmptyParams: TLspStringArray;
  begin
    EmptyParams := nil;
    if Cur.Kind <> ttkIdent then
    begin
      Inc(Idx);
      Exit;
    end;
    Doc := Cur.PrecedingDoc;
    NameTok := Cur;
    Inc(Idx);
    ValPreview := '';
    if (Cur.Text = ':') or (Cur.Text = '=') then
    begin
      while (Cur.Kind <> ttkEof) and (Cur.Text <> ';') do
      begin
        if Length(ValPreview) < 60 then
        begin
          if ValPreview <> '' then
            ValPreview := ValPreview + ' ';
          ValPreview := ValPreview + Cur.Text;
        end;
        Inc(Idx);
      end;
    end;
    if Cur.Text = ';' then
      Inc(Idx);
    PushSymbol(
      NameTok.Text, '', ValPreview, 'const ' + NameTok.Text + ' ' + ValPreview, Doc,
      lskConstant, lcikConstant, -1,
      TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
      TLspRange.SingleLine(NameTok.Line, NameTok.StartCol, NameTok.EndCol),
      EmptyParams
    );
  end;

  procedure ParseVarDeclaration;
  var
    Names: array of TToken;
    Doc, VarType: string;
    I: Integer;
    EmptyParams: TLspStringArray;
  begin
    EmptyParams := nil;
    if Cur.Kind <> ttkIdent then
    begin
      Inc(Idx);
      Exit;
    end;
    Doc := Cur.PrecedingDoc;
    Names := nil;
    while Cur.Kind = ttkIdent do
    begin
      SetLength(Names, Length(Names) + 1);
      Names[High(Names)] := Cur;
      Inc(Idx);
      if Cur.Text = ',' then
        Inc(Idx)
      else
        Break;
    end;
    VarType := '';
    if Cur.Text = ':' then
    begin
      Inc(Idx);
      if Cur.Kind = ttkIdent then
        VarType := Cur.Text;
    end;
    SkipToSemicolon;
    for I := 0 to High(Names) do
    begin
      PushSymbol(
        Names[I].Text, '', VarType, 'var ' + Names[I].Text + ': ' + VarType, Doc,
        lskVariable, lcikVariable, -1,
        TLspRange.SingleLine(Names[I].Line, Names[I].StartCol, Names[I].EndCol),
        TLspRange.SingleLine(Names[I].Line, Names[I].StartCol, Names[I].EndCol),
        EmptyParams
      );
    end;
  end;

var
  HeaderStart, HeaderEnd: TToken;
  UsedUnitName: string;
  MainBlockDepth: Integer;
begin
  ResultObj := TPasIndexedFile.Create;
  ResultObj.Uri := AUri;
  ResultObj.NormalizedKey := LowerCase(NormalizeDocumentUri(AUri));
  ResultObj.FilePath := AFilePath;
  if AFilePath <> '' then
    ResultObj.ModuleName := ChangeFileExt(ExtractFileName(AFilePath), '');
  ResultObj.ModuleNameLower := LowerCase(ResultObj.ModuleName);
  SymCount := 0;

  TokenizePascal(AText, Toks);
  Idx := 0;
  InInterface := True;
  CurSection := dsNone;

  // Optional unit / program / library header
  if (Cur.Lower = 'unit') or (Cur.Lower = 'program') or (Cur.Lower = 'library') then
  begin
    if Cur.Lower <> 'unit' then
      InInterface := False;
    Inc(Idx);
    UsedUnitName := ReadDottedIdent(HeaderStart, HeaderEnd);
    if UsedUnitName <> '' then
    begin
      ResultObj.ModuleName := UsedUnitName;
      ResultObj.ModuleNameLower := LowerCase(UsedUnitName);
    end;
    SkipToSemicolon;
  end;

  while Cur.Kind <> ttkEof do
  begin
    if Cur.Lower = 'interface' then
    begin
      InInterface := True;
      CurSection := dsNone;
      Inc(Idx);
      Continue;
    end;

    if Cur.Lower = 'implementation' then
    begin
      InInterface := False;
      CurSection := dsNone;
      Inc(Idx);
      Continue;
    end;

    if Cur.Lower = 'uses' then
    begin
      CurSection := dsNone;
      Inc(Idx);
      while (Cur.Kind <> ttkEof) and (Cur.Text <> ';') do
      begin
        if Cur.Kind = ttkIdent then
        begin
          UsedUnitName := ReadDottedIdent(HeaderStart, HeaderEnd);
          AppendStr(ResultObj.UsedUnits, UsedUnitName);
          if Cur.Lower = 'in' then
          begin
            Inc(Idx);
            if Cur.Kind = ttkString then
              Inc(Idx);
          end;
        end
        else
          Inc(Idx);
        if Cur.Text = ',' then
          Inc(Idx);
      end;
      if Cur.Text = ';' then
        Inc(Idx);
      Continue;
    end;

    if (Cur.Lower = 'initialization') or (Cur.Lower = 'finalization') or (Cur.Lower = 'begin') then
    begin
      // Skip module main/init block
      CurSection := dsNone;
      MainBlockDepth := 1;
      Inc(Idx);
      while (Cur.Kind <> ttkEof) and (MainBlockDepth > 0) do
      begin
        if (Cur.Lower = 'begin') or (Cur.Lower = 'try') or (Cur.Lower = 'case') or (Cur.Lower = 'asm') then
          Inc(MainBlockDepth)
        else if Cur.Lower = 'end' then
          Dec(MainBlockDepth);
        Inc(Idx);
      end;
      if Cur.Text = '.' then
        Break;
      Continue;
    end;

    if Cur.Lower = 'type' then
    begin
      CurSection := dsType;
      Inc(Idx);
      Continue;
    end;

    if (Cur.Lower = 'const') or (Cur.Lower = 'resourcestring') then
    begin
      CurSection := dsConst;
      Inc(Idx);
      Continue;
    end;

    if (Cur.Lower = 'var') or (Cur.Lower = 'threadvar') then
    begin
      CurSection := dsVar;
      Inc(Idx);
      Continue;
    end;

    if (Cur.Lower = 'generic') and
       ((Peek(1).Lower = 'function') or (Peek(1).Lower = 'procedure')) then
    begin
      CurSection := dsNone;
      Inc(Idx); // 'generic'
      ParseRoutineDeclaration(-1, '', 'generic');
      Continue;
    end;

    if (Cur.Lower = 'class') and
       ((Peek(1).Lower = 'function') or (Peek(1).Lower = 'procedure') or
        (Peek(1).Lower = 'constructor') or (Peek(1).Lower = 'destructor')) then
    begin
      CurSection := dsNone;
      Inc(Idx); // 'class'
      ParseRoutineDeclaration(-1, '', 'class');
      Continue;
    end;

    if (Cur.Lower = 'procedure') or (Cur.Lower = 'function') or
       (Cur.Lower = 'constructor') or (Cur.Lower = 'destructor') then
    begin
      CurSection := dsNone;
      ParseRoutineDeclaration(-1, '', '');
      Continue;
    end;

    if (Cur.Kind = ttkIdent) or (Cur.Lower = 'generic') then
    begin
      case CurSection of
        dsType:
          begin
            ParseTypeDeclaration;
            Continue;
          end;
        dsConst:
          begin
            ParseConstDeclaration;
            Continue;
          end;
        dsVar:
          begin
            ParseVarDeclaration;
            Continue;
          end;
        dsNone: ;
      else
        raise ENikError.CreateFmt('Unexpected TDeclSection ordinal: %d', [Ord(CurSection)]);
      end;
    end;

    Inc(Idx);
  end;

  Result := ResultObj;
end;

{ TNikSymbolIndex }

constructor TNikSymbolIndex.Create;
begin
  inherited Create;
  FFiles := TFPList.Create;
  FFileKeyHash := TFPHashList.Create;
  FSearchDirs := TStringList.Create;
  FUnitPathsPool := TStringList.Create;
  FUnitHash := TFPHashList.Create;
end;

destructor TNikSymbolIndex.Destroy;
begin
  Clear;
  FreeAndNil(FUnitHash);
  FreeAndNil(FUnitPathsPool);
  FreeAndNil(FSearchDirs);
  FreeAndNil(FFileKeyHash);
  FreeAndNil(FFiles);
  inherited Destroy;
end;

procedure TNikSymbolIndex.Clear;
var
  I: Integer;
begin
  for I := 0 to FFiles.Count - 1 do
    TObject(FFiles[I]).Free;
  FFiles.Clear;
  FFileKeyHash.Clear;
  FSearchDirs.Clear;
  FUnitPathsPool.Clear;
  FUnitHash.Clear;
end;

procedure TNikSymbolIndex.SetUnitMapEntry(const AUnitLower, AFullPath: string; AOverwrite: Boolean);
var
  ExistingIdx, NewIdx: PtrInt;
begin
  if (AUnitLower = '') or (AFullPath = '') then
    Exit;
  ExistingIdx := PtrInt(FUnitHash.Find(AUnitLower));
  if ExistingIdx > 0 then
  begin
    if AOverwrite then
      FUnitPathsPool[ExistingIdx - 1] := AFullPath;
    Exit;
  end;
  NewIdx := FUnitPathsPool.Add(AFullPath) + 1;
  FUnitHash.Add(AUnitLower, Pointer(NewIdx));
end;

function TNikSymbolIndex.GetUnitMapEntry(const AUnitLower: string): string;
var
  ExistingIdx: PtrInt;
begin
  if AUnitLower = '' then
    Exit('');
  ExistingIdx := PtrInt(FUnitHash.Find(AUnitLower));
  if (ExistingIdx > 0) and (ExistingIdx <= FUnitPathsPool.Count) then
    Result := FUnitPathsPool[ExistingIdx - 1]
  else
    Result := '';
end;

procedure TNikSymbolIndex.ScanDirectoryForUnits(const ADir: string; AMaxDepth: Integer);
var
  SR: TSearchRec;
  CleanDir, Ext, UnitLower, FullFile: string;
begin
  if (ADir = '') or (AMaxDepth < 0) or (not DirectoryExists(ADir)) then
    Exit;

  CleanDir := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(CleanDir + AllFilesMask, faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        FullFile := CleanDir + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
        begin
          if (SR.Name[1] <> '.') and (AMaxDepth > 0) then
            ScanDirectoryForUnits(FullFile, AMaxDepth - 1);
        end
        else
        begin
          Ext := LowerCase(ExtractFileExt(SR.Name));
          if (Ext = '.pas') or (Ext = '.pp') or (Ext = '.dpr') or (Ext = '.lpr') then
          begin
            UnitLower := LowerCase(ChangeFileExt(SR.Name, ''));
            SetUnitMapEntry(UnitLower, FullFile, False);
          end;
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

procedure TNikSymbolIndex.RebuildUnitFileMap;
var
  I: Integer;
begin
  FUnitPathsPool.Clear;
  FUnitHash.Clear;
  for I := 0 to FSearchDirs.Count - 1 do
    ScanDirectoryForUnits(FSearchDirs[I], 4);
end;

procedure TNikSymbolIndex.ConfigureSearchPaths(const AProjectUnitDirs: array of string;
  const ARtlSourceDir, APackagesSourceDir: string);
var
  I: Integer;
begin
  FSearchDirs.Clear;
  for I := Low(AProjectUnitDirs) to High(AProjectUnitDirs) do
    if (AProjectUnitDirs[I] <> '') and DirectoryExists(AProjectUnitDirs[I]) then
      FSearchDirs.Add(AProjectUnitDirs[I]);

  if (ARtlSourceDir <> '') and DirectoryExists(ARtlSourceDir) then
    FSearchDirs.Add(ARtlSourceDir);
  if (APackagesSourceDir <> '') and DirectoryExists(APackagesSourceDir) then
    FSearchDirs.Add(APackagesSourceDir);

  RebuildUnitFileMap;
end;

procedure TNikSymbolIndex.IndexProjectUnitDirs(const AProjectUnitDirs: array of string);
const
  MAX_EAGER_PROJECT_FILES = 400;
var
  I, EagerCount: Integer;
  SR: TSearchRec;
  CleanDir, Ext: string;
begin
  EagerCount := 0;
  for I := Low(AProjectUnitDirs) to High(AProjectUnitDirs) do
  begin
    if EagerCount >= MAX_EAGER_PROJECT_FILES then
      Break;
    if (AProjectUnitDirs[I] = '') or (not DirectoryExists(AProjectUnitDirs[I])) then
      Continue;
    CleanDir := IncludeTrailingPathDelimiter(AProjectUnitDirs[I]);
    if FindFirst(CleanDir + AllFilesMask, faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Attr and faDirectory) <> 0 then
            Continue;
          Ext := LowerCase(ExtractFileExt(SR.Name));
          if (Ext = '.pas') or (Ext = '.pp') or (Ext = '.lpr') or (Ext = '.dpr') then
          begin
            IndexDiskFile(CleanDir + SR.Name);
            Inc(EagerCount);
            if EagerCount >= MAX_EAGER_PROJECT_FILES then
              Break;
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
  end;
end;

function TNikSymbolIndex.FindIndexedByKey(const ANormalizedKey: string): Integer;
var
  FoundIdx: PtrInt;
begin
  if ANormalizedKey = '' then
    Exit(-1);
  FoundIdx := PtrInt(FFileKeyHash.Find(ANormalizedKey));
  if (FoundIdx > 0) and (FoundIdx <= FFiles.Count) then
    Result := Integer(FoundIdx - 1)
  else
    Result := -1;
end;

function TNikSymbolIndex.FindIndexedByUnitLower(const AUnitLower: string): TPasIndexedFile;
var
  I: Integer;
begin
  for I := 0 to FFiles.Count - 1 do
    if TPasIndexedFile(FFiles[I]).ModuleNameLower = AUnitLower then
      Exit(TPasIndexedFile(FFiles[I]));
  Result := nil;
end;

function TNikSymbolIndex.EnsureUnitIndexed(const AUnitName: string): TPasIndexedFile;
var
  ULower, DiskPath: string;
begin
  ULower := LowerCase(Trim(AUnitName));
  if ULower = '' then
    Exit(nil);
  Result := FindIndexedByUnitLower(ULower);
  if Result <> nil then
    Exit;

  DiskPath := GetUnitMapEntry(ULower);
  if (DiskPath <> '') and FileExists(DiskPath) then
    Result := IndexDiskFile(DiskPath);
end;

function TNikSymbolIndex.IndexText(const AUri, AFilePath, ASourceText: string): TPasIndexedFile;
var
  Parsed: TPasIndexedFile;
  ExistingIdx: Integer;
begin
  Parsed := ParsePascalSourceSymbols(AUri, AFilePath, ASourceText);
  ExistingIdx := FindIndexedByKey(Parsed.NormalizedKey);
  if ExistingIdx >= 0 then
  begin
    TObject(FFiles[ExistingIdx]).Free;
    FFiles[ExistingIdx] := Parsed;
  end
  else
  begin
    ExistingIdx := FFiles.Add(Parsed);
    FFileKeyHash.Add(Parsed.NormalizedKey, Pointer(PtrInt(ExistingIdx + 1)));
  end;

  if (Parsed.ModuleNameLower <> '') and (AFilePath <> '') then
    SetUnitMapEntry(Parsed.ModuleNameLower, AFilePath, True);

  Result := Parsed;
end;

function TNikSymbolIndex.IndexDiskFile(const AFilePath: string): TPasIndexedFile;
var
  FullPath, Uri, RawText: string;
  FS: TFileStream;
begin
  Result := nil;
  if (AFilePath = '') or (not FileExists(AFilePath)) then
    Exit;
  FullPath := ExpandFileName(AFilePath);
  Uri := FilePathToUri(FullPath);
  RawText := '';
  try
    FS := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(RawText, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(RawText[1], FS.Size);
    finally
      FS.Free;
    end;
    if (Length(RawText) >= 3) and
       (RawText[1] = #$EF) and (RawText[2] = #$BB) and (RawText[3] = #$BF) then
      Delete(RawText, 1, 3);
  except
    Exit(nil);
  end;
  Result := IndexText(Uri, FullPath, RawText);
end;

function TNikSymbolIndex.FindFileByUri(const AUri: string): TPasIndexedFile;
var
  Idx: Integer;
begin
  Idx := FindIndexedByKey(LowerCase(NormalizeDocumentUri(AUri)));
  if Idx >= 0 then
    Result := TPasIndexedFile(FFiles[Idx])
  else
    Result := nil;
end;

function TNikSymbolIndex.DoesFileUseUnit(const AUri, AUnitNameLower: string): Boolean;
var
  F: TPasIndexedFile;
  I: Integer;
begin
  Result := False;
  if AUnitNameLower = '' then
    Exit;
  F := FindFileByUri(AUri);
  if F = nil then
    Exit;
  for I := 0 to High(F.UsedUnits) do
    if LowerCase(F.UsedUnits[I]) = AUnitNameLower then
      Exit(True);
end;

function TNikSymbolIndex.BuildDocumentSymbols(const AUri: string): TLspDocumentSymbolArray;
var
  F: TPasIndexedFile;
  I: Integer;
begin
  Result := nil;
  F := FindFileByUri(AUri);
  if F = nil then
    Exit;

  SetLength(Result, Length(F.Symbols));
  for I := 0 to High(F.Symbols) do
  begin
    Result[I].ParentIndex := F.Symbols[I].ParentSymbolIndex;
    if (F.Symbols[I].ParentSymbolIndex < 0) and (F.Symbols[I].ContainerName <> '') then
      Result[I].Name := F.Symbols[I].ContainerName + '.' + F.Symbols[I].Name
    else
      Result[I].Name := F.Symbols[I].Name;
    Result[I].Detail := F.Symbols[I].Detail;
    Result[I].Kind := F.Symbols[I].Kind;
    Result[I].Range := F.Symbols[I].Range;
    Result[I].SelectionRange := F.Symbols[I].SelectionRange;
  end;
end;

function TNikSymbolIndex.SearchWorkspaceSymbols(const AQuery: string; AMaxResults: Integer): TLspSymbolInformationArray;
var
  QLower: string;
  I, J, Count: Integer;
  F: TPasIndexedFile;
begin
  Result := nil;
  QLower := LowerCase(Trim(AQuery));
  Count := 0;
  for I := 0 to FFiles.Count - 1 do
  begin
    F := TPasIndexedFile(FFiles[I]);
    for J := 0 to High(F.Symbols) do
    begin
      if (QLower = '') or (Pos(QLower, F.Symbols[J].NameLower) > 0) then
      begin
        SetLength(Result, Count + 1);
        Result[Count].Name := F.Symbols[J].Name;
        Result[Count].Kind := F.Symbols[J].Kind;
        Result[Count].Location := TLspLocation.Create(F.Uri, F.Symbols[J].SelectionRange);
        if F.Symbols[J].ContainerName <> '' then
          Result[Count].ContainerName := F.Symbols[J].ContainerName
        else
          Result[Count].ContainerName := F.ModuleName;
        Inc(Count);
        if Count >= AMaxResults then
          Exit;
      end;
    end;
  end;
end;

function TNikSymbolIndex.ResolveDefinitions(const AUri, AIdent: string): TLspLocationArray;
var
  TargetLower: string;
  CurFile, UsedFile, AnyFile: TPasIndexedFile;
  I, J, Count: Integer;

  procedure AddLoc(const ALocUri: string; const ARange: TLspRange);
  var
    K: Integer;
  begin
    for K := 0 to Count - 1 do
      if (Result[K].Uri = ALocUri) and
         (Result[K].Range.StartPos.Line = ARange.StartPos.Line) and
         (Result[K].Range.StartPos.Character = ARange.StartPos.Character) then
        Exit;
    SetLength(Result, Count + 1);
    Result[Count] := TLspLocation.Create(ALocUri, ARange);
    Inc(Count);
  end;

begin
  Result := nil;
  Count := 0;
  TargetLower := LowerCase(Trim(AIdent));
  if TargetLower = '' then
    Exit;

  CurFile := FindFileByUri(AUri);

  // 1. Symbols inside current file first (so local symbols are never shadowed by unrelated unit names)
  if CurFile <> nil then
  begin
    for J := 0 to High(CurFile.Symbols) do
      if (CurFile.Symbols[J].NameLower = TargetLower) and CurFile.Symbols[J].IsInterfaceSection then
        AddLoc(CurFile.Uri, CurFile.Symbols[J].SelectionRange);
    for J := 0 to High(CurFile.Symbols) do
      if CurFile.Symbols[J].NameLower = TargetLower then
        AddLoc(CurFile.Uri, CurFile.Symbols[J].SelectionRange);

    if Count > 0 then
      Exit;

    // 2. Direct unit jump when identifier names an imported unit in 'uses'
    for I := 0 to High(CurFile.UsedUnits) do
      if SameText(CurFile.UsedUnits[I], AIdent) then
      begin
        UsedFile := EnsureUnitIndexed(CurFile.UsedUnits[I]);
        if UsedFile <> nil then
        begin
          AddLoc(UsedFile.Uri, TLspRange.SingleLine(0, 0, 0));
          Exit;
        end;
      end;

    // 3. Interface symbols in units imported via 'uses'
    for I := 0 to High(CurFile.UsedUnits) do
    begin
      UsedFile := EnsureUnitIndexed(CurFile.UsedUnits[I]);
      if UsedFile <> nil then
      begin
        for J := 0 to High(UsedFile.Symbols) do
          if UsedFile.Symbols[J].IsInterfaceSection and (UsedFile.Symbols[J].NameLower = TargetLower) then
            AddLoc(UsedFile.Uri, UsedFile.Symbols[J].SelectionRange);
      end;
    end;
    if Count > 0 then
      Exit;
  end;

  // 4. Direct unit name jump fallback (e.g. dotted unit name or unindexed file)
  UsedFile := EnsureUnitIndexed(AIdent);
  if UsedFile <> nil then
  begin
    AddLoc(UsedFile.Uri, TLspRange.SingleLine(0, 0, 0));
    Exit;
  end;

  // 5. Fallback across already-indexed project units
  for I := 0 to FFiles.Count - 1 do
  begin
    AnyFile := TPasIndexedFile(FFiles[I]);
    for J := 0 to High(AnyFile.Symbols) do
      if AnyFile.Symbols[J].IsInterfaceSection and (AnyFile.Symbols[J].NameLower = TargetLower) then
        AddLoc(AnyFile.Uri, AnyFile.Symbols[J].SelectionRange);
  end;
end;

function TNikSymbolIndex.ResolveHover(const AUri, AIdent: string; const AWordRange: TLspRange): TLspHover;
var
  TargetLower, Md: string;
  CurFile, UsedFile: TPasIndexedFile;
  I, J: Integer;

  function BuildHoverFromSym(AFile: TPasIndexedFile; const ASym: TPasUnitSymbol): TLspHover;
  begin
    Result := Default(TLspHover);
    Result.HasValue := True;
    Result.HasRange := True;
    Result.Range := AWordRange;
    Md := '```pascal' + #10 + ASym.Signature + #10 + '```';
    if ASym.DocComment <> '' then
      Md := Md + #10#10 + ASym.DocComment;
    if AFile.ModuleName <> '' then
      Md := Md + #10#10 + '*Unit `' + AFile.ModuleName + '`*';
    Result.Markdown := Md;
  end;

begin
  Result := Default(TLspHover);
  TargetLower := LowerCase(Trim(AIdent));
  if TargetLower = '' then
    Exit;

  CurFile := FindFileByUri(AUri);
  if CurFile <> nil then
  begin
    for J := 0 to High(CurFile.Symbols) do
      if CurFile.Symbols[J].NameLower = TargetLower then
        Exit(BuildHoverFromSym(CurFile, CurFile.Symbols[J]));

    for I := 0 to High(CurFile.UsedUnits) do
    begin
      UsedFile := EnsureUnitIndexed(CurFile.UsedUnits[I]);
      if UsedFile <> nil then
      begin
        for J := 0 to High(UsedFile.Symbols) do
          if UsedFile.Symbols[J].IsInterfaceSection and (UsedFile.Symbols[J].NameLower = TargetLower) then
            Exit(BuildHoverFromSym(UsedFile, UsedFile.Symbols[J]));
      end;
    end;
  end;

  UsedFile := EnsureUnitIndexed(AIdent);
  if UsedFile <> nil then
  begin
    Result.HasValue := True;
    Result.HasRange := True;
    Result.Range := AWordRange;
    Result.Markdown := '```pascal' + #10 + 'unit ' + UsedFile.ModuleName + ';' + #10 + '```' +
      #10#10 + '`' + UsedFile.FilePath + '`';
  end;
end;

function TNikSymbolIndex.ResolveCompletions(const AUri, ALinePrefix: string): TLspCompletionList;
const
  PASCAL_KEYWORDS: array[0..29] of string = (
    'begin', 'end', 'procedure', 'function', 'constructor', 'destructor',
    'class', 'record', 'interface', 'implementation', 'uses', 'type', 'const',
    'var', 'property', 'try', 'finally', 'except', 'raise', 'if', 'then',
    'else', 'case', 'of', 'for', 'while', 'repeat', 'until', 'Result', 'Exit'
  );
var
  Seen: TStringList;
  Count, I, J, DotPos: Integer;
  TrimPrefix, ReceiverLower: string;
  CurFile, UsedFile: TPasIndexedFile;

  procedure AddItem(const ALabel: string; AKind: TLspCompletionItemKind;
    const ADetail, ADoc, ASortPrefix: string);
  var
    Key: string;
    Idx: Integer;
  begin
    if ALabel = '' then
      Exit;
    Key := LowerCase(ALabel);
    if Seen.Find(Key, Idx) then
      Exit;
    Seen.Add(Key);

    SetLength(Result.Items, Count + 1);
    Result.Items[Count] := Default(TLspCompletionItem);
    Result.Items[Count].LabelText := ALabel;
    Result.Items[Count].Kind := AKind;
    Result.Items[Count].Detail := ADetail;
    Result.Items[Count].DocumentationMarkdown := ADoc;
    Result.Items[Count].SortText := ASortPrefix + ALabel;
    Inc(Count);
  end;

  procedure AddContainerMembers(AFile: TPasIndexedFile; const AContainerLower: string; AOnlyInterface: Boolean);
  var
    K: Integer;
  begin
    if AFile = nil then
      Exit;
    for K := 0 to High(AFile.Symbols) do
    begin
      if AOnlyInterface and (not AFile.Symbols[K].IsInterfaceSection) then
        Continue;
      if LowerCase(AFile.Symbols[K].ContainerName) = AContainerLower then
        AddItem(AFile.Symbols[K].Name, AFile.Symbols[K].CompletionKind,
          AFile.Symbols[K].Signature, AFile.Symbols[K].DocComment, '0_');
    end;
  end;

begin
  Result := Default(TLspCompletionList);
  Result.IsIncomplete := False;
  Count := 0;

  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;

    CurFile := FindFileByUri(AUri);
    TrimPrefix := TrimRight(ALinePrefix);

    // Qualified completion after 'UnitOrType.'
    DotPos := Length(TrimPrefix);
    while (DotPos >= 1) and IsIdentCont(TrimPrefix[DotPos]) do
      Dec(DotPos);

    if (DotPos >= 2) and (TrimPrefix[DotPos] = '.') then
    begin
      I := DotPos - 1;
      while (I >= 1) and (IsIdentCont(TrimPrefix[I]) or (TrimPrefix[I] = '.')) do
        Dec(I);
      ReceiverLower := LowerCase(Copy(TrimPrefix, I + 1, DotPos - I - 1));
      if ReceiverLower <> '' then
      begin
        UsedFile := nil;
        if (CurFile <> nil) and (CurFile.ModuleNameLower = ReceiverLower) then
          UsedFile := CurFile
        else if DoesFileUseUnit(AUri, ReceiverLower) then
          UsedFile := EnsureUnitIndexed(ReceiverLower);

        if UsedFile <> nil then
        begin
          for J := 0 to High(UsedFile.Symbols) do
            if ((UsedFile = CurFile) or UsedFile.Symbols[J].IsInterfaceSection) and
               (UsedFile.Symbols[J].ParentSymbolIndex < 0) then
              AddItem(UsedFile.Symbols[J].Name, UsedFile.Symbols[J].CompletionKind,
                UsedFile.Symbols[J].Signature, UsedFile.Symbols[J].DocComment, '0_');
          if Count > 0 then
            Exit;
        end;

        AddContainerMembers(CurFile, ReceiverLower, False);
        if CurFile <> nil then
          for I := 0 to High(CurFile.UsedUnits) do
            AddContainerMembers(EnsureUnitIndexed(CurFile.UsedUnits[I]), ReceiverLower, True);
        if Count > 0 then
          Exit;
      end;
    end;

    // Unqualified scope completion: current file symbols + imported interface symbols + keywords
    if CurFile <> nil then
    begin
      for J := 0 to High(CurFile.Symbols) do
        if CurFile.Symbols[J].ParentSymbolIndex < 0 then
          AddItem(CurFile.Symbols[J].Name, CurFile.Symbols[J].CompletionKind,
            CurFile.Symbols[J].Signature, CurFile.Symbols[J].DocComment, '1_');

      for I := 0 to High(CurFile.UsedUnits) do
      begin
        UsedFile := EnsureUnitIndexed(CurFile.UsedUnits[I]);
        if UsedFile <> nil then
        begin
          for J := 0 to High(UsedFile.Symbols) do
          begin
            if UsedFile.Symbols[J].IsInterfaceSection and (UsedFile.Symbols[J].ParentSymbolIndex < 0) then
              AddItem(UsedFile.Symbols[J].Name, UsedFile.Symbols[J].CompletionKind,
                UsedFile.Symbols[J].Signature, UsedFile.Symbols[J].DocComment, '2_');
            if Count >= 250 then
              Break;
          end;
        end;
        if Count >= 250 then
          Break;
      end;
    end;

    for I := Low(PASCAL_KEYWORDS) to High(PASCAL_KEYWORDS) do
      AddItem(PASCAL_KEYWORDS[I], lcikKeyword, 'keyword', '', '9_');
  finally
    Seen.Free;
  end;
end;

function TNikSymbolIndex.ResolveSignatureHelp(const AUri, ACalleeIdent: string; AActiveParam: Integer): TLspSignatureHelp;
var
  TargetLower: string;
  CurFile, UsedFile: TPasIndexedFile;
  I, J, K, SigCount: Integer;

  procedure AddSig(const ASym: TPasUnitSymbol);
  var
    PIdx: Integer;
  begin
    if (ASym.Kind <> lskFunction) and (ASym.Kind <> lskMethod) and (ASym.Kind <> lskConstructor) then
      Exit;
    SetLength(Result.Signatures, SigCount + 1);
    Result.Signatures[SigCount].LabelText := ASym.Signature;
    Result.Signatures[SigCount].DocumentationMarkdown := ASym.DocComment;
    SetLength(Result.Signatures[SigCount].Parameters, Length(ASym.Params));
    for PIdx := 0 to High(ASym.Params) do
    begin
      Result.Signatures[SigCount].Parameters[PIdx].LabelText := ASym.Params[PIdx];
      Result.Signatures[SigCount].Parameters[PIdx].DocumentationMarkdown := '';
    end;
    Inc(SigCount);
  end;

begin
  Result := Default(TLspSignatureHelp);
  Result.ActiveSignature := 0;
  if AActiveParam >= 0 then
    Result.ActiveParameter := AActiveParam
  else
    Result.ActiveParameter := 0;

  TargetLower := LowerCase(Trim(ACalleeIdent));
  if TargetLower = '' then
    Exit;

  SigCount := 0;
  CurFile := FindFileByUri(AUri);
  if CurFile <> nil then
  begin
    for J := 0 to High(CurFile.Symbols) do
      if CurFile.Symbols[J].NameLower = TargetLower then
        AddSig(CurFile.Symbols[J]);

    for I := 0 to High(CurFile.UsedUnits) do
    begin
      UsedFile := EnsureUnitIndexed(CurFile.UsedUnits[I]);
      if UsedFile <> nil then
        for K := 0 to High(UsedFile.Symbols) do
          if UsedFile.Symbols[K].IsInterfaceSection and (UsedFile.Symbols[K].NameLower = TargetLower) then
            AddSig(UsedFile.Symbols[K]);
    end;
  end;
end;

end.
