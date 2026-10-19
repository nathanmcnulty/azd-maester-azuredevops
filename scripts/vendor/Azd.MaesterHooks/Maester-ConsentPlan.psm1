Set-StrictMode -Version Latest

function ConvertTo-MaesterCanonicalValue {
  param([AllowNull()]$Value, [int]$Depth = 0)
  if ($Depth -gt 32) { throw 'Consent details exceed the supported nesting depth.' }
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
    if ($Value -is [System.Collections.IDictionary]) { $keys = [string[]]@($Value.Keys) } else { $keys = [string[]]@($Value.PSObject.Properties | ForEach-Object Name) }
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $ordered = [ordered]@{}
    foreach ($key in $keys) {
      if ($Value -is [System.Collections.IDictionary]) { $item = $Value[$key] } else { $item = $Value.$key }
      $ordered[$key] = ConvertTo-MaesterCanonicalValue -Value $item -Depth ($Depth + 1)
    }
    return $ordered
  }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($item in $Value) { $items.Add((ConvertTo-MaesterCanonicalValue -Value $item -Depth ($Depth + 1))) }
    return ,$items.ToArray()
  }
  return $Value
}

function New-MaesterConsentPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$PrincipalObjectId,
    [Parameter(Mandatory)][string]$Capability,
    [Parameter(Mandatory)][string]$ManifestVersion,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ManifestSha256,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Desired,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Missing,
    [hashtable]$Details = @{}
  )
  if ($TenantId -eq [guid]::Empty -or $PrincipalObjectId -eq [guid]::Empty) {
    throw 'A consent plan requires explicit non-empty tenant and principal identities.'
  }
  $desiredValues = @($Desired | Sort-Object -Unique)
  $missingValues = @($Missing | Sort-Object -Unique)
  if (@($missingValues | Where-Object { $_ -notin $desiredValues }).Count) {
    throw 'The proposed consent delta contains an unrequested permission.'
  }
  $orderedDetails = ConvertTo-MaesterCanonicalValue -Value $Details
  $payload = [ordered]@{
    schemaVersion = '1.0'
    tenantId = $TenantId.ToString()
    principalObjectId = $PrincipalObjectId.ToString()
    capability = $Capability
    manifestVersion = $ManifestVersion
    manifestSha256 = $ManifestSha256.ToLowerInvariant()
    desired = $desiredValues
    missing = $missingValues
    details = $orderedDetails
    removalPolicy = 'PreserveExistingGrants'
  }
  $canonical = $payload | ConvertTo-Json -Depth 100 -Compress -WarningAction Stop
  $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
  $payload['planHash'] = $hash
  return [pscustomobject]$payload
}

function Assert-MaesterConsentPlanApproval {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Plan, [AllowEmptyString()][string]$ApprovedPlanHash)

  $details = @{}
  $detailValues = ConvertTo-MaesterCanonicalValue -Value $Plan.details
  foreach ($key in $detailValues.Keys) { $details[$key] = $detailValues[$key] }
  $current = New-MaesterConsentPlan -TenantId $Plan.tenantId -PrincipalObjectId $Plan.principalObjectId `
    -Capability $Plan.capability -ManifestVersion $Plan.manifestVersion -ManifestSha256 $Plan.manifestSha256 `
    -Desired $Plan.desired -Missing $Plan.missing -Details $details
  if ($Plan.schemaVersion -cne '1.0' -or $Plan.removalPolicy -cne 'PreserveExistingGrants' -or $current.planHash -cne $Plan.planHash) {
    throw 'The consent plan was modified after it was generated. Build and review a fresh plan.'
  }
  if (@($Plan.missing).Count -eq 0) { return }
  if ($ApprovedPlanHash -cne $Plan.planHash) {
    throw "Permission expansion requires approval of the current plan hash '$($Plan.planHash)'. Review its tenant, target identity, capability and missing grants, then rerun with -Apply -ApprovedPlanHash. A prior version's approval does not authorize this change."
  }
}

function Confirm-MaesterConsentPlan {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Plan)

  # This validates integrity only; it does not replace the approval below.
  Assert-MaesterConsentPlanApproval -Plan $Plan -ApprovedPlanHash $Plan.planHash
  Write-Host ($Plan | ConvertTo-Json -Depth 100 -WarningAction Stop)
  if (@($Plan.missing).Count -eq 0) { return $Plan.planHash }
  if ($env:CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected) {
    throw 'Non-interactive permission expansion requires an explicit approved plan hash.'
  }
  $answer = Read-Host 'Approve these exact new permissions for this tenant and identity? [y/N]'
  if ($answer -notmatch '^(?i:y|yes)$') { throw 'Permission expansion was not approved. No grants were changed.' }
  return $Plan.planHash
}

Export-ModuleMember -Function New-MaesterConsentPlan, Assert-MaesterConsentPlanApproval, Confirm-MaesterConsentPlan
