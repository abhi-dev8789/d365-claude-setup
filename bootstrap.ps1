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

.PARAMETER Uninstall
    Reverse everything this script did, using the manifest of pre-existing state
    recorded on the first run. Restores or deletes config, removes the plugins and
    marketplaces it installed, and unregisters the Learn MCP server. Tools installed
    via winget/npm are reported, not removed, unless -RemoveTools is also passed.

.PARAMETER RemoveTools
    With -Uninstall, also uninstall tools this script installed. Off by default:
    Node, git and the rest are commonly wanted for other work, and silently removing
    them would be worse than leaving them.

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
    [switch]$Uninstall,
    [switch]$RemoveTools,
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

function Get-LatestPythonPackageId {
    <#
        winget has no version-agnostic 'Python.Python.3' id - every package is pinned to a
        minor version (3.12, 3.13, 3.14...). Hardcoding one means this script installs an
        increasingly stale Python as the years pass, so discover the newest instead.
        Falls back to a known-good id only if discovery fails (offline, winget missing).
    #>
    $fallback = 'Python.Python.3.12'

    try {
        $out = & winget search --id Python.Python.3 --source winget 2>$null | Out-String
        $versions = [regex]::Matches($out, 'Python\.Python\.3\.(\d+)') |
                    ForEach-Object { [int]$_.Groups[1].Value } |
                    Sort-Object -Unique
        if ($versions) { return "Python.Python.3.$($versions[-1])" }
    } catch { }

    return $fallback
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

function Update-SessionPath {
    # winget writes PATH to the registry; an already-running shell keeps its stale copy.
    # Without this, a tool installed moments ago is invisible for the rest of the run -
    # which matters most for Node, since npm must exist before the Claude CLI installs.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Invoke-Preflight {
    Write-Step 'Preflight'
    if ($InstallTools) { Write-Info 'Missing tools will be installed.' }
    else { Write-Info 'Reporting only - nothing is installed. Use -Full to install.' }
    Write-Host ''

    # Every entry is installable. Required ones block setup if still absent afterwards.
    # Kind 'winget' entries are installed before 'npm' ones, because npm needs Node.
    $script:Missing = @()

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
        $script:Missing += @{ Name = 'Claude Code CLI'; Kind = 'npm'; Id = '@anthropic-ai/claude-code'; Required = $false }
    }

    if (-not (Test-PacCli)) {
        $script:Missing += @{ Name = 'pac CLI'; Kind = 'winget'; Id = 'Microsoft.PowerPlatformCLI'; Required = $true }
    }

    if (-not (Test-Tool -Name 'Node.js' -Command 'node' -VersionArgs @('--version') `
        -NeededFor 'code apps, FlowAgent MCP (needs >= 18)' `
        -InstallHint 'winget install OpenJS.NodeJS.LTS' -Required)) {
        $script:Missing += @{ Name = 'Node.js'; Kind = 'winget'; Id = 'OpenJS.NodeJS.LTS'; Required = $true }
    }

    if (-not (Test-Tool -Name 'git' -Command 'git' -VersionArgs @('--version') `
        -NeededFor 'cloning this repo' -InstallHint 'winget install Git.Git' -Required)) {
        $script:Missing += @{ Name = 'git'; Kind = 'winget'; Id = 'Git.Git'; Required = $true }
    }

    # Optional-but-expected: absence degrades specific plugins rather than blocking setup.
    if (-not (Test-Tool -Name 'Azure CLI' -Command 'az' -VersionArgs @('version', '--output', 'tsv') `
        -NeededFor 'Dataverse Web API auth, FlowAgent' `
        -InstallHint 'winget install Microsoft.AzureCLI')) {
        $script:Missing += @{ Name = 'Azure CLI'; Kind = 'winget'; Id = 'Microsoft.AzureCLI'; Required = $false }
    }

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
        $pyId = Get-LatestPythonPackageId
        Write-Warn 'Python 3 not found - needed by the Dataverse plugin dv-connect'
        Write-Info "       install: winget install $pyId"
        $script:Missing += @{ Name = 'Python 3'; Kind = 'winget'; Id = $pyId; Required = $false }
    }

    if (Resolve-GhCli) {
        Write-Ok 'GitHub CLI present'
    } else {
        Write-Warn 'GitHub CLI not found - needed to create/push a private repo'
        Write-Info '       install: winget install GitHub.cli'
        $script:Missing += @{ Name = 'GitHub CLI'; Kind = 'winget'; Id = 'GitHub.cli'; Required = $false }
    }

    # canvas-apps documents .NET 10 as its minimum. Test for >= that major version rather
    # than an exact match, so a machine with only .NET 11 isn't told .NET is missing.
    $dotnetMinMajor = 10
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnet) {
        $majors = & dotnet --list-sdks 2>$null |
                  ForEach-Object { if ($_ -match '^(\d+)\.') { [int]$Matches[1] } } |
                  Sort-Object -Unique
        $best = $majors | Where-Object { $_ -ge $dotnetMinMajor } | Select-Object -Last 1
        if ($best) {
            Write-Ok ".NET SDK $best (canvas-apps needs >= $dotnetMinMajor)"
        } else {
            $have = if ($majors) { ($majors -join ', ') } else { 'none' }
            Write-Warn ".NET SDK >= $dotnetMinMajor not found (have: $have) - canvas-apps requires it"
            Write-Info "       install: winget install Microsoft.DotNet.SDK.$dotnetMinMajor"
            $script:Missing += @{ Name = ".NET SDK $dotnetMinMajor"; Kind = 'winget'; Id = "Microsoft.DotNet.SDK.$dotnetMinMajor"; Required = $false }
        }
    } else {
        Write-Warn ".NET SDK not found - canvas-apps requires >= $dotnetMinMajor"
        Write-Info "       install: winget install Microsoft.DotNet.SDK.$dotnetMinMajor"
        $script:Missing += @{ Name = ".NET SDK $dotnetMinMajor"; Kind = 'winget'; Id = "Microsoft.DotNet.SDK.$dotnetMinMajor"; Required = $false }
    }
}

function Assert-RequiredTools {
    $stillMissing = @()
    if (-not (Get-Command pac  -ErrorAction SilentlyContinue)) { $stillMissing += 'pac' }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { $stillMissing += 'node' }
    if (-not (Get-Command git  -ErrorAction SilentlyContinue)) { $stillMissing += 'git' }

    if ($stillMissing.Count -gt 0) {
        if ($InstallTools) {
            throw ("Required tools still missing after install: {0}. " -f ($stillMissing -join ', ')) +
                  "Open a NEW terminal (PATH may be stale) and re-run .\bootstrap.ps1 -Full."
        }
        throw ("Required tools missing: {0}. " -f ($stillMissing -join ', ')) +
              "Re-run with -Full to install them automatically."
    }
}

# ---------------------------------------------------------------------------
# First-run manifest
#
# Timestamped backups alone cannot drive an uninstall: they only capture files
# that already existed. On a machine where CLAUDE.md or skills/ were never there,
# nothing records their absence, so a restore would leave our files behind and
# call it success. This records what the machine looked like BEFORE the first run,
# and is written exactly once so re-runs cannot overwrite the original state.
# ---------------------------------------------------------------------------
$ManifestPath = Join-Path $ClaudeDir '.bootstrap-manifest.json'

function Save-BootstrapManifest {
    if (Test-Path -LiteralPath $ManifestPath) { return }   # never overwrite
    if ($WhatIfOnly) { Write-Info 'would record a first-run manifest of pre-existing state'; return }

    $pre = [ordered]@{
        recordedAt      = (Get-Date -Format 'o')
        claudeDirExisted = (Test-Path -LiteralPath $ClaudeDir)
        existingFiles   = @()
        existingDirs    = @()
        settingsExisted = (Test-Path -LiteralPath (Join-Path $ClaudeDir 'settings.json'))
        allowlistExisted = (Test-Path -LiteralPath (Join-Path $ClaudeDir 'dev-environments.txt'))
        claudeJsonHadMcp = $false
        preexistingPlugins = @()
        preexistingMarketplaces = @()
        toolsAlreadyPresent = @()
        toolsWeInstalled    = @()
    }

    foreach ($f in ($ManagedFiles + @('settings.json'))) {
        if (Test-Path -LiteralPath (Join-Path $ClaudeDir $f) -PathType Leaf) { $pre.existingFiles += $f }
    }
    foreach ($d in $ManagedDirs) {
        if (Test-Path -LiteralPath (Join-Path $ClaudeDir $d) -PathType Container) { $pre.existingDirs += $d }
    }

    $cj = Join-Path $env:USERPROFILE '.claude.json'
    if (Test-Path -LiteralPath $cj) {
        try {
            $parsed = Get-Content -LiteralPath $cj -Raw | ConvertFrom-Json
            $pre.claudeJsonHadMcp = ($parsed.PSObject.Properties.Name -contains 'mcpServers')
        } catch { }
    }

    # Anything already installed must survive the uninstall.
    if ($script:ClaudeCli) {
        try {
            $listed = (& $script:ClaudeCli plugin list 2>$null | Out-String)
            foreach ($p in $script:Plugins) {
                if ($listed -match [regex]::Escape($p)) { $pre.preexistingPlugins += $p }
            }
            $mkts = (& $script:ClaudeCli plugin marketplace list 2>$null | Out-String)
            foreach ($m in $script:Marketplaces) {
                if ($mkts -match [regex]::Escape($m.Name)) { $pre.preexistingMarketplaces += $m.Name }
            }
        } catch { }
    }

    foreach ($t in @('pac','node','git','az','dotnet','gh','python','claude')) {
        if (Get-Command $t -ErrorAction SilentlyContinue) { $pre.toolsAlreadyPresent += $t }
    }

    if (-not (Test-Path -LiteralPath $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }
    $pre | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $ManifestPath -Encoding utf8 -Force
    Write-Ok 'recorded pre-existing state for a clean uninstall'
}

function Add-InstalledToolToManifest {
    param([string]$Name, [string]$Kind, [string]$Id)
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return }
    try {
        $m = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        $list = @($m.toolsWeInstalled) | Where-Object { $_ }
        $list += [pscustomobject]@{ name = $Name; kind = $Kind; id = $Id }
        $m.toolsWeInstalled = $list
        $m | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $ManifestPath -Encoding utf8 -Force
    } catch { }
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
function Test-ToolPresent {
    param([string]$Name)

    # Verify by re-resolving the binary, never by the installer's exit code:
    # winget returns 0 for "already installed" and for some partial states.
    switch ($Name) {
        'Claude Code CLI' { return [bool]($script:ClaudeCli = Resolve-ClaudeCli) }
        'GitHub CLI'      { return [bool](Resolve-GhCli) }
        'Python 3'        { return [bool](Resolve-RealPython) }
        'pac CLI'         { return [bool](Get-Command pac    -ErrorAction SilentlyContinue) }
        'Node.js'         { return [bool](Get-Command node   -ErrorAction SilentlyContinue) }
        'git'             { return [bool](Get-Command git    -ErrorAction SilentlyContinue) }
        'Azure CLI'       { return [bool](Get-Command az     -ErrorAction SilentlyContinue) }
        default {
            if ($Name -like '.NET SDK*') {
                $d = Get-Command dotnet -ErrorAction SilentlyContinue
                return ($d -and ((& dotnet --list-sdks 2>$null) | Where-Object { $_ -match '^\d+\.' }))
            }
            return $false   # no verifier written - do not claim success
        }
    }
}

function Install-MissingTools {
    if (-not $script:Missing -or $script:Missing.Count -eq 0) {
        Write-Ok 'Nothing missing.'
        return
    }

    # winget before npm: npm does not exist until Node is installed.
    $ordered = @($script:Missing | Where-Object { $_.Kind -eq 'winget' }) +
               @($script:Missing | Where-Object { $_.Kind -ne 'winget' })

    foreach ($t in $ordered) {
        if ($WhatIfOnly) { Write-Info "would install $($t.Name) ($($t.Id)) via $($t.Kind)"; continue }

        Write-Info "installing $($t.Name)..."
        if ($t.Kind -eq 'winget') {
            & winget install --id $t.Id --source winget `
                --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
            # Pick up PATH entries the installer just wrote, so the next tool in the
            # list (and the npm stage below) can actually see it.
            Update-SessionPath
        } else {
            if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
                Write-Bad "$($t.Name) - npm not available (Node.js install may need a new terminal)"
                continue
            }
            & npm install -g $t.Id 2>&1 | Out-Null
            Update-SessionPath
        }

        if (Test-ToolPresent -Name $t.Name) {
            Write-Ok "$($t.Name)"
            # Record it so -Uninstall can offer to remove exactly what we added.
            Add-InstalledToolToManifest -Name $t.Name -Kind $t.Kind -Id $t.Id
        } elseif ($t.Required) {
            Write-Bad "$($t.Name) - REQUIRED and not usable after install"
        } else {
            Write-Warn "$($t.Name) - not usable yet; a new terminal may be needed"
        }
    }
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
# Two separable things, and only one of them belongs to the user:
#   - deciding which environments are safe to write to  -> the user's call,
#     because a guard the tooling can widen authorizes nothing
#   - creating the file                                 -> pure scaffolding
#
# So write the file, pre-filled with discovered pac profiles, every line
# commented out. Nothing is trusted until a human removes a '#', which keeps
# the fail-safe intact while reducing the work to editing one character.
# ---------------------------------------------------------------------------
function New-DevEnvironmentsFile {
    $path = Join-Path $ClaudeDir 'dev-environments.txt'

    if (Test-Path -LiteralPath $path) {
        # Same parsing as hooks/guard-pac-env.ps1: strip any trailing comment, then
        # keep the first token. Users enabling a line often delete both '#' chars.
        $active = @(Get-Content -LiteralPath $path |
                    ForEach-Object {
                        $line = $_.Trim()
                        if (-not $line -or $line.StartsWith('#')) { return }
                        $line = ($line -split '#', 2)[0].Trim()
                        if (-not $line) { return }
                        ($line -split '\s+')[0]
                    } |
                    Where-Object { $_ })
        if ($active.Count -gt 0) {
            Write-Ok "allowlist has $($active.Count) active entr$(if ($active.Count -eq 1) { 'y' } else { 'ies' }): $($active -join ', ')"
        } else {
            Write-Warn 'allowlist exists but every line is commented out - nothing is trusted yet'
            Write-Info "       uncomment the environments you want in $path"
        }
        return
    }

    $profiles = @()
    try {
        $profiles = @(& pac auth list 2>$null |
                      Select-String -Pattern '(https://[a-zA-Z0-9\-]+\.[a-zA-Z0-9\.\-]*dynamics\.com)' -AllMatches |
                      ForEach-Object { $_.Matches[0].Groups[1].Value } |
                      Sort-Object -Unique)
    } catch { }

    if ($WhatIfOnly) {
        Write-Info "would write $path with $($profiles.Count) discovered profile(s), all commented out"
        return
    }

    $lines = @(
        '# Environments safe for DESTRUCTIVE pac operations (import, delete, push).',
        '#',
        '# Matched as substrings against the target org URL. Uncomment a line to trust',
        '# that environment. Anything not listed here is treated as production and',
        '# blocked by ~/.claude/hooks/guard-pac-env.ps1.',
        '#',
        '# To enable one, delete the leading "#". The URL after the second "#" is just',
        '# a note showing what the token matches - leaving it, or deleting it, both work.',
        '#',
        '# Leave production commented out. That is the entire point of the file.',
        '#',
        '# This file is gitignored - client identifiers stay on this machine.',
        ''
    )

    if ($profiles.Count -gt 0) {
        $lines += '# --- pac auth profiles found on this machine ---'
        $lines += '# Uncomment the ones that are safe to write to:'
        $lines += ''
        foreach ($p in $profiles) {
            # Use the org host as the match token - shorter and stable across URL forms.
            $token = if ($p -match 'https://([a-zA-Z0-9\-]+)\.') { $Matches[1] } else { $p }
            $lines += "# $token".PadRight(28) + "  # $p"
        }
    } else {
        $lines += '# No pac auth profiles found yet. After `pac auth create`, re-run'
        $lines += '# bootstrap.ps1 and it will list your environments here.'
        $lines += '#'
        $lines += '# Example:'
        $lines += '#   contoso-dev'
        $lines += '#   myclient-uat'
    }
    $lines += ''

    $lines | Out-File -LiteralPath $path -Encoding utf8 -Force

    Write-Ok "wrote $path"
    if ($profiles.Count -gt 0) {
        Write-Info "listed $($profiles.Count) discovered environment(s), all commented out"
    }
    Write-Warn 'Nothing is trusted until you uncomment a line - destructive pac commands stay blocked.'
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    Write-Step 'Uninstall'

    $m = $null
    if (Test-Path -LiteralPath $ManifestPath) {
        try { $m = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json } catch { }
    }

    $prePlugins = @(); $preMarkets = @(); $preFiles = @(); $preDirs = @()
    $settingsExisted = $false; $allowlistExisted = $false; $claudeDirExisted = $true; $hadMcp = $false

    if (-not $m) {
        # No manifest (setup predates it, or it was deleted). Infer pre-existing state
        # from the earliest backup instead of assuming: a file captured there existed
        # before the first run. Assuming "did not exist" would delete a settings.json
        # that was only ever merged into - unrecoverable, and the worst outcome here.
        Write-Warn 'No first-run manifest - inferring pre-existing state from the earliest backup.'

        $b0 = Get-ChildItem $ClaudeDir -Directory -Filter '.backup-*' -Force -ErrorAction SilentlyContinue |
              Sort-Object Name | Select-Object -First 1
        if ($b0) {
            Write-Info "  using $($b0.Name)"
            foreach ($f in ($ManagedFiles + @('settings.json'))) {
                if (Test-Path -LiteralPath (Join-Path $b0.FullName $f)) { $preFiles += $f }
            }
            foreach ($d in $ManagedDirs) {
                if (Test-Path -LiteralPath (Join-Path $b0.FullName $d)) { $preDirs += $d }
            }
            $settingsExisted = ($preFiles -contains 'settings.json')
        } else {
            Write-Warn '  no backups either - nothing will be deleted, only reported.'
            Write-Info '  Remove files under ~/.claude by hand once you have checked them.'
            $preFiles = @($ManagedFiles) + @('settings.json')
            $preDirs  = @($ManagedDirs)
            $settingsExisted = $true
        }
    }

    if ($m) {
        $prePlugins      = @($m.preexistingPlugins)      | Where-Object { $_ }
        $preMarkets      = @($m.preexistingMarketplaces) | Where-Object { $_ }
        $preFiles        = @($m.existingFiles)           | Where-Object { $_ }
        $preDirs         = @($m.existingDirs)            | Where-Object { $_ }
        $settingsExisted = [bool]$m.settingsExisted
        $allowlistExisted= [bool]$m.allowlistExisted
        $claudeDirExisted= [bool]$m.claudeDirExisted
        $hadMcp          = [bool]$m.claudeJsonHadMcp
    }

    # --- plugins and marketplaces -------------------------------------------
    Write-Host ''
    Write-Info 'Plugins:'
    $cli = Resolve-ClaudeCli
    if (-not $cli) {
        Write-Warn '  claude CLI not available - remove plugins by hand with /plugin'
    } else {
        foreach ($p in $script:Plugins) {
            if ($prePlugins -contains $p) { Write-Info "  keeping $p (was already installed)"; continue }
            if ($WhatIfOnly) { Write-Info "  would uninstall $p"; continue }
            & $cli plugin uninstall $p --scope user 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "  removed $p" } else { Write-Warn "  $p (exit $LASTEXITCODE - may already be gone)" }
        }
        foreach ($mk in $script:Marketplaces) {
            if ($preMarkets -contains $mk.Name) { Write-Info "  keeping marketplace $($mk.Name) (pre-existing)"; continue }
            if ($WhatIfOnly) { Write-Info "  would remove marketplace $($mk.Name)"; continue }
            & $cli plugin marketplace remove $mk.Name 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "  removed marketplace $($mk.Name)" } else { Write-Warn "  marketplace $($mk.Name) (exit $LASTEXITCODE)" }
        }
    }

    # --- Learn MCP -----------------------------------------------------------
    Write-Host ''
    Write-Info 'Microsoft Learn MCP server:'
    if ($WhatIfOnly) {
        Write-Info '  would unregister microsoft-learn'
    } elseif ($cli) {
        & $cli mcp remove microsoft-learn --scope user 2>&1 | Out-Null
        Write-Ok '  unregistered microsoft-learn'
    } else {
        $cj = Join-Path $env:USERPROFILE '.claude.json'
        $bak = Get-ChildItem $env:USERPROFILE -Filter '.claude.json.bak-*' -Force -ErrorAction SilentlyContinue |
               Sort-Object Name | Select-Object -First 1
        if ($bak -and -not $hadMcp) {
            Copy-Item -LiteralPath $bak.FullName -Destination $cj -Force
            Write-Ok "  restored ~/.claude.json from $($bak.Name)"
        } else {
            Write-Warn '  remove the "microsoft-learn" entry from ~/.claude.json by hand'
        }
    }

    # --- config files --------------------------------------------------------
    Write-Host ''
    Write-Info 'Config files:'

    # The earliest backup holds the pre-existing copies, if any.
    $firstBackup = Get-ChildItem $ClaudeDir -Directory -Filter '.backup-*' -Force -ErrorAction SilentlyContinue |
                   Sort-Object Name | Select-Object -First 1

    foreach ($f in $ManagedFiles) {
        $dst = Join-Path $ClaudeDir $f
        if (-not (Test-Path -LiteralPath $dst)) { continue }
        if ($preFiles -contains $f) {
            $src = if ($firstBackup) { Join-Path $firstBackup.FullName $f } else { $null }
            if ($src -and (Test-Path -LiteralPath $src)) {
                if ($WhatIfOnly) { Write-Info "  would restore $f from backup" }
                else { Copy-Item -LiteralPath $src -Destination $dst -Force; Write-Ok "  restored $f" }
            } else { Write-Warn "  $f pre-existed but no backup copy found - left in place" }
        } else {
            if ($WhatIfOnly) { Write-Info "  would delete $f (did not exist before)" }
            else { Remove-Item -LiteralPath $dst -Force; Write-Ok "  deleted $f" }
        }
    }

    foreach ($d in $ManagedDirs) {
        $dst = Join-Path $ClaudeDir $d
        if (-not (Test-Path -LiteralPath $dst)) { continue }
        if ($preDirs -contains $d) {
            Write-Warn "  $d/ pre-existed - left in place; restore from $($firstBackup.Name) if needed"
        } else {
            if ($WhatIfOnly) { Write-Info "  would delete $d/ (did not exist before)" }
            else { Remove-Item -LiteralPath $dst -Recurse -Force; Write-Ok "  deleted $d/" }
        }
    }

    # settings.json: restore the original, or remove it if we created it.
    $settingsPath = Join-Path $ClaudeDir 'settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
        if ($settingsExisted) {
            $src = if ($firstBackup) { Join-Path $firstBackup.FullName 'settings.json' } else { $null }
            if ($src -and (Test-Path -LiteralPath $src)) {
                if ($WhatIfOnly) { Write-Info '  would restore settings.json from backup' }
                else { Copy-Item -LiteralPath $src -Destination $settingsPath -Force; Write-Ok '  restored settings.json' }
            } else { Write-Warn '  settings.json pre-existed but no backup found - left in place' }
        } else {
            if ($WhatIfOnly) { Write-Info '  would delete settings.json (did not exist before)' }
            else { Remove-Item -LiteralPath $settingsPath -Force; Write-Ok '  deleted settings.json' }
        }
    }

    # allowlist: ours unless it pre-existed. Contains client identifiers, so removing
    # it is the polite default on someone else's machine.
    $allow = Join-Path $ClaudeDir 'dev-environments.txt'
    if ((Test-Path -LiteralPath $allow) -and -not $allowlistExisted) {
        if ($WhatIfOnly) { Write-Info '  would delete dev-environments.txt' }
        else { Remove-Item -LiteralPath $allow -Force; Write-Ok '  deleted dev-environments.txt' }
    }

    # --- tools ---------------------------------------------------------------
    Write-Host ''
    Write-Info 'Tools:'
    $installed = @()
    if ($m -and $m.PSObject.Properties.Name -contains 'toolsWeInstalled') {
        $installed = @($m.toolsWeInstalled) | Where-Object { $_ }
    }

    if ($installed.Count -eq 0) {
        Write-Info '  none were installed by this script'
    } elseif (-not $RemoveTools) {
        Write-Warn "  $($installed.Count) tool(s) were installed and are being LEFT IN PLACE:"
        foreach ($t in $installed) {
            $cmd = if ($t.kind -eq 'npm') { "npm uninstall -g $($t.id)" } else { "winget uninstall --id $($t.id)" }
            Write-Info "    $($t.name)  ->  $cmd"
        }
        Write-Info '  Re-run with -Uninstall -RemoveTools to remove them automatically.'
        Write-Info '  Left by default because Node, git and similar are usually wanted anyway.'
    } else {
        foreach ($t in $installed) {
            if ($WhatIfOnly) { Write-Info "  would uninstall $($t.name)"; continue }
            if ($t.kind -eq 'npm') { & npm uninstall -g $t.id 2>&1 | Out-Null }
            else { & winget uninstall --id $t.id --disable-interactivity 2>&1 | Out-Null }
            Write-Ok "  uninstalled $($t.name)"
        }
    }

    # --- manifest and directory ---------------------------------------------
    if (-not $WhatIfOnly -and (Test-Path -LiteralPath $ManifestPath)) {
        Remove-Item -LiteralPath $ManifestPath -Force
    }

    Write-Host ''
    if (-not $claudeDirExisted) {
        Write-Warn "~/.claude did not exist before setup."
        Write-Info "  Backups and Claude Code's own state still live there. Once you've confirmed"
        Write-Info "  nothing is needed, remove the whole folder:"
        Write-Info "    Remove-Item '$ClaudeDir' -Recurse -Force"
    } else {
        Write-Info "Timestamped backups are still under $ClaudeDir (.backup-*)."
        Write-Info 'Delete them once you are satisfied the rollback is correct.'
    }

    Write-Host ''
    Write-Host 'Uninstall complete. Restart Claude Code to unload plugins and the MCP server.' -ForegroundColor Green
    Write-Host ''
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
    Write-Host '  3. Uncomment your safe environments (the file is already written for you):' -ForegroundColor White
    Write-Host "       $ClaudeDir\dev-environments.txt" -ForegroundColor Cyan
    Write-Host '       Every line starts commented out - nothing is trusted until you edit it.' -ForegroundColor Gray
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

if ($Uninstall) {
    Invoke-Uninstall
    return
}

# Must run before anything is changed, and only writes on the very first run.
Write-Step 'Recording pre-existing state'
Save-BootstrapManifest

if ($InstallTools) {
    Write-Step 'Installing missing tools'
    Install-MissingTools
}

# Deferred until after the install attempt, so -Full can fix a clean machine rather
# than refusing to start on one.
if (-not $WhatIfOnly) { Assert-RequiredTools }

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
