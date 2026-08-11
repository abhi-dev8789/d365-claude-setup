# Claude Code — Power Platform / D365 Configuration

A portable, versioned Claude Code setup for Dynamics 365 CRM and Power Platform work.

`~/.claude/` is treated as **derived output**. Everything is authored here, then projected
onto a machine by `bootstrap.ps1`. A new laptop needs a clone and one command — not a
re-explanation.

## Why this exists

Claude Code with no configuration starts every session cold: no Power Platform grounding,
no live documentation source, so it reasons from its training cutoff and whatever the open
web returns. In practice that means deprecated APIs (`Xrm.Page`, `OrganizationServiceProxy`),
guesses about what the platform can do, and unverified claims of success. The time saved on
the work gets spent cross-checking it.

This repo fixes that at the configuration layer:

- **Microsoft Learn MCP** wired in, so docs are looked up live instead of recalled.
- **Microsoft's official plugins** for Dataverse, model-driven apps, Power Automate, Canvas,
  Power Pages, code apps and mobile.
- **Custom skills** for the pro-dev gap Microsoft's plugins don't cover — C# plugins,
  web resources, PCF controls, and solution ALM.
- **Explicit rules** in `CLAUDE.md` that forbid the specific failure modes observed.
- **A safety net** — statusline and a pre-flight hook — so a schema change never lands in the
  wrong client's environment unnoticed.

## Requirements and access

**Windows only.** `bootstrap.ps1` is PowerShell and installs via `winget`; the hook and status
line are `.ps1`. The *content* — `CLAUDE.md`, the four skills, the plugin list — is
platform-neutral, so a macOS or Linux user can copy `claude/` into `~/.claude` by hand and run
the `claude plugin install` lines from `docs/manual-steps.md`. Only the automation is
Windows-bound.

**The repo is private**, so cloning needs access. Which route depends on who is setting up:

| Who | How they get access |
|---|---|
| **You, on a new machine** | Sign in to GitHub as the repo owner. Git Credential Manager (bundled with Git for Windows) prompts on first clone and stores the token. Or run `gh auth login` first. |
| **A teammate** | Add them on GitHub → repo **Settings → Collaborators**. They then clone normally with their own credentials. |
| **No GitHub access at all** | Download the repo as a ZIP from the web UI, extract, and run `bootstrap.ps1 -Full`. Nothing in the setup requires git at runtime — git is only how the repo travels. |

If a clone fails with `Authentication failed` or `repository not found`, it's almost always
access rather than a bad URL — a private repo returns "not found" to anyone without permission,
which is confusing but deliberate.

## Setting up a machine

```powershell
git clone https://github.com/abhi-dev8789/d365-claude-setup claude-config
cd claude-config
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Full
```

> **Use that exact command — don't shorten it to `.\bootstrap.ps1`.** Windows blocks unsigned
> scripts by default (`Restricted` on most client installs, `AllSigned` on managed ones), and
> the plain form fails with *"is not digitally signed"* or *"running scripts is disabled on
> this system"*. `-ExecutionPolicy Bypass` applies to that one process only: it changes no
> machine setting and needs no admin rights.
>
> If you downloaded a **ZIP** instead of cloning, Windows also tags the files as
> internet-sourced. Clear that first, from the repo folder:
>
> ```powershell
> Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
> ```
>
> Cloning with git doesn't set that tag, so this is a ZIP-only step.

### Before you start

- **Claude Code installed and signed in** — the VS Code extension or the CLI, either is fine.
  Bootstrap installs the CLI if it's missing, but it can't sign in for you.
- **winget available** — ships with App Installer on Windows 10/11. Check with
  `winget --version`. Without it, bootstrap can still project config and install plugins, but
  it can't install missing tools; install those by hand from the table below.
- **A UAC prompt or two** is normal if winget installs anything machine-scoped.

