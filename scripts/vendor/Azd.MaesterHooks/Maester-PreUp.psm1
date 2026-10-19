# Shared preup helpers for azd-maester solutions.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Maester-Helpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester-SetupHelpers.psm1') -Force

function Get-ValueFromEnvironmentOrAzd {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [hashtable]$AzdValues
  )

  $fromEnvironment = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
    return $fromEnvironment
  }

  return (Get-AzdEnvironmentValue -Values $AzdValues -Name $Name)
}

function Invoke-MaesterPreUp {
  [CmdletBinding()]
  param()

  $envValues = Get-AzdEnvironmentValues

  $resourceGroupName = Get-ValueFromEnvironmentOrAzd -Name 'AZURE_RESOURCE_GROUP' -AzdValues $envValues
  if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
    return
  }

  $subscriptionId = Get-ValueFromEnvironmentOrAzd -Name 'AZURE_SUBSCRIPTION_ID' -AzdValues $envValues
  if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw "AZURE_SUBSCRIPTION_ID is required to resolve resource group '$resourceGroupName'."
  }

  $tenantId = Get-ValueFromEnvironmentOrAzd -Name 'AZURE_TENANT_ID' -AzdValues $envValues
  if ([string]::IsNullOrWhiteSpace($tenantId)) {
    throw "AZURE_TENANT_ID is required to resolve resource group '$resourceGroupName'."
  }
  $context = Get-AzCliSubscriptionContext -SubscriptionId $subscriptionId -TenantId $tenantId
  $subscriptionId = $context.id

  $exists = (& az group exists --name $resourceGroupName --subscription $subscriptionId -o tsv 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($exists)) {
    throw "Failed to check whether resource group '$resourceGroupName' exists."
  }

  if ($exists.Trim().ToLowerInvariant() -eq 'true') {
    Write-Host "Using existing resource group '$resourceGroupName'."
    return
  }

  if ($exists.Trim().ToLowerInvariant() -ne 'false') {
    throw "Invalid existence response for resource group '$resourceGroupName'."
  }

  # Preup is read-only. Creating here would predate the durable fresh-RG
  # receipt and make a normal azd up indistinguishable from a reused group.
  # The preprovision hook creates only after the wizard and exact target checks,
  # through Initialize-MaesterInfrastructureOwnership's pending/HTTP-201 path.
  Write-Host "Resource group '$resourceGroupName' is absent. Creation is deferred to ownership-aware preprovision."

}

Export-ModuleMember -Function Invoke-MaesterPreUp
