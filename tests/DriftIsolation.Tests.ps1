#Requires -Version 7.6
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeAll {
  $script:runner = Get-Content (Join-Path $PSScriptRoot '../scripts/Invoke-MaesterAzureDevOpsRun.ps1') -Raw
  $invokeStart = $script:runner.IndexOf("Write-Host 'Running Maester tests...'")
  $invokeEnd = $script:runner.IndexOf('$generatedHtml =', $invokeStart)
  if ($invokeStart -lt 0 -or $invokeEnd -lt $invokeStart) { throw 'Production Invoke-Maester isolation block was not found.' }
  $script:invokeBlock = [scriptblock]::Create($script:runner.Substring($invokeStart, $invokeEnd - $invokeStart))
  $script:originalDriftRoot = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'Process')
  $script:originalMarker = [Environment]::GetEnvironmentVariable('DRIFT_TEST_MARKER', 'Process')

  function Invoke-Maester {
    [CmdletBinding()]
    param(
      $Path,
      $PesterConfiguration,
      $OutputFolder,
      [switch]$NonInteractive
    )
    $script:observedDriftRoot = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'Process')
    if ($script:throwDuringRun) { throw 'controlled Maester failure' }
  }
}

Describe 'Default-disabled drift isolation' {
  AfterEach {
    [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', $script:originalDriftRoot, 'Process')
    [Environment]::SetEnvironmentVariable('DRIFT_TEST_MARKER', $script:originalMarker, 'Process')
  }

  It 'clears and restores an inherited drift root when failure is <fails>' -ForEach @(
    @{ fails = $false }
    @{ fails = $true }
  ) {
    $testsRoot = 'fixture-tests'
    $pesterConfiguration = New-PesterConfiguration
    $outputFolder = 'fixture-output'
    $script:throwDuringRun = $fails
    [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'unapproved-inherited-folder', 'Process')

    if ($fails) { { & $script:invokeBlock } | Should -Throw '*controlled Maester failure*' }
    else { & $script:invokeBlock | Out-Null }

    $script:observedDriftRoot | Should -BeNullOrEmpty
    [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'Process') | Should -BeExactly 'unapproved-inherited-folder'
  }

  It 'preserves an unset drift root after the run' {
    $testsRoot = 'fixture-tests'
    $pesterConfiguration = New-PesterConfiguration
    $outputFolder = 'fixture-output'
    $script:throwDuringRun = $false
    [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', $null, 'Process')

    & $script:invokeBlock | Out-Null

    $script:observedDriftRoot | Should -BeNullOrEmpty
    [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'Process') | Should -BeNullOrEmpty
  }

  It 'excludes the locked drift file before discovery while an ordinary test runs' {
    $testsRoot = Join-Path $TestDrive 'suite'
    $driftRoot = Join-Path $testsRoot 'Maester/Drift'
    $null = New-Item -ItemType Directory -Path $driftRoot
    @'
Describe 'Ordinary assessment fixture' { It 'runs' { 1 | Should -Be 1 } }
'@ | Set-Content (Join-Path $testsRoot 'Ordinary.Tests.ps1')
    @'
BeforeDiscovery {
  [IO.File]::WriteAllText($env:DRIFT_TEST_MARKER, 'unapproved discovery')
  throw 'Drift discovery must not run in the default assessment.'
}
Describe 'Drift' { It 'must not run' { $false | Should -BeTrue } }
'@ | Set-Content (Join-Path $driftRoot 'MT1060Drift.tests.ps1')

    $configStart = $script:runner.IndexOf('$pesterConfiguration = New-PesterConfiguration')
    $configEnd = $script:runner.IndexOf('$pesterConfiguration.TestResult.Enabled', $configStart)
    if ($configStart -lt 0 -or $configEnd -lt $configStart) { throw 'Production Pester configuration was not found.' }
    $configuration = $script:runner.Substring($configStart, $configEnd - $configStart)
    $harness = @'
param([string]$TestsPath)
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 6.2.0 -Force
$testsRoot = $TestsPath
'@ + "`n" + $configuration + @'

$pesterConfiguration.Run.Path = $TestsPath
$pesterConfiguration.Run.PassThru = $true
$pesterConfiguration.Output.Verbosity = 'None'
$result = Invoke-Pester -Configuration $pesterConfiguration
if ($result.TotalCount -ne 1 -or $result.PassedCount -ne 1 -or $result.FailedContainers.Count -ne 0) { exit 1 }
'@
    $harnessPath = Join-Path $TestDrive 'discovery-harness.ps1'
    $harness | Set-Content $harnessPath
    $env:DRIFT_TEST_MARKER = Join-Path $TestDrive 'discovery-marker'
    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })

    $output = & $pwsh -NoProfile -File $harnessPath -TestsPath $testsRoot 2>&1

    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    Test-Path $env:DRIFT_TEST_MARKER | Should -BeFalse
  }
}
