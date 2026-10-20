# Setup ownership and interrupted operations

Setup now keeps a versioned ownership journal in the selected local azd environment. A complete lifecycle holds an exclusive journal session while it verifies targets, performs approved writes, and reads results back. Plan-only inspection does not create ownership records.

The journal binds the environment, tenant, subscription, resource group, setup client and exact Azure DevOps organization/project. Runtime objects are added by their returned IDs as each bootstrap stage completes. The separately configured setup client is protected; selecting an existing runtime application, repository, endpoint or pipeline does not make that object deployment-owned.

## What gets recorded

- New repositories, service connections, runtime and Easy Auth applications/service principals, federated credentials and pipelines
- Individual new Graph, Exchange, Teams and Azure role assignments, including grants on adopted principals
- Exact per-pipeline authorization changes, with preserved individual grants,
  and endpoint binding changes
- Sanitized Easy Auth configuration and delegated-consent scope changes
- Publication repository/branch, reviewed paths, and before/after commit IDs
- New application creation baselines: redirect and identifier URIs, group claims, implicit-token flags and sign-in audience

Every approved remote write gets a durable pending record first. Exact response IDs are checkpointed before another write or readback. A later error does not erase earlier successful receipts. No-change runs preserve prior records and do not turn reused objects into owned ones.

Setup also validates acknowledged Graph, Teams, Azure and Exchange assignment tuples after checkpointing their IDs. Delegated-consent and application/Web App configuration mutations require exact-target readback. Contradictory or unreadable results become conflicts and stop before later Azure DevOps authorization, publication or pipeline actions.

Application creation baselines come from the approved request and explicit creation defaults. Setup checks the acknowledged response and exact-ID readback against that baseline; a contradiction becomes a conflict rather than silently adopting the changed configuration. Teardown compares the retained baseline and any reviewed, parent-covered configuration changes before removing the application.

A provider may accept a request even when its response is lost. Such an operation remains pending; setup refuses further application until the exact outcome is reconciled. Names, naming conventions, and ordinary azd configuration IDs are never substitutes for ownership evidence. Do not delete the journal to bypass an unresolved operation.

## Reused resources

Individual new grants and federated credentials on a reused application are recorded separately from the application itself. Mutations covered by a previously recorded owned parent are linked to that parent.

Successfully acknowledged changes to shared or adopted objects are recorded as applied mutations with sanitized before/after metadata and no owned-parent link. This records a known successful write, but it does not authorize restoration or parent deletion: automatic down is blocked by the unsupported shared-restoration guard. In particular, publishing into an adopted repository does not authorize deleting that repository or rewriting its history. Such publication retains its exact commit/path evidence and requires deliberate reconciliation. The journal does not silently restore permissions, app configuration, or source over concurrent changes.

Publication into a deployment-owned repository supports one narrow successor chain: each approved update names its exact applied predecessor and previous commit, records the new commit before push, and retains all earlier receipts. A no-op does not add a receipt. Branched histories, changed source commits, cross-target links and unresolved writes block another update. Teardown checks the terminal publication commit for each owned branch. Other repeated shared mutations still require reconciliation; there is no general receipt-generation or restoration mechanism. Actual mismatched outcomes are conflicts and stop the current invocation immediately. Pending, deleting or conflict records block subsequent apply calls, including otherwise no-op applies; plan-only inspection remains available. Successfully acknowledged shared changes permit the rest of the approved setup and no-op reruns, retaining the existing evidence and the teardown blocker. Follow-up work should define reviewed generation transitions without overwriting earlier ownership or before/after receipts.

The journal is local and unsigned. It guards against accidental target confusion and interrupted writes; it is not proof against an attacker who can rewrite the checkout or its environment files. Keep the environment and journal together for teardown and review.

Successful full down retains the ownership receipts. Reprovisioning the same environment is intentionally blocked until a supported reset/reconciliation workflow exists; do not remove the receipts to bypass that protection. A new environment is the supported initial provision/setup/down roundtrip.

## Interactive down and recovery

Run `azd down` in an interactive terminal and omit `--no-prompt`. Hooks 3.1.1 checks actual prompt availability before owned lock removal when external cleanup records remain; it does not promise a shell-hook environment signal for `--no-prompt`. `-PlanOnly` stays read-only. If Azure is removed before cleanup is declined or blocked, receipts remain. Recover using `./scripts/Run-AzdPostDown.ps1 -EnvironmentName <original-environment> -TenantId <original-tenant> -SubscriptionId <original-subscription> -InteractiveConsent` in an interactive terminal. It can select a fresh normal-browser login if needed, then separately asks approval for the fresh cleanup plan. A deliberate noninteractive retry needs an already verified Graph `Process` context and fresh exact `-ApprovedPlanHash` in the same PowerShell process; azd does not transfer the parent shell's context, and the reviewed scope union is unchanged.

## Offline coverage and live boundary

Stateful tests execute the production planners, application functions, setup caller, publication helper, and actual predown/postdown wrapper files with provider boundaries replaced by fixtures. They exercise partial creation, failed readback, exact ID persistence, new grants on reused parents, no-op preservation, ambiguous publication, lifecycle-lock release, owned-object removal, adopted-object preservation, changed-source/dependency refusal and partial-cleanup retry. They never authenticate or contact Azure, Graph, Exchange or Azure DevOps.

Those tests establish the local ownership algorithm and actual hook control flow with simulated before/after provider state. They do not execute the native `azd down` command or establish provider propagation, native pipeline execution or final live before/after state. A separately authorized lifecycle qualification is still required for those claims.

## Dedicated-object boundary

Deployment-owned applications, identities and Azure DevOps objects must remain dedicated throughout their lifetime. Do not repurpose, share or concurrently edit them. Cleanup checks the reviewed configuration fields and dependencies; it does not inventory every possible application property or downstream reference and cannot guarantee detection of arbitrary later reuse. The separately administered setup client remains outside this ownership boundary.

The fresh pipeline-preparation stage records publication and the returned exact
pipeline ID before the separate access plan is approved. Owned endpoint and
repository cleanup checks their authorized pipeline IDs against owned pipeline
receipts. Unrelated pipelines elsewhere in the project do not become dependents
merely because they share the project; an unrecorded pipeline actually authorized
to an owned endpoint/repository still blocks cleanup. Narrow authorization on an
adopted parent does not remove the shared-restoration limit described above.
