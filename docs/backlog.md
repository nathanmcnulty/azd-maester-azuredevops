# Backlog: nathanmcnulty/azd-maester-azuredevops

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-maester-azuredevops
- **Source revision:** `8fd330ba59db6ad18b13f8383c699b8720dc7168`
- **Captured:** 2026-10-16
- **Items:** 12

## MADO-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- Reconciled later reviewed metadata tip 45ab981d03f8c0506a8b66bf7d93edd189fa5085 against freshly fetched origin/main 582697472d74247bb9345c75104b0b69d85e7355. Current main adds reviewed source fixes from pull request&lpar;s&rpar; &num;16; no dirty canonical bytes or unrelated branch history were copied.
- Current repository issues and pull requests were read on 2026-10-04&colon; none are open. Items MADO-002, MADO-003, MADO-005, MADO-006, MADO-007, MADO-008 remain proposed because their component, host-specific live, or shared azd-maester issue gates are not satisfied by source merges alone; completed issue-backed fixes retain exact issue and pull-request evidence.
- Full current-source offline Pester validation passed 37/37 tests with zero failures. Canonical backlog schema and generated-Markdown checks also passed; no Azure, Graph, deployment, report publication or other live operation was performed.

**Review and authorization note:**

Review MADO-001 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-009: Pin Azure PowerShell and runner module versions for reproducibility

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The report captured on 2026-10-03 is closed after the reviewed fix merged; this record preserves the original trigger and validation boundary.

**Scope:**

- Linked issue and current source &lpar;read-only&rpar;
- Repository-local backlog evidence

**Acceptance:**

- Read the linked issue and current default branch; classify the exact defect, current owner and evidence gap.
- Record a current PR or verified resolution before selecting any implementation; preserve broader feature and live acceptance gates.

**Validation:**

- Read current issue and PR state using nathanmcnulty; do not modify or close issues during reconciliation.
- Inspect dirty state and worktrees; resolve the exact current revision and relevant offline commands before implementation.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-azuredevops/issues/13

**Evidence:**

- GitHub issue &num;13 is closed by merged pull request &num;14; current origin/main 582697472d74247bb9345c75104b0b69d85e7355 contains the reviewed fix. Source closure does not claim a new live deployment, report publication, or human-visible result.

**Review and authorization note:**

Review MADO-009 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-004: Validation treats mixed pipeline failures as successful Maester test findings

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The report captured on 2026-10-03 is closed after the reviewed fix merged; this record preserves the original trigger and validation boundary.

**Scope:**

- Paths and trigger cited in the linked issue
- Focused offline regression tests
- docs/
- docs/backlog.json
- docs/backlog.md
- BACKLOG.md

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-azuredevops/issues/12
- README.md

**Evidence:**

- Merged fix&colon; https&colon;//github.com/nathanmcnulty/azd-maester-azuredevops/pull/14 closed issue &num;12 and is current main 67b9c6c91013fc4f6a0c05a0ffc252cba231ba15.
- Current-head classifier accepts findings only when the Maester runner is the sole failed task, both publishers succeed, TestResults exists and the runner-owned marker matches&colon; https&colon;//github.com/nathanmcnulty/azd-maester-azuredevops/blob/67b9c6c91013fc4f6a0c05a0ffc252cba231ba15/scripts/PipelineValidation.Core.psm1&num;L19-L58
- Deterministic fixtures retain the findings-only control and reject publication failure, other failed tasks or jobs, missing artifacts and missing markers&colon; https&colon;//github.com/nathanmcnulty/azd-maester-azuredevops/blob/67b9c6c91013fc4f6a0c05a0ffc252cba231ba15/tests/PipelineValidation.Tests.ps1&num;L16-L59
- Exact current-main validation passed&colon; https&colon;//github.com/nathanmcnulty/azd-maester-azuredevops/actions/runs/37145878990/job/111269591797
- Live evidence gap preserved&colon; PR &num;14 claims no live Azure DevOps pipeline or Graph run; this is current-source and offline-regression evidence only.
- GitHub issue &num;12 is closed by merged pull request &num;14; current origin/main 582697472d74247bb9345c75104b0b69d85e7355 contains the reviewed fix. Source closure does not claim a new live deployment, report publication, or human-visible result.

**Review and authorization note:**

Review MADO-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-005: Azure DevOps solution - Authentication Sync between az and azd

- **Kind:** maintenance
- **Priority:** P1
- **Status:** proposed
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Open GitHub report captured 2026-10-03. Reproduce against the current source and reconcile active PRs before changing code; the issue remains the detailed trigger/evidence reference.

**Scope:**

- Paths and trigger cited in the linked issue
- Focused offline regression tests
- docs/

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester/issues/15
- README.md

**Evidence:**

