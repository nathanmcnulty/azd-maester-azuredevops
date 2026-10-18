Describe 'Post-deployment authentication target boundary' {
  BeforeAll {
    $sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Setup-PostDeploy.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
    $statements = @($ast.EndBlock.Statements)
    $start = $statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$selectedSubscription' } | Select-Object -First 1
    $end = $statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$deploymentValues' } | Select-Object -First 1
    # Execute the real authentication block and its first target-lookup statement.
    # Skip only the intervening helper dot-source; its command is mocked below.
    $selected = $statements | Where-Object {
      $_.Extent.StartOffset -ge $start.Extent.StartOffset -and $_.Extent.EndOffset -le $end.Extent.EndOffset -and
      -not ($_.Extent.Text -like ". (Join-Path*Resolve-DeploymentTargets.ps1*)")
    }
    $script:authBlock = [scriptblock]::Create("Set-StrictMode -Version Latest`n" + ($selected.Extent.Text -join "`n"))

    function Get-AzContext { param([string]$ErrorAction) throw 'Unmocked Az context read.' }
    function Connect-AzAccount {
      param($AccessToken, $AccountId, $Tenant, $Subscription, [switch]$SkipContextPopulation)
      throw 'Real authentication is forbidden in this fixture.'
    }
    function Get-AzCliAccessToken { param($Resource, $TenantId, $SubscriptionId) throw 'Real token acquisition is forbidden.' }
    function Get-AzCliSubscriptionContext { param($SubscriptionId, $TenantId) throw 'Unmocked CLI context read.' }
    function Get-MaesterDeploymentValues { param($EnvironmentName, $SubscriptionId, $ResourceGroupName) throw 'Real target discovery is forbidden.' }
    function az { throw 'Real CLI dispatch is forbidden.' }
  }

  BeforeEach {
    $script:subscription = '11111111-1111-1111-1111-111111111111'
    $script:tenant = '22222222-2222-2222-2222-222222222222'
    $script:finalContext = [pscustomobject]@{
      Subscription = [pscustomobject]@{ Id = $script:subscription; Name = 'Selected' }
      Tenant = [pscustomobject]@{ Id = $script:tenant }
    }
    $script:initialContext = $script:finalContext
    $script:contextReads = 0
    Mock Get-AzContext {
      $script:contextReads++
      if ($script:contextReads -eq 1) { return $script:initialContext }
      return $script:finalContext
    }
    Mock Get-AzCliAccessToken { 'synthetic-arm-token' }
    Mock Connect-AzAccount {}
    Mock az { $global:LASTEXITCODE = 0; 'operator@example.com' }
    Mock Get-AzCliSubscriptionContext { $global:LASTEXITCODE = 0; [pscustomobject]@{ name = 'Selected'; id = $script:subscription; tenantId = $script:tenant } }
    Mock Get-MaesterDeploymentValues { @{} }
    $SubscriptionId = $script:subscription
    $TenantId = $script:tenant
    $EnvironmentName = 'fixture'
    $ResourceGroupName = 'rg-fixture'
  }

  It 'refreshes a matching cached Az context with the selected CLI management token before target lookup' {
    & $script:authBlock
    Should -Invoke Get-AzCliAccessToken -Times 1 -Exactly -ParameterFilter {
      $Resource -ceq 'https://management.azure.com/' -and $TenantId -eq $script:tenant -and $SubscriptionId -eq $script:subscription
    }
    Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
      $AccessToken -ceq 'synthetic-arm-token' -and $AccountId -ceq 'operator@example.com' -and
      $Tenant -eq $script:tenant -and $Subscription -eq $script:subscription -and $SkipContextPopulation
    }
    Should -Invoke Get-MaesterDeploymentValues -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:subscription }
  }

  It 'refreshes from an unrelated cached Az default into the explicitly selected target' {
    $script:initialContext = [pscustomobject]@{
      Subscription = [pscustomobject]@{ Id = '99999999-9999-4999-8999-999999999999' }
      Tenant = [pscustomobject]@{ Id = '88888888-8888-4888-8888-888888888888' }
    }
    & $script:authBlock
    Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
      $Tenant -eq $script:tenant -and $Subscription -eq $script:subscription -and $AccessToken -ceq 'synthetic-arm-token'
    }
    Should -Invoke Get-MaesterDeploymentValues -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:subscription }
  }

  It 'rejects an unconfirmed returned context before any target lookup: <Case>' -ForEach @(
    @{ Case = 'wrong subscription'; Mode = 'subscription' }
    @{ Case = 'wrong tenant'; Mode = 'tenant' }
    @{ Case = 'missing context'; Mode = 'null' }
    @{ Case = 'missing tenant'; Mode = 'missingTenant' }
  ) {
    switch ($Mode) {
      subscription { $script:finalContext.Subscription.Id = '33333333-3333-3333-3333-333333333333' }
      tenant { $script:finalContext.Tenant.Id = '33333333-3333-3333-3333-333333333333' }
      null { $script:finalContext = $null }
      missingTenant { $script:finalContext.Tenant = $null }
    }
    { & $script:authBlock } | Should -Throw '*Azure PowerShell context*selected subscription and tenant*'
    Should -Invoke Get-MaesterDeploymentValues -Times 0 -Exactly
    Should -Invoke Get-AzCliSubscriptionContext -Times 1 -Exactly
  }

  It 'uses the normal selected-tenant login when neither CLI token nor cached Az context is available' {
    $script:initialContext = $null
    Mock Get-AzCliAccessToken { $null }
    & $script:authBlock
    Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
      -not $AccessToken -and $Tenant -eq $script:tenant -and $Subscription -eq $script:subscription
    }
    Should -Invoke Get-MaesterDeploymentValues -Times 1 -Exactly
  }

  It 'retains a matching cached Az context when the CLI token is unavailable' {
    Mock Get-AzCliAccessToken { $null }
    & $script:authBlock
    Should -Invoke Connect-AzAccount -Times 0 -Exactly
    Should -Invoke Get-MaesterDeploymentValues -Times 1 -Exactly
  }

  It 'carries the tenant confirmed by ARM into the Az context and target discovery' {
    & $script:authBlock
    Should -Invoke Get-AzCliSubscriptionContext -Times 2 -Exactly -ParameterFilter { $TenantId -eq $script:tenant }
    Should -Invoke Get-MaesterDeploymentValues -Times 1 -Exactly
  }
}
