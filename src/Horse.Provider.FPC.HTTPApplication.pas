unit Horse.Provider.FPC.HTTPApplication;

{ PATCH-FPCHTTP-1: ListenWithConfig override — same root cause as PATCH-CONSOLE-1. }
{ PATCH-FPCHTTP-2 (rev 2): TCP_NODELAY on every connection, applied per request.
  fphttpserver never calls setsockopt(TCP_NODELAY) on accepted sockets, and it
  writes each response as two send() calls (header block, then body).  Nagle
  therefore holds the small second write until the peer ACKs the first, and the
  peer — having nothing to send — waits out its ~40 ms delayed-ACK timer.  That
  is the whole of the keepalive stall; it is not a poll interval.

  rev 1 hooked TFPCustomHttpServer.OnAllowConnect.  That could never work:
  fphttpserver writes FOnAllowConnect in its setter and reads it NOWHERE, so the
  handler is never invoked.  rev 2 uses OnGetModule instead, which fcl-web does
  call for every request (custweb.pp, TWebHandler.OldHandleRequest) and which
  hands us the TRequest — and through it the accepted socket.
  Guards: FPC >= 3.3.1 (custhttpapp required); UNIX and Windows both handled. }

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
    class procedure ApplyNoDelay(const ARequest: TRequest);
    class procedure ConfigureKeepAlive(const AApplication: THTTPApplication);
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
  {$IF FPC_FULLVERSION >= 30301}, custhttpapp, fphttpserver{$ENDIF}
  {$IFDEF UNIX}, Sockets{$ENDIF}
  {$IFDEF WINDOWS}, WinSock2{$ENDIF};

{$IF FPC_FULLVERSION >= 30301}
const
  { Both values are identical on every platform Horse targets: IPPROTO_TCP = 6
    per the IANA protocol registry, and TCP_NODELAY = 1 on POSIX as well as in
    Winsock. Declared locally so neither branch has to pull in linux.pp / bsd.pp
    for a single constant, and so the UNIX and Windows paths below stay
    symmetrical. }
  HORSE_IPPROTO_TCP = 6;
  HORSE_TCP_NODELAY = 1;

  { How long a keepalive connection is held open after a request, in ms.
    fphttpserver closes it once this elapses. 15 s matches the figure the
    reverted FPC-KEEPALIVE-1 used. }
  HORSE_KEEPALIVE_TIMEOUT_MS = 15000;

type
  { Friend classes: a descendant declared in the same unit gains access to the
    protected members of its ancestor from fcl-web, regardless of the visibility
    the library declares.
    - THorseHTTPServerHandlerAccess: reaches the protected HTTPServer property.
    - THorseEmbeddedServerAccess: reaches the protected KeepConnections and
      KeepConnectionTimeout. TFPHttpServer republishes both, but
      TEmbeddedHttpServer descends from TFPCustomHttpServer directly and so
      never inherits that published section. }
  THorseHTTPServerHandlerAccess = class(custhttpapp.TFPHTTPServerHandler);
  THorseEmbeddedServerAccess    = class(custhttpapp.TEmbeddedHttpServer);

{ PATCH-FPCHTTP-2 — set TCP_NODELAY on the connection carrying this request.

  Called from DoGetModule, i.e. once per request rather than once per accepted
  socket. That is deliberate: fphttpserver exposes no usable per-connection
  hook (see the note on OnAllowConnect at the top of this unit), while
  OnGetModule is invoked for every request and carries the TRequest, whose
  Connection.Socket is the accepted descriptor.

  Applying it on the FIRST request of a connection is early enough — the option
  is set before any part of the response is written, so even that request
  avoids the stall. Repeating it on later requests of the same keepalive
  connection is a redundant but harmless syscall (setsockopt with the value
  already in effect is a no-op in the kernel).

  Deliberately NOT cached in a class var keyed on the descriptor: connection
  threads run concurrently and descriptor numbers are reused after close, so a
  stale hit would silently skip a socket that genuinely needed the option. A
  microsecond-scale syscall per request is the cheaper mistake than a 40 ms
  stall that reappears intermittently. }