- 2026-10-16&colon; Inspected origin/main 80dd3bcab64cdbf5adafd7131f5ea47b378065f6 and the linked azd-maester issue &num;15. The original MFA/token-expiry report needs stage-specific live evidence; no trace identifies whether provisioning or post-provision setup failed. It remains proposed and is not closed by this change.
- Reproduced a separate post-provision boundary defect&colon; four offline cases &lpar;wrong subscription, wrong tenant, absent context, absent tenant&rpar; reached target discovery. Added a returned-context guard before discovery; all eight authentication behavior tests and all 72 repository tests pass with PowerShell 7.6.6 and Pester 6.2.0. No live authentication, deployments, permissions or audience membership changes were performed.
- See docs/authentication-context.md for credential-store boundaries and the evidence still needed for the original report.

**Review and authorization note:**

Review MADO-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-006: Azure DevOps Solution - Interactive Wizard - Security Group Validation

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Upstream issue &num;14 reports that the Web App wizard accepted blank or malformed security-group object IDs and failed later. The adopted shared hook now validates and normalizes a non-empty GUID before persistence while preserving the disabled Web App path.

**Scope:**

- scripts/vendor/Azd.MaesterHooks/Maester-UpWizard.psm1
- azd-components.lock.json
- Focused offline regression tests
- docs/

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- maester-azd-hooks

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester/issues/14
- azd-components.lock.json
- scripts/vendor/Azd.MaesterHooks/Maester-UpWizard.psm1

**Evidence:**

- Read open upstream azd-maester issue &num;14 on 2026-10-07 and adopted reviewed pilot maester-azd-hooks 0.1.6 from immutable azd-reference revision a09cac311aac7362f56d2a31833ed90ce5812649 into exact host base 80e99c8acc486e985988d06b9ddce75990e4fd38. The lock now binds the changed wizard to SHA-256 aa88f4f8a65d41ae6b06a1008c55eb1e2fbedebbb07b5f2f987c4452baf363c0.
- Nine extracted canonical behavior tests executed against the actual vendored component bytes&colon; blank, malformed, nil and malformed legacy cached values fail before environment persistence; a valid cached GUID is normalized before persistence; interactive input retries after a malformed value; and the disabled Web App path performs no group validation or Graph lookup.
- The guard proves GUID formatting and fail-before-persistence behavior only. It does not prove that the GUID identifies a group, that the group exists in a selected directory, or that a live Azure DevOps deployment succeeds. No authentication, directory lookup, group creation, permission grant, deployment or upstream issue action ran.

**Review and authorization note:**

Review MADO-006 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-007: Azure DevOps solution - Null Path Binding error in manual fallback instructions

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Open GitHub report captured 2026-10-03. Reproduce against the current source and reconcile active PRs before changing code; the issue remains the detailed trigger/evidence reference.

**Scope:**

- Paths and trigger cited in the linked issue
- Focused offline regression tests
- docs/

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester/issues/13
- README.md

**Evidence:**

- Reproduced issue &num;13 against exact current-main base 760ac2d854b54367376b6c9892ff8c0385ab92c6&colon; with TEMP absent, repository staging raised the reported Null Path Binding error before invoking git.
- Setup-PostDeploy now resolves its repository staging root with IO.Path.GetTempPath; focused offline Pester coverage passed both the no-change and clone-failure paths with TEMP absent and verified finally cleanup without authentication or network access.
- Full current-source offline validation passed 39/39 Pester tests and parsed all 23 PowerShell files without errors; no authentication, repository push or live service operation ran.

**Review and authorization note:**

Review MADO-007 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-008: Azure DevOps Solution - postprovision fails to push to empty repository

- **Kind:** maintenance
- **Priority:** P1
- **Status:** proposed
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The upstream report attributes an automatic pipeline-file push failure to a newly created empty Azure DevOps repository. Current source successfully bootstraps ordinary empty Git repositories offline, so any remaining failure is specific to the provider, authentication, timing or target and requires new exact Azure DevOps evidence before a code change.

**Scope:**

- Paths and trigger cited in the linked issue
- Focused offline regression tests
- docs/

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester/issues/12
- README.md

**Evidence:**

- Read open upstream azd-maester issue &num;12 on 2026-10-07 and inspected exact standalone main 6d1930742b93b16dfaf61bc0ceb8f215f6eff5f4. Push-RepositoryFiles still fails closed when git clone returns nonzero; it does not classify authentication, network or provider errors as an empty repository.
- Executed the exact current Push-RepositoryFiles and cleanup functions using Git 2.55.0.windows.3. An empty local bare repository received refs/heads/main and the pipeline YAML, so the later branch/YAML lookup inputs existed. A seeded nonempty repository preserved its history and unrelated file; an identical second call made no commit or push. A missing remote propagated the native clone failure and cleanup left no staging directory. No authentication, network or Azure DevOps operation ran.
- The generic empty-repository trigger is not reproducible offline. No source fallback was added because converting an unclassified clone failure into git init/push would mask target, authorization, transport and provider failures. No live Azure DevOps organization, project, repository, account or permission set was selected or authorized, and the provider REST branch-resolution request was not exercised. A future source change needs a fresh redacted Azure DevOps command/error trace covering both the clone failure and refs/heads/main lookup; this classification does not close upstream issue &num;12 or claim a live provider fix.

