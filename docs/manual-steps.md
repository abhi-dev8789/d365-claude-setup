# Manual steps

Start here:

```powershell
git clone https://github.com/abhi-dev8789/d365-claude-setup claude-config
cd claude-config
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Full
```

That does everything scriptable: prerequisites, config projection, Learn MCP registration,
both marketplaces, and all eight plugins.

**The `-ExecutionPolicy Bypass -File` form is required**, not decoration. Windows refuses
unsigned scripts by default, so a bare `.\bootstrap.ps1` fails with *"is not digitally
signed"* or *"running scripts is disabled on this system"*. The flag is process-scoped —
no machine change, no admin rights.

Then **restart Claude Code** so it loads the plugins and MCP server.

Only three things below genuinely need a human. Run them once per machine.

---

## 1. Plugins — already automated

`bootstrap.ps1 -Full` installs these via `claude plugin install`, the documented
non-interactive equivalent of the `/plugin` slash command:

```
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin marketplace add microsoft/power-platform-skills

claude plugin install dataverse@claude-plugins-official        --scope user
claude plugin install model-apps@power-platform-skills         --scope user
claude plugin install power-automate@power-platform-skills     --scope user
claude plugin install canvas-apps@power-platform-skills        --scope user
claude plugin install power-pages@power-platform-skills        --scope user
claude plugin install code-apps-preview@power-platform-skills  --scope user
claude plugin install mobile-app@power-platform-skills         --scope user
claude plugin install mcp-apps@power-platform-skills           --scope user
```

Bootstrap verifies the result against `claude plugin list` rather than the install exit
codes. Check yourself any time with `/plugin` → **Installed**, or `claude plugin list`.

`settings.template.json` also declares `extraKnownMarketplaces` and `enabledPlugins`. That
records intent and survives to a new machine, but it does **not** fetch plugins from an
external marketplace on its own — the install step is still required, which is why bootstrap
runs both.

> Microsoft ships an `install.js` bootstrapper that does this plus a toolchain install. We
> don't use it: the toolchain is already handled by `bootstrap.ps1`'s preflight, and piping a
> remote script straight into `node` is worth avoiding when the per-step equivalent is this
> short.

## 2. Authenticate to Dataverse — needs you

```powershell
pac auth create --environment https://<your-dev-env>.crm<n>.dynamics.com
pac auth list          # confirm the right profile is active
```

Entra browser sign-in. No client secrets, nothing stored in plaintext by us.

Switch environments later with `pac auth select --index N`. The status line shows which is
active — check it before any write.

## 3. Uncomment your safe environments — needs you

`bootstrap.ps1` already wrote `~/.claude/dev-environments.txt`, pre-filled with the `pac auth`
profiles it found on this machine — **every line commented out**:

```
# --- pac auth profiles found on this machine ---
# Uncomment the ones that are safe to write to:

# contoso-dev                 # https://contoso-dev.crm8.dynamics.com
# contoso-prod                # https://contoso-prod.crm8.dynamics.com
```

Open it and delete the leading `#` on each environment that is safe for destructive
operations. That is the whole step. Gitignored by design — client identifiers stay on the
machine.

**Leave production commented.** When the hook fires on a prod target, that's it working.

If you ran bootstrap before `pac auth create`, the file has no profiles yet — re-run it
afterwards and it will list them.

### Why bootstrap writes the file but won't uncomment a line

Two separable things, and only one is a security decision:

- **Creating the file** is scaffolding. It authorizes nothing, so automating it just saves you
  from authoring a format you have never seen.
- **Choosing which environments to trust** is exactly what the guard exists to protect. If the
  tooling — or Claude — could widen the allowlist, the guard would be self-authorizing and
  worth nothing.

So bootstrap writes it fully commented, and the same rule binds Claude via `CLAUDE.md`. Nothing
is trusted until a human removes a `#`.

## 4. Run the per-plugin setup — needs you

| Plugin | Step | Notes |
|---|---|---|
| dataverse | run `dv-connect` | Installs the Dataverse CLI + Python SDK, authenticates, registers the Dataverse MCP server. **Needs a real Python 3** — see the App execution alias note in the README. |
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
