param(
    [string[]]$Versions = @('17.0', '22.0', '23.0', '37.0'),
    [Parameter(Mandatory)][string]$OpenSsl,
    [Parameter(Mandatory)][string]$OpenSslDllDirectory,
    [ValidateRange(1024, 65535)][int]$Port = 19130
)
# Requires PowerShell 7. OpenSSL CLI and Indy-compatible Win32 OpenSSL DLLs
# are supplied by the caller; nothing is downloaded or installed by this test.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$output = Join-Path $root ('benchmarks/results/tls-policy-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $output | Out-Null
$OpenSsl = (Resolve-Path $OpenSsl).Path
foreach ($dll in @('libeay32.dll', 'ssleay32.dll')) {
    if (-not (Test-Path (Join-Path $OpenSslDllDirectory $dll))) { throw "Missing $dll" }
}

function New-Child([string]$File, [string[]]$Arguments) {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $File
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['HORSE_TEST_SILENCE'] = '1'
    foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Cannot start $File" }
    return $process
}

function Invoke-Peer([string]$Name, [string[]]$Protocol, [bool]$Success, [string]$ExpectedProtocol) {
    $peer = New-Child $OpenSsl (@('s_client', '-connect', "127.0.0.1:$Port",
        '-servername', 'localhost', '-verify_hostname', 'localhost', '-verify_return_error',
        '-CAfile', "$output/cert.pem", '-brief', '-ign_eof', '-cipher', 'DEFAULT:@SECLEVEL=0') + $Protocol)
    try {
        $stdout = $peer.StandardOutput.ReadToEndAsync()
        $stderr = $peer.StandardError.ReadToEndAsync()
        $peer.StandardInput.Write("GET /tls HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n")
        $peer.StandardInput.Close()
        if (-not $peer.WaitForExit(10000)) { throw "$Name timed out" }
        $text = $stdout.Result + "`n" + $stderr.Result
        $text | Set-Content "$scenario/$Name.log"
        if ($Success) {
            if ($peer.ExitCode -ne 0 -or $text -notmatch 'HTTP/1.1 200' -or
                    $text -notmatch 'tls-policy-ok' -or $text -notmatch "Protocol version: $([regex]::Escape($ExpectedProtocol))") {
                throw "$Name failed: $scenario/$Name.log"
            }
        } elseif ($peer.ExitCode -eq 0 -or $text -match 'tls-policy-ok' -or
                  $text -notmatch 'alert protocol version|unsupported protocol') {
            throw "$Name did not reject the legacy protocol: $scenario/$Name.log"
        }
        Write-Host "PASS $version / $policy / $Name"
    } finally {
        if (-not $peer.HasExited) { $peer.Kill(); $peer.WaitForExit() }
        $peer.Dispose()
    }
}

& $OpenSsl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj '/CN=localhost' `
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -keyout "$output/key.pem" -out "$output/cert.pem" *> "$output/certificate.log"
if ($LASTEXITCODE -ne 0) { throw 'Test certificate generation failed' }
$count = 0
foreach ($version in $Versions) {
    $studio = "C:/Program Files (x86)/Embarcadero/Studio/$version"
    if (-not (Test-Path "$studio/bin/dcc32.exe")) { throw "Compiler $version is not installed" }
    $scenario = Join-Path $output $version
    New-Item -ItemType Directory -Force $scenario | Out-Null
    foreach ($program in @('TlsPolicyCheck', 'TlsPolicyServer')) {
        & "$studio/bin/dcc32.exe" -B -Q '-DHORSE_CONSOLE' '-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi' `
            "-U$root/src;$studio/lib/win32/release" "-E$scenario" "-N0$scenario" "$PSScriptRoot/$program.dpr" *> "$scenario/$program-build.log"
        if ($LASTEXITCODE -ne 0) { throw "Build failed: $scenario/$program-build.log" }
    }
    & "$scenario/TlsPolicyCheck.exe" *> "$scenario/unit.log"
    if ($LASTEXITCODE -ne 0 -or (Get-Content "$scenario/unit.log" -Raw) -match 'Unexpected Memory Leak') {
        throw "Unit regression failed: $scenario/unit.log"
    }
    Write-Host "PASS $version / $(Get-Content "$scenario/unit.log" -Raw)"
    Copy-Item (Join-Path $OpenSslDllDirectory 'libeay32.dll'), (Join-Path $OpenSslDllDirectory 'ssleay32.dll') $scenario
    foreach ($policy in @('default', 'mixed', 'method')) {
        if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
            throw "Port $Port is occupied; no unrelated listener will be stopped"
        }
        $server = New-Child "$scenario/TlsPolicyServer.exe" @("$Port", "$output/cert.pem", "$output/key.pem", $policy)
        try {
            $errorOutput = $server.StandardError.ReadToEndAsync()
            $ready = $server.StandardOutput.ReadLineAsync()
            if (-not $ready.Wait(15000)) { throw "Server $policy initialization timed out" }
            if ($ready.Result -ne 'READY') { throw "Server $policy did not initialize: $($ready.Result)" }
            Invoke-Peer "$policy-auto" @() $true 'TLSv1.2'
            Invoke-Peer "$policy-tls12" @('-tls1_2') $true 'TLSv1.2'
            if ($policy -eq 'mixed') {
                Invoke-Peer "$policy-tls11-optin" @('-tls1_1') $true 'TLSv1.1'
                Invoke-Peer "$policy-tls10-optin" @('-tls1') $true 'TLSv1'
            } else {
                Invoke-Peer "$policy-reject-tls11" @('-tls1_1') $false ''
                Invoke-Peer "$policy-reject-tls10" @('-tls1') $false ''
            }
            $server.StandardInput.WriteLine('stop')
            $server.StandardInput.Close()
            if (-not $server.WaitForExit(30000)) { throw 'Server shutdown timed out' }
            $tail = $server.StandardOutput.ReadToEnd() + $errorOutput.Result
            $tail | Set-Content "$scenario/$policy-server.log"
            if ($server.ExitCode -ne 0 -or $tail -match 'Unexpected Memory Leak') { throw 'Server shutdown failed' }
        } finally {
            if (-not $server.HasExited) { $server.Kill(); $server.WaitForExit() }
            $server.Dispose()
        }
    }
    $count++
}
if ($count -eq 0) { throw 'No compiler exercised' }
Write-Host "PASS $count compilers; 93 configuration checks and 12 real TLS/HTTP probes per compiler. Reports: $output"
