<#
.SYNOPSIS
    Projects this repo's Claude Code configuration onto the current machine.

.DESCRIPTION
    Idempotent. Safe to re-run. Backs up anything it is about to replace, and merges
    into settings.json rather than overwriting it so machine-local keys survive.

    Copies (does not symlink) because symlink creation on Windows needs elevation or
    Developer Mode, neither of which can be assumed.

.PARAMETER SyncBack
    Reverse direction: copy config from ~/.claude back into this repo, to rescue edits
    made in place during a session. Review the git diff afterwards before committing.

.PARAMETER SkipMcp
    Skip registering the Microsoft Learn MCP server.

.PARAMETER WhatIfOnly
    Report what would change without writing anything.

.EXAMPLE
    .\bootstrap.ps1
    .\bootstrap.ps1 -SyncBack
    .\bootstrap.ps1 -WhatIfOnly
#>
[CmdletBinding()]
param(
    [switch]$SyncBack,
    [switch]$SkipMcp,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = $PSScriptRoot
$RepoClaude  = Join-Path $RepoRoot 'claude'
$ClaudeDir   = Join-Path $env:USERPROFILE '.claude'
$LearnMcpUrl = 'https://learn.microsoft.com/api/mcp'

# Directories and files projected from repo -> ~/.claude.
# Anything not listed here is left strictly alone.
$ManagedDirs  = @('skills', 'hooks')
$ManagedFiles = @('CLAUDE.md', 'statusline.ps1')

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host "  [MISS] $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "  $m" -ForegroundColor Gray }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
function Test-Tool {
    param(
        [string]$Name,
        [string]$Command,
        [string[]]$VersionArgs,
        [string]$NeededFor,
        [string]$InstallHint,
        [switch]$Required
    )

    $exe = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $exe) {
        if ($Required) { Write-Bad "$Name - $NeededFor" } else { Write-Warn "$Name not found - $NeededFor" }
        Write-Info "       install: $InstallHint"
        return $false
    }

    # Some tools resolve on PATH but produce nothing - notably the Windows Store
    # 'python' alias stub. Treat empty output as not really installed.
    $version = ''
    try { $version = (& $Command @VersionArgs 2>$null | Where-Object { $_ } | Select-Object -First 1) } catch { $version = '' }

    if ([string]::IsNullOrWhiteSpace($version)) {
        if ($Required) { Write-Bad "$Name found on PATH but returned no version - $NeededFor" }
        else           { Write-Warn "$Name found on PATH but returned no version (stub?) - $NeededFor" }
        Write-Info "       install: $InstallHint"
        return $false
    }

    Write-Ok "$Name $($version.Trim())"
    return $true
}

function Test-PacCli {
    # 'pac --version' is not a valid pac command - it prints the banner, then errors.
    # The banner carries the version on any invocation, so parse it from 'pac help'.
    $exe = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $exe) {
        Write-Bad 'pac CLI - all Power Platform plugins'
        Write-Info '       install: winget install Microsoft.PowerPlatformCLI'
        return $false
    }

    $banner  = & pac help 2>$null | Out-String
    $version = ''
    if ($banner -match 'Version:\s*(\d+\.\d+\.\d+)') { $version = $Matches[1] }

    if (-not $version) {
        Write-Warn 'pac CLI present but version could not be parsed'
        return $true
    }

    Write-Ok "pac CLI $version"

    $parts = $version.Split('.')
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 7)) {
        Write-Warn "pac $version is below 2.7.0 - the model-apps plugin requires >= 2.7.0"
        Write-Info '       update: pac install latest'
    }
    return $true
}

