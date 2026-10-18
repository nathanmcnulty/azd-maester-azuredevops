Describe 'Actual setup and pipeline target control flow (offline)' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:setupPath = Join-Path $root 'scripts/Setup-PostDeploy.ps1'
    $script:pipelinePath = Join-Path $root 'scripts/Invoke-PipelineValidation.ps1'
    Import-Module (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1') -Force
    # Execute the unchanged production authentication/guard region through the
    # first deployment lookup. Authentication and discovery commands are stubs.
    $ast = [Management.Automation.Language.Parser]::ParseFile($script:setupPath, [ref]$null, [ref]$null)
    $statements = @($ast.EndBlock.Statements)
    # Match by the diagnostic rather than relying on line offsets.
    $first = $statements | Where-Object { $_.Extent.Text -like '*TenantId is required to validate the intended setup target*' } | Select-Object -First 1
    $last = $statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$deploymentValues' } | Select-Object -First 1
    $selected = $statements | Where-Object { $_.Extent.StartOffset -ge $first.Extent.StartOffset -and $_.Extent.EndOffset -le $last.Extent.EndOffset -and $_.Extent.Text -notlike ". (Join-Path*Resolve-DeploymentTargets.ps1*)" }
    $script:setupControlFlow = [scriptblock]::Create($selected.Extent.Text -join "`n")
    $exchangeCall = $ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Connect-ExchangeOnlineSilent'}, $true)
    $script:exchangeControlFlow = [scriptblock]::Create($exchangeCall.Extent.Text)
    function global:az {
      $global:AdoGuardFixture.Calls.Add(($args -join ' '))
      $global:LASTEXITCODE = 0
      if ($args[0] -eq 'rest') {
        ($args -join ' ') | Should -BeLike "*--subscription $($global:AdoGuardFixture.Subscription)*"
        if ($global:AdoGuardFixture.ReadFailure) { $global:LASTEXITCODE = 1; return '' }
        return ($global:AdoGuardFixture.Metadata | ConvertTo-Json -Compress)
      }
      if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
        if ($global:AdoGuardFixture.NoCliToken) { $global:LASTEXITCODE = 1; return '' }
        if ('--tenant' -notin $args -and '--subscription' -notin $args) { throw 'Unscoped token tripwire.' }
        return (@{ accessToken = 'offline-token'; tenant = $global:AdoGuardFixture.Tenant; subscription = $global:AdoGuardFixture.Subscription } | ConvertTo-Json -Compress)
      }
      if (($args -join ' ') -like 'account show *--query user.name*') { return 'synthetic@example.com' }
      throw "Unexpected CLI call: $($args -join ' ')"
    }
    function global:azd {
      if (($args -join ' ') -like 'env get-values --output json*') { $global:LASTEXITCODE = 0; return '{}' }
      throw 'Unexpected azd write tripwire.'
    }
    function Invoke-OfflineSetup {
      param($SubscriptionId, $TenantId)
      & $script:setupPath -SubscriptionId $SubscriptionId -TenantId $TenantId -EnvironmentName offline -ResourceGroupName rg-offline -AdoOrganization org -AdoProject project -AdoRepositoryName repo -AdoPipelineName pipeline -AdoServiceConnectionName connection
    }
    function Get-AzContext { $global:AdoGuardFixture.Context }
    function Connect-AzAccount { param($Subscription, $Tenant, $AccessToken, $AccountId, [switch]$SkipContextPopulation) $global:AdoGuardFixture.AuthCalls++ }
    function Get-AzAccessToken { param($ResourceUrl, $TenantId) $global:AdoGuardFixture.AzTokens++; $global:AdoGuardFixture.AzTokenTenant=$TenantId; [pscustomobject]@{Token='offline-token'} }
    function Get-MaesterDeploymentValues { param($EnvironmentName, $SubscriptionId, $ResourceGroupName) $global:AdoGuardFixture.Discoveries++; @{} }
    function Connect-ADOPS { param($Organization, $OAuthToken, [switch]$SkipVerification) $global:AdoGuardFixture.AdoConnections++ }
    function Get-ADOPSPipeline { param($Project,$Name,$Organization) [pscustomobject]@{id=7} }
    function Start-ADOPSPipeline { param($Project,$Name,$Branch,$Organization) $global:AdoGuardFixture.Builds++; [pscustomobject]@{id=9;state='completed';result='succeeded'} }
    function Invoke-ADOPSRestMethod { param($Method,$Uri) [pscustomobject]@{state='completed';result=$global:AdoGuardFixture.Result} }
    function global:Connect-ExchangeOnline { param($AccessToken,$ShowBanner,$Organization) $global:AdoGuardFixture.ExchangeConnections++ }
    function Invoke-RestMethod { throw 'External HTTP tripwire.' }
    Import-Module (Join-Path $root 'scripts/PipelineValidation.Core.psm1') -Force
    Mock Test-ModuleAvailable { $true }
    Mock Import-Module {}
  }
  BeforeEach {
    $SubscriptionId = '11111111-1111-4111-8111-111111111111'
    $TenantId = '22222222-2222-4222-8222-222222222222'
    $EnvironmentName = 'offline'; $ResourceGroupName = 'rg-offline'
    $global:AdoGuardFixture = @{
      Subscription=$SubscriptionId; Tenant=$TenantId; ReadFailure=$false; NoCliToken=$false
      Calls=[Collections.Generic.List[string]]::new(); AuthCalls=0; Discoveries=0; Builds=0; AdoConnections=0; AzTokens=0; ExchangeConnections=0; Result='succeeded'
      Metadata=@{id="/subscriptions/$SubscriptionId";subscriptionId=$SubscriptionId;tenantId=$TenantId;displayName='Selected';state='Enabled'}
      Context=[pscustomobject]@{Subscription=[pscustomobject]@{Id=$SubscriptionId;Name='Selected'};Tenant=[pscustomobject]@{Id=$TenantId}}
    }
  }
  AfterAll {
    Remove-Item function:az, function:azd, function:Connect-ExchangeOnline -ErrorAction SilentlyContinue
    Remove-Variable AdoGuardFixture -Scope Global -ErrorAction SilentlyContinue
  }
  It 'blocks <entrypoint> before any downstream activity for <case>' -ForEach @(
    foreach ($entrypoint in 'setup','pipeline') {
      foreach ($case in 'wrong tenant','wrong subscription','Disabled','missing state','missing tenant','read failure') {
        @{entrypoint=$entrypoint;case=$case}
      }
    }
  ) {
    switch ($case) {
      'wrong tenant' { $global:AdoGuardFixture.Metadata.tenantId='33333333-3333-4333-8333-333333333333' }
      'wrong subscription' { $global:AdoGuardFixture.Metadata.subscriptionId='33333333-3333-4333-8333-333333333333' }
      'Disabled' { $global:AdoGuardFixture.Metadata.state='Disabled' }
      'missing state' { $global:AdoGuardFixture.Metadata.Remove('state') }
      'missing tenant' { $global:AdoGuardFixture.Metadata.Remove('tenantId') }
      'read failure' { $global:AdoGuardFixture.ReadFailure=$true }
    }
    if ($entrypoint -eq 'setup') { { Invoke-OfflineSetup -SubscriptionId $SubscriptionId -TenantId $TenantId } | Should -Throw }
    else { { & $script:pipelinePath -SubscriptionId $SubscriptionId -TenantId $TenantId -AdoOrganization org -AdoProject project -PipelineName offline } | Should -Throw }
    $global:AdoGuardFixture.Calls.Count | Should -Be 1
    $global:AdoGuardFixture.Calls[0] | Should -BeLike 'rest *'
    $global:AdoGuardFixture.Discoveries | Should -Be 0
    $global:AdoGuardFixture.Builds | Should -Be 0
    $global:AdoGuardFixture.AdoConnections | Should -Be 0
    $global:AdoGuardFixture.AuthCalls | Should -Be 0
    @($global:AdoGuardFixture.Calls | Where-Object { $_ -notlike 'rest *' }).Count | Should -Be 0
  }
  It 'rejects absent configured tenant before any setup activity' {
    $TenantId = ''
    { & $script:setupControlFlow } | Should -Throw '*TenantId is required*'
    $global:AdoGuardFixture.Calls.Count | Should -Be 0
    $global:AdoGuardFixture.Discoveries | Should -Be 0
  }
  It 'rejects absent configured pipeline context before any build activity' {
    $savedTenant = $env:AZURE_TENANT_ID
    $savedSubscription = $env:AZURE_SUBSCRIPTION_ID
    try {
      $env:AZURE_TENANT_ID = ''; $env:AZURE_SUBSCRIPTION_ID = ''
      { & $script:pipelinePath -AdoOrganization org -AdoProject project -PipelineName offline } | Should -Throw '*SubscriptionId and TenantId are required*'
      $global:AdoGuardFixture.Calls.Count | Should -Be 0
      $global:AdoGuardFixture.Builds | Should -Be 0
    }
    finally { $env:AZURE_TENANT_ID = $savedTenant; $env:AZURE_SUBSCRIPTION_ID = $savedSubscription }
  }
  It 'validates setup and requests the actual Exchange helper token for the intended tenant' {
    & $script:setupControlFlow
    $global:AdoGuardFixture.Discoveries | Should -Be 1
    $exoOrganization = 'selected.onmicrosoft.com'
    & $script:exchangeControlFlow
    $global:AdoGuardFixture.ExchangeConnections | Should -Be 1
    @($global:AdoGuardFixture.Calls | Where-Object { $_ -like "*https://outlook.office365.com*--tenant $TenantId*" }).Count | Should -Be 1
  }
  It 'starts a valid selected pipeline even when the unrelated Az default differs' {
    $global:AdoGuardFixture.Context.Subscription.Id='99999999-9999-4999-8999-999999999999'
    $result = & $script:pipelinePath -SubscriptionId $SubscriptionId -TenantId $TenantId -AdoOrganization org -AdoProject project -PipelineName offline -PassThru
    $result.ValidationPassed | Should -BeTrue
    $global:AdoGuardFixture.Builds | Should -Be 1
    $global:AdoGuardFixture.AzTokens | Should -Be 0
  }
  It 'uses the verified selected Az fallback with an explicit tenant when the CLI token is unavailable' {
    $global:AdoGuardFixture.NoCliToken=$true
    $result = & $script:pipelinePath -SubscriptionId $SubscriptionId -TenantId $TenantId -AdoOrganization org -AdoProject project -PipelineName offline -PassThru
    $result.ValidationPassed | Should -BeTrue
    $global:AdoGuardFixture.AzTokens | Should -Be 1
    $global:AdoGuardFixture.AzTokenTenant | Should -Be $TenantId
    $global:AdoGuardFixture.Builds | Should -Be 1
    $global:AdoGuardFixture.AuthCalls | Should -Be 0
  }
  It 'rejects a mismatched returned Az fallback context before acquiring its token or starting a build' {
    $global:AdoGuardFixture.NoCliToken=$true
    $global:AdoGuardFixture.Context.Tenant.Id='99999999-9999-4999-8999-999999999999'
    { & $script:pipelinePath -SubscriptionId $SubscriptionId -TenantId $TenantId -AdoOrganization org -AdoProject project -PipelineName offline } | Should -Throw '*Could not acquire*'
    $global:AdoGuardFixture.Builds | Should -Be 0
    $global:AdoGuardFixture.AzTokens | Should -Be 0
  }
  It 'preserves execution failure instead of calling it successful validation' {
    $global:AdoGuardFixture.Result='canceled'
    { & $script:pipelinePath -SubscriptionId $SubscriptionId -TenantId $TenantId -AdoOrganization org -AdoProject project -PipelineName offline } | Should -Throw "*result 'canceled'*"
  }
}
