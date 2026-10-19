BeforeAll {
  $root = Split-Path $PSScriptRoot -Parent
  $runner = Get-Content (Join-Path $root 'scripts/Invoke-MaesterAzureDevOpsRun.ps1') -Raw
  $pipeline = Get-Content (Join-Path $root 'pipelines/template-maester.yml') -Raw
  $lock = Get-Content (Join-Path $root 'runtime-packages.lock.json') -Raw | ConvertFrom-Json
}
Describe 'Reviewed Maester 2.3.0 runtime contract' {
  It 'pins actual reviewed Maester and Graph packages' {
    $maester = $lock.packages | Where-Object name -EQ Maester
    $maester.version | Should -Be '2.3.0'
    $maester.sha256 | Should -BeExactly '95F720822D04271F5E15F4665BC017111DC72E17B97E5D0525CB4EC2FF5BD0B0'
    ($lock.packages | Where-Object name -EQ Microsoft.Graph.Authentication).version | Should -Be '2.41.0'
    $runner | Should -Not -Match '2\.2\.0'
    $runner | Should -Match "Version -eq \[version\]'2\.3\.0'"
  }
  It 'discloses all profiles while optional capabilities remain independent default-off flags' {
    $ast = [Management.Automation.Language.Parser]::ParseInput($runner,[ref]$null,[ref]$null)
    foreach ($name in 'IncludeMailSend','IncludeReportSettingsWrite') {
      $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
      $parameter.DefaultValue.SafeGetValue() | Should -Be 'false'
    }
    $pipeline | Should -Match '__INCLUDE_MAIL_SEND__'
    $pipeline | Should -Match '__INCLUDE_REPORT_SETTINGS_WRITE__'
    $pipeline | Should -Match '__PERMISSION_PROFILE__'
    $runner | Should -Match 'Declared Graph read profile:'
  }
  It 'uses JUnit framework errors and deterministic report binding with no permission filters' {
    $pipeline | Should -Match 'testResultsFormat: JUnit'
    $pipeline | Should -Not -Match 'testResultsFormat: NUnit'
    $runner | Should -Not -Match '\.Filter\.(ExcludeTag|Tag)|Get-ChildItem -Path \$outputFolder -Filter'
    $runner | Should -Match "OutputFolderFileName = 'assessment'"
    $runner | Should -Match 'PassThru = \$true'
    $runner | Should -Match 'DisableTelemetry = \$true'
    $runner | Should -Match 'SkipVersionCheck = \$true'
    $runner | Should -Not -Match "WarningAction = 'SilentlyContinue'"
    $runner.IndexOf('Get-MaesterAssessmentEvidence -Output $maesterOutput') | Should -BeLessThan $runner.IndexOf('Set-AzStorageBlobContent -File $latestHtmlPath')
    $runner.IndexOf('Set-AzStorageBlobContent -File $latestHtmlPath') | Should -BeLessThan $runner.IndexOf('Send-MtMail -MaesterResults')
    $runner.IndexOf("'assessment-evidence.json') -Encoding") | Should -BeLessThan $runner.IndexOf('AZD_MAESTER_RESULT=FINDINGS;')
  }
  It 'preserves workload federation and refuses requested connection failures' {
    $runner | Should -Match '-FederatedToken \$env:idToken'
    $pipeline | Should -Match 'addSpnToEnvironment: true'
    foreach ($code in 'exchangeConnectionFailed','complianceConnectionFailed','teamsConnectionFailed') { $runner | Should -Match "throw 'assessment.$code'" }
  }
  It 'validates both ordinary and isolated approved-drift result health' {
    $runner | Should -Match 'Get-MaesterAssessmentEvidence -Output @\(\$approvedDriftRunResult.Result\)'
    $runner | Should -Match "throw 'drift.optionalCapabilitiesUnsupported'"
    $runner | Should -Match 'Assert-MaesterReportPrivacyRestored -Expected \$reportPrivacyBefore'
    $pipeline | Should -Not -Match 'EnableApprovedDrift|DriftInputRoot'
  }
}
