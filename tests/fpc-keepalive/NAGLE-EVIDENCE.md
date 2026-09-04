# FPC keep-alive ~44 ms stall — root cause: Nagle + delayed ACK

Evidence captured 2026-09-04 on Linux (FPC trunk, `fphttpserver` provider,
Horse's own `samples/lazarus/console` server, route `/ping` → 4-byte body).

Supersedes the earlier "fixed ~40 ms `select()` poll interval" reading, which
was **wrong**. See "How the earlier reading went wrong" at the bottom.

## Result after the fix (validated 2026-09-04, FPC trunk 3.3.1, Linux)

`run-keepalive-test.sh`, scenario A, same server and route:

| | before | after |
|---|---|---|
| min | 0.28 ms | 0.04 ms |
| **p50** | **43.98 ms** | **0.07 / 0.08 ms** (two runs) |
| max | 44.00 ms | 0.25 / 0.21 ms |

The stall is gone, not merely reduced — 0.08 ms is loopback round-trip time
with no 40 ms component left in the distribution.

Scenario C reports "reuse OK", which is the control that matters: keep-alive is
genuinely active rather than silently off. "Fast" alone would also be the
signature of keep-alive not being enabled at all.

Caveat on the comparison: the before/after binaries were built differently
(n=4 hand-built against the distro unit tree, vs n=20 via the script against
trunk's). The magnitude is far outside any plausible noise floor and the
mechanism was established independently by the capture below, but this is not a
controlled A/B. The decisive confirmation is to re-capture and check that the
79-byte and 4-byte segments now leave back-to-back with no ACK between them.

## Verdict

The response is written in **two `send()` calls** (79-byte header block, then
the 4-byte body). `TCP_NODELAY` is **never set** on the accepted socket, so
Nagle applies to the second write: it is smaller than MSS *and* there is
unacknowledged data outstanding (the 79 bytes), so the kernel holds it until
the peer ACKs. The peer, having nothing to send, waits for its delayed-ACK
timer (~40 ms on Linux). The ACK lands, Nagle releases, the body goes out.

## Wire capture

`tcpdump -i lo -n -ttt 'tcp port 9000'` — leading column is the delta from the
previous packet. Client port 40114, four sequential requests on one socket.

Request 1 — fast (0.28 ms end to end):

```
0.000239  9000 > 40114  length 79     headers
0.000014  40114 > 9000  ack 80        client ACKs immediately (quickack)
0.000010  9000 > 40114  length 4      body, 10 us later
```

Requests 2, 3, 4 — stalled:

```
0.000040  9000 > 40114  length 79     headers out immediately
0.042530  40114 > 9000  ack 163       delayed ACK, 42.5 ms
0.000014  9000 > 40114  length 4      body released 14 us after the ACK

0.000102  9000 > 40114  length 79
0.043827  40114 > 9000  ack 246
0.000011  9000 > 40114  length 4      11 us after the ACK

0.000088  9000 > 40114  length 79
0.043857  40114 > 9000  ack 329
0.000011  9000 > 40114  length 4      11 us after the ACK
```

## Why this is causation, not correlation

The body segment leaves **11–14 µs after the ACK arrives**, three times, while
the ACK delay itself varies (42.530 / 43.827 / 43.857 ms). The body tracks the
ACK to within microseconds across a *varying* delay. Only Nagle produces that
signature — the arriving ACK is what releases the held segment.

A fixed server-side poll interval would produce the opposite: a body timed
independently of the ACK, since a bare incoming ACK does not make a socket
readable and cannot wake a `select()` waiting for request data.

`KeepAliveLatencyProbe` on the same run reported
`n=4 min=0.28 p50=43.98 p90=44.00 max=44.00 (ms)` — `min` is request 1,
the percentiles are requests 2–4. The capture accounts for every value.

## Two controls in the same capture

**Only the first request on a connection is fast.** Linux starts a connection
in quickack mode, so early ACKs are immediate; delayed ACK engages afterwards.
Confirmed on all three connections in the capture (ports 40114, 40116, 40122).
This is exactly why the bug is invisible without keep-alive — with
`Connection: close` every request is request 1 on a fresh socket.

**A 300 ms idle gap also makes it fast.** Port 40122, second request after
300 ms think time: ACK in 16 µs, body 6 µs later. Linux re-enters quickack
after an idle period, so the stall only appears on *back-to-back* requests.

## Why the existing mitigation does nothing

`PATCH-FPCHTTP-2` sets `TFPCustomHttpServer.OnAllowConnect` (via a friend class)
intending to `setsockopt(TCP_NODELAY)` on each accepted fd. It never fires.

The reason is in fcl-web, not in the patch. In `fphttpserver.pp`:

- `CreateServerSocket` wires `FServer.OnConnectSocketQuery := @DoOnAllowConnect`
- `TFPCustomHttpServer.DoOnAllowConnect` handles only the
  `MaxLiveConnectionCount` / 503 logic and then sets `Allow := True`
- `FOnAllowConnect` is **written by `SetOnAllowConnect` and read nowhere**

So `OnAllowConnect` is a dead property in this fphttpserver version: assigning
it can never invoke the handler. Not a timing, ordering, or method-binding
problem — the library simply never calls it.

Independently confirmed at runtime: the instrumentation marker inside
`SetNoDelayOnAccept` never printed, and `grep -c TCP_NODELAY` over an `strace`
of the server returned **0**. `fphttpserver.pp` contains no `TCP_NODELAY`
anywhere, so nothing else sets it either.

## Fix directions

Both keep keep-alive enabled; neither requires patching fcl-web.

1. **Set `TCP_NODELAY` per connection at request time** — IMPLEMENTED, as
   PATCH-FPCHTTP-2 rev 2 in `patches/horse/src/`.
   Hook: `THorseProvider.DoGetModule` in the fphttpserver provider, called for
   every request from `custweb.pp`'s `TWebHandler.OldHandleRequest` (Horse sets
   `LegacyRouting := True`). From its `TRequest`,
   `TFPHTTPConnectionRequest.Connection` → `TFPHTTPConnection.Socket.Handle`
   reaches the accepted fd; both members are public, and `Socket.Handle` is the
   accessor fphttpserver itself uses.

   `THorseWebModule.HandleRequest` was the other candidate and is rejected:
   the web module is shared by every FPC provider, so putting the code there
   would pull `fphttpserver` into the epoll and daemon builds that do not use
   it. `DoGetModule` already lives in the fphttpserver provider unit.

   Applied per request rather than cached per connection — descriptor numbers
   are reused after close and connection threads run concurrently, so a cache
   keyed on the fd could silently skip a socket that needed the option. One
   sub-microsecond syscall per request is the cheaper mistake. Request 1 is
   covered too, since the option is set before the response is written.

2. **Coalesce the response into a single `send()`** so no small trailing
   segment exists. Not reachable from Horse — the two writes happen inside
   `fphttpserver`, so this needs an upstream FPC change.

Precedent for direction 1: the identical defect in the nghttp2 transport
(`FIX-NODELAY`) cost 2036 ms → 17 ms on Linux and was invisible on Windows.

## How the earlier reading went wrong

The server was observed blocking ~43 ms in `select()`, and that was recorded as
"the loop's poll interval, confirmed not Nagle". Cause and effect were
inverted: the server was idle in `select()` waiting for the *next request*,
which the client could not send because it was still waiting for a body Nagle
was holding. The accompanying claim that "TCP_NODELAY was applied and had no
effect" was false — it was never applied, for the reason above.

Three separate attempts to test the Nagle hypothesis were void rather than
negative, and each was nearly recorded as a disproof:

- setting `TCP_NODELAY` on the **client** — irrelevant; that governs the
  client's own writes, not the ACKs the server is waiting for
- the `OnAllowConnect` hook — never fires (dead property, above)
- an `LD_PRELOAD` shim over `accept()` — FPC's `fpAccept` issues the syscall
  directly and never enters libc, so the shim was never entered

A test whose instrument cannot be observed to have taken effect proves nothing.
The wire capture was decisive because it needs no instrumentation at all.

## Caveat on the source reading

`fphttpserver.pp` here is the local snapshot in `fcl-web-src/` (dated
2026-07-16). Confirm against the FPC trunk RTL actually compiled against before
shipping a fix. The runtime evidence agrees with this snapshot on every point.

## Reproducing

Server: `horse/samples/lazarus/console`, FPC trunk, keep-alive active.
Client: `KeepAliveLatencyProbe.lpr` in this directory (scenario A), or `curl`
with two URLs on one connection. Capture with
`sudo tcpdump -i lo -n -ttt 'tcp port 9000'`; cache sudo with `sudo -v` first
or the backgrounded capture suspends on the password prompt and records nothing.
