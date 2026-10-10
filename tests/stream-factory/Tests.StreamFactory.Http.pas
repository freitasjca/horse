unit Tests.StreamFactory.Http;

interface

uses
  DUnitX.TestFramework, Horse, Horse.Response, Horse.Instance, System.SysUtils, System.Classes,
  System.Net.HttpClient, System.Net.URLClient, System.SyncObjs;

type
  [TestFixture]
  TStreamFactoryHttpTests = class
  private
    FServer: TThread;
    FReady: TEvent;
    procedure AssertErrorResponse(const APath: string);
  public
    [SetupFixture]
    procedure Setup;
    [TearDownFixture]
    procedure Teardown;
    [Test]
    procedure MissingFactoryReturnsError;
    [Test]
    procedure RefusingFactoryReturnsError;
  end;

implementation

const
  TestPort = 19127;

function RefuseStreamWriter(const AResponse: THorseResponse): IHorseStreamWriter;
begin
  Result := nil;
  raise Exception.Create('stream writer unavailable');
end;

procedure TStreamFactoryHttpTests.Setup;
var
  client: THTTPClient;
  ready: Boolean;
  attempt: Integer;
begin
  FReady := TEvent.Create(nil, True, False, '');
  THorse.AddOnAfterListen(
    procedure(const AInstance: THorseInstance)
    begin
      FReady.SetEvent;
    end);
  THorse.Get('/ready',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.Send('ready');
    end);
  THorse.Get('/missing',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      try
        Res.SendStream(
          procedure(const AWriter: IHorseStreamWriter)
          begin
            raise Exception.Create('producer must not run');
          end);
      except
        on E: Exception do Res.Status(503).Send('stream writer unavailable');
      end;
    end);
  THorse.Get('/refusing',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      THorseResponse.RegisterStreamWriterFactory(RefuseStreamWriter);
      try
        try
          Res.SendStream(
            procedure(const AWriter: IHorseStreamWriter)
            begin
              raise Exception.Create('producer must not run');
            end);
        except
          on E: Exception do Res.Status(503).Send('stream writer unavailable');
        end;
      finally
        THorseResponse.RegisterStreamWriterFactory(nil);
      end;
    end);
  // Process-global failure injection: this fixture has its own executable.
  THorseResponse.RegisterStreamWriterFactory(nil);
  FServer := TThread.CreateAnonymousThread(
    procedure
    begin
      THorse.Listen(TestPort, '127.0.0.1');
    end);
  FServer.FreeOnTerminate := False;
  FServer.Start;
  // A successful HTTP probe can precede worker-pool initialization. Wait for
  // the provider lifecycle hook before exercising shutdown in this fast test.
  Assert.IsTrue(FReady.WaitFor(10000) = wrSignaled, 'Listener initialization timed out');
  client := THTTPClient.Create;
  try
    client.ConnectionTimeout := 500;
    client.ResponseTimeout := 500;
    client.CustomHeaders['Connection'] := 'close';
    ready := False;
    for attempt := 1 to 30 do
    begin
      try
        ready := client.Get(Format('http://127.0.0.1:%d/ready', [TestPort])).StatusCode = 200;
      except
        on E: Exception do ready := False;
      end;
      if ready then Break;
      Sleep(100);
    end;
    Assert.IsTrue(ready, 'Listener did not become ready');
  finally
    client.Free;
  end;
end;

procedure TStreamFactoryHttpTests.Teardown;
begin
  THorse.StopListen;
  if Assigned(FServer) then
  begin
    FServer.WaitFor;
    FServer.Free;
    FServer := nil;
  end;
  THorseResponse.RegisterStreamWriterFactory(nil);
  FReady.Free;
  FReady := nil;
end;

procedure TStreamFactoryHttpTests.AssertErrorResponse(const APath: string);
var
  client: THTTPClient;
  response: IHTTPResponse;
begin
  client := THTTPClient.Create;
  try
    client.ConnectionTimeout := 3000;
    client.ResponseTimeout := 3000;
    client.CustomHeaders['Connection'] := 'close';
    response := client.Get(Format('http://127.0.0.1:%d/%s', [TestPort, APath]));
    Assert.AreEqual(503, response.StatusCode, response.ContentAsString);
    Assert.AreEqual('stream writer unavailable', response.ContentAsString);
  finally
    client.Free;
  end;
end;

procedure TStreamFactoryHttpTests.MissingFactoryReturnsError;
begin
  AssertErrorResponse('missing');
end;

procedure TStreamFactoryHttpTests.RefusingFactoryReturnsError;
begin
  AssertErrorResponse('refusing');
end;

initialization
  TDUnitX.RegisterTestFixture(TStreamFactoryHttpTests);

end.
