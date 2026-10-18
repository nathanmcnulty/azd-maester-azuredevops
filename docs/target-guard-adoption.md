# Canonical target guard adoption

This source adoption addresses #27 on top of approved-drift PR #26 at
`4ea91e976742f178b74a6eccb54b81d428b56151`. PR #24's post-authentication Az context
verification is already inherited through #25 and #26. It remains in place,
including CLI management-token refresh, matching cached-context reuse, and the
selected-target interactive fallback after successful fresh ARM validation. A
failed metadata read now stops even if an Az context is cached; that context
cannot attest current subscription state. No earlier branch is restored or rewritten.

## Provenance and target selection

The eight `maester-azd-hooks` files are vendored byte-for-byte from Reference #111,
`fd26f7351f36c569067ae37edcb35d6b6cc40f29`, component version **1.0.0**, status
**pilot**. `azd-components.lock.json` records that immutable revision and exact
SHA-256 hashes. No reference checkout is needed at runtime.

`Run-AzdPreUp.ps1` executes the canonical guard before resource-group lookup or
creation. Setup validates configured subscription and expected tenant against
fresh ARM metadata before authentication refresh, deployment discovery, or
permission/resource writes. Both Setup and pipeline validation require an
explicit expected tenant (direct `-TenantId`, `AZURE_TENANT_ID`, or Setup's selected
azd environment). Missing expected context fails closed; setup no longer infers
the intended tenant from an existing Az default.

`Invoke-PipelineValidation.ps1` validates the selected subscription's current
Enabled state and tenant, uses canonical explicit-target token acquisition, and
checks the Az context before its fallback token acquisition. An unrelated global
CLI/Az default is not used to select the pipeline target. No CLI default is changed.
Setup passes the validated tenant to the actual Exchange helper, whose Outlook
token request carries that tenant and rejects a mismatched response.

## Preserved boundaries

- No permission requirements or role definitions are added; only affected evidence
  hashes change.
- PR #26's private output workspace guard, default-off approved-drift inputs,
  generated pipeline file list, and report contracts are unchanged.
- Failed pipeline execution remains distinct from recognized Maester findings.
- Existing resource/tag/ownership and cleanup safeguards remain unchanged.

## Verification scope

Offline Pester tests exercise the actual preup wrapper and full pipeline validator
with command stubs, full Setup rejection paths, the unchanged Setup
guard/authentication region through its
first deployment lookup, and the actual Setup Exchange call through the canonical
token helper. They cover wrong targets, missing identity/state, stale cached
Enabled versus fresh Disabled, failed metadata reads, missing configured context,
explicit splatted token selectors, and positive selected-target execution with an
unrelated Az default. Unexpected CLI/HTTP operations are tripwires. These tests do
not execute Setup's downstream permission writes.

The registered suite also checks component and permission-evidence hashes and
retains all drift isolation, private-output, file-inclusion and report tests.
Run with PowerShell 7.6+ and Pester 6.2.0 using `Invoke-Pester -Path ./tests -CI`.

Offline and hosted CI success do not qualify native Azure DevOps runtime, service
connections/workload identity, publication/access/retention/rollback, or owned
resource cleanup. Those remain separate operator validation gates. No live Azure,
Graph, Exchange or Azure DevOps calls, grants, merges, or releases are part of this
source adoption.
