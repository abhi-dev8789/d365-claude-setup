# Manual steps

`bootstrap.ps1` handles files, settings and the Learn MCP registration. These steps can't be
scripted — `/plugin` is an interactive slash command, and the auth flows open a browser.

Run them once per machine, in order.

---

## 1. Install the plugins

Inside a Claude Code session:

```
/plugin install dataverse@claude-plugins-official
```

Then the Microsoft app-layer marketplace:

```
/plugin marketplace add microsoft/power-platform-skills
/plugin install model-apps@power-platform-skills
/plugin install power-automate@power-platform-skills
/plugin install canvas-apps@power-platform-skills
/plugin install power-pages@power-platform-skills
/plugin install code-apps-preview@power-platform-skills
/plugin install mobile-app@power-platform-skills
/plugin install mcp-apps@power-platform-skills
```

Verify with `/plugin` — all eight should show as enabled.

> Microsoft ships an `install.js` bootstrapper that does this plus a toolchain install. We
> don't use it: the toolchain is already handled by `bootstrap.ps1`'s preflight, and piping a
> remote script straight into `node` is worth avoiding when the per-step equivalent is this
> short.

## 2. Authenticate to Dataverse

```powershell
pac auth create --environment https://<your-dev-env>.crm<n>.dynamics.com
pac auth list          # confirm the right profile is active
```

Entra browser sign-in. No client secrets, nothing stored in plaintext by us.

Switch environments later with `pac auth select --index N`. The status line shows which is
active — check it before any write.

## 3. Declare your safe environments

The `PreToolUse` hook blocks destructive `pac` commands against environments you haven't
declared. Create `~/.claude/dev-environments.txt` with one substring per line:

```
# Environments safe for destructive operations (import, delete, push).
# Matched as substrings against the target org URL.
myorg-dev
myclient-uat
```

Gitignored by design — client identifiers stay on the machine.

Leave production out. When the hook fires on a prod target, that's it working.

## 4. Run the per-plugin setup

| Plugin | Step | Notes |
|---|---|---|
| dataverse | run `dv-connect` | Installs the Dataverse CLI + Python SDK, authenticates, registers the Dataverse MCP server. **Install Python 3 first.** |
| canvas-apps | `/configure-canvas-mcp` | Wires up the Canvas Authoring MCP server. Needs .NET 10. |
| power-automate | ask Claude to run its `setup` skill | Starts the bundled FlowAgent MCP server. Needs Node ≥ 18 and Azure CLI. |

### Expect this on client tenants

The Dataverse MCP server requires **tenant-level admin consent** and **per-environment
allowlisting**. The plugin doesn't bypass these — that's correct behaviour, not a bug. If
you're not a tenant admin, `dv-connect` may stall at that step and you'll need an admin to
grant it.

The `pac`-based skills keep working regardless, so this is a partial degradation rather than
a blocker.

## 5. Verify

```powershell
claude mcp list      # microsoft-learn -> connected
pac auth list        # active profile on a dev environment
```

In-session:

- `/plugin` lists all eight plugins.
- The status line shows the active environment (green = recognised non-prod, red = treat as
  production).
- Ask a Power Platform question and confirm the answer cites Microsoft Learn.

### The test that actually matters

In a scratch dev environment, ask:

> Create a Dataverse table `Equipment` with a text column, an option-set column, and a lookup
> to Account, in solution X.

It should complete **without guidance and without claiming it can't be automated**. Then check
in make.powerapps.com that the table and all three columns exist with the right types.

That's the regression test for the problem this whole setup was built to solve. If it passes,
the setup works. If it doesn't, the gap is in the plugin rather than the configuration — and
the fix is a targeted custom skill in `claude/skills/`.
