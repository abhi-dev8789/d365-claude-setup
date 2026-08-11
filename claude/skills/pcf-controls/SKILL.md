---
name: pcf-controls
description: Build, test and deploy Power Apps Component Framework (PCF) code components for model-driven and canvas apps — pac pcf init, field vs dataset vs React virtual control types, ControlManifest.Input.xml, the init/updateView/getOutputs/destroy lifecycle, context.parameters and context.webAPI, packaging into a solution, and pac pcf push. Use whenever the task involves a custom control, code component, or replacing a standard field or grid rendering with custom UI.
---

# Power Apps Component Framework (PCF)

Verified against Microsoft Learn — see `docs/sources.md`. Re-check API specifics against the
`microsoft-learn` MCP server; the framework's typings move faster than most of the platform.

## When PCF is the right answer

PCF replaces how a **column, dataset or canvas screen element renders**. Reach for it when the
standard control genuinely can't express the interaction — a slider instead of a number box, a
calendar or map instead of a grid.

Not the right answer for: form-level logic (use a web resource), server-side rules (plug-in),
or a whole page (use a generative page, code app, or canvas app).

Versus HTML web resources: code components render **in the same context and load with the rest
of the form**, rather than in an iframe. That's the practical difference — no iframe messaging,
no separate load, no layout fighting.

**Not supported on-premises.**

## Control types

| Type | Bound to | Use for |
|---|---|---|
| **Field** | A single column | Replacing one field's editor/display |
| **Dataset** | A view or subgrid | Replacing a list with a different visualisation |
| **React virtual** | Either | React components that share the host's React and Fluent instances |

React virtual controls avoid bundling their own React, which materially reduces bundle size and
improves load time when several components are on one form. Prefer them for React work — but
they constrain you to the platform's React/Fluent versions, so check compatibility before
committing.

## Scaffolding

```powershell
pac pcf init --namespace MyNamespace --name MyControl --template field
pac pcf init --namespace MyNamespace --name MyControl --template dataset
npm install
npm run build
npm start watch        # local harness, no environment needed
```

`npm start watch` is the fast loop — it renders the component in a local test harness with mock
data. Use it for anything that isn't specifically about real Dataverse data. Pushing to an
environment for every iteration wastes minutes each time.

## Lifecycle

```typescript
export class MyControl implements ComponentFramework.StandardControl<IInputs, IOutputs> {

    // Called once. Cache context, container, and the notifyOutputChanged callback.
    public init(
        context: ComponentFramework.Context<IInputs>,
        notifyOutputChanged: () => void,
        state: ComponentFramework.Dictionary,
        container: HTMLDivElement
    ): void { }

    // Called on every data or context change. Must be cheap and idempotent.
    public updateView(context: ComponentFramework.Context<IInputs>): void { }

    // Called after notifyOutputChanged(). Return values back to the platform.
    public getOutputs(): IOutputs { return {}; }

    // Called on removal. Detach listeners, cancel timers, free resources.
    public destroy(): void { }
}
```

The contract people break:

- **`updateView` runs often.** Rebuilding the DOM there instead of diffing produces flicker and
  poor performance. Treat it like a render function.
- **Writing a value is two steps:** store it locally, call `notifyOutputChanged()`, then return
  it from `getOutputs()`. Setting a field and expecting it to save without
  `notifyOutputChanged()` is the single most common PCF bug.
- **`destroy` must actually clean up.** The platform destroys and reloads components for
  performance. Leaked listeners accumulate across reloads.
- Components must tolerate being destroyed and re-created with preserved state.

## Manifest — `ControlManifest.Input.xml`

Declares properties, datasets, resources and feature usage. Key points:

- Property `of-type` determines what the component can bind to; getting it wrong means the
  component won't appear as an option for the intended column.
- `usage="bound"` vs `"input"` — bound reads and writes the column; input is configuration.
- `feature-usage` must declare `WebAPI`, `Device`, `Utility` etc. before you use them, or the
  call fails at runtime rather than at build.
- **Licensing:** a component that reaches an external service directly from the browser is
  **premium**, and makes any app using it premium. Declare it honestly:

  ```xml
  <external-service-usage enabled="true">
    <domain>api.example.com</domain>
  </external-service-usage>
  ```

  This is a licensing consequence for the client, not a formality — flag it to the user before
  building something that trips it.

Changing the manifest requires a rebuild; changing the **version** is what makes an updated
component actually take effect after a push.

## Data and platform access

```typescript
context.parameters.myProperty.raw          // current value
context.parameters.myDataset.records       // dataset rows
context.parameters.myDataset.paging        // paging - datasets are NOT fully loaded
context.webAPI.retrieveMultipleRecords(...)// Dataverse access
context.formatting                         // locale-correct number/date formatting
context.mode.isControlDisabled             // respect this
context.device                             // camera, location, microphone
```

- **Datasets are paged.** `records` holds the current page, not the whole view. Use
  `paging.loadNextPage()` / `hasNextPage`. Assuming you have everything is a bug that only shows
  up on large data.
- Use `context.formatting` rather than hand-rolled formatting — it respects the user's locale
  and the platform's column formatting.
- Honour `context.mode.isControlDisabled` and `isVisible`. A component that ignores read-only
  mode will happily let users edit records they have no privilege to change.
- `context.webAPI` requires `WebAPI` in `feature-usage`.

## Deploying

Fast path, unmanaged dev environment only:

```powershell
pac pcf push --publisher-prefix abc
```

Proper path, for anything that ships:

```powershell
pac solution init --publisher-name MyPublisher --publisher-prefix abc
pac solution add-reference --path ../MyControl
dotnet build -c Release
# then import the produced solution
```

Notes:

- `pac pcf push` creates a temporary solution. Convenient for iteration, not appropriate for
  release — use a real solution project so the component versions with everything else.
- **Bump the manifest version** before pushing an update, or the platform may serve the cached
  previous build and you'll debug a change that was never deployed.
- After import, the component must still be **added to the form/view** and the form published.
- Hard-refresh before concluding an update didn't work.

## Checklist before saying it works

- [ ] Version bumped in `ControlManifest.Input.xml`
- [ ] Built clean (`npm run build`) with no TypeScript errors
- [ ] Tested in `npm start watch` before pushing
- [ ] `feature-usage` declares everything used (WebAPI, Device, ...)
- [ ] `notifyOutputChanged()` called wherever a value is written
- [ ] `destroy()` removes listeners and timers
- [ ] Dataset paging handled, not just the first page
- [ ] Disabled/read-only mode respected
- [ ] Premium licensing implication checked and flagged if `external-service-usage` is set
- [ ] Component added to the form/view and published; verified with a hard refresh
