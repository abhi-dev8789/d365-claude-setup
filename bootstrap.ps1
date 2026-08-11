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

.PARAMETER Full
    One-command setup. Implies -InstallTools and -InstallPlugins, and offers to build
    the environment allowlist. Use this on a new machine.

.PARAMETER InstallTools
    Install missing prerequisites (Python, GitHub CLI via winget; Claude Code CLI via
    npm) instead of only reporting them.

.PARAMETER InstallPlugins
    Register the plugin marketplaces and install all eight plugins non-interactively
    via the claude CLI.

.PARAMETER SkipMcp
    Skip registering the Microsoft Learn MCP server.

.PARAMETER WhatIfOnly
    Report what would change without writing anything.

.EXAMPLE
    .\bootstrap.ps1 -Full        # new machine: everything scriptable, in one command
    .\bootstrap.ps1              # config only, report missing tools
    .\bootstrap.ps1 -SyncBack
    .\bootstrap.ps1 -WhatIfOnly
#>
[CmdletBinding()]
param(
    [switch]$Full,
    [switch]$InstallTools,
    [switch]$InstallPlugins,
    [switch]$SyncBack,
    [switch]$SkipMcp,
    [switch]$WhatIfOnly
)

if ($Full) { $InstallTools = $true; $InstallPlugins = $true }

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
# Tool resolution
#
# npm's global bin and freshly-installed MSI paths are not on PATH in an already
# running shell, so resolve by known location as well as by PATH.
# ---------------------------------------------------------------------------
function Resolve-Exe {
    param([string]$Name, [string[]]$Candidates)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Resolve-ClaudeCli {
    $npmPrefix = ''
    try { $npmPrefix = (& npm config get prefix 2>$null | Select-Object -First 1) } catch { }

    $candidates = @()
    if ($npmPrefix) { $candidates += (Join-Path $npmPrefix 'claude.cmd') }
    $candidates += @(
        (Join-Path $env:APPDATA 'npm\claude.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe')
    )
    return (Resolve-Exe -Name 'claude' -Candidates $candidates)
}

function Resolve-GhCli {
    return (Resolve-Exe -Name 'gh' -Candidates @("$env:ProgramFiles\GitHub CLI\gh.exe"))
}

function Resolve-RealPython {
    # The Windows Store 'python' alias is a stub that resolves on PATH, prints nothing,
    # and shadows a real install. Look for an actual interpreter, ignoring WindowsApps.
    $candidates = @()
    $candidates += Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Directory -ErrorAction SilentlyContinue |
                   ForEach-Object { Join-Path $_.FullName 'python.exe' }
    $candidates += Get-ChildItem $env:ProgramFiles -Filter 'Python3*' -Directory -ErrorAction SilentlyContinue |
                   ForEach-Object { Join-Path $_.FullName 'python.exe' }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $v = & $c --version 2>&1
            if ($v -match 'Python 3') { return [pscustomobject]@{ Path = $c; Version = "$v".Trim() } }
        }
    }
    return $null
}

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

    $script:Optional = @()   # tools we can install on request

    # The claude CLI is absent when Claude Code is used only as the VS Code extension,
    # which is a normal setup rather than a broken one. Config projection works without
    # it, but plugin installation and `claude mcp add` need it.
    $script:ClaudeCli = Resolve-ClaudeCli
    if ($script:ClaudeCli) {
        $v = (& $script:ClaudeCli --version 2>$null | Select-Object -First 1)
        Write-Ok "Claude Code CLI $v"
    } else {
        Write-Warn 'Claude Code CLI not found - needed for plugin install and MCP registration'
        Write-Info '       install: npm install -g @anthropic-ai/claude-code'
        $script:Optional += @{ Name = 'Claude Code CLI'; Kind = 'npm'; Id = '@anthropic-ai/claude-code' }
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

    $py = Resolve-RealPython
    if ($py) {
        Write-Ok "$($py.Version) ($($py.Path))"
        $onPath = (Get-Command python -ErrorAction SilentlyContinue).Source
        if ($onPath -like '*WindowsApps*') {
            Write-Warn "but 'python' on PATH still resolves to the Windows Store alias stub"
            Write-Info '       dv-connect may fail until you disable it:'
            Write-Info '       Settings > Apps > Advanced app settings > App execution aliases'
            Write-Info '       toggle OFF python.exe and python3.exe'
        }
    } else {
        Write-Warn 'Python 3 not found - needed by the Dataverse plugin dv-connect'
        Write-Info '       install: winget install Python.Python.3.12'
        $script:Optional += @{ Name = 'Python 3'; Kind = 'winget'; Id = 'Python.Python.3.12' }
    }

    if (Resolve-GhCli) {
        Write-Ok 'GitHub CLI present'
    } else {
        Write-Warn 'GitHub CLI not found - needed to create/push a private repo'
        Write-Info '       install: winget install GitHub.cli'
        $script:Optional += @{ Name = 'GitHub CLI'; Kind = 'winget'; Id = 'GitHub.cli' }
    }

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

    if (-not $script:ClaudeCli) {
        Write-Info 'claude CLI not available - registering via ~/.claude.json instead.'
        Register-LearnMcpViaConfig
        return
    }

    $existing = ''
    try { $existing = (& $script:ClaudeCli mcp list 2>$null | Out-String) } catch { $existing = '' }

    if ($existing -match 'microsoft-learn') {
        Write-Ok 'microsoft-learn already registered.'
        return
    }

    if ($WhatIfOnly) { Write-Info "would run: claude mcp add --scope user --transport http microsoft-learn $LearnMcpUrl"; return }

    & $script:ClaudeCli mcp add --scope user --transport http microsoft-learn $LearnMcpUrl
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Registered microsoft-learn ($LearnMcpUrl)"
    } else {
        Write-Warn "CLI registration failed (exit $LASTEXITCODE) - falling back to config patch."
        Register-LearnMcpViaConfig
    }
}