class procedure THorseProvider.ApplyNoDelay(const ARequest: TRequest);
var
  LConnection: TFPHTTPConnection;
  LNoDelay: LongInt;
begin
  if not (ARequest is TFPHTTPConnectionRequest) then
    Exit;
  LConnection := TFPHTTPConnectionRequest(ARequest).Connection;
  if (LConnection = nil) or (LConnection.Socket = nil) then
    Exit;
  LNoDelay := 1;
  {$IFDEF UNIX}
  fpSetSockOpt(LongInt(LConnection.Socket.Handle), HORSE_IPPROTO_TCP,
    HORSE_TCP_NODELAY, @LNoDelay, SizeOf(LNoDelay));
  {$ELSE}
  {$IFDEF WINDOWS}
  setsockopt(TSocket(LConnection.Socket.Handle), HORSE_IPPROTO_TCP,
    HORSE_TCP_NODELAY, PAnsiChar(@LNoDelay), SizeOf(LNoDelay));
  {$ENDIF}
  {$ENDIF}
end;

{ FPC-KEEPALIVE-2 — re-enable HTTP/1.1 keepalive.

  fphttpserver defaults KeepConnections to False, so every request pays a fresh
  TCP handshake. An earlier attempt to enable it (FPC-KEEPALIVE-1) was reverted
  because it appeared to cost ~44 ms per request; that cost was the Nagle
  interaction fixed by ApplyNoDelay above, not a property of keepalive itself.
  With TCP_NODELAY in place the stall does not occur, so the trade-off that
  motivated the revert no longer applies.

  Kept as a separate routine from ApplyNoDelay so it can be dropped on its own:
  ApplyNoDelay is a pure bug fix and changes no observable behaviour, whereas
  this block changes the server's default connection handling. }
class procedure THorseProvider.ConfigureKeepAlive(const AApplication: THTTPApplication);
var
  LHandler: TFPHTTPServerHandler;
  LServer: TEmbeddedHttpServer;
begin
  LHandler := AApplication.HTTPHandler;
  if LHandler = nil then
    Exit;
  LServer := THorseHTTPServerHandlerAccess(LHandler).HTTPServer;
  if LServer = nil then
    Exit;
  THorseEmbeddedServerAccess(LServer).KeepConnections := True;
  THorseEmbeddedServerAccess(LServer).KeepConnectionTimeout := HORSE_KEEPALIVE_TIMEOUT_MS;
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
  { The ~44 ms P50 seen on Linux with keepalive enabled is Nagle interacting
    with the peer's delayed ACK — NOT a select() poll interval, and NOT
    unavoidable.  fphttpserver writes each response as two send() calls (the
    header block, then the body).  TCP_NODELAY is never set on the accepted
    socket, so the small second write is held until the peer ACKs the first;
    the peer, having nothing to send, waits out its ~40 ms delayed-ACK timer.
    Proven by wire capture: the body segment leaves 11-14 us after the ACK
    arrives, tracking a delay that itself varies 42.5-43.9 ms.  Only the first
    request on a connection is fast, because Linux starts a socket in quickack
    mode — which is exactly why the stall is invisible without keepalive, and
    why a 300 ms idle gap between requests also hides it.

    The TCP_NODELAY half of the fix is applied per request in DoGetModule, not
    here — fphttpserver offers no usable per-connection hook at listen time.
    This call only re-enables keepalive itself, which is safe to do now that
    the stall that motivated reverting it is gone. }
  ConfigureKeepAlive(LHTTPApplication);
  {$ENDIF}
  FRunning := True;
  DoOnListen;
  LHTTPApplication.Run;
end;

class procedure THorseProvider.DoGetModule(Sender: TObject; ARequest: TRequest; var ModuleClass: TCustomHTTPModuleClass);
begin
  {$IF FPC_FULLVERSION >= 30301}
  { PATCH-FPCHTTP-2 — earliest per-request point at which the accepted socket
    is reachable, and still ahead of any response write. }
  ApplyNoDelay(ARequest);
  {$ENDIF}
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