That single command installs **every** missing prerequisite — pac CLI, Node, git, .NET, Azure
CLI, Python, GitHub CLI, and the Claude Code CLI — projects the config into `~/.claude`,
registers the Microsoft Learn MCP server, adds both plugin marketplaces, and installs all
eight plugins. Each step is verified by re-checking the result, not by trusting an exit code.

winget writes `PATH` to the registry, which a running shell won't see, so bootstrap refreshes
its own `PATH` after each install. That ordering matters: Node has to be installed *and*
visible before npm can install the Claude Code CLI.

> **Tested end-to-end on a machine that already had the toolchain.** The clean-machine path —
> where winget installs Node and the same run then uses npm — is written for but not yet
> exercised on a genuinely bare Windows install. If a tool lands but isn't usable in the same
> run, bootstrap says so and tells you to re-run from a new terminal; because it's idempotent,
> that second run is harmless. Worth knowing before you hand this to someone else as
> guaranteed-first-time.

It is idempotent. Re-run it any time; it backs up whatever it is about to replace and
**merges** into `settings.json` rather than overwriting, so machine-local settings survive.

Run it without `-Full` to project config only and report missing tools without installing
anything. `-WhatIfOnly` shows what would change and writes nothing.

### What still needs a human

Three things genuinely can't be scripted:

1. **`pac auth create --environment <url>`** — Entra sign-in, opens a browser.
2. **Per-plugin setup**, inside a Claude Code session: `dv-connect`,
   `/configure-canvas-mcp`, and the power-automate `setup` skill.
3. **`~/.claude/dev-environments.txt`** — which environments are safe to write to is a
   judgement call, and a guard that a script can widen isn't a guard. `bootstrap.ps1`
   lists your `pac auth` profiles to make it a copy-paste job.

Restart Claude Code afterwards to load the plugins and MCP server.

### Prerequisites

`bootstrap.ps1 -Full` installs the ones marked ✓. The rest are reported if missing.

| Tool | Needed for | Auto | Install |
|---|---|---|---|
| Claude Code CLI | plugin install, MCP registration | ✓ | `npm install -g @anthropic-ai/claude-code` |
| Python 3 | Dataverse plugin `dv-connect` | ✓ | newest `Python.Python.3.*` winget offers |
| GitHub CLI | pushing this repo | ✓ | `winget install GitHub.cli` |
| pac CLI ≥ 2.7 | all Power Platform plugins | | `winget install Microsoft.PowerPlatformCLI` |
| .NET SDK ≥ 10 | canvas-apps plugin | | `winget install Microsoft.DotNet.SDK.10` |
| Node.js ≥ 18 | code apps, FlowAgent MCP | | `winget install OpenJS.NodeJS.LTS` |
| Azure CLI | Dataverse Web API auth, FlowAgent | | `winget install Microsoft.AzureCLI` |
| git | cloning this repo | | `winget install Git.Git` |

**On version pinning.** No Python version is hardcoded. winget has no version-agnostic
`Python.Python.3` id, so `bootstrap.ps1` queries winget and installs the newest `3.x` it
offers, falling back to a pin only if the query fails. Version checks are minimums (`>=`), not
exact matches, so newer releases satisfy them: a machine with .NET 11 and no .NET 10 passes.
The two real floors — pac ≥ 2.7 for `model-apps`, .NET ≥ 10 for `canvas-apps` — come from
Microsoft's own plugin docs and are declared as named constants near the top of the preflight
so they're easy to raise when Microsoft moves them.

> **Windows gotcha:** installing Python isn't always enough. The Store's *App execution
> alias* for `python.exe` shadows a real install on `PATH`. `bootstrap.ps1` detects this
> and tells you to turn it off under **Settings → Apps → Advanced app settings → App
> execution aliases**.

## Undoing it

