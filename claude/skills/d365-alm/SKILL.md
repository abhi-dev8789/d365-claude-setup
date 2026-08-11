---
name: d365-alm
description: Power Platform solution lifecycle and deployment — managed vs unmanaged solutions, publishers and prefixes, solution segmentation, connection references and environment variables, deployment settings files, pac solution export/pack/unpack/import/upgrade, source control of unpacked solutions, and CI/CD with Power Platform Build Tools for Azure DevOps or GitHub Actions. Use whenever the task involves moving solutions between environments, a solution import failing, connection or environment variable configuration, or setting up a deployment pipeline.
---

# Solution ALM and deployment

Verified against Microsoft Learn — see `docs/sources.md`. Re-check against the `microsoft-learn`
MCP server before relying on specifics.

This skill exists because the Dataverse and model-app plugins handle solution CRUD, but not the
part that actually breaks: **a solution that imports cleanly in dev and fails in test.**

## Ground rules

- **Never author into the Default solution.** It can't be exported cleanly and it makes
  everything downstream harder. Create a named solution with an explicit publisher prefix before
  writing anything.
- **The publisher prefix is effectively permanent.** Changing it later means recreating
  components. Agree it at project start.
- **Unmanaged in dev, managed everywhere else.** Importing unmanaged into test or production
  means those components can never be cleanly removed or upgraded.
- **One dev environment per solution stream** where practical. Shared dev environments produce
  exports containing other people's half-finished work.

## Managed vs unmanaged

| | Unmanaged | Managed |
|---|---|---|
| Edit in place | Yes | No (creates an unmanaged layer) |
| Clean uninstall | No | Yes |
| Where | Dev only | Test, UAT, Production |

**Unmanaged layers are the thing to watch.** Editing a managed component in a downstream
environment creates an unmanaged layer that shadows it — and future managed updates to that
component silently stop taking effect. When a deployed fix "doesn't apply" downstream, check for
unmanaged layers before anything else.

## Connection references — the usual cause of import failures

A **connection** is stored credentials. A **connection reference** is a solution component that
points at one. Solution-aware flows bind to the reference, not the connection, so the same flow
can use different credentials per environment.

What actually goes wrong:

- **Flows added to a solution keep using direct connections** until converted. They don't
  upgrade automatically. Either export unmanaged and reimport (which replaces connections with
  references), or use the flow checker's "Remove connections so connection references can be
  added" action.
- **`ConnectionAuthorizationFailed` on turning a flow on** means the activating user lacks
  permission to at least one connection. Either the connection owner activates the flow, or they
  share every connection with **Can use**. Once activated by the owner, co-owners can toggle it.
- **Custom connectors must be imported in a separate solution, before the connection references
  and flows that use them.** This ordering is not optional and is a very common pipeline failure.
- **Copying an environment breaks connection references for custom connectors** — the connector
  identifier is environment-specific. New references must be created against the new connector,
  and dependent apps and flows fixed.
- **Canvas apps only use connection references for implicitly shared (non-OAuth) connections.**
  They also don't recognise references on custom connectors — the app must be edited after import
  to remove and re-add the connection, which creates an unmanaged layer if it's managed.

## Environment variables

Use them for anything that differs per environment: URLs, IDs, tenant-specific settings, feature
switches. Never hard-code those into a flow or plug-in.

- A **definition** (with optional default) is the solution component; the **value** is
  environment-specific.
- A variable with no value and no default **blocks the import**. That's the mechanism working —
  supply values at import time rather than removing the variable.
- Secrets belong in Azure Key Vault–backed variables, not plain text values.

## Deployment settings file — automate the above

This is what turns a manual import into a repeatable one. Both connection references and
environment variables can be supplied at import time from a file:

```powershell
pac solution create-settings --solution-zip MySolution.zip --settings-file deploy-test.json
# edit deploy-test.json - fill in per-environment connection ids and variable values
pac solution import --path MySolution.zip --settings-file deploy-test.json
```

Keep one settings file per target environment in source control. **Values referencing client
environments are environment-specific configuration — check whether they belong in the repo or
in pipeline secrets before committing them.**

## Source control

Never commit the `.zip`. Unpack it:

```powershell
pac solution export --path ./out --name MySolution --managed false
pac solution unpack --zipfile ./out/MySolution.zip --folder ./src/MySolution --packagetype Unmanaged
```

Unpacked solutions diff meaningfully in review. Repack for deployment:

```powershell
pac solution pack --zipfile ./out/MySolution.zip --folder ./src/MySolution --packagetype Managed
```

Canvas apps inside solutions have their own unpack rules and hand-authoring limits — see the
Canvas gotchas in the global `CLAUDE.md` before editing unpacked canvas sources.

## Solution segmentation

Adding a whole table pulls in every column, form, view and relationship. Add **only the
components you changed** when extending a table you don't own — otherwise your solution claims
ownership of components another solution manages, and you get layering conflicts later.

Segment by concern: separate solutions for custom connectors (imported first), core schema,
plug-ins, and apps/flows. This costs a little more coordination and saves a great deal of
dependency pain.

## Pipelines

Power Platform Build Tools exist for both Azure DevOps and GitHub Actions. Typical shape:

1. **Export** unmanaged from dev
2. **Unpack** and commit to source control
3. **Build** — pack as managed
4. **Import** to test with `--settings-file deploy-test.json`
5. Gate, then repeat step 4 for production

Service principal authentication (`pac auth create --applicationId --clientSecret --tenant`) for
unattended runs — never a user account.

Power Platform **Pipelines** (the in-product feature) is the lower-ceremony alternative when a
full DevOps pipeline isn't warranted. Worth suggesting for smaller engagements.

## Diagnosing a failed import

In order:

1. **Read the import log.** Download it from the failure — it names the specific component. The
   portal's summary message rarely does.
2. **Missing dependency** → a required component lives in a solution not yet imported. Check
   ordering, and custom connectors first.
3. **Environment variable has no value** → supply it, via settings file or manually.
4. **Connection reference unresolved** → the target has no connection for that connector.
5. **Unmanaged layer** on the component being updated → remove the layer.
6. **Publisher mismatch** → the prefix differs from the target's existing solution. Not fixable
   by retrying.

## Checklist before saying a deployment succeeded

- [ ] `pac solution list` on the **target** shows the expected solution **and version**
- [ ] Managed/unmanaged flag is what you intended
- [ ] Import log reviewed — warnings read, not just the success line
- [ ] All environment variables have values in the target
- [ ] All connection references resolve to a real connection
- [ ] Flows are **turned on** (import doesn't always activate them)
- [ ] A functional check performed — open the app, run the flow, read a record back

`pac solution import` exiting 0 is not evidence of a working deployment. It is evidence that a
command returned.