**Review and authorization note:**

Review MADO-008 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-010: Enforce the PowerShell 7.6 and Pester 6.2 authoring baseline

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Repository CI now selects Pester 6.2, but owned entry points and the generated pipeline did not enforce the PowerShell 7.6 floor.

**Scope:**

- Owned scripts and validation module
- Generated pipeline preflight and developer guidance

**Acceptance:**

- Require PowerShell 7.6+ before owned script/module bodies execute; keep immutable vendor and runtime package locks unchanged.
- Check the pipeline agent version before its Azure CLI service-connection task and log the selected validation versions.
- Run all offline tests on actual PowerShell 7.6+ and Pester 6.2; retain the separate live agent/workload gates.

**Validation:**

- Import-Module Pester -RequiredVersion 6.2.0; Invoke-Pester -Path ./tests -CI
- Parse owned entry points and generated inline pipeline script; validate permission evidence and canonical backlog schema/generated Markdown.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-azuredevops/issues/23
- https&colon;//github.com/nathanmcnulty/azd-maester-azuredevops/pull/24
- docs/development.md

**Evidence:**

- 2026-10-16&colon; Follow-up based on authentication PR24 head 87cacb1f926971b1ad4ead8e4ed497c50021f9d4. All ten owned scripts/modules require PowerShell 7.6. The generated pipeline performs a version preflight before its Azure CLI task. Vendored source and runtime package locks are unchanged.
- Actual PowerShell 7.6.6 / Pester 6.2.0 full offline suite&colon; 74 passed, zero failed/skipped. No live Azure DevOps agent, service connection, workload, report publication or tenant change was exercised; MADO-002 remains open.

**Review and authorization note:**

Review MADO-010 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-003: Reconcile shared hook/webapp versions and host permission deltas

- **Kind:** maintenance
- **Priority:** P2
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Existing adoption must be updated through hashes and host-specific validation rather than blindly reinstalling components.

**Scope:**

- azd-components.lock.json
- azd-permissions.json
- scripts/
- infra/
- docs/

**Acceptance:**

- Compare lock pins with canonical manifests and current-source drift before proposing an update.
- Run target-context negative cases and compare minimal versus optional-feature permissions.
- Keep Maester execution and reporting host-specific; record exact source hashes and candidate/pilot status.

**Validation:**

- Invoke-Pester ./tests/TargetContext.Tests.ps1 -CI
- Read and compare lock hashes with canonical reference source; do not overwrite drift.

**Dependencies:**

- _none_

**Components:**

- maester-azd-hooks
- maester-report-webapp

**Sources:**

- README.md
- azd-components.lock.json

**Evidence:**

- At reviewed host base 80e99c8acc486e985988d06b9ddce75990e4fd38, all eight maester-azd-hooks 0.1.5 files and the maester-report-webapp 0.1.1 file matched their existing lock hashes before import. Adopted only maester-azd-hooks 0.1.6 from immutable azd-reference revision a09cac311aac7362f56d2a31833ed90ce5812649; seven hook files were byte-identical and only Maester-UpWizard.psm1 changed. The report-webapp pin remains 0.1.1 at 79f0608c672639aae0f0ed96d160b1eb17cfc08f.
- Added a partial, source-bound permission inventory with 24 proven entries&colon; eight Minimal Graph application roles, eleven Extended additions, four deployment-operator delegated scopes used by the shared grant helper, and optional Mail.Send when a recipient is configured. Canonical comparison has no evidence-hash findings but comparisonComplete remains false because Azure RBAC, Azure DevOps, other host Graph operations, Exchange, Teams, report-webapp and cleanup authority remain explicit gaps; this records no tenant consent or effective grants.
- Offline validation passed all 39 repository Pester tests, the focused TargetContext negative cases, all nine extracted canonical Maester hook behavior tests against the actual vendored bytes, parsing of 23 PowerShell files, two Bicep builds, component drift, permission schema/comparison including a stale-hash control, and backlog schema/generated-view checks. No authentication, deployment, permission grant, pipeline run, report publication or cleanup ran.

**Review and authorization note:**

Review MADO-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-002: Qualify Azure DevOps pipeline execution and optional report-webapp lifecycle

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** azure-deployment
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Shared pilots are already vendored; host-specific execution and report access still need independently bound evidence.

**Scope:**

