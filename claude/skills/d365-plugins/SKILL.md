---
name: d365-plugins
description: Write, register, debug and troubleshoot Dataverse / Dynamics 365 server-side code — IPlugin and PluginBase classes, the event execution pipeline (PreValidation / PreOperation / PostOperation), plug-in registration via pac plugin or the Plug-in Registration Tool, Custom APIs and Custom Process Actions, ITracingService and reading PluginTraceLog, InvalidPluginExecutionException, infinite-loop and depth problems, and custom workflow activities. Use whenever the task involves C# code that runs inside Dataverse.
---

# Dataverse plug-ins and server-side code

Verified against Microsoft Learn — see `docs/sources.md` in the config repo for URLs and dates.
Platform APIs change; **re-check anything load-bearing against the `microsoft-learn` MCP server**
rather than trusting this file indefinitely.

## Before writing a plug-in at all

Microsoft's own guidance is to reach for declarative options first. Check in this order:

1. Calculated / rollup columns
2. Business rules
3. Power Automate flow (solution-aware)
4. **Plug-in** — when the above genuinely don't fit

Plug-ins win on performance and power, and lose on maintainability and blast radius. A plug-in
that could have been a business rule is a liability. Say so if you spot one.

## The IPlugin contract

Target **.NET Framework** (not .NET/Core). Reference the NuGet packages, never the legacy CRM
SDK download.

```csharp
public class MyPlugin : IPlugin
{
    public void Execute(IServiceProvider serviceProvider)
    {
        IPluginExecutionContext context = (IPluginExecutionContext)
            serviceProvider.GetService(typeof(IPluginExecutionContext));

        IOrganizationServiceFactory serviceFactory = (IOrganizationServiceFactory)
            serviceProvider.GetService(typeof(IOrganizationServiceFactory));
        IOrganizationService orgService = serviceFactory.CreateOrganizationService(context.UserId);

        ITracingService tracingService = (ITracingService)
            serviceProvider.GetService(typeof(ITracingService));

        try
        {
            // logic here
        }
        catch (FaultException<OrganizationServiceFault> ex)
        {
            throw new InvalidPluginExecutionException("The following error occurred in MyPlugin.", ex);
        }
        catch (Exception ex)
        {
            tracingService.Trace("MyPlugin: error: {0}", ex.ToString());
            throw;
        }
    }
}
```

### Statelessness is not optional

**The platform caches the class instance and reuses it across invocations.** Never store a
service reference or context data in a field or property — it will leak between executions,
across users, in ways that are intermittent and horrible to debug.

Constants and helper methods called from `Execute` are fine. Anything per-invocation is not.

### Constructor signatures

Only these three are recognised, for passing registration-time configuration:

```csharp
public MyPlugin() {}
public MyPlugin(string unsecure) {}
public MyPlugin(string unsecure, string secure) {}
```

`secure` is stored in a separate table readable only by system administrators. Use it for
anything sensitive; use `unsecure` for behaviour switches.

### PluginBase

`pac plugin init` and Power Platform Tools for Visual Studio generate a `PluginBase.cs` that
implements `IPlugin` and pre-wires the services into an `ILocalPluginContext`. It's optional
but recommended.

**The two generators produce slightly different member signatures.** Pick one and stay with it
across a project — mixing them produces confusing near-duplicates.

```csharp
public class MyPlugin : PluginBase
{
    public MyPlugin(string unsecureConfiguration, string secureConfiguration)
        : base(typeof(MyPlugin)) { }

    protected override void ExecuteDataversePlugin(ILocalPluginContext localPluginContext)
    {
        if (localPluginContext == null) throw new ArgumentNullException(nameof(localPluginContext));

        var context = localPluginContext.PluginExecutionContext;
        var service = localPluginContext.OrgSvcFactory.CreateOrganizationService(context.UserId);
        var trace   = localPluginContext.TracingService;
        // ...
    }
}
```

## The event pipeline

| Stage | Transaction | Use it for |
|---|---|---|
| **PreValidation** | Outside (for the initial operation) | Cancelling the operation cheaply. **Runs before security checks.** |
| **PreOperation** | Inside | Changing values on the record being written. |
| **MainOperation** | Inside | Internal only — except Custom APIs and virtual table data providers. |
| **PostOperation** | Inside (sync) / outside (async) | Reading the committed result, triggering downstream work. |

Registration values are commonly 10 / 20 / 30 / 40 respectively — confirm against Learn if you
are writing them programmatically rather than picking them in a tool.

Rules that follow from the table:

