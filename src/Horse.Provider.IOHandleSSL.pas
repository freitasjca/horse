unit Horse.Provider.IOHandleSSL;

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
  IdSSLOpenSSL,
  Horse.Provider.IOHandleSSL.Contract;

type
  THorseProviderIOHandleSSL = class(TInterfacedObject, IHorseProviderIOHandleSSL)
  private
    FKeyFile: string;
    FRootCertFile: string;
    FCertFile: string;
    FDHParamsFile: string;
    FCipherList: string;
    FMethod: TIdSSLVersion;
    FSSLVersions: TIdSSLVersions;
    FOnGetPassword: TPasswordEvent;
    FActive: Boolean;
    function Active: Boolean; overload;
    function Active(const AValue: Boolean): IHorseProviderIOHandleSSL; overload;
    function CertFile: string; overload;
    function CertFile(const AValue: string): IHorseProviderIOHandleSSL; overload;
    function RootCertFile: string; overload;
    function RootCertFile(const AValue: string): IHorseProviderIOHandleSSL; overload;
    function KeyFile: string; overload;
    function KeyFile(const AValue: string): IHorseProviderIOHandleSSL; overload;
    function Method: TIdSSLVersion; overload;
    function Method(const AValue: TIdSSLVersion): IHorseProviderIOHandleSSL; overload;
    function SSLVersions: TIdSSLVersions; overload;
    function SSLVersions(const AValue: TIdSSLVersions): IHorseProviderIOHandleSSL; overload;
    function DHParamsFile: string; overload;
    function DHParamsFile(const AValue: string): IHorseProviderIOHandleSSL; overload;
    function CipherList: string; overload;
    function CipherList(const AValue: string): IHorseProviderIOHandleSSL; overload;
    function OnGetPassword: TPasswordEvent; overload;
    function OnGetPassword(const AValue: TPasswordEvent): IHorseProviderIOHandleSSL; overload;
  public
    constructor Create;
    class function New: IHorseProviderIOHandleSSL;
  end;

implementation

function THorseProviderIOHandleSSL.Active(const AValue: Boolean): IHorseProviderIOHandleSSL;
begin
  FActive := AValue;
  Result := Self;
end;

function THorseProviderIOHandleSSL.Active: Boolean;
begin
  Result := FActive;
end;

function THorseProviderIOHandleSSL.CertFile(const AValue: string): IHorseProviderIOHandleSSL;
begin
  FCertFile := AValue;
  Result := Self;
end;

function THorseProviderIOHandleSSL.CipherList: string;
begin
  Result := FCipherList;
end;

function THorseProviderIOHandleSSL.CipherList(const AValue: string): IHorseProviderIOHandleSSL;
begin
  FCipherList := AValue;
  Result := Self;
end;

function THorseProviderIOHandleSSL.CertFile: string;
begin
  Result := FCertFile;
end;

constructor THorseProviderIOHandleSSL.Create;
begin
  FActive := True;
  // Do not inherit Indy's legacy TLS 1.0-only defaults. This OpenSSL adapter
  // supports TLS 1.2; older protocols require an explicit application opt-in.
  FMethod := sslvTLSv1_2;
  FSSLVersions := [sslvTLSv1_2];
end;

function THorseProviderIOHandleSSL.DHParamsFile: string;
begin
  Result := FDHParamsFile;
end;

function THorseProviderIOHandleSSL.DHParamsFile(const AValue: string): IHorseProviderIOHandleSSL;
begin
  FDHParamsFile := AValue;
  Result := Self;
end;

function THorseProviderIOHandleSSL.KeyFile(const AValue: string): IHorseProviderIOHandleSSL;
begin
  FKeyFile := AValue;
  Result := Self;
end;

function THorseProviderIOHandleSSL.KeyFile: string;
begin
  Result := FKeyFile;
end;

function THorseProviderIOHandleSSL.Method(const AValue: TIdSSLVersion): IHorseProviderIOHandleSSL;
var
  LOptions: TIdSSLOptions;
begin
  // Keep both views consistent, including Indy's sslvSSLv23 special case.
  // Providers assign Method followed by SSLVersions to the real IOHandler.
  LOptions := TIdSSLOptions.Create;
  try
    LOptions.Method := AValue;
    FMethod := LOptions.Method;
    FSSLVersions := LOptions.SSLVersions;
  finally
    LOptions.Free;
  end;
  Result := Self;
end;

function THorseProviderIOHandleSSL.Method: TIdSSLVersion;
begin
  Result := FMethod;
end;

class function THorseProviderIOHandleSSL.New: IHorseProviderIOHandleSSL;
begin
  Result := THorseProviderIOHandleSSL.Create;
end;

function THorseProviderIOHandleSSL.OnGetPassword(const AValue: TPasswordEvent): IHorseProviderIOHandleSSL;
begin
  FOnGetPassword := AValue;
  Result := Self;
end;

function THorseProviderIOHandleSSL.OnGetPassword: TPasswordEvent;
begin
  Result := FOnGetPassword;
end;

function THorseProviderIOHandleSSL.RootCertFile(const AValue: string): IHorseProviderIOHandleSSL;
begin
  FRootCertFile := AValue;
  Result := Self;
end;

function THorseProviderIOHandleSSL.RootCertFile: string;
begin
  Result := FRootCertFile;
end;

function THorseProviderIOHandleSSL.SSLVersions: TIdSSLVersions;
begin
  Result := FSSLVersions;
end;

function THorseProviderIOHandleSSL.SSLVersions(const AValue: TIdSSLVersions): IHorseProviderIOHandleSSL;
var
  LOptions: TIdSSLOptions;
begin
  LOptions := TIdSSLOptions.Create;
  try
    LOptions.SSLVersions := AValue;
    FMethod := LOptions.Method;
    FSSLVersions := LOptions.SSLVersions;
  finally
    LOptions.Free;
  end;
  Result := Self;
end;

end.