function Invoke-Preflight {
    Write-Step 'Preflight'
    Write-Info "Reporting only - nothing is installed for you."
    Write-Host ''

    $missing = @()

    # The claude CLI is NOT required to project config files - only to register the MCP
    # server. It is absent when Claude Code is used solely as the VS Code extension, which
    # is a normal setup, not a broken one. Fall back to patching .claude.json directly.
    $script:HasClaudeCli = Test-Tool -Name 'Claude Code CLI' -Command 'claude' -VersionArgs @('--version') `
        -NeededFor 'registering the Learn MCP server from a script' `
        -InstallHint 'https://claude.com/claude-code (the VS Code extension alone is fine)'
    if (-not $script:HasClaudeCli) {
        Write-Info '       not required - MCP will be registered by patching ~/.claude.json'
    }

    if (-not (Test-PacCli)) { $missing += 'pac' }

    if (-not (Test-Tool -Name 'Node.js' -Command 'node' -VersionArgs @('--version') `
        -NeededFor 'code apps, FlowAgent MCP (needs >= 18)' `
        -InstallHint 'winget install OpenJS.NodeJS.LTS' -Required)) { $missing += 'node' }

    if (-not (Test-Tool -Name 'git' -Command 'git' -VersionArgs @('--version') `
        -NeededFor 'this repo' -InstallHint 'winget install Git.Git' -Required)) { $missing += 'git' }

    # Optional-but-expected: absence degrades specific plugins rather than blocking setup.
    Test-Tool -Name 'Azure CLI' -Command 'az' -VersionArgs @('version', '--output', 'tsv') `
        -NeededFor 'Dataverse Web API auth, FlowAgent' `
        -InstallHint 'winget install Microsoft.AzureCLI' | Out-Null

    Test-Tool -Name 'Python 3' -Command 'python' -VersionArgs @('--version') `
        -NeededFor 'Dataverse plugin dv-connect' `
        -InstallHint 'winget install Python.Python.3.12' | Out-Null

    Test-Tool -Name 'GitHub CLI' -Command 'gh' -VersionArgs @('--version') `
        -NeededFor 'creating/pushing the private repo' `
        -InstallHint 'winget install GitHub.cli' | Out-Null

    # .NET 10 specifically - canvas-apps will not run without it.
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnet) {
        $sdks = & dotnet --list-sdks 2>$null
        $has10 = $sdks | Where-Object { $_ -match '^10\.' }
        if ($has10) {
            Write-Ok ".NET SDK 10 ($(($has10 | Select-Object -First 1) -split ' ' | Select-Object -First 1))"
        } else {
            Write-Warn ".NET SDK 10 not found - canvas-apps plugin requires it"
            Write-Info "       install: winget install Microsoft.DotNet.SDK.10"
        }
    } else {
        Write-Warn ".NET SDK not found - canvas-apps plugin requires .NET 10"
        Write-Info "       install: winget install Microsoft.DotNet.SDK.10"
    }

    # Python's Windows Store alias is a stub that intercepts 'python' and does nothing useful.
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd -and $pythonCmd.Source -like '*WindowsApps*') {
        Write-Warn "'python' resolves to the Windows Store alias stub, not a real interpreter."
        Write-Info "       Install Python 3 properly, or disable the alias:"
        Write-Info "       Settings > Apps > Advanced app settings > App execution aliases"
    }

    if ($missing.Count -gt 0) {
        throw "Required tools missing: $($missing -join ', '). Install them and re-run."
    }
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
function New-ConfigBackup {
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $ClaudeDir ".backup-$stamp"
    $backedUp  = $false

    foreach ($name in ($ManagedFiles + @('settings.json'))) {
        $src = Join-Path $ClaudeDir $name
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            if (-not (Test-Path -LiteralPath $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $src -Destination (Join-Path $backupDir $name) -Force
            $backedUp = $true
        }
    }

    foreach ($name in $ManagedDirs) {
        $src = Join-Path $ClaudeDir $name
        if (Test-Path -LiteralPath $src -PathType Container) {
            if (-not (Test-Path -LiteralPath $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $src -Destination $backupDir -Recurse -Force
            $backedUp = $true
        }
    }

    if ($backedUp) {
        Write-Ok "Backed up existing config to $backupDir"
    } else {
        Write-Info 'Nothing existing to back up.'
    }
}

# ---------------------------------------------------------------------------
# settings.json merge
#
# Deep-merges the template into the existing file. Existing values win on scalar
# conflicts, so machine-local choices (model, effortLevel, ...) are never clobbered.
# Arrays are unioned rather than replaced, so a permission added by hand survives.
# ---------------------------------------------------------------------------
function ConvertTo-Hashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = @()
        foreach ($item in $InputObject) { $list += ,(ConvertTo-Hashtable $item) }
        return ,$list
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $ht
    }

    return $InputObject
}

function Merge-Hashtable {
    param(
        [hashtable]$Base,      # existing settings - wins on scalar conflict
        [hashtable]$Overlay    # template - fills gaps only
    )

    $result = @{}
    foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] }

    foreach ($k in $Overlay.Keys) {
        if (-not $result.ContainsKey($k)) {
            $result[$k] = $Overlay[$k]
            continue
        }

        $existing = $result[$k]
        $incoming = $Overlay[$k]

        if ($existing -is [hashtable] -and $incoming -is [hashtable]) {
            $result[$k] = Merge-Hashtable -Base $existing -Overlay $incoming
        }
        elseif ($existing -is [array] -and $incoming -is [array]) {
            # Union, preserving order, comparing by serialized shape so object
            # entries (hooks) dedupe as reliably as string entries (permissions).
            $merged = @()
            $seen   = New-Object System.Collections.Generic.HashSet[string]
            foreach ($item in ($existing + $incoming)) {
                $key = if ($item -is [string]) { $item } else { ($item | ConvertTo-Json -Depth 10 -Compress) }
                if ($seen.Add($key)) { $merged += ,$item }
            }
            $result[$k] = $merged
        }
        # else: scalar conflict -> keep existing. Machine-local choice wins.
    }

    return $result
}

function Update-Settings {
    $templatePath = Join-Path $RepoClaude 'settings.template.json'
    $settingsPath = Join-Path $ClaudeDir 'settings.json'

    if (-not (Test-Path -LiteralPath $templatePath)) {
        Write-Warn 'settings.template.json not found - skipping settings merge.'
        return
    }

    # The template cannot know the user profile path; substitute at projection time.
    # Let ConvertTo-Json do the escaping rather than hand-rolling it - a manual
    # -replace here double-escapes, producing C:\\Users instead of C:\Users.
    $claudeDirJson = ($ClaudeDir | ConvertTo-Json).Trim('"')
    $templateRaw   = (Get-Content -LiteralPath $templatePath -Raw) -replace '\{\{CLAUDE_DIR\}\}', $claudeDirJson
    $template      = ConvertTo-Hashtable (ConvertFrom-Json $templateRaw)

    $existing = @{}
    if (Test-Path -LiteralPath $settingsPath) {
        $raw = Get-Content -LiteralPath $settingsPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $existing = ConvertTo-Hashtable (ConvertFrom-Json $raw)
        }
    }

    $merged = Merge-Hashtable -Base $existing -Overlay $template
    $json   = $merged | ConvertTo-Json -Depth 20

    if ($WhatIfOnly) {
        Write-Info 'Would write merged settings.json:'
        Write-Host $json
        return
    }

    $json | Out-File -LiteralPath $settingsPath -Encoding utf8 -Force

    $preserved = @($existing.Keys | Where-Object { $_ -in @('model', 'switchModelsOnFlag', 'effortLevel') })
    Write-Ok "Merged settings.json"
    if ($preserved.Count -gt 0) { Write-Info "preserved existing: $($preserved -join ', ')" }
}

# ---------------------------------------------------------------------------
# Projection: repo -> ~/.claude
# ---------------------------------------------------------------------------
function Copy-Config {
    param([switch]$Reverse)

    $from = if ($Reverse) { $ClaudeDir }  else { $RepoClaude }
    $to   = if ($Reverse) { $RepoClaude } else { $ClaudeDir }

    foreach ($name in $ManagedFiles) {
        $src = Join-Path $from $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            Write-Info "skip $name (not present in source)"
            continue
        }
        if ($WhatIfOnly) { Write-Info "would copy $name"; continue }
        Copy-Item -LiteralPath $src -Destination (Join-Path $to $name) -Force
        Write-Ok "$name"
    }

    foreach ($name in $ManagedDirs) {
        $src = Join-Path $from $name
        if (-not (Test-Path -LiteralPath $src -PathType Container)) {
            Write-Info "skip $name/ (not present in source)"
            continue
        }
        if ($WhatIfOnly) { Write-Info "would copy $name/"; continue }

        $dst = Join-Path $to $name
        if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }

        # -Path, not -LiteralPath: LiteralPath treats the trailing '*' as a filename,
        # matches nothing, and copies nothing silently.
        Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force

        # Count what actually landed at the destination. Counting the source would
        # report success for a copy that did nothing.
        $expected = (Get-ChildItem -LiteralPath $src -Recurse -File | Measure-Object).Count
        $actual   = (Get-ChildItem -LiteralPath $dst -Recurse -File | Measure-Object).Count

        if ($actual -lt $expected) {
            Write-Bad "$name/ - copied $actual of $expected files"
        } else {
            Write-Ok "$name/ ($actual files)"
        }
    }
}

# ---------------------------------------------------------------------------
# Microsoft Learn MCP
# ---------------------------------------------------------------------------
function Register-LearnMcpViaConfig {
    <#
        Fallback when the claude CLI isn't on PATH (e.g. VS Code extension only).

        User-scope MCP servers live in ~/.claude.json, which is a large live state file.
        A full ConvertFrom-Json / ConvertTo-Json round-trip in PowerShell 5.1 would reorder
        keys, truncate at the default depth and risk mangling unrelated state - so this
        does a surgical text insert after the opening brace instead, then validates the
        result parses before replacing the original. Backup first, restore on failure.
    #>
    $configPath = Join-Path $env:USERPROFILE '.claude.json'

    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Warn "~/.claude.json not found - cannot register MCP automatically."
        Write-Info "  Run this in a terminal where the claude CLI is available:"
        Write-Info "    claude mcp add --scope user --transport http microsoft-learn $LearnMcpUrl"
        return
    }

    $raw = Get-Content -LiteralPath $configPath -Raw

    if ($raw -match '"microsoft-learn"') {
        Write-Ok 'microsoft-learn already present in ~/.claude.json'
        return
    }

    # Check for a ROOT-level mcpServers key by parsing. A text match is wrong here:
    # every entry under "projects" carries its own nested "mcpServers": {}.
    $hasRootMcp = $false
    try {
        $parsed = $raw | ConvertFrom-Json
        $hasRootMcp = ($parsed.PSObject.Properties.Name -contains 'mcpServers')
    } catch {
        Write-Warn 'Could not parse ~/.claude.json - leaving it untouched.'
        Write-Info "  Add by hand: `"microsoft-learn`": { `"type`": `"http`", `"url`": `"$LearnMcpUrl`" }"
        return
    }

    if ($hasRootMcp) {
        Write-Warn 'A root "mcpServers" block already exists in ~/.claude.json.'
        Write-Info '  Not editing it automatically. Add this entry by hand:'
        Write-Info "    `"microsoft-learn`": { `"type`": `"http`", `"url`": `"$LearnMcpUrl`" }"
        return
    }

    if ($WhatIfOnly) { Write-Info 'would insert a root "mcpServers" block into ~/.claude.json'; return }

    $backup = "$configPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $configPath -Destination $backup -Force

    $block = @"
  "mcpServers": {
    "microsoft-learn": {
      "type": "http",
      "url": "$LearnMcpUrl"
    }
  },
"@

    # Insert immediately after the first '{' - everything else is left byte-identical.
    $idx = $raw.IndexOf('{')
    if ($idx -lt 0) {
        Write-Warn 'Could not parse ~/.claude.json - left unchanged.'
        return
    }
    $patched = $raw.Substring(0, $idx + 1) + "`n" + $block + $raw.Substring($idx + 1)

    try {
        $null = $patched | ConvertFrom-Json
    } catch {
        Write-Warn "Patched config failed JSON validation - original left untouched."
        Write-Info "  Backup at $backup"
        return
    }

    $patched | Out-File -LiteralPath $configPath -Encoding utf8 -NoNewline -Force
    Write-Ok "Registered microsoft-learn in ~/.claude.json"
    Write-Info "backup: $backup"
    Write-Info 'Restart Claude Code for the MCP server to connect.'
}

function Register-LearnMcp {
    if ($SkipMcp) { Write-Info 'Skipped (-SkipMcp).'; return }

    if (-not $script:HasClaudeCli) {
        Write-Info 'claude CLI not on PATH - registering via ~/.claude.json instead.'
        Register-LearnMcpViaConfig
        return
    }

    $existing = ''
    try { $existing = (& claude mcp list 2>$null | Out-String) } catch { $existing = '' }

    if ($existing -match 'microsoft-learn') {
        Write-Ok 'microsoft-learn already registered.'
        return
    }

    if ($WhatIfOnly) { Write-Info "would run: claude mcp add --scope user --transport http microsoft-learn $LearnMcpUrl"; return }

    & claude mcp add --scope user --transport http microsoft-learn $LearnMcpUrl
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Registered microsoft-learn ($LearnMcpUrl)"
    } else {
        Write-Warn "CLI registration failed (exit $LASTEXITCODE) - falling back to config patch."
        Register-LearnMcpViaConfig
    }
}

# ---------------------------------------------------------------------------
# Manual steps - slash commands are interactive and cannot be scripted.
# ---------------------------------------------------------------------------
function Show-ManualSteps {
    Write-Host ''
    Write-Host '  Run these inside a Claude Code session (slash commands cannot be scripted):' -ForegroundColor White
    Write-Host ''

    $commands = @(
        '/plugin install dataverse@claude-plugins-official',
        '/plugin marketplace add microsoft/power-platform-skills',
        '/plugin install model-apps@power-platform-skills',
        '/plugin install power-automate@power-platform-skills',
        '/plugin install canvas-apps@power-platform-skills',
        '/plugin install power-pages@power-platform-skills',
        '/plugin install code-apps-preview@power-platform-skills',
        '/plugin install mobile-app@power-platform-skills',
        '/plugin install mcp-apps@power-platform-skills'
    )
    foreach ($c in $commands) { Write-Host "    $c" -ForegroundColor Cyan }

    Write-Host ''
    Write-Host '  Then, once per machine:' -ForegroundColor White
    Write-Host '    pac auth create --environment <your-dev-env-url>' -ForegroundColor Cyan
    Write-Host '    dv-connect        (Dataverse plugin: tool checks + MCP registration)' -ForegroundColor Cyan
    Write-Host '    /configure-canvas-mcp                     (canvas-apps)' -ForegroundColor Cyan
    Write-Host '    ask Claude to run the power-automate "setup" skill' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Full detail: docs/manual-steps.md' -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Claude Code - Power Platform / D365 configuration' -ForegroundColor White
Write-Host "repo:   $RepoRoot" -ForegroundColor Gray
Write-Host "target: $ClaudeDir" -ForegroundColor Gray
if ($WhatIfOnly) { Write-Host 'MODE:   dry run - nothing will be written' -ForegroundColor Yellow }

if ($SyncBack) {
    Write-Step 'Sync back (~/.claude -> repo)'
    Write-Warn 'This overwrites repo files with the machine copy. Review git diff before committing.'
    Copy-Config -Reverse
    Write-Host ''
    Write-Host 'Done. Review with: git diff' -ForegroundColor White
    Write-Host ''
    return
}

Invoke-Preflight

if (-not (Test-Path -LiteralPath $ClaudeDir)) {
    if (-not $WhatIfOnly) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }
    Write-Info "Created $ClaudeDir"
}

Write-Step 'Backup'
if ($WhatIfOnly) { Write-Info 'would back up existing managed config' } else { New-ConfigBackup }

Write-Step 'Projecting config (repo -> ~/.claude)'
Copy-Config

Write-Step 'Merging settings.json'
Update-Settings

Write-Step 'Microsoft Learn MCP server'
Register-LearnMcp

Write-Step 'Remaining manual steps'
Show-ManualSteps

Write-Host 'Bootstrap complete.' -ForegroundColor Green
Write-Host ''
