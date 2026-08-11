<#
    Claude Code status line - shows the active Dataverse environment.

    Why: pac's active auth profile is invisible in the terminal, and this setup lets
    Claude create tables, import solutions and publish flows autonomously. Knowing
    which client environment is live at a glance is the cheapest guard available.

    Contract: session JSON arrives on stdin, one line goes to stdout. This runs on
    every prompt render, so it must be fast and must never throw - a broken status
    line should degrade to nothing, not break the prompt.
#>

$ErrorActionPreference = 'SilentlyContinue'

$CacheFile = Join-Path $env:TEMP 'claude-pac-env.cache'
$CacheTtl  = 90  # seconds; pac auth list costs ~1s, far too slow per render

function Get-CwdLabel {
    $stdin = ''
    try { $stdin = [Console]::In.ReadToEnd() } catch { }

    $dir = $null
    if (-not [string]::IsNullOrWhiteSpace($stdin)) {
        try {
            $payload = $stdin | ConvertFrom-Json
            if ($payload.PSObject.Properties.Name -contains 'cwd') { $dir = $payload.cwd }
            elseif ($payload.PSObject.Properties.Name -contains 'workspace') { $dir = $payload.workspace.current_dir }
        } catch { }
    }
    if (-not $dir) { $dir = (Get-Location).Path }
    return (Split-Path -Leaf $dir)
}

function Get-ActivePacEnv {
    # Serve from cache when fresh.
    if (Test-Path -LiteralPath $CacheFile) {
        $age = (Get-Date) - (Get-Item -LiteralPath $CacheFile).LastWriteTime
        if ($age.TotalSeconds -lt $CacheTtl) {
            return (Get-Content -LiteralPath $CacheFile -Raw).Trim()
        }
    }

    $label = ''
    try {
        $lines = & pac auth list 2>$null
        # The active profile is flagged with '*'. Prefer the friendly name, fall back
        # to the org host - output columns vary across pac versions, so match loosely.
        $active = $lines | Where-Object { $_ -match '^\s*\[?\d+\]?\s*\*' } | Select-Object -First 1

        if ($active) {
            if ($active -match '(https://([a-zA-Z0-9\-]+)\.[a-zA-Z0-9\.\-]*dynamics\.com)') {
                $label = $Matches[2]
            } elseif ($active -match '\s\*\s+\S+\s+(\S+)') {
                $label = $Matches[1]
            } else {
                $label = 'active'
            }
        }
    } catch { $label = '' }

    try { $label | Out-File -LiteralPath $CacheFile -Encoding utf8 -Force } catch { }
    return $label
}

try {
    $cwd = Get-CwdLabel
    $env = Get-ActivePacEnv

    # ANSI colours; Claude Code renders them in the status line.
    $dim   = "$([char]27)[2m"
    $reset = "$([char]27)[0m"
    $cyan  = "$([char]27)[36m"
    $red   = "$([char]27)[31m"
    $green = "$([char]27)[32m"

    $parts = @("$cyan$cwd$reset")

    if ([string]::IsNullOrWhiteSpace($env)) {
        $parts += "${dim}no pac auth$reset"
    } else {
        # Anything not obviously non-production reads as red. Deliberately pessimistic:
        # a false alarm costs a glance, a missed prod write costs a client.
        #
        # ASCII only - PowerShell 5.1 mangles non-ASCII glyphs here into mojibake.
        # The '!' prefix carries the warning without depending on colour, which
        # matters for colour-blind users and terminals that drop ANSI.
        $isNonProd = $env -match '(?i)(dev|test|uat|sandbox|sbx|demo|trial|scratch)'
        if ($isNonProd) {
            $parts += "${green}$env$reset"
        } else {
            $parts += "${red}! $env$reset"
        }
    }

    Write-Output ($parts -join "$dim | $reset")
} catch {
    # Never break the prompt.
    Write-Output ''
}
