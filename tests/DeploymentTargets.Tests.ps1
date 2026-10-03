BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/Resolve-DeploymentTargets.ps1')
  $script:subscriptionId = '11111111-1111-4111-8111-111111111111'
  $script:resourceGroupName = 'rg-maester-test'
  $script:environmentName = 'maester-test'
  $script:solutionName = 'azure-devops'
  $script:scope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"
  $script:storageId = "$scope/providers/Microsoft.Storage/storageAccounts/stmaester123"
  $script:webAppId = "$scope/providers/Microsoft.Web/sites/app-maester-123"

  function Invoke-TargetResolution {
    param([hashtable]$Values, [hashtable]$Resources)
    Resolve-MaesterDeploymentTargets -EnvironmentValues $Values -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -EnvironmentName $environmentName -SolutionName $solutionName -GetResource {
      param($path)
      $id = ($path -split '\?')[0]
      $Resources[$id]
    }
  }

  function New-Resources {
    $tags = [pscustomobject]@{ workload = 'maester'; solution = $solutionName; environment = $environmentName; managedBy = 'azd' }
    @{
      $storageId = [pscustomobject]@{ id = $storageId; name = 'stmaester123'; type = 'Microsoft.Storage/storageAccounts'; tags = $tags }
      $webAppId = [pscustomobject]@{ id = $webAppId; name = 'app-maester-123'; type = 'Microsoft.Web/sites'; kind = 'app'; tags = $tags; properties = @{ defaultHostName = 'app-maester-123.azurewebsites.net' } }
      "$scope/providers/Microsoft.Web/sites/unrelated" = [pscustomobject]@{ id = "$scope/providers/Microsoft.Web/sites/unrelated"; name = 'unrelated'; type = 'Microsoft.Web/sites'; kind = 'app'; tags = @{ solution = 'other' }; properties = @{ defaultHostName = 'unrelated.azurewebsites.net' } }
    }
  }
}

Describe 'Exact deployed resource binding' {
  It 'binds the named storage and Web App, ignoring unrelated sites' {
    $result = Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'true'; INCLUDE_WEB_APP = 'false'; WEB_APP_NAME = 'app-maester-123' } -Resources (New-Resources)
    $result.StorageAccount.id | Should -Be $storageId
    $result.WebApp.id | Should -Be $webAppId
  }

  It 'skips the optional Web App even when unrelated sites exist' {
    $result = Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'false'; INCLUDE_WEB_APP = 'true'; WEB_APP_NAME = 'unrelated' } -Resources (New-Resources)
    $result.WebApp | Should -BeNullOrEmpty
  }

  It 'rejects an absent expected Web App rather than using another site' {
    $resources = New-Resources
    $resources.Remove($webAppId)
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'true'; WEB_APP_NAME = 'app-maester-123' } -Resources $resources } | Should -Throw '*deployed Web App*'
  }

  It 'rejects missing deployment outputs only when the optional Web App is requested' {
    { Invoke-TargetResolution -Values @{ WEB_APP_ENABLED = 'false' } -Resources (New-Resources) } | Should -Throw '*STORAGE_ACCOUNT_NAME*'
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'true' } -Resources (New-Resources) } | Should -Throw '*WEB_APP_NAME*'
  }

  It 'rejects absent authoritative enablement output despite a stale optional name' {
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_NAME = 'unrelated' } -Resources (New-Resources) } | Should -Throw '*WEB_APP_ENABLED*'
  }

  It 'rejects storage absent from its exact scope instead of another account' {
    $resources = New-Resources
    $resources.Remove($storageId)
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'false' } -Resources $resources } | Should -Throw '*deployed storage account*'
  }

  It 'rejects wrong-scope and wrong-type ARM responses' {
    $resources = New-Resources
    $resources[$storageId].id = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/other/providers/Microsoft.Storage/storageAccounts/stmaester123'
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'false' } -Resources $resources } | Should -Throw '*deployed storage account*'
    $resources = New-Resources
    $resources[$webAppId].type = 'Microsoft.Web/sites/slots'
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'true'; WEB_APP_NAME = 'app-maester-123' } -Resources $resources } | Should -Throw '*deployed Web App*'
  }

  It 'rejects a Function App or missing Web App host name' {
    $resources = New-Resources
    $resources[$webAppId].kind = 'functionapp'
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'true'; WEB_APP_NAME = 'app-maester-123' } -Resources $resources } | Should -Throw '*deployed Web App*'
    $resources = New-Resources
    $resources[$webAppId].properties.defaultHostName = ''
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'true'; WEB_APP_NAME = 'app-maester-123' } -Resources $resources } | Should -Throw '*default host name*'
  }

  It 'rejects a different environment tag before selecting storage or Web App' {
    $resources = New-Resources
    $resources[$storageId].tags.environment = 'another-environment'
    { Invoke-TargetResolution -Values @{ STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'false' } -Resources $resources } | Should -Throw '*deployed storage account*'
  }
}

