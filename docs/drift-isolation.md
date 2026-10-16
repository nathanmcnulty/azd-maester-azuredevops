# Default-disabled configuration drift

This host does not yet accept approved drift baseline/current artifacts.
It excludes the locked Maester 2.2.0 `Maester/Drift/MT1060Drift.tests.ps1`
before Pester discovery, clears `MAESTER_FOLDER_DRIFT` during the invocation,
and restores its previous process value on success or failure. Existing ordinary
assessment, genuine findings, report/publication and failure behavior remain
host-owned. No collector, permission or enabled drift feature is added.

The [reviewed integration design](https://github.com/nathanmcnulty/azd-maester/blob/090001c61660d6522d2c5d4df6581af297015b35/docs/drift-analysis-design.md)
records actual upstream suite/report behavior and limits. Scalar roots and
malformed settings need validation before execution; inherited input and zero-case
discovery failures cannot establish approved assessment. Supplied configuration
values can appear in report details and require reviewed normalization/privacy.

`tests/DriftIsolation.Tests.ps1` exercises the production blocks and uses a child
Pester 6.2 process to prove exclusion before a drift BeforeDiscovery marker runs,
while one ordinary test executes. Environment restoration is covered on success,
failure and an initially unset variable. The inherited-root and discovery tests
fail against the previous runner and pass with the fix.

Separate local qualification ran the real locked Invoke-Maester with this host's
production configuration/invocation blocks, a hash-identical upstream drift suite
copy, an inherited unapproved input folder and one ordinary synthetic test.
Exactly that one ordinary test passed and the prior variable was restored.
Offline connection/telemetry/version flags were supplied for the qualification;
HTTP/authentication tripwires recorded no attempts. This does not execute the
complete deployed runner or prove native runtime, workload identity, Blob/report
publication, access, rollback or resource cleanup.

MADO-011 records this isolation fix. MADO-012 retains explicitly approved,
bounded, data-only baseline/current inputs with tenant/run/source/hash/freshness
binding, schemas, reviewed exclusions/normalization, privacy, positive expected
case counts and failure handling. Native execution/report access/rollback/owned
cleanup remain separate gates; existing runtime-validation tasks stay open.
