# Stream writer factory regression

*Read this in [English](./README.md) or [Português (BR)](./README.pt-BR.md).*

Regression coverage for PR #611. Run from the repository root:

```powershell
./tests/stream-factory/run-stream-factory.ps1
```

The runner uses installed Delphi 11, 12 and 13 compilers. Each scenario has isolated build artifacts under `benchmarks/results/`. No compiler installation is a failure, not a successful skip. Other supported installations can be selected with `-Versions`.

`StreamFactoryCheck.dpr` checks both callback overloads: absent/raising factories leave `IsStreaming` false and do not invoke the producer; an acquired writer sees streaming state and closes exactly once, even if the producer raises.

The Delphi registration matrix first builds the default dependency graph, then recompiles the **real Horse.Response unit** under each provider define and relinks the probe. This deliberately isolates response initialization from external transport initialization. It covers legacy/namespaced CrossSocket and nghttp2, mORMot, ICS, IOCP, HttpSys and Epoll, plus preservation of the default WebBroker fallback. It does **not** replace live external-provider tests or validate their unit initialization order.

`StreamingFailureCheck.dpr` runs two DUnitX HTTP tests with Indy, IOCP and HttpSys, using both Tree and Radix. The tests verify a 503 response and its complete body after missing/raising factory acquisition, rather than an empty 200 or a timeout. Port **19127**, IPv4 loopback only, must be available; the runner never terminates unrelated processes. Startup waits for the provider's after-listen hook and an HTTP readiness probe. Teardown stops and joins the listener thread.

Factory injection is process-global. Keep these tests in their dedicated executable, not in a concurrently running successful-stream fixture. Existing NDJSON, SSE and concurrent streaming tests remain in the main suite:

```powershell
./tests/run_delphi_tests.ps1 -Versions 22.0,23.0,37.0
```

On FPC, run the shared response-state/lifetime probe, with heaptrc leak detection:

```sh
sh tests/stream-factory/run-stream-factory.sh
```

For example, from Windows with the repository's locally built FPC test images:

```powershell
docker run --rm -v "${PWD}:/work:ro" --entrypoint sh horse-provider-tests:fpc-3.2.2 /work/tests/stream-factory/run-stream-factory.sh
docker run --rm -v "${PWD}:/work:ro" --entrypoint sh horse-provider-tests:fpc-3.3.1 /work/tests/stream-factory/run-stream-factory.sh
```

The Linux runner exercises the default FPC dependency graph; the define-isolation matrix is Delphi-only. An Epoll build registers its own writer, so expecting an absent factory in a complete Epoll program would be incorrect.
