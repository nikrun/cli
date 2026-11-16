unit nik.types;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  NIK_VERSION           = '0.1.0';
  NIK_SCHEMA_VERSION    = 1;
  DEFAULT_SDK_INDEX_URL = 'https://github.com/nikrun/sdk/releases/download/latest/index.json';
  ENV_NIKRUN_HOME       = 'NIKRUN_HOME';
  ENV_SDK_INDEX_URL     = 'NIKRUN_SDK_INDEX_URL';

type
  ENikError = class(Exception)
  private
    FExitCode: Integer;
  public
    procedure AfterConstruction; override;
    constructor CreateWithCode(const AMsg: string; AExitCode: Integer);
    property ExitCode: Integer read FExitCode write FExitCode;
  end;

  TSdkPaths = record
    BinDir: string;
    FpcBinary: string;
    PpcBinary: string;
    FpcmkcfgBinary: string;
    UnitsDir: string;
    RtlSourceDir: string;
    PackagesSourceDir: string;
  end;

  TSdkManifest = record
    SchemaVersion: Integer;
    SdkId: string;
    FpcVersion: string;
    GitRepo: string;
    GitRef: string;
    GitCommit: string;
    TargetOs: string;
    TargetCpu: string;
    TargetTriplet: string;
    BuiltAtUtc: string;
    Paths: TSdkPaths;
  end;

  TInstalledSdk = record
    Manifest: TSdkManifest;
    InstallPath: string;
  end;
  TInstalledSdkArray = array of TInstalledSdk;

  TRemoteSdkEntry = record
    SdkId: string;
    FpcVersion: string;
    GitRepo: string;
    GitRef: string;
    GitCommit: string;
    TargetOs: string;
    TargetCpu: string;
    TargetTriplet: string;
    BuiltAtUtc: string;
    FileName: string;
    SizeBytes: Int64;
    Sha256: string;
    DownloadUrl: string;
  end;
  TRemoteSdkArray = array of TRemoteSdkEntry;

  TSdkIndex = record
    SchemaVersion: Integer;
    ReleaseTag: string;
    UpdatedAtUtc: string;
    Sdks: TRemoteSdkArray;
  end;

  TDownloadProgressProc = procedure(ABytesRead, ATotalBytes: Int64);

implementation

procedure ENikError.AfterConstruction;
begin
  inherited AfterConstruction;
  if FExitCode = 0 then
    FExitCode := 1;
end;

constructor ENikError.CreateWithCode(const AMsg: string; AExitCode: Integer);
begin
  inherited Create(AMsg);
  if AExitCode <> 0 then
    FExitCode := AExitCode
  else
    FExitCode := 1;
end;

end.
