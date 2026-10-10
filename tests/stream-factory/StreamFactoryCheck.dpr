program StreamFactoryCheck;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ELSE}{$APPTYPE CONSOLE}{$ENDIF}

uses
{$IF DEFINED(FPC) AND DEFINED(UNIX)}
  cthreads,
{$ENDIF}
  SysUtils, Classes, Horse.Response;

type
  TTestWriter = class(THorseStreamWriterBase)
  protected
    procedure SendRawHeaders; override;
    procedure WriteRawBytes(const ABytes: TBytes); override;
  public
    procedure Close; override;
    function IsConnected: Boolean; override;
  end;

  TProducer = class
  public
    procedure Produce(const AWriter: IHorseStreamWriter);
  end;

var
  Response: THorseResponse;
  Calls, Closes, Checks, Failures: Integer;
  RaiseInProducer: Boolean;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  Inc(Checks);
  if not ACondition then
  begin
    Inc(Failures);
    Writeln('FAIL: ', AMessage);
  end;
end;

procedure TTestWriter.SendRawHeaders;
begin
end;

procedure TTestWriter.WriteRawBytes(const ABytes: TBytes);
begin
end;

procedure TTestWriter.Close;
begin
  Inc(Closes);
end;

function TTestWriter.IsConnected: Boolean;
begin
  Result := True;
end;

procedure Produce(const AWriter: IHorseStreamWriter);
begin
  Inc(Calls);
  Check(Response.IsStreaming, 'producer sees streaming state');
  if RaiseInProducer then
    raise Exception.Create('producer failed');
end;

procedure TProducer.Produce(const AWriter: IHorseStreamWriter);
begin
  StreamFactoryCheck.Produce(AWriter);
end;

function RefusingFactory(const AResponse: THorseResponse): IHorseStreamWriter;
begin
  Result := nil;
  raise Exception.Create('writer acquisition failed');
end;

function WorkingFactory(const AResponse: THorseResponse): IHorseStreamWriter;
begin
  Result := TTestWriter.Create(AResponse);
end;

procedure Invoke(AProducer: TProducer; AMethod: Boolean);
var
  callback: THorseStreamAnonProc;
begin
  callback := Produce;
  if AMethod then
    Response.SendStream(AProducer.Produce)
  else
    Response.SendStream(callback);
end;

procedure CheckAcquisitionFailure(AProducer: TProducer; AMethod: Boolean);
var
  raised: Boolean;
begin
  Response := THorseResponse.Create(nil);
  try
    Calls := 0;
    raised := False;
    try
      Invoke(AProducer, AMethod);
    except
      on E: Exception do raised := True;
    end;
    Check(raised, 'missing/refusing factory raises');
    Check(Calls = 0, 'failed acquisition does not invoke producer');
    Check(not Response.IsStreaming, 'failed acquisition preserves normal response');
  finally
    Response.Free;
  end;
end;

var
  producer: TProducer;
  raised, expectDefault: Boolean;
  methodIndex, failureIndex: Integer;
begin
  producer := TProducer.Create;
  try
    expectDefault := ParamStr(1) = 'default';
    Check(expectDefault or (ParamStr(1) = 'excluded'), 'explicit registration expectation');
    Response := THorseResponse.Create(nil);
    try
      raised := False;
      try
        Invoke(producer, False);
      except
        on E: Exception do raised := True;
      end;
      Check(raised <> expectDefault, 'WebBroker fallback matches selected define');
    finally
      Response.Free;
    end;
    THorseResponse.RegisterStreamWriterFactory(nil);
    for methodIndex := 0 to 1 do
      CheckAcquisitionFailure(producer, methodIndex = 1);
    THorseResponse.RegisterStreamWriterFactory(RefusingFactory);
    for methodIndex := 0 to 1 do
      CheckAcquisitionFailure(producer, methodIndex = 1);
    THorseResponse.RegisterStreamWriterFactory(WorkingFactory);
    for failureIndex := 0 to 1 do
      for methodIndex := 0 to 1 do
      begin
        Response := THorseResponse.Create(nil);
        try
          Calls := 0;
          Closes := 0;
          RaiseInProducer := failureIndex = 1;
          raised := False;
          try
            Invoke(producer, methodIndex = 1);
          except
            on E: Exception do raised := True;
          end;
          Check(raised = RaiseInProducer, 'producer exception propagates');
          Check(Calls = 1, 'producer invoked exactly once');
          Check(Closes = 1, 'writer closed exactly once, including producer failure');
        finally
          Response.Free;
        end;
      end;
    THorseResponse.RegisterStreamWriterFactory(nil);
  finally
    producer.Free;
  end;
  Writeln('checks=', Checks, ' failures=', Failures);
  if Failures > 0 then
    ExitCode := 1;
end.
