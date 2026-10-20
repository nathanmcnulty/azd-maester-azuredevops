# azd-maester-azuredevops

Deploys a production-style Maester monitoring solution using Azure DevOps Pipelines with:

- Azure DevOps Azure Repos Git repository + YAML pipeline
- Azure DevOps Azure Resource Manager service connection using workload identity federation (no secrets/certificates)
- Entra workload identity app + federated credential automation
- Federated application permissions (Graph app roles + optional Exchange/Teams/Azure)
- Storage-backed report history (`archive`) and latest pointer (`latest/latest.html`)
- Optional App Service + Easy Auth portal in WebApp mode

Local setup and pipeline execution require **PowerShell 7.6 or newer**. See
[development validation](docs/development.md) for the matching Pester baseline
and the pipeline agent requirement.

## Quickstart (existing Azure DevOps project)

After `azd init -t nathanmcnulty/azd-maester-azuredevops`, run from the template root:

`azd up`

Before setup, an administrator must prepare the dedicated setup public client.
Postprovision is read-only by default. Fresh runtime identity creation uses
separately reviewed bootstrap stages, followed by an approved unrun-pipeline
preparation stage. Access changes then require a fresh aggregate plan hash
bound to that exact pipeline ID. Follow [setup and consent](docs/setup-consent.md) for the complete
scope union, bootstrap and apply commands. Existing runtime identities keep
workload federation and do not receive permission-management authority.

## Versioning and shared components

This template uses the stable Maester module `2.3.0`. Shared azd hooks,
permission setup, and the optional report web app are vendored from
`nathanmcnulty/azd-reference` and recorded in `azd-components.lock.json`.

The original multi-variant catalog remains available at
[`nathanmcnulty/azd-maester`](https://github.com/nathanmcnulty/azd-maester) while
the migration is being completed.

During interactive `azd up`, the preprovision wizard prompts for:

- Include Web App / Exchange / Teams / Azure
- Security group object ID (required when Web App is enabled)
- Azure RBAC scopes (when Azure is enabled)
- Azure DevOps organization/project (required)
- Full assessment [Y/n], with separate default-off mail and report-write choices
- Dedicated setup client/account and optional mail recipient

For fresh environments, `preprovision` creates the selected absent dedicated resource group and records its exact creation outcome. Existing groups are never silently adopted for cleanup.

## What setup does

- Provisions Azure resources after direct selected-tenant/subscription guards
- Prints read-only bootstrap or access plans before setup writes
- Preserves federated runtime identity and exact repository/endpoint ownership
- Separately approves runtime app/SP creation, resolved FIC trust and endpoint binding
- Separately approves Full27, Minimal8 or explicit legacy Extended19 Graph reads
- Keeps mail, report-setting writes, Exchange, Teams, Azure and Easy Auth optional
- Revalidates the aggregate delta and rendered source hashes before applying
- Activates the chosen schedule only after separately approved exact-pipeline
  access; explicit validation runs are default-off
- Separately prepares reviewed runtime files and an exact unrun pipeline
- Authorizes only that pipeline to use its endpoint and repository; project-wide
  pipeline access is rejected
- Preserves existing private reports and default-off isolated approved drift

Existing repositories are preserved by teardown; only repositories created by
this environment are marked for removal. Read [the staged setup workflow](docs/setup-consent.md)
and [Maester 2.3.0 runtime evidence](docs/runtime-maester-230.md) before applying.

## Permission lifecycle

- Toggling an option from `Yes` to `No` in a later `azd up` run is additive only and does **not** revoke prior assignments.
- `azd down` checks ownership first and removes only exactly receipted external objects after Azure absence and a fresh cleanup approval.

## Authority boundaries

Some environments already have the required Microsoft Graph permissions consented and assigned. If Graph consent has not been completed previously, the deployment may require a **Global Administrator or Privileged Role Administrator**. See the selected profile and permission sections for solution-specific details. Optional Exchange, Teams, Azure, and Easy Auth setup has its own prerequisites, so a successful repository or service-connection setup is not proof that the monitoring workload is ready.

The Azure DevOps identity used for setup must have Code access in the organization (for example, a Basic access level or a Visual Studio subscription) and `Create repository` permission in the target project. Stakeholder access cannot create or use the Azure Repos repository required by this template. The hooks use the selected Azure CLI token first and retain Azure PowerShell token acquisition as a fallback.

## Operations

- Provision/update:
  - `azd up -e <env>`
- Remove environment + Azure resources + Azure DevOps artifacts (with separate owned-lock and postdown cleanup approvals):
  - `azd down -e <env>`
- Only after complete cleanup and preserving recovery evidence, optionally remove local azd env files:
  - `azd env remove <env> --force`

### Teardown behavior

`azd down` validates the fresh dedicated resource group's ownership and exact declared inventory. Foreign resources or locks block teardown. Exact owned locks require a separate default-No confirmation; canceling azd afterward leaves those approved locks removed but resources and authorization unchanged.

After Azure deletion, `scripts/Run-AzdPostDown.ps1` proves the bound group/runtime absent, previews the remaining exact external objects, and requires a new default-No confirmation or current plan hash before deletion. Unknown outcomes, foreign dependencies and unsupported restoration of shared changes block cleanup and retain the journal for retry. A generic `--force` does not approve either hook's plan.

Preserve both `.azure/<env>/maester-*-ownership.json` receipts until cleanup is verified. The separately administrator-created setup client and access group remain external prerequisites. Deleting owned accounts removes their stored contents; owned ADO definition deletion also removes associated builds/history/artifacts. See [ownership and recovery limits](docs/ownership-lifecycle.md) before teardown. Live before/after acceptance is still required.

## Notes

- For a manual postprovision retry, select the same azd environment after a successful provision. Setup binds the exact `STORAGE_ACCOUNT_NAME`, `WEB_APP_NAME`, and `WEB_APP_ENABLED` deployment outputs and writes receipts back to that named environment. A false enablement output skips Web App setup even when other sites exist; missing or mismatched targets stop setup before Azure DevOps, Graph, or role changes.
- This solution intentionally avoids secrets and certificates.
- If automatic repository push fails, setup writes manual files to `outputs/<env>-pipeline-files`.
- Setup summary is written to `outputs/<env>-setup-summary.md`.

## Script map

- azd hooks: `scripts/Run-AzdPreUp.ps1`, `scripts/Run-AzdPreProvision.ps1`, `scripts/Run-AzdPostProvision.ps1`, `scripts/Run-AzdPreDown.ps1`, `scripts/Run-AzdPostDown.ps1`
- Core provisioning: `scripts/Setup-PostDeploy.ps1`
- Pipeline runtime script (committed to Azure Repos): `scripts/Invoke-MaesterAzureDevOpsRun.ps1`
- Pipeline validation: `scripts/Invoke-PipelineValidation.ps1`

## Reference docs

- Maester Azure DevOps guide: https://maester.dev/docs/monitoring/azure-devops
- Azure DevOps pipeline schedule syntax: https://learn.microsoft.com/azure/devops/pipelines/process/scheduled-triggers
- Azure Developer CLI hooks: https://learn.microsoft.com/azure/developer/azure-developer-cli/azd-extensibility

Configuration drift remains disabled: the runner isolates inherited drift input
from the ordinary assessment. See [drift isolation and remaining gates](docs/drift-isolation.md)
(MADO-011 and MADO-012).
