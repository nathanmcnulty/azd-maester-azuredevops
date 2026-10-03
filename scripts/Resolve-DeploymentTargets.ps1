function Assert-MaesterAzdEnvironmentContext {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EnvironmentName)

  if ($env:AZURE_ENV_NAME -and $env:AZURE_ENV_NAME -ine $EnvironmentName) {
    throw 'The process Azure environment differs from the requested azd environment.'
  }
  $defaultValues = & azd env get-values --output json | ConvertFrom-Json -AsHashtable
  if ($LASTEXITCODE -ne 0 -or -not $defaultValues -or $defaultValues['AZURE_ENV_NAME'] -ine $EnvironmentName) {
    throw 'The default azd environment differs from the requested environment.'
  }
  return $defaultValues
}

function Get-MaesterDeploymentValues {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$ResourceGroupName)

  Assert-MaesterAzdEnvironmentContext -EnvironmentName $EnvironmentName | Out-Null
  $values = & azd env get-values -e $EnvironmentName --output json | ConvertFrom-Json -AsHashtable
  if ($LASTEXITCODE -ne 0 -or -not $values -or $values['AZURE_ENV_NAME'] -ine $EnvironmentName -or
      $values['AZURE_SUBSCRIPTION_ID'] -ine $SubscriptionId -or
      ($values['AZURE_RESOURCE_GROUP'] -and $values['AZURE_RESOURCE_GROUP'] -ine $ResourceGroupName)) {
    throw 'The requested azd environment and selected Azure subscription/resource group could not be verified.'
  }
  return $values
}

function Set-MaesterAzdEnvValue {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value)

  & azd env set -e $EnvironmentName $Name $Value | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to persist $Name to azd environment '$EnvironmentName'." }
}

function Set-MaesterAzdEnvJsonArray {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][string[]]$Values = @())

  $serialized = (@($Values) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ';'
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name $Name -Value $serialized
}

function Resolve-MaesterDeploymentTargets {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName,
    [Parameter(Mandatory)][scriptblock]$GetResource
  )

  $storageName = [string]$EnvironmentValues['STORAGE_ACCOUNT_NAME']
  if ($storageName -cnotmatch '^[a-z0-9]{3,24}$') {
    throw 'Deployment output STORAGE_ACCOUNT_NAME is missing or invalid.'
  }
  $includeWebApp = [string]$EnvironmentValues['WEB_APP_ENABLED']
  if ($includeWebApp -notin @('true', 'false')) {
    throw 'Deployment output WEB_APP_ENABLED must be true or false.'
  }

  $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
  $storageId = "$scope/providers/Microsoft.Storage/storageAccounts/$storageName"
  $storage = & $GetResource "${storageId}?api-version=2023-05-01"
  if (-not $storage -or $storage.id -ine $storageId -or $storage.name -ine $storageName -or $storage.type -ine 'Microsoft.Storage/storageAccounts' -or
      -not $storage.tags -or $storage.tags.workload -ine 'maester' -or $storage.tags.solution -ine $SolutionName -or
      $storage.tags.environment -ine $EnvironmentName -or $storage.tags.managedBy -ine 'azd') {
    throw "The deployed storage account '$storageName' was not found at its exact subscription and resource-group scope."
  }

  $webApp = $null
  if ($includeWebApp -eq 'true') {
    $webAppName = [string]$EnvironmentValues['WEB_APP_NAME']
    if ($webAppName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,58}[a-zA-Z0-9]$') {
      throw 'Deployment output WEB_APP_NAME is missing or invalid for WEB_APP_ENABLED=true.'
    }
    $webAppId = "$scope/providers/Microsoft.Web/sites/$webAppName"
    $webApp = & $GetResource "${webAppId}?api-version=2023-12-01"
    if (-not $webApp -or $webApp.id -ine $webAppId -or $webApp.name -ine $webAppName -or $webApp.type -ine 'Microsoft.Web/sites' -or
        -not $webApp.tags -or $webApp.tags.workload -ine 'maester' -or $webApp.tags.solution -ine $SolutionName -or
        $webApp.tags.environment -ine $EnvironmentName -or $webApp.tags.managedBy -ine 'azd' -or $webApp.kind -like '*functionapp*') {
      throw "The deployed Web App '$webAppName' was not found at its exact subscription and resource-group scope."
    }
    if ([string]::IsNullOrWhiteSpace([string]$webApp.properties.defaultHostName)) {
      throw "The deployed Web App '$webAppName' has no default host name."
    }
  }

  return [pscustomobject]@{ StorageAccount = $storage; WebApp = $webApp }
}

function Select-UniqueMaesterApplication {
  [CmdletBinding()]
  param($Response, [Parameter(Mandatory)][string]$DisplayName)

  if (-not $Response) { throw "The Entra application lookup for '$DisplayName' returned no response." }
  $value = $null
  if ($Response -is [System.Collections.IDictionary]) {
    $value = $Response['value']
  }
  else {
    $property = $Response.PSObject.Properties['value']
    if ($property) { $value = $property.Value }
  }
  if ($null -eq $value -or $value -isnot [System.Collections.IList]) {
    throw "The Entra application lookup for '$DisplayName' returned no complete value collection."
  }
  $nextLink = $null
  if ($Response -is [System.Collections.IDictionary]) {
    $nextLink = $Response['@odata.nextLink']
  }
  elseif ($Response) {
    $nextLinkProperty = $Response.PSObject.Properties['@odata.nextLink']
    if ($nextLinkProperty) { $nextLink = $nextLinkProperty.Value }
  }
  if ($nextLink) {
    throw "The Entra application lookup for '$DisplayName' is incomplete."
  }
  $matches = @($value)
  if ($matches.Count -gt 1) {
    throw "Multiple Entra applications match '$DisplayName'."
  }
  if ($matches.Count -eq 1) {
    return $matches[0]
  }
  return $null
}
