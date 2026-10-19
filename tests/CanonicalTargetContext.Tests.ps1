Describe 'Maester explicit target boundaries (offline)' {
  BeforeAll {
    $hooksRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vendor/Azd.MaesterHooks'
    Import-Module (Join-Path $hooksRoot 'Maester-PreUp.psm1') -Force
    Import-Module (Join-Path $hooksRoot 'Maester-SetupHelpers.psm1') -Force
    # No Azure executable or authentication is used. These command doubles fail
    # on every unexpected command, including account set and unscoped requests.
    function global:az {
      $arguments = @($args)
      $global:MaesterTargetTest.Calls.Add(($arguments -join ' '))
      $global:LASTEXITCODE = 0
      if ($arguments[0] -eq 'rest') {
        if (($arguments -join ' ') -notlike "*--subscription $($global:MaesterTargetTest.Subscription)*" -or
            ($arguments -join ' ') -notlike "*https://management.azure.com/subscriptions/$($global:MaesterTargetTest.Subscription)?api-version=2022-12-01*") {
          throw 'ARM metadata was not explicitly scoped.'
        }
        if ($global:MaesterTargetTest.ReadFailure) { $global:LASTEXITCODE = 1; return '' }
        if ($global:MaesterTargetTest.Malformed) { return '{invalid' }
        return ($global:MaesterTargetTest.Metadata | ConvertTo-Json -Compress)
      }
      if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'get-access-token') {
        if ('--tenant' -notin $arguments -and '--subscription' -notin $arguments) { throw 'Unscoped token request.' }
        if ($global:MaesterTargetTest.TokenFailure) { $global:LASTEXITCODE = 1; return '' }
        return (@{ accessToken = $global:MaesterTargetTest.Token; tenant = $global:MaesterTargetTest.TokenTenant; subscription = $global:MaesterTargetTest.TokenSubscription } | ConvertTo-Json -Compress)
      }
      if ($arguments[0] -eq 'group') {
        if (($arguments -join ' ') -notlike "*--subscription $($global:MaesterTargetTest.Subscription)*") { throw 'Unscoped group command.' }
        if ($arguments[1] -eq 'exists') { return $global:MaesterTargetTest.Exists }
        if ($arguments[1] -eq 'create') { $global:MaesterTargetTest.Creates++; return }
      }
      # An unrelated cached/default account is deliberately available but must
      # never be trusted as current subscription-state proof.
      if ($arguments[0] -eq 'account' -and $arguments[1] -in @('list', 'show')) {
        return (@{ id = '99999999-9999-4999-8999-999999999999'; tenantId = '88888888-8888-4888-8888-888888888888'; state = 'Enabled' } | ConvertTo-Json)
      }
      throw "Unexpected az command: $($arguments -join ' ')"
    }
    function global:azd {
      if (($args -join ' ') -eq 'env get-values --output json') { $global:LASTEXITCODE = 0; return ($global:MaesterTargetTest.AzdValues | ConvertTo-Json -Compress) }
      throw "Unexpected azd command: $($args -join ' ')"
    }
    function global:Connect-ExchangeOnline {
      param($AccessToken, $ShowBanner, $Organization)
      $global:MaesterTargetTest.ExchangeConnections++
      $AccessToken | Should -Be 'offline-token'
    }
    $savedEnvironment = @{}
    foreach ($name in 'AZURE_RESOURCE_GROUP', 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_LOCATION') {
      $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
  }
  AfterAll {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-Module Maester-PreUp, Maester-SetupHelpers -Force -ErrorAction SilentlyContinue
    Remove-Item function:az, function:azd, function:Connect-ExchangeOnline
    Remove-Variable MaesterTargetTest -Scope Global
  }
  BeforeEach {
    Import-Module (Join-Path $hooksRoot 'Maester-SetupHelpers.psm1') -Force
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $null) }
    $subscription = '11111111-1111-4111-8111-111111111111'
    $selectedTenant = '22222222-2222-4222-8222-222222222222'
    $global:MaesterTargetTest = @{
      Subscription = $subscription; Tenant = $selectedTenant; Creates = 0; ExchangeConnections = 0; ExchangeMutations = 0
      Calls = [Collections.Generic.List[string]]::new(); ReadFailure = $false; Malformed = $false; TokenFailure = $false
      Token = 'offline-token'; TokenTenant = $selectedTenant; TokenSubscription = $subscription; Exists = 'false'
      Metadata = @{ id = "/subscriptions/$subscription"; subscriptionId = $subscription; tenantId = $selectedTenant; displayName = 'Selected subscription'; state = 'Enabled' }
      AzdValues = @{ AZURE_RESOURCE_GROUP = 'selected-group'; AZURE_SUBSCRIPTION_ID = $subscription; AZURE_TENANT_ID = $selectedTenant; AZURE_LOCATION = 'westus' }
    }
  }

  It 'validates the selected missing group and defers creation to ownership-aware preprovision' {
    & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1')
    $global:MaesterTargetTest.Creates | Should -Be 0
    $global:MaesterTargetTest.Calls.Count | Should -Be 2
    $global:MaesterTargetTest.Calls[0] | Should -BeLike 'rest *'
    $global:MaesterTargetTest.Calls[1] | Should -BeLike 'group exists *'
  }

  It 'respects an environment tenant override and refuses the actual preup write in another tenant' {
    $env:AZURE_TENANT_ID = '33333333-3333-4333-8333-333333333333'
    { & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1') } | Should -Throw '*not selected tenant*'
    $global:MaesterTargetTest.Creates | Should -Be 0
    @($global:MaesterTargetTest.Calls | Where-Object { $_ -like 'group *' }).Count | Should -Be 0
  }

  It 'rejects <case> before the actual preup creation path' -ForEach @(
    @{ case = 'Disabled despite cached Enabled'; field = 'state'; value = 'Disabled' }
    @{ case = 'unknown state'; field = 'state'; value = 'FutureState' }
    @{ case = 'missing state'; field = 'state'; value = $null }
    @{ case = 'missing tenant'; field = 'tenantId'; value = $null }
    @{ case = 'invalid tenant'; field = 'tenantId'; value = 'bad' }
    @{ case = 'wrong tenant'; field = 'tenantId'; value = '33333333-3333-4333-8333-333333333333' }
    @{ case = 'wrong subscription'; field = 'subscriptionId'; value = '44444444-4444-4444-8444-444444444444' }
    @{ case = 'wrong ARM identity'; field = 'id'; value = '/subscriptions/44444444-4444-4444-8444-444444444444' }
    @{ case = 'missing name'; field = 'displayName'; value = $null }
  ) {
    $global:MaesterTargetTest.Metadata[$field] = $value
    { & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1') } | Should -Throw
    $global:MaesterTargetTest.Creates | Should -Be 0
  }

  It 'fails closed on a failed or malformed metadata read' -ForEach @('ReadFailure', 'Malformed') {
    $global:MaesterTargetTest[$_] = $true
    { & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1') } | Should -Throw
    $global:MaesterTargetTest.Creates | Should -Be 0
  }

  It 'rejects missing or invalid expected context without invoking Azure' -ForEach @(
    @{ field = 'AZURE_TENANT_ID'; value = '' }
    @{ field = 'AZURE_TENANT_ID'; value = 'invalid' }
    @{ field = 'AZURE_SUBSCRIPTION_ID'; value = '' }
    @{ field = 'AZURE_SUBSCRIPTION_ID'; value = 'invalid' }
  ) {
    $global:MaesterTargetTest.AzdValues[$field] = $value
    { & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1') } | Should -Throw
    $global:MaesterTargetTest.Calls.Count | Should -Be 0
  }

  It 'preserves the account-shaped context return fields and optionally derives the tenant from ARM' {
    $context = Get-AzCliSubscriptionContext -SubscriptionId $global:MaesterTargetTest.Subscription
    $context.id | Should -Be $global:MaesterTargetTest.Subscription
    $context.tenantId | Should -Be $global:MaesterTargetTest.Tenant
    $context.name | Should -Be 'Selected subscription'
    $context.state | Should -Be 'Enabled'
  }

  It 'requests the Outlook token with the selected tenant and connects without interactive fallback' {
    Connect-ExchangeOnlineSilent -Organization 'selected.onmicrosoft.com' -TenantId $global:MaesterTargetTest.Tenant
    $global:MaesterTargetTest.ExchangeConnections | Should -Be 1
    $global:MaesterTargetTest.Calls.Count | Should -Be 1
    $global:MaesterTargetTest.Calls[0] | Should -BeLike "account get-access-token --resource https://outlook.office365.com *--tenant $($global:MaesterTargetTest.Tenant)"
  }

  It 'does not reach Exchange mutations when required context/token is unavailable or invalid: <case>' -ForEach @(
    @{ case = 'missing tenant'; tenant = '' }
    @{ case = 'invalid tenant'; tenant = 'invalid' }
    @{ case = 'failed token'; tenant = '22222222-2222-4222-8222-222222222222' }
    @{ case = 'missing token tenant'; tenant = '22222222-2222-4222-8222-222222222222' }
    @{ case = 'empty token'; tenant = '22222222-2222-4222-8222-222222222222' }
    @{ case = 'wrong token tenant'; tenant = '22222222-2222-4222-8222-222222222222' }
  ) {
    if ($case -eq 'failed token') { $global:MaesterTargetTest.TokenFailure = $true }
    if ($case -eq 'missing token tenant') { $global:MaesterTargetTest.TokenTenant = $null }
    if ($case -eq 'empty token') { $global:MaesterTargetTest.Token = '' }
    if ($case -eq 'wrong token tenant') { $global:MaesterTargetTest.TokenTenant = '33333333-3333-4333-8333-333333333333' }
    { Connect-ExchangeOnlineSilent -TenantId $tenant; $global:MaesterTargetTest.ExchangeMutations++ } | Should -Throw
    $global:MaesterTargetTest.ExchangeConnections | Should -Be 0
    $global:MaesterTargetTest.ExchangeMutations | Should -Be 0
  }

  It 'refuses unscoped token and login helpers without invoking Azure' {
    { Get-AzCliAccessToken -Resource 'https://outlook.office365.com' } | Should -Throw '*explicit*'
    { Confirm-AzureLogin } | Should -Throw '*explicit*'
    $global:MaesterTargetTest.Calls.Count | Should -Be 0
  }

  It 'proves both supplied selectors before using the mutually exclusive subscription token selector' {
    Get-AzCliAccessToken -Resource 'https://management.azure.com/' -SubscriptionId $global:MaesterTargetTest.Subscription -TenantId $global:MaesterTargetTest.Tenant | Should -Be 'offline-token'
    $global:MaesterTargetTest.Calls.Count | Should -Be 2
    $global:MaesterTargetTest.Calls[1] | Should -BeLike "*--subscription $($global:MaesterTargetTest.Subscription)"
    $global:MaesterTargetTest.Calls[1] | Should -Not -BeLike '*--tenant*'
  }

  It 'does not acquire a token for a mismatched tenant/subscription pair' {
    { Get-AzCliAccessToken -Resource 'https://management.azure.com/' -SubscriptionId $global:MaesterTargetTest.Subscription -TenantId '33333333-3333-4333-8333-333333333333' } | Should -Throw '*not selected tenant*'
    @($global:MaesterTargetTest.Calls | Where-Object { $_ -like 'account get-access-token*' }).Count | Should -Be 0
  }

  It 'does not reuse a previous successful Enabled read' {
    $null = Get-AzCliSubscriptionContext -SubscriptionId $global:MaesterTargetTest.Subscription -TenantId $global:MaesterTargetTest.Tenant
    $global:MaesterTargetTest.Metadata.state = 'Disabled'
    { & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1') } | Should -Throw '*must currently be Enabled*'
    $global:MaesterTargetTest.Creates | Should -Be 0
    @($global:MaesterTargetTest.Calls | Where-Object { $_ -like 'rest *' }).Count | Should -Be 2
  }

  It 'rejects a token response for a different subscription' {
    $global:MaesterTargetTest.TokenSubscription = '44444444-4444-4444-8444-444444444444'
    Get-AzCliAccessToken -Resource 'https://management.azure.com/' -SubscriptionId $global:MaesterTargetTest.Subscription | Should -BeNullOrEmpty
  }

  It 'keeps an existing group without requiring a creation location' {
    $global:MaesterTargetTest.Exists = 'true'
    $global:MaesterTargetTest.AzdValues.AZURE_LOCATION = ''
    & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1')
    $global:MaesterTargetTest.Creates | Should -Be 0
    $global:MaesterTargetTest.Calls.Count | Should -Be 2
  }

  It 'does not create a group on an unknown existence response' {
    $global:MaesterTargetTest.Exists = 'unknown'
    { & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1') } | Should -Throw '*Invalid existence response*'
    $global:MaesterTargetTest.Creates | Should -Be 0
  }

  It 'keeps the no-resource-group preup no-op' {
    $global:MaesterTargetTest.AzdValues = @{}
    & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Run-AzdPreUp.ps1')
    $global:MaesterTargetTest.Calls.Count | Should -Be 0
  }

}
