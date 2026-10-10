param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '../..'))
# Run from the repository root: ./tests/docs/check-ics-docs.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$icsPages = @('README.md', 'README.pt-BR.md', 'doc/providers.md', 'doc/providers.pt-BR.md',
    'doc/compiler-support.md', 'doc/compiler-support.pt-BR.md', 'doc/deployment.md', 'doc/deployment.pt-BR.md')
$failures = @()
foreach ($page in $icsPages) {
    $content = Get-Content -LiteralPath (Join-Path $root $page) -Raw
    foreach ($line in ($content -split '\r?\n' | Where-Object { $_ -match 'ICS|ics' })) {
        if ($line -match 'Windows\s*\+\s*(?:POSIX|Linux)|Win\s*\+\s*Linux|Windows\s*/\s*Linux|Windows (?:and|e) POSIX|THorseICSLinuxDaemonApp') {
            $failures += "Stale ICS platform claim in ${page}: $line"
        }
    }
    if ($content -notmatch 'OpenSSL_Resource_Files') {
        $failures += "Missing explicit default resource-loading configuration: $page"
    }
}
$pages = @('README.md', 'README.pt-BR.md') + @(
    Get-ChildItem -LiteralPath (Join-Path $root 'doc') -Filter '*.md' | ForEach-Object { "doc/$($_.Name)" }
)
$links = 0
foreach ($page in $pages) {
    $absolute = Join-Path $root $page
    $content = Get-Content -LiteralPath $absolute -Raw
    foreach ($match in [regex]::Matches($content, '\]\(\./([^)]*\.md)(?:#[^)]*)?\)')) {
        $links++
        $target = Join-Path (Split-Path $absolute) $match.Groups[1].Value
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $failures += "Broken link in ${page}: $($match.Groups[1].Value)"
        }
    }
}
if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
Write-Host "PASS: $($icsPages.Count) ICS pages and $links internal Markdown links across $($pages.Count) pages."
