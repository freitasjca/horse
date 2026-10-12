# Indy TLS policy regression (#610)

Run from PowerShell 7, supplying a modern OpenSSL CLI (tested with OpenSSL 3) and Indy-compatible **Win32**
`libeay32.dll` / `ssleay32.dll` (OpenSSL 1.0.2). Nothing is downloaded:

```powershell
./tests/tls-policy/run-tls-policy.ps1 `
  -OpenSsl 'C:/path/to/openssl.exe' `
  -OpenSslDllDirectory 'C:/path/to/openssl-1.0.2/win32'
```

Defaults: Delphi 10/11/12/13, loopback port 19130. Override with `-Versions` and
`-Port`. Occupied ports fail; only owned child processes are terminated. One-day
localhost certificates, private keys, binaries and logs remain in the ignored
`benchmarks/results/tls-policy-*` directory. Never use these keys in production.

Per compiler:

- 93 checks cover TLS 1.2 defaults, every Indy method, single/multiple version
  sets, explicit legacy opt-ins, `sslvSSLv23`, empty sets and both setter orders.
  Options are applied in the same order as Console, Daemon and VCL.
- 12 real OpenSSL handshakes/HTTP requests exercise Horse Console: defaults,
  mixed versions and `SSLVersions([TLS1.0]).Method(TLS1.2)`. Automatic negotiation
  must select TLS 1.2. Defaults/method policies reject TLS 1.0/1.1; the mixed
  policy still accepts these deliberate legacy opt-ins.
- Successful peers verify certificates and hostname and receive HTTP 200 with
  the expected body. Failure probes require a protocol rejection, not just any
  connection error. HTTP uses `Connection: close`.
- Bounded server shutdown; unexpected Delphi memory-leak reports fail.

The OpenSSL client is intentional: native HTTP clients cannot portably constrain
each offered version and expose the negotiated protocol for these assertions.
This is not a shutdown/concurrency load test.
The test client's cipher security level is lowered only to allow probing obsolete
protocols deliberately; it does not alter the server's production TLS policy.

Negative control against the pre-fix configuration on Delphi 12: **93 checks,
45 failures**. Reversing enum members or set elements is not a fix: Indy version
sets are allow-lists, not protocol preference lists.

FPC's built-in providers do not use this Indy adapter. Check them separately with
`tests/run_compile_matrix.ps1`; no FPC TLS handshake coverage is claimed here.
Daemon/VCL share the class and assignment order, but only Console is exercised
over the network by this runner.
