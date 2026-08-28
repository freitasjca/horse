unit Horse.Provider.FPC.HTTPApplication;

{ PATCH-FPCHTTP-1: ListenWithConfig override — same root cause as PATCH-CONSOLE-1. }
{ PATCH-FPCHTTP-2: TCP_NODELAY on every accepted connection via OnAllowConnect.
  fphttpserver never calls setsockopt(TCP_NODELAY) on accepted sockets; without it
  the Nagle + delayed-ACK interaction adds ~40 ms per request on non-loopback links.
  Guards: FPC >= 3.3.1 (custhttpapp required); UNIX only (fpSetSockOpt). }

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

{$IF DEFINED(FPC)}
uses
  SysUtils,
  Classes,
  httpdefs,
  fpHTTP,
  fphttpapp,
  Horse.Provider.Abstract,
  Horse.Provider.Config,
  Horse.Constants,
  Horse.Proc;

type
  THorseProvider = class(THorseProviderAbstract)
  private
    class var FPort: Integer;
    class var FHost: string;
    class var FRunning: Boolean;
    class var FListenQueue: Integer;
    class var FHTTPApplication: THTTPApplication;
    class function GetDefaultHTTPApplication: THTTPApplication;
    class function HTTPApplicationIsNil: Boolean;
    class procedure SetListenQueue(const AValue: Integer); static;
    class procedure SetPort(const AValue: Integer); static;
    class procedure SetHost(const AValue: string); static;
    class function GetListenQueue: Integer; static;
    class function GetPort: Integer; static;
    class function GetDefaultPort: Integer; static;
    class function GetDefaultHost: string; static;
    class function GetHost: string; static;
    class procedure InternalListen; virtual;
    class procedure DoGetModule(Sender: TObject; ARequest: TRequest; var ModuleClass: TCustomHTTPModuleClass);
    {$IF FPC_FULLVERSION >= 30301}
    class procedure EnableServerNoDelay(const AApplication: THTTPApplication);
    class procedure SetNoDelayOnAccept(Sender: TObject; ASocket: Longint; var Allow: Boolean);
    {$ENDIF}
  public
    class property Host: string read GetHost write SetHost;
    class property Port: Integer read GetPort write SetPort;
    class property ListenQueue: Integer read GetListenQueue write SetListenQueue;
    class function GetActivePort: Integer; override;
    class procedure Listen; overload; override;
    class procedure Listen(const APort: Integer; const AHost: string = '0.0.0.0';
      const ACallbackListen: TProc = nil; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const APort: Integer; const ACallbackListen: TProc;
      const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const AHost: string; const ACallbackListen: TProc = nil;
      const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const ACallbackListen: TProc;
      const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    // PATCH-FPCHTTP-1
    class procedure ListenWithConfig(const APort: Integer;
      const AConfig: THorseCrossSocketConfig); override;
    class function IsRunning: Boolean;
  end;
{$ENDIF}

implementation

{$IF DEFINED(FPC)}

uses
  Horse.WebModule,
  Horse.Response
  {$IF FPC_FULLVERSION >= 30301}, custhttpapp{$ENDIF}
  {$IFDEF UNIX}, Sockets{$ENDIF};

{$IF FPC_FULLVERSION >= 30301}
const
  {$IFDEF UNIX}
  { TCP_NODELAY = 1 on every POSIX platform (Linux/macOS/FreeBSD).
    Declared here to avoid pulling in linux.pp / bsd.pp for one constant. }
  HORSE_TCP_NODELAY = 1;
  {$ENDIF}

type
  { Friend classes: descendants declared in the same unit gain access to
    protected members of their ancestors from fcl-web, regardless of the
    visibility the library declares for them.
    - THorseHTTPServerHandlerAccess: reaches the protected HTTPServer property.
    - THorseEmbeddedServerAccess: reaches the protected OnAllowConnect property
      (forwarded from TInetServer but never re-published as public on
      TEmbeddedHttpServer). }
  THorseHTTPServerHandlerAccess = class(custhttpapp.TFPHTTPServerHandler);
  THorseEmbeddedServerAccess    = class(custhttpapp.TEmbeddedHttpServer);

{ PATCH-FPCHTTP-2 — set TCP_NODELAY on each accepted socket.
  TSocketServer.OnAllowConnect fires immediately after fpAccept() returns the
  raw file descriptor, before CreateStream wraps it and before the connection
  thread starts — the descriptor is valid for setsockopt at that point. }
{$IFDEF UNIX}
class procedure THorseProvider.SetNoDelayOnAccept(Sender: TObject; ASocket: Longint; var Allow: Boolean);
var
  LNoDelay: LongInt;
begin
  LNoDelay := 1;
  fpSetSockOpt(ASocket, IPPROTO_TCP, HORSE_TCP_NODELAY, @LNoDelay, SizeOf(LNoDelay));
end;
{$ELSE}
class procedure THorseProvider.SetNoDelayOnAccept(Sender: TObject; ASocket: Longint; var Allow: Boolean);
begin
  { Non-UNIX path: Windows FPC would need WinSock2.setsockopt.
    Left as a no-op — see PR body for the Windows follow-up path. }
end;
{$ENDIF}

class procedure THorseProvider.EnableServerNoDelay(const AApplication: THTTPApplication);
var
  LHandler: TFPHTTPServerHandler;
  LServer: TEmbeddedHttpServer;
begin
  LHandler := AApplication.HTTPHandler;
  if LHandler = nil then
    Exit;
  LServer := THorseHTTPServerHandlerAccess(LHandler).HTTPServer;
  { OnAllowConnect is protected on TFPCustomHttpServer — use the friend class,
    the same pattern already established for KeepConnections. }
  if LServer <> nil then
    THorseEmbeddedServerAccess(LServer).OnAllowConnect := THorseProvider.SetNoDelayOnAccept;
end;
{$ENDIF} // FPC_FULLVERSION >= 30301

class function THorseProvider.GetDefaultHTTPApplication: THTTPApplication;
begin
  if HTTPApplicationIsNil then
    FHTTPApplication := Application;
  Result := FHTTPApplication;
end;

class function THorseProvider.HTTPApplicationIsNil: Boolean;
begin
  Result := FHTTPApplication = nil;
end;

class function THorseProvider.GetDefaultHost: string;
begin
  Result := DEFAULT_HOST;
end;

class function THorseProvider.GetDefaultPort: Integer;
begin
  Result := DEFAULT_PORT;
end;

class function THorseProvider.GetHost: string;
begin
  Result := FHost;
end;

class function THorseProvider.GetListenQueue: Integer;
begin
  Result := FListenQueue;
end;

class function THorseProvider.GetPort: Integer;
begin
  Result := FPort;
end;

class function THorseProvider.GetActivePort: Integer;
begin
  Result := FPort;
end;

class procedure THorseProvider.InternalListen;
var
  LHTTPApplication: THTTPApplication;
begin
  TriggerBeforeListen;
  inherited;
  if FPort <= 0 then
    FPort := GetDefaultPort;
  if FHost.IsEmpty then
    FHost := GetDefaultHost;
  if FListenQueue = 0 then
    FListenQueue := 15;
  LHTTPApplication := GetDefaultHTTPApplication;
  LHTTPApplication.AllowDefaultModule := True;
  LHTTPApplication.OnGetModule := DoGetModule;
  LHTTPApplication.Threaded := True;
  LHTTPApplication.QueueSize := FListenQueue;
  LHTTPApplication.Port := FPort;
  LHTTPApplication.LegacyRouting := True;
  LHTTPApplication.Address := FHost;
  LHTTPApplication.Initialize;
  {$IF FPC_FULLVERSION >= 30301}
  { fphttpserver's keepalive loop (TFPHTTPConnectionThread) polls with a fixed
    ~40 ms select() interval to check for shutdown signals.  With keepalive
    enabled every response cycle waits one full interval even when the next
    request is already queued, giving a consistent ~40 ms per-request stall.
    Measured at 44 ms P50 on Linux in the Horse P1 bench (50 000 requests,
    -c 1); confirmed to be the loop's poll interval, not Nagle (TCP_NODELAY
    was applied and had no effect).  Without fphttpserver patching this cannot
    be reduced — KeepConnections stays False (the default).
    PATCH-FPCHTTP-2 — TCP_NODELAY on every accepted socket.  Avoids Nagle on
    non-loopback links (VMs, containers, production hosts). }
  EnableServerNoDelay(LHTTPApplication);
  {$ENDIF}
  FRunning := True;
  DoOnListen;
  LHTTPApplication.Run;
end;

class procedure THorseProvider.DoGetModule(Sender: TObject; ARequest: TRequest; var ModuleClass: TCustomHTTPModuleClass);
begin
  ModuleClass := THorseWebModule;
end;

class function THorseProvider.IsRunning: Boolean;
begin
  Result := FRunning;
end;

class procedure THorseProvider.Listen;
begin
  InternalListen;;
end;

class procedure THorseProvider.Listen(const APort: Integer; const AHost: string; const ACallbackListen, ACallbackStopListen: TProc);
begin
  SetPort(APort);
  SetHost(AHost);
  SetOnListen(ACallbackListen);
  SetOnStopListen(ACallbackStopListen);
  InternalListen;
end;

class procedure THorseProvider.Listen(const APort: Integer; const ACallbackListen, ACallbackStopListen: TProc);
begin
  Listen(APort, FHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProvider.Listen(const AHost: string; const ACallbackListen, ACallbackStopListen: TProc);
begin
  Listen(FPort, AHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProvider.Listen(const ACallbackListen, ACallbackStopListen: TProc);
begin
  Listen(FPort, FHost, ACallbackListen, ACallbackStopListen);
end;

// PATCH-FPCHTTP-1
class procedure THorseProvider.ListenWithConfig(const APort: Integer;
  const AConfig: THorseCrossSocketConfig);
begin
  SetPort(APort);
  InternalListen;
end;

class procedure THorseProvider.SetHost(const AValue: string);
begin
  FHost := AValue;
end;

class procedure THorseProvider.SetListenQueue(const AValue: Integer);
begin
  FListenQueue := AValue;
end;

class procedure THorseProvider.SetPort(const AValue: Integer);
begin
  FPort := AValue;
end;
{$ENDIF}

end.
