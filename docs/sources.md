# Sources and verification status

The custom skills in `claude/skills/` are documentation snapshots. They will drift. This file
records what each was built from and — importantly — **which claims were not verified against a
fetched page.**

The whole point of this setup is to stop trusting stale docs. That has to apply to these files
too, or they become the problem they were written to solve.

**Authored:** 2026-08-11
**Method:** direct fetch of Microsoft Learn pages (the Learn MCP server was registered as part
of the same setup, so the first authoring pass used direct fetches).

---

## Verified — fetched and read at authoring time

| Skill | Learn page | Page `ms.date` | Last updated |
|---|---|---|---|
| `d365-plugins` | [Use plug-ins to extend business processes](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/plug-ins) | 2026-03-30 | 2026-04-01 |
| `d365-plugins` | [Write a plug-in](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/write-plug-in) | 2026-07-02 | 2026-07-10 |
| `d365-plugins` | [Event framework](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/event-framework) | 2026-03-09 | 2026-03-10 |
| `d365-web-resources` | [Client API form context](https://learn.microsoft.com/en-us/power-apps/developer/model-driven-apps/clientapi/clientapi-form-context) | 2026-03-27 | 2026-03-28 |
| `pcf-controls` | [Power Apps component framework overview](https://learn.microsoft.com/en-us/power-apps/developer/component-framework/overview) | 2026-01-09 | 2026-01-16 |
| `d365-alm` | [Use a connection reference in a solution](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-connection-reference) | 2026-01-09 | 2026-01-09 |
| (setup) | [Microsoft Learn MCP Server overview](https://learn.microsoft.com/en-us/training/support/mcp) | 2026-05-05 | 2026-05-22 |

Specifically confirmed from those pages, not from memory:

- `IPlugin.Execute(IServiceProvider)`, the three constructor signatures, statelessness caching
  behaviour, and the `PluginBase` / `ILocalPluginContext` pattern
- `GetService` retrieval of `IPluginExecutionContext`, `IOrganizationServiceFactory`,
  `ITracingService`
- Web API is **not supported** inside plug-ins; users are pre-authenticated
- Early-bound `ToEntity<T>()` is fine for reads; assigning an early-bound type into
  `InputParameters` throws `SerializationException`
- Pipeline stage names and semantics; PreValidation runs **before security checks**; PostOperation
  modification triggers a new Update event; exceptions at sync in-transaction stages roll back
- Async mode is required when updating on `Create` of `SystemUser`
- Trace logging must be enabled in the environment before `PluginTraceLog` receives anything
- `Xrm.Page` deprecation status and the six-month removal notice commitment; the
  `executionContext.getFormContext()` replacement; "Pass execution context as first parameter"
- Form contexts are valid **only during the event in which they are passed**
- PCF not supported on-premises; `external-service-usage` making a component premium
- Connection reference behaviour: flows use them for all connectors, canvas apps only for
  implicitly shared connections; custom connectors must be imported in a **separate solution
  first**; copy-environment breaks custom connector references; `ConnectionAuthorizationFailed`
  cause and resolution

---

## NOT independently verified — treat as needing a Learn MCP check before relying on

These are written from general knowledge and are stable, widely-used facts, but no page was
fetched to confirm them during authoring. They're flagged in the skills themselves where it
matters.

| Claim | Where | Why flagged |
|---|---|---|
| Pipeline stage registration values 10 / 20 / 30 / 40 | `d365-plugins` | Named stages confirmed; the numeric values were not on the fetched page |
| Synchronous plug-in time limit = 2 minutes | `d365-plugins` | Learn confirms a hard limit exists and links to "Analyze plug-in performance"; that page was not fetched, so the figure is unconfirmed. The skill says so inline. |
| `context.Depth` threshold behaviour | `d365-plugins` | Depth exists; the exact platform abort threshold was not confirmed |
| Custom API parameter flags (`IsFunction`, `IsPrivate`, `AllowedCustomProcessingStepType`) | `d365-plugins` | The Custom API page was not fetched |
| PCF lifecycle signatures (`init` / `updateView` / `getOutputs` / `destroy`) | `pcf-controls` | Only the PCF *overview* page was fetched; the lifecycle reference was not |
| `ControlManifest.Input.xml` structure, `of-type`, `usage`, `feature-usage` | `pcf-controls` | Same — overview only |
| `pac pcf init` / `pac pcf push` flag syntax | `pcf-controls` | CLI reference not fetched |
| Dataset paging API (`paging.loadNextPage()`, `hasNextPage`) | `pcf-controls` | Not fetched |
| `pac solution create-settings` / `--settings-file` syntax | `d365-alm` | CLI reference not fetched. This is the most useful command in that skill — **verify it first.** |
| `pac webresource push` flag syntax | `d365-web-resources` | CLI reference not fetched |
| Power Platform Build Tools pipeline task names | `d365-alm` | Described at the shape level only, deliberately |
| Environment variables blocking import when unset | `d365-alm` | Referenced by the connection reference page but not documented there directly |

---

## Re-validating

Ask Claude, in a session with the Learn MCP server connected:

> Re-validate `claude/skills/<name>/SKILL.md` against the Microsoft Learn MCP server. For every
> API name, CLI flag and numeric limit, confirm it against current Learn content. Report anything
> that has changed, been deprecated, or that you cannot confirm — do not silently rewrite.

Worth doing when a skill gives advice that turns out wrong, after a major platform release, or
roughly every six months. Update the tables above with the new date when you do.

## Deliberately not used

[`DanielKerridge/claude-code-power-platform-skills`](https://github.com/DanielKerridge/claude-code-power-platform-skills)
covers overlapping ground (`dataverse-plugins`, `pcf-controls`, `dataverse-web-resources`). Read
as reference material, not installed: single-commit repo, no maintenance signal, and its content
was not verified against Learn. Nothing from it was copied into these skills.
