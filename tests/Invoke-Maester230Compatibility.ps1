#Requires -Version 7.6
<#!
Offline release qualification. Uses the real locked Maester/Pester packages and
production invocation/health blocks with bundled test wrappers plus offline adapters,
synthetic policy responses, and transport tripwires. It never qualifies tenant
permissions, live workload coverage, publication, or a native Azure host.
#>
[CmdletBinding()]
param([string]$MaesterManifest, [Parameter(Mandatory)][string]$MaesterPackage)
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 6.2.0 -Force
if ($MaesterManifest) { Import-Module -Name $MaesterManifest -Force }
else { Import-Module Maester -RequiredVersion 2.3.0 -Force }
$module = Get-Module Maester
. (Join-Path $PSScriptRoot 'Assert-Maester230Package.ps1')
Assert-Maester230Package -PackagePath $MaesterPackage -Module $module
if ($module.Version -ne [version]'2.3.0') { throw 'The actual reviewed Maester 2.3.0 package is required.' }
$bundle = Join-Path $module.ModuleBase 'maester-tests'
if (@(Get-ChildItem $bundle -Recurse -File -Filter '*.Tests.ps1').Count -ne 519) { throw 'Unexpected bundled 2.3.0 test inventory.' }
$root = Split-Path $PSScriptRoot -Parent
$runner = Get-Content (Join-Path $root 'scripts/Invoke-MaesterAzureDevOpsRun.ps1') -Raw
Import-Module (Join-Path $root 'scripts/Maester.AssessmentEvidence.psm1') -Force
$configStart = $runner.IndexOf('$pesterConfiguration = New-PesterConfiguration')
$configEnd = $runner.IndexOf("Write-Host 'Running Maester tests...'", $configStart)
$invokeStart = $configEnd
$invokeEnd = $runner.IndexOf("Write-Host 'Maester execution completed.'", $invokeStart)
if ($configStart -lt 0 -or $configEnd -le $configStart -or $invokeEnd -le $invokeStart) { throw 'Production invocation blocks not found.' }
$configBlock = [scriptblock]::Create($runner.Substring($configStart, $configEnd - $configStart))
$invokeBlock = [scriptblock]::Create($runner.Substring($invokeStart, $invokeEnd - $invokeStart))
# Real Graph package is imported but has no session. Block every network/auth
# entrypoint even if upstream behavior changes. No fabricated Graph context.
$global:Maester230TransportAttempts = 0
foreach ($command in @('Invoke-WebRequest','Invoke-RestMethod','Invoke-MgGraphRequest','Connect-MgGraph','Connect-AzAccount','Connect-ExchangeOnline','Connect-MicrosoftTeams','Install-Module','Send-MtMail','Send-MtTeamsMessage')) {
    Set-Item -Path "function:global:$command" -Value { $global:Maester230TransportAttempts++; throw 'OFFLINE_TRANSPORT_FORBIDDEN' }
}
function global:Test-MtTenantCreationRestricted { $true }
function global:Test-MtSecurityGroupCreationRestricted {
    if ($global:Maester230FixtureMode -eq 'runtime-error') { throw [IO.IOException]::new('synthetic runtime error') }
        if ($global:Maester230FixtureMode -eq 'permission-error') { throw [UnauthorizedAccessException]::new('synthetic permission denied') }
    if ($global:Maester230FixtureMode -eq 'core-skipped') { Set-ItResult -Skipped -Because 'synthetic unavailable workload'; return }
    $false
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "maester-230-compat-$([guid]::NewGuid().ToString('N'))"
$originalDrift = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'Process')
$checks = [Collections.Generic.List[object]]::new()
try {
    foreach ($mode in @('policy','runtime-error','permission-error','setup-error','core-skipped')) {
        $global:Maester230FixtureMode = $mode
        $testsRoot = Join-Path $temp "$mode/tests"
        $outputFolder = Join-Path $temp "$mode/output"
        $entra = Join-Path $testsRoot 'Maester/Entra'
        $null = New-Item -ItemType Directory -Path $entra, $outputFolder -Force
        foreach ($file in @('Test-MtTenantCreationRestricted.Tests.ps1','Test-MtSecurityGroupCreationRestricted.Tests.ps1')) {
            $adapter = @'
BeforeAll {
    function Test-MtTenantCreationRestricted { $true }
    function Test-MtSecurityGroupCreationRestricted {
        if ($global:Maester230FixtureMode -eq 'runtime-error') { throw [IO.IOException]::new('synthetic runtime error') }
        if ($global:Maester230FixtureMode -eq 'permission-error') { throw [UnauthorizedAccessException]::new('synthetic permission denied') }
        if ($global:Maester230FixtureMode -eq 'core-skipped') { Set-ItResult -Skipped -Because 'synthetic unavailable workload'; return }
        $false
    }
}
'@
            ($adapter + "`n" + (Get-Content (Join-Path $bundle "Maester/Entra/$file") -Raw)) | Set-Content (Join-Path $entra $file)
        }
        @'
Describe 'Release compatibility' {
    It 'OFFLINE.SKIP: Explicit unavailable service remains visible.' { Set-ItResult -Skipped -Because 'offline fixture' }
    It 'OFFLINE.PREVIEW: Upstream preview default remains visible.' -Tag Preview { throw 'Preview must remain opt-in.' }
    It 'OFFLINE.LONG: Upstream long-running default remains visible.' -Tag LongRunning { throw 'LongRunning must remain opt-in.' }
}
'@ | Set-Content (Join-Path $testsRoot 'Compatibility.Tests.ps1')
        if ($mode -eq 'setup-error') {
            "Describe 'Engine failure' { BeforeAll { throw 'synthetic setup failure' }; It 'OFFLINE.SETUP: Unreachable.' { 1 | Should -Be 1 } }" | Set-Content (Join-Path $testsRoot 'Engine.Tests.ps1')
        }
        $resultsXmlPath = Join-Path $outputFolder 'test-results.xml'
        $outputHtmlPath = Join-Path $outputFolder 'assessment.html'
        $EnableApprovedDrift = $false
        $MailRecipient = ''
        . $configBlock
        $maesterInvokeParameters.SkipGraphConnect = $true # Harness-only offline adapter.
        [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'unapproved-inherited-fixture', 'Process')
        $failure = $null
        try {
            . $invokeBlock
            $assessmentEvidence = Get-MaesterAssessmentEvidence -Output $maesterOutput -JunitPath $resultsXmlPath -TestsPath $testsRoot -ReportPath $outputHtmlPath
        } catch { $failure = $_.Exception.Message }
        if ([Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'Process') -cne 'unapproved-inherited-fixture') { throw 'Ambient drift state was not restored.' }
        if ($mode -eq 'policy') {
            if ($failure) { throw "Actual 2.3.0 policy result failed the production gate: $failure" }
            $counts = $assessmentEvidence.Counts
            if ($counts.TotalCount -ne 5 -or $counts.PassedCount -ne 1 -or $counts.FailedCount -ne 1 -or $counts.SkippedCount -ne 1 -or $counts.NotRunCount -ne 2 -or $counts.ErrorCount -ne 0) { throw 'Unexpected actual 2.3.0 result accounting.' }
            $checks.Add([ordered]@{ Mode = $mode; Outcome = 'ExpectedCompletion'; Counts = $counts })
        } else {
            $expected = switch ($mode) { 'runtime-error' { 'assessment.unclassifiedFailure' }; 'permission-error' { 'assessment.unclassifiedFailure' }; 'setup-error' { 'assessment.unclassifiedFailure' }; 'core-skipped' { 'assessment.coreNotExecuted' } }
            if ($failure -cne $expected) { throw "Expected $expected for $mode; got '$failure'." }
            if ($mode -eq 'setup-error' -and ([xml](Get-Content $resultsXmlPath -Raw)).testsuites.errors -lt 1) { throw 'Expected real Pester engine errors in JUnit.' }
            $checks.Add([ordered]@{ Mode = $mode; Outcome = 'ExpectedRejection'; Gate = $failure })
        }
    }
    if ($global:Maester230TransportAttempts -ne 0) { throw 'An upstream network/authentication boundary was reached.' }
    [ordered]@{ Kind = 'OfflineMaester230AzureDevOpsCompatibility'; ModuleVersion = $module.Version.ToString(); BundledTestFiles = 519; TransportAttempts = $global:Maester230TransportAttempts; Checks = @($checks.ToArray()) } | ConvertTo-Json -Depth 6
} finally {
    [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', $(if ($null -eq $originalDrift) { [System.Management.Automation.Language.NullString]::Value } else { $originalDrift }), 'Process')
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
