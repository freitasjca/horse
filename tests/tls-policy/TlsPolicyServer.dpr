program TlsPolicyServer;

{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, SyncObjs, Horse, IdSSLOpenSSL;

type
  TServerThread = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Command: string;
  ServerThread: TServerThread;
  Ready: TEvent;
  StartupError: string;

procedure TServerThread.Execute;
begin
  try
    THorse.Listen(StrToInt(ParamStr(1)), '127.0.0.1',
      procedure
      begin
        Ready.SetEvent;
      end);
  except
    on E: Exception do
    begin
      StartupError := E.ClassName + ': ' + E.Message;
      Ready.SetEvent;
    end;
  end;
end;

procedure RegisterRoutes;
begin
  THorse.Get('/tls',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.Send('tls-policy-ok');
    end);
end;

begin
  ReportMemoryLeaksOnShutdown := True;
  try
    if ParamCount <> 4 then
      raise Exception.Create('Usage: TlsPolicyServer port cert key default|mixed|method');
    // Match the normal Console provider lifecycle. stdin controls shutdown.
    THorse.ReadTimeout := 2000;
    THorse.IOHandleSSL.CertFile(ParamStr(2)).KeyFile(ParamStr(3));
    if ParamStr(4) = 'mixed' then
      THorse.IOHandleSSL.SSLVersions([sslvTLSv1, sslvTLSv1_1, sslvTLSv1_2])
    else if ParamStr(4) = 'method' then
      THorse.IOHandleSSL.SSLVersions([sslvTLSv1]).Method(sslvTLSv1_2)
    else if ParamStr(4) <> 'default' then
      raise Exception.Create('Unknown policy');
    RegisterRoutes;
    Ready := TEvent.Create(nil, True, False, '');
    ServerThread := TServerThread.Create(True);
    ServerThread.FreeOnTerminate := False;
    ServerThread.Start;
    try
      if Ready.WaitFor(10000) <> wrSignaled then
        raise Exception.Create('Listener initialization timed out');
      if StartupError <> '' then
        raise Exception.Create(StartupError);
      Writeln('READY');
      Flush(Output);
      Readln(Command);
    finally
      THorse.StopListenGraceful(2000);
      ServerThread.WaitFor;
      THorse.OnListen := nil;
      ServerThread.Free;
      Ready.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
