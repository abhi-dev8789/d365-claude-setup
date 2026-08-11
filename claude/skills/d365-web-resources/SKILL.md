---
name: d365-web-resources
description: Write and deploy Dynamics 365 / model-driven app client-side customisations — JavaScript form scripts using the modern Client API and formContext, form and field event handlers, ribbon/command bar customisations, HTML and CSS web resources, Xrm.WebApi calls, and pac webresource deployment. Use whenever the task involves JavaScript running on a model-driven app form, grid, or command bar. Also covers migrating legacy Xrm.Page code.
---

# Model-driven app web resources and Client API

Verified against Microsoft Learn — see `docs/sources.md` for URLs and dates. Re-check anything
load-bearing against the `microsoft-learn` MCP server.

## The one rule that matters most

**`Xrm.Page` is deprecated. Use `formContext`, obtained from the passed-in execution context.**

```javascript
// Deprecated - do not write new code like this
function displayName() {
    var firstName = Xrm.Page.getAttribute("firstname").getValue();
}

// Correct
function displayName(executionContext) {
    var formContext = executionContext.getFormContext();
    var firstName = formContext.getAttribute("firstname").getValue();
}
```

`Xrm.Page` still works for backward compatibility and Microsoft has committed to at least six
months' notice before removal — but it is on the deprecation list, and it cannot express the
thing that makes `formContext` worth using: **one handler that works on both a form and an
editable grid row**, because it operates on whatever context it was handed.

### The step that gets forgotten

In the Handler Properties dialog you must tick **"Pass execution context as first parameter."**
Without it, `executionContext` is `undefined` and the handler fails at the first line with an
error that does not mention the checkbox. If a handler is inexplicably broken, check this first.

### Context lifetime

Form contexts are **only valid during the event in which they're passed.** Do not stash a
`formContext` in a module-level variable and use it from a callback later — by then it may be
stale. Re-derive it, or capture the specific values you need synchronously.

## formContext object model

Two branches:

- **`formContext.data`** — the record
  - `data.entity` — record-level: `getId()`, `getEntityName()`, `save()`, `attributes`
  - `data.entity.attributes` — columns present **on the form** (not all table columns)
  - `data.process` — business process flow data
- **`formContext.ui`** — the interface
  - `ui.controls` — every control on the form
  - `ui.tabs` → `.sections` → `.controls`
  - `ui.formSelector.items` — forms available to this user
  - `ui.quickForms` — quick view controls
  - `ui.navigation.items`

Attribute vs control is the distinction people get wrong:

```javascript
formContext.getAttribute("name").setValue("x");         // the data
formContext.getControl("name").setVisible(false);       // the UI
formContext.getControl("name").setDisabled(true);       // the UI
```

One attribute can have several controls (same field on multiple tabs). `setVisible` on the
attribute doesn't exist; hiding means hiding each control.

### Only what's on the form

`data.entity.attributes` contains **only columns added to the form.** Reading a column that
isn't on the form returns null — it isn't loaded. Either add it (hidden if need be) or fetch it
with `Xrm.WebApi`.

## Data access

Use `Xrm.WebApi` — asynchronous, promise-based.

```javascript
Xrm.WebApi.retrieveRecord("account", accountId, "?$select=name,revenue").then(
    function (result) { /* ... */ },
    function (error)  { console.error(error.message); }
);
```

- `retrieveRecord`, `retrieveMultipleRecords`, `createRecord`, `updateRecord`, `deleteRecord`
- **Never use synchronous `XMLHttpRequest`.** It blocks the UI thread and is not supported.
- Always attach the error handler. A silently rejected promise is the most common cause of
  "the script just doesn't do anything."
- `$select` is not optional in practice — omitting it retrieves every column.

Navigation: use `Xrm.Navigation.navigateTo` for new work, not `Xrm.Utility.openEntityForm`.

## Ribbon / command bar

Command bar handlers get context differently from form handlers — you request it explicitly via
CRM parameters (`PrimaryControl`, `SelectedControl`) in the command definition, rather than
receiving an execution context. Pass `PrimaryControl` and treat it as the form context.

Modern commanding in the maker portal covers most cases. Ribbon Workbench (XrmToolBox) is still
the practical tool for anything the modern editor can't express — and for reading what an
existing legacy customisation actually does.

## Deployment

```powershell
pac webresource push --path ./scripts/account.js --solution-unique-name MySolution
```

Then **publish** — a pushed but unpublished web resource does not take effect, and this is a
frequent source of "I deployed it and nothing changed."

Caching is the second source. When a change doesn't appear:

1. Confirm the push succeeded
2. Confirm you published
3. Hard-refresh (Ctrl+F5)
4. Confirm you're looking at the right form and the handler is registered on it

Naming: use a publisher prefix and a folder-like path, e.g. `abc_/scripts/account/main.js`.
Flat unprefixed names become unmanageable as soon as there are more than a handful.

## Migrating legacy code

A mechanical conversion:

1. Add `executionContext` as the first parameter of every handler
2. `var formContext = executionContext.getFormContext();` at the top
3. Replace every `Xrm.Page.` with `formContext.`
4. Tick "Pass execution context as first parameter" on every registration
5. Replace `Xrm.Page.context` with `Xrm.Utility.getGlobalContext()`
6. Replace synchronous XHR / `Xrm.WebApi` legacy calls with the promise-based API and add error
   handlers

Step 4 is the one that breaks silently at runtime, so verify each handler registration rather
than assuming.

## Checklist before saying it works

- [ ] Web resource pushed **and published**
- [ ] Handler registered on the correct form and event
- [ ] "Pass execution context as first parameter" ticked
- [ ] Every column read is actually on the form, or fetched via `Xrm.WebApi`
- [ ] Every promise has an error handler
- [ ] Tested with a hard refresh, not a cached page
- [ ] No `Xrm.Page`, no synchronous XHR
