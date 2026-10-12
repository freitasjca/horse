program TlsPolicyCheck;

{$APPTYPE CONSOLE}

uses
  SysUtils, IdSSLOpenSSL, Horse.Provider.IOHandleSSL,
  Horse.Provider.IOHandleSSL.Contract;

var
  Config: IHorseProviderIOHandleSSL;
  Options, Expected: TIdSSLOptions;
  Version: TIdSSLVersion;
  Checks, Failures: Integer;

procedure Check(const Condition: Boolean; const MessageText: string);
begin
  Inc(Checks);
  if not Condition then
  begin
    Inc(Failures);
    Writeln('FAIL: ', MessageText);
  end;
end;

procedure CheckApplied;
begin
  // Same assignment order used by Console, Daemon and VCL providers.
  Options.Method := Config.Method;
  Options.SSLVersions := Config.SSLVersions;
  Check(Options.Method = Expected.Method, 'applied Method');
  Check(Options.SSLVersions = Expected.SSLVersions, 'applied SSLVersions');
  Check(Config.Method = Expected.Method, 'configuration Method');
  Check(Config.SSLVersions = Expected.SSLVersions, 'configuration SSLVersions');
end;

begin
  ReportMemoryLeaksOnShutdown := True;
  Options := TIdSSLOptions.Create;
  Expected := TIdSSLOptions.Create;
  try
    Config := THorseProviderIOHandleSSL.New;
    Check(Config.Active, 'TLS handler active by default');
    Expected.SSLVersions := [sslvTLSv1_2];
    CheckApplied;
    // Each explicit method must survive provider initialization, including
    // deliberate legacy opt-ins and Indy's special negotiation method.
    for Version := Low(TIdSSLVersion) to High(TIdSSLVersion) do
    begin
      Config := THorseProviderIOHandleSSL.New;
      Config.Method(Version);
      Expected.Method := Version;
      CheckApplied;
      Config.SSLVersions([sslvTLSv1_1, sslvTLSv1_2]);
      Expected.SSLVersions := [sslvTLSv1_1, sslvTLSv1_2];
      CheckApplied;
      Config.Method(Version);
      Expected.Method := Version;
      CheckApplied;
    end;
    Config.SSLVersions([sslvTLSv1, sslvTLSv1_1, sslvTLSv1_2]);
    Expected.SSLVersions := [sslvTLSv1, sslvTLSv1_1, sslvTLSv1_2];
    CheckApplied;
    Config.SSLVersions([sslvTLSv1_2]);
    Expected.SSLVersions := [sslvTLSv1_2];
    CheckApplied;
    Config.SSLVersions([sslvSSLv23]);
    Expected.SSLVersions := [sslvSSLv23];
    CheckApplied;
    Config.SSLVersions([]);
    Expected.SSLVersions := [];
    CheckApplied;
    Config := nil;
  finally
    Expected.Free;
    Options.Free;
  end;
  Writeln('checks=', Checks, ' failures=', Failures);
  if Failures <> 0 then ExitCode := 1;
end.
