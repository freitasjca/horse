program StreamingFailureCheck;

{$APPTYPE CONSOLE}

// The factory is process-global; failure injection must never run concurrently
// with successful stream tests in the same process.
uses
  System.SysUtils,
  Horse,
  DUnitX.TestFramework,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  Tests.StreamFactory.Http;

var
  runner: ITestRunner;
  results: IRunResults;
begin
  ReportMemoryLeaksOnShutdown := True;
{$IFDEF HORSE_RADIX_ROUTER}
  THorse.UseRadixRouter;
{$ENDIF}
  try
    TDUnitX.CheckCommandLine;
    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := False;
    runner.FailsOnNoAsserts := True;
    runner.AddLogger(TDUnitXConsoleLogger.Create(True));
    runner.AddLogger(TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile));
    results := runner.Execute;
    if (results.TestCount <> 2) or not results.AllPassed then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
