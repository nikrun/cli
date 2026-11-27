unit nik.lsp.manifest;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  nikrun.lsp.types, nikrun.lsp.uri, nikrun.lsp.utf16, nikrun.lsp.documents;

function BuildManifestDocumentSymbols(ADoc: TLspDocument): TLspDocumentSymbolArray;

function ResolveManifestDefinitions(const AManifestPath: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspLocationArray;

function ResolveManifestHover(const AManifestPath: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspHover;

function ResolveManifestCompletions(const AManifestPath: string; ADoc: TLspDocument;
  const APos: TLspPosition; const ATriggerChar: string): TLspCompletionList;

implementation

uses
  nik.types, nik.platform, nik.paths, nik.fs, nik.archive,
  nik.sdk.manager, nik.pkg.types, nik.pkg.lock, nik.pkg.fetch,
  VSoft.YAML;

type
  TYamlCursorRole = (
    ycrNone,
    ycrKey,
    ycrScalarValue,
    ycrSeqItem
  );

  TYamlValueKind = (
    yvkScalar,
    yvkMapping,
    yvkSequence,
    yvkScalarOrMapping
  );

  TYamlLogicalLine = record
    IsBlank: Boolean;
    Indent: Integer;
    EffectiveLen: Integer;    // Length excluding trailing # comment
    TrimRightEnd: Integer;    // Last non-whitespace byte <= EffectiveLen
    CommentStartByte: Integer; // 0 when no trailing comment
    IsSeqItem: Boolean;
    DashByte: Integer;
    SeqValStartByte: Integer;
    HasColon: Boolean;
    ColonByte: Integer;
    KeyStartByte: Integer;
    KeyEndByte: Integer;
    KeyName: string;
    ValStartByte: Integer;    // 0 when nothing after colon
    ValEndByte: Integer;
  end;

  TYamlStackEntry = record
    Indent: Integer;
    KeyName: string;
    LineIndex: Integer;
  end;

  TYamlCursorContext = record
    Valid: Boolean;
    InComment: Boolean;
    Role: TYamlCursorRole;
    RootArtifact: string;     // 'program', 'library', 'package', 'template', or ''
    IsOverlay: Boolean;       // True inside test, targets.*, or profiles.*
    ParentPath: string;       // Raw dot-separated ancestor keys
    CanonicalParent: string;  // Normalized scope ('root', 'artifact', 'test', 'targets', 'profiles', 'subOverlay', 'toolchain', 'build', 'warnings', 'dependencies', 'depMapping')
    CurrentKey: string;       // Key on current line (for ycrKey or ycrScalarValue)
    InlineScalarValue: string; // Unquoted scalar value on current line when HasColonOnLine is True
    CanonicalField: string;   // Normalized field identifier (e.g. 'toolchain.fpc', 'build.mode', 'root.program')
    TokenText: string;        // Unquoted token at cursor
    IsQuotedToken: Boolean;   // True if cursor is inside '...' or "..."
    HasColonOnLine: Boolean;  // True if key line already has ':'
    IsFirstListElement: Boolean;
    TriggeredRightAfterDelim: Boolean; // True right after ': ', '- ', or ', '
    TokenRange: TLspRange;    // Range of the hovered/completed token (excluding quotes when quoted)
    ReplaceRange: TLspRange;  // Range to replace in CompletionItem.TextEdit
    ExistingKeys: TStringArray;
  end;

  TManifestKeySpec = record
    Name: string;
    ValueKind: TYamlValueKind;
    TypeLabel: string;
    DefaultLabel: string;
    FpcFlagLabel: string;
    Summary: string;
    DetailsMarkdown: string;
  end;

  TManifestEnumSpec = record
    Value: string;
    Detail: string;
    Documentation: string;
  end;

  TSdkVersionCandidate = record
    Version: string;
    HasInstalled: Boolean;
    Installed: TInstalledSdk;
    HasRemote: Boolean;
    Remote: TRemoteSdkEntry;
    UpdateAvailable: Boolean;
  end;
  TSdkVersionCandidateArray = array of TSdkVersionCandidate;

function IsSpaceOrTab(ACh: Char): Boolean; inline;
begin
  Result := (ACh = ' ') or (ACh = #9);
end;

function StripQuotes(const ARaw: string; out AWasQuoted: Boolean): string;
var
  S: string;
begin
  AWasQuoted := False;
  S := Trim(ARaw);
  if (Length(S) >= 2) and
     (((S[1] = '"') and (S[Length(S)] = '"')) or
      ((S[1] = '''') and (S[Length(S)] = ''''))) then
  begin
    AWasQuoted := True;
    Result := Copy(S, 2, Length(S) - 2);
  end
  else if (Length(S) >= 1) and ((S[1] = '"') or (S[1] = '''')) then
  begin
    AWasQuoted := True;
    Result := Copy(S, 2, MaxInt);
  end
  else
    Result := S;
end;

var
  GLineParserOptions: IYAMLParserOptions;

function LineParserOptions: IYAMLParserOptions;
begin
  if GLineParserOptions = nil then
  begin
    GLineParserOptions := TYAML.CreateParserOptions;
    GLineParserOptions.RecordPositions := True;
    GLineParserOptions.YAML11Compatibility := False;
  end;
  Result := GLineParserOptions;
end;

{ Parses one source line with VSoft.YAML. A line that is still being typed is usually not valid
  on its own (an unclosed quote or bracket), so closing characters are appended until it parses;
  they only extend the line, so every recorded position still refers to the original text. }
function LoadYamlLine(const ARaw: string; ALeadingBytes: Integer; out ADoc: IYAMLDocument): Boolean;
const
  Suffixes: array[0..8] of UnicodeString = ('', '"', '''', ']', '}', '"]', ''']', '"}', '''}');
var
  Work: string;
  I: Integer;
begin
  Result := False;
  ADoc := nil;
  Work := ARaw;
  for I := 1 to ALeadingBytes do
    if Work[I] = #9 then
      Work[I] := ' ';
  for I := Low(Suffixes) to High(Suffixes) do
  begin
    try
      ADoc := TYAML.LoadFromString(UTF8Decode(Work) + Suffixes[I], LineParserOptions);
      Exit(ADoc <> nil);
    except
      ADoc := nil;
    end;
  end;
end;

{ Reads the structure of one line (indentation, comment, "- " item, key, colon and value) from
  the positions VSoft.YAML records while parsing it. All fields are 1-based UTF-8 byte indexes. }
function ReadYamlLine(const ARaw: string): TYamlLogicalLine;
var
  Len, Lead, I, ContentEnd, StartByte, StopByte: Integer;
  Doc: IYAMLDocument;
  Root, Val: IYAMLValue;
  Map: IYAMLMapping;
  Seq: IYAMLSequence;
  DummyQuoted: Boolean;

  function ByteOf(const APos: TYAMLPosition): Integer;
  begin
    Result := Utf16ColToByteIndex(ARaw, APos.Index);
    if Result < 1 then
      Result := 1;
    if Result > Len + 1 then
      Result := Len + 1;
  end;

begin
  Result := Default(TYamlLogicalLine);
  Len := Length(ARaw);
  if Len = 0 then
  begin
    Result.IsBlank := True;
    Exit;
  end;

  Lead := 0;
  while (Lead < Len) and IsSpaceOrTab(ARaw[Lead + 1]) do
    Inc(Lead);
  Result.EffectiveLen := Len;
  Result.Indent := Lead;
  Result.TrimRightEnd := Len;

  if Lead >= Len then
  begin
    Result.IsBlank := True;
    Result.Indent := Len;
    Exit;
  end;

  if ARaw[Lead + 1] = '#' then
  begin
    Result.IsBlank := True;
    Result.CommentStartByte := Lead + 1;
    Result.EffectiveLen := Lead;
    Result.TrimRightEnd := Lead;
    Exit;
  end;

  Result.IsBlank := True;
  if not LoadYamlLine(ARaw, Lead, Doc) then
    Exit;
  Root := Doc.Root;
  if (Root = nil) or (not Root.HasRange) or Root.Range.IsEmpty then
    Exit;

  Result.IsBlank := False;
  ContentEnd := Len + 1;

  if Root.IsSequence and (ARaw[Lead + 1] = '-') then
  begin
    Seq := Root.AsSequence;
    Result.IsSeqItem := True;
    Result.DashByte := Lead + 1;
    ContentEnd := Result.DashByte + 1;
    if Seq.Count > 0 then
    begin
      Val := Seq.Items[0];
      if Val.HasRange and (not Val.Range.IsEmpty) then
      begin
        Result.SeqValStartByte := ByteOf(Val.Range.Start);
        ContentEnd := ByteOf(Val.Range.Stop);
      end;
    end;
  end
  else if Root.IsMapping and (ARaw[ByteOf(Root.Range.Start)] <> '{') and (Root.AsMapping.Count > 0) then
  begin
    Map := Root.AsMapping;
    Result.KeyName := UTF8Encode(Map.Keys[0]);
    Result.KeyStartByte := ByteOf(Map.GetKeyRange(0).Start);
    Result.KeyEndByte := ByteOf(Map.GetKeyRange(0).Stop) - 1;
    ContentEnd := Result.KeyEndByte + 1;
    I := ContentEnd;
    while (I <= Len) and IsSpaceOrTab(ARaw[I]) do
      Inc(I);
    if (I <= Len) and (ARaw[I] = ':') then
    begin
      Result.HasColon := True;
      Result.ColonByte := I;
      ContentEnd := I + 1;
      Val := Map.Values[Map.Keys[0]];
      if Val.HasRange and (not Val.Range.IsEmpty) then
      begin
        Result.ValStartByte := ByteOf(Val.Range.Start);
        Result.ValEndByte := ByteOf(Val.Range.Stop) - 1;
        ContentEnd := Result.ValEndByte + 1;
      end;
    end;
  end
  else
  begin
    StartByte := ByteOf(Root.Range.Start);
    StopByte := ByteOf(Root.Range.Stop) - 1;
    Result.KeyStartByte := StartByte;
    Result.KeyEndByte := StopByte;
    ContentEnd := StopByte + 1;
  end;

  // What follows the last token of a parsed line is blanks and an optional comment.
  for I := ContentEnd to Len do
    if (ARaw[I] = '#') and ((I = 1) or IsSpaceOrTab(ARaw[I - 1])) then
    begin
      Result.CommentStartByte := I;
      Break;
    end;
  if Result.CommentStartByte > 0 then
    Result.EffectiveLen := Result.CommentStartByte - 1;
  Result.TrimRightEnd := Result.EffectiveLen;
  while (Result.TrimRightEnd > Result.Indent) and IsSpaceOrTab(ARaw[Result.TrimRightEnd]) do
    Dec(Result.TrimRightEnd);

  // Characters appended to repair the line are not part of it.
  if Result.KeyEndByte > Result.TrimRightEnd then
    Result.KeyEndByte := Result.TrimRightEnd;
  if Result.ValEndByte > Result.TrimRightEnd then
    Result.ValEndByte := Result.TrimRightEnd;
  if (Result.ValStartByte > Result.TrimRightEnd) or (Result.ValEndByte < Result.ValStartByte) then
  begin
    Result.ValStartByte := 0;
    Result.ValEndByte := 0;
  end;
  if (Result.SeqValStartByte > Result.TrimRightEnd) then
    Result.SeqValStartByte := 0;

  if (not Result.IsSeqItem) and (not Result.HasColon) and (Result.KeyEndByte >= Result.KeyStartByte) then
    Result.KeyName := StripQuotes(
      Copy(ARaw, Result.KeyStartByte, Result.KeyEndByte - Result.KeyStartByte + 1), DummyQuoted);
end;

function IsSequenceFieldKey(const AKey: string): Boolean;
begin
  Result :=
    (AKey = 'authors') or
    (AKey = 'modeSwitches') or
    (AKey = 'unitPaths') or
    (AKey = 'includePaths') or
    (AKey = 'libraryPaths') or
    (AKey = 'objectPaths') or
    (AKey = 'resourcePaths') or
    (AKey = 'defines') or
    (AKey = 'undefines') or
    (AKey = 'checks') or
    (AKey = 'suppress') or
    (AKey = 'linkLibraries') or
    (AKey = 'linkerArgs') or
    (AKey = 'fpcArgs');
end;

function IsAdditiveOverlayListField(const ACanonicalField: string): Boolean;
begin
  Result :=
    (ACanonicalField = 'build.modeSwitches') or
    (ACanonicalField = 'build.unitPaths') or
    (ACanonicalField = 'build.includePaths') or
    (ACanonicalField = 'build.libraryPaths') or
    (ACanonicalField = 'build.objectPaths') or
    (ACanonicalField = 'build.resourcePaths') or
    (ACanonicalField = 'build.defines') or
    (ACanonicalField = 'build.undefines') or
    (ACanonicalField = 'build.checks') or
    (ACanonicalField = 'warnings.suppress') or
    (ACanonicalField = 'build.linkLibraries') or
    (ACanonicalField = 'build.linkerArgs') or
    (ACanonicalField = 'build.fpcArgs');
end;

function IsEntryFileField(const ACanonicalField: string): Boolean;
begin
  Result :=
    (ACanonicalField = 'artifact.entry') or
    (ACanonicalField = 'subOverlay.entry');
end;

function IsDirectoryListField(const ACanonicalField: string): Boolean;
begin
  Result :=
    (ACanonicalField = 'build.unitPaths') or
    (ACanonicalField = 'build.includePaths') or
    (ACanonicalField = 'build.libraryPaths') or
    (ACanonicalField = 'build.objectPaths') or
    (ACanonicalField = 'build.resourcePaths');
end;

function IsMappingOnlyScopeAndKey(const ACanonicalParent, AKey: string): Boolean;
begin
  if (ACanonicalParent = 'root') and
     ((AKey = 'program') or (AKey = 'library') or (AKey = 'package') or (AKey = 'template')) then
    Exit(True);
  if ((ACanonicalParent = 'artifact') or (ACanonicalParent = 'test') or (ACanonicalParent = 'subOverlay')) and
     ((AKey = 'toolchain') or (AKey = 'build') or (AKey = 'dependencies') or
      (AKey = 'test') or (AKey = 'targets') or (AKey = 'profiles')) then
    Exit(True);
  if (ACanonicalParent = 'build') and (AKey = 'warnings') then
    Exit(True);
  if (ACanonicalParent = 'targets') or (ACanonicalParent = 'profiles') then
    Exit(True);
  Result := False;
end;

procedure SplitDotSegments(const APath: string; out ASegs: TStringArray);
var
  StartIdx, I, Count: Integer;
begin
  ASegs := nil;
  if APath = '' then
    Exit;
  Count := 0;
  StartIdx := 1;
  for I := 1 to Length(APath) do
    if APath[I] = '.' then
    begin
      SetLength(ASegs, Count + 1);
      ASegs[Count] := Copy(APath, StartIdx, I - StartIdx);
      Inc(Count);
      StartIdx := I + 1;
    end;
  SetLength(ASegs, Count + 1);
  ASegs[Count] := Copy(APath, StartIdx, MaxInt);
end;

procedure ClassifyManifestScope(const AParentPath: string;
  out ARootArtifact, ACanonicalParent: string; out AIsOverlay: Boolean);
var
  Segs: TStringArray;
  Idx, Rem: Integer;
begin
  ARootArtifact := '';
  ACanonicalParent := '';
  AIsOverlay := False;

  if AParentPath = '' then
  begin
    ACanonicalParent := 'root';
    Exit;
  end;

  SplitDotSegments(AParentPath, Segs);
  if Length(Segs) = 0 then
  begin
    ACanonicalParent := 'root';
    Exit;
  end;

  if (Segs[0] <> 'program') and (Segs[0] <> 'library') and
     (Segs[0] <> 'package') and (Segs[0] <> 'template') then
    Exit;

  ARootArtifact := Segs[0];
  if Length(Segs) = 1 then
  begin
    ACanonicalParent := 'artifact';
    Exit;
  end;

  Idx := 1;
  if Segs[1] = 'test' then
  begin
    AIsOverlay := True;
    if Length(Segs) = 2 then
    begin
      ACanonicalParent := 'test';
      Exit;
    end;
    Idx := 2;
  end
  else if (Segs[1] = 'targets') or (Segs[1] = 'profiles') then
  begin
    AIsOverlay := True;
    if Length(Segs) = 2 then
    begin
      ACanonicalParent := Segs[1];
      Exit;
    end;
    if Length(Segs) = 3 then
    begin
      ACanonicalParent := 'subOverlay';
      Exit;
    end;
    Idx := 3;
  end;

  Rem := Length(Segs) - Idx;
  if Rem = 1 then
  begin
    if Segs[Idx] = 'toolchain' then
      ACanonicalParent := 'toolchain'
    else if Segs[Idx] = 'build' then
      ACanonicalParent := 'build'
    else if Segs[Idx] = 'dependencies' then
      ACanonicalParent := 'dependencies'
    else if IsSequenceFieldKey(Segs[Idx]) then
      ACanonicalParent := 'artifact.' + Segs[Idx];
  end
  else if Rem = 2 then
  begin
    if (Segs[Idx] = 'build') and (Segs[Idx + 1] = 'warnings') then
      ACanonicalParent := 'warnings'
    else if (Segs[Idx] = 'build') and IsSequenceFieldKey(Segs[Idx + 1]) then
      ACanonicalParent := 'build.' + Segs[Idx + 1]
    else if Segs[Idx] = 'dependencies' then
      ACanonicalParent := 'depMapping';
  end
  else if Rem = 3 then
  begin
    if (Segs[Idx] = 'build') and (Segs[Idx + 1] = 'warnings') and (Segs[Idx + 2] = 'suppress') then
      ACanonicalParent := 'warnings.suppress'
    else if (Segs[Idx] = 'dependencies') and
            ((Segs[Idx + 2] = 'unitPaths') or (Segs[Idx + 2] = 'includePaths')) then
      ACanonicalParent := 'depMapping.' + Segs[Idx + 2];
  end;
end;

function MakeCanonicalField(const ACanonicalParent, AKey: string): string;
begin
  if ACanonicalParent = '' then
    Exit('');
  if (Pos('.', ACanonicalParent) > 0) and (AKey = '') then
    Exit(ACanonicalParent);
  if AKey = '' then
    Exit(ACanonicalParent);
  Result := ACanonicalParent + '.' + AKey;
end;

function MakeLineRange(ALine: Integer; const ALineUtf8: string; AStartByte, AEndByteExclusive: Integer): TLspRange;
var
  StartCol, EndCol: Integer;
begin
  if AStartByte < 1 then
    AStartByte := 1;
  if AEndByteExclusive < AStartByte then
    AEndByteExclusive := AStartByte;
  StartCol := ByteIndexToUtf16Col(ALineUtf8, AStartByte);
  EndCol := ByteIndexToUtf16Col(ALineUtf8, AEndByteExclusive);
  Result := TLspRange.SingleLine(ALine, StartCol, EndCol);
end;

procedure ExtractTokenBoundsAndQuotes(const ALineUtf8: string; ALine, ARawStartByte, ARawEndByte, ACursorByte: Integer;
  out ATokenText: string; out AIsQuoted: Boolean; out ATokenRange, AReplaceRange: TLspRange);
var
  SByte, EByte: Integer;
begin
  AIsQuoted := False;
  SByte := ARawStartByte;
  EByte := ARawEndByte;
  while (SByte <= EByte) and IsSpaceOrTab(ALineUtf8[SByte]) do
    Inc(SByte);
  while (EByte >= SByte) and IsSpaceOrTab(ALineUtf8[EByte]) do
    Dec(EByte);

  if SByte > EByte then
  begin
    ATokenText := '';
    ATokenRange := MakeLineRange(ALine, ALineUtf8, ACursorByte, ACursorByte);
    AReplaceRange := ATokenRange;
    Exit;
  end;

  if (ALineUtf8[SByte] = '"') or (ALineUtf8[SByte] = '''') then
  begin
    AIsQuoted := True;
    if (EByte > SByte) and (ALineUtf8[EByte] = ALineUtf8[SByte]) then
    begin
      ATokenText := Copy(ALineUtf8, SByte + 1, EByte - SByte - 1);
      ATokenRange := MakeLineRange(ALine, ALineUtf8, SByte + 1, EByte);
      AReplaceRange := ATokenRange;
    end
    else
    begin
      ATokenText := Copy(ALineUtf8, SByte + 1, EByte - SByte);
      ATokenRange := MakeLineRange(ALine, ALineUtf8, SByte + 1, EByte + 1);
      AReplaceRange := ATokenRange;
    end;
  end
  else
  begin
    ATokenText := Copy(ALineUtf8, SByte, EByte - SByte + 1);
    ATokenRange := MakeLineRange(ALine, ALineUtf8, SByte, EByte + 1);
    AReplaceRange := ATokenRange;
  end;
end;

function TryCheckInlineBracketList(const ALineUtf8: string; ALine, AValStartByte, AEffectiveLen, ACursorByte: Integer;
  out ATokenText: string; out AIsQuoted, AIsFirstElem, ARightAfterDelim: Boolean;
  out ATokenRange, AReplaceRange: TLspRange): Boolean;
var
  I, OpenBracket, CloseBracket, SegStart, SegEnd, ItemIdx: Integer;
  InSingle, InDouble: Boolean;
begin
  Result := False;
  AIsQuoted := False;
  AIsFirstElem := True;
  ARightAfterDelim := False;
  if (AValStartByte <= 0) or (AValStartByte > AEffectiveLen) then
    Exit;
  if ALineUtf8[AValStartByte] <> '[' then
    Exit;

  OpenBracket := AValStartByte;
  if ACursorByte <= OpenBracket then
    Exit;

  CloseBracket := 0;
  InSingle := False;
  InDouble := False;
  for I := OpenBracket + 1 to AEffectiveLen do
  begin
    if InSingle then
    begin
      if ALineUtf8[I] = '''' then InSingle := False;
    end
    else if InDouble then
    begin
      if (ALineUtf8[I] = '\') and (I + 1 <= AEffectiveLen) then
        Continue;
      if ALineUtf8[I] = '"' then InDouble := False;
    end
    else
    begin
      if ALineUtf8[I] = '''' then InSingle := True
      else if ALineUtf8[I] = '"' then InDouble := True
      else if ALineUtf8[I] = ']' then
      begin
        CloseBracket := I;
        Break;
      end;
    end;
  end;

  if (CloseBracket > 0) and (ACursorByte > CloseBracket) then
    Exit;

  Result := True;
  SegStart := OpenBracket + 1;
  if CloseBracket > 0 then
    SegEnd := CloseBracket - 1
  else
    SegEnd := AEffectiveLen;

  // Split by unquoted ',' to find the segment containing ACursorByte
  ItemIdx := 0;
  InSingle := False;
  InDouble := False;
  for I := OpenBracket + 1 to SegEnd do
  begin
    if InSingle then
    begin
      if ALineUtf8[I] = '''' then InSingle := False;
    end
    else if InDouble then
    begin
      if ALineUtf8[I] = '"' then InDouble := False;
    end
    else
    begin
      if ALineUtf8[I] = '''' then InSingle := True
      else if ALineUtf8[I] = '"' then InDouble := True
      else if ALineUtf8[I] = ',' then
      begin
        if ACursorByte <= I then
        begin
          SegEnd := I - 1;
          Break;
        end;
        SegStart := I + 1;
        Inc(ItemIdx);
      end;
    end;
  end;

  AIsFirstElem := (ItemIdx = 0);
  I := ACursorByte - 1;
  while (I >= SegStart) and IsSpaceOrTab(ALineUtf8[I]) do
    Dec(I);
  if (I < SegStart) and (SegStart > OpenBracket + 1) then
    ARightAfterDelim := True;

  ExtractTokenBoundsAndQuotes(ALineUtf8, ALine, SegStart, SegEnd, ACursorByte,
    ATokenText, AIsQuoted, ATokenRange, AReplaceRange);
end;

procedure CollectSiblingKeysInMapping(ADoc: TLspDocument; AParentLine, ACursorLine, ATargetIndent: Integer;
  out AKeys: TStringArray);
var
  StartLine, L, Count, I: Integer;
  Parsed: TYamlLogicalLine;
  Exists: Boolean;
begin
  AKeys := nil;
  Count := 0;
  if AParentLine >= 0 then
    StartLine := AParentLine + 1
  else
    StartLine := 0;

  for L := StartLine to ADoc.LineCount - 1 do
  begin
    if L = ACursorLine then
      Continue;
    Parsed := ReadYamlLine(ADoc.GetLineText(L));
    if Parsed.IsBlank then
      Continue;
    if (AParentLine >= 0) and (Parsed.Indent < ATargetIndent) then
      Break;
    if (Parsed.Indent = ATargetIndent) and Parsed.HasColon and (Parsed.KeyName <> '') then
    begin
      Exists := False;
      for I := 0 to Count - 1 do
        if AKeys[I] = Parsed.KeyName then
        begin
          Exists := True;
          Break;
        end;
      if not Exists then
      begin
        SetLength(AKeys, Count + 1);
        AKeys[Count] := Parsed.KeyName;
        Inc(Count);
      end;
    end;
  end;
end;

function AnalyzeYamlCursorContext(ADoc: TLspDocument; const APos: TLspPosition): TYamlCursorContext;
var
  Stack: array of TYamlStackEntry;
  StackLen, L, I, CursorByte, EffectiveIndent, ParentLineIdx, CheckIdx: Integer;
  PriorLine, CurLine: TYamlLogicalLine;
  RawCurLine: string;
  DummyQuoted: Boolean;
begin
  Result := Default(TYamlCursorContext);
  if (ADoc = nil) or (APos.Line < 0) or (APos.Line >= ADoc.LineCount) then
    Exit;

  Stack := nil;
  StackLen := 0;
  for L := 0 to APos.Line - 1 do
  begin
    PriorLine := ReadYamlLine(ADoc.GetLineText(L));
    if PriorLine.IsBlank or PriorLine.IsSeqItem then
      Continue;
    if PriorLine.HasColon and (PriorLine.KeyName <> '') then
    begin
      while (StackLen > 0) and (Stack[StackLen - 1].Indent >= PriorLine.Indent) do
        Dec(StackLen);
      SetLength(Stack, StackLen + 1);
      Stack[StackLen].Indent := PriorLine.Indent;
      Stack[StackLen].KeyName := PriorLine.KeyName;
      Stack[StackLen].LineIndex := L;
      Inc(StackLen);
    end;
  end;

  RawCurLine := ADoc.GetLineText(APos.Line);
  CurLine := ReadYamlLine(RawCurLine);
  CursorByte := Utf16ColToByteIndex(RawCurLine, APos.Character);

  if (CurLine.CommentStartByte > 0) and (CursorByte > CurLine.CommentStartByte) then
  begin
    Result.InComment := True;
    Exit;
  end;

  if CurLine.IsBlank then
  begin
    EffectiveIndent := CursorByte - 1;
    if EffectiveIndent < 0 then
      EffectiveIndent := 0;
    while (StackLen > 0) and (Stack[StackLen - 1].Indent >= EffectiveIndent) do
      Dec(StackLen);
  end
  else if CurLine.IsSeqItem and (CursorByte > CurLine.Indent) then
  begin
    EffectiveIndent := CurLine.Indent;
    while (StackLen > 0) and
          ((Stack[StackLen - 1].Indent > EffectiveIndent) or
           ((Stack[StackLen - 1].Indent = EffectiveIndent) and (not IsSequenceFieldKey(Stack[StackLen - 1].KeyName)))) do
      Dec(StackLen);
  end
  else if CursorByte <= CurLine.Indent then
  begin
    EffectiveIndent := CursorByte - 1;
    if EffectiveIndent < 0 then
      EffectiveIndent := 0;
    while (StackLen > 0) and (Stack[StackLen - 1].Indent >= EffectiveIndent) do
      Dec(StackLen);
  end
  else
  begin
    EffectiveIndent := CurLine.Indent;
    while (StackLen > 0) and (Stack[StackLen - 1].Indent >= EffectiveIndent) do
      Dec(StackLen);
  end;

  Result.ParentPath := '';
  for I := 0 to StackLen - 1 do
  begin
    if Result.ParentPath = '' then
      Result.ParentPath := Stack[I].KeyName
    else
      Result.ParentPath := Result.ParentPath + '.' + Stack[I].KeyName;
  end;
  if StackLen > 0 then
    ParentLineIdx := Stack[StackLen - 1].LineIndex
  else
    ParentLineIdx := -1;

  ClassifyManifestScope(Result.ParentPath, Result.RootArtifact, Result.CanonicalParent, Result.IsOverlay);
  if Result.CanonicalParent = '' then
    Exit;

  Result.Valid := True;

  if CurLine.IsSeqItem and (CursorByte > CurLine.Indent) then
  begin
    Result.Role := ycrSeqItem;
    Result.CanonicalField := MakeCanonicalField(Result.CanonicalParent, '');

    Result.IsFirstListElement := True;
    if ParentLineIdx >= 0 then
      for L := ParentLineIdx + 1 to APos.Line - 1 do
      begin
        PriorLine := ReadYamlLine(ADoc.GetLineText(L));
        if PriorLine.IsSeqItem then
        begin
          Result.IsFirstListElement := False;
          Break;
        end;
      end;

    CheckIdx := CursorByte - 1;
    while (CheckIdx > CurLine.DashByte) and IsSpaceOrTab(RawCurLine[CheckIdx]) do
      Dec(CheckIdx);
    Result.TriggeredRightAfterDelim := (CheckIdx = CurLine.DashByte) and (CursorByte > CurLine.DashByte + 1);

    if CurLine.SeqValStartByte > 0 then
      ExtractTokenBoundsAndQuotes(RawCurLine, APos.Line, CurLine.SeqValStartByte, CurLine.TrimRightEnd, CursorByte,
        Result.TokenText, Result.IsQuotedToken, Result.TokenRange, Result.ReplaceRange)
    else
    begin
      Result.TokenText := '';
      Result.TokenRange := MakeLineRange(APos.Line, RawCurLine, CursorByte, CursorByte);
      Result.ReplaceRange := Result.TokenRange;
    end;
    Exit;
  end;

  if (not CurLine.IsBlank) and (CursorByte > CurLine.Indent) and CurLine.HasColon then
  begin
    Result.CurrentKey := CurLine.KeyName;
    Result.HasColonOnLine := True;
    if CurLine.ValStartByte > 0 then
      Result.InlineScalarValue := StripQuotes(
        Copy(RawCurLine, CurLine.ValStartByte, CurLine.ValEndByte - CurLine.ValStartByte + 1), DummyQuoted);

    if CursorByte <= CurLine.ColonByte then
    begin
      Result.Role := ycrKey;
      Result.CanonicalField := MakeCanonicalField(Result.CanonicalParent, Result.CurrentKey);
      ExtractTokenBoundsAndQuotes(RawCurLine, APos.Line, CurLine.KeyStartByte, CurLine.KeyEndByte, CursorByte,
        Result.TokenText, Result.IsQuotedToken, Result.TokenRange, Result.ReplaceRange);
      CollectSiblingKeysInMapping(ADoc, ParentLineIdx, APos.Line, EffectiveIndent, Result.ExistingKeys);
    end
    else
    begin
      Result.CanonicalField := MakeCanonicalField(Result.CanonicalParent, Result.CurrentKey);
      if TryCheckInlineBracketList(RawCurLine, APos.Line, CurLine.ValStartByte, CurLine.EffectiveLen, CursorByte,
           Result.TokenText, Result.IsQuotedToken, Result.IsFirstListElement, Result.TriggeredRightAfterDelim,
           Result.TokenRange, Result.ReplaceRange) then
      begin
        Result.Role := ycrSeqItem;
        Exit;
      end;

      if IsMappingOnlyScopeAndKey(Result.CanonicalParent, Result.CurrentKey) then
      begin
        Result.Role := ycrNone;
        Exit;
      end;

      Result.Role := ycrScalarValue;
      CheckIdx := CursorByte - 1;
      while (CheckIdx > CurLine.ColonByte) and IsSpaceOrTab(RawCurLine[CheckIdx]) do
        Dec(CheckIdx);
      Result.TriggeredRightAfterDelim := (CheckIdx = CurLine.ColonByte) and (CursorByte > CurLine.ColonByte + 1);

      if CurLine.ValStartByte > 0 then
        ExtractTokenBoundsAndQuotes(RawCurLine, APos.Line, CurLine.ValStartByte, CurLine.ValEndByte, CursorByte,
          Result.TokenText, Result.IsQuotedToken, Result.TokenRange, Result.ReplaceRange)
      else
      begin
        Result.TokenText := '';
        Result.TokenRange := MakeLineRange(APos.Line, RawCurLine, CursorByte, CursorByte);
        Result.ReplaceRange := Result.TokenRange;
      end;
    end;
    Exit;
  end;

  if (Pos('.', Result.CanonicalParent) > 0) then
  begin
    Result.Valid := False;
    Exit;
  end;

  Result.Role := ycrKey;
  Result.HasColonOnLine := False;
  if (not CurLine.IsBlank) and (CursorByte > CurLine.Indent) then
  begin
    Result.CurrentKey := CurLine.KeyName;
    Result.CanonicalField := MakeCanonicalField(Result.CanonicalParent, Result.CurrentKey);
    ExtractTokenBoundsAndQuotes(RawCurLine, APos.Line, CurLine.KeyStartByte, CurLine.KeyEndByte, CursorByte,
      Result.TokenText, Result.IsQuotedToken, Result.TokenRange, Result.ReplaceRange);
  end
  else
  begin
    Result.CurrentKey := '';
    Result.CanonicalField := Result.CanonicalParent;
    Result.TokenText := '';
    Result.TokenRange := MakeLineRange(APos.Line, RawCurLine, CursorByte, CursorByte);
    Result.ReplaceRange := Result.TokenRange;
  end;
  CollectSiblingKeysInMapping(ADoc, ParentLineIdx, APos.Line, EffectiveIndent, Result.ExistingKeys);
end;

{ ---------------------------------------------------------------------------
  Dynamic SDK Discovery & Status Helpers (Step 2)
  --------------------------------------------------------------------------- }

function ExtractConfiguredToolchainTarget(ADoc: TLspDocument): string;
var
  L: Integer;
  Parsed: TYamlLogicalLine;
  RawLine, Val: string;
  InToolchain: Boolean;
  ToolchainIndent: Integer;
  DummyQuoted: Boolean;
begin
  Result := '';
  if ADoc = nil then
    Exit;

  InToolchain := False;
  ToolchainIndent := 0;
  for L := 0 to ADoc.LineCount - 1 do
  begin
    RawLine := ADoc.GetLineText(L);
    Parsed := ReadYamlLine(RawLine);
    if Parsed.IsBlank or Parsed.IsSeqItem then
      Continue;
    if InToolchain and (Parsed.Indent <= ToolchainIndent) then
      InToolchain := False;

    if Parsed.HasColon and (Parsed.KeyName = 'toolchain') and (Parsed.ValStartByte = 0) then
    begin
      InToolchain := True;
      ToolchainIndent := Parsed.Indent;
    end
    else if InToolchain and Parsed.HasColon and (Parsed.KeyName = 'target') and (Parsed.ValStartByte > 0) then
    begin
      Val := LowerCase(Trim(StripQuotes(
        Copy(RawLine, Parsed.ValStartByte, Parsed.ValEndByte - Parsed.ValStartByte + 1), DummyQuoted)));
      if (Val <> '') and (Val <> 'native') then
        Exit(Val);
    end;
  end;
end;

function MatchesTargetOrHost(const ATargetOs, ATargetCpu, ATargetTriplet, AExplicitTriplet: string): Boolean;
begin
  if AExplicitTriplet <> '' then
    Exit(SameText(ATargetTriplet, AExplicitTriplet));

  if not SameText(ATargetOs, GetHostOs) then
    Exit(False);
  if SameText(ATargetCpu, GetHostCpu) then
    Exit(True);
  // Windows ARM64 can transparently run x86_64-win64 SDKs when native ARM64 is absent
  if SameText(GetHostOs, 'win64') and SameText(GetHostCpu, 'aarch64') and SameText(ATargetCpu, 'x86_64') then
    Exit(True);
  Result := False;
end;

function ParseVerSortTuple(const AVer: string; out AMaj, AMin, APat: Integer): Boolean;
var
  D1, D2, E1, E2, E3: Integer;
  Rest: string;
begin
  Result := False;
  AMaj := 0;
  AMin := 0;
  APat := 0;
  D1 := Pos('.', AVer);
  if D1 <= 1 then Exit;
  Rest := Copy(AVer, D1 + 1, MaxInt);
  D2 := Pos('.', Rest);
  if D2 <= 1 then Exit;
  Val(Copy(AVer, 1, D1 - 1), AMaj, E1);
  Val(Copy(Rest, 1, D2 - 1), AMin, E2);
  Val(Copy(Rest, D2 + 1, MaxInt), APat, E3);
  Result := (E1 = 0) and (E2 = 0) and (E3 = 0);
end;

function CompareSdkCandidates(const A, B: TSdkVersionCandidate): Integer;
var
  MajA, MinA, PatA, MajB, MinB, PatB: Integer;
begin
  // Prefer locally installed SDKs first so immediate offline-ready toolchains sit at the top
  if A.HasInstalled <> B.HasInstalled then
  begin
    if A.HasInstalled then
      Exit(-1)
    else
      Exit(1);
  end;

  if ParseVerSortTuple(A.Version, MajA, MinA, PatA) and
     ParseVerSortTuple(B.Version, MajB, MinB, PatB) then
  begin
    if MajA <> MajB then Exit(MajB - MajA);
    if MinA <> MinB then Exit(MinB - MinA);
    if PatA <> PatB then Exit(PatB - PatA);
  end;
  Result := CompareText(B.Version, A.Version);
end;

function FindOrAddSdkVersionCandidate(var ACands: TSdkVersionCandidateArray; const AVer: string): Integer;
var
  K: Integer;
begin
  for K := 0 to High(ACands) do
    if SameText(ACands[K].Version, AVer) then
      Exit(K);
  Result := Length(ACands);
  SetLength(ACands, Result + 1);
  ACands[Result] := Default(TSdkVersionCandidate);
  ACands[Result].Version := AVer;
end;

function CollectSdkVersionCandidates(ADoc: TLspDocument): TSdkVersionCandidateArray;
const
  FALLBACK_VERSIONS: array[0..2] of string = ('3.3.1', '3.2.4', '3.2.2');
var
  ExplicitTarget: string;
  InstalledList: TInstalledSdkArray;
  RemoteIdx: TSdkIndex;
  HasRemote, DummyNeedsRefresh, UpdAvail: Boolean;
  I, J, Idx: Integer;
  MatchedInst: TInstalledSdk;
  Tmp: TSdkVersionCandidate;
begin
  Result := nil;
  ExplicitTarget := ExtractConfiguredToolchainTarget(ADoc);
  if ExplicitTarget = 'x86_64-windows' then ExplicitTarget := 'x86_64-win64'
  else if ExplicitTarget = 'aarch64-windows' then ExplicitTarget := 'aarch64-win64'
  else if ExplicitTarget = 'x86_64-macos' then ExplicitTarget := 'x86_64-darwin'
  else if ExplicitTarget = 'aarch64-macos' then ExplicitTarget := 'aarch64-darwin';

  InstalledList := ListInstalledSdks;
  HasRemote := TryLoadAvailableSdkIndexForLsp(RemoteIdx, DummyNeedsRefresh);

  // 1. Installed SDKs matching target/host
  for I := 0 to High(InstalledList) do
  begin
    if not IsExactFpcVersion(InstalledList[I].Manifest.FpcVersion) then
      Continue;
    if not MatchesTargetOrHost(
         InstalledList[I].Manifest.TargetOs,
         InstalledList[I].Manifest.TargetCpu,
         InstalledList[I].Manifest.TargetTriplet,
         ExplicitTarget) then
      Continue;

    Idx := FindOrAddSdkVersionCandidate(Result, InstalledList[I].Manifest.FpcVersion);
    // Prefer exact host CPU match over ARM64->x64 fallback
    if (not Result[Idx].HasInstalled) or
       SameText(InstalledList[I].Manifest.TargetCpu, GetHostCpu) then
    begin
      Result[Idx].HasInstalled := True;
      Result[Idx].Installed := InstalledList[I];
    end;
  end;

  // 2. Remote/cached index SDKs matching target/host (or any target if none match host)
  if HasRemote then
  begin
    for I := 0 to High(RemoteIdx.Sdks) do
    begin
      if not IsExactFpcVersion(RemoteIdx.Sdks[I].FpcVersion) then
        Continue;
      if not MatchesTargetOrHost(
           RemoteIdx.Sdks[I].TargetOs,
           RemoteIdx.Sdks[I].TargetCpu,
           RemoteIdx.Sdks[I].TargetTriplet,
           ExplicitTarget) then
        Continue;

      Idx := FindOrAddSdkVersionCandidate(Result, RemoteIdx.Sdks[I].FpcVersion);
      if (not Result[Idx].HasRemote) or
         (SameText(RemoteIdx.Sdks[I].TargetCpu, GetHostCpu) and
          (not SameText(Result[Idx].Remote.TargetCpu, GetHostCpu))) then
      begin
        Result[Idx].HasRemote := True;
        Result[Idx].Remote := RemoteIdx.Sdks[I];
        if MatchRemoteSdkInstallState(InstalledList, RemoteIdx.Sdks[I], MatchedInst, UpdAvail) then
          Result[Idx].UpdateAvailable := UpdAvail;
      end;
    end;
  end;

  // 3. Offline cold-start fallback when neither installed SDKs nor cached index exist yet
  if Length(Result) = 0 then
  begin
    for I := Low(FALLBACK_VERSIONS) to High(FALLBACK_VERSIONS) do
      FindOrAddSdkVersionCandidate(Result, FALLBACK_VERSIONS[I]);
  end;

  // Sort candidates
  for I := 0 to High(Result) - 1 do
    for J := I + 1 to High(Result) do
      if CompareSdkCandidates(Result[J], Result[I]) < 0 then
      begin
        Tmp := Result[I];
        Result[I] := Result[J];
        Result[J] := Tmp;
      end;
end;

function FormatSizeMb(ASizeBytes: Int64): string;
begin
  if ASizeBytes <= 0 then
    Exit('');
  Result := Format('%.1f MB', [ASizeBytes / (1024.0 * 1024.0)]);
end;

function ShortCommitStr(const ACommit: string): string;
begin
  if Length(ACommit) > 8 then
    Result := Copy(ACommit, 1, 8)
  else
    Result := ACommit;
end;

function FormatSdkCandidateHoverSection(const ACand: TSdkVersionCandidate): string;
var
  SizeStr, CommitStr: string;
begin
  if ACand.HasInstalled then
  begin
    Result :=
      '**SDK Status:** Installed locally (`' + ACand.Installed.Manifest.TargetTriplet + '`)' + #10 +
      '- **SDK ID:** `' + ACand.Installed.Manifest.SdkId + '`';
    if ACand.Installed.Manifest.GitCommit <> '' then
      Result := Result + #10 + '- **Compiler commit:** `' + ShortCommitStr(ACand.Installed.Manifest.GitCommit) + '`';
    Result := Result + #10 + '- **Path:** `' + NormalizeForwardSlashes(ACand.Installed.InstallPath) + '`';
    if ACand.UpdateAvailable and ACand.HasRemote then
      Result := Result + #10 + '- **Update available:** `' + ACand.Remote.SdkId + '` (run `nik sdk update ' + ACand.Version + '`)';
  end
  else if ACand.HasRemote then
  begin
    SizeStr := FormatSizeMb(ACand.Remote.SizeBytes);
    CommitStr := ShortCommitStr(ACand.Remote.GitCommit);
    Result :=
      '**SDK Status:** Available online (`' + ACand.Remote.TargetTriplet + '`, not yet installed locally)' + #10 +
      '- **Remote SDK:** `' + ACand.Remote.SdkId + '`';
    if CommitStr <> '' then
      Result := Result + ' (`' + CommitStr + '`)';
    if SizeStr <> '' then
      Result := Result + ' â€” ' + SizeStr;
    Result := Result + #10 + '- **Provisioning:** Installed automatically on `nik build`, or via `nik sdk install ' + ACand.Version + '`.';
  end
  else
    Result :=
      '**SDK Status:** Not installed locally (`~/.nikrun/sdks/`).' + #10 +
      '- Run `nik sdk install ' + ACand.Version + '` or `nik build` to download and verify this SDK.';
end;

function DescribeSdkVersionForHover(ADoc: TLspDocument; const AVersion: string): string;
var
  Cands: TSdkVersionCandidateArray;
  I: Integer;
  FallbackCand: TSdkVersionCandidate;
begin
  Result := '';
  if not IsExactFpcVersion(AVersion) then
    Exit;
  Cands := CollectSdkVersionCandidates(ADoc);
  for I := 0 to High(Cands) do
    if SameText(Cands[I].Version, AVersion) then
      Exit(FormatSdkCandidateHoverSection(Cands[I]));

  FallbackCand := Default(TSdkVersionCandidate);
  FallbackCand.Version := AVersion;
  Result := FormatSdkCandidateHoverSection(FallbackCand);
end;

{ ---------------------------------------------------------------------------
  Dependency & Path Resolution Helpers (Step 2)
  --------------------------------------------------------------------------- }

function ExtractUrlBaseBeforeAt(const ARawSpec: string): string;
var
  SchemePos, SlashPos, I: Integer;
begin
  Result := Trim(ARawSpec);
  SchemePos := Pos('://', Result);
  if SchemePos <= 0 then
    Exit('');
  SlashPos := Pos('/', Copy(Result, SchemePos + 3, MaxInt));
  if SlashPos <= 0 then
    Exit(Result);
  for I := Length(Result) downto SchemePos + 2 + SlashPos + 1 do
    if Result[I] = '@' then
      Exit(Copy(Result, 1, I - 1));
end;

function DescribeDependencyLockStatus(const AManifestPath, ADepKey, AInlineScalar: string;
  ADoc: TLspDocument; AKeyLine: Integer): string;
var
  ProjDir, TargetUrl, TargetPath, ResolvedLocal, SubLineRaw: string;
  Lock: TLockFile;
  I, L, KeyIndent: Integer;
  Parsed: TYamlLogicalLine;
  DummyQuoted: Boolean;
begin
  Result := '';
  if AManifestPath = '' then
    Exit;
  ProjDir := ExtractFileDir(AManifestPath);
  if ProjDir = '' then
    Exit;

  TargetUrl := '';
  TargetPath := '';
  if AInlineScalar <> '' then
  begin
    if (Pos('://', AInlineScalar) > 0) then
      TargetUrl := ExtractUrlBaseBeforeAt(AInlineScalar)
    else
      TargetPath := AInlineScalar;
  end
  else if (ADoc <> nil) and (AKeyLine >= 0) and (AKeyLine < ADoc.LineCount) then
  begin
    KeyIndent := ReadYamlLine(ADoc.GetLineText(AKeyLine)).Indent;
    for L := AKeyLine + 1 to ADoc.LineCount - 1 do
    begin
      SubLineRaw := ADoc.GetLineText(L);
      Parsed := ReadYamlLine(SubLineRaw);
      if Parsed.IsBlank then
        Continue;
      if Parsed.Indent <= KeyIndent then
        Break;
      if Parsed.HasColon and (Parsed.ValStartByte > 0) then
      begin
        if Parsed.KeyName = 'url' then
          TargetUrl := StripQuotes(Copy(SubLineRaw, Parsed.ValStartByte, Parsed.ValEndByte - Parsed.ValStartByte + 1), DummyQuoted)
        else if Parsed.KeyName = 'path' then
          TargetPath := StripQuotes(Copy(SubLineRaw, Parsed.ValStartByte, Parsed.ValEndByte - Parsed.ValStartByte + 1), DummyQuoted);
      end;
    end;
  end;

  if TargetPath <> '' then
  begin
    ResolvedLocal := ResolveRelativePath(ProjDir, TargetPath);
    if DirectoryExists(ResolvedLocal) or FileExists(ResolvedLocal) then
      Result := '- **Local target:** `' + NormalizeForwardSlashes(ResolvedLocal) + '` *(exists)*'
    else
      Result := '- **Local target:** `' + NormalizeForwardSlashes(ResolvedLocal) + '` *(missing on disk)*';
  end;

  try
    Lock := LoadLockFile(ProjDir);
    if Lock.ExistsOnDisk and (TargetUrl <> '') then
    begin
      // Strip trailing .git or / for matching
      while (Length(TargetUrl) > 1) and (TargetUrl[Length(TargetUrl)] = '/') do
        Delete(TargetUrl, Length(TargetUrl), 1);
      if (Length(TargetUrl) > 4) and SameText(Copy(TargetUrl, Length(TargetUrl) - 3, 4), '.git') then
        Delete(TargetUrl, Length(TargetUrl) - 3, 4);

      for I := 0 to High(Lock.Packages) do
        if SameText(Lock.Packages[I].Url, TargetUrl) then
        begin
          if Result <> '' then
            Result := Result + #10;
          if Lock.Packages[I].Version <> '' then
            Result := Result + '- **Locked (`nik.lock`):** `' + Lock.Packages[I].Version + '`'
          else
            Result := Result + '- **Locked (`nik.lock`):**';
          if Lock.Packages[I].Rev <> '' then
            Result := Result + ' (`' + ShortCommitStr(Lock.Packages[I].Rev) + '`)';
          if Lock.Packages[I].Integrity <> '' then
            Result := Result + #10 + '- **Integrity:** `' + Copy(Lock.Packages[I].Integrity, 1, 23) + 'â€¦`'
          else if Lock.Packages[I].Sha256 <> '' then
            Result := Result + #10 + '- **SHA-256:** `' + Copy(Lock.Packages[I].Sha256, 1, 16) + 'â€¦`';
          Break;
        end;
    end;
  except
    // Ignore malformed nik.lock during hover
  end;
end;

function ShouldSkipProjectDirName(const AName: string): Boolean;
begin
  Result :=
    (AName = '.') or (AName = '..') or
    ((Length(AName) > 0) and (AName[1] = '.')) or
    SameText(AName, 'node_modules') or
    SameText(AName, 'dist');
end;

function HasPascalEntryExtension(const AFileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  Result := (Ext = '.pas') or (Ext = '.pp') or (Ext = '.lpr') or (Ext = '.dpr');
end;

procedure BuildRelativePathCompletions(const AManifestPath: string; const ACtx: TYamlCursorContext;
  AIncludePascalFiles, AIncludeArchives, ARequireDotPrefix: Boolean;
  var AList: TLspCompletionList);
const
  MAX_PATH_ITEMS = 80;
var
  ProjDir, TypedSlash, DirPrefixSlash, SearchDir, EntryPath, RelCandidate, SubEntryPath: string;
  LastSlash, OutCount, I: Integer;
  Rec, SubRec: TSearchRec;
  IsDir: Boolean;
  Item: TLspCompletionItem;

  procedure AddPathItem(const ARelPath: string; AKind: TLspCompletionItemKind; const ADetail, ASortGroup: string);
  begin
    if OutCount >= MAX_PATH_ITEMS then
      Exit;
    Item := Default(TLspCompletionItem);
    Item.LabelText := ARelPath;
    Item.Kind := AKind;
    Item.Detail := ADetail;
    Item.SortText := ASortGroup + '_' + LowerCase(ARelPath);
    Item.FilterText := ARelPath;
    Item.HasTextEdit := True;
    Item.TextEdit := TLspTextEdit.Create(ACtx.ReplaceRange, ARelPath);
    SetLength(AList.Items, OutCount + 1);
    AList.Items[OutCount] := Item;
    Inc(OutCount);
  end;

begin
  if AManifestPath = '' then
    Exit;
  ProjDir := ExtractFileDir(AManifestPath);
  if (ProjDir = '') or (not DirectoryExists(ProjDir)) then
    Exit;

  TypedSlash := NormalizeForwardSlashes(ACtx.TokenText);
  if ARequireDotPrefix and (TypedSlash <> '') and (TypedSlash[1] <> '.') then
    Exit;

  LastSlash := 0;
  for I := Length(TypedSlash) downto 1 do
    if TypedSlash[I] = '/' then
    begin
      LastSlash := I;
      Break;
    end;

  if LastSlash > 0 then
  begin
    DirPrefixSlash := Copy(TypedSlash, 1, LastSlash); // includes trailing '/'
    SearchDir := ResolveRelativePath(ProjDir, Copy(DirPrefixSlash, 1, Length(DirPrefixSlash) - 1));
  end
  else
  begin
    DirPrefixSlash := '';
    SearchDir := ProjDir;
  end;

  if not DirectoryExists(SearchDir) then
    Exit;

  OutCount := 0;
  if FindFirst(IncludeTrailingPathDelimiter(SearchDir) + AllFilesMask, faAnyFile, Rec) = 0 then
  begin
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        IsDir := (Rec.Attr and faDirectory) <> 0;
        if IsDir then
        begin
          if ShouldSkipProjectDirName(Rec.Name) then
            Continue;
          EntryPath := JoinPath(SearchDir, Rec.Name);
          if AIncludePascalFiles then
          begin
            // Suggest nested *.pas files one level deep immediately when typing 'entry: '
            if (DirPrefixSlash = '') and
               (FindFirst(IncludeTrailingPathDelimiter(EntryPath) + AllFilesMask, faAnyFile, SubRec) = 0) then
            begin
              try
                repeat
                  if ((SubRec.Attr and faDirectory) = 0) and HasPascalEntryExtension(SubRec.Name) then
                  begin
                    SubEntryPath := Rec.Name + '/' + SubRec.Name;
                    AddPathItem(SubEntryPath, lcikFile, 'Pascal entry source', '00');
                  end;
                until FindNext(SubRec) <> 0;
              finally
                FindClose(SubRec);
              end;
            end;
            AddPathItem(DirPrefixSlash + Rec.Name + '/', lcikFolder, 'directory', '02');
          end
          else
          begin
            RelCandidate := DirPrefixSlash + Rec.Name;
            if ARequireDotPrefix and (DirPrefixSlash = '') then
              RelCandidate := './' + Rec.Name;
            if FileExists(JoinPath(EntryPath, 'nik.yaml')) or FileExists(JoinPath(EntryPath, 'nik.yml')) then
              AddPathItem(RelCandidate, lcikFolder, 'local Nikrun package', '00')
            else
              AddPathItem(RelCandidate, lcikFolder, 'directory', '01');
          end;
        end
        else
        begin
          if AIncludePascalFiles and HasPascalEntryExtension(Rec.Name) then
            AddPathItem(DirPrefixSlash + Rec.Name, lcikFile, 'Pascal entry source', '01')
          else if AIncludeArchives and IsSupportedArchivePath(Rec.Name) then
          begin
            RelCandidate := DirPrefixSlash + Rec.Name;
            if ARequireDotPrefix and (DirPrefixSlash = '') then
              RelCandidate := './' + Rec.Name;
            AddPathItem(RelCandidate, lcikFile, 'package archive', '01');
          end;
        end;
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  Schema Metadata Catalog (nik.yaml v1)
  --------------------------------------------------------------------------- }

function MakeKeySpec(const AName: string; AValKind: TYamlValueKind;
  const ATypeLabel, ADefaultLabel, AFpcFlagLabel, ASummary, ADetails: string): TManifestKeySpec;
begin
  Result.Name := AName;
  Result.ValueKind := AValKind;
  Result.TypeLabel := ATypeLabel;
  Result.DefaultLabel := ADefaultLabel;
  Result.FpcFlagLabel := AFpcFlagLabel;
  Result.Summary := ASummary;
  Result.DetailsMarkdown := ADetails;
end;

function MakeEnumSpec(const AVal, ADetail, ADoc: string): TManifestEnumSpec;
begin
  Result.Value := AVal;
  Result.Detail := ADetail;
  Result.Documentation := ADoc;
end;

procedure AppendKeySpec(var AArr: array of TManifestKeySpec; var ACount: Integer; const ASpec: TManifestKeySpec);
begin
  if ACount <= High(AArr) then
  begin
    AArr[ACount] := ASpec;
    Inc(ACount);
  end;
end;

function GetAllowedKeysForScope(const ACanonicalParent, ARootArtifact: string;
  out ASpecs: array of TManifestKeySpec): Integer;
var
  IsPkg, IsTpl: Boolean;
begin
  Result := 0;
  IsPkg := (ARootArtifact = 'package');
  IsTpl := (ARootArtifact = 'template');

  if ACanonicalParent = 'root' then
  begin
    AppendKeySpec(ASpecs, Result, MakeKeySpec('schemaVersion', yvkScalar, 'integer', '1', '',
      'Manifest schema version (`1`).',
      'Optional manifest format version. Must be `1` when specified.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('program', yvkMapping, 'mapping', '', '',
      'Executable Free Pascal application (`program MyApp;`).',
      'Declares a standalone executable target. Requires `entry` and `toolchain.fpc`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('library', yvkMapping, 'mapping', '', '',
      'Native shared library (`.dll` / `lib*.so` / `lib*.dylib`).',
      'Declares a native shared library (`library MyLib;`). Automatically enables PIC (`-Cg`) on Unix targets when `build.pic` is `auto`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('package', yvkMapping, 'mapping', '', '',
      'Reusable source-first Object Pascal unit package.',
      'Declares a reusable collection of Object Pascal units without a standalone binary (`entry` and `output` are not allowed; use `nik test` with `*_test.pas` / `*.test.pas` units for package tests).'));
    Exit;
  end;

  if (ACanonicalParent = 'artifact') or (ACanonicalParent = 'test') or (ACanonicalParent = 'subOverlay') then
  begin
    if (ACanonicalParent <> 'test') and (not IsTpl) then
      AppendKeySpec(ASpecs, Result, MakeKeySpec('name', yvkScalar, 'string', 'directory name', '',
        'Artifact or package identifier.',
        'Project, library, or package name. Defaults to the containing directory name when omitted.'));

    if ACanonicalParent <> 'test' then
      AppendKeySpec(ASpecs, Result, MakeKeySpec('version', yvkScalar, 'string (SemVer)', '0.1.0', '',
        'Project or package SemVer version.',
        'Semantic version string (e.g. `0.1.0`, `1.2.0`). Defaults to `0.1.0`.'));

    if ACanonicalParent = 'artifact' then
    begin
      AppendKeySpec(ASpecs, Result, MakeKeySpec('description', yvkScalar, 'string', '', '',
        'Short human-readable summary of the project or package.',
        'Optional project or package description metadata.'));
      AppendKeySpec(ASpecs, Result, MakeKeySpec('license', yvkScalar, 'string (SPDX)', '', '',
        'SPDX license identifier (e.g. `MIT`, `GPL-3.0-or-later`).',
        'Optional SPDX license expression for this project or package.'));
      AppendKeySpec(ASpecs, Result, MakeKeySpec('repository', yvkScalar, 'string (URL)', '', '',
        'Canonical source repository URL.',
        'Optional canonical Git repository URL (e.g. `https://github.com/owner/repo`).'));
      AppendKeySpec(ASpecs, Result, MakeKeySpec('authors', yvkSequence, 'string[]', '[]', '',
        'List of project or package authors.',
        'Optional list of author names or `Name <email>` entries.'));
    end;

    if (not IsTpl) and (not IsPkg) and (ACanonicalParent <> 'test') then
    begin
      AppendKeySpec(ASpecs, Result, MakeKeySpec('entry', yvkScalar, 'string (path)', '', '<entry.pas>',
        'Main Free Pascal entry source file (`.pas` / `.lpr` / `.dpr`).',
        'Relative path to the main program or library source file passed to `ppc*`. **Required** on `program` and `library`.'));
      AppendKeySpec(ASpecs, Result, MakeKeySpec('output', yvkScalar, 'string (path)', 'bin/<name>', '-FE / -o',
        'Output binary path (OS file extension added automatically).',
        'Relative output path for the compiled executable or shared library. Platform extensions (`.exe`, `.dll`, `.so`, `.dylib`) are appended automatically if omitted.'));
    end;

    AppendKeySpec(ASpecs, Result, MakeKeySpec('toolchain', yvkMapping, 'mapping', '', '',
      'Free Pascal SDK version and target platform configuration.',
      'Configures the exact hermetic Free Pascal SDK (`toolchain.fpc`) and optional target triplet (`toolchain.target`).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('build', yvkMapping, 'mapping', '', '',
      'Dialect, search paths, defines, checks, warnings, and optimization options.',
      'Declarative compiler and linker configuration translated deterministically into `ppc*` arguments.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('dependencies', yvkMapping, 'mapping', '', '',
      'Local path/archive and remote Git/archive package dependencies.',
      'Maps local dependency aliases to `./` / `../` local paths or `https://...@<semver|commit>` remote packages. Resolved via MVS and locked in `nik.lock`.'));

    if ACanonicalParent = 'artifact' then
    begin
      if not IsTpl then
        AppendKeySpec(ASpecs, Result, MakeKeySpec('test', yvkMapping, 'mapping', '', '',
          'Test target overlay (`nik test`).',
          'Overlay applied when compiling and running tests (test-only `unitPaths`, `defines`, `heaptrc`, and `test.dependencies`). `nik test` discovers `*_test.pas` / `*.test.pas` fpcunit units next to your code automatically; there is no `entry` or `output`.'));
      AppendKeySpec(ASpecs, Result, MakeKeySpec('targets', yvkMapping, 'mapping', '', '',
        'Automatic OS and CPU architecture overlays.',
        'Platform-specific overlays applied automatically in order of specificity: `unix` -> OS (`windows`/`linux`/`darwin`) -> CPU (`x86_64`/`aarch64`) -> exact `<cpu>-<os>` triplet.'));
      AppendKeySpec(ASpecs, Result, MakeKeySpec('profiles', yvkMapping, 'mapping', '', '',
        'Named build profiles (`debug`, `release`, or custom profiles).',
        'Profile overlays selected via `-p` / `--profile` (defaults to `debug`). `debug` and `release` carry built-in defaults that you can customize here.'));
    end;
    Exit;
  end;

  if ACanonicalParent = 'targets' then
  begin
    AppendKeySpec(ASpecs, Result, MakeKeySpec('windows', yvkMapping, 'target overlay', '', '',
      'Applied when targeting Windows (`win64`).', 'Alias for `win64`; applied automatically for Windows SDK targets.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('linux', yvkMapping, 'target overlay', '', '',
      'Applied when targeting Linux.', 'Applied automatically for `x86_64-linux` and `aarch64-linux` targets.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('darwin', yvkMapping, 'target overlay', '', '',
      'Applied when targeting macOS (`darwin`).', 'Applied automatically for `x86_64-darwin` and `aarch64-darwin` targets.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('macos', yvkMapping, 'target overlay', '', '',
      'Applied when targeting macOS (alias for `darwin`).', 'Alias for `darwin`; applied automatically on macOS targets.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('unix', yvkMapping, 'target overlay', '', '',
      'Applied on all Unix-family targets (`linux` and `darwin`).', 'OS-family overlay applied before specific `linux` or `darwin` target overlays.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('win64', yvkMapping, 'target overlay', '', '',
      'Applied when targeting 64-bit Windows (`win64`).', 'Canonical Free Pascal OS target overlay for Windows.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('x86_64', yvkMapping, 'target overlay', '', '',
      'Applied on 64-bit x86 (`x86_64`) targets across all OSes.', 'CPU architecture overlay applied after OS overlays and before exact `<cpu>-<os>` triplets.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('aarch64', yvkMapping, 'target overlay', '', '',
      'Applied on 64-bit ARM (`aarch64`) targets across all OSes.', 'CPU architecture overlay applied after OS overlays and before exact `<cpu>-<os>` triplets.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('x86_64-win64', yvkMapping, 'target overlay', '', '',
      'Exact target triplet overlay for Windows x64.', 'Most specific target overlay for `x86_64-win64`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('aarch64-win64', yvkMapping, 'target overlay', '', '',
      'Exact target triplet overlay for Windows ARM64.', 'Most specific target overlay for `aarch64-win64`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('x86_64-linux', yvkMapping, 'target overlay', '', '',
      'Exact target triplet overlay for Linux x64.', 'Most specific target overlay for `x86_64-linux`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('aarch64-linux', yvkMapping, 'target overlay', '', '',
      'Exact target triplet overlay for Linux ARM64.', 'Most specific target overlay for `aarch64-linux`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('x86_64-darwin', yvkMapping, 'target overlay', '', '',
      'Exact target triplet overlay for macOS Intel.', 'Most specific target overlay for `x86_64-darwin`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('aarch64-darwin', yvkMapping, 'target overlay', '', '',
      'Exact target triplet overlay for macOS Apple Silicon.', 'Most specific target overlay for `aarch64-darwin`.'));
    Exit;
  end;

  if ACanonicalParent = 'profiles' then
  begin
    AppendKeySpec(ASpecs, Result, MakeKeySpec('debug', yvkMapping, 'profile overlay', '', '',
      'Default development profile (`-dDEBUG`, `dwarf2`, assertions & runtime checks).',
      'Built-in defaults: `defines: [DEBUG]`, `debugInfo: dwarf2`, `assertions: true`, `checks: [range, overflow, io]`, `optimization: 0`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('release', yvkMapping, 'profile overlay', '', '',
      'Optimized production profile (`-dRELEASE`, `-O2`, smart-linking & symbol stripping).',
      'Built-in defaults: `defines: [RELEASE]`, `debugInfo: none`, `assertions: false`, `optimization: 2`, `smartLink: true`, `stripSymbols: true`.'));
    Exit;
  end;

  if ACanonicalParent = 'toolchain' then
  begin
    AppendKeySpec(ASpecs, Result, MakeKeySpec('fpc', yvkScalar, 'string (exact version)', '', '',
      'Required exact Free Pascal SDK version (e.g. `3.2.2`, `3.2.4`, `3.3.1`).',
      'Pins the exact Free Pascal compiler & RTL version from `~/.nikrun/sdks/`. Automatically provisioned on `nik build` when missing locally.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('target', yvkScalar, 'string (triplet)', 'native', '-P<cpu> -T<os>',
      'Target CPU-OS triplet or `native`.',
      'Selects the target platform (`native`, `x86_64-win64`, `aarch64-win64`, `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`).'));
    Exit;
  end;

  if ACanonicalParent = 'build' then
  begin
    AppendKeySpec(ASpecs, Result, MakeKeySpec('mode', yvkScalar, 'enum', 'objfpc', '-M<mode>',
      'Default Object Pascal syntax mode (`objfpc`, `delphi`, â€¦).',
      'Sets the project-wide Free Pascal syntax mode (`objfpc`, `delphi`, `delphiunicode`, `fpc`, `tp`, `macpas`, `iso`, `extendedpascal`). Individual units may still override via `{$mode ...}`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('longStrings', yvkScalar, 'boolean', 'true', '-Sh / -Sh-',
      'Enable `AnsiString` (`{$H+}`) for `string` by default.',
      'When `true` (default), `string` maps to dynamically managed `AnsiString` (`-Sh`). When `false`, `string` defaults to `ShortString` (`-Sh-`).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('cOperators', yvkScalar, 'boolean', 'false', '-Sc / -Sc-',
      'Enable C-style assignment operators (`+=`, `-=`, `*=`, `/=`).',
      'Passes `-Sc` when `true` or `-Sc-` when `false`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('modeSwitches', yvkSequence, 'string[]', '[]', '-M<switch>',
      'Project-wide Free Pascal modeswitches (e.g. `advancedRecords`, `typeHelpers`).',
      'Passes `-M<switch>` for each item. Merges **additively** across overlays (place `"$reset"` first to clear inherited items).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('subsystem', yvkScalar, 'enum', 'console', '-WG (Windows)',
      'Application subsystem (`console` or `gui`).',
      '`gui` passes `-WG` on Windows targets to omit the console window; ignored on Unix targets.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('pic', yvkScalar, 'auto | boolean', 'auto', '-Cg / -Cg-',
      'Position-independent code generation (`auto`, `true`, `false`).',
      '`auto` enables `-Cg` automatically for `library` targets on Unix. `true` forces `-Cg`; `false` passes `-Cg-`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('cpuType', yvkScalar, 'string', '', '-Cp<cpu>',
      'Target CPU instruction set (e.g. `COREAVX2`, `ARMV8`).',
      'Forwards `-Cp<cpuType>` to `ppc*` for target-specific instruction scheduling.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('fpuType', yvkScalar, 'string', '', '-Cf<fpu>',
      'Target FPU / vector instruction set (e.g. `AVX2`, `VFPv4`).',
      'Forwards `-Cf<fpuType>` to `ppc*`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('stackSize', yvkScalar, 'integer', '', '-Cs<bytes>',
      'Explicit stack size in bytes.',
      'Passes `-Cs<bytes>` to configure the stack size limit.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('unitPaths', yvkSequence, 'string[]', '[]', '-Fu<dir>',
      'Unit search directories relative to `nik.yaml`.',
      'Adds `-Fu<dir>` for `.pas` / `.pp` unit discovery. Merges **additively** across overlays (`"$reset"` first clears inherited paths).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('includePaths', yvkSequence, 'string[]', '[]', '-Fi<dir>',
      'Include file (`{$I ...}`) search directories.',
      'Adds `-Fi<dir>` for include files. Merges **additively** across overlays (`"$reset"` first clears inherited paths).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('libraryPaths', yvkSequence, 'string[]', '[]', '-Fl<dir>',
      'Native linker library search directories.',
      'Adds `-Fl<dir>` so the linker can locate static/shared native libraries. Merges **additively** across overlays.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('objectPaths', yvkSequence, 'string[]', '[]', '-Fo<dir>',
      'Object file (`.o` / `.obj`) search directories.',
      'Adds `-Fo<dir>`. Merges **additively** across overlays.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('resourcePaths', yvkSequence, 'string[]', '[]', '-Fi<dir> -Fo<dir>',
      'Resource (`.res` / `.rc` / `.lfm`) search directories.',
      'Registers each directory in both `-Fi` and `-Fo` for resource lookup. Merges **additively** across overlays.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('defines', yvkSequence, 'string[]', '[DEBUG] / [RELEASE]', '-d<SYMBOL>',
      'Conditional compilation symbols (`{$IFDEF SYMBOL}`).',
      'Passes `-d<SYMBOL>` to both `ppc*` and `nik lsp` CodeTools indexing. Merges **additively** across overlays (`"$reset"` first replaces inherited symbols).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('undefines', yvkSequence, 'string[]', '[]', '-u<SYMBOL>',
      'Conditional symbols to undefine (emitted before `defines`).',
      'Passes `-u<SYMBOL>` prior to `-d` flags. Merges **additively** across overlays.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('debugInfo', yvkScalar, 'enum | boolean', 'dwarf2 (debug) / none (release)', '-gl -gw2 / -gw3 / -gs / -Xg',
      'Debug symbol format (`dwarf2`, `dwarf3`, `lineinfo`, `external`, `stabs`, `none`).',
      'Controls debug info generation: `dwarf2` (`-gl -gw2`), `dwarf3` (`-gl -gw3`), `lineinfo` (`-gl`), `external` (`-gl -gw2 -Xg`), `stabs` (`-gl -gs`), or `none` (`-g-`).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('heaptrc', yvkScalar, 'boolean', 'false (true in test)', '-gh -gl',
      'Link the Free Pascal `heaptrc` memory-leak detector.',
      'Passes `-gh -gl` when `true` (enabled by default in the `test` overlay).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('assertions', yvkScalar, 'boolean', 'true (debug/test) / false (release)', '-Sa / -Sa-',
      'Compile `Assert(...)` runtime checks.',
      'Passes `-Sa` when `true` or `-Sa-` when `false`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('checks', yvkSequence, 'string[]', '[range, overflow, io] (debug)', '-Cr -Co -Ci -Ct -CR',
      'Runtime safety checks (`range`, `overflow`, `io`, `stack`, `object`, `all`, `none`).',
      'Maps items to Free Pascal check switches: `range` (`-Cr`), `overflow` (`-Co`), `io` (`-Ci`), `stack` (`-Ct`), `object` (`-CR`). Merges **additively** across overlays (`"$reset"` or `none` resets).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('warnings', yvkMapping, 'mapping', '', '-Sew / -vh / -vn / -vm',
      'Compiler warning, hint, note, and message suppression controls.',
      'Configures `asErrors` (`-Sew`), `hints` (`-vh`), `notes` (`-vn`), and `suppress` (`-vm<code>`).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('optimization', yvkScalar, '0..4 | none | default | boolean', '0 (debug) / 2 (release)', '-O- / -O1..4',
      'Compiler optimization level (`0`..`4`, `none`, `default`).',
      '`0` / `none` / `false` disables optimizations (`-O-`); `1`..`4` passes `-O1`..`-O4`; `default` / `true` selects `-O2`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('smartLink', yvkScalar, 'boolean', 'false (true in release)', '-CX -XX',
      'Create smartlinkable units and strip unused code/data.',
      'Passes `-CX -XX` when `true` to dead-strip unreferenced procedures and symbols at link time.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('stripSymbols', yvkScalar, 'boolean', 'false (true in release)', '-Xs',
      'Strip debug/symbol tables from the linked binary.',
      'Passes `-Xs` when `true` to reduce final executable or library size.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('linkLibraries', yvkSequence, 'string[]', '[]', '-k-l<lib>',
      'Native system/C libraries to link (e.g. `[pthread, dl, sqlite3]`).',
      'Forwards `-k-l<lib>` for each library name. Merges **additively** across overlays.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('linkerArgs', yvkSequence, 'string[]', '[]', '-k<arg>',
      'Raw flags forwarded directly to the linker.',
      'Passes `-k<arg>` for each item. Merges **additively** across overlays.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('fpcArgs', yvkSequence, 'string[]', '[]', '<raw arg>',
      'Escape-hatch compiler flags appended verbatim to `ppc*`.',
      'Appends raw Free Pascal flags immediately before the entry source file. Merges **additively** across overlays.'));
    Exit;
  end;

  if ACanonicalParent = 'warnings' then
  begin
    AppendKeySpec(ASpecs, Result, MakeKeySpec('asErrors', yvkScalar, 'boolean', 'false', '-Sew',
      'Treat compiler warnings as fatal errors.',
      'Passes `-Sew` when `true` so any compiler warning fails the build.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('hints', yvkScalar, 'boolean', 'false', '-vh / -vh-',
      'Enable or disable Free Pascal compiler hints.',
      'Passes `-vh` when `true` or `-vh-` when `false`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('notes', yvkScalar, 'boolean', 'true', '-vn / -vn-',
      'Enable or disable Free Pascal compiler notes.',
      'Passes `-vn` when `true` or `-vn-` when `false`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('suppress', yvkSequence, 'integer[]', '[]', '-vm<id>',
      'Specific Free Pascal message numbers to suppress (e.g. `[5024]`).',
      'Passes `-vm<id>` for each positive message ID (for example `5024` for *Parameter not used*). Merges **additively** across overlays.'));
    Exit;
  end;

  if ACanonicalParent = 'depMapping' then
  begin
    AppendKeySpec(ASpecs, Result, MakeKeySpec('path', yvkScalar, 'string (local path)', '', '',
      'Local directory or archive path (`./...`, `../...`).',
      'Points to a local package directory or `.zip`/`.tar.gz` archive. When combined with `url`, overrides that remote URL locally across the entire dependency graph.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('url', yvkScalar, 'string (URL)', '', '',
      'Remote Git repository root URL or direct archive URL.',
      'Canonical `https://` / `ssh://` Git repository URL (paired with `version` or `rev`) or direct `.zip`/`.tar.gz`/`.tgz` URL.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('version', yvkScalar, 'string (SemVer constraint)', '', '',
      'SemVer constraint for Git tag resolution (e.g. `^0.2.0`, `~1.4.0`, `1.2.3`).',
      'Resolved deterministically via Minimal Version Selection (MVS) and pinned in `nik.lock`. Mutually exclusive with `rev`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('rev', yvkScalar, 'string (commit SHA)', '', '',
      'Exact Git commit hash (7..40 hex characters).',
      'Pins an immutable Git commit hash. Moving branch names (`main`, `trunk`) are intentionally disallowed.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('subpath', yvkScalar, 'string (relative dir)', '', '',
      'Relative subdirectory inside a multi-package repository or archive.',
      'Selects a nested package folder inside a monorepo or archive (e.g. `lsp-protocol`).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('sha256', yvkScalar, 'string (64 hex chars)', '', '',
      'Expected SHA-256 hex digest for direct `.zip`/`.tar.gz` archive dependencies.',
      'Verifies archive integrity on fetch (Git repository dependencies verify directory-tree SHA-256 automatically in `nik.lock`).'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('unitPaths', yvkSequence, 'string[]', '[]', '-Fu<dir>',
      'Explicit unit search paths for legacy packages without a `nik.yaml`.',
      'Provides `-Fu` directories relative to the dependency root when consuming third-party repositories that do not yet ship a `nik.yaml`.'));
    AppendKeySpec(ASpecs, Result, MakeKeySpec('includePaths', yvkSequence, 'string[]', '[]', '-Fi<dir>',
      'Explicit include search paths for legacy packages without a `nik.yaml`.',
      'Provides `-Fi` directories relative to the dependency root when consuming legacy repositories without a `nik.yaml`.'));
    Exit;
  end;
end;

function GetEnumSpecsForField(const ACanonicalField: string; AAllowReset: Boolean;
  out AEnums: array of TManifestEnumSpec): Integer;

  procedure AddE(const AVal, ADetail, ADoc: string);
  begin
    if Result <= High(AEnums) then
    begin
      AEnums[Result] := MakeEnumSpec(AVal, ADetail, ADoc);
      Inc(Result);
    end;
  end;

begin
  Result := 0;

  if ACanonicalField = 'root.schemaVersion' then
  begin
    AddE('1', 'nik.yaml schema v1', 'Current declarative Nikrun manifest schema version.');
    Exit;
  end;

  if ACanonicalField = 'toolchain.target' then
  begin
    AddE('native', 'Host CPU & OS (default)', 'Targets the current host machine architecture and operating system.');
    AddE('x86_64-win64', 'Windows x64 (-Px86_64 -Twin64)', '64-bit x86 Windows target.');
    AddE('aarch64-win64', 'Windows ARM64 (-Paarch64 -Twin64)', '64-bit ARM Windows target.');
    AddE('x86_64-linux', 'Linux x64 (-Px86_64 -Tlinux)', '64-bit x86 Linux target.');
    AddE('aarch64-linux', 'Linux ARM64 (-Paarch64 -Tlinux)', '64-bit ARM Linux target.');
    AddE('x86_64-darwin', 'macOS Intel (-Px86_64 -Tdarwin)', '64-bit x86 macOS target.');
    AddE('aarch64-darwin', 'macOS Apple Silicon (-Paarch64 -Tdarwin)', '64-bit ARM macOS target.');
    Exit;
  end;

  if ACanonicalField = 'build.mode' then
  begin
    AddE('objfpc', '-Mobjfpc (default)', 'Object Pascal mode with strict Free Pascal extensions (`@` proc pointers, `specialize`/`generic`).');
    AddE('delphi', '-Mdelphi', 'Delphi-compatible Object Pascal syntax mode.');
    AddE('delphiunicode', '-Mdelphiunicode', 'Delphi mode where `string` defaults to `UnicodeString`.');
    AddE('fpc', '-Mfpc', 'Classic Free Pascal dialect mode (without classes/exceptions by default).');
    AddE('tp', '-Mtp', 'Turbo Pascal 7 compatibility mode.');
    AddE('macpas', '-Mmacpas', 'Macintosh Pascal dialect compatibility mode.');
    AddE('iso', '-Miso', 'ISO 7185 Standard Pascal mode.');
    AddE('extendedpascal', '-Mextendedpascal', 'ISO 10206 Extended Pascal mode.');
    Exit;
  end;

  if ACanonicalField = 'build.subsystem' then
  begin
    AddE('console', 'Console application (default)', 'Standard terminal application with `stdin`/`stdout`/`stderr` streams.');
    AddE('gui', 'GUI application (-WG on Windows)', 'Graphical Windows subsystem application without an attached console window (`-WG`).');
    Exit;
  end;

  if ACanonicalField = 'build.pic' then
  begin
    AddE('auto', 'Automatic PIC (default)', 'Enables `-Cg` automatically for `library` targets on Unix platforms.');
    AddE('true', 'Force PIC (-Cg)', 'Always generate position-independent code (`-Cg`).');
    AddE('false', 'Disable PIC (-Cg-)', 'Explicitly disable position-independent code (`-Cg-`).');
    Exit;
  end;

  if ACanonicalField = 'build.debugInfo' then
  begin
    AddE('dwarf2', '-gl -gw2 (debug default)', 'DWARF v2 debug symbols with `lineinfo` backtraces (broadest LLDB/GDB compatibility).');
    AddE('dwarf3', '-gl -gw3', 'DWARF v3 debug symbols with `lineinfo` backtraces (improved dynamic array/string inspection).');
    AddE('lineinfo', '-gl', 'Lightweight line-number backtrace info without full DWARF type tables.');
    AddE('external', '-gl -gw2 -Xg', 'Emit debug symbols into an external `.dbg` companion file (`-Xg`).');
    AddE('stabs', '-gl -gs', 'Legacy Stabs debug symbol format (`-gs`).');
    AddE('none', '-g- (release default)', 'Omit debug symbol generation.');
    Exit;
  end;

  if ACanonicalField = 'build.optimization' then
  begin
    AddE('0', '-O- (no optimization)', 'Fastest compilation and most accurate step-by-step debugging.');
    AddE('1', '-O1 (level 1)', 'Debugger-friendly basic optimizations.');
    AddE('2', '-O2 (release default)', 'Standard production optimizations (`-O2`).');
    AddE('3', '-O3 (aggressive)', 'Aggressive loop/register optimizations (`-O3`).');
    AddE('4', '-O4 (maximum)', 'Maximum optimization level (`-O4`; may reorder/inline aggressively).');
    AddE('none', '-O- (alias for 0)', 'Disable compiler optimizations.');
    AddE('default', '-O2 (alias for 2)', 'Use standard level 2 optimizations.');
    Exit;
  end;

  if (ACanonicalField = 'build.longStrings') or
     (ACanonicalField = 'build.cOperators') or
     (ACanonicalField = 'build.heaptrc') or
     (ACanonicalField = 'build.assertions') or
     (ACanonicalField = 'build.smartLink') or
     (ACanonicalField = 'build.stripSymbols') or
     (ACanonicalField = 'warnings.asErrors') or
     (ACanonicalField = 'warnings.hints') or
     (ACanonicalField = 'warnings.notes') then
  begin
    AddE('true', 'boolean', 'Enable this option.');
    AddE('false', 'boolean', 'Disable this option.');
    Exit;
  end;

  if ACanonicalField = 'build.checks' then
  begin
    if AAllowReset then
      AddE('$reset', 'Overlay list reset', 'Clears inherited `checks` from base/target layers before applying the remaining items.');
    AddE('range', '-Cr (range checking)', 'Verify array, string, and subrange bounds at runtime (`-Cr`).');
    AddE('overflow', '-Co (integer overflow)', 'Detect integer arithmetic overflows at runtime (`-Co`).');
    AddE('io', '-Ci (I/O checking)', 'Check `IOResult` automatically after standard file I/O operations (`-Ci`).');
    AddE('stack', '-Ct (stack checking)', 'Check for stack overflow on routine entry (`-Ct`).');
    AddE('object', '-CR (method/object verification)', 'Verify virtual method calls and `as`/`is` object casts (`-CR`).');
    AddE('all', '-Cr -Co -Ci -Ct -CR', 'Enable all runtime safety checks.');
    AddE('none', 'Disable runtime checks', 'Clear and disable runtime safety checks.');
    Exit;
  end;

  if ACanonicalField = 'build.modeSwitches' then
  begin
    if AAllowReset then
      AddE('$reset', 'Overlay list reset', 'Clears inherited `modeSwitches` before applying the remaining switches.');
    AddE('advancedRecords', '-MadvancedRecords', 'Allow methods, properties, class operators, and visibility sections on `record` types.');
    AddE('typeHelpers', '-MtypeHelpers', 'Allow `record helper` / `type helper` extensions on primitive and structured types.');
    AddE('functionReferences', '-MfunctionReferences', 'Enable `reference to procedure/function` closure types (FPC 3.3.1+).');
    AddE('anonymousFunctions', '-ManonymousFunctions', 'Enable inline anonymous `procedure`/`function` expressions (FPC 3.3.1+).');
    AddE('managementOperators', '-MmanagementOperators', 'Enable `Initialize`, `Finalize`, `Copy`, and `AddRef` record operators.');
    AddE('implicitFunctionSpecialization', '-MimplicitFunctionSpecialization', 'Infer generic routine type parameters without explicit `specialize` (FPC 3.3.1+).');
    AddE('prefixedAttributes', '-MprefixedAttributes', 'Enable `[Attribute]` syntax before types, methods, and properties.');
    AddE('multiHelpers', '-MmultiHelpers', 'Allow multiple active helpers on the same target type simultaneously.');
    AddE('arrayOperators', '-MarrayOperators', 'Enable `+` concatenation operator on dynamic arrays.');
    AddE('nestedProcVars', '-MnestedProcVars', 'Allow passing nested local procedures as `is nested` procedural values.');
    AddE('autoderef', '-Mautoderef', 'Automatically dereference typed pointers on field/element access.');
    AddE('unicodestrings', '-Municodestrings', 'Map `string` to UTF-16 `UnicodeString` (`{$H+}`).');
    AddE('defaultParameters', '-MdefaultParameters', 'Allow default parameter values in routine declarations.');
    AddE('out', '-Mout', 'Enable the `out` parameter modifier.');
    AddE('result', '-Mresult', 'Enable the implicit `Result` variable inside functions.');
    Exit;
  end;

  if AAllowReset and IsAdditiveOverlayListField(ACanonicalField) then
  begin
    AddE('$reset', 'Overlay list reset', 'Clears inherited list items from earlier layers before appending subsequent items.');
  end;
end;

function FormatKeyHoverMarkdown(const ASpec: TManifestKeySpec): string;
var
  MetaLine: string;
begin
  Result := '**`' + ASpec.Name + '`**';
  if ASpec.TypeLabel <> '' then
    Result := Result + ' â€” *' + ASpec.TypeLabel + '*';
  Result := Result + #10#10 + ASpec.Summary;

  MetaLine := '';
  if ASpec.DefaultLabel <> '' then
    MetaLine := '- **Default:** `' + ASpec.DefaultLabel + '`';
  if ASpec.FpcFlagLabel <> '' then
  begin
    if MetaLine <> '' then
      MetaLine := MetaLine + #10;
    MetaLine := MetaLine + '- **Compiler flag (`ppc*`):** `' + ASpec.FpcFlagLabel + '`';
  end;

  if MetaLine <> '' then
    Result := Result + #10#10 + MetaLine;

  if ASpec.DetailsMarkdown <> '' then
    Result := Result + #10#10 + ASpec.DetailsMarkdown;
end;

{ ---------------------------------------------------------------------------
  LSP Handlers: Hover, Completion, Go-to-Definition, DocumentSymbol
  --------------------------------------------------------------------------- }

function ResolveManifestHover(const AManifestPath: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspHover;
var
  Ctx: TYamlCursorContext;
  KeySpecs: array[0..31] of TManifestKeySpec;
  EnumSpecs: array[0..23] of TManifestEnumSpec;
  KeyCount, EnumCount, I: Integer;
  DynamicExtra, ProjDir, ResolvedPath: string;
begin
  Result := Default(TLspHover);
  Ctx := AnalyzeYamlCursorContext(ADoc, APos);
  if (not Ctx.Valid) or Ctx.InComment or (Ctx.TokenText = '') then
    Exit;

  if Ctx.Role = ycrKey then
  begin
    if Ctx.CanonicalParent = 'dependencies' then
    begin
      Result.HasValue := True;
      Result.HasRange := True;
      Result.Range := Ctx.TokenRange;
      Result.Markdown :=
        '**`' + Ctx.TokenText + '`** â€” *dependency alias*' + #10#10 +
        'Local dependency identifier in `nik.yaml`. Maps to a `./` / `../` local path/archive, ' +
        'a `https://...@<semver|commit>` Git repository, or a `{ url, version, rev, path, subpath }` mapping.';
      DynamicExtra := DescribeDependencyLockStatus(AManifestPath, Ctx.TokenText, Ctx.InlineScalarValue, ADoc, APos.Line);
      if DynamicExtra <> '' then
        Result.Markdown := Result.Markdown + #10#10 + DynamicExtra;
      Exit;
    end;

    KeyCount := GetAllowedKeysForScope(Ctx.CanonicalParent, Ctx.RootArtifact, KeySpecs);
    for I := 0 to KeyCount - 1 do
      if KeySpecs[I].Name = Ctx.TokenText then
      begin
        Result.HasValue := True;
        Result.HasRange := True;
        Result.Range := Ctx.TokenRange;
        Result.Markdown := FormatKeyHoverMarkdown(KeySpecs[I]);
        if (Ctx.CanonicalField = 'toolchain.fpc') and (Ctx.InlineScalarValue <> '') then
        begin
          DynamicExtra := DescribeSdkVersionForHover(ADoc, Ctx.InlineScalarValue);
          if DynamicExtra <> '' then
            Result.Markdown := Result.Markdown + #10#10 + DynamicExtra;
        end;
        Exit;
      end;

    if Ctx.CanonicalParent = 'profiles' then
    begin
      Result.HasValue := True;
      Result.HasRange := True;
      Result.Range := Ctx.TokenRange;
      Result.Markdown :=
        '**`' + Ctx.TokenText + '`** â€” *custom build profile*' + #10#10 +
        'Named profile overlay selectable via `nik build -p ' + Ctx.TokenText + '` or `Nikrun: Select Active Profile` in `nikrun.vscode`.';
      Exit;
    end;
    Exit;
  end;

  if (Ctx.Role = ycrScalarValue) or (Ctx.Role = ycrSeqItem) then
  begin
    // 1. Dynamic SDK version hover on toolchain.fpc: <version>
    if Ctx.CanonicalField = 'toolchain.fpc' then
    begin
      DynamicExtra := DescribeSdkVersionForHover(ADoc, Ctx.TokenText);
      if DynamicExtra <> '' then
      begin
        Result.HasValue := True;
        Result.HasRange := True;
        Result.Range := Ctx.TokenRange;
        Result.Markdown := '**Free Pascal `' + Ctx.TokenText + '`**' + #10#10 + DynamicExtra;
        Exit;
      end;
    end;

    // 2. Dynamic file/directory path hover on entry & search paths
    if (AManifestPath <> '') and
       (IsEntryFileField(Ctx.CanonicalField) or IsDirectoryListField(Ctx.CanonicalField) or
        (Ctx.CanonicalField = 'depMapping.path')) then
    begin
      ProjDir := ExtractFileDir(AManifestPath);
      if (ProjDir <> '') and (Ctx.TokenText <> '$reset') then
      begin
        ResolvedPath := ResolveRelativePath(ProjDir, Ctx.TokenText);
        Result.HasValue := True;
        Result.HasRange := True;
        Result.Range := Ctx.TokenRange;
        if FileExists(ResolvedPath) or DirectoryExists(ResolvedPath) then
          Result.Markdown := '**`' + Ctx.TokenText + '`**' + #10#10 +
            '- **Resolved path:** `' + NormalizeForwardSlashes(ResolvedPath) + '` *(exists)*'
        else
          Result.Markdown := '**`' + Ctx.TokenText + '`**' + #10#10 +
            '- **Resolved path:** `' + NormalizeForwardSlashes(ResolvedPath) + '` *(not found on disk)*';
        Exit;
      end;
    end;

    // 3. Dynamic compact dependency value hover
    if Ctx.CanonicalParent = 'dependencies' then
    begin
      DynamicExtra := DescribeDependencyLockStatus(AManifestPath, Ctx.CurrentKey, Ctx.TokenText, ADoc, APos.Line);
      if DynamicExtra <> '' then
      begin
        Result.HasValue := True;
        Result.HasRange := True;
        Result.Range := Ctx.TokenRange;
        Result.Markdown := '**Dependency `' + Ctx.CurrentKey + '`**' + #10#10 + DynamicExtra;
        Exit;
      end;
    end;

    // 4. Static Enum / ModeSwitch / Check value hover
    EnumCount := GetEnumSpecsForField(Ctx.CanonicalField, True, EnumSpecs);
    for I := 0 to EnumCount - 1 do
      if SameText(EnumSpecs[I].Value, Ctx.TokenText) then
      begin
        Result.HasValue := True;
        Result.HasRange := True;
        Result.Range := Ctx.TokenRange;
        Result.Markdown :=
          '**`' + EnumSpecs[I].Value + '`** â€” `' + EnumSpecs[I].Detail + '`' + #10#10 +
          EnumSpecs[I].Documentation;
        Exit;
      end;
  end;
end;

function ResolveManifestDefinitions(const AManifestPath: string; ADoc: TLspDocument;
  const APos: TLspPosition): TLspLocationArray;
var
  Ctx: TYamlCursorContext;
  ProjDir, CandidatePath, PkgManifest, TargetUrl, CacheDir, DummyCommit, DummyIntegrity: string;
  Lock: TLockFile;
  I: Integer;

  procedure EmitFileLocation(const ATargetFile: string);
  begin
    SetLength(Result, 1);
    Result[0] := TLspLocation.Create(FilePathToUri(ATargetFile), TLspRange.SingleLine(0, 0, 0));
  end;

  function TryResolvePackageDirManifest(const ADir: string; out AFoundManifest: string): Boolean;
  begin
    AFoundManifest := JoinPath(ADir, 'nik.yaml');
    if FileExists(AFoundManifest) then
      Exit(True);
    AFoundManifest := JoinPath(ADir, 'nik.yml');
    Result := FileExists(AFoundManifest);
  end;

begin
  Result := nil;
  if AManifestPath = '' then
    Exit;
  ProjDir := ExtractFileDir(AManifestPath);
  if ProjDir = '' then
    Exit;

  Ctx := AnalyzeYamlCursorContext(ADoc, APos);
  if (not Ctx.Valid) or Ctx.InComment or (Ctx.TokenText = '') then
    Exit;

  // 1. Go to Definition on entry: src/main.pas
  if (Ctx.Role = ycrScalarValue) and IsEntryFileField(Ctx.CanonicalField) then
  begin
    CandidatePath := ResolveRelativePath(ProjDir, Ctx.TokenText);
    if FileExists(CandidatePath) then
      EmitFileLocation(CandidatePath);
    Exit;
  end;

  // 2. Go to Definition on local dependency path ('path: ../pkg' or 'pkg: ../pkg')
  if ((Ctx.Role = ycrScalarValue) and (Ctx.CanonicalField = 'depMapping.path')) or
     ((Ctx.Role = ycrScalarValue) and (Ctx.CanonicalParent = 'dependencies') and (Pos('://', Ctx.TokenText) = 0)) then
  begin
    CandidatePath := ResolveRelativePath(ProjDir, Ctx.TokenText);
    if DirectoryExists(CandidatePath) and TryResolvePackageDirManifest(CandidatePath, PkgManifest) then
      EmitFileLocation(PkgManifest)
    else if FileExists(CandidatePath) then
      EmitFileLocation(CandidatePath);
    Exit;
  end;

  // 3. Go to Definition on remote dependency URL -> cached ~/.nikrun/cache/pkg/.../nik.yaml via nik.lock
  if ((Ctx.Role = ycrScalarValue) and (Ctx.CanonicalField = 'depMapping.url')) or
     ((Ctx.Role = ycrScalarValue) and (Ctx.CanonicalParent = 'dependencies') and (Pos('://', Ctx.TokenText) > 0)) then
  begin
    TargetUrl := ExtractUrlBaseBeforeAt(Ctx.TokenText);
    if TargetUrl = '' then
      TargetUrl := Ctx.TokenText;
    while (Length(TargetUrl) > 1) and (TargetUrl[Length(TargetUrl)] = '/') do
      Delete(TargetUrl, Length(TargetUrl), 1);
    if (Length(TargetUrl) > 4) and SameText(Copy(TargetUrl, Length(TargetUrl) - 3, 4), '.git') then
      Delete(TargetUrl, Length(TargetUrl) - 3, 4);

    try
      Lock := LoadLockFile(ProjDir);
      if Lock.ExistsOnDisk then
        for I := 0 to High(Lock.Packages) do
          if SameText(Lock.Packages[I].Url, TargetUrl) then
          begin
            CacheDir := '';
            if (Lock.Packages[I].Kind = lpkGit) and (Lock.Packages[I].Rev <> '') then
              FindCachedGitPackageDir(Lock.Packages[I].Url, Lock.Packages[I].Rev, DummyCommit, CacheDir, DummyIntegrity)
            else if (Lock.Packages[I].Kind = lpkArchive) and (Lock.Packages[I].Sha256 <> '') then
              FindCachedArchiveDir(Lock.Packages[I].Sha256, CacheDir);

            if CacheDir <> '' then
            begin
              if Lock.Packages[I].Subpath <> '' then
                CacheDir := JoinPath(CacheDir, Lock.Packages[I].Subpath);
              if TryResolvePackageDirManifest(CacheDir, PkgManifest) then
              begin
                EmitFileLocation(PkgManifest);
                Exit;
              end;
            end;
          end;
    except
      // Ignore lock lookup errors
    end;
  end;
end;

function ContainsKeyName(const AList: TStringArray; const AKey: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AList) do
    if AList[I] = AKey then
      Exit(True);
  Result := False;
end;

function ResolveManifestCompletions(const AManifestPath: string; ADoc: TLspDocument;
  const APos: TLspPosition; const ATriggerChar: string): TLspCompletionList;
var
  Ctx: TYamlCursorContext;
  KeySpecs: array[0..31] of TManifestKeySpec;
  EnumSpecs: array[0..23] of TManifestEnumSpec;
  SdkCands: TSdkVersionCandidateArray;
  KeyCount, EnumCount, I, OutCount: Integer;
  Item: TLspCompletionItem;
  NewVal: string;
begin
  Result := Default(TLspCompletionList);
  Result.IsIncomplete := False;

  if (ATriggerChar = ':') or (ATriggerChar = '@') then
    Exit;

  Ctx := AnalyzeYamlCursorContext(ADoc, APos);
  if (not Ctx.Valid) or Ctx.InComment then
    Exit;

  if (ATriggerChar = ' ') and (not Ctx.TriggeredRightAfterDelim) then
    Exit;

  // 1. Key completions
  if Ctx.Role = ycrKey then
  begin
    if (ATriggerChar = '/') or (ATriggerChar = '.') then
      Exit;

    KeyCount := GetAllowedKeysForScope(Ctx.CanonicalParent, Ctx.RootArtifact, KeySpecs);
    if KeyCount <= 0 then
      Exit;

    OutCount := 0;
    SetLength(Result.Items, KeyCount);
    for I := 0 to KeyCount - 1 do
    begin
      if ContainsKeyName(Ctx.ExistingKeys, KeySpecs[I].Name) then
        Continue;
      if (Ctx.CanonicalParent = 'root') and
         ((KeySpecs[I].Name = 'program') or (KeySpecs[I].Name = 'library') or (KeySpecs[I].Name = 'package')) and
         (ContainsKeyName(Ctx.ExistingKeys, 'program') or
          ContainsKeyName(Ctx.ExistingKeys, 'library') or
          ContainsKeyName(Ctx.ExistingKeys, 'package')) then
        Continue;

      Item := Default(TLspCompletionItem);
      Item.LabelText := KeySpecs[I].Name;
      if KeySpecs[I].ValueKind = yvkMapping then
        Item.Kind := lcikModule
      else
        Item.Kind := lcikProperty;

      if KeySpecs[I].FpcFlagLabel <> '' then
        Item.Detail := KeySpecs[I].TypeLabel + ' (' + KeySpecs[I].FpcFlagLabel + ')'
      else
        Item.Detail := KeySpecs[I].TypeLabel;

      Item.DocumentationMarkdown := FormatKeyHoverMarkdown(KeySpecs[I]);
      Item.SortText := Format('%.2d_%s', [I, KeySpecs[I].Name]);
      Item.FilterText := KeySpecs[I].Name;

      if Ctx.HasColonOnLine or Ctx.IsQuotedToken then
        NewVal := KeySpecs[I].Name
      else if KeySpecs[I].ValueKind = yvkScalar then
        NewVal := KeySpecs[I].Name + ': '
      else
        NewVal := KeySpecs[I].Name + ':';

      Item.HasTextEdit := True;
      Item.TextEdit := TLspTextEdit.Create(Ctx.ReplaceRange, NewVal);
      Result.Items[OutCount] := Item;
      Inc(OutCount);
    end;
    SetLength(Result.Items, OutCount);
    Exit;
  end;

  // 2. Value & Sequence Item completions
  if (Ctx.Role = ycrScalarValue) or (Ctx.Role = ycrSeqItem) then
  begin
    // 2a. Dynamic Free Pascal SDK version completions (installed + cached/online index.json)
    if (Ctx.Role = ycrScalarValue) and (Ctx.CanonicalField = 'toolchain.fpc') then
    begin
      if ATriggerChar = '/' then
        Exit;
      SdkCands := CollectSdkVersionCandidates(ADoc);
      SetLength(Result.Items, Length(SdkCands));
      for I := 0 to High(SdkCands) do
      begin
        Item := Default(TLspCompletionItem);
        Item.LabelText := SdkCands[I].Version;
        Item.Kind := lcikValue;
        if SdkCands[I].HasInstalled then
        begin
          if SdkCands[I].UpdateAvailable then
            Item.Detail := Format('Free Pascal %s â€” installed (%s, update available)',
              [SdkCands[I].Version, SdkCands[I].Installed.Manifest.TargetTriplet])
          else
            Item.Detail := Format('Free Pascal %s â€” installed (%s)',
              [SdkCands[I].Version, SdkCands[I].Installed.Manifest.TargetTriplet]);
        end
        else if SdkCands[I].HasRemote then
          Item.Detail := Format('Free Pascal %s â€” available online (%s)',
            [SdkCands[I].Version, SdkCands[I].Remote.TargetTriplet])
        else
          Item.Detail := Format('Free Pascal %s', [SdkCands[I].Version]);

        Item.DocumentationMarkdown :=
          '**Free Pascal `' + SdkCands[I].Version + '`**' + #10#10 +
          FormatSdkCandidateHoverSection(SdkCands[I]);
        Item.SortText := Format('%.2d_%s', [I, SdkCands[I].Version]);
        Item.FilterText := SdkCands[I].Version;
        Item.HasTextEdit := True;
        Item.TextEdit := TLspTextEdit.Create(Ctx.ReplaceRange, SdkCands[I].Version);
        Result.Items[I] := Item;
      end;
      Exit;
    end;

    // 2b. Relative file/directory path completions
    if (Ctx.Role = ycrScalarValue) and IsEntryFileField(Ctx.CanonicalField) then
    begin
      BuildRelativePathCompletions(AManifestPath, Ctx, True, False, False, Result);
      Exit;
    end;

    if (Ctx.Role = ycrSeqItem) and IsDirectoryListField(Ctx.CanonicalField) then
    begin
      BuildRelativePathCompletions(AManifestPath, Ctx, False, False, False, Result);
      if Ctx.IsOverlay and Ctx.IsFirstListElement and (ATriggerChar <> '/') then
      begin
        Item := Default(TLspCompletionItem);
        Item.LabelText := '$reset';
        Item.Kind := lcikKeyword;
        Item.Detail := 'Overlay list reset';
        Item.DocumentationMarkdown := 'Clears inherited directories before appending subsequent paths.';
        Item.SortText := '99_$reset';
        Item.FilterText := '$reset';
        if Ctx.IsQuotedToken then
          NewVal := '$reset'
        else
          NewVal := '"$reset"';
        Item.HasTextEdit := True;
        Item.TextEdit := TLspTextEdit.Create(Ctx.ReplaceRange, NewVal);
        OutCount := Length(Result.Items);
        SetLength(Result.Items, OutCount + 1);
        Result.Items[OutCount] := Item;
      end;
      Exit;
    end;

    if (Ctx.Role = ycrScalarValue) and (Ctx.CanonicalField = 'depMapping.path') then
    begin
      BuildRelativePathCompletions(AManifestPath, Ctx, False, True, False, Result);
      Exit;
    end;

    if (Ctx.Role = ycrScalarValue) and (Ctx.CanonicalParent = 'dependencies') and
       ((Ctx.TokenText = '') or (Ctx.TokenText[1] = '.')) then
    begin
      BuildRelativePathCompletions(AManifestPath, Ctx, False, True, True, Result);
      Exit;
    end;

    if (ATriggerChar = '/') or (ATriggerChar = '.') then
      Exit;

    // 2c. Static Enum / ModeSwitch / Check / Boolean completions
    EnumCount := GetEnumSpecsForField(Ctx.CanonicalField, Ctx.IsOverlay and Ctx.IsFirstListElement, EnumSpecs);
    if EnumCount > 0 then
    begin
      OutCount := 0;
      SetLength(Result.Items, EnumCount);
      for I := 0 to EnumCount - 1 do
      begin
        Item := Default(TLspCompletionItem);
        Item.LabelText := EnumSpecs[I].Value;
        if EnumSpecs[I].Value = '$reset' then
          Item.Kind := lcikKeyword
        else
          Item.Kind := lcikEnumMember;
        Item.Detail := EnumSpecs[I].Detail;
        Item.DocumentationMarkdown := EnumSpecs[I].Documentation;
        Item.SortText := Format('%.2d_%s', [I, EnumSpecs[I].Value]);
        Item.FilterText := EnumSpecs[I].Value;

        if (EnumSpecs[I].Value = '$reset') and (not Ctx.IsQuotedToken) then
          NewVal := '"$reset"'
        else
          NewVal := EnumSpecs[I].Value;

        Item.HasTextEdit := True;
        Item.TextEdit := TLspTextEdit.Create(Ctx.ReplaceRange, NewVal);
        Result.Items[OutCount] := Item;
        Inc(OutCount);
      end;
      SetLength(Result.Items, OutCount);
      Exit;
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  Hierarchical DocumentSymbol Outline for nik.yaml
  --------------------------------------------------------------------------- }

function BuildManifestDocumentSymbols(ADoc: TLspDocument): TLspDocumentSymbolArray;
type
  TSymFrame = record
    Indent: Integer;
    SymbolIdx: Integer;
  end;
var
  Frames: array of TSymFrame;
  FrameCount, SymCount, L, I: Integer;
  RawLine, ScalarDetail: string;
  Parsed: TYamlLogicalLine;
  Sym: TLspDocumentSymbol;
  DummyQuoted: Boolean;
begin
  Result := nil;
  if (ADoc = nil) or (ADoc.LineCount <= 0) then
    Exit;

  Frames := nil;
  FrameCount := 0;
  SymCount := 0;

  for L := 0 to ADoc.LineCount - 1 do
  begin
    RawLine := ADoc.GetLineText(L);
    Parsed := ReadYamlLine(RawLine);
    if Parsed.IsBlank or Parsed.IsSeqItem or (not Parsed.HasColon) or (Parsed.KeyName = '') then
      Continue;

    while (FrameCount > 0) and (Frames[FrameCount - 1].Indent >= Parsed.Indent) do
      Dec(FrameCount);

    Sym := Default(TLspDocumentSymbol);
    if FrameCount > 0 then
      Sym.ParentIndex := Frames[FrameCount - 1].SymbolIdx
    else
      Sym.ParentIndex := -1;

    Sym.Name := Parsed.KeyName;
    if Parsed.ValStartByte > 0 then
    begin
      ScalarDetail := StripQuotes(Copy(RawLine, Parsed.ValStartByte, Parsed.ValEndByte - Parsed.ValStartByte + 1), DummyQuoted);
      Sym.Detail := ScalarDetail;
      if (Length(ScalarDetail) >= 2) and (ScalarDetail[1] = '[') then
        Sym.Kind := lskArray
      else if SameText(ScalarDetail, 'true') or SameText(ScalarDetail, 'false') then
        Sym.Kind := lskBoolean
      else
        Sym.Kind := lskProperty;
    end
    else
    begin
      if (Sym.ParentIndex < 0) and
         ((Parsed.KeyName = 'program') or (Parsed.KeyName = 'library') or (Parsed.KeyName = 'package')) then
        Sym.Kind := lskPackage
      else if IsSequenceFieldKey(Parsed.KeyName) then
        Sym.Kind := lskArray
      else
        Sym.Kind := lskNamespace;
    end;

    Sym.SelectionRange := MakeLineRange(L, RawLine, Parsed.KeyStartByte, Parsed.KeyEndByte + 1);
    Sym.Range := MakeLineRange(L, RawLine, Parsed.KeyStartByte, Parsed.TrimRightEnd + 1);

    SetLength(Result, SymCount + 1);
    Result[SymCount] := Sym;

    for I := 0 to FrameCount - 1 do
      Result[Frames[I].SymbolIdx].Range.EndPos := Sym.Range.EndPos;

    SetLength(Frames, FrameCount + 1);
    Frames[FrameCount].Indent := Parsed.Indent;
    Frames[FrameCount].SymbolIdx := SymCount;
    Inc(FrameCount);
    Inc(SymCount);
  end;
end;

end.
