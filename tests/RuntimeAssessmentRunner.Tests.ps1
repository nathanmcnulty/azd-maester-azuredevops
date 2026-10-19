BeforeAll {
  Remove-Module Maester.AssessmentEvidence -Force -ErrorAction SilentlyContinue
  $repo = Split-Path $PSScriptRoot -Parent
  $importModuleCommand = Get-Command Import-Module -CommandType Cmdlet
  . (Join-Path $PSScriptRoot 'fixtures/RuntimeAssessmentEvidence.ps1')
  $staged = Join-Path $TestDrive 'staged'
  $stagedScripts = Join-Path $staged 'scripts'
  $null = New-Item -ItemType Directory $stagedScripts -Force
  foreach ($name in 'Invoke-MaesterAzureDevOpsRun.ps1','Maester.AssessmentEvidence.psm1') { Copy-Item (Join-Path $repo "scripts/$name") $stagedScripts }
  Copy-Item (Join-Path $repo 'runtime-packages.lock.json') $staged
  Set-Content (Join-Path $stagedScripts 'Install-LockedModules.ps1') 'param($LockPath,$DestinationRoot); $global:RuntimeAssessmentHarness.Installs++'
  $fixtureModuleBase = Join-Path $TestDrive 'Maester'
  $null = New-Item -ItemType Directory (Join-Path $fixtureModuleBase 'maester-tests/Maester/Entra') -Force
  Set-Content (Join-Path $fixtureModuleBase 'maester-tests/fixture.Tests.ps1') '# offline fixture, never executed'
  $fixtureVersions = @{}
  (Get-Content (Join-Path $staged 'runtime-packages.lock.json') -Raw | ConvertFrom-Json).packages | ForEach-Object { $fixtureVersions[$_.name]=$_.version }
  $envNames = @('idToken','servicePrincipalId','tenantId','AGENT_TEMPDIRECTORY','PSModulePath','BUILD_BUILDID','MAESTER_FOLDER_DRIFT')
  $savedEnv = @{}
  foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
  $savedFunctions = @{}
  foreach ($name in 'az','Connect-AzAccount','Get-AzContext','Get-AzAccessToken','Connect-MgGraph','Get-MgContext','Invoke-Maester','New-AzStorageContext','Set-AzStorageBlobContent','Send-MtMail') {
    $savedFunctions[$name] = (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
  }
  function global:az { $global:LASTEXITCODE = 0; 'offline-subscription' }
  function global:Connect-AzAccount { param([switch]$ServicePrincipal,$ApplicationId,$Tenant,$FederatedToken,$Subscription) throw 'Unmocked authentication forbidden' }
  function global:Get-AzContext { throw 'Unmocked Azure forbidden' }
  function global:Get-AzAccessToken { param($ResourceUrl,$TenantId,[switch]$AsSecureString) throw 'Unmocked token forbidden' }
  function global:Connect-MgGraph { param($AccessToken,[switch]$NoWelcome) throw 'Unmocked Graph authentication forbidden' }
  function global:Get-MgContext { throw 'Unmocked Graph forbidden' }
  function global:Invoke-Maester { param($Path,$OutputFolder,$PesterConfiguration,[switch]$NonInteractive,[switch]$PassThru,$OutputFolderFileName,[switch]$DisableTelemetry,[switch]$SkipVersionCheck) throw 'Unmocked assessment forbidden' }
  function global:New-AzStorageContext { param($StorageAccountName,[switch]$UseConnectedAccount) throw 'Unmocked storage forbidden' }
  function global:Set-AzStorageBlobContent { param($File,$Container,$Blob,$Context,[switch]$Force) throw 'Unmocked upload forbidden' }
  function global:Send-MtMail { param($MaesterResults,$Recipient,$UserId) throw 'Unmocked mail forbidden' }
}
Describe 'Complete Azure DevOps runner assessment boundary (offline)' {
  BeforeEach {
    $global:RuntimeAssessmentHarness = @{ Mode='good'; Installs=0; Uploads=0; Mail=0; Auth=0; Scopes=@('Directory.Read.All') }
    $working = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory $working
    Push-Location $working
    $env:idToken='offline-federated-token'; $env:servicePrincipalId='offline-client'; $env:tenantId='offline-tenant'
    $env:AGENT_TEMPDIRECTORY=$working; $env:BUILD_BUILDID='12345'; $env:MAESTER_FOLDER_DRIFT='unapproved-inherited-folder'
    $run = @{ TenantId='offline-tenant'; SubscriptionId='offline-subscription'; ClientId='offline-client'; StorageAccountName='offlinestorage' }
    Mock Import-Module {
      if ([string]$Name -ne (Join-Path $stagedScripts 'Maester.AssessmentEvidence.psm1')) { throw 'Unexpected module import' }
      & $importModuleCommand -Name $Name -Force -Global -ErrorAction Stop
    }
    Mock Import-Module {} -ParameterFilter { $Name -in @('PackageManagement','PowerShellGet','Az.Accounts','Az.Storage','Microsoft.Graph.Authentication','Pester','Maester') }
    Mock Get-Module { [pscustomobject]@{ Name=$Name; Version=[version]$fixtureVersions[([string]$Name[0])]; Path=(Join-Path $fixtureModuleBase 'Maester.psd1') } }
    Mock Connect-AzAccount { $global:RuntimeAssessmentHarness.Auth++ }
    Mock Get-AzContext { $null }
    Mock Get-AzAccessToken { [pscustomobject]@{Token=(ConvertTo-SecureString 'offline-token' -AsPlainText -Force)} }
    Mock Connect-MgGraph { $global:RuntimeAssessmentHarness.Auth++ }
    Mock Get-MgContext { [pscustomobject]@{Scopes=$global:RuntimeAssessmentHarness.Scopes} }
    Mock New-AzStorageContext { 'offline-context' }
    Mock Set-AzStorageBlobContent {
      $global:RuntimeAssessmentHarness.Uploads++
      if ($global:RuntimeAssessmentHarness.Mode -eq 'publication-error') { throw 'offline publication error' }
    }
    Mock Send-MtMail { $global:RuntimeAssessmentHarness.Mail++ }
    Mock Invoke-Maester {
      $PassThru | Should -BeTrue
      $DisableTelemetry | Should -BeTrue
      $SkipVersionCheck | Should -BeTrue
      $NonInteractive | Should -BeTrue
      $PesterConfiguration.TestResult.OutputFormat.Value | Should -Be 'JUnitXml'
      $PesterConfiguration.Run.ExcludePath.Value | Should -HaveCount 1
      $env:MAESTER_FOLDER_DRIFT | Should -BeNullOrEmpty
      $report = Join-Path $OutputFolder 'assessment.html'
      $r = New-TestAssessmentResult $Path
      $r | Add-Member OutputFiles ([pscustomobject]@{OutputHtmlFile=$report})
      switch ($global:RuntimeAssessmentHarness.Mode) {
        'maester-error' { $r.Tests[0].Result='Error'; $r.PassedCount=0; $r.ErrorCount=1 }
        'permission-error' { $r.Tests[1].ErrorRecord=@([pscustomobject]@{FullyQualifiedErrorId='Authorization_RequestDenied'}) }
        'core-skipped' { $r.Tests[0].Result='Skipped'; $r.PassedCount=0; $r.SkippedCount=2 }
        'duplicate-output' { $r }
      }
      if ($global:RuntimeAssessmentHarness.Mode -ne 'no-report') { Set-Content $report '<html>private fixture</html>' }
      $errors = if ($global:RuntimeAssessmentHarness.Mode -eq 'engine-error') {1} else {0}
      $disabled = if ($global:RuntimeAssessmentHarness.Mode -eq 'core-skipped') {4} else {3}
      Set-Content $PesterConfiguration.TestResult.OutputPath.Value "<testsuites tests=`"5`" errors=`"$errors`" failures=`"1`" disabled=`"$disabled`" />"
      $r
    }
  }
  AfterEach {
    Pop-Location
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name,$savedEnv[$name]) }
  }
  AfterAll {
    foreach ($name in $savedFunctions.Keys) {
      Remove-Item "function:$name" -ErrorAction SilentlyContinue
      if ($savedFunctions[$name]) { Set-Item "function:global:$name" $savedFunctions[$name] }
    }
    Remove-Module Maester.AssessmentEvidence -Force -ErrorAction SilentlyContinue
    Remove-Variable RuntimeAssessmentHarness -Scope Global
  }
  It 'writes source-bound sanitized evidence after healthy policy findings and federation' {
    $null = & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run
    $r = Get-Content (Join-Path $working 'test-results/assessment-evidence.json') -Raw | ConvertFrom-Json
    $r.Kind | Should -Be 'MaesterAzureDevOpsAssessment'
    $r.BuildId | Should -Be '12345'
    $r.Runtime.Modules.Maester | Should -Be '2.3.0'
    $r.Source.RunnerSha256 | Should -Be ((Get-FileHash (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1')).Hash.ToLowerInvariant())
    $r.Assessment.Counts.FailedCount | Should -Be 1
    $r.Assessment.Counts.NotRunCount | Should -Be 2
    $r.Permissions.DeclaredReadRoleCount | Should -Be 27
    $r.Publication.Mail | Should -Be 'Disabled'
    $r.Publication.Latest | Should -Be 'Published'
    ($r | ConvertTo-Json -Depth 10) | Should -Not -Match 'offline-token|offline-tenant|private fixture'
    $global:RuntimeAssessmentHarness.Uploads | Should -Be 2
    $global:RuntimeAssessmentHarness.Auth | Should -Be 2
    $env:MAESTER_FOLDER_DRIFT | Should -Be 'unapproved-inherited-folder'
    Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $FederatedToken -eq 'offline-federated-token' -and $ApplicationId -eq 'offline-client' }
  }
  It 'keeps Minimal8 visible without removing any tests' {
    $null = & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run -PermissionProfile Minimal
    $r = Get-Content (Join-Path $working 'test-results/assessment-evidence.json') -Raw | ConvertFrom-Json
    $r.Permissions.DeclaredReadRoleCount | Should -Be 8
    $r.Assessment.Counts.TotalCount | Should -Be 5
  }
  It 'rejects <_> before any publication, mail or successful receipt' -ForEach @('maester-error','permission-error','engine-error','core-skipped','no-report','duplicate-output') {
    $global:RuntimeAssessmentHarness.Mode=$_
    $global:RuntimeAssessmentHarness.Scopes += 'Mail.Send'
    { & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run -IncludeMailSend true -MailRecipient 'recipient@example.invalid' -FailOnTestFailures false } | Should -Throw '*assessment.*'
    $global:RuntimeAssessmentHarness.Uploads | Should -Be 0
    $global:RuntimeAssessmentHarness.Mail | Should -Be 0
    Test-Path (Join-Path $working 'test-results/assessment-evidence.json') | Should -BeFalse
    $env:MAESTER_FOLDER_DRIFT | Should -Be 'unapproved-inherited-folder'
  }
  It 'uses fresh fixed outputs rather than accepting an old HTML report' {
    $null = New-Item -ItemType Directory (Join-Path $working 'test-results')
    Set-Content (Join-Path $working 'test-results/assessment.html') 'old report'
    $global:RuntimeAssessmentHarness.Mode='no-report'
    { & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run } | Should -Throw '*reportMissing*'
    $global:RuntimeAssessmentHarness.Uploads | Should -Be 0
  }
  It 'does not send for a configured recipient or existing grant without explicit opt-in' {
    $global:RuntimeAssessmentHarness.Scopes += 'Mail.Send'
    $null = & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run -MailRecipient 'recipient@example.invalid'
    $global:RuntimeAssessmentHarness.Mail | Should -Be 0
  }
  It 'sends only after health and publication with explicit opt-in' {
    $global:RuntimeAssessmentHarness.Scopes += 'Mail.Send'
    $null = & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run -IncludeMailSend true -MailRecipient 'recipient@example.invalid'
    $global:RuntimeAssessmentHarness.Mail | Should -Be 1
    (Get-Content (Join-Path $working 'test-results/assessment-evidence.json') -Raw | ConvertFrom-Json).Publication.Mail | Should -Be 'UpstreamUnverified'
  }
  It 'fails a requested publication instead of emitting findings-only evidence' {
    $global:RuntimeAssessmentHarness.Mode='publication-error'
    { & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run -FailOnTestFailures true } | Should -Throw '*offline publication error*'
    Test-Path (Join-Path $working 'test-results/assessment-evidence.json') | Should -BeFalse
  }
  It 'blocks existing report-settings-write access before assessment unless explicitly enabled' {
    $global:RuntimeAssessmentHarness.Scopes += 'ReportSettings.ReadWrite.All'
    { & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run } | Should -Throw '*reportSettingsWriteRequiresExplicitOptIn*'
    Should -Invoke Invoke-Maester -Times 0 -Exactly
  }
  It 'never allows optional capabilities on isolated approved drift' {
    { & (Join-Path $stagedScripts 'Invoke-MaesterAzureDevOpsRun.ps1') @run -EnableApprovedDrift -IncludeReportSettingsWrite true } | Should -Throw '*drift.optionalCapabilitiesUnsupported*'
    $global:RuntimeAssessmentHarness.Auth | Should -Be 0
    $global:RuntimeAssessmentHarness.Installs | Should -Be 0
  }
}
