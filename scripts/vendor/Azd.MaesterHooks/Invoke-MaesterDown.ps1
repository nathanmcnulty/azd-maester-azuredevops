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
$canPrompt = -not ($env:CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected)
if ($Phase -eq 'PreDown') {
  if ($hasJournal) {
    if (-not $PlanOnly -and $InteractiveConsent) {
      $remainingScopes = @(Get-MaesterOwnedCleanupScopes -ProjectRoot $ProjectRoot -Binding $binding)
      if ($remainingScopes.Count) {
        if (-not $canPrompt) { throw 'Interactive postdown cleanup is required for the remaining ownership records, but this process cannot prompt. Down stopped before changing owned locks or Azure resources. Run azd down in an interactive terminal without --no-prompt. Postdown runs in a separate PowerShell process and may require a fresh sign-in to the approved setup client, account, tenant and selected scopes; a parent Process session is not transferred. Explicit noninteractive cleanup requires its own verified session and fresh exact plan approval.' }
        Write-Host 'Postdown runs in a separate PowerShell process. It may require a fresh normal-browser sign-in to the approved setup client, account, tenant and selected cleanup scopes, followed by separate cleanup approval. A parent Process session is not transferred. If postdown is declined or fails, Azure may already be removed and the cleanup receipts remain for recovery.'
      }
    }
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
      if (-not $canPrompt) { throw 'Noninteractive lock removal requires an exact approved plan hash.' }
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
  if (-not $canPrompt) {
    $literalRoot=$ProjectRoot.Replace("'", "''")
    $entrypoint=$PSCommandPath.Replace("'", "''")
    $retry="& '$entrypoint' -Phase PostDown -ProjectRoot '$literalRoot' -EnvironmentName '$EnvironmentName' -SolutionName '$SolutionName' -TenantId '$TenantId' -SubscriptionId '$SubscriptionId' -InteractiveConsent"
    throw "Azure has been removed; external cleanup is incomplete and the ownership journal is retained. Interactive teardown login is unavailable in this process. Use this entrypoint in an interactive terminal to select fresh normal-browser sign-in if needed and separately approve the fresh cleanup plan: $retry. Explicit noninteractive cleanup requires a verified session in this same process and fresh exact plan approval; a parent Process session is not transferred to an azd hook."
  }
  Write-Host 'These scopes must already have separately approved administrator consent. Stop if sign-in requests new consent or unexpected device-code authentication. Process token caching still uses the SDK shared authentication-record file.'
  $answer = Read-Host "Allow normal browser sign-in if needed for setup account '$env:MAESTER_SETUP_ACCOUNT' in tenant '$TenantId', using only the scopes listed above? [y/N]"
  $AllowInteractiveGraphLogin = $answer -match '^(?i:y|yes)$'
}
$cleanup = @{ProjectRoot=$ProjectRoot;Binding=$binding;AllowInteractiveGraphLogin=$AllowInteractiveGraphLogin;AllowGraphContextReplacement=$AllowGraphContextReplacement}
if ($PlanOnly) { return Get-MaesterOwnedCleanupPlan @cleanup }
return Invoke-MaesterOwnedCleanupPostDown @cleanup -ApprovedPlanHash $ApprovedPlanHash -InteractiveConsent:$InteractiveConsent
