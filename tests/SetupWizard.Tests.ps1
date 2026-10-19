Describe 'Maester assessment profile selection' {
  BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/vendor/Azd.MaesterHooks/Maester-UpWizard.psm1') -Force
  }
  AfterAll { Remove-Module Maester-UpWizard -Force -ErrorAction SilentlyContinue }

  It 'maps an interactive Full choice <answer> to <profile> without including report writes' -ForEach @(
    @{ answer = ''; profile = 'Full' }, @{ answer = 'n'; profile = 'Minimal' }
  ) {
    InModuleScope Maester-UpWizard -Parameters @{ answer = $answer; profile = $profile } {
      Mock Test-InteractiveWizard { $true }
      Mock Get-AzdEnvironmentValues { @{
        INCLUDE_WEB_APP = 'false'; INCLUDE_EXCHANGE = 'false'; INCLUDE_TEAMS = 'false'; INCLUDE_AZURE = 'false'
        AZDO_ORGANIZATION = 'org'; AZDO_PROJECT = 'project'; AZDO_REPOSITORY = 'repo'; MAESTER_SETUP_CLIENT_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; MAESTER_SETUP_ACCOUNT = 'admin@example.com'
      } }
      Mock Read-Host { if ($Prompt -like 'Grant the permissions needed for the full assessment?*') { return $answer }; return 'n' }
      Mock Set-AzdEnvValueStrict {}
      Invoke-MaesterUpWizard -SolutionName azure-devops -SubscriptionId '11111111-1111-4111-8111-111111111111'
      Should -Invoke Read-Host -Times 1 -ParameterFilter { $Prompt -ceq 'Grant the permissions needed for the full assessment? [Y/n]' }
      Should -Invoke Set-AzdEnvValueStrict -Times 1 -ParameterFilter { $Name -ceq 'PERMISSION_PROFILE' -and $Value -ceq $profile }
      Should -Invoke Set-AzdEnvValueStrict -Times 1 -ParameterFilter { $Name -ceq 'INCLUDE_REPORT_SETTINGS_WRITE' -and $Value -ceq 'false' }
      Should -Invoke Set-AzdEnvValueStrict -Times 1 -ParameterFilter { $Name -ceq 'INCLUDE_MAIL_SEND' -and $Value -ceq 'false' }
    }
  }

  It 'keeps noninteractive <stored> as <expected> without permission expansion' -ForEach @(
    @{ stored = ''; expected = 'Minimal' }, @{ stored = 'Minimal'; expected = 'Minimal' },
    @{ stored = 'Extended'; expected = 'Extended' }, @{ stored = 'Full'; expected = 'Full' }
  ) {
    InModuleScope Maester-UpWizard -Parameters @{ stored = $stored; expected = $expected } {
      Mock Test-InteractiveWizard { $false }
      Mock Get-AzdEnvironmentValues { @{
        PERMISSION_PROFILE = $stored
        AZDO_ORGANIZATION = 'org'; AZDO_PROJECT = 'project'; AZDO_REPOSITORY = 'repo'; MAESTER_SETUP_CLIENT_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; MAESTER_SETUP_ACCOUNT = 'admin@example.com'
      } }
      Mock Read-Host { throw 'No unattended prompts.' }
      Mock Set-AzdEnvValueStrict {}
      Invoke-MaesterUpWizard -SolutionName azure-devops -SubscriptionId '11111111-1111-4111-8111-111111111111'
      Should -Invoke Set-AzdEnvValueStrict -Times 1 -ParameterFilter { $Name -ceq 'PERMISSION_PROFILE' -and $Value -ceq $expected }
      Should -Invoke Read-Host -Times 0
    }
  }

  It 'does not call the legacy Extended profile Full' {
    InModuleScope Maester-UpWizard {
      Mock Test-InteractiveWizard { $true }
      Mock Get-AzdEnvironmentValues { @{
        PERMISSION_PROFILE = 'Extended'; INCLUDE_WEB_APP = 'false'; INCLUDE_EXCHANGE = 'false'; INCLUDE_TEAMS = 'false'; INCLUDE_AZURE = 'false'
        AZDO_ORGANIZATION = 'org'; AZDO_PROJECT = 'project'; AZDO_REPOSITORY = 'repo'; MAESTER_SETUP_CLIENT_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; MAESTER_SETUP_ACCOUNT = 'admin@example.com'
      } }
      Mock Read-Host { 'n' }
      Mock Set-AzdEnvValueStrict {}
      Mock Write-Host {}
      Invoke-MaesterUpWizard -SolutionName azure-devops -SubscriptionId '11111111-1111-4111-8111-111111111111'
      Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like 'Extended is the legacy permission set.*' }
      Should -Invoke Set-AzdEnvValueStrict -Times 1 -ParameterFilter { $Name -ceq 'PERMISSION_PROFILE' -and $Value -ceq 'Minimal' }
    }
  }

  It 'rejects missing or default setup-client identity before persistence' -ForEach @(
    @{ client = ''; account = 'admin@example.com' },
    @{ client = '14d82eec-204b-4c2f-b7e8-296a70dab67e'; account = 'admin@example.com' },
    @{ client = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; account = '' }
  ) {
    InModuleScope Maester-UpWizard -Parameters @{ client = $client; account = $account } {
      Mock Test-InteractiveWizard { $false }
      Mock Get-AzdEnvironmentValues { @{ AZDO_ORGANIZATION = 'org'; AZDO_PROJECT = 'project'; AZDO_REPOSITORY = 'repo'; MAESTER_SETUP_CLIENT_ID = $client; MAESTER_SETUP_ACCOUNT = $account } }
      Mock Set-AzdEnvValueStrict {}
      { Invoke-MaesterUpWizard -SolutionName azure-devops -SubscriptionId '11111111-1111-4111-8111-111111111111' } | Should -Throw
      Should -Invoke Set-AzdEnvValueStrict -Times 0
    }
  }
}
