# Approved drift input preparation

`scripts/Maester.DriftInputs.psm1` implements the input boundary for MADO-012.
The host-local modules port the exact reviewed Container Apps Job implementation
at commit `5132a5320969d15ff8b707b5f4b97e2817aee3f3`; Azure DevOps changes only the
manifest host binding and runner integration. They are not a shared component or
evidence of native-host qualification.
`scripts/Maester.DriftRun.psm1` and the runner provide a manual, default-off
CLI opt-in for the locked Maester drift suite. The opt-in validates trusted
operator arguments, binds both connected Graph and Azure tenants, stages the
receipt, accounts for exact drift checks and private JUnit container errors,
then removes the stage before existing private blob publication routes run.
It does not provision or upload input packages, enable the scheduled/Bicep path,
or change permissions. MCAT-011 coordinates the wider host rollout; this host
task remains in progress.

Use PowerShell 7.6+ and import the module from this checkout. The exported
`Initialize-MaesterDriftInput` command requires:

| Argument | Authority and meaning |
| --- | --- |
| `InputRoot` | Existing directory containing only the files below. |
| `StagingParent` | Existing caller-owned normal directory outside InputRoot, protected from untrusted replacement; a fresh private child is allocated. |
| `ExpectedBaselineManifestSha256` | Lowercase SHA-256 supplied from an independently reviewed approval record, outside the artifact. |
| `TenantId`, `Environment`, `RunId` | Exact expected target/environment and selected run. GUIDs must be nonzero. |
| `ProducerId`, `ProducerRevision` | Expected export producer label and immutable lowercase Git revision. |
| `MaxAgeMinutes` | Current-input age bound, 1–60 minutes; default 30. At most one minute of future clock skew is tolerated. |
| `Now` | Evaluation clock, default UTC now; injectable for deterministic tests. Production callers must use the trusted host clock. |

The caller must obtain the expected digest and target/producer context from its
trusted orchestration configuration. Computing the expected digest from an
untrusted incoming package does not approve that package. A digest proves bytes,
not who collected them, permission to collect, completeness, provenance or actual
administrator approval. Manifest labels remain producer assertions. The helper
does not authenticate those assertions or acquire a trusted clock.

## Package

All files are UTF-8 JSON without BOM, comments or trailing commas. There are
exactly two manifests and two fixed files per case. Case IDs match
`[a-z][a-z0-9-]{0,31}` and are unique. No directories, scripts, links/reparse
points, extra files or path fields are accepted. Existing ancestor links are
also rejected. JSON property names cannot repeat or collide by case.

```text
baseline-manifest.json
current-manifest.json
case-1.baseline.json
case-1.current.json
```

`baseline-manifest.json` has exactly these fields:

```json
{
  "schemaVersion": "1.0",
  "tenantId": "00000000-0000-0000-0000-000000000001",
  "environment": "fixture",
  "host": "azuredevops",
  "revision": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "approvalReference": "fixture-only",
  "normalizationRevision": "identity.v1",
  "cases": [{
    "id": "case-1",
    "sha256": "REPLACE_WITH_BASELINE_FILE_SHA256",
    "length": 16,
    "schemaRevision": "fixture.v1",
    "schema": {
      "type": "object",
      "properties": {"enabled": {"type": "boolean"}},
      "required": ["enabled"],
      "additionalProperties": false
    },
    "excludeProperties": []
  }]
}
```

This is a synthetic format illustration, not approval evidence. SHA placeholders
must be replaced with actual lowercase digests before validation.

`current-manifest.json` has exactly `schemaVersion`, `tenantId`, `environment`,
`host`, `runId`, `baselineManifestSha256`, `producerId`, `producerRevision`,
`normalizationRevision`, `capturedAt` and `cases`. Binding values must match the
explicit caller and approved baseline. `capturedAt` is an explicit UTC `Z`
timestamp. All binding headers must be strings and match by ordinal comparison;
JSON booleans, numbers and culture-equivalent text are not accepted. Each case
has exactly `id`, `sha256` and `length`, for the matching
`<id>.current.json`. Baseline and current cases have complete one-to-one parity.
Both file hashes and byte lengths are checked before staging.

The approved baseline digest covers the baseline bytes, schema, normalization
revision, exclusions, immutable source revision and approval reference. Every
input must validate against the approved schema. Root values must be nonempty
objects. This helper validates declared normalization; export producers perform
the actual normalization before creating their JSON.

## Bounds and schemas

Limits are 32 cases, 1 MiB per file including manifests, 16 MiB total including
manifests, and JSON depth 32. Reads use a bounded buffer; verified byte snapshots
are copied, without reopening source data after validation. Changing a source
file later does not change the prepared copy.

Schemas use a closed, reference-free subset: `type`, optional `enum` (1–64
entries), object `properties`/optional `required`/`additionalProperties: false`,
array `items`/`maxItems` (1–256), and string `maxLength` (1–4096). Object schemas
have 1–128 properties. Property/exclusion names are bounded ASCII identifiers
matching `[A-Za-z_][A-Za-z0-9_.-]{0,63}`. Only object, array, string, number,
integer, boolean and null types are accepted. Other keywords, including `$ref`,
patterns and remote schemas, are refused. Upstream comparison still has its
documented limits, including ignoring additional current-only properties;
schema validation does not turn it into a complete bidirectional comparator.