# ---------------------------------------------------------------------------
# Optional tool installation
# ---------------------------------------------------------------------------
function Install-MissingTools {
    if (-not $script:Optional -or $script:Optional.Count -eq 0) {
        Write-Ok 'Nothing missing.'
        return
    }

    foreach ($t in $script:Optional) {
        if ($WhatIfOnly) { Write-Info "would install $($t.Name) via $($t.Kind)"; continue }

        Write-Info "installing $($t.Name)..."
        if ($t.Kind -eq 'winget') {
            & winget install --id $t.Id --source winget `
                --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        } else {
            & npm install -g $t.Id 2>&1 | Out-Null
        }

        # Re-resolve rather than trusting the exit code - winget returns 0 for
        # "already installed" and for some partial states.
        $ok = switch ($t.Name) {
            'Claude Code CLI' { [bool]($script:ClaudeCli = Resolve-ClaudeCli) }
            'GitHub CLI'      { [bool](Resolve-GhCli) }
            'Python 3'        { [bool](Resolve-RealPython) }
            default           { $false }   # no verifier written - do not claim success
        }
        if ($ok) { Write-Ok "$($t.Name)" } else { Write-Bad "$($t.Name) - could not verify a usable binary after install" }
    }

    Write-Info 'Newly installed tools may need a new terminal before they are on PATH.'
}

# ---------------------------------------------------------------------------
# Plugins
#
# `claude plugin install` is the documented non-interactive path; the /plugin
# slash command is interactive and cannot be scripted. settings.template.json
# also declares extraKnownMarketplaces/enabledPlugins, but that alone does not
# fetch plugins from an external marketplace - the install step is still needed.
# ---------------------------------------------------------------------------
$script:Marketplaces = @(
    @{ Name = 'claude-plugins-official'; Repo = 'anthropics/claude-plugins-official' },
    @{ Name = 'power-platform-skills';   Repo = 'microsoft/power-platform-skills' }
)

$script:Plugins = @(
    'dataverse@claude-plugins-official',
    'model-apps@power-platform-skills',
    'power-automate@power-platform-skills',
    'canvas-apps@power-platform-skills',
    'power-pages@power-platform-skills',
    'code-apps-preview@power-platform-skills',
    'mobile-app@power-platform-skills',
    'mcp-apps@power-platform-skills'
)

function Install-Plugins {
    if (-not $script:ClaudeCli) {
        Write-Warn 'Claude Code CLI not available - skipping plugin install.'
        Write-Info '  Install it (npm install -g @anthropic-ai/claude-code) and re-run,'
        Write-Info '  or run the /plugin commands listed below by hand.'
        return
    }

    if ($WhatIfOnly) {
        Write-Info "would add $($script:Marketplaces.Count) marketplaces and install $($script:Plugins.Count) plugins"
        return
    }

    foreach ($m in $script:Marketplaces) {
        $out = (& $script:ClaudeCli plugin marketplace add $m.Repo 2>&1 | Out-String)
        if ($out -match 'Successfully added|already') { Write-Ok "marketplace $($m.Name)" }
        else { Write-Warn "marketplace $($m.Name) - $(($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1))" }
    }

    foreach ($p in $script:Plugins) {
        & $script:ClaudeCli plugin install $p --scope user 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok $p } else { Write-Bad "$p (exit $LASTEXITCODE)" }
    }

    # Verify against the CLI's own view rather than the install exit codes.
    $listed = (& $script:ClaudeCli plugin list 2>&1 | Out-String)
    $missing = $script:Plugins | Where-Object { $listed -notmatch [regex]::Escape($_) }
    if ($missing) { Write-Bad "not present after install: $($missing -join ', ')" }
    else { Write-Ok "verified all $($script:Plugins.Count) plugins installed" }
}

# ---------------------------------------------------------------------------
# Environment allowlist
#
# Deliberately interactive. The guard hook is pointless if it can be widened
# without a human deciding which environments are safe to write to.
# ---------------------------------------------------------------------------
function New-DevEnvironmentsFile {
    $path = Join-Path $ClaudeDir 'dev-environments.txt'

    if (Test-Path -LiteralPath $path) {
        $n = (Get-Content -LiteralPath $path | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | Measure-Object).Count
        Write-Ok "allowlist exists ($n entries)"
        return
    }

    Write-Warn 'No environment allowlist - destructive pac commands are all blocked.'

    $profiles = @()
    try {
        $profiles = & pac auth list 2>$null |
                    Select-String -Pattern '(https://[a-zA-Z0-9\-]+\.[a-zA-Z0-9\.\-]*dynamics\.com)' -AllMatches |
                    ForEach-Object { $_.Matches[0].Groups[1].Value } |
                    Sort-Object -Unique
    } catch { }

    if ($profiles) {
        Write-Info 'pac auth profiles found on this machine:'
        foreach ($p in $profiles) { Write-Info "    $p" }
    }

    Write-Info ''
    Write-Info "Create $path with one substring per line for each environment that is"
    Write-Info 'safe for destructive operations (import, delete, push). Leave production out.'
    Write-Info 'This file is gitignored - client identifiers stay on this machine.'
}

# ---------------------------------------------------------------------------
# Manual steps - what genuinely cannot be scripted.
# ---------------------------------------------------------------------------
function Show-ManualSteps {
    Write-Host ''
    Write-Host '  These need a human. Everything else is done.' -ForegroundColor White
    Write-Host ''
    Write-Host '  1. Sign in to Dataverse (opens a browser - cannot be scripted):' -ForegroundColor White
    Write-Host '       pac auth create --environment <your-dev-env-url>' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  2. In a Claude Code session, run each plugin''s one-time setup:' -ForegroundColor White
    Write-Host '       dv-connect              (Dataverse: tool checks, auth, MCP registration)' -ForegroundColor Cyan
    Write-Host '       /configure-canvas-mcp   (canvas-apps: authoring MCP server)' -ForegroundColor Cyan
    Write-Host '       ask Claude to run the power-automate setup skill' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  3. Create the environment allowlist if you have not yet:' -ForegroundColor White
    Write-Host "       $ClaudeDir\dev-environments.txt" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Restart Claude Code to pick up plugins and the MCP server.' -ForegroundColor Gray
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

if ($InstallTools) {
    Write-Step 'Installing missing tools'
    Install-MissingTools
}

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

if ($InstallPlugins) {
    Write-Step 'Plugins'
    Install-Plugins
}

Write-Step 'Environment allowlist'
New-DevEnvironmentsFile

Write-Step 'Remaining manual steps'
Show-ManualSteps

Write-Host 'Bootstrap complete.' -ForegroundColor Green
Write-Host ''