- scripts/Invoke-PipelineValidation.ps1
- docs/
- infra/
- tests/TargetContext.Tests.ps1

**Acceptance:**

- Record exact Maester/runtime/component revisions and host execution output under the selected tenant.
- Validate optional webapp identity, report publishing, Easy Auth and feature-specific permission delta.
- Disabled web hosting works independently; cleanup preserves adopted objects and records exact owned resources.

**Validation:**

- Invoke-Pester ./tests/TargetContext.Tests.ps1 -CI
- After separate authorization use ./scripts/Invoke-PipelineValidation.ps1 against the exact owned host; retain report access and cleanup evidence.

**Dependencies:**

- _none_

**Components:**

- maester-azd-hooks
- maester-report-webapp

**Sources:**

- README.md
- scripts/Invoke-PipelineValidation.ps1

**Evidence:**

- _none_

**Review and authorization note:**

Review MADO-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-011: Keep configuration drift disabled and isolated by default

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 3
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Omitting DriftRoot leaves upstream Maester able to discover unapproved input from an inherited process environment variable.

**Scope:**

- scripts/Invoke-MaesterAzureDevOpsRun.ps1
- tests/DriftIsolation.Tests.ps1
- docs/drift-isolation.md
- docs/backlog.json
- docs/backlog.md

**Acceptance:**

- Exclude the locked upstream drift file before Pester discovery and clear its ambient environment during invocation, restoring prior process state on success and failure.
- Preserve ordinary assessment, genuine findings, publication and failure semantics; do not enable drift, fetch data or add permissions.
- Prove the original inherited-input defect and corrected isolation with exact production configuration/invocation tests plus actual locked suite/report qualification.

**Validation:**

- PowerShell 7.6+ and Pester 6.2&colon; Invoke-Pester ./tests -CI
- Parse all PowerShell; canonical backlog schema/render checks; fixtures are not native job or publisher proof.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- docs/drift-isolation.md
- https&colon;//github.com/nathanmcnulty/azd-maester/blob/090001c61660d6522d2c5d4df6581af297015b35/docs/drift-analysis-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/2

**Evidence:**

- PowerShell 7.6.6/Pester 6.2.0 full repository validation passed 78/78 with zero nonpasses; parser and differential analyzer checks found no new supported-runtime issue. Three isolation regression cases fail against the original runner, and all four pass with the fix.
- Actual offline locked Maester 2.2.0 Invoke-Maester qualification used this host production configuration/invocation blocks, an unchanged hash-verified upstream suite, one ordinary synthetic test and an inherited unapproved input folder. Exactly one ordinary test passed, drift stayed excluded, the inherited environment was restored, and no HTTP/authentication tripwire fired. Qualification supplies offline connection flags and invokes only assessment blocks; publisher paths are outside this check, and no native job, workload identity, Blob publication/access or cleanup outcome is claimed.
- Default-disabled isolation only; MADO-012 retains the approved-input adapter, normalization/privacy and native qualification gates. Existing runtime/deployment validation evidence is preserved.

**Review and authorization note:**

Review MADO-011 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MADO-012: Implement approved data-only configuration drift inputs

- **Kind:** feature
- **Priority:** P2
- **Status:** proposed
- **Wave:** 4
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Upstream drift comparison exists, but this host has no approved artifact/target/privacy contract or live qualification.

**Scope:**

- scripts/Invoke-MaesterAzureDevOpsRun.ps1
- tests/
- docs/
- azd-permissions.json

**Acceptance:**

- Follow the reviewed MCAT-011 design&colon; explicitly enabled data-only artifacts, immutable approved baseline, tenant/environment/run/source/hash/freshness binding, bounded JSON/path/link/duplicate validation and reviewed schemas, normalization and exclusions.
- Use the actual locked upstream suite with expected positive case counts and fail on missing suite, zero cases, malformed/scalar/settings inputs, comparison errors and container failures; preserve default-off isolation and reused-process environment restoration.
- Inspect actual HTML/JSON/Markdown/logs for planted sensitive values; preserve separate comparison, report and publication outcomes and rollback. Add no automatic capture, baseline update or remediation.
- Independently review the adapter and qualify authorized native job execution, report access, rollback and exact owned cleanup; coordinate a second host before shared extraction.

**Validation:**

- PowerShell 7.6+/Pester 6.2 registered tests and actual locked suite/report fixtures.
- Separate authorized native host/report/access/cleanup qualification; local metadata grants no live authority.

**Dependencies:**

- MADO-011

**Components:**

- _none_

**Sources:**

- docs/drift-isolation.md
- https&colon;//github.com/nathanmcnulty/azd-maester/blob/090001c61660d6522d2c5d4df6581af297015b35/docs/drift-analysis-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/2

**Evidence:**

- _none_

**Review and authorization note:**

Review MADO-012 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
