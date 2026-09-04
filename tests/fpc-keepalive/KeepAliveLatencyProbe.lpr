program KeepAliveLatencyProbe;

{ ============================================================================
  fphttpserver keep-alive latency probe — reproducer for HashLoad/horse#562

  A RAW TCP client. It does not link Horse and does not care how the server is
  built, so it can be pointed at any HTTP server and the two keep-alive
  configurations are produced by running YOUR server twice (see RUNNING below).
  That keeps the measurement independent of the thing being measured.

  WHAT IT SATISFIES FROM #562
  ---------------------------
    raw TCP client, reuse provable        one socket() for the whole run; the
                                          fd is printed, and any reconnect
                                          would be a hard failure, not a retry
    several sequential HTTP/1.1 requests  N requests, each fully read before
                                          the next is written
    keep-alive on vs off                  same binary, run twice; the report is
                                          designed to be diffed
    distribution, not a threshold         min / median / p90 / p95 / max, and
                                          NO pass-fail on absolute milliseconds
    requests already on the socket        scenario B pipelines 3 requests in
                                          one write, then reads all responses
    Connection header validation          the header is captured and printed
                                          for every response
    behaviour after close                 scenario C writes one more request
                                          after the server closes and reports
                                          exactly what happens (EOF vs RST)

  WHAT IT DELIBERATELY DOES NOT DO
  --------------------------------
  It does not decide whether a delay is Nagle, delayed-ACK, or the server's
  wait loop. It measures; attribution needs strace/tcpdump alongside. Running
  it under strace is the intended next step:

    strace -f -T -e trace=select,poll,ppoll,read,write,recvfrom,sendto \
           -o /tmp/srv.strace  <your server>

  and correlating the select/poll durations with the per-request latencies
  printed here.

  RUNNING
  -------
    fpc -MDelphi -B KeepAliveLatencyProbe.lpr
    ./KeepAliveLatencyProbe 127.0.0.1 9000 /ping 20

  Then, against the SAME server built two ways:

    (a) as master stands — Horse.Provider.FPC.HTTPApplication.pas currently
        forces keep-alive on:
            THorseEmbeddedServerAccess(LServer).KeepConnections := True;
            if ... KeepConnectionTimeout <= 0 then
              ... KeepConnectionTimeout := DEFAULT_KEEPALIVE_TIMEOUT_MS;

    (b) with those lines commented out (fphttpserver's own default is
        KeepConnections = False).

  Diff the two reports. Absolute numbers vary by machine; the shape of the
  distribution and the ratio between (a) and (b) are what carry meaning.

  Exit code is 0 unless the probe itself failed (connect error, malformed
  response). A slow server is a RESULT, not a failure — that is the point of
  not asserting a threshold.
  ============================================================================ }

{$MODE DELPHI}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Sockets, BaseUnix,
  Unix,              { fpGetTimeOfDay — BaseUnix supplies fpSelect/fpRecv, not this }
  DateUtils, Math;

var
  GHost: string    = '127.0.0.1';
  GPort: Integer   = 9000;
  GPath: string    = '/ping';
  GCount: Integer  = 20;
  GNoDelay: Boolean = False;   { 5th arg: 1 = set TCP_NODELAY on the client socket }

var
  GBaseSec: Int64 = 0;

{ Milliseconds since program start, NOT since the epoch.

  Returning absolute epoch ms (~1.7e12) in a Double throws away everything
  below roughly 0.1 ms: a Double carries ~15-16 significant digits and 13 of
  them are already spent on the integer part. The first version of this probe
  did that and printed min=p50=max=0.00 for every sample on loopback, where the
  true round trip is 50-200 us. Anchoring to a baseline keeps the values small
  and preserves full microsecond resolution. }
function NowMs: Double;
var
  LTv: TTimeVal;
begin
  fpGetTimeOfDay(@LTv, nil);
  if GBaseSec = 0 then
    GBaseSec := LTv.tv_sec;
  Result := (LTv.tv_sec - GBaseSec) * 1000.0 + LTv.tv_usec / 1000.0;
end;

