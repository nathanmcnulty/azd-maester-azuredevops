# Maester 2.3.0 runtime qualification

The Azure DevOps runner imports the exact hash-verified Maester 2.3.0 package
with Microsoft.Graph.Authentication 2.41.0 and Pester 6.2.0. The reviewed Maester
package SHA-256 is
`95F720822D04271F5E15F4665BC017111DC72E17B97E5D0525CB4EC2FF5BD0B0`,
from [upstream commit 7413c42d](https://github.com/maester365/maester/tree/7413c42d3fcc724dfea94d2726e690ddd364d914).
The bundle contains 519 test files. No tests are fetched from a moving branch.

## Health and coverage

`Invoke-Maester -PassThru` and its exact `assessment.html` output are checked
against Pester 6.2 JUnit (`test-results.xml`). The gate rejects missing/duplicate
results, zero discovery, malformed counts, runtime or permission error records,
Maester errors, JUnit container/setup failures, and missing/skipped core checks
MT.1068 and MT.1069. Every error record is classified, including mixed assertion
and runtime errors that upstream can otherwise label `Failed`. A nonempty HTML
file alone never establishes success. Core execution is a health check, not a
claim of complete assessment coverage.

The declared Graph profile is recorded separately from observed Graph SDK scope
count: Full is the reviewed 27-read-role baseline; Minimal keeps the original
8 roles; Extended is the explicit legacy 19-role inventory. The same bundled
suite runs for each. No permission-based path/tag filter hides errors or gaps.
All Passed, Failed, Error, Investigate, Skipped and NotRun counts stay visible.
Upstream Preview, LongRunning and unconnected Active Directory defaults remain;
ambient drift is excluded before discovery. Full does not establish licensing,
app-only API support, workload connections, native host readiness or compliance.

Requested Exchange/IPPS/Teams connection failures terminate the run rather than
quietly reducing coverage. Genuine assertion findings retain the existing
`FailOnTestFailures` choice. Permission/runtime/health/publication errors always
fail and never emit the findings-only marker, irrespective of that choice.

After healthy execution and configured publication, `assessment-evidence.json`
records the build ID, times, source hashes, actual runtime/module versions,
profile/capability context, result counts, core execution and exact report/JUnit
hashes. It contains no tokens, tenant identities or test details. It is a
source-bound receipt, not a signed or independently verified attestation. The
existing `TestResults` artifact also contains detailed reports and JUnit and
must retain private project/build permissions and appropriate retention.

The pipeline publishes JUnit using the same `test-results.xml` filename. The
legacy NUnit reader remains only for compatibility with earlier focused tests;
Maester 2.3.0 success/finding classification does not use it.

## Optional capabilities are explicit and default-off

`IncludeMailSend=false` means `MailRecipient` alone never sends mail and an
existing Mail.Send grant never enables sending. Enabling it requires a recipient
and Mail.Send in the connected Graph SDK context. Mail is sent only after the
health gate and configured report publication, using the recipient mailbox as
sender, as required by app-only mail. Delivery is recorded as
`UpstreamUnverified`; a successful call is not proof of receipt. The setting
neither grants nor revokes permissions.

`IncludeReportSettingsWrite=false` refuses to start assessment if the connected
Graph SDK context already exposes ReportSettings.ReadWrite.All. Choosing a
smaller profile does not remove existing grants. Either remove that capability
through a separately approved administrative change or explicitly opt in after
reviewing the consequences. No JWT claim decoding is treated as authorization.
Unavailable scope evidence is a blocker, not proof that the capability is absent.

When explicitly enabled, upstream `Test-MtExoMoeraMailActivity` may temporarily
change tenant-wide report concealment to inspect identifiable usage data.
Upstream attempts restoration but can fail; read-only/obfuscated results can
also have reduced coverage. The runner reads the prior privacy setting and
requires a fresh matching read after invocation, including failure cleanup,
before reporting success. It never adds its own tenant-setting write. This does
not eliminate the temporary disclosure window or prove that every upstream
write/read succeeded; assess the report and retain the partial-coverage caveat.

Mail and report-setting writes are rejected for the isolated approved-drift
path. Its existing private staging, locked unchanged drift-suite digest,
workspace exclusion, exact-case checks, ambient-state restoration and owned
cleanup are preserved. The new full-suite health gate also validates ordinary
assessment results inside that private run before publication. No drift report
or evidence is copied to the workspace artifact.

## Offline verification and live gates

Run normal repository tests with Pester 6.2.0. The additional qualification
scripts use actual local packages, check the Maester archive digest and imported
manifest/module/test/assets bytes, and execute production configuration and
invocation blocks with synthetic responses and network/authentication tripwires:

```powershell
./tests/Invoke-Maester230Compatibility.ps1 `
  -MaesterManifest /path/to/Maester.psd1 -MaesterPackage /path/to/Maester.2.3.0.nupkg
./tests/Invoke-Maester230DriftCompatibility.ps1 `
  -MaesterManifest /path/to/Maester.psd1 -MaesterPackage /path/to/Maester.2.3.0.nupkg
```

The ordinary fixture establishes genuine findings with visible skipped/not-run
rows and rejects runtime errors, permission denial, setup errors and skipped
core checks. The drift fixture executes the hash-identical upstream suite and
both core wrappers for absent, empty and inherited ambient values: 11 checks,
9 passes, 2 intentional findings, no errors, unchanged input bytes and removed
owned stages/roots. Both record zero network/authentication attempts.

These are offline source/package contract checks. A live Windows Azure DevOps
agent, federated identity and token scopes, selected grants, every workload,
Blob/Web App/mail publication, artifact access/retention and rollback remain
unverified. No Azure or Azure DevOps login, grant, deployment, run or publication
is performed by these qualification scripts.
