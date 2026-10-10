param([string[]]$Versions = @('22.0', '23.0', '37.0'))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$output = Join-Path $root ('benchmarks/results/stream-factory-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $output | Out-Null
$count = 0
foreach ($version in $Versions) {
    $studio = "C:/Program Files (x86)/Embarcadero/Studio/$version"
    if (-not (Test-Path "$studio/bin/dcc32.exe")) { continue }
    foreach ($define in @('', 'HORSE_CROSSSOCKET', 'HORSE_PROVIDER_CROSSSOCKET',
            'HORSE_NGHTTP2', 'HORSE_PROVIDER_NGHTTP2', 'HORSE_PROVIDER_MORMOT',
            'HORSE_PROVIDER_ICS', 'HORSE_PROVIDER_IOCP', 'HORSE_PROVIDER_HTTPSYS', 'HORSE_PROVIDER_EPOLL')) {
        $name = if ($define) { $define } else { 'default' }
        $scenario = Join-Path $output "$version-$name"
        New-Item -ItemType Directory -Force $scenario | Out-Null
        $search = "$scenario;$root/src;$studio/lib/win32/release"
        $common = @('-Q', '-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi', "-U$search", "-E$scenario", "-N0$scenario")
        # First build the default dependency graph. Then recompile the REAL
        # Horse.Response unit under each define, without pulling external transports
        # through Horse.pas. This tests its initialization, not provider networking.
        & "$studio/bin/dcc32.exe" -B @common "$PSScriptRoot/StreamFactoryCheck.dpr" *> "$scenario/build.log"
        if ($LASTEXITCODE -ne 0) { throw "Build failed: $scenario/build.log" }
        if ($define) {
            & "$studio/bin/dcc32.exe" @common "-D$define" "$root/src/Horse.Response.pas" *> "$scenario/response-build.log"
            if ($LASTEXITCODE -ne 0) { throw "Response build failed: $scenario/response-build.log" }
            & "$studio/bin/dcc32.exe" @common "-D$define" "$PSScriptRoot/StreamFactoryCheck.dpr" *> "$scenario/link.log"
            if ($LASTEXITCODE -ne 0) { throw "Link failed: $scenario/link.log" }
        }
        $expect = if ($define) { 'excluded' } else { 'default' }
        & "$scenario/StreamFactoryCheck.exe" $expect *> "$scenario/run.log"
        if ($LASTEXITCODE -ne 0) { throw "Regression failed: $scenario/run.log" }
        $count++
        Write-Host "PASS $version / ${name}: $(Get-Content "$scenario/run.log" -Raw)"
    }
    foreach ($provider in @('Default', 'IOCP', 'HttpSys')) {
        foreach ($router in @('Tree', 'Radix')) {
            if (Get-NetTCPConnection -LocalPort 19127 -State Listen -ErrorAction SilentlyContinue) {
                throw 'Port 19127 is occupied; no unrelated process will be stopped.'
            }
            $scenario = Join-Path $output "$version-HTTP-$provider-$router"
            New-Item -ItemType Directory -Force $scenario | Out-Null
            $defines = 'HORSE_CONSOLE'
            if ($provider -eq 'IOCP') { $defines += ';HORSE_PROVIDER_IOCP' }
            if ($provider -eq 'HttpSys') { $defines += ';HORSE_PROVIDER_HTTPSYS' }
            if ($router -eq 'Radix') { $defines += ';HORSE_RADIX_ROUTER' }
            & "$studio/bin/dcc32.exe" -B -Q "-D$defines" '-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi' "-U$root/src;$PSScriptRoot;$studio/lib/win32/release;$studio/source/DUnitX" "-E$scenario" "-N0$scenario" "$PSScriptRoot/StreamingFailureCheck.dpr" *> "$scenario/build.log"
            if ($LASTEXITCODE -ne 0) { throw "HTTP build failed: $scenario/build.log" }
            & "$scenario/StreamingFailureCheck.exe" "--xml:$scenario/results.xml" *> "$scenario/run.log"
            if ($LASTEXITCODE -ne 0 -or (Get-Content "$scenario/run.log" -Raw) -match 'Unexpected Memory Leak') {
                throw "HTTP regression failed: $scenario/run.log"
            }
            $count++
            Write-Host "PASS $version / HTTP / $provider / $router"
        }
    }
}
if ($count -eq 0) { throw 'No installed compiler was exercised.' }
Write-Host "PASS $count scenarios. Reports: $output"
