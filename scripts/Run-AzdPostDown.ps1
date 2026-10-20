#Requires -Version 7.6
[CmdletBinding()]
param(
  [string]$EnvironmentName = $env:AZURE_ENV_NAME,
  [string]$TenantId = $env:AZURE_TENANT_ID,
  [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
  [string]$ResourceGroupName,
  [string]$ApprovedUnlockPlanHash,
  [string]$ApprovedPlanHash,
  [switch]$InteractiveConsent,
  [switch]$AllowInteractiveGraphLogin,
  [switch]$AllowGraphContextReplacement,
  [switch]$PlanOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$parameters = @{} + $PSBoundParameters
foreach ($name in @('EnvironmentName','TenantId','SubscriptionId')) { $parameters[$name] = Get-Variable -Name $name -ValueOnly }
& (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Invoke-MaesterDown.ps1') @parameters `
  -Phase PostDown -ProjectRoot (Split-Path $PSScriptRoot -Parent) -SolutionName 'azure-devops'
