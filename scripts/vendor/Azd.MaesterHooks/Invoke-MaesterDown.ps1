# Shared actual azd hook entrypoint. Keep provider handlers in their narrow modules.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('PreDown','PostDown')][string]$Phase,
  [Parameter(Mandatory)][string]$ProjectRoot,
  [Parameter(Mandatory)][string]$SolutionName,
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
if ($EnvironmentName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'An explicit selected azd EnvironmentName is required for down; no default environment is inferred.' }
foreach ($id in @($TenantId,$SubscriptionId)) {
  $parsed = [guid]::Empty
  if (-not [guid]::TryParse($id,[ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'Explicit selected tenant and subscription GUIDs are required for down.' }
}
if ($AllowGraphContextReplacement -and -not $AllowInteractiveGraphLogin) { throw 'Context replacement requires explicit interactive Graph login approval.' }
if ($Phase -eq 'PreDown' -and ($ApprovedPlanHash -or $AllowInteractiveGraphLogin -or $AllowGraphContextReplacement)) { throw 'Predown does not authenticate Graph or approve external deletion.' }
if ($Phase -eq 'PostDown' -and $ApprovedUnlockPlanHash) { throw 'Resource-lock approval belongs only to predown.' }
Import-Module (Join-Path $PSScriptRoot 'Maester-InfrastructureOwnership.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Maester-PreDownCleanup.psm1') -ErrorAction Stop
$infraArgs = @{ProjectRoot=$ProjectRoot;EnvironmentName=$EnvironmentName;SolutionName=$SolutionName;TenantId=$TenantId;SubscriptionId=$SubscriptionId}
if ($ResourceGroupName) { $infraArgs.ResourceGroupName=$ResourceGroupName }
$infra = Resolve-MaesterInfrastructureBinding @infraArgs
$journalPath = Join-Path ([IO.Path]::GetFullPath($ProjectRoot)) ".azure/$EnvironmentName/maester-setup-ownership.json"
$hasJournal = Test-Path -LiteralPath $journalPath
if ($hasJournal -and -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'The external ownership journal path is not a regular file.' }
if (-not $hasJournal -and $infra.ExternalSetupStarted) { throw 'External setup previously started but its ownership journal is missing. Automatic down is blocked; recover the original receipt first.' }
$binding = if ($hasJournal) {
  Resolve-MaesterCleanupBinding -ProjectRoot $ProjectRoot -EnvironmentName $EnvironmentName -SolutionName $SolutionName -TenantId $TenantId -SubscriptionId $SubscriptionId
} else {
  @{environmentName=$EnvironmentName;solutionName=$SolutionName;tenantId=$infra.TenantId;subscriptionId=$infra.SubscriptionId;resourceGroupId=$infra.ResourceGroupId}
}
if ($binding.resourceGroupId -ine $infra.ResourceGroupId) { throw 'External and infrastructure ownership receipts identify different resource groups.' }
if ($Phase -eq 'PreDown') {
  if ($hasJournal) {
    if ($PlanOnly) { $InteractiveConsent=$false; $ApprovedUnlockPlanHash='' }
    return Test-MaesterOwnedCleanupPreDown -ProjectRoot $ProjectRoot -Binding $binding -ApprovedUnlockPlanHash $ApprovedUnlockPlanHash -InteractiveConsent:$InteractiveConsent -PlanOnly:$PlanOnly
  }
  $inventory = Test-MaesterInfrastructureOwnership @infraArgs
  if (-not $inventory.SafeToUnlock) { throw "Infrastructure ownership validation blocked down: $($inventory.BlockingReason)" }
  Write-Host ($inventory | ConvertTo-Json -Depth 8)
  if (-not $inventory.SafeToDelete) {
    if ($PlanOnly) { return $inventory }
    if ($ApprovedUnlockPlanHash) {
      if ($ApprovedUnlockPlanHash -cne $inventory.PlanHash) { throw 'The lock-removal approval hash does not match the current plan.' }
    } elseif ($InteractiveConsent) {
      if ($env:CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected) { throw 'Noninteractive lock removal requires an exact approved plan hash.' }
      Write-Host 'Canceling the later azd deletion leaves these explicitly approved locks removed. Azure resources and authorization are unchanged by unlocking.'
      $answer = Read-Host 'Remove only the exact owned locks in this plan? [y/N]'
      if ($answer -notmatch '^(?i:y|yes)$') { throw 'Owned lock removal was not approved.' }
      $ApprovedUnlockPlanHash=$inventory.PlanHash
    } else { throw "Review the lock plan and pass -ApprovedUnlockPlanHash '$($inventory.PlanHash)' or -InteractiveConsent." }
    $null = Unlock-MaesterInfrastructureLocks @infraArgs -ApprovedPlanHash $ApprovedUnlockPlanHash
    $inventory = Test-MaesterInfrastructureOwnership @infraArgs
    if (-not $inventory.SafeToDelete) { throw "Infrastructure remains blocked after unlock: $($inventory.BlockingReason)" }
  }
  Write-Host $inventory.DeletionWarning
  Write-Host 'No external setup was started. Predown does not delete external authentication or access.'
  return $inventory
}
# A direct postdown invocation is not authority: prove exact Azure absence first.
$null = Test-MaesterCleanupAzureAbsent -Binding $binding
if (-not $hasJournal) {
  Write-Host 'The exact owned Azure resource group is absent; no external setup was started. Infrastructure receipt retained.'
  return @{Completed=$true;ExternalSetupStarted=$false;ResourceGroupId=$binding.resourceGroupId}
}
$scopes = @(Get-MaesterOwnedCleanupScopes -ProjectRoot $ProjectRoot -Binding $binding)
Write-Host "Selected teardown delegated Graph scopes: $($scopes -join ', ')"
if ($InteractiveConsent -and -not $AllowInteractiveGraphLogin -and $scopes.Count) {
  if ($env:CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected) { throw 'Interactive teardown login is unavailable; explicitly select the existing Process session or normal browser-login option.' }
  Write-Host 'These scopes must already have separately approved administrator consent. Stop if sign-in requests new consent or unexpected device-code authentication. Process token caching still uses the SDK shared authentication-record file.'
  $answer = Read-Host "Allow normal browser sign-in if needed for setup account '$env:MAESTER_SETUP_ACCOUNT' in tenant '$TenantId', using only the scopes listed above? [y/N]"
  $AllowInteractiveGraphLogin = $answer -match '^(?i:y|yes)$'
}
$cleanup = @{ProjectRoot=$ProjectRoot;Binding=$binding;AllowInteractiveGraphLogin=$AllowInteractiveGraphLogin;AllowGraphContextReplacement=$AllowGraphContextReplacement}
if ($PlanOnly) { return Get-MaesterOwnedCleanupPlan @cleanup }
return Invoke-MaesterOwnedCleanupPostDown @cleanup -ApprovedPlanHash $ApprovedPlanHash -InteractiveConsent:$InteractiveConsent