If someone tries this and decides they don't want it, one command reverses it:

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Uninstall
```

Add `-WhatIfOnly` first to see exactly what it would do without touching anything.

It uninstalls the eight plugins and both marketplaces, unregisters the Learn MCP server,
restores or deletes each config file, and removes the environment allowlist. Anything that
was already on the machine before setup is kept — the first run records a manifest of
pre-existing state (`~/.claude/.bootstrap-manifest.json`), so a plugin or marketplace the
user already had is left alone.

**Tools are deliberately left installed.** Node, git, pac and the rest are commonly wanted
for other work, so silently removing them would be worse than leaving them. The uninstall
lists exactly what it added with the command to remove each. Pass `-RemoveTools` if you
genuinely want them gone.

If the manifest is missing — setup predates it, or someone deleted it — the uninstall infers
pre-existing state from the earliest `.backup-*` folder rather than guessing. A file captured
there existed before the first run and is restored; a file absent from it was ours and is
removed. With no backups either, it deletes nothing and only reports, because assuming "this
didn't exist" would destroy a `settings.json` that was only ever merged into.

### What it will not touch

The uninstall only removes things this repo created. Specifically:

| Concern | Behaviour |
|---|---|
| **Your own skills** | `skills/` and `hooks/` are shared folders. It deletes only the files this repo ships, never the directory, and removes the directory afterwards only if it's empty. A skill you added yourself survives. |
| **Your settings** | It strips only the keys it added — its plugin entries, its permission strings, its `statusLine`, its hook. Every other key is kept, including changes made after setup. It does **not** restore `settings.json` wholesale, because that would silently revert your later edits. |
| **`statusLine` / hooks you repointed** | Removed only if they still reference this repo's scripts. Point them at something of your own and they're left alone. |
| **`~/.claude.json`** | Only the `microsoft-learn` block is excised, and only if it's byte-identical to what was inserted. Never restored wholesale — it's a live state file holding your account, project registrations and history. If it's been edited since, it's left untouched with a note. |
| **Plugins and marketplaces** | Only the eight installed here, and only those not already present before setup. |
| **Tools** | Left installed unless you pass `-RemoveTools`. |
| **Anything else under `~/.claude`** | Never touched. |

Before deleting anything it snapshots the current state to `~/.claude/.pre-uninstall-<timestamp>`,
separate from the pre-install `.backup-*` folders. So there are two recovery points: what the
machine looked like before setup, and what it looked like just before removal.

> Verified with `-WhatIfOnly` against a machine seeded with a user's own skill, their own
> permission entry, and a custom settings key — all three survived, while the eight plugins,
> 51 permissions, `statusLine` and hook were correctly identified for removal. A full
> destructive round-trip has not been run, so do the `-WhatIfOnly` pass first and read it.

## Layout

```
claude/                    projected into ~/.claude by bootstrap.ps1
├── CLAUDE.md              global rules and platform gotchas
├── settings.template.json merged into settings.json (never overwrites)
├── skills/                custom skills for the D365 pro-dev gap
├── hooks/                 environment guard
└── statusline.ps1         shows the active Dataverse org on every prompt

docs/
├── manual-steps.md        the /plugin commands to run in-session
└── sources.md             Learn URLs + verified-on dates behind each skill
```

## Working rule

**Edit here, then run `.\bootstrap.ps1`.** The repo is the source of truth.

If you edited `~/.claude` directly mid-session, rescue it with:

```powershell
.\bootstrap.ps1 -SyncBack
```

which copies changes back into the repo so they can be reviewed and committed.

## What never gets committed

`.gitignore` blocks OAuth credentials, pac auth profiles, session transcripts, and local
overrides. No org URL, environment GUID, tenant ID or client name belongs in this repo —
`CLAUDE.md` deliberately contains rules and platform gotchas only, so it stays safe to push
and safe to share across client engagements. Environment-specific detail stays in per-project
config on the machine that needs it.

## Skill freshness

The custom skills in `claude/skills/` are grounded in Microsoft Learn at authoring time, with
every source URL and verification date recorded in [docs/sources.md](docs/sources.md). They
are documentation snapshots and will drift. Re-validate them against the Learn MCP server
periodically — the point of this setup is to not trust stale docs, and that applies to these
files too.
