unit nik.lsp.index;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Contnrs,
  nik.lsp.check,
  nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.utf16, nikrun.lsp.documents;

type
  TPasWorkspaceSymbolEntry = record
    Name: string;
    NameLower: string;
    ContainerName: string;
    Kind: TLspSymbolKind;
    SelectionRange: TLspRange;
  end;
  TPasWorkspaceSymbolArray = array of TPasWorkspaceSymbolEntry;

  TPasIndexedFile = class
  public
    Uri: string;
    NormalizedKey: string;
    FilePath: string;
    ModuleName: string;
    ModuleNameLower: string;
    UsedUnits: TLspStringArray;
    Symbols: TPasWorkspaceSymbolArray;
  end;

  TNikSymbolIndex = class
  private
    FFiles: TFPList;           // Owns TPasIndexedFile (workspace symbol & uses cache)
    FFileKeyHash: TFPHashList; // O(1) NormalizedKey -> Pointer(PtrInt(FileIndex + 1))
    FCodeToolsReady: Boolean;

    procedure EnsureCodeToolsBaseInitialized;
    procedure HandleCodeCacheDecodeLoaded(ACode: TObject; const AFilename: string;
      var ASource, ADiskEncoding, AMemEncoding: string);
    procedure ApplyWorkspaceDefineTemplates(const ADirs, AUnitPaths, AIncludePaths,
      ADefines, AUndefines: array of string);
    function FindIndexedByKey(const ANormalizedKey: string): Integer;
    procedure StoreIndexedFile(AParsed: TPasIndexedFile);
    procedure RemoveIndexedByKey(const ANormalizedKey: string);
    procedure IndexProjectDirectories(const AProjectUnitDirs: array of string);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    procedure ConfigureWorkspace(const AContext: TNikWorkspaceContext;
      AWorkspaceReady: Boolean; const AFallbackRootDir: string);

    function SyncOpenDocument(const AUri, AFilePath, ASourceText: string): TPasIndexedFile;
    procedure CloseOpenDocument(const AUri, AFilePath: string);
    function RefreshDiskFile(const AFilePath: string): TPasIndexedFile;

    function FindFileByUri(const AUri: string): TPasIndexedFile;
    function DoesFileUseUnit(const AUri, AFilePath, AUnitNameLower: string): Boolean;

    function BuildDocumentSymbols(const AUri, AFilePath: string): TLspDocumentSymbolArray;
    function SearchWorkspaceSymbols(const AQuery: string; AMaxResults: Integer = 100): TLspSymbolInformationArray;
    function ResolveDefinitions(const AUri, AFilePath: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspLocationArray;
    function ResolveDeclarations(const AUri, AFilePath: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspLocationArray;
    function ResolveHover(const AUri, AFilePath: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspHover;
    function ResolveCompletions(const AUri, AFilePath: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspCompletionList;
    function ResolveSignatureHelp(const AUri, AFilePath: string; ADoc: TLspDocument;
      const APos: TLspPosition): TLspSignatureHelp;
  end;

implementation

uses
  LazLoggerBase,
  CodeToolManager, CodeToolsConfig, CodeCache, CodeTree, CustomCodeTool,
  PascalParserTool, PascalReaderTool, FindDeclarationTool, IdentCompletionTool,
  DefineTemplates, BasicCodeTools, LinkScanner, SourceChanger,
  nik.types, nik.paths, nik.fs, nik.sdk.manager;

const
  NIK_WORKSPACE_TEMPLATE_NAME = 'NikrunWorkspace';

var
  GLoggerSilenced: Boolean = False;

procedure SilenceCodeToolsLogger;
begin
  if not GLoggerSilenced then
  begin
    SetDebugLogger(TLazLoggerNoOutput.Create);
    GLoggerSilenced := True;
  end;
end;

function QuoteFpcOptIfNeeded(const AOpt: string): string;
begin
  if Pos(' ', AOpt) > 0 then
    Result := '"' + AOpt + '"'
  else
    Result := AOpt;
end;

procedure AppendUniqueStr(var AArr: TLspStringArray; const AVal: string);
var
  I, N: Integer;
begin
  if Trim(AVal) = '' then
    Exit;
  for I := 0 to High(AArr) do
    if SameText(AArr[I], AVal) then
      Exit;
  N := Length(AArr);
  SetLength(AArr, N + 1);
  AArr[N] := AVal;
end;

procedure AppendUniqueNativePath(var APaths: TStringArray; const APath: string);
var
  Clean: string;
  I, N: Integer;
begin
  Clean := ExcludeTrailingPathDelimiter(Trim(APath));
  if Clean = '' then
    Exit;
  Clean := ExpandFileName(NormalizeNativeSeparators(Clean));
  for I := 0 to High(APaths) do
  begin
    {$IFDEF WINDOWS}
    if SameText(APaths[I], Clean) then
      Exit;
    {$ELSE}
    if APaths[I] = Clean then
      Exit;
    {$ENDIF}
  end;
  N := Length(APaths);
  SetLength(APaths, N + 1);
  APaths[N] := Clean;
end;

function JoinSemicolonPaths(const APaths: array of string): string;
var
  I: Integer;
  P: string;
begin
  Result := '';
  for I := Low(APaths) to High(APaths) do
  begin
    P := ExcludeTrailingPathDelimiter(Trim(APaths[I]));
    if P = '' then
      Continue;
    if Result <> '' then
      Result := Result + ';';
    Result := Result + P;
  end;
end;

function IsIdentByte(ACh: Char): Boolean; inline;
begin
  Result :=
    ((ACh >= 'A') and (ACh <= 'Z')) or
    ((ACh >= 'a') and (ACh <= 'z')) or
    ((ACh >= '0') and (ACh <= '9')) or
    (ACh = '_');
end;

function IsPosBefore(const A, B: TLspPosition): Boolean; inline;
begin
  Result := (A.Line < B.Line) or ((A.Line = B.Line) and (A.Character < B.Character));
end;

procedure NormalizeContainingRange(const ASelRange: TLspRange; var AFullRange: TLspRange);
begin
  if IsPosBefore(AFullRange.EndPos, AFullRange.StartPos) then
    AFullRange.EndPos := AFullRange.StartPos;
  if IsPosBefore(ASelRange.StartPos, AFullRange.StartPos) then
    AFullRange.StartPos := ASelRange.StartPos;
  if IsPosBefore(AFullRange.EndPos, ASelRange.EndPos) then
    AFullRange.EndPos := ASelRange.EndPos;
end;

function ObtainCodeBuffer(const AFilePath: string; ALoadFromDisk: Boolean): TCodeBuffer;
var
  ExpPath: string;
begin
  Result := nil;
  if Trim(AFilePath) = '' then
    Exit;

  ExpPath := ExpandFileName(NormalizeNativeSeparators(AFilePath));
  Result := CodeToolBoss.FindFile(ExpPath);
  if (Result <> nil) and (not Result.IsDeleted) then
    Exit;

  if ALoadFromDisk and FileExists(ExpPath) then
    Result := CodeToolBoss.LoadFile(ExpPath, False, False)
  else if not ALoadFromDisk then
  begin
    Result := CodeToolBoss.CreateFile(ExpPath);
    if Result <> nil then
      Result.IsDeleted := False;
  end;
end;

function LspPosToCodeXY(ABuf: TCodeBuffer; ADoc: TLspDocument;
  const APos: TLspPosition; out AX, AY: Integer): Boolean;
var
  Line0: Integer;
  LineStr: string;
begin
  AX := 1;
  AY := 1;
  if ABuf = nil then
    Exit(False);

  Line0 := APos.Line;
  if Line0 < 0 then
    Line0 := 0;

  if ADoc <> nil then
    LineStr := ADoc.GetLineText(Line0)
  else if (Line0 >= 0) and (Line0 < ABuf.LineCount) then
    LineStr := ABuf.GetLine(Line0, False)
  else
    LineStr := '';

  AY := Line0 + 1;
  if (ABuf.LineCount > 0) and (AY > ABuf.LineCount) then
    AY := ABuf.LineCount;

  AX := Utf16ColToByteIndex(LineStr, APos.Character);
  if AX < 1 then
    AX := 1;
  Result := True;
end;

function CodeXYIdentifierRange(ABuf: TCodeBuffer; AX, AY: Integer): TLspRange;
var
  Line0, StartByte, EndByte, Len: Integer;
  LineStr: string;
begin
  if (ABuf = nil) or (AY < 1) then
    Exit(TLspRange.SingleLine(0, 0, 0));

  Line0 := AY - 1;
  if Line0 < ABuf.LineCount then
    LineStr := ABuf.GetLine(Line0, False)
  else
    LineStr := '';

  Len := Length(LineStr);
  StartByte := AX;
  if StartByte < 1 then
    StartByte := 1;
  if StartByte > Len + 1 then
    StartByte := Len + 1;

  // Skip leading '&' on escaped Pascal identifiers
  if (StartByte <= Len) and (LineStr[StartByte] = '&') and
     (StartByte + 1 <= Len) and IsIdentByte(LineStr[StartByte + 1]) then
    EndByte := StartByte + 1
  else
    EndByte := StartByte;

  while (EndByte <= Len) and IsIdentByte(LineStr[EndByte]) do
    Inc(EndByte);

  Result := TLspRange.SingleLine(
    Line0,
    ByteIndexToUtf16Col(LineStr, StartByte),
    ByteIndexToUtf16Col(LineStr, EndByte)
  );
end;

function CleanPosSpanToLspRange(ATool: TCodeTool; ABuf: TCodeBuffer;
  AStartCleanPos, AEndCleanPos: Integer; out ARange: TLspRange): Boolean;
var
  StartCaret, EndCaret: TCodeXYPosition;
  StartLineStr, EndLineStr: string;
  EndPosAdj: Integer;
begin
  ARange := TLspRange.SingleLine(0, 0, 0);
  if (ATool = nil) or (ABuf = nil) or (AStartCleanPos < 1) then
    Exit(False);

  if not ATool.CleanPosToCaret(AStartCleanPos, StartCaret) then
    Exit(False);
  if StartCaret.Code <> ABuf then
    Exit(False);

  EndPosAdj := AEndCleanPos;
  if EndPosAdj < AStartCleanPos then
    EndPosAdj := AStartCleanPos;

  if (not ATool.CleanPosToCaret(EndPosAdj, EndCaret)) or (EndCaret.Code <> ABuf) then
    EndCaret := StartCaret;

  if (StartCaret.Y >= 1) and (StartCaret.Y - 1 < ABuf.LineCount) then
    StartLineStr := ABuf.GetLine(StartCaret.Y - 1, False)
  else
    StartLineStr := '';

  if (EndCaret.Y >= 1) and (EndCaret.Y - 1 < ABuf.LineCount) then
    EndLineStr := ABuf.GetLine(EndCaret.Y - 1, False)
  else
    EndLineStr := '';

  ARange := TLspRange.Create(
    TLspPosition.Create(StartCaret.Y - 1, ByteIndexToUtf16Col(StartLineStr, StartCaret.X)),
    TLspPosition.Create(EndCaret.Y - 1, ByteIndexToUtf16Col(EndLineStr, EndCaret.X))
  );
  Result := True;
end;

function CleanCommentBody(const ARawComment: string): string;
var
  Body, L: string;
  Lines: TStringList;
  I: Integer;
begin
  Result := '';
  Body := Trim(ARawComment);
  if Body = '' then
    Exit;

  if (Length(Body) >= 2) and (Body[1] = '/') and (Body[2] = '/') then
  begin
    if (Length(Body) >= 3) and (Body[3] = '/') then
      Body := Copy(Body, 4, MaxInt)
    else
      Body := Copy(Body, 3, MaxInt);
    Exit(Trim(Body));
  end;

  if Body[1] = '{' then
  begin
    if (Length(Body) >= 2) and (Body[2] = '$') then
      Exit('');
    if Body[Length(Body)] = '}' then
      Body := Copy(Body, 2, Length(Body) - 2)
    else
      Body := Copy(Body, 2, MaxInt);
  end
  else if (Length(Body) >= 2) and (Body[1] = '(') and (Body[2] = '*') then
  begin
    if (Length(Body) >= 3) and (Body[3] = '$') then
      Exit('');
    if (Length(Body) >= 4) and (Body[Length(Body) - 1] = '*') and (Body[Length(Body)] = ')') then
      Body := Copy(Body, 3, Length(Body) - 4)
    else
      Body := Copy(Body, 3, MaxInt);
  end;

  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Body);
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

function ExtractPasDocForCodeXY(ABuf: TCodeBuffer; AX, AY: Integer): string;
var
  CommentPosList: TFPList;
  I, StartPos, EndPos: Integer;
  PosItem: PCodeXYPosition;
  CBuf: TCodeBuffer;
  NestedComments: Boolean;
  RawPiece, CleanPiece: string;
begin
  Result := '';
  if (ABuf = nil) or (AX < 1) or (AY < 1) then
    Exit;

  CommentPosList := nil;
  try
    if not CodeToolBoss.GetPasDocComments(ABuf, AX, AY, CommentPosList) then
      Exit;
    if (CommentPosList = nil) or (CommentPosList.Count = 0) then
      Exit;

    NestedComments := CodeToolBoss.GetNestedCommentsFlagForFile(ABuf.Filename);
    for I := 0 to CommentPosList.Count - 1 do
    begin
      PosItem := PCodeXYPosition(CommentPosList[I]);
      if (PosItem = nil) or (PosItem^.Code = nil) then
        Continue;
      CBuf := PosItem^.Code;
      CBuf.LineColToPosition(PosItem^.Y, PosItem^.X, StartPos);
      if (StartPos < 1) or (StartPos > CBuf.SourceLength) then
        Continue;
      EndPos := FindCommentEnd(CBuf.Source, StartPos, NestedComments);
      RawPiece := Copy(CBuf.Source, StartPos, EndPos - StartPos);
      CleanPiece := CleanCommentBody(RawPiece);
      if CleanPiece <> '' then
      begin
        if Result <> '' then
          Result := Result + #10;
        Result := Result + CleanPiece;
      end;
    end;
  finally
    if CommentPosList <> nil then
      CodeToolBoss.FreeListOfPCodeXYPosition(CommentPosList);
  end;
end;

procedure SplitParameterStrings(const AParamsText: string; out AParams: TLspStringArray);
var
  I, ParenDepth, StartIdx: Integer;
  Ch: Char;
  InQuote: Boolean;
  Piece: string;
begin
  AParams := nil;
  if Trim(AParamsText) = '' then
    Exit;

  ParenDepth := 0;
  InQuote := False;
  StartIdx := 1;
  for I := 1 to Length(AParamsText) do
  begin
    Ch := AParamsText[I];
    if Ch = '''' then
      InQuote := not InQuote
    else if not InQuote then
    begin
      if (Ch = '(') or (Ch = '[') or (Ch = '<') then
        Inc(ParenDepth)
      else if (Ch = ')') or (Ch = ']') or (Ch = '>') then
      begin
        if ParenDepth > 0 then
          Dec(ParenDepth);
      end
      else if (ParenDepth = 0) and (Ch = ';') then
      begin
        Piece := Trim(Copy(AParamsText, StartIdx, I - StartIdx));
        if Piece <> '' then
        begin
          SetLength(AParams, Length(AParams) + 1);
          AParams[High(AParams)] := Piece;
        end;
        StartIdx := I + 1;
      end;
    end;
  end;

  Piece := Trim(Copy(AParamsText, StartIdx, MaxInt));
  if Piece <> '' then
  begin
    SetLength(AParams, Length(AParams) + 1);
    AParams[High(AParams)] := Piece;
  end;
end;

procedure ExtractDocumentSymbolsFromBuffer(ABuf: TCodeBuffer;
  out ADocSymbols: TLspDocumentSymbolArray;
  out AWorkspaceSymbols: TPasWorkspaceSymbolArray;
  out AModuleName: string;
  out AUsedUnits: TLspStringArray);
var
  Tool: TCodeTool;
  DocSymCount, WsSymCount: Integer;
  MainUses, ImplUses: TStrings;
  UIdx: Integer;

  function PushDocAndWsSymbol(const AName, AContainer, ADetail: string;
    AKind: TLspSymbolKind; AParentIdx: Integer;
    const ASelRange: TLspRange; AFullRange: TLspRange): Integer;
  begin
    if Trim(AName) = '' then
      Exit(-1);
    NormalizeContainingRange(ASelRange, AFullRange);

    Result := DocSymCount;
    Inc(DocSymCount);
    SetLength(ADocSymbols, DocSymCount);
    ADocSymbols[Result].ParentIndex := AParentIdx;
    ADocSymbols[Result].Name := AName;
    ADocSymbols[Result].Detail := ADetail;
    ADocSymbols[Result].Kind := AKind;
    ADocSymbols[Result].Range := AFullRange;
    ADocSymbols[Result].SelectionRange := ASelRange;

    Inc(WsSymCount);
    SetLength(AWorkspaceSymbols, WsSymCount);
    AWorkspaceSymbols[WsSymCount - 1].Name := AName;
    AWorkspaceSymbols[WsSymCount - 1].NameLower := LowerCase(AName);
    AWorkspaceSymbols[WsSymCount - 1].ContainerName := AContainer;
    AWorkspaceSymbols[WsSymCount - 1].Kind := AKind;
    AWorkspaceSymbols[WsSymCount - 1].SelectionRange := ASelRange;
  end;

  function NodeNameSelRange(ANode: TCodeTreeNode; ACleanNamePos: Integer): TLspRange;
  var
    Caret: TCodeXYPosition;
  begin
    if (ACleanNamePos < 1) and (ANode <> nil) then
      ACleanNamePos := ANode.StartPos;
    if Tool.CleanPosToCaret(ACleanNamePos, Caret) and (Caret.Code = ABuf) then
      Result := CodeXYIdentifierRange(ABuf, Caret.X, Caret.Y)
    else
      Result := TLspRange.SingleLine(0, 0, 0);
  end;

  procedure WalkNodeList(AFirstNode: TCodeTreeNode; AParentIdx: Integer;
    const AContainerName: string; AInsideStructuredType: Boolean); forward;

  procedure HandleTypeDefNode(ATypeDefNode: TCodeTreeNode; AParentIdx: Integer;
    const AContainerName: string);
  var
    TypeName, DetailStr: string;
    SubNode, MemberChild: TCodeTreeNode;
    FullRange, SelRange: TLspRange;
    SymKind: TLspSymbolKind;
    StructIdx, NamePos: Integer;
    NameNode: TCodeTreeNode;
  begin
    if not CleanPosSpanToLspRange(Tool, ABuf, ATypeDefNode.StartPos, ATypeDefNode.EndPos, FullRange) then
      Exit;

    TypeName := Trim(Tool.ExtractDefinitionName(ATypeDefNode));
    if TypeName = '' then
      Exit;

    NameNode := Tool.FindDefinitionNameNode(ATypeDefNode);
    if NameNode <> nil then
      NamePos := NameNode.StartPos
    else
      NamePos := ATypeDefNode.StartPos;
    SelRange := NodeNameSelRange(ATypeDefNode, NamePos);

    SubNode := ATypeDefNode.FirstChild;
    while (SubNode <> nil) and
          ((SubNode.Desc = ctnGenericName) or (SubNode.Desc = ctnGenericParams) or
           (SubNode.Desc = ctnAttribute)) do
      SubNode := SubNode.NextBrother;

    if SubNode = nil then
    begin
      PushDocAndWsSymbol(TypeName, AContainerName, 'type', lskClass, AParentIdx, SelRange, FullRange);
      Exit;
    end;

    case SubNode.Desc of
      ctnClass, ctnObject, ctnObjCClass, ctnCPPClass,
      ctnClassHelper, ctnRecordHelper, ctnTypeHelper,
      ctnRecordType, ctnClassInterface, ctnDispinterface, ctnObjCProtocol:
        begin
          if (SubNode.SubDesc and ctnsForwardDeclaration) <> 0 then
          begin
            PushDocAndWsSymbol(TypeName, AContainerName, 'forward', lskClass, AParentIdx, SelRange, FullRange);
            Exit;
          end;

          case SubNode.Desc of
            ctnRecordType:
              begin
                SymKind := lskStruct;
                DetailStr := 'record';
              end;
            ctnClassInterface, ctnDispinterface, ctnObjCProtocol:
              begin
                SymKind := lskInterface;
                DetailStr := 'interface';
              end;
          else
            begin
              SymKind := lskClass;
              DetailStr := 'class';
            end;
          end;

          StructIdx := PushDocAndWsSymbol(TypeName, AContainerName, DetailStr, SymKind,
            AParentIdx, SelRange, FullRange);
          if StructIdx >= 0 then
            WalkNodeList(SubNode.FirstChild, StructIdx, TypeName, True);
        end;

      ctnEnumerationType:
        begin
          StructIdx := PushDocAndWsSymbol(TypeName, AContainerName, 'enum', lskEnum,
            AParentIdx, SelRange, FullRange);
          if StructIdx >= 0 then
          begin
            MemberChild := SubNode.FirstChild;
            while MemberChild <> nil do
            begin
              if MemberChild.Desc = ctnEnumIdentifier then
              begin
                if CleanPosSpanToLspRange(Tool, ABuf, MemberChild.StartPos, MemberChild.EndPos, FullRange) then
                begin
                  SelRange := NodeNameSelRange(MemberChild, MemberChild.StartPos);
                  PushDocAndWsSymbol(
                    GetIdentifier(@Tool.Src[MemberChild.StartPos]),
                    TypeName, TypeName, lskEnumMember, StructIdx, SelRange, FullRange
                  );
                end;
              end;
              MemberChild := MemberChild.NextBrother;
            end;
          end;
        end;
    else
      begin
        DetailStr := Trim(Tool.ExtractDefinitionNodeType(ATypeDefNode));
        if DetailStr = '' then
          DetailStr := 'type';
        PushDocAndWsSymbol(TypeName, AContainerName, DetailStr, lskClass, AParentIdx, SelRange, FullRange);
      end;
    end;
  end;

  procedure HandleProcNode(AProcNode: TCodeTreeNode; AParentIdx: Integer;
    const AContainerName: string; AInsideStructuredType: Boolean);
  var
    ProcName, RetType, OwnerClass: string;
    FullRange, SelRange: TLspRange;
    HeadEndPos, NameCleanPos: Integer;
    SymKind: TLspSymbolKind;
  begin
    if AProcNode.FirstChild <> nil then
      HeadEndPos := AProcNode.FirstChild.EndPos
    else
      HeadEndPos := AProcNode.EndPos;

    if not CleanPosSpanToLspRange(Tool, ABuf, AProcNode.StartPos, AProcNode.EndPos, FullRange) then
      if not CleanPosSpanToLspRange(Tool, ABuf, AProcNode.StartPos, HeadEndPos, FullRange) then
        Exit;

    if AInsideStructuredType then
    begin
      ProcName := Trim(Tool.ExtractProcName(AProcNode, [phpWithoutClassName]));
      OwnerClass := AContainerName;
    end
    else
    begin
      ProcName := Trim(Tool.ExtractProcName(AProcNode, []));
      OwnerClass := Trim(Tool.ExtractClassNameOfProcNode(AProcNode, True, False));
    end;

    if ProcName = '' then
      Exit;

    Tool.MoveCursorToProcName(AProcNode, AInsideStructuredType);
    NameCleanPos := Tool.CurPos.StartPos;
    SelRange := NodeNameSelRange(AProcNode, NameCleanPos);

    RetType := Trim(Tool.ExtractFuncResultType(AProcNode, [phpWithoutSemicolon]));
    if (Length(RetType) > 0) and (RetType[1] = ':') then
      RetType := Trim(Copy(RetType, 2, MaxInt));

    if Tool.NodeIsConstructor(AProcNode) then
      SymKind := lskConstructor
    else if AInsideStructuredType or (OwnerClass <> '') then
      SymKind := lskMethod
    else
      SymKind := lskFunction;

    PushDocAndWsSymbol(ProcName, OwnerClass, RetType, SymKind, AParentIdx, SelRange, FullRange);
  end;

  procedure WalkNodeList(AFirstNode: TCodeTreeNode; AParentIdx: Integer;
    const AContainerName: string; AInsideStructuredType: Boolean);
  var
    Node: TCodeTreeNode;
    FullRange, SelRange: TLspRange;
    SymName, SymDetail: string;
    SymKind: TLspSymbolKind;
    NameNode: TCodeTreeNode;
    NamePos: Integer;
  begin
    Node := AFirstNode;
    while Node <> nil do
    begin
      case Node.Desc of
        ctnProgram, ctnUnit, ctnLibrary, ctnPackage,
        ctnInterface, ctnImplementation,
        ctnTypeSection, ctnVarSection, ctnConstSection, ctnResStrSection,
        ctnPropertySection,
        ctnClassPrivate, ctnClassProtected, ctnClassPublic, ctnClassPublished,
        ctnClassRequired, ctnClassOptional, ctnClassClassVar,
        ctnRecordCase, ctnRecordVariant:
          WalkNodeList(Node.FirstChild, AParentIdx, AContainerName, AInsideStructuredType);

        ctnTypeDefinition, ctnGenericType:
          HandleTypeDefNode(Node, AParentIdx, AContainerName);

        ctnProcedure:
          HandleProcNode(Node, AParentIdx, AContainerName, AInsideStructuredType);

        ctnProperty, ctnGlobalProperty:
          begin
            if CleanPosSpanToLspRange(Tool, ABuf, Node.StartPos, Node.EndPos, FullRange) then
            begin
              SymName := Trim(Tool.ExtractPropName(Node, False));
              SymDetail := Trim(Tool.ExtractPropType(Node, False, False));
              if Tool.MoveCursorToPropName(Node) then
                NamePos := Tool.CurPos.StartPos
              else
                NamePos := Node.StartPos;
              SelRange := NodeNameSelRange(Node, NamePos);
              PushDocAndWsSymbol(SymName, AContainerName, SymDetail, lskProperty,
                AParentIdx, SelRange, FullRange);
            end;
          end;

        ctnVarDefinition:
          begin
            if CleanPosSpanToLspRange(Tool, ABuf, Node.StartPos, Node.EndPos, FullRange) then
            begin
              SymName := Trim(Tool.ExtractDefinitionName(Node));
              SymDetail := Trim(Tool.ExtractDefinitionNodeType(Node));
              NameNode := Tool.FindDefinitionNameNode(Node);
              if NameNode <> nil then
                NamePos := NameNode.StartPos
              else
                NamePos := Node.StartPos;
              SelRange := NodeNameSelRange(Node, NamePos);
              if AInsideStructuredType then
                SymKind := lskField
              else
                SymKind := lskVariable;
              PushDocAndWsSymbol(SymName, AContainerName, SymDetail, SymKind,
                AParentIdx, SelRange, FullRange);
            end;
          end;

        ctnConstDefinition:
          begin
            if CleanPosSpanToLspRange(Tool, ABuf, Node.StartPos, Node.EndPos, FullRange) then
            begin
              SymName := Trim(Tool.ExtractDefinitionName(Node));
              SymDetail := 'const';
              SelRange := NodeNameSelRange(Node, Node.StartPos);
              PushDocAndWsSymbol(SymName, AContainerName, SymDetail, lskConstant,
                AParentIdx, SelRange, FullRange);
            end;
          end;
      else
        // Skip executable statements, uses nodes, attributes, etc.
      end;
      Node := Node.NextBrother;
    end;
  end;

begin
  ADocSymbols := nil;
  AWorkspaceSymbols := nil;
  AModuleName := '';
  AUsedUnits := nil;
  DocSymCount := 0;
  WsSymCount := 0;

  if ABuf = nil then
    Exit;

  AModuleName := ChangeFileExt(ExtractFileName(ABuf.Filename), '');

  MainUses := nil;
  ImplUses := nil;
  try
    if CodeToolBoss.FindUsedUnitNames(ABuf, MainUses, ImplUses) then
    begin
      if MainUses <> nil then
        for UIdx := 0 to MainUses.Count - 1 do
          AppendUniqueStr(AUsedUnits, MainUses[UIdx]);
      if ImplUses <> nil then
        for UIdx := 0 to ImplUses.Count - 1 do
          AppendUniqueStr(AUsedUnits, ImplUses[UIdx]);
    end;
  finally
    MainUses.Free;
    ImplUses.Free;
  end;

  Tool := nil;
  CodeToolBoss.Explore(ABuf, Tool, False, False);
  if (Tool = nil) or (Tool.Tree = nil) or (Tool.Tree.Root = nil) then
    Exit;

  if Trim(Tool.GetSourceName(False)) <> '' then
    AModuleName := Trim(Tool.GetSourceName(False));

  WalkNodeList(Tool.Tree.Root, -1, '', False);
end;

function MapIdentItemKind(AItem: TIdentifierListItem; out ACompKind: TLspCompletionItemKind): Boolean;
var
  Desc: TCodeTreeNodeDesc;
begin
  Result := True;
  if AItem = nil then
    Exit(False);

  if iliKeyword in AItem.Flags then
  begin
    ACompKind := lcikKeyword;
    Exit;
  end;

  Desc := AItem.GetDesc;
  case Desc of
    ctnProcedure, ctnProcedureHead:
      begin
        if AItem.IsConstructor then
          ACompKind := lcikConstructor
        else if (AItem.Node <> nil) and (AItem.Tool <> nil) and AItem.Tool.NodeIsInAMethod(AItem.Node) then
          ACompKind := lcikMethod
        else
          ACompKind := lcikFunction;
      end;
    ctnProperty, ctnGlobalProperty:
      ACompKind := lcikProperty;
    ctnVarDefinition:
      begin
        if (AItem.Node <> nil) and (AItem.Node.Parent <> nil) and
           (AItem.Node.Parent.Desc in (AllClassSections + [ctnRecordType, ctnRecordCase, ctnRecordVariant])) then
          ACompKind := lcikField
        else
          ACompKind := lcikVariable;
      end;
    ctnConstDefinition, ctnConstant:
      ACompKind := lcikConstant;
    ctnEnumIdentifier:
      ACompKind := lcikEnumMember;
    ctnEnumerationType:
      ACompKind := lcikEnum;
    ctnRecordType:
      ACompKind := lcikStruct;
    ctnClassInterface, ctnDispinterface, ctnObjCProtocol:
      ACompKind := lcikInterface;
    ctnClass, ctnObject, ctnObjCClass, ctnCPPClass,
    ctnClassHelper, ctnRecordHelper, ctnTypeHelper,
    ctnTypeDefinition, ctnGenericType:
      ACompKind := lcikClass;
    ctnUnit, ctnProgram, ctnLibrary, ctnPackage,
    ctnUseUnit, ctnUseUnitNamespace, ctnUseUnitClearName:
      ACompKind := lcikModule;
  else
    ACompKind := lcikText;
  end;
end;

function FormatPascalDeclaration(const ARaw: string): string;
var
  Trimmed, Beautified, OutBuf: string;
  OldLineLen, I, Len: Integer;
  InQuote: Boolean;
  Ch, PrevCh, NextCh: Char;
begin
  Trimmed := Trim(ARaw);
  if Trimmed = '' then
    Exit('');

  if (CodeToolBoss <> nil) and (CodeToolBoss.SourceChangeCache <> nil) and
     (CodeToolBoss.Beautifier <> nil) then
  begin
    OldLineLen := CodeToolBoss.Beautifier.LineLength;
    try
      CodeToolBoss.Beautifier.LineLength := MaxInt;
      Beautified := Trim(CodeToolBoss.Beautifier.BeautifyStatement(
        Trimmed, 0, [bcfDoNotIndentFirstLine], 1
      ));
    finally
      CodeToolBoss.Beautifier.LineLength := OldLineLen;
    end;
  end
  else
    Beautified := Trimmed;

  // Normalize spaces around standalone '=' (e.g. default parameters 'AQuantity: Integer=1')
  // and remove redundant spaces right before ')' or ';' without touching string literals.
  OutBuf := '';
  InQuote := False;
  Len := Length(Beautified);
  for I := 1 to Len do
  begin
    Ch := Beautified[I];
    if Ch = '''' then
    begin
      InQuote := not InQuote;
      OutBuf := OutBuf + Ch;
      Continue;
    end;

    if not InQuote then
    begin
      if ((Ch = ')') or (Ch = ';')) and (Length(OutBuf) > 0) and (OutBuf[Length(OutBuf)] = ' ') then
        Delete(OutBuf, Length(OutBuf), 1);

      if Ch = '=' then
      begin
        if Length(OutBuf) > 0 then
          PrevCh := OutBuf[Length(OutBuf)]
        else
          PrevCh := #0;
        if I < Len then
          NextCh := Beautified[I + 1]
        else
          NextCh := #0;

        if not (PrevCh in [':', '<', '>', '+', '-', '*', '/', ' ']) then
          OutBuf := OutBuf + ' ';
        OutBuf := OutBuf + '=';
        if not (NextCh in ['>', '=', ' ', #0]) then
          OutBuf := OutBuf + ' ';
        Continue;
      end;
    end;

    OutBuf := OutBuf + Ch;
  end;

  Result := Trim(OutBuf);
end;

function BuildIdentItemDetail(AItem: TIdentifierListItem): string;
var
  Params, ResType: string;
begin
  Result := '';
  if AItem = nil then
    Exit;
  if iliKeyword in AItem.Flags then
    Exit('keyword');

  case AItem.GetDesc of
    ctnProcedure, ctnProcedureHead:
      begin
        // Prefer extracting directly from the real AST node so original casing,
        // var/const/out modifiers, default values, and clean spacing are preserved.
        if (AItem.Node <> nil) and (AItem.Tool <> nil) and (AItem.Node.Desc = ctnProcedure) then
        begin
          Result := FormatPascalDeclaration(AItem.Tool.ExtractProcHead(
            AItem.Node,
            [phpWithStart, phpWithoutClassName, phpWithVarModifiers,
             phpWithParameterNames, phpWithDefaultValues, phpWithResultType]
          ));
          if Result <> '' then
            Exit;
        end;

        Params := Trim(AItem.ParamNameList);
        if (Length(Params) > 0) and (Params[Length(Params)] = ';') then
          Params := Trim(Copy(Params, 1, Length(Params) - 1));
        if (Length(Params) >= 2) and (Params[1] = '(') and (Params[Length(Params)] = ')') then
          Params := Trim(Copy(Params, 2, Length(Params) - 2));

        ResType := Trim(AItem.ResultType);
        if AItem.IsConstructor then
          Result := 'constructor ' + AItem.Identifier
        else if AItem.IsDestructor then
          Result := 'destructor ' + AItem.Identifier
        else if AItem.IsFunction or (ResType <> '') then
          Result := 'function ' + AItem.Identifier
        else
          Result := 'procedure ' + AItem.Identifier;

        if Params <> '' then
          Result := Result + '(' + Params + ')';
        if ResType <> '' then
          Result := Result + ': ' + ResType;
        Result := FormatPascalDeclaration(Result + ';');
      end;
    ctnProperty, ctnGlobalProperty:
      begin
        if (AItem.Node <> nil) and (AItem.Tool <> nil) then
          Result := FormatPascalDeclaration('property ' + AItem.Tool.ExtractProperty(
            AItem.Node,
            [phpWithVarModifiers, phpWithParameterNames, phpWithResultType]
          ))
        else
          Result := Trim(AItem.ResultType);
      end;
    ctnVarDefinition, ctnConstDefinition:
      begin
        ResType := Trim(AItem.ResultType);
        if (ResType = '') and (AItem.Node <> nil) and (AItem.Tool <> nil) then
        begin
          if AItem.GetDesc = ctnVarDefinition then
            ResType := FormatPascalDeclaration(
              Trim(AItem.Tool.ExtractDefinitionName(AItem.Node)) + ': ' +
              Trim(AItem.Tool.ExtractDefinitionNodeType(AItem.Node))
            )
          else
            ResType := FormatPascalDeclaration('const ' + Trim(AItem.Tool.ExtractNode(AItem.Node, [])));
        end;
        Result := ResType;
      end;
  else
    Result := Trim(AItem.ResultType);
  end;
end;

{ TNikSymbolIndex }

constructor TNikSymbolIndex.Create;
begin
  inherited Create;
  SilenceCodeToolsLogger;
  FFiles := TFPList.Create;
  FFileKeyHash := TFPHashList.Create;
  FCodeToolsReady := False;
end;

destructor TNikSymbolIndex.Destroy;
begin
  if (CodeToolBoss <> nil) and (CodeToolBoss.SourceCache <> nil) then
    CodeToolBoss.SourceCache.OnDecodeLoaded := nil;
  Clear;
  FreeAndNil(FFileKeyHash);
  FreeAndNil(FFiles);
  inherited Destroy;
end;

procedure TNikSymbolIndex.HandleCodeCacheDecodeLoaded(ACode: TObject;
  const AFilename: string; var ASource, ADiskEncoding, AMemEncoding: string);
begin
  if (Length(ASource) >= 3) and
     (ASource[1] = #$EF) and (ASource[2] = #$BB) and (ASource[3] = #$BF) then
  begin
    Delete(ASource, 1, 3);
    ADiskEncoding := 'UTF-8BOM';
  end
  else if ADiskEncoding = '' then
    ADiskEncoding := 'UTF-8';
  AMemEncoding := 'UTF-8';
end;

procedure TNikSymbolIndex.EnsureCodeToolsBaseInitialized;
begin
  SilenceCodeToolsLogger;
  CodeToolBoss.WriteExceptions := False;
  CodeToolBoss.CatchExceptions := True;
  CodeToolBoss.IdentComplIncludeKeywords := True;
  CodeToolBoss.IdentifierList.SortForHistory := False;
  CodeToolBoss.IdentifierList.SortMethodForCompletion := icsScopedAlphabetic;
  if CodeToolBoss.SourceCache <> nil then
    CodeToolBoss.SourceCache.OnDecodeLoaded := TOnCodeCacheDecodeLoaded(@HandleCodeCacheDecodeLoaded);
end;

procedure TNikSymbolIndex.Clear;
var
  I: Integer;
begin
  for I := 0 to FFiles.Count - 1 do
    TObject(FFiles[I]).Free;
  FFiles.Clear;
  FFileKeyHash.Clear;
end;

procedure TNikSymbolIndex.ApplyWorkspaceDefineTemplates(const ADirs, AUnitPaths,
  AIncludePaths, ADefines, AUndefines: array of string);
var
  BlockTempl, DirTempl, SubTempl: TDefineTemplate;
  JoinedUnits, JoinedIncs, DefEntry, DefName, DefVal: string;
  I, J, EqPos: Integer;
begin
  CodeToolBoss.DefineTree.RemoveRootDefineTemplateByName(NIK_WORKSPACE_TEMPLATE_NAME);
  if Length(ADirs) = 0 then
  begin
    CodeToolBoss.DefineTree.ClearCache;
    Exit;
  end;

  JoinedUnits := JoinSemicolonPaths(AUnitPaths);
  JoinedIncs  := JoinSemicolonPaths(AIncludePaths);

  BlockTempl := TDefineTemplate.Create(
    NIK_WORKSPACE_TEMPLATE_NAME,
    'Nikrun workspace paths and defines',
    '', '', da_Block
  );

  for I := Low(ADirs) to High(ADirs) do
  begin
    if Trim(ADirs[I]) = '' then
      Continue;

    DirTempl := TDefineTemplate.Create(
      'NikDir_' + IntToStr(I),
      ADirs[I],
      '',
      ADirs[I],
      da_Directory
    );

    if JoinedUnits <> '' then
    begin
      SubTempl := TDefineTemplate.Create(
        'UnitPath', 'UnitPath', UnitPathMacroName,
        UnitPathMacro + ';' + JoinedUnits, da_DefineRecurse
      );
      DirTempl.AddChild(SubTempl);
    end;

    if JoinedIncs <> '' then
    begin
      SubTempl := TDefineTemplate.Create(
        'IncPath', 'IncPath', IncludePathMacroName,
        IncludePathMacro + ';' + JoinedIncs, da_DefineRecurse
      );
      DirTempl.AddChild(SubTempl);
    end;

    for J := Low(ADefines) to High(ADefines) do
    begin
      DefEntry := Trim(ADefines[J]);
      if DefEntry = '' then
        Continue;
      EqPos := Pos('=', DefEntry);
      if EqPos > 1 then
      begin
        DefName := Trim(Copy(DefEntry, 1, EqPos - 1));
        DefVal  := Copy(DefEntry, EqPos + 1, MaxInt);
      end
      else
      begin
        DefName := DefEntry;
        DefVal  := '1';
      end;
      if DefName <> '' then
      begin
        SubTempl := TDefineTemplate.Create(
          'Def_' + DefName, DefName, DefName, DefVal, da_DefineRecurse
        );
        DirTempl.AddChild(SubTempl);
      end;
    end;

    for J := Low(AUndefines) to High(AUndefines) do
    begin
      DefName := Trim(AUndefines[J]);
      if DefName <> '' then
      begin
        SubTempl := TDefineTemplate.Create(
          'Undef_' + DefName, DefName, DefName, '', da_UndefineRecurse
        );
        DirTempl.AddChild(SubTempl);
      end;
    end;

    BlockTempl.AddChild(DirTempl);
  end;

  CodeToolBoss.DefineTree.ReplaceRootSameName(BlockTempl);
  CodeToolBoss.DefineTree.ClearCache;
end;

procedure TNikSymbolIndex.ConfigureWorkspace(const AContext: TNikWorkspaceContext;
  AWorkspaceReady: Boolean; const AFallbackRootDir: string);
var
  Opts: TCodeToolsOptions;
  InstalledSdks: TInstalledSdkArray;
  FallbackSdk: TInstalledSdk;
  HasSdk: Boolean;
  CompilerBin, FpcSrcRoot, TargetOs, TargetCpu, ProjDir, CacheDir: string;
  ConfigXmlPath, TestUnitPath, FpcOpts: string;
  ScopeDirs, EffUnitPaths, EffIncPaths: TStringArray;
  I: Integer;

  procedure AddFpcOpt(const AFlag: string);
  begin
    if Trim(AFlag) = '' then
      Exit;
    if FpcOpts <> '' then
      FpcOpts := FpcOpts + ' ';
    FpcOpts := FpcOpts + QuoteFpcOptIfNeeded(AFlag);
  end;

begin
  Clear;
  EnsureCodeToolsBaseInitialized;

  HasSdk := False;
  CompilerBin := '';
  FpcSrcRoot := '';
  TargetOs := '';
  TargetCpu := '';
  ProjDir := '';
  CacheDir := '';
  FpcOpts := '';
  ScopeDirs := nil;
  EffUnitPaths := nil;
  EffIncPaths := nil;

  if AWorkspaceReady then
  begin
    CompilerBin := AContext.CompilerBinary;
    FpcSrcRoot  := JoinPath(AContext.Sdk.InstallPath, 'source');
    TargetOs    := AContext.Sdk.Manifest.TargetOs;
    TargetCpu   := AContext.Sdk.Manifest.TargetCpu;
    ProjDir     := AContext.ProjectDir;
    CacheDir    := AContext.CacheDir;
    HasSdk      := (CompilerBin <> '') and FileExists(CompilerBin);

    if Trim(AContext.Mode) <> '' then
      AddFpcOpt('-M' + Trim(AContext.Mode))
    else
      AddFpcOpt('-Mobjfpc');

    if AContext.LongStrings then
      AddFpcOpt('-Sh')
    else
      AddFpcOpt('-Sh-');

    for I := 0 to High(AContext.Defines) do
      if Trim(AContext.Defines[I]) <> '' then
        AddFpcOpt('-d' + Trim(AContext.Defines[I]));
    for I := 0 to High(AContext.Undefines) do
      if Trim(AContext.Undefines[I]) <> '' then
        AddFpcOpt('-u' + Trim(AContext.Undefines[I]));

    AppendUniqueNativePath(ScopeDirs, ProjDir);
    for I := 0 to High(AContext.UnitPaths) do
    begin
      AppendUniqueNativePath(EffUnitPaths, AContext.UnitPaths[I]);
      AppendUniqueNativePath(ScopeDirs, AContext.UnitPaths[I]);
      AddFpcOpt('-Fu' + AContext.UnitPaths[I]);
    end;
    for I := 0 to High(AContext.IncludePaths) do
    begin
      AppendUniqueNativePath(EffIncPaths, AContext.IncludePaths[I]);
      AppendUniqueNativePath(ScopeDirs, AContext.IncludePaths[I]);
      AddFpcOpt('-Fi' + AContext.IncludePaths[I]);
    end;
  end
  else
  begin
    ProjDir := Trim(AFallbackRootDir);
    if (ProjDir <> '') and DirectoryExists(ProjDir) then
    begin
      AppendUniqueNativePath(ScopeDirs, ProjDir);
      AppendUniqueNativePath(EffUnitPaths, ProjDir);
      AppendUniqueNativePath(EffIncPaths, ProjDir);
      CacheDir := JoinPath(JoinPath(JoinPath(ProjDir, '.nik'), 'cache'), 'fallback-lsp');
    end;

    try
      InstalledSdks := ListInstalledSdks;
      for I := High(InstalledSdks) downto 0 do
      begin
        FallbackSdk := InstalledSdks[I];
        CompilerBin := JoinPath(FallbackSdk.InstallPath, FallbackSdk.Manifest.Paths.PpcBinary);
        if FileExists(CompilerBin) then
        begin
          FpcSrcRoot := JoinPath(FallbackSdk.InstallPath, 'source');
          TargetOs   := FallbackSdk.Manifest.TargetOs;
          TargetCpu  := FallbackSdk.Manifest.TargetCpu;
          HasSdk     := True;
          Break;
        end;
      end;
    except
      HasSdk := False;
    end;
    AddFpcOpt('-Mobjfpc');
    AddFpcOpt('-Sh');
  end;

  if HasSdk then
  begin
    Opts := TCodeToolsOptions.Create;
    try
      ConfigXmlPath := '';
      if CacheDir <> '' then
      begin
        try
          EnsureDirExists(CacheDir);
          ConfigXmlPath := JoinPath(CacheDir, 'codetools-config.xml');
          TestUnitPath  := JoinPath(CacheDir, '_nik_ct_probe.pas');
          if not FileExists(TestUnitPath) then
            WriteFileTextUtf8(TestUnitPath, 'unit _nik_ct_probe;' + LineEnding + 'interface' + LineEnding + 'implementation' + LineEnding + 'end.' + LineEnding);
          if FileExists(ConfigXmlPath) then
            Opts.LoadFromFile(ConfigXmlPath);
          Opts.TestPascalFile := TestUnitPath;
        except
          ConfigXmlPath := '';
        end;
      end;

      Opts.FPCPath         := CompilerBin;
      if (FpcSrcRoot <> '') and DirectoryExists(FpcSrcRoot) then
        Opts.FPCSrcDir     := FpcSrcRoot;
      Opts.TargetOS        := TargetOs;
      Opts.TargetProcessor := TargetCpu;
      if ProjDir <> '' then
        Opts.ProjectDir    := ProjDir;
      Opts.FPCOptions      := FpcOpts;

      CodeToolBoss.Init(Opts);
      FCodeToolsReady := True;

      if ConfigXmlPath <> '' then
      begin
        try
          Opts.SaveToFile(ConfigXmlPath);
        except
          // Non-fatal if cache directory is read-only
        end;
      end;
    finally
      Opts.Free;
    end;
  end;

  if AWorkspaceReady then
  begin
    ApplyWorkspaceDefineTemplates(
      ScopeDirs, EffUnitPaths, EffIncPaths,
      AContext.Defines, AContext.Undefines
    );
    IndexProjectDirectories(EffUnitPaths);
    if (AContext.EntryPath <> '') and FileExists(AContext.EntryPath) then
      RefreshDiskFile(AContext.EntryPath);
  end
  else
  begin
    ApplyWorkspaceDefineTemplates(ScopeDirs, EffUnitPaths, EffIncPaths, [], []);
    IndexProjectDirectories(EffUnitPaths);
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

procedure TNikSymbolIndex.StoreIndexedFile(AParsed: TPasIndexedFile);
var
  ExistingIdx: Integer;
begin
  if AParsed = nil then
    Exit;
  ExistingIdx := FindIndexedByKey(AParsed.NormalizedKey);
  if ExistingIdx >= 0 then
  begin
    TObject(FFiles[ExistingIdx]).Free;
    FFiles[ExistingIdx] := AParsed;
  end
  else
  begin
    ExistingIdx := FFiles.Add(AParsed);
    FFileKeyHash.Add(AParsed.NormalizedKey, Pointer(PtrInt(ExistingIdx + 1)));
  end;
end;

procedure TNikSymbolIndex.RemoveIndexedByKey(const ANormalizedKey: string);
var
  Idx, I: Integer;
begin
  Idx := FindIndexedByKey(ANormalizedKey);
  if Idx < 0 then
    Exit;

  TObject(FFiles[Idx]).Free;
  FFiles.Delete(Idx);
  FFileKeyHash.Clear;
  for I := 0 to FFiles.Count - 1 do
    FFileKeyHash.Add(TPasIndexedFile(FFiles[I]).NormalizedKey, Pointer(PtrInt(I + 1)));
end;

procedure TNikSymbolIndex.IndexProjectDirectories(const AProjectUnitDirs: array of string);
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
            RefreshDiskFile(CleanDir + SR.Name);
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

function TNikSymbolIndex.SyncOpenDocument(const AUri, AFilePath, ASourceText: string): TPasIndexedFile;
var
  ExpPath, EffUri, ModName: string;
  Buf: TCodeBuffer;
  DummyDocSyms: TLspDocumentSymbolArray;
  WsSyms: TPasWorkspaceSymbolArray;
  UsedArr: TLspStringArray;
begin
  EnsureCodeToolsBaseInitialized;
  if Trim(AFilePath) <> '' then
    ExpPath := ExpandFileName(NormalizeNativeSeparators(AFilePath))
  else
    ExpPath := ExpandFileName(NormalizeNativeSeparators(UriToFilePath(AUri)));

  if AUri <> '' then
    EffUri := AUri
  else
    EffUri := FilePathToUri(ExpPath);

  Buf := ObtainCodeBuffer(ExpPath, False);
  if Buf <> nil then
  begin
    Buf.IsDeleted := False;
    if (Length(ASourceText) >= 3) and
       (ASourceText[1] = #$EF) and (ASourceText[2] = #$BB) and (ASourceText[3] = #$BF) then
    begin
      if Buf.Source <> Copy(ASourceText, 4, MaxInt) then
      begin
        Buf.Source := Copy(ASourceText, 4, MaxInt);
        if CodeToolBoss.DirectoryCachePool <> nil then
          CodeToolBoss.DirectoryCachePool.IncreaseFileTimeStamp;
      end;
    end
    else if Buf.Source <> ASourceText then
    begin
      Buf.Source := ASourceText;
      if CodeToolBoss.DirectoryCachePool <> nil then
        CodeToolBoss.DirectoryCachePool.IncreaseFileTimeStamp;
    end;
  end;

  ExtractDocumentSymbolsFromBuffer(Buf, DummyDocSyms, WsSyms, ModName, UsedArr);

  Result := TPasIndexedFile.Create;
  Result.Uri             := EffUri;
  Result.NormalizedKey   := LowerCase(NormalizeDocumentUri(EffUri));
  Result.FilePath        := ExpPath;
  Result.ModuleName      := ModName;
  Result.ModuleNameLower := LowerCase(ModName);
  Result.UsedUnits       := UsedArr;
  Result.Symbols         := WsSyms;
  StoreIndexedFile(Result);
end;

procedure TNikSymbolIndex.CloseOpenDocument(const AUri, AFilePath: string);
var
  ExpPath, NormKey: string;
  Buf: TCodeBuffer;
begin
  EnsureCodeToolsBaseInitialized;
  if Trim(AFilePath) <> '' then
    ExpPath := ExpandFileName(NormalizeNativeSeparators(AFilePath))
  else
    ExpPath := ExpandFileName(NormalizeNativeSeparators(UriToFilePath(AUri)));

  if AUri <> '' then
    NormKey := LowerCase(NormalizeDocumentUri(AUri))
  else
    NormKey := LowerCase(NormalizeDocumentUri(FilePathToUri(ExpPath)));

  Buf := CodeToolBoss.FindFile(ExpPath);
  if Buf <> nil then
  begin
    if FileExists(ExpPath) then
      Buf.Revert
    else
      Buf.IsDeleted := True;
    if CodeToolBoss.DirectoryCachePool <> nil then
      CodeToolBoss.DirectoryCachePool.IncreaseFileTimeStamp;
  end;

  if FileExists(ExpPath) then
    RefreshDiskFile(ExpPath)
  else
    RemoveIndexedByKey(NormKey);
end;

function TNikSymbolIndex.RefreshDiskFile(const AFilePath: string): TPasIndexedFile;
var
  ExpPath, EffUri, ModName: string;
  Buf: TCodeBuffer;
  DummyDocSyms: TLspDocumentSymbolArray;
  WsSyms: TPasWorkspaceSymbolArray;
  UsedArr: TLspStringArray;
begin
  Result := nil;
  if (Trim(AFilePath) = '') or (not FileExists(AFilePath)) then
    Exit;

  EnsureCodeToolsBaseInitialized;
  ExpPath := ExpandFileName(NormalizeNativeSeparators(AFilePath));
  EffUri  := FilePathToUri(ExpPath);

  Buf := CodeToolBoss.FindFile(ExpPath);
  if Buf <> nil then
    Buf.Revert
  else
    Buf := CodeToolBoss.LoadFile(ExpPath, True, False);

  if CodeToolBoss.DirectoryCachePool <> nil then
    CodeToolBoss.DirectoryCachePool.IncreaseFileTimeStamp;

  if Buf = nil then
    Exit;

  ExtractDocumentSymbolsFromBuffer(Buf, DummyDocSyms, WsSyms, ModName, UsedArr);

  Result := TPasIndexedFile.Create;
  Result.Uri             := EffUri;
  Result.NormalizedKey   := LowerCase(NormalizeDocumentUri(EffUri));
  Result.FilePath        := ExpPath;
  Result.ModuleName      := ModName;
  Result.ModuleNameLower := LowerCase(ModName);
  Result.UsedUnits       := UsedArr;
  Result.Symbols         := WsSyms;
  StoreIndexedFile(Result);
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

function TNikSymbolIndex.DoesFileUseUnit(const AUri, AFilePath, AUnitNameLower: string): Boolean;
var
  F: TPasIndexedFile;
  Buf: TCodeBuffer;
  MainUses, ImplUses: TStrings;
  I: Integer;
begin
  Result := False;
  if AUnitNameLower = '' then
    Exit;

  F := FindFileByUri(AUri);
  if F <> nil then
  begin
    for I := 0 to High(F.UsedUnits) do
      if LowerCase(F.UsedUnits[I]) = AUnitNameLower then
        Exit(True);
  end;

  Buf := ObtainCodeBuffer(AFilePath, True);
  if Buf = nil then
    Exit;

  MainUses := nil;
  ImplUses := nil;
  try
    if CodeToolBoss.FindUsedUnitNames(Buf, MainUses, ImplUses) then
    begin
      if MainUses <> nil then
        for I := 0 to MainUses.Count - 1 do
          if LowerCase(MainUses[I]) = AUnitNameLower then
            Exit(True);
      if ImplUses <> nil then
        for I := 0 to ImplUses.Count - 1 do
          if LowerCase(ImplUses[I]) = AUnitNameLower then
            Exit(True);
    end;
  finally
    MainUses.Free;
    ImplUses.Free;
  end;
end;

function TNikSymbolIndex.BuildDocumentSymbols(const AUri, AFilePath: string): TLspDocumentSymbolArray;
var
  ExpPath, ModName: string;
  Buf: TCodeBuffer;
  WsSyms: TPasWorkspaceSymbolArray;
  UsedArr: TLspStringArray;
begin
  Result := nil;
  EnsureCodeToolsBaseInitialized;
  if Trim(AFilePath) <> '' then
    ExpPath := AFilePath
  else
    ExpPath := UriToFilePath(AUri);

  Buf := ObtainCodeBuffer(ExpPath, True);
  if Buf = nil then
    Exit;

  ExtractDocumentSymbolsFromBuffer(Buf, Result, WsSyms, ModName, UsedArr);
end;

function TNikSymbolIndex.SearchWorkspaceSymbols(const AQuery: string;
  AMaxResults: Integer): TLspSymbolInformationArray;
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

function TNikSymbolIndex.ResolveDefinitions(const AUri, AFilePath: string;
  ADoc: TLspDocument; const APos: TLspPosition): TLspLocationArray;
var
  ExpPath: string;
  Buf, DeclBuf, BodyBuf: TCodeBuffer;
  X, Y, DeclX, DeclY, DeclTop, BodyX, BodyY, BodyTop, BlockTop, BlockBot: Integer;
  Revertable: Boolean;
begin
  Result := nil;
  EnsureCodeToolsBaseInitialized;
  if Trim(AFilePath) <> '' then
    ExpPath := AFilePath
  else
    ExpPath := UriToFilePath(AUri);

  Buf := ObtainCodeBuffer(ExpPath, True);
  if not LspPosToCodeXY(Buf, ADoc, APos, X, Y) then
    Exit;

  CodeToolBoss.ClearError;
  DeclBuf := nil;
  if CodeToolBoss.FindMainDeclaration(Buf, X, Y, DeclBuf, DeclX, DeclY, DeclTop) and
     (DeclBuf <> nil) then
  begin
    // If cursor was already standing on the interface/class declaration itself, toggle to implementation body
    if (DeclBuf = Buf) and (DeclY = Y) then
    begin
      BodyBuf := nil;
      if CodeToolBoss.JumpToMethod(DeclBuf, DeclX, DeclY, BodyBuf, BodyX, BodyY, BodyTop,
           BlockTop, BlockBot, Revertable) and (BodyBuf <> nil) then
      begin
        SetLength(Result, 1);
        Result[0] := TLspLocation.Create(
          FilePathToUri(BodyBuf.Filename),
          CodeXYIdentifierRange(BodyBuf, BodyX, BodyY)
        );
        Exit;
      end;
    end;

    SetLength(Result, 1);
    Result[0] := TLspLocation.Create(
      FilePathToUri(DeclBuf.Filename),
      CodeXYIdentifierRange(DeclBuf, DeclX, DeclY)
    );
    Exit;
  end;

  // Fallback when cursor is directly on an interface/class method header (where FindMainDeclaration returns False)
  CodeToolBoss.ClearError;
  BodyBuf := nil;
  if CodeToolBoss.JumpToMethod(Buf, X, Y, BodyBuf, BodyX, BodyY, BodyTop,
       BlockTop, BlockBot, Revertable) and (BodyBuf <> nil) then
  begin
    SetLength(Result, 1);
    Result[0] := TLspLocation.Create(
      FilePathToUri(BodyBuf.Filename),
      CodeXYIdentifierRange(BodyBuf, BodyX, BodyY)
    );
  end;
end;

function TNikSymbolIndex.ResolveDeclarations(const AUri, AFilePath: string;
  ADoc: TLspDocument; const APos: TLspPosition): TLspLocationArray;
var
  ExpPath: string;
  Buf, DeclBuf, JumpBuf: TCodeBuffer;
  X, Y, DeclX, DeclY, DeclTop, JumpX, JumpY, JumpTop, BlockTop, BlockBot: Integer;
  Revertable: Boolean;
begin
  Result := nil;
  EnsureCodeToolsBaseInitialized;
  if Trim(AFilePath) <> '' then
    ExpPath := AFilePath
  else
    ExpPath := UriToFilePath(AUri);

  Buf := ObtainCodeBuffer(ExpPath, True);
  if not LspPosToCodeXY(Buf, ADoc, APos, X, Y) then
    Exit;

  CodeToolBoss.ClearError;
  DeclBuf := nil;
  if CodeToolBoss.FindMainDeclaration(Buf, X, Y, DeclBuf, DeclX, DeclY, DeclTop) and
     (DeclBuf <> nil) then
  begin
    SetLength(Result, 1);
    Result[0] := TLspLocation.Create(
      FilePathToUri(DeclBuf.Filename),
      CodeXYIdentifierRange(DeclBuf, DeclX, DeclY)
    );
    Exit;
  end;

  // Fallback for method implementation headers jumping back up to class/interface declaration
  CodeToolBoss.ClearError;
  JumpBuf := nil;
  if CodeToolBoss.JumpToMethod(Buf, X, Y, JumpBuf, JumpX, JumpY, JumpTop,
       BlockTop, BlockBot, Revertable) and (JumpBuf <> nil) and
     ((JumpBuf <> Buf) or (JumpY < Y)) then
  begin
    SetLength(Result, 1);
    Result[0] := TLspLocation.Create(
      FilePathToUri(JumpBuf.Filename),
      CodeXYIdentifierRange(JumpBuf, JumpX, JumpY)
    );
  end;
end;

function TNikSymbolIndex.ResolveHover(const AUri, AFilePath: string;
  ADoc: TLspDocument; const APos: TLspPosition): TLspHover;
var
  ExpPath, SmartHint, SigLine, DocComment, ModUnitName, Md, Ident: string;
  Buf, DeclBuf: TCodeBuffer;
  X, Y, DeclX, DeclY, DeclTop, CleanPos: Integer;
  WordRange: TLspRange;
  HasWordRange: Boolean;
  DeclTool: TCodeTool;
  DeclNode: TCodeTreeNode;
  DeclCaret: TCodeXYPosition;
begin
  Result := Default(TLspHover);
  EnsureCodeToolsBaseInitialized;
  if Trim(AFilePath) <> '' then
    ExpPath := AFilePath
  else
    ExpPath := UriToFilePath(AUri);

  Buf := ObtainCodeBuffer(ExpPath, True);
  if not LspPosToCodeXY(Buf, ADoc, APos, X, Y) then
    Exit;

  HasWordRange := False;
  if (ADoc <> nil) and ADoc.ExtractIdentifierAt(APos, Ident, WordRange) then
    HasWordRange := True;

  CodeToolBoss.ClearError;
  DeclBuf := nil;
  if not CodeToolBoss.FindMainDeclaration(Buf, X, Y, DeclBuf, DeclX, DeclY, DeclTop) then
    Exit;
  if DeclBuf = nil then
    Exit;

  // Direct unit jump/hover when cursor is on a unit name in uses
  if (DeclX = 1) and (DeclY = 1) then
  begin
    ModUnitName := CodeToolBoss.GetSourceName(DeclBuf, False);
    if ModUnitName = '' then
      ModUnitName := ChangeFileExt(ExtractFileName(DeclBuf.Filename), '');
    Result.HasValue := True;
    Result.HasRange := HasWordRange;
    Result.Range    := WordRange;
    Result.Markdown := '```pascal' + #10 + 'unit ' + ModUnitName + ';' + #10 + '```' +
      #10#10 + '`' + DeclBuf.Filename + '`';
    Exit;
  end;

  SigLine := '';
  DeclTool := nil;
  if CodeToolBoss.Explore(DeclBuf, DeclTool, False, False) and (DeclTool <> nil) then
  begin
    DeclCaret.Code := DeclBuf;
    DeclCaret.X := DeclX;
    DeclCaret.Y := DeclY;
    if DeclTool.CaretToCleanPos(DeclCaret, CleanPos) = 0 then
    begin
      DeclNode := DeclTool.FindDeepestNodeAtPos(CleanPos, False);
      while (DeclNode <> nil) and
            not (DeclNode.Desc in [ctnProcedure, ctnProperty, ctnGlobalProperty,
                                   ctnTypeDefinition, ctnGenericType,
                                   ctnVarDefinition, ctnConstDefinition, ctnEnumIdentifier]) do
        DeclNode := DeclNode.Parent;

      if DeclNode <> nil then
      begin
        case DeclNode.Desc of
          ctnProcedure:
            SigLine := FormatPascalDeclaration(DeclTool.ExtractProcHead(DeclNode,
              [phpWithStart, phpWithVarModifiers, phpWithParameterNames,
               phpWithDefaultValues, phpWithResultType]));
          ctnProperty, ctnGlobalProperty:
            SigLine := FormatPascalDeclaration('property ' + Trim(DeclTool.ExtractProperty(DeclNode,
              [phpWithVarModifiers, phpWithParameterNames, phpWithResultType])));
          ctnVarDefinition:
            SigLine := FormatPascalDeclaration(
              Trim(DeclTool.ExtractDefinitionName(DeclNode)) + ': ' +
              Trim(DeclTool.ExtractDefinitionNodeType(DeclNode)) + ';'
            );
          ctnTypeDefinition, ctnGenericType:
            SigLine := FormatPascalDeclaration('type ' + Trim(DeclTool.ExtractNode(DeclNode, [])));
          ctnConstDefinition:
            SigLine := FormatPascalDeclaration('const ' + Trim(DeclTool.ExtractNode(DeclNode, [])));
          ctnEnumIdentifier:
            SigLine := GetIdentifier(@DeclTool.Src[DeclNode.StartPos]);
        else
          SigLine := '';
        end;
      end;
    end;
  end;

  if SigLine = '' then
  begin
    SmartHint := Trim(CodeToolBoss.FindSmartHint(Buf, X, Y));
    if SmartHint <> '' then
      SigLine := SmartHint;
  end;

  if SigLine = '' then
    Exit;

  DocComment  := ExtractPasDocForCodeXY(DeclBuf, DeclX, DeclY);
  ModUnitName := CodeToolBoss.GetSourceName(DeclBuf, True);
  if ModUnitName = '' then
    ModUnitName := ChangeFileExt(ExtractFileName(DeclBuf.Filename), '');

  Md := '```pascal' + #10 + SigLine + #10 + '```';
  if DocComment <> '' then
    Md := Md + #10#10 + DocComment;
  if ModUnitName <> '' then
    Md := Md + #10#10 + '*Unit `' + ModUnitName + '`*';

  Result.HasValue := True;
  Result.HasRange := HasWordRange;
  Result.Range    := WordRange;
  Result.Markdown := Md;
end;

function TNikSymbolIndex.ResolveCompletions(const AUri, AFilePath: string;
  ADoc: TLspDocument; const APos: TLspPosition): TLspCompletionList;
const
  MAX_COMPLETION_ITEMS = 3500;
var
  ExpPath, LineStr, Prefix, SortPfx: string;
  Buf: TCodeBuffer;
  X, Y, StartByte, TotalCount, I, OutCount, SeenIdx: Integer;
  IdentList: TIdentifierList;
  Item: TIdentifierListItem;
  CompKind: TLspCompletionItemKind;
  Seen: TStringList;
  KeyLower: string;
  ItemCaret: TCodeXYPosition;
begin
  Result := Default(TLspCompletionList);
  Result.IsIncomplete := False;
  EnsureCodeToolsBaseInitialized;

  if Trim(AFilePath) <> '' then
    ExpPath := AFilePath
  else
    ExpPath := UriToFilePath(AUri);

  Buf := ObtainCodeBuffer(ExpPath, True);
  if not LspPosToCodeXY(Buf, ADoc, APos, X, Y) then
    Exit;

  Prefix := '';
  if ADoc <> nil then
    LineStr := ADoc.GetLineText(APos.Line)
  else if (APos.Line >= 0) and (APos.Line < Buf.LineCount) then
    LineStr := Buf.GetLine(APos.Line, False)
  else
    LineStr := '';

  StartByte := X - 1;
  if StartByte > Length(LineStr) then
    StartByte := Length(LineStr);
  while (StartByte >= 1) and IsIdentByte(LineStr[StartByte]) do
    Dec(StartByte);
  if StartByte + 1 <= X - 1 then
    Prefix := Copy(LineStr, StartByte + 1, (X - 1) - StartByte);

  CodeToolBoss.ClearError;
  if not CodeToolBoss.GatherIdentifiers(Buf, X, Y) then
    Exit;

  IdentList := CodeToolBoss.IdentifierList;
  // Return full scope set for fast client-side fuzzy matching unless scope exceeds MAX_COMPLETION_ITEMS
  if (IdentList.Count > MAX_COMPLETION_ITEMS) and (Prefix <> '') then
  begin
    IdentList.Prefix := Prefix;
    Result.IsIncomplete := True;
  end
  else
    IdentList.Prefix := '';

  TotalCount := IdentList.GetFilteredCount;
  if TotalCount <= 0 then
    Exit;

  if TotalCount > MAX_COMPLETION_ITEMS then
    Result.IsIncomplete := True;

  OutCount := 0;
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;

    for I := 0 to TotalCount - 1 do
    begin
      if OutCount >= MAX_COMPLETION_ITEMS then
        Break;
      Item := IdentList.FilteredItems[I];
      if (Item = nil) or (Item.Identifier = '') then
        Continue;

      if not MapIdentItemKind(Item, CompKind) then
        Continue;

      LineStr := BuildIdentItemDetail(Item);
      KeyLower := LowerCase(Item.Identifier + '|' + LineStr);
      if Seen.Find(KeyLower, SeenIdx) then
        Continue;
      Seen.Add(KeyLower);

      if iliKeyword in Item.Flags then
        SortPfx := '9_'
      else
      begin
        case Item.Compatibility of
          icompExact:        SortPfx := '0_';
          icompCompatible:   SortPfx := '1_';
          icompUnknown:      SortPfx := '2_';
          icompIncompatible: SortPfx := '3_';
        else
          SortPfx := '2_';
        end;
      end;

      SetLength(Result.Items, OutCount + 1);
      Result.Items[OutCount] := Default(TLspCompletionItem);
      Result.Items[OutCount].LabelText := Item.Identifier;
      Result.Items[OutCount].Kind      := CompKind;
      Result.Items[OutCount].Detail    := LineStr;
      if (TotalCount <= 150) and (Item.Node <> nil) and (Item.Tool <> nil) then
      begin
        if Item.Tool.CleanPosToCaret(Item.Node.StartPos, ItemCaret) and
           (ItemCaret.Code <> nil) then
          Result.Items[OutCount].DocumentationMarkdown := ExtractPasDocForCodeXY(
            ItemCaret.Code,
            ItemCaret.X,
            ItemCaret.Y
          );
      end;
      Result.Items[OutCount].SortText  := SortPfx + Format('%.4d_', [I]) + Item.Identifier;
      if iliNeedsAmpersand in Item.Flags then
        Result.Items[OutCount].InsertText := '&' + Item.Identifier;
      Inc(OutCount);
    end;
  finally
    Seen.Free;
  end;
end;

function TNikSymbolIndex.ResolveSignatureHelp(const AUri, AFilePath: string;
  ADoc: TLspDocument; const APos: TLspPosition): TLspSignatureHelp;
var
  ExpPath, ParamsRaw, RetRaw, ProcName, LabelStr, DocComment: string;
  Buf: TCodeBuffer;
  X, Y, I, PIdx, OutCount: Integer;
  Contexts: TCodeContextInfo;
  CtxItem: TCodeContextInfoItem;
  ProcNode: TCodeTreeNode;
  ProcTool: TFindDeclarationTool;
  ParamParts: TLspStringArray;
  Caret: TCodeXYPosition;
begin
  Result := Default(TLspSignatureHelp);
  Result.ActiveSignature := 0;
  Result.ActiveParameter := 0;
  EnsureCodeToolsBaseInitialized;

  if Trim(AFilePath) <> '' then
    ExpPath := AFilePath
  else
    ExpPath := UriToFilePath(AUri);

  Buf := ObtainCodeBuffer(ExpPath, True);
  if not LspPosToCodeXY(Buf, ADoc, APos, X, Y) then
    Exit;

  CodeToolBoss.ClearError;
  Contexts := nil;
  try
    if not CodeToolBoss.FindCodeContext(Buf, X, Y, Contexts) then
      Exit;
    if (Contexts = nil) or (Contexts.Count = 0) then
      Exit;

    if Contexts.ParameterIndex > 1 then
      Result.ActiveParameter := Contexts.ParameterIndex - 1
    else
      Result.ActiveParameter := 0;

    OutCount := 0;
    for I := 0 to Contexts.Count - 1 do
    begin
      CtxItem := Contexts[I];
      if CtxItem = nil then
        Continue;

      ParamParts := nil;
      LabelStr := '';
      DocComment := '';

      if (CtxItem.Expr.Context.Node <> nil) and (CtxItem.Expr.Context.Tool <> nil) and
         (CtxItem.Expr.Context.Node.Desc = ctnProcedure) then
      begin
        ProcNode := CtxItem.Expr.Context.Node;
        ProcTool := CtxItem.Expr.Context.Tool;
        ProcName := Trim(ProcTool.ExtractProcName(ProcNode, []));
        ParamsRaw := FormatPascalDeclaration(ProcTool.ExtractProcHead(ProcNode,
          [phpWithoutName, phpWithoutBrackets, phpWithoutSemicolon,
           phpWithVarModifiers, phpWithParameterNames, phpWithDefaultValues]));
        RetRaw := FormatPascalDeclaration(ProcTool.ExtractFuncResultType(ProcNode, [phpWithoutSemicolon]));
        if (Length(RetRaw) > 0) and (RetRaw[1] = ':') and
           (Length(RetRaw) >= 2) and (RetRaw[2] <> ' ') then
          RetRaw := ': ' + Trim(Copy(RetRaw, 2, MaxInt));

        SplitParameterStrings(ParamsRaw, ParamParts);
        LabelStr := FormatPascalDeclaration(ProcName + '(' + ParamsRaw + ')' + RetRaw);

        if ProcTool.CleanPosToCaret(ProcNode.StartPos, Caret) and (Caret.Code <> nil) then
          DocComment := ExtractPasDocForCodeXY(Caret.Code, Caret.X, Caret.Y);
      end
      else if CtxItem.ProcName <> '' then
      begin
        ProcName := CtxItem.ProcName;
        if CtxItem.Params <> nil then
        begin
          SetLength(ParamParts, CtxItem.Params.Count);
          ParamsRaw := '';
          for PIdx := 0 to CtxItem.Params.Count - 1 do
          begin
            ParamParts[PIdx] := Trim(CtxItem.Params[PIdx]);
            if PIdx > 0 then
              ParamsRaw := ParamsRaw + '; ';
            ParamsRaw := ParamsRaw + ParamParts[PIdx];
          end;
        end
        else
          ParamsRaw := '';
        LabelStr := ProcName + '(' + ParamsRaw + ')';
        if CtxItem.ResultType <> '' then
          LabelStr := LabelStr + ': ' + CtxItem.ResultType;
      end;

      if LabelStr = '' then
        Continue;

      SetLength(Result.Signatures, OutCount + 1);
      Result.Signatures[OutCount].LabelText := LabelStr;
      Result.Signatures[OutCount].DocumentationMarkdown := DocComment;
      SetLength(Result.Signatures[OutCount].Parameters, Length(ParamParts));
      for PIdx := 0 to High(ParamParts) do
      begin
        Result.Signatures[OutCount].Parameters[PIdx].LabelText := ParamParts[PIdx];
        Result.Signatures[OutCount].Parameters[PIdx].DocumentationMarkdown := '';
      end;
      Inc(OutCount);
    end;
  finally
    Contexts.Free;
  end;
end;

end.