{ TCP_NODELAY on the CLIENT socket, controllable from the command line.

  This matters for attribution. Without it, a small request can be held by
  Nagle on the client until the peer's delayed ACK fires (~40 ms on Linux) —
  which looks exactly like a slow server. An strace of the server then shows
  select() BLOCKING and returning 1 with data, rather than timing out: proof
  that the server was waiting for bytes that had not arrived, not spinning in
  a poll loop.

  Run the probe both ways. If the latency collapses with nodelay=1, the delay
  was in the client's send path and says nothing about the server. }
function SetNoDelay(ASock: LongInt): Boolean;
var
  LOn: cint;
begin
  LOn := 1;
  Result := fpSetSockOpt(ASock, IPPROTO_TCP, TCP_NODELAY, @LOn, SizeOf(LOn)) = 0;
end;

function ConnectRaw(out ASock: LongInt): Boolean;
var
  LAddr: TInetSockAddr;
begin
  Result := False;
  ASock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if ASock < 0 then Exit;
  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(GPort);
  LAddr.sin_addr   := StrToNetAddr(GHost);
  if fpConnect(ASock, @LAddr, SizeOf(LAddr)) <> 0 then
  begin
    fpClose(ASock);
    ASock := -1;
    Exit;
  end;
  if GNoDelay then
    SetNoDelay(ASock);
  Result := True;
end;

function WaitReadable(ASock: LongInt; ATimeoutMS: Integer): Boolean;
var
  LSet: TFDSet;
  LTv:  TTimeVal;
begin
  fpFD_ZERO(LSet);
  fpFD_SET(ASock, LSet);
  LTv.tv_sec  := ATimeoutMS div 1000;
  LTv.tv_usec := (ATimeoutMS mod 1000) * 1000;
  Result := fpSelect(ASock + 1, @LSet, nil, nil, @LTv) > 0;
end;

procedure SendRequest(ASock: LongInt; const APath: string; const AClose: Boolean);
var
  LReq: string;
begin
  LReq := 'GET ' + APath + ' HTTP/1.1'#13#10 +
          'Host: ' + GHost + ':' + IntToStr(GPort) + #13#10;
  if AClose then
    LReq := LReq + 'Connection: close'#13#10;
  LReq := LReq + #13#10;
  fpSend(ASock, @LReq[1], Length(LReq), 0);
end;

{ Reads exactly one HTTP response: headers, then a body sized by
  Content-Length. Returns False on EOF or timeout — both are results worth
  reporting, so the caller decides what they mean. }
function ReadOneResponse(ASock: LongInt; ATimeoutMS: Integer;
  out AHeaders: string; out AClosedByPeer: Boolean): Boolean;
var
  LBuf: array[0..8191] of Byte;
  LN, LHdrEnd, LLen, LBodyGot, LNeed: Integer;
  LAll, LLine, LLower: string;
  I: Integer;
begin
  Result := False; AHeaders := ''; AClosedByPeer := False;
  LAll := '';

  { headers }
  repeat
    if not WaitReadable(ASock, ATimeoutMS) then Exit;
    LN := fpRecv(ASock, @LBuf[0], SizeOf(LBuf), 0);
    if LN = 0 then begin AClosedByPeer := True; Exit; end;
    if LN < 0 then Exit;
    SetLength(LLine, LN);
    Move(LBuf[0], LLine[1], LN);
    LAll := LAll + LLine;
    LHdrEnd := Pos(#13#10#13#10, LAll);
  until LHdrEnd > 0;

  AHeaders := Copy(LAll, 1, LHdrEnd + 3);

  { Content-Length }
  LLen := 0;
  LLower := LowerCase(AHeaders);
  I := Pos('content-length:', LLower);
  if I > 0 then
    LLen := StrToIntDef(Trim(Copy(AHeaders, I + 15,
              Pos(#13#10, Copy(AHeaders, I, MaxInt)) - 16)), 0);

  LBodyGot := Length(LAll) - (LHdrEnd + 3);
  while LBodyGot < LLen do
  begin
    LNeed := LLen - LBodyGot;
    if not WaitReadable(ASock, ATimeoutMS) then Exit;
    LN := fpRecv(ASock, @LBuf[0], Min(LNeed, SizeOf(LBuf)), 0);
    if LN <= 0 then begin AClosedByPeer := LN = 0; Exit; end;
    Inc(LBodyGot, LN);
  end;
  Result := True;
end;

function HeaderValue(const AHeaders, AName: string): string;
var
  LLower: string;
  I, J: Integer;
begin
  Result := '';
  LLower := LowerCase(AHeaders);
  I := Pos(LowerCase(AName) + ':', LLower);
  if I = 0 then Exit;
  Inc(I, Length(AName) + 1);
  J := Pos(#13#10, Copy(AHeaders, I, MaxInt));
  if J = 0 then Exit;
  Result := Trim(Copy(AHeaders, I, J - 1));
end;

procedure Report(const ALabel: string; const ATimes: array of Double; ACount: Integer);
var
  LSorted: array of Double;
  I, J: Integer;
  LV: Double;

  function Pct(P: Double): Double;
  var
    K: Integer;
  begin
    K := Trunc(P * (ACount - 1) + 0.5);
    if K < 0 then K := 0;
    if K > ACount - 1 then K := ACount - 1;
    Result := LSorted[K];
  end;

begin
  if ACount = 0 then
  begin
    WriteLn('  ', ALabel, ': no samples');
    Exit;
  end;
  SetLength(LSorted, ACount);
  for I := 0 to ACount - 1 do LSorted[I] := ATimes[I];
  { Insertion sort — ACount is small and this keeps the program dependency-free.
    Locals declared up front: FPC 3.2.2 has no inline var. }
  for I := 1 to ACount - 1 do
  begin
    LV := LSorted[I];
    J  := I - 1;
    while (J >= 0) and (LSorted[J] > LV) do
    begin
      LSorted[J + 1] := LSorted[J];
      Dec(J);
    end;
    LSorted[J + 1] := LV;
  end;
  WriteLn(Format('  %s  n=%d  min=%.2f  p50=%.2f  p90=%.2f  p95=%.2f  max=%.2f  (ms)',
    [ALabel, ACount, LSorted[0], Pct(0.50), Pct(0.90), Pct(0.95), LSorted[ACount-1]]));
end;

{ ── Scenario A: sequential requests on ONE socket ───────────────────────── }
procedure ScenarioA;
var
  LSock: LongInt;
  LTimes: array of Double;
  LHeaders: string;
  LClosed: Boolean;
  I, LOk: Integer;
  LT0: Double;
begin
  WriteLn;
  WriteLn('── A  ', GCount, ' sequential HTTP/1.1 requests on ONE socket ──────────');
  if not ConnectRaw(LSock) then
  begin
    WriteLn('  FAIL  connect to ', GHost, ':', GPort);
    Halt(1);
  end;
  WriteLn('  socket fd = ', LSock, '  (never reconnected below; a close is reported, not retried)');

  SetLength(LTimes, GCount);
  LOk := 0;
  for I := 1 to GCount do
  begin
    LT0 := NowMs;
    SendRequest(LSock, GPath, False);
    if not ReadOneResponse(LSock, 5000, LHeaders, LClosed) then
    begin
      if LClosed then
        WriteLn('  request ', I, ': server CLOSED the connection (no keep-alive)')
      else
        WriteLn('  request ', I, ': timeout / malformed response');
      Break;
    end;
    LTimes[LOk] := NowMs - LT0;
    Inc(LOk);
    if I = 1 then
      WriteLn('  first response Connection: "', HeaderValue(LHeaders, 'Connection'), '"');
  end;

  Report('sequential', LTimes, LOk);
  if LOk < GCount then
    WriteLn('  NOTE: only ', LOk, '/', GCount,
            ' completed on one socket — the server is not keeping it open.');
  fpClose(LSock);
end;

{ ── Scenario B: requests already sitting in the socket buffer ───────────── }
procedure ScenarioB;
var
  LSock: LongInt;
  LReq, LHeaders: string;
  LClosed: Boolean;
  I, LOk: Integer;
  LT0: Double;
  LTimes: array of Double;
begin
  WriteLn;
  WriteLn('── B  3 pipelined requests written in ONE syscall ────────────────');
  if not ConnectRaw(LSock) then
  begin
    WriteLn('  FAIL  connect');
    Exit;
  end;
  LReq := '';
  for I := 1 to 3 do
    LReq := LReq + 'GET ' + GPath + ' HTTP/1.1'#13#10 +
                   'Host: ' + GHost + ':' + IntToStr(GPort) + #13#10#13#10;
  LT0 := NowMs;
  fpSend(LSock, @LReq[1], Length(LReq), 0);

  SetLength(LTimes, 3);
  LOk := 0;
  for I := 1 to 3 do
  begin
    if not ReadOneResponse(LSock, 5000, LHeaders, LClosed) then
    begin
      if LClosed then
        WriteLn('  response ', I, ': connection closed before it arrived')
      else
        WriteLn('  response ', I, ': timeout');
      Break;
    end;
    LTimes[LOk] := NowMs - LT0;   { cumulative: shows arrival spacing }
    Inc(LOk);
  end;
  WriteLn('  responses received: ', LOk, '/3   (cumulative arrival times below)');
  Report('pipelined', LTimes, LOk);
  WriteLn('  If the server waits between already-available requests, the gaps');
  WriteLn('  here are the wait loop, not the network.');
  fpClose(LSock);
end;

{ ── Scenario C: what a pooling client would hit after the server closes ─── }
procedure ScenarioC;
var
  LSock: LongInt;
  LHeaders: string;
  LClosed: Boolean;
  LN: LongInt;
  LBuf: array[0..255] of Byte;
begin
  WriteLn;
  WriteLn('── C  reuse after the server closes (the ECONNRESET question) ────');
  if not ConnectRaw(LSock) then
  begin
    WriteLn('  FAIL  connect');
    Exit;
  end;
  SendRequest(LSock, GPath, False);
  if not ReadOneResponse(LSock, 5000, LHeaders, LClosed) then
  begin
    WriteLn('  FAIL  no first response');
    fpClose(LSock);
    Exit;
  end;
  WriteLn('  response 1 Connection: "', HeaderValue(LHeaders, 'Connection'), '"');

  Sleep(300);
  SendRequest(LSock, GPath, False);
  if ReadOneResponse(LSock, 3000, LHeaders, LClosed) then
    WriteLn('  reuse OK — the socket was still usable (true keep-alive)')
  else if LClosed then
    WriteLn('  reuse got EOF — server had closed. A pooling client would see')
  else
  begin
    LN := fpRecv(LSock, @LBuf[0], SizeOf(LBuf), 0);
    if (LN < 0) and (fpgeterrno = ESysECONNRESET) then
      WriteLn('  reuse got ECONNRESET — exactly the risk raised in the review')
    else
      WriteLn('  reuse: no response, errno=', fpgeterrno);
  end;
  WriteLn('  Whether the server announced "Connection: close" above decides');
  WriteLn('  whether a client can be blamed for reusing this socket.');
  fpClose(LSock);
end;

begin
  if ParamCount >= 1 then GHost  := ParamStr(1);
  if ParamCount >= 2 then GPort  := StrToIntDef(ParamStr(2), GPort);
  if ParamCount >= 3 then GPath  := ParamStr(3);
  if ParamCount >= 4 then GCount := StrToIntDef(ParamStr(4), GCount);
  if ParamCount >= 5 then GNoDelay := ParamStr(5) = '1';

  WriteLn('keep-alive latency probe — target http://', GHost, ':', GPort, GPath);
  WriteLn('samples: ', GCount, '   client TCP_NODELAY: ', GNoDelay,
          '   (no pass/fail threshold — this reports, it does not judge)');

  ScenarioA;
  ScenarioB;
  ScenarioC;

  WriteLn;
  WriteLn('Run this against the same server built two ways (keep-alive forced on,');
  WriteLn('as master does today, and with those lines removed) and diff the output.');
  Halt(0);
end.