Export producers and approval reviewers must remove secrets, tokens, personal
data and sensitive descriptions before packaging. This is not a general
redactor. The helper emits safe failure codes and no source values, but Maester
comparison reports can include approved input values and differences. Schema
approval must therefore include the privacy of permitted values. Initial suite
qualification uses non-sensitive synthetic data only.

## Owned copies and remaining integration

The returned receipt contains the fresh `StageRoot`, case count/IDs, manifest
digests and run ID. Only `<id>/baseline.json`, `current.json` and generated
`settings.json` are staged. Windows staging disables inherited ACLs and grants
only the current identity full control; Unix uses mode 0700. Source artifacts
and the process drift environment variable are not changed. A failed preparation
cleans only its freshly allocated child. The CLI adapter deletes that exact
receipt-bound directory after invocation and before external publication. Its
outer lifecycle deletes the owned private run root, including JSON, Markdown and
JUnit reports, after success or failure. Input baselines and other runs remain.

The runner's `-EnableApprovedDrift` path verifies the locked built-in suite's
SHA-256 and requires exactly four results per expected case from that file.
Input-validity checks must pass; comparison checks can pass or report genuine
findings. Missing, extra, duplicate, skipped or error results fail the gate.
Supported Pester JUnit output must report zero discovery/container/setup errors;
the XML reader prohibits DTDs and limits the document to 4 MiB. Ordinary
assessments continue to run in the same invocation. Both genuine ordinary and
drift findings remain in the report; missing reports and required latest-blob
publication failures fail the runner. Ambient process state is restored exactly,
including the distinction between an absent and an empty environment variable.
The first opt-in refuses configured mail and Web App destinations because their
audience and in-call delivery boundaries are not qualified for data-bearing
reports. No native scheduled job, workload identity, report access, source
transport/retention, rollback or live collection is qualified by this local
adapter or its fixtures. A second real host integration is required before
extracting a shared adapter into `azd-reference`.

## Manual CLI opt-in

The runner accepts these explicit arguments in addition to `-EnableApprovedDrift`:

| Runner argument | Input helper argument |
| --- | --- |
| `-DriftInputRoot` | `InputRoot` |
| `-DriftExpectedBaselineManifestSha256` | `ExpectedBaselineManifestSha256` |
| `-DriftExpectedTenantId` | `TenantId`; also checked against connected Graph and Az tenant contexts |
| `-DriftEnvironment` | `Environment` |
| `-DriftRunId` | `RunId` |
| `-DriftProducerId` | `ProducerId` |
| `-DriftProducerRevision` | `ProducerRevision` |
| `-DriftMaxAgeMinutes` | `MaxAgeMinutes`, optional, default 30 |

Partial arguments without the switch are refused. Bicep, schedules and environment
variables do not enable this feature. Setup uploads the two helper modules beside
the runner; it does not upload or acquire input packages. Operators must provide
a protected source package and independent approval context, review all permitted
values for privacy, and approve the configured private Blob readers and retention
before any native pilot. Existing archive retention is 365 days; latest output
has no new retention policy. This source integration does not verify live Blob
access or retention. Rolling back means removing the explicit switch and binding
arguments; native rollback still needs qualification.

If partial-stage deletion fails, preparation throws `drift.stagingCleanupFailed`.
The private generated path is retained in `Exception.Data['StageRoot']` for the
trusted caller's recovery; it is not included in the safe error message. Callers
must preserve that recovery context privately and verify cleanup instead of
claiming success. Input errors that occur before allocation never delete a
pre-existing staging-name collision. Trailing directory separators are normalized
before overlap and cleanup checks.

## Local qualification and pipeline publication boundary

Source-bound qualification with the real locked Maester 2.2.0/Pester 6.2.0 suite
ran two synthetic drift cases plus one ordinary synthetic finding. For absent,
empty and inherited drift environment values, each run produced nine checks:
seven passed, two intentional findings, and zero execution errors. The original
input hashes and exact ambient state were preserved; receipt-bound staging and
the owned output root were removed. An additional real BeforeDiscovery failure
was rejected by the JUnit error gate. HTTP and authentication tripwires recorded
zero attempts. This exercised production configuration/invocation and cleanup
blocks, with offline connection/telemetry/version flags and Pester TestRegistry
disabled for the qualification; it did not execute the full runner bootstrap or
a native Azure DevOps pipeline.

Both planted baseline/current string values appeared in the successful HTML,
JSON and Markdown reports. They were absent from the captured log, summary and
JUnit files in this fixture. This is data-bearing output, not a general redactor.
Use only reviewed synthetic non-sensitive exports until a real-data privacy,
reader-access and retention pilot is explicitly approved.

The normal pipeline always publishes workspace `test-results` and scans workspace
NUnit files. The enabled adapter rejects an allocated temporary root equal to or
beneath the current working directory, `BUILD_SOURCESDIRECTORY`, or
`SYSTEM_DEFAULTWORKINGDIRECTORY` before staging input or writing reports. This
also covers an agent whose TEMP/TMP points inside the checkout: even if cleanup
then fails, that newly allocated tree contains no input/report files to publish.
A configured temporary directory outside those workspace roots is required.