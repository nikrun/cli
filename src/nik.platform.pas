unit nik.platform;

{$mode objfpc}{$H+}

interface

procedure HardenHostProcess;
function GetHostOs: string;
function GetHostCpu: string;
function GetHostTriplet: string;
function GetCompileTimeCpu: string;

implementation

uses
  SysUtils
  {$IFDEF WINDOWS}
  , Windows
  {$ENDIF};

procedure HardenHostProcess;
{$IFDEF WINDOWS}
const
  LOAD_LIBRARY_SEARCH_SYSTEM32 = DWORD($00000800);
type
  TSetDefaultDllDirectoriesFn = function(DirectoryFlags: DWORD): BOOL; stdcall;
var
  KernelMod: HMODULE;
  SetDefaultDllDirs: TSetDefaultDllDirectoriesFn;
{$ENDIF}
begin
{$IFDEF WINDOWS}
  KernelMod := GetModuleHandle('kernel32.dll');
  if KernelMod <> 0 then
  begin
    Pointer(SetDefaultDllDirs) := GetProcAddress(KernelMod, 'SetDefaultDllDirectories');
    if Assigned(SetDefaultDllDirs) then
      SetDefaultDllDirs(LOAD_LIBRARY_SEARCH_SYSTEM32);
  end;
{$ENDIF}
end;

function GetHostOs: string;
begin
{$IF DEFINED(WINDOWS)}
  Result := 'win64';
{$ELSEIF DEFINED(DARWIN)}
  Result := 'darwin';
{$ELSEIF DEFINED(LINUX)}
  Result := 'linux';
{$ELSE}
  Result := LowerCase({$I %FPCTARGETOS%});
{$ENDIF}
end;

function GetCompileTimeCpu: string;
begin
{$IF DEFINED(CPUAARCH64)}
  Result := 'aarch64';
{$ELSEIF DEFINED(CPUX86_64)}
  Result := 'x86_64';
{$ELSE}
  Result := LowerCase({$I %FPCTARGETCPU%});
{$ENDIF}
end;

function GetHostCpu: string;
{$IFDEF WINDOWS}
const
  IMAGE_FILE_MACHINE_ARM64 = Word($AA64);
  IMAGE_FILE_MACHINE_AMD64 = Word($8664);
type
  TIsWow64Process2Fn = function(hProcess: HANDLE; pProcessMachine, pNativeMachine: PWORD): BOOL; stdcall;
var
  KernelMod: HMODULE;
  IsWow64Process2Fn: TIsWow64Process2Fn;
  ProcMachine, NativeMachine: Word;
  ArchEnv, WowArchEnv: string;
{$ENDIF}
begin
{$IFDEF WINDOWS}
  KernelMod := GetModuleHandle('kernel32.dll');
  if KernelMod <> 0 then
  begin
    Pointer(IsWow64Process2Fn) := GetProcAddress(KernelMod, 'IsWow64Process2');
    if Assigned(IsWow64Process2Fn) then
    begin
      ProcMachine := 0;
      NativeMachine := 0;
      if IsWow64Process2Fn(GetCurrentProcess, @ProcMachine, @NativeMachine) then
      begin
        if NativeMachine = IMAGE_FILE_MACHINE_ARM64 then
          Exit('aarch64');
        if NativeMachine = IMAGE_FILE_MACHINE_AMD64 then
          Exit('x86_64');
      end;
    end;
  end;

  WowArchEnv := UpperCase(Trim(SysUtils.GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')));
  ArchEnv := UpperCase(Trim(SysUtils.GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')));
  if (WowArchEnv = 'ARM64') or (ArchEnv = 'ARM64') then
    Exit('aarch64');
  if (WowArchEnv = 'AMD64') or (ArchEnv = 'AMD64') then
    Exit('x86_64');
{$ENDIF}
  Result := GetCompileTimeCpu;
end;

function GetHostTriplet: string;
begin
  Result := GetHostCpu + '-' + GetHostOs;
end;

end.
