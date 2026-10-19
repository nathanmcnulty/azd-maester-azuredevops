# Reviewed setup and federation consent

Maester 2.3.0 is pinned by package version and SHA-256. Shared hooks 2.1.0 and
delegated-session coordinator 1.1.0 are vendored from reviewed
[Reference #134](https://github.com/nathanmcnulty/azd-reference/pull/134), exact
revision `552ade2f0267e6872bd681f9a1d8a67ac72d055b`, with per-file lock hashes. The interactive question
“Grant the permissions needed for the full assessment? [Y/n]” maps Yes/Enter to
**Full (27 read roles)** and No to **Minimal (8)**. Extended remains the legacy
19-role set. Selecting a profile does not grant permissions. Neither Full nor
Minimal promises complete app-only, license, workload or test coverage.

`INCLUDE_MAIL_SEND` and `INCLUDE_REPORT_SETTINGS_WRITE` are independent,
default-off capabilities. A mail recipient alone grants and sends nothing.
Existing grants are retained, even after selecting a smaller profile. Existing
report-setting write access blocks runtime assessment unless explicitly enabled;
see [runtime qualification](runtime-maester-230.md) for tenant-wide concealment
changes, restoration verification and coverage limits.

## Administrator prerequisite: setup public client

An administrator must separately create and consent a tenant-owned, single-tenant
public-client application for interactive delegated setup. Configure its exact
client ID as `MAESTER_SETUP_CLIENT_ID` and the operator's exact sign-in account
as `MAESTER_SETUP_ACCOUNT`. Configure the **Mobile and desktop applications**
public-client redirect exactly as `http://localhost`, as required by canonical
setup-client verification. Require assignment on the enterprise application and
assign only designated setup administrators or groups. Do not enable additional
authentication flows to work around a failed normal browser or broker login.
Follow the [pinned canonical administrator bootstrap instructions](https://github.com/nathanmcnulty/azd-reference/blob/552ade2f0267e6872bd681f9a1d8a67ac72d055b/docs/maester-consent-flow.md#one-time-authorized-administrator-bootstrap).
Setup never creates its own privileged setup client or consents itself, and
rejects built-in shared clients and runtime/setup identity reuse. The runtime app
is a separate federated Application service principal.

The canonical delegated-session coordinator requires the exact selected tenant,
client, account and complete selected scope union before any inventory or writes:

- Core: Application.Read.All, AppRoleAssignment.ReadWrite.All, Directory.Read.All
- Selected runtime-application bootstrap: additionally Application.ReadWrite.All
- Selected Teams: additionally RoleManagement.ReadWrite.Directory
- Selected Easy Auth: additionally Application.ReadWrite.All,
  DelegatedPermissionGrant.ReadWrite.All and Group.Read.All

Bootstrap requests this full union upfront, including the later selected access
features. Keep `MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP=true` for every pass in
a fresh-bootstrap workflow, or pass `-IncludeRuntimeApplicationBootstrap` on
subsequent access passes. An existing fully prepared runtime can omit bootstrap
scope unless Easy Auth needs it. No retries add scopes or reconnect at a write
boundary. An interactive browser login is separately opt-in with
`-AllowInteractiveGraphLogin`; replacing an unrelated session also requires
`-AllowGraphContextReplacement`. Start in a fresh `pwsh -NoProfile` process.
Maester requires `ContextScope Process` and refuses an inherited non-Process
context even when replacement is approved. The coordinator does not call
Disconnect or delete cached authentication. However, Microsoft Graph SDK 2.41
still touches its shared `~/.mg` authentication record and may remove that record
on an authentication failure; Process is not a complete filesystem-isolation
promise. The coordinator requests browser authentication, not device code, but
the SDK can internally fall back to device code. Stop an unexpected device-code
prompt and review the shared-record effect with the operator before sign-in.

Directory.Read.All covers direct directory-role-assignment inventory according
to the [official unifiedRoleAssignments permission table](https://learn.microsoft.com/graph/api/rbacapplication-list-roleassignments?view=graph-rest-1.0).
The operator also needs a supported directory role and appropriate Azure/ADO,
Exchange and workload authority for the selected operations. These delegated
setup scopes are never assigned to the runtime application.

## Phase 1: bootstrap exact runtime identities

Provision the Azure infrastructure in the selected azd environment. The normal
postprovision setup is plan-only and stops if runtime bootstrap is incomplete.
No broad identity discovery or first-match adoption substitutes for exact targets.
Use an organization name such as `contoso`, not a URL.

Run `./scripts/Setup-PostDeploy.ps1 -Bootstrap` with the selected environment,
tenant, subscription and configured ADO organization/project/repository/endpoint.
It prints a read-only `AzureDevOpsRuntimeBootstrap` plan and hash. Review every
requested object, existing identity, credential and consequence. To apply just
that plan, rerun with `-ApplyBootstrap -ApprovedBootstrapPlanHash <hash>`.

Fresh environments normally require multiple bootstrap reviews:

1. Create the selected missing repository, draft federated endpoint and
   single-tenant runtime application. No service-principal or FIC placeholders
   authorize additional work.
2. Review the resolved app and create its exact tenant-owned service principal.
3. Review the resolved endpoint, tenant-owned app/SP, exact federation issuer,
   subject and sole `api://AzureADTokenExchange` audience. Approve creation of
   that trust and finalization of the same endpoint to the same app and exact
   resource-group scope.

Each apply regenerates all inventories and compares the current hash before the
first write, executes only that stage's listed operations, verifies returned
identifiers against fresh inventories, and stops. A newly resolved FIC is never
covered by an earlier unknown-output plan. Repeating a completed stage is a no-op.
Partial failures remain visible; retry by reviewing a fresh plan.

Existing credentials and federations are preserved and hashed, with existing
application permissions and direct directory roles shown. Any new trust can use
all existing app privileges. Inherited/group-based access, broader Azure RBAC
and workload-specific RBAC are explicitly not proven by this bootstrap inventory.
Review those externally before adding trust. Missing, unreadable, ambiguous or
paginated inventories fail closed. The setup application cannot be the runtime.

The host reads the selected organization's `ConnectionData.instanceId` before
trust planning. The [documented legacy issuer/subject](https://learn.microsoft.com/en-us/azure/devops/pipelines/release/troubleshoot-workload-identity?view=azure-devops)
must match that organization ID and the exact organization/project/endpoint
names. Microsoft Entra-issued endpoints must use the selected tenant's `/v2.0`
issuer and exact organization/endpoint-ID subject suffix. The opaque Entra prefix
is copied from the selected endpoint and hashed, never invented or rewritten.
Changing between issuer formats is not an automatic migration.

The older ADOPS finalize call dropped `authorization.parameters.scope`.
Existing endpoints missing the exact resource-group scope require a reviewed
bootstrap binding update. Setup never silently rebinds an endpoint to a different
client, tenant, project or subscription, and never changes the runtime to a
managed identity. Host scope metadata is an additional guard; Azure RBAC remains
the enforcement boundary.

## Phase 2: aggregate access plan, then application

Run `./scripts/Setup-PostDeploy.ps1` without apply flags. It verifies direct Azure
deployment outputs/ownership and exact ADO project, repository, endpoint,
Application SP, FIC, pipeline definition and branch. The plan includes:

- Current/desired/missing Graph application roles and optional capabilities
- Runtime Azure Reader, Storage Blob Data Contributor and optional Website
  Contributor, plus operator Storage Blob Data Reader
- Selected Exchange, Teams and Azure Reader grants
- Selected Easy Auth application, exact security group, delegated consent delta
  and auth settings
- ADO endpoint/repository pipeline authorization. This preserves the existing
  template's project-wide `allPipelines` behavior; a new grant explicitly exposes
  the endpoint/repository to every pipeline in that exact project
- Exact rendered pipeline/runtime file hashes, repository, YAML path, branch,
  schedule, current branch object ID, pipeline definition revision and requested
  validation run. Publication, missing-definition creation and queuing each
  require approval even when every access grant already exists

No Graph/ARM/ADO write, environment receipt, file push or pipeline run happens
in plan-only mode. Apply using `-Apply -ApprovedPlanHash <hash>`. An interactive
operator may instead use `-InteractiveConsent`; permission expansion defaults
to **No**. Capability selection is never consent approval. The entire plan is
rebuilt and checked before the first write. Source, branch, identity, existing
permission, target or optional-feature changes invalidate the approval.

Only a verified current branch is used for a push; a concurrent change requires
a new plan. Nonempty existing repositories must already have the selected
branch. Existing pipelines must match the selected repo/YAML/default branch.
The exact definition ID, revision and targets are checked again before reuse and
at validation dispatch. The run API is called by exact ID and `pipelineVersion`,
with the reviewed or newly published immutable repository commit, rather than a
second name lookup. The emitted UTF-8 file bytes match the reviewed hashes; staged Git blobs are
checked against raw files, and line-ending/filter transformations fail closed.
A failed automatic push retains the existing manual-file
fallback and blocks validation until a fresh review after manual publication. Existing
private project/build artifacts and approved drift isolation remain unchanged.

Azure setup dependencies (Az.Accounts and ADOPS, plus selected Exchange support)
must already be installed; planning never prompts to install them. Setup retains
previous role receipts on idempotent reruns. Canonical Graph assignments and
ADO pipeline authorization have readback checks; ARM RBAC, Exchange, Teams and
Easy Auth operation receipts establish accepted write responses, not independently
verified effective access or propagation. Their `configured` status must not be
read as a live workload acceptance result. Only repositories created by this
environment are marked eligible for teardown. No live login, grant, application,
service connection, pipeline, deployment or mail operation was used to qualify
this source adoption; those remain explicit operator acceptance gates.