- **Cancel in PreValidation, not PreOperation.** Throwing in PreOperation rolls back a
  transaction that has already started — correct, but expensive.
- **Modify the Target in PreOperation.** Modifying it in PostOperation triggers a *new* Update
  event, which is the classic accidental-recursion bug.
- **Any exception at a synchronous in-transaction stage rolls the whole transaction back.**
  Handle what you can; throw `InvalidPluginExecutionException` with a message the user can
  actually act on, because that message surfaces in the UI.
- Multiple steps on the same message and stage run in **Execution Order** sequence.
- Register asynchronous steps on PostOperation when the work doesn't need to block the user.
  Async is required when updating on the `Create` of `SystemUser`.

### Depth and recursion

`context.Depth` increments each time a plug-in triggers an operation that triggers another
plug-in. The platform aborts beyond a threshold, but relying on that produces a nasty error
rather than correct behaviour. Guard explicitly:

```csharp
if (context.Depth > 1) return;
```

Better still, don't write back to the record you were triggered on — use PreOperation and
modify the `Target` in place, which costs no extra operation at all.

### Time limits

Synchronous plug-ins have a hard execution time limit (documented at 2 minutes at time of
writing — **verify via Learn MCP before relying on the exact figure**). Long work belongs in an
async step or a flow. A synchronous plug-in calling an external service is a latency bomb.

## Data access rules inside a plug-in

- **Use the Organization service (`IOrganizationService`), not the Web API.** The Web API is
  not supported in plug-ins.
- **Do not authenticate.** The user is pre-authenticated before the plug-in runs.
- `CreateOrganizationService(context.UserId)` runs as the calling user (respects their
  privileges). `CreateOrganizationService(null)` runs as the system user — use deliberately, and
  say so in a comment, because it silently bypasses security.
- Early-bound types work for *reading*:
  ```csharp
  Account acct = context.InputParameters["Target"].ToEntity<Account>();
  ```
  But **never assign an early-bound type into `InputParameters`** — that throws
  `SerializationException` at runtime.

## Custom APIs (prefer over custom workflow activities)

A Custom API defines a new named message with typed request/response parameters, callable from
the Web API, the Organization service, flows and JavaScript. It's the modern replacement for
custom actions and unbound workflow activities.

- Implement as a plug-in registered on the **MainOperation** stage of the custom message.
- Define request/response parameters as solution components so they travel with the solution.
- `IsFunction` / `IsPrivate` / `AllowedCustomProcessingStepType` control how it can be called
  and whether others can extend it.
- Prefer this over `CodeActivity` custom workflow activities for anything new.

## Registration

```powershell
pac plugin init                  # scaffold a project (generates PluginBase.cs)
pac tool prt                     # launch the Plug-in Registration Tool
dotnet build
```

- The assembly must be **signed** (strong name).
- Merge dependencies with ILMerge/ILRepack, or the assembly will fail to load — Dataverse does
  not resolve external references at runtime. Fewer dependencies is the better answer.
- Registering a step needs: message, primary table, stage, execution mode, filtering attributes,
  and (for Update) the images you need.
- **Set filtering attributes.** A plug-in on Update with no attribute filter fires on every
  column change and is a common cause of unexplained load.
- Pre/Post images give you the record state either side of the operation — cheaper and more
  reliable than a `Retrieve` inside the plug-in.

## Debugging

Trace logging must be **enabled in the environment** before anything is written:
Settings → Administration → System Settings → Customization → Plug-in and custom workflow
activity tracing.

```csharp
tracingService.Trace("Retrieved {0} records for {1}", results.Entities.Count, accountId);
```

Then read the **PluginTraceLog** table. Trace generously — a plug-in fails in production with
no debugger attached, and traces are the only evidence you'll get.

For local debugging, the Plug-in Registration Tool's profiler captures a real execution context
and replays it in Visual Studio. Faster than deploy-and-pray.

### Reading a failure

Dataverse errors are verbose and the useful part is rarely the first line. Look for the inner
exception and the plug-in trace text. `InvalidPluginExecutionException` messages surface to the
user; everything else surfaces as a generic platform error with the detail buried in the log.

## Checklist before saying it works

- [ ] Assembly built and **actually pushed** — confirm the version in the environment
- [ ] Step registered on the right message, table, stage and mode
- [ ] Filtering attributes set
- [ ] Trace logging enabled, and a trace confirms the plug-in ran
- [ ] Behaviour verified by reading data back, not by the deploy command exiting 0
- [ ] Recursion checked — trigger the operation twice and confirm depth guarding holds
