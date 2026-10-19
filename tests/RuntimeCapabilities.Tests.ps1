BeforeAll {
  Remove-Module Maester.AssessmentEvidence -Force -ErrorAction SilentlyContinue
  $root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $root 'scripts/Maester.AssessmentEvidence.psm1') -Force
}
Describe 'Explicit optional runtime capabilities' {
  It 'keeps Full27, Minimal8 and legacy Extended19 distinct from effective access' -ForEach @(
    @{ Profile='Full'; Count=27 }, @{ Profile='Minimal'; Count=8 }, @{ Profile='Extended'; Count=19 }
  ) {
    $r = Get-MaesterRuntimeCapabilities -Context ([pscustomobject]@{Scopes=@('Directory.Read.All')}) -PermissionProfile $Profile
    $r.DeclaredReadRoleCount | Should -Be $Count
    $r.ObservedScopeCount | Should -Be 1
    $r.MailSendEnabled | Should -BeFalse
    $r.ReportSettingsWriteEnabled | Should -BeFalse
    $r.Coverage | Should -Match '^Partial'
  }
  It 'never treats existing Mail.Send as runtime opt-in' {
    $r = Get-MaesterRuntimeCapabilities -Context ([pscustomobject]@{Scopes=@('Directory.Read.All','Mail.Send')}) -PermissionProfile Full
    $r.MailSendObserved | Should -BeTrue
    $r.MailSendEnabled | Should -BeFalse
  }
  It 'blocks existing report-settings write capability without explicit opt-in' {
    { Get-MaesterRuntimeCapabilities -Context ([pscustomobject]@{Scopes=@('ReportSettings.ReadWrite.All')}) -PermissionProfile Minimal } | Should -Throw '*reportSettingsWriteRequiresExplicitOptIn*'
  }
  It 'accepts an explicitly enabled, observed capability' {
    $r = Get-MaesterRuntimeCapabilities -Context ([pscustomobject]@{Scopes=@('ReportSettings.ReadWrite.All','Mail.Send')}) -PermissionProfile Full -IncludeMailSend $true -IncludeReportSettingsWrite $true
    $r.MailSendEnabled | Should -BeTrue
    $r.ReportSettingsWriteEnabled | Should -BeTrue
  }
  It 'rejects enabling a capability absent from connected context' -ForEach @('IncludeMailSend','IncludeReportSettingsWrite') {
    $options = @{ $_=$true }
    { Get-MaesterRuntimeCapabilities -Context ([pscustomobject]@{Scopes=@('Directory.Read.All')}) -PermissionProfile Full @options } | Should -Throw '*CapabilityMissing*'
  }
  It 'fails closed when capability evidence is unavailable or malformed' -ForEach @(
    @{ Context=$null }, @{ Context=[pscustomobject]@{} }, @{ Context=[pscustomobject]@{Scopes=@()} }, @{ Context=[pscustomobject]@{Scopes=@('')} }, @{ Context=[pscustomobject]@{Scopes=@(42)} }
  ) {
    { Get-MaesterRuntimeCapabilities -Context $Context -PermissionProfile Full } | Should -Throw '*capabilityEvidenceUnavailable*'
  }
}
Describe 'Opted-in report privacy restoration evidence' {
  BeforeAll {
    $savedGraphRequest = (Get-Command Invoke-MgGraphRequest -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    function global:Invoke-MgGraphRequest { param($Method,$Uri) throw 'Unmocked network forbidden' }
  }
  AfterAll {
    Remove-Item function:Invoke-MgGraphRequest -ErrorAction SilentlyContinue
    if ($savedGraphRequest) { Set-Item function:global:Invoke-MgGraphRequest $savedGraphRequest }
  }
  It 'reads the upstream setting without changing it' {
    Mock Invoke-MgGraphRequest { @{displayConcealedNames=$true} } -ModuleName Maester.AssessmentEvidence
    Get-MaesterReportPrivacyState | Should -BeTrue
    Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ModuleName Maester.AssessmentEvidence -ParameterFilter { $Method -eq 'GET' -and $Uri -eq 'https://graph.microsoft.com/v1.0/admin/reportSettings' }
  }
  It 'rejects unverifiable privacy-setting evidence' {
    Mock Invoke-MgGraphRequest { @{displayConcealedNames='true'} } -ModuleName Maester.AssessmentEvidence
    { Get-MaesterReportPrivacyState } | Should -Throw '*reportSettingsStateUnverifiable*'
  }
  It 'verifies restoration to either original value' -ForEach @($true,$false) {
    $script:privacy = $_
    Mock Invoke-MgGraphRequest { @{displayConcealedNames=$script:privacy} } -ModuleName Maester.AssessmentEvidence
    { Assert-MaesterReportPrivacyRestored -Expected $script:privacy } | Should -Not -Throw
    { Assert-MaesterReportPrivacyRestored -Expected (-not $script:privacy) } | Should -Throw '*reportSettingsRestoreUnverified*'
  }
  It 'fails closed when restoration readback is denied' {
    Mock Invoke-MgGraphRequest { throw 'synthetic access denied' } -ModuleName Maester.AssessmentEvidence
    { Assert-MaesterReportPrivacyRestored -Expected $true } | Should -Throw '*reportSettingsRestoreUnverified*'
  }
}
