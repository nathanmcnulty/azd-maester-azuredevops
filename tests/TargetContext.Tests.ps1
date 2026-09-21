$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptFiles = Get-ChildItem -LiteralPath (Split-Path -Parent $PSScriptRoot) -Recurse -File -Include *.ps1, *.psm1 |
  Where-Object { $_.FullName -notmatch '[\\/](?:\.git|tests)[\\/]' }

Import-Module (Join-Path $repoRoot 'scripts/vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1') -Force

Describe 'Azure CLI target context' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
  }

  It 'does not mutate the global default subscription' {
    $matches = $scriptFiles | Select-String -Pattern '\baz account set\b'
    $matches | Should -BeNullOrEmpty
  }

  It 'targets every access token request explicitly' {
    $matches = $scriptFiles | Select-String -Pattern '\baz account get-access-token\b'
    foreach ($match in $matches) {
      $match.Line | Should -Match '--(?:subscription|tenant)\b'
    }
  }

  It 'requests only the Azure DevOps access token for pipeline validation' {
    $validator = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\Invoke-PipelineValidation.ps1')

    $validator | Should -Match "'--query',\s*'accessToken'"
  }

  It 'targets every Azure CLI REST request explicitly' {
    $matches = $scriptFiles | Select-String -Pattern '\baz rest\b'
    foreach ($match in $matches) {
      $match.Line | Should -Match '(?:--subscription\b|@subscriptionArgs\b)'
    }
  }

  It 'refreshes a stale Az PowerShell context from the target Azure CLI token' {
    $setup = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\Setup-PostDeploy.ps1')

    $setup | Should -Match 'Get-AzCliAccessToken'
    $setup | Should -Match 'https://management.azure.com/'
    $setup | Should -Match '-SubscriptionId \$SubscriptionId'
    $setup | Should -Match '\$managementToken\s*=\s*Get-AzCliAccessToken'
    $setup | Should -Match '-AccessToken \$managementToken'
  }
}

Describe 'Selected subscription validation' {
  InModuleScope Maester-SetupHelpers {
    BeforeEach {
      Mock az {
        $global:LASTEXITCODE = 0
        '[{"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222"}]'
      }
    }

    It 'returns the requested subscription without changing the default' {
      $account = Get-AzCliSubscriptionContext `
        -SubscriptionId '11111111-1111-1111-1111-111111111111' `
        -TenantId '22222222-2222-2222-2222-222222222222'

      $account.id | Should -Be '11111111-1111-1111-1111-111111111111'
      Should -Invoke az -Times 1 -Exactly
    }

    It 'rejects a subscription from a different tenant' {
      {
        Get-AzCliSubscriptionContext `
          -SubscriptionId '11111111-1111-1111-1111-111111111111' `
          -TenantId '33333333-3333-3333-3333-333333333333'
      } | Should -Throw '*belongs to tenant*'
    }
  }
}

Describe 'Azure DevOps repository ownership' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
  }

  It 'records whether setup created the repository' {
    $setup = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\Setup-PostDeploy.ps1')

    $setup | Should -Match "AZDO_REPOSITORY_CREATED"
    $setup | Should -Match '\$repositoryCreatedByEnvironment\s*=\s*\$true'
  }

  It 'preserves repositories that were not created by the environment' {
    $cleanup = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts\vendor\Azd.MaesterHooks\Maester-PreDownCleanup.psm1')

    $cleanup | Should -Match '\$adoRepositoryCreated\s*=.*AZDO_REPOSITORY_CREATED'
    $cleanup | Should -Match 'Preserving Azure DevOps repository'
  }
}