Describe 'Named azd environment access' {
  It 'reads and writes only the explicitly named environment' {
    $script:azdCalls = [System.Collections.Generic.List[string]]::new()
    function azd {
      $script:azdCalls.Add(($args -join ' '))
      $global:LASTEXITCODE = 0
      if ($args[1] -eq 'get-values') {
        return '{"AZURE_ENV_NAME":"maester-test","AZURE_SUBSCRIPTION_ID":"11111111-1111-4111-8111-111111111111","AZURE_RESOURCE_GROUP":"rg-maester-test","STORAGE_ACCOUNT_NAME":"stmaester123","WEB_APP_ENABLED":"false"}'
      }
    }
    try {
      $values = Get-MaesterDeploymentValues -EnvironmentName $environmentName -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName
      $values['STORAGE_ACCOUNT_NAME'] | Should -Be 'stmaester123'
      Set-MaesterAzdEnvValue -EnvironmentName $environmentName -Name 'RECEIPT' -Value 'recorded'
      Set-MaesterAzdEnvJsonArray -EnvironmentName $environmentName -Name 'ROLES' -Values @('b', 'a', 'a')
      $script:azdCalls[0] | Should -Be 'env get-values --output json'
      $script:azdCalls[1] | Should -Be 'env get-values -e maester-test --output json'
      $script:azdCalls[2] | Should -Be 'env set -e maester-test RECEIPT recorded'
      $script:azdCalls[3] | Should -Be 'env set -e maester-test ROLES a;b'
    }
    finally { Remove-Item Function:\azd -ErrorAction SilentlyContinue }
  }

  It 'rejects default environment A before reading named environment B or writing receipts' {
    $script:azdCalls = [System.Collections.Generic.List[string]]::new()
    function azd {
      $script:azdCalls.Add(($args -join ' '))
      $global:LASTEXITCODE = 0
      if ($args -contains '-e') {
        return '{"AZURE_ENV_NAME":"maester-test","AZURE_SUBSCRIPTION_ID":"11111111-1111-4111-8111-111111111111","AZURE_RESOURCE_GROUP":"rg-maester-test"}'
      }
      return '{"AZURE_ENV_NAME":"other","AZURE_SUBSCRIPTION_ID":"11111111-1111-4111-8111-111111111111","AZURE_RESOURCE_GROUP":"rg-maester-test"}'
    }
    try {
      { Get-MaesterDeploymentValues -EnvironmentName $environmentName -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName } | Should -Throw '*default azd environment*'
      $script:azdCalls.Count | Should -Be 1
      $script:azdCalls[0] | Should -Be 'env get-values --output json'
    }
    finally { Remove-Item Function:\azd -ErrorAction SilentlyContinue }
  }

  It 'rejects a mismatched process environment before calling azd' {
    $original = $env:AZURE_ENV_NAME
    $env:AZURE_ENV_NAME = 'other'
    try {
      { Assert-MaesterAzdEnvironmentContext -EnvironmentName $environmentName } | Should -Throw '*process Azure environment*'
    }
    finally { $env:AZURE_ENV_NAME = $original }
  }
}

Describe 'Entra application lookup' {
  It 'accepts one exact match and returns none for no match' {
    $application = [pscustomobject]@{ id = 'owned-app'; appId = '11111111-1111-4111-8111-111111111111' }
    (Select-UniqueMaesterApplication -Response ([pscustomobject]@{ value = @($application) }) -DisplayName 'maester').id | Should -Be 'owned-app'
    Select-UniqueMaesterApplication -Response @{ value = @() } -DisplayName 'maester' | Should -BeNullOrEmpty
  }

  It 'rejects duplicate matches and an incomplete first page' {
    { Select-UniqueMaesterApplication -Response @{ value = @(@{ id = 'one' }, @{ id = 'two' }) } -DisplayName 'maester' } | Should -Throw '*Multiple Entra applications*'
    { Select-UniqueMaesterApplication -Response @{ value = @(@{ id = 'one' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/applications?page=2' } -DisplayName 'maester' } | Should -Throw '*incomplete*'
  }

  It 'rejects null, missing, and non-collection Graph response values before creation' {
    { Select-UniqueMaesterApplication -Response $null -DisplayName 'maester' } | Should -Throw '*no response*'
    { Select-UniqueMaesterApplication -Response ([pscustomobject]@{ value = $null }) -DisplayName 'maester' } | Should -Throw '*complete value collection*'
    { Select-UniqueMaesterApplication -Response ([pscustomobject]@{ other = 'field' }) -DisplayName 'maester' } | Should -Throw '*complete value collection*'
    { Select-UniqueMaesterApplication -Response ([pscustomobject]@{ value = 'not-an-array' }) -DisplayName 'maester' } | Should -Throw '*complete value collection*'
  }
}
