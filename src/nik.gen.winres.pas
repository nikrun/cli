unit nik.gen.winres;

{$mode objfpc}{$H+}

{ Pure text generators for the Windows resource of a program/library: the .rc script (icon, VERSIONINFO,
  manifest reference) and the application manifest XML. Nothing here touches the file system. }

interface

uses
  SysUtils, nik.types, nik.manifest.types;

const
  { File names inside the generated directory the .rc script refers to. }
  WINRES_ICON_FILE     = 'icon.ico';
  WINRES_MANIFEST_FILE = 'app.manifest';

{ Wide RC string literal (L"...") for a UTF-8 text. Quotes, backslashes, control and non-ASCII characters
  become \xHHHH escapes (the RC compiler of the SDK mangles raw UTF-8 and mis-reads \" and \\).
  Characters outside the BMP are not supported by fpcres and end up as '?'. }
function RcWideString(const AUtf8: string): string;

{ Numeric FILEVERSION/PRODUCTVERSION: windows.version, else derived from the effective version string,
  else 0.0.0.0. }
function EffectiveWindowsVersion(const AWin: TResolvedWindows; const AVersionText: string): TWindowsVersion;

{ Application manifest XML generated from the 'manifest' switches (not used when manifest.file is set). }
function BuildWindowsManifestXml(const AWin: TResolvedWindows): string;

{ .rc script. AHasIcon/AHasManifest decide whether the ICON/RT_MANIFEST lines are emitted; the files
  themselves are expected next to the script under WINRES_ICON_FILE/WINRES_MANIFEST_FILE. }
function BuildWindowsRcSource(const AManifest: TResolvedManifest; const AVersionText: string;
  AHasIcon, AHasManifest: Boolean): string;

implementation

const
  FLAG_DEBUG        = 1;
  FLAG_PRERELEASE   = 2;
  FLAG_PRIVATEBUILD = 8;

  { supportedOS GUIDs of the Windows application manifest }
  OS_WIN7  = '{35138b9a-5d96-4fbd-8e2d-a2440225f93a}';
  OS_WIN8  = '{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}';
  OS_WIN81 = '{1f676c76-80e1-4239-95bb-83d0f6d0da78}';
  OS_WIN10 = '{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}';

function RcWideString(const AUtf8: string): string;
var
  Wide: UnicodeString;
  I: Integer;
  Code: Word;
  Safe, PrevEscaped: Boolean;
begin
  Wide := UTF8Decode(AUtf8);
  Result := 'L"';
  PrevEscaped := False;
  for I := 1 to Length(Wide) do
  begin
    Code := Ord(Wide[I]);
    Safe := (Code >= 32) and (Code < 127) and (Code <> Ord('"')) and (Code <> Ord('\'));
    // A hex digit right after an escape would be swallowed by the \x escape: escape it as well.
    if Safe and PrevEscaped and (Char(Code) in ['0'..'9', 'A'..'F', 'a'..'f']) then
      Safe := False;
    if Safe then
      Result := Result + Char(Code)
    else
      Result := Result + '\x' + IntToHex(Code, 4);
    PrevEscaped := not Safe;
  end;
  Result := Result + '"';
end;

function EffectiveWindowsVersion(const AWin: TResolvedWindows; const AVersionText: string): TWindowsVersion;
begin
  if (Trim(AWin.Version) <> '') and TryParseWindowsVersion(Trim(AWin.Version), Result) then
    Exit;
  TryDeriveWindowsVersion(AVersionText, Result);
end;

function OsGuid(const AName: string): string;
begin
  if AName = 'win7' then
    Result := OS_WIN7
  else if AName = 'win8' then
    Result := OS_WIN8
  else if AName = 'win81' then
    Result := OS_WIN81
  else if AName = 'win10' then
    Result := OS_WIN10
  else
    raise ENikError.CreateFmt('Unsupported windows.manifest.supportedOS value: %s', [AName]);
end;

function BuildWindowsManifestXml(const AWin: TResolvedWindows): string;
var
  Level, Dpi, Settings: string;
  I: Integer;
  Systems: TStringArray;
  HasSystem: Boolean;

  procedure AddLine(const ALine: string);
  begin
    Result := Result + ALine + LineEnding;
  end;

  procedure AddSetting(const ALine: string);
  begin
    Settings := Settings + '      ' + ALine + LineEnding;
  end;

begin
  Level := AWin.ExecutionLevel;
  if Level = '' then
    Level := 'asInvoker';

  Systems := AWin.SupportedOS;
  if Length(Systems) = 0 then
  begin
    SetLength(Systems, 1);
    Systems[0] := 'win10';
  end;

  Settings := '';
  Dpi := AWin.DpiAwareness;
  if Dpi = 'system' then
  begin
    AddSetting('<dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>');
    AddSetting('<dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">System</dpiAwareness>');
  end
  else if Dpi = 'perMonitor' then
  begin
    AddSetting('<dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>');
    AddSetting('<dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitor</dpiAwareness>');
  end
  else if Dpi = 'perMonitorV2' then
  begin
    AddSetting('<dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>');
    AddSetting('<dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2,PerMonitor</dpiAwareness>');
  end;
  if AWin.HasLongPaths and AWin.LongPaths then
    AddSetting('<longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>');
  if AWin.HasUtf8 and AWin.Utf8 then
    AddSetting('<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>');

  Result := '';
  AddLine('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
  AddLine('<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">');
  AddLine('  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">');
  AddLine('    <security>');
  AddLine('      <requestedPrivileges>');
  AddLine('        <requestedExecutionLevel level="' + Level + '" uiAccess="false"/>');
  AddLine('      </requestedPrivileges>');
  AddLine('    </security>');
  AddLine('  </trustInfo>');
  AddLine('  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">');
  AddLine('    <application>');
  for I := 0 to High(Systems) do
    AddLine('      <supportedOS Id="' + OsGuid(Systems[I]) + '"/>');
  AddLine('    </application>');
  AddLine('  </compatibility>');
  HasSystem := Settings <> '';
  if HasSystem then
  begin
    AddLine('  <application xmlns="urn:schemas-microsoft-com:asm.v3">');
    AddLine('    <windowsSettings>');
    Result := Result + Settings;
    AddLine('    </windowsSettings>');
    AddLine('  </application>');
  end;
  AddLine('</assembly>');
end;

function FlagsValue(const AFlags: TStringArray): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AFlags) do
    if AFlags[I] = 'debug' then
      Result := Result or FLAG_DEBUG
    else if AFlags[I] = 'prerelease' then
      Result := Result or FLAG_PRERELEASE
    else if AFlags[I] = 'privateBuild' then
      Result := Result or FLAG_PRIVATEBUILD
    else
      raise ENikError.CreateFmt('Unsupported windows.info.flags value: %s', [AFlags[I]]);
end;

function FirstNonEmpty(const A, B: string): string;
begin
  if A <> '' then
    Result := A
  else
    Result := B;
end;

function BuildWindowsRcSource(const AManifest: TResolvedManifest; const AVersionText: string;
  AHasIcon, AHasManifest: Boolean): string;
var
  W: TResolvedWindows;
  V: TWindowsVersion;
  Product, Description, InternalName, OriginalName, VersionStr, OutputBase: string;
  IsLibrary: Boolean;
  ManifestId: Integer;
  VersionCsv: string;

  procedure AddLine(const ALine: string);
  begin
    Result := Result + ALine + LineEnding;
  end;

  procedure AddValue(const AKey, AValue: string; AAlways: Boolean = False);
  begin
    if AAlways or (AValue <> '') then
      AddLine('      VALUE "' + AKey + '", ' + RcWideString(AValue));
  end;

begin
  W := AManifest.Windows;
  IsLibrary := AManifest.Kind = mkLibrary;
  V := EffectiveWindowsVersion(W, AVersionText);
  VersionCsv := Format('%d,%d,%d,%d', [V[0], V[1], V[2], V[3]]);

  VersionStr := Trim(AVersionText);
  if VersionStr = '' then
    VersionStr := Format('%d.%d.%d.%d', [V[0], V[1], V[2], V[3]]);

  Product := FirstNonEmpty(W.Product, AManifest.ProjectName);
  Description := FirstNonEmpty(W.Description, AManifest.Description);
  Description := FirstNonEmpty(Description, Product);
  InternalName := FirstNonEmpty(W.InternalName, AManifest.ProjectName);

  OutputBase := ExtractFileName(StringReplace(AManifest.Output, '\', '/', [rfReplaceAll]));
  if OutputBase = '' then
    OutputBase := AManifest.ProjectName;
  if ExtractFileExt(OutputBase) = '' then
  begin
    if IsLibrary then
      OutputBase := OutputBase + '.dll'
    else
      OutputBase := OutputBase + '.exe';
  end;
  OriginalName := FirstNonEmpty(W.OriginalFilename, OutputBase);

  Result := '';
  if AHasIcon then
  begin
    AddLine('1 ICON "' + WINRES_ICON_FILE + '"');
    AddLine('');
  end;
  if AHasManifest then
  begin
    // 1 = CREATEPROCESS_MANIFEST_RESOURCE_ID (executables), 2 = ISOLATIONAWARE_MANIFEST_RESOURCE_ID (DLLs)
    if IsLibrary then
      ManifestId := 2
    else
      ManifestId := 1;
    AddLine(Format('%d 24 "%s"', [ManifestId, WINRES_MANIFEST_FILE]));
    AddLine('');
  end;

  AddLine('1 VERSIONINFO');
  AddLine('FILEVERSION ' + VersionCsv);
  AddLine('PRODUCTVERSION ' + VersionCsv);
  AddLine('FILEFLAGSMASK 0x3fL');
  AddLine(Format('FILEFLAGS 0x%xL', [FlagsValue(W.Flags)]));
  AddLine('FILEOS 0x40004L');
  if IsLibrary then
    AddLine('FILETYPE 0x2L')
  else
    AddLine('FILETYPE 0x1L');
  AddLine('BEGIN');
  AddLine('  BLOCK "StringFileInfo"');
  AddLine('  BEGIN');
  AddLine('    BLOCK "040904B0"');
  AddLine('    BEGIN');
  AddValue('CompanyName', W.Company);
  AddValue('FileDescription', Description);
  AddValue('FileVersion', VersionStr, True);
  AddValue('InternalName', InternalName);
  AddValue('LegalCopyright', W.Copyright);
  AddValue('OriginalFilename', OriginalName);
  AddValue('ProductName', Product);
  AddValue('ProductVersion', VersionStr, True);
  AddValue('Comments', W.Comments);
  AddLine('    END');
  AddLine('  END');
  AddLine('  BLOCK "VarFileInfo"');
  AddLine('  BEGIN');
  AddLine('    VALUE "Translation", 0x0409, 1200');
  AddLine('  END');
  AddLine('END');
end;

end.
