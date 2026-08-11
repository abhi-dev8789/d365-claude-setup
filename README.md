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

## Setting up a machine

```powershell
git clone <this-repo> claude-config
cd claude-config
.\bootstrap.ps1
```

Then run the `/plugin` commands it prints (see [docs/manual-steps.md](docs/manual-steps.md) —
slash commands are interactive and cannot be scripted), and authenticate:

```powershell
pac auth create --environment <your-dev-env-url>
```

`bootstrap.ps1` is idempotent — re-run it any time. It backs up whatever it is about to
replace, and **merges** into `settings.json` rather than overwriting, so machine-local
settings survive.

### Prerequisites

Checked by `bootstrap.ps1`, which reports what's missing rather than installing it silently.

| Tool | Needed for | Install |
|---|---|---|
| Claude Code | everything | — |
| pac CLI ≥ 2.7 | all Power Platform plugins | `winget install Microsoft.PowerPlatformCLI` |
| .NET SDK 10 | canvas-apps plugin | `winget install Microsoft.DotNet.SDK.10` |
| Node.js ≥ 18 | code apps, FlowAgent MCP | `winget install OpenJS.NodeJS.LTS` |
| Azure CLI | Dataverse Web API auth, FlowAgent | `winget install Microsoft.AzureCLI` |
| Python 3 | Dataverse plugin `dv-connect` | `winget install Python.Python.3.12` |
| git | this repo | `winget install Git.Git` |

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
