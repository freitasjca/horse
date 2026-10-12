# Indy TLS protocol policy

The built-in Delphi Indy providers (Console, Daemon and VCL) configure HTTPS
through `THorse.IOHandleSSL`. New handlers now default to **TLS 1.2 only**, rather
than inheriting Indy's TLS 1.0-only default.

```pascal
uses Horse, IdSSLOpenSSL;

begin
  THorse.IOHandleSSL
    .CertFile('server.crt')
    .KeyFile('server.key')
    .SSLVersions([sslvTLSv1_2]);
  THorse.Listen(9000);
end;
```

`Method(...)` and `SSLVersions(...)` are two views of the same policy. The last
setter wins, using the installed Indy's own normalization. For example,
`SSLVersions([sslvTLSv1]).Method(sslvTLSv1_2)` now really selects TLS 1.2 instead
of silently retaining TLS 1.0 when the provider initializes.

`SSLVersions` is an unordered allow-list, not a retry/preference list. With
multiple allowed versions, Indy/OpenSSL negotiates the highest mutually
supported protocol; Horse does not attempt each set element in enum order.
`sslvSSLv23` is Indy's historical negotiation selector, not TLS 1.3, and retains
Indy's legacy semantics (including permission for obsolete SSL versions).
Prefer an explicit version set.

## Compatibility and scope

Applications relying on implicit TLS 1.0 must migrate their clients. Explicit
legacy configurations remain accepted for compatibility, but enabling TLS
1.0/1.1 is discouraged. This does not change plain HTTP, external providers or
the shared `THorseProviderConfig` TLS fields.

The stock `IdSSLOpenSSL` adapter supports at most TLS 1.2 and requires compatible
OpenSSL binaries; this change does **not** add TLS 1.3 or upgrade OpenSSL. Use a
TLS-capable external provider or reverse proxy when newer TLS support is needed.
The built-in HttpSys/IOCP/Epoll and FPC providers do not gain HTTPS from this
change; binding an OS certificate alone does not enable it in Horse.

See [provider capabilities](providers.md) and
[reproducible TLS regression tests](../tests/tls-policy/README.md).
