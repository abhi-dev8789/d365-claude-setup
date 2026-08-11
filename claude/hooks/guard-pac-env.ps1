<#
    PreToolUse hook - blocks destructive Power Platform commands aimed at an
    environment that has not been explicitly declared safe.

    Why a hook and not a CLAUDE.md rule: the harness enforces hooks deterministically.
    An instruction is advisory and gets skipped exactly when context is long and
    attention is elsewhere - which is precisely when a solution import lands in the
    wrong client's production.

    Contract:
      stdin  - JSON: { tool_name, tool_input: { command, ... }, ... }
      exit 0 - allow (silent)
      exit 2 - block; stderr is fed back to Claude as the reason

    Safe environments are declared in ~/.claude/dev-environments.txt, one substring
    per line. That file is machine-local and gitignored, so client org URLs never
    enter the repo.
#>

$ErrorActionPreference = 'Stop'

$AllowlistFile = Join-Path $env:USERPROFILE '.claude\dev-environments.txt'

# Operations that mutate an environment in ways that are slow or impossible to undo.
# Read-only verbs (list, who, export, unpack) are deliberately absent.
$DestructiveVerbs = @(
    'solution\s+import',
    'solution\s+delete',
    'solution\s+upgrade',
    'data\s+delete',
    'org\s+delete',
    'org\s+reset',
    'application\s+install',
    'package\s+deploy',
    'plugin\s+push',
    'pcf\s+push',
    'webresource\s+push',
    'canvas\s+create'
)

# Anchor 'pac' to a command position - start of string, or after a separator.
# Without this, merely *mentioning* one of these commands (in an echo, a grep, a
# heredoc, or documentation) trips the guard. The point is to block execution,
# not discussion.
$CommandStart = '(?:^|[;&|`]|\n)\s*(?:&\s*)?["'']?(?:[\w:\\/\.\- ]*[\\/])?pac(?:\.exe)?["'']?\s+'
$DestructivePatterns = $DestructiveVerbs | ForEach-Object { $CommandStart + $_ }

function Exit-Allow { exit 0 }

function Exit-Block {
    param([string]$Reason)
    [Console]::Error.WriteLine($Reason)
    exit 2
}

# --- Read the tool call -----------------------------------------------------
$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { Exit-Allow }
if ([string]::IsNullOrWhiteSpace($raw)) { Exit-Allow }

$command = ''
try {
    $payload = $raw | ConvertFrom-Json
    if ($payload.PSObject.Properties.Name -contains 'tool_input') {
        $ti = $payload.tool_input
        if ($ti -and ($ti.PSObject.Properties.Name -contains 'command')) { $command = [string]$ti.command }
    }
} catch {
    # Unparseable payload is not grounds to block an unrelated tool call.
    Exit-Allow
}

if ([string]::IsNullOrWhiteSpace($command)) { Exit-Allow }

# --- Is this something we care about? --------------------------------------
$matched = $null
foreach ($pattern in $DestructivePatterns) {
    if ($command -match $pattern) {
        # Report the verb, not the whole matched span (which includes the separator
        # and any path prefix) so the message reads cleanly.
        $matched = ($Matches[0] -replace '^[\s;&|`\n]*', '' -replace '\s+', ' ').Trim()
        break
    }
}
if (-not $matched) { Exit-Allow }

# --- Resolve the target environment ----------------------------------------
# An explicit --environment / --url on the command line wins; otherwise the
# operation hits whatever pac profile is currently active.
$target = $null
$source = ''

# Exclude quotes and braces from the capture - a lazy \S+? happily swallows the
# trailing "}} when the command arrives embedded in JSON.
if ($command -match '(?:--environment|--url|-env)\s+["'']?([^\s"''`}]+)') {
    $target = $Matches[1]
    $source = 'the --environment argument'
} else {
    try {
        $lines  = & pac auth list 2>$null
        $active = $lines | Where-Object { $_ -match '^\s*\[?\d+\]?\s*\*' } | Select-Object -First 1
        if ($active -and $active -match '(https://\S*dynamics\.com[^\s]*)') {
            $target = $Matches[1]
            $source = 'the active pac auth profile'
        }
    } catch { }
}

if (-not $target) {
    Exit-Block @"
BLOCKED: '$matched' - cannot determine the target environment.

No --environment argument was given and no active pac auth profile could be read,
so there is no way to confirm this is not production.

Run 'pac auth list' to check what is active, then either select the right profile
with 'pac auth select --index N' or pass --environment explicitly.
"@
}

# --- Check it against the allowlist ----------------------------------------
if (-not (Test-Path -LiteralPath $AllowlistFile)) {
    Exit-Block @"
BLOCKED: '$matched' targeting $target (from $source).

No environment allowlist exists yet, so no environment is trusted for destructive
operations. This is a one-time setup step.

Create $AllowlistFile with one substring per line matching each environment that is
safe to write to, for example:

    contoso-dev
    myclient-uat
    org12345678

Lines starting with # are ignored. This file is gitignored - client URLs stay on
this machine and never reach the repo.

Ask the user which environments belong in it. Do not create it unilaterally.
"@
}

$entries = Get-Content -LiteralPath $AllowlistFile |
           ForEach-Object { $_.Trim() } |
           Where-Object { $_ -and -not $_.StartsWith('#') }

foreach ($entry in $entries) {
    if ($target -like "*$entry*") { Exit-Allow }
}

Exit-Block @"
BLOCKED: '$matched' targeting $target (from $source).

That environment is not in the allowlist at $AllowlistFile, so it is treated as
production. Nothing was executed.

If this is intentional, tell the user exactly which environment is about to be
modified and ask them to confirm before adding it to the allowlist. Do not add it
yourself.
"@
