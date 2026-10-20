# Ownership-aware down hooks. Configuration values and display names never prove ownership.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Maester-SetupHelpers.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Maester-OwnershipJournal.psm1') -ErrorAction Stop

$script:CleanupKinds = @('GraphAppRoleAssignment','DirectoryRoleAssignment','AzureRoleAssignment','ExchangeServicePrincipal','ExchangeRoleAssignment','EntraApplication','EntraServicePrincipal','FederatedIdentityCredential','OAuth2PermissionGrant','ApplicationConfiguration','WebAppAuthConfiguration','AdoRepository','AdoServiceConnection','AdoServiceConnectionBinding','AdoPipeline','AdoPipelineAuthorization','AdoRepositoryPublication','ResourceLock')
$script:CleanupRank = @{ GraphAppRoleAssignment=10; DirectoryRoleAssignment=10; AzureRoleAssignment=10; ExchangeRoleAssignment=10; OAuth2PermissionGrant=10; FederatedIdentityCredential=10; AdoPipelineAuthorization=15; ApplicationConfiguration=15; WebAppAuthConfiguration=15; AdoRepositoryPublication=15; AdoServiceConnectionBinding=15; AdoPipeline=20; ExchangeServicePrincipal=25; AdoServiceConnection=30; AdoRepository=40; EntraServicePrincipal=50; EntraApplication=60; ResourceLock=70 }

function Get-MaesterCleanupField {
  param($Value, [string]$Name, $Default = $null)
  $result=$Default
  if ($null -ne $Value) {
    if ($Value -is [Collections.IDictionary]) { if ($Value.Contains($Name)) { $result=$Value[$Name] } }
    else { $property=$Value.PSObject.Properties[$Name]; if ($null -ne $property) { $result=$property.Value } }
  }
  if ($result -is [Collections.IList]) { return ,$result }
  return $result
}

function Test-MaesterCleanupHasField {
  param($Value, [string]$Name)
  if ($null -eq $Value) { return $false }
  if ($Value -is [Collections.IDictionary]) { return $Value.Contains($Name) }
  return $null -ne $Value.PSObject.Properties[$Name]
}

function ConvertTo-MaesterCleanupCanonicalJson {
  param($Value)
  function Convert-CleanupCanonical($item) {
    if ($null -eq $item) { return $null }
    if ($item -is [Collections.IDictionary] -or $item -is [pscustomobject]) {
      $map = [ordered]@{}
      $keys = [string[]]@()
      if ($item -is [Collections.IDictionary]) { $keys = [string[]]@($item.Keys) } else { $keys = [string[]]@($item.PSObject.Properties.Name) }
      [Array]::Sort($keys, [StringComparer]::Ordinal)
      foreach ($key in $keys) { $map[$key] = Convert-CleanupCanonical (Get-MaesterCleanupField $item $key) }
      return $map
    }
    if ($item -is [Collections.IList]) { $items = @(); foreach ($child in $item) { $items += ,(Convert-CleanupCanonical $child) }; return ,$items }
    return $item
  }
  return (Convert-CleanupCanonical $Value | ConvertTo-Json -Depth 24 -Compress -WarningAction Stop)
}

function Get-MaesterCleanupHash {
  param($Value)
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-MaesterCleanupCanonicalJson $Value)))).ToLowerInvariant()
}

function Get-MaesterCleanupHttpStatus {
  param([Management.Automation.ErrorRecord]$ErrorRecord)
  # Only numeric provider status is authoritative. Never classify by error text.
  foreach ($value in @((Get-MaesterCleanupField $ErrorRecord.Exception 'ResponseStatusCode'), (Get-MaesterCleanupField (Get-MaesterCleanupField $ErrorRecord.Exception 'Response') 'StatusCode'))) {
    if ($null -ne $value) { try { return [int]$value } catch {} }
  }
  return 0
}

function Assert-MaesterCleanupArmId {
  param([string]$Id)
  $subscriptionPath = $Id -match '^/subscriptions/[0-9a-f-]{36}(?:/[A-Za-z0-9_().-]+)*$'
  $managementGroupPath = $Id -match '^/providers/Microsoft.Management/managementGroups/[A-Za-z0-9_().-]+/providers/Microsoft.Authorization/roleAssignments/[0-9a-f-]{36}$'
  if ((-not $subscriptionPath -and -not $managementGroupPath) -or $Id.Contains('//') -or $Id -match '(^|/)\.{1,2}(/|$)') {
    throw 'Cleanup ARM target contains an unsupported or unsafe path.'
  }
}

function Invoke-MaesterCleanupArmRequest {
  param($Binding, [ValidateSet('GET','DELETE')][string]$Method, [string]$ResourceId, [string]$ApiVersion, [string]$Query = '')
  Assert-MaesterCleanupArmId $ResourceId
  if ($ApiVersion -notmatch '^20[0-9]{2}-[0-9]{2}-[0-9]{2}(?:-preview)?$' -or ($Query -and $Query -notmatch '^&\$filter=principalId%20eq%20%27[0-9a-f-]{36}%27$')) { throw 'Unsafe cleanup ARM query.' }
  $targetSubscription=$Binding.subscriptionId
  if ($ResourceId -match '^/subscriptions/([0-9a-f-]{36})(?:/|$)') { $targetSubscription=$Matches[1] }
  $token = Get-AzCliAccessToken -Resource 'https://management.azure.com/' -SubscriptionId $targetSubscription -TenantId $Binding.tenantId
  if (-not $token) { throw 'Current tenant-bound ARM authentication is required for cleanup.' }
  $status = 0
  $value = Invoke-RestMethod -Method $Method -Uri "https://management.azure.com${ResourceId}?api-version=$ApiVersion$Query" -Headers @{Authorization="Bearer $token"} -SkipHttpErrorCheck -StatusCodeVariable status -ResponseHeadersVariable responseHeaders -ErrorAction Stop
  if ($status -eq 404) { return @{StatusCode=404; Value=$null} }
  if ($null -ne $responseHeaders -and $responseHeaders.ContainsKey('x-ms-continuationtoken') -and @($responseHeaders['x-ms-continuationtoken']).Count -gt 0) { throw 'Cleanup inventory has an unhandled continuation token; refusing incomplete verification.' }
  if ($status -lt 200 -or $status -ge 300) { throw "ARM cleanup request failed with HTTP $status; absence was not established." }
  return @{StatusCode=[int]$status; Value=$value}
}

function Invoke-MaesterCleanupGraphRequest {
  param($Binding, [ValidateSet('GET','DELETE')][string]$Method, [string]$Path)
  $ordinaryRoute=$Path -match '^/v1\.0/(applications|servicePrincipals|roleManagement/directory/roleAssignments|oauth2PermissionGrants)(?:/|\?|$)'
  $directoryRoleRead=$Method -ceq 'GET' -and $Path -cmatch '^/v1\.0/directoryRoles/[0-9a-f-]{36}\?\$select=id,roleTemplateId$'
  if ((-not $ordinaryRoute -and -not $directoryRoleRead) -or $Path -match '[\r\n#]') { throw 'Unsupported cleanup Graph route.' }
  try { return @{StatusCode=200; Value=(Invoke-GraphRestRequest -TenantId $Binding.tenantId -Method $Method -Uri "https://graph.microsoft.com$Path")} }
  catch { if ((Get-MaesterCleanupHttpStatus $_) -eq 404) { return @{StatusCode=404; Value=$null} }; throw }
}

function Invoke-MaesterCleanupAdoRequest {
  param($Binding, [ValidateSet('GET','DELETE')][string]$Method, [string]$Path)
  $organizationUrl = [string](Get-MaesterCleanupField $Binding 'adoOrganizationUrl')
  if ($organizationUrl -cnotmatch '^https://dev\.azure\.com/[A-Za-z0-9][A-Za-z0-9_-]{0,63}/?$') { throw 'Cleanup requires the exact bound Azure DevOps organization URL.' }
  if ($Path -notmatch '^/(?:[0-9a-f-]{36}/)?_apis/[A-Za-z0-9_/?=&.%,-]+$' -or $Path -match '%(?!20|27|2F|2f|3A|3a)' -or $Path.Contains('..')) { throw 'Unsupported cleanup Azure DevOps route.' }
  $token = Get-AzCliAccessToken -Resource '499b84ac-1321-427f-aa17-267ca6975798' -SubscriptionId $Binding.subscriptionId -TenantId $Binding.tenantId
  if (-not $token) { throw 'Current tenant-bound Azure DevOps authentication is required.' }
  $status = 0
  $value = Invoke-RestMethod -Method $Method -Uri "$($organizationUrl.TrimEnd('/'))$Path" -Headers @{Authorization="Bearer $token"} -SkipHttpErrorCheck -StatusCodeVariable status -ResponseHeadersVariable responseHeaders -ErrorAction Stop
  if ($status -eq 404) { return @{StatusCode=404; Value=$null} }
  if ($null -ne $responseHeaders -and $responseHeaders.ContainsKey('x-ms-continuationtoken') -and @($responseHeaders['x-ms-continuationtoken']).Count -gt 0) { throw 'Cleanup inventory has an unhandled continuation token; refusing incomplete verification.' }
  if ($status -lt 200 -or $status -ge 300) { throw "Azure DevOps cleanup request failed with HTTP $status; absence was not established." }
  return @{StatusCode=[int]$status; Value=$value}
}

function Assert-MaesterCleanupCollection {
  param($Response, [string]$Label)
  if ($Response.StatusCode -eq 404) { throw "$Label collection was not found; dependent ownership cannot be established." }
  if ($null -ne (Get-MaesterCleanupField $Response.Value '@odata.nextLink') -or $null -ne (Get-MaesterCleanupField $Response.Value 'nextLink') -or $null -ne (Get-MaesterCleanupField $Response.Value 'continuationToken')) { throw "$Label inventory is paginated; refusing an incomplete dependency inventory." }
  $value = Get-MaesterCleanupField $Response.Value 'value'
  if ($value -isnot [Collections.IList]) { throw "$Label response does not contain an exact array value inventory." }
  return ,@($value)
}

function Assert-MaesterCleanupEqual {
  param($Actual, $Expected, [string]$Label, [switch]$CaseSensitive)
  $equal = if ($CaseSensitive) { [string]$Actual -ceq [string]$Expected } else { [string]$Actual -ieq [string]$Expected }
  if ($null -eq $Actual -or -not $equal) { throw "Cleanup conflict: $Label no longer matches the recorded exact tuple." }
}

function Assert-MaesterCleanupSet {
  param($Actual, $Expected, [string]$Label)
  $left = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
  $right = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
  if ((ConvertTo-MaesterCleanupCanonicalJson $left) -cne (ConvertTo-MaesterCleanupCanonicalJson $right)) { throw "Cleanup conflict: $Label changed." }
}

function Assert-MaesterCleanupJournal {
  param($Journal)
  $records = @($Journal.records)
  foreach ($record in $records) {
    if ($record.kind -cnotin $script:CleanupKinds) { throw "Unsupported cleanup operation kind '$($record.kind)'." }
    if ($record.state -in @('pending','conflict')) { throw "Cleanup blocked by $($record.state) operation '$($record.operationId)'; resolve its exact remote outcome first." }
    if ($record.state -eq 'deleted') { continue }
    if ($record.ownership -eq 'Mutation' -and $record.kind -ne 'WebAppAuthConfiguration') {
      $parentId = [string](Get-MaesterCleanupField $record 'coveredByOperationId')
      $parent = @($records | Where-Object operationId -CEQ $parentId)
      if ($parent.Count -ne 1 -or $parent[0].ownership -cne 'Created') { throw "Cleanup blocked: shared mutation '$($record.operationId)' has no provable owned-parent removal and cannot be restored safely under concurrent changes." }
      $p = $parent[0]
      $covered = switch ($record.kind) {
        ApplicationConfiguration { $p.kind -eq 'EntraApplication' -and $p.exactIds.applicationObjectId -eq $record.expected.applicationObjectId }
        OAuth2PermissionGrant { $p.kind -eq 'EntraServicePrincipal' -and $p.exactIds.servicePrincipalId -eq $record.expected.clientId }
        AdoServiceConnectionBinding { $p.kind -eq 'AdoServiceConnection' -and $p.exactIds.serviceConnectionId -eq $record.expected.serviceConnectionId }
        AdoPipelineAuthorization { ($p.kind -eq 'AdoServiceConnection' -and $p.exactIds.serviceConnectionId -eq $record.expected.resourceId) -or ($p.kind -eq 'AdoRepository' -and ($p.exactIds.repositoryId -eq $record.expected.resourceId -or "$($record.expected.projectId).$($p.exactIds.repositoryId)" -eq $record.expected.resourceId)) }
        AdoRepositoryPublication { $p.kind -eq 'AdoRepository' -and $p.exactIds.repositoryId -eq $record.expected.repositoryId }
        default { $false }
      }
      if (-not $covered) { throw "Cleanup blocked: mutation '$($record.operationId)' does not identify its claimed owned parent." }
    }
  }
}

function Assert-MaesterCleanupArmAuthority {
  param($Binding, [switch]$RequireAbsent)
  $null = Get-AzCliSubscriptionContext -SubscriptionId $Binding.subscriptionId -TenantId $Binding.tenantId
  $group = Invoke-MaesterCleanupArmRequest -Binding $Binding -Method GET -ResourceId $Binding.resourceGroupId -ApiVersion '2021-04-01'
  if ($RequireAbsent) {
    if ($group.StatusCode -ne 404) { throw 'The bound Azure resource group still exists. External cleanup is forbidden until azd has genuinely removed Azure resources.' }
    $runtimeId = [string](Get-MaesterCleanupField $Binding 'runtimeResourceId')
    if ($runtimeId) {
      $runtime = Invoke-MaesterCleanupArmRequest -Binding $Binding -Method GET -ResourceId $runtimeId -ApiVersion (Get-MaesterCleanupRuntimeApiVersion $runtimeId)
      if ($runtime.StatusCode -ne 404) { throw 'The exact bound runtime resource still exists; external cleanup is forbidden.' }
    }
    return
  }
  if ($group.StatusCode -ne 404) { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $group.Value 'id') $Binding.resourceGroupId 'resource group identity' }

}

function Get-MaesterCleanupScopes {
  param($Journal)
  $scopes = @('Application.Read.All','Directory.Read.All')
  $kinds = @($Journal.records | Where-Object state -NE 'deleted' | ForEach-Object kind)
  if ('GraphAppRoleAssignment' -in $kinds) { $scopes += 'AppRoleAssignment.ReadWrite.All' }
  if ('DirectoryRoleAssignment' -in $kinds) { $scopes += 'RoleManagement.ReadWrite.Directory' }
  if (@($kinds | Where-Object { $_ -in @('EntraApplication','EntraServicePrincipal','FederatedIdentityCredential','ApplicationConfiguration') }).Count) { $scopes += 'Application.ReadWrite.All' }
  if ('OAuth2PermissionGrant' -in $kinds) { $scopes += 'DelegatedPermissionGrant.ReadWrite.All' }
  return @($scopes | Sort-Object -Unique)
}

function Get-MaesterOwnedCleanupScopes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][Collections.IDictionary]$Binding)
  $session=Open-MaesterOwnershipJournal -ProjectRoot $ProjectRoot -Binding $Binding -RequireExisting
  try {
    $journal=Get-MaesterOwnershipJournal -Session $session
    Assert-MaesterCleanupJournal $journal
    if (-not @($journal.records | Where-Object state -NE 'deleted').Count) { return @() }
    return @(Get-MaesterCleanupScopes $journal)
  } finally { $session.Dispose() }
}

function Initialize-MaesterCleanupGraph {
  param($Journal, [switch]$AllowInteractiveGraphLogin, [switch]$AllowGraphContextReplacement)
  $binding = $Journal.binding
  $ambientClient = if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) { [string](Get-MaesterCleanupField (Get-MgContext) 'ClientId') } else { '' }
  $currentClient = if ($env:MAESTER_SETUP_CLIENT_ID) { $env:MAESTER_SETUP_CLIENT_ID } else { $binding.setupClientId }
  $selectedScopes=@(Get-MaesterCleanupScopes $Journal)
  Write-Host "Postdown selected delegated Graph scopes (Process context): $($selectedScopes -join ', ')"
  Assert-GraphAccess -TenantId $binding.tenantId -ClientId $currentClient -ExpectedAccount $env:MAESTER_SETUP_ACCOUNT -Scopes $selectedScopes -AllowInteractive:$AllowInteractiveGraphLogin -AllowContextReplacement:$AllowGraphContextReplacement
  $clients = @($binding.setupClientId, $currentClient, $ambientClient | Where-Object { $_ } | Sort-Object -Unique)
  $protectedIds = @()
  foreach ($client in $clients) {
    if ($client -notmatch '^[0-9a-fA-F-]{36}$') { throw 'The authenticated setup client identity is malformed.' }
    foreach ($collection in @('applications','servicePrincipals')) {
      $items = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/${collection}?`$filter=appId eq '$client'&`$select=id,appId") 'protected setup identity'
      foreach ($item in $items) { $protectedIds += [string](Get-MaesterCleanupField $item 'id') }
    }
  }
  foreach ($record in $Journal.records) { $protectedIds += @((Get-MaesterCleanupField $record.after 'allowedGroups' @())) }
  foreach ($group in @($env:SECURITY_GROUP_OBJECT_ID,$env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID)) { if ($group -and $group -match '^[0-9a-fA-F-]{36}$') { $protectedIds += $group } }
  return @{clientIds=$clients; objectIds=@($protectedIds | Sort-Object -Unique)}
}

function Assert-MaesterCleanupProtected {
  param($Record, $Protection)
  foreach ($field in @('appId','applicationObjectId','servicePrincipalId','clientId','principalId')) {
    foreach ($map in @($Record.expected,$Record.exactIds)) {
      $id = [string](Get-MaesterCleanupField $map $field)
      if ($id -and ($id -iin $Protection.clientIds -or $id -iin $Protection.objectIds)) { throw "Cleanup would modify the retained setup identity via '$($Record.operationId)'; refusing." }
    }
  }
}

function Get-MaesterCleanupKnownIds {
  param($Journal, [string]$Kind, [string]$Field, [string]$ExpectedField = '', [string]$ExpectedValue = '')
  return @($Journal.records | Where-Object { $_.kind -ceq $Kind -and $_.state -cne 'deleted' -and ($ExpectedField -eq '' -or (Get-MaesterCleanupField $_.expected $ExpectedField) -ieq $ExpectedValue) } | ForEach-Object { Get-MaesterCleanupField $_.exactIds $Field } | Where-Object { $_ })
}

function Assert-MaesterCleanupKnownChildren {
  param($Items, $KnownIds, [string]$Label, [string]$IdField = 'id')
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($item in @($Items)) {
    $id=[string](Get-MaesterCleanupField $item $IdField)
    if (-not $id -or $id -cnotin $KnownIds) { throw "Cleanup conflict: unrecorded $Label '$id' would be affected by deleting its parent." }
    if (-not $seen.Add($id)) { throw "Cleanup conflict: duplicate $Label identity '$id' in provider inventory." }
  }
}

function Get-MaesterCleanupRuntimeApiVersion {
  param([string]$Id)
  switch -Regex ($Id) {
    '/providers/Microsoft.Web/sites/[^/]+$' { return '2023-12-01' }
    '/providers/Microsoft.Automation/automationAccounts/[^/]+$' { return '2023-11-01' }
    '/providers/Microsoft.App/jobs/[^/]+$' { return '2024-03-01' }
    default { throw 'The exact runtime resource type is unsupported for verified cleanup absence.' }
  }
}

function Get-MaesterCleanupApplicationConfigurationValue {
  param($Application, [string]$Field)
  $value=switch ($Field) {
    redirectUris { Get-MaesterCleanupField (Get-MaesterCleanupField $Application 'web') 'redirectUris' }
    enableIdTokenIssuance { Get-MaesterCleanupField (Get-MaesterCleanupField (Get-MaesterCleanupField $Application 'web') 'implicitGrantSettings') 'enableIdTokenIssuance' }
    enableAccessTokenIssuance { Get-MaesterCleanupField (Get-MaesterCleanupField (Get-MaesterCleanupField $Application 'web') 'implicitGrantSettings') 'enableAccessTokenIssuance' }
    default { Get-MaesterCleanupField $Application $Field }
  }
  if ($Field -ceq 'groupMembershipClaims') {
    if (-not (Test-MaesterCleanupHasField $Application $Field)) { throw 'Cleanup cannot verify application groupMembershipClaims.' }
    if ($null -eq $value) { return 'None' }
  }
  if ($Field -in @('redirectUris','identifierUris')) {
    if ($value -isnot [Collections.IList]) { throw "Cleanup cannot verify the complete application configuration $Field array." }
    return ,$value
  }
  if ($Field -in @('enableIdTokenIssuance','enableAccessTokenIssuance') -and $value -isnot [bool]) { throw "Cleanup cannot verify the application configuration $Field Boolean." }
  return $value
}

function Assert-MaesterCleanupApplicationConfiguration {
  param($Record, $Journal, $Application)
  $fields=@('redirectUris','identifierUris','groupMembershipClaims','enableIdTokenIssuance','enableAccessTokenIssuance','signInAudience')
  $effective=@{}
  foreach ($field in $fields) {
    if (-not (Test-MaesterCleanupHasField $Record.after $field)) { throw "Owned application creation receipt has no complete configuration baseline ($field); preserving the application." }
    $effective[$field]=$Record.after[$field]
  }
  foreach ($configuration in @($Journal.records | Where-Object { $_.kind -ceq 'ApplicationConfiguration' -and $_.coveredByOperationId -ceq $Record.operationId -and $_.state -in @('applied','deleting') })) {
    foreach ($field in $configuration.after.Keys) {
      if ($field -cnotin $fields) { throw 'Unsupported application configuration override.' }
      $effective[$field]=$configuration.after[$field]
    }
  }
  foreach ($field in $fields) {
    $actual=Get-MaesterCleanupApplicationConfigurationValue $Application $field
    if ($effective[$field] -is [Collections.IList]) { Assert-MaesterCleanupSet $actual $effective[$field] "application configuration $field" }
    else { Assert-MaesterCleanupEqual $actual $effective[$field] "application configuration $field" -CaseSensitive }
  }
}

function Assert-MaesterCleanupGraphParent {
  param($Record, $Journal, $Value)
  $binding = $Journal.binding
  $isApp = $Record.kind -ceq 'EntraApplication'
  $objectId = if ($isApp) { $Record.exactIds.applicationObjectId } else { $Record.exactIds.servicePrincipalId }
  $collection = if ($isApp) { 'applications' } else { 'servicePrincipals' }
  foreach ($credential in @('passwordCredentials','keyCredentials')) {
    if (-not (Test-MaesterCleanupHasField $Value $credential)) { throw "Cleanup cannot verify the complete $credential inventory for '$objectId'." }
    if (@((Get-MaesterCleanupField $Value $credential @())).Count) { throw "Cleanup conflict: owned $collection '$objectId' has unrecorded $credential." }
  }
  $owners = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/$collection/$objectId/owners?`$select=id") 'application owners'
  $creator=[string](Get-MaesterCleanupField $Record.expected 'creatorPrincipalId')
  foreach ($owner in $owners) {
    if (-not $creator -or [string](Get-MaesterCleanupField $owner 'id') -ine $creator) { throw "Cleanup conflict: owned $collection '$objectId' has owners not covered by its approved creation receipt." }
  }
  if ($owners.Count -gt 1) { throw "Cleanup conflict: owned $collection '$objectId' has an ambiguous owner inventory." }
  if ($isApp) {
    Assert-MaesterCleanupApplicationConfiguration $Record $Journal $Value
    $fics = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/applications/$objectId/federatedIdentityCredentials") 'federated credentials'
    Assert-MaesterCleanupKnownChildren $fics @(Get-MaesterCleanupKnownIds $Journal FederatedIdentityCredential federatedCredentialId applicationObjectId $objectId) 'federated credential'
    $principals = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/servicePrincipals?`$filter=appId eq '$($Record.exactIds.appId)'&`$select=id,appId") 'application service principals'
    Assert-MaesterCleanupKnownChildren $principals @(Get-MaesterCleanupKnownIds $Journal EntraServicePrincipal servicePrincipalId appId $Record.exactIds.appId) 'service principal'
    return
  }
  $members=Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/servicePrincipals/$objectId/memberOf?`$select=id") 'principal memberships'
  if ($members.Count) {
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($member in $members) {
      $memberId=[string](Get-MaesterCleanupField $member 'id')
      $memberGuid=[guid]::Empty
      if (-not [guid]::TryParse($memberId,[ref]$memberGuid) -or $memberGuid -eq [guid]::Empty -or -not $seen.Add($memberId) -or (Get-MaesterCleanupField $member '@odata.type') -cne '#microsoft.graph.directoryRole') { throw "Cleanup conflict: principal '$objectId' has an unrecorded group or unknown membership." }
      # Read the exact returned role ID. OData casts would require advanced-query
      # eventual consistency; no indexed/cast inventory is used for deletion proof.
      $role=Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/directoryRoles/$($memberGuid.ToString())?`$select=id,roleTemplateId"
      if ($role.StatusCode -ne 200) { throw 'Directory-role membership identity cannot be fully verified.' }
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $role.Value 'id') $memberGuid.ToString() 'directory-role membership object ID'
      $template=[string](Get-MaesterCleanupField $role.Value 'roleTemplateId')
      if (-not $template) { throw 'Directory-role membership template cannot be fully verified.' }
      $owned=@($Journal.records | Where-Object { $_.kind -ceq 'DirectoryRoleAssignment' -and $_.ownership -ceq 'Created' -and $_.state -in @('applied','deleting') -and $_.expected.principalId -ieq $objectId -and $_.expected.directoryScopeId -ceq '/' -and $_.expected.roleDefinitionId -ieq $template })
      if ($owned.Count -ne 1) { throw 'Cleanup conflict: principal has an unrecorded or stale directory-role membership.' }
    }
  }
  $ownedObjects=Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/servicePrincipals/$objectId/ownedObjects?`$select=id") 'principal owned objects'
  if ($ownedObjects.Count) { throw "Cleanup conflict: principal '$objectId' has unrecorded ownedObjects relationships." }
  $roles = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/servicePrincipals/$objectId/appRoleAssignments") 'principal app roles'
  Assert-MaesterCleanupKnownChildren $roles @(Get-MaesterCleanupKnownIds $Journal GraphAppRoleAssignment assignmentId principalId $objectId) 'app-role assignment'
  $inbound = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/servicePrincipals/$objectId/appRoleAssignedTo") 'inbound app roles'
  Assert-MaesterCleanupKnownChildren $inbound @(Get-MaesterCleanupKnownIds $Journal GraphAppRoleAssignment assignmentId resourceId $objectId) 'inbound app-role assignment'
  foreach ($field in @('clientId','resourceId')) {
    $grants = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/oauth2PermissionGrants?`$filter=$field eq '$objectId'") 'delegated grants'
    Assert-MaesterCleanupKnownChildren $grants @(Get-MaesterCleanupKnownIds $Journal OAuth2PermissionGrant grantId $field $objectId) 'delegated permission grant'
    foreach ($grant in $grants) {
      $receipts=@($Journal.records | Where-Object { $_.kind -ceq 'OAuth2PermissionGrant' -and $_.state -in @('applied','deleting') -and $_.exactIds.grantId -ceq (Get-MaesterCleanupField $grant 'id') })
      if ($receipts.Count -ne 1) { throw 'Delegated grant dependency has no unique active exact receipt.' }
      foreach ($key in @('clientId','resourceId','consentType')) { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $grant $key) $receipts[0].expected[$key] "dependent delegated grant $key" }
      Assert-MaesterCleanupSet @(([string](Get-MaesterCleanupField $grant 'scope')).Split(' ',[StringSplitOptions]::RemoveEmptyEntries)) $receipts[0].after.scopes 'dependent delegated grant scopes'
      if ($receipts[0].expected.consentType -ceq 'Principal') { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $grant 'principalId') (Get-MaesterCleanupField $receipts[0].expected 'principalId') 'dependent delegated grant principal' }
      elseif ($null -ne (Get-MaesterCleanupField $grant 'principalId')) { throw 'Cleanup conflict: AllPrincipals dependent delegated grant has a non-null principalId.' }
    }
  }
  $directoryRoles = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupGraphRequest $binding GET "/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$objectId'") 'directory roles'
  Assert-MaesterCleanupKnownChildren $directoryRoles @(Get-MaesterCleanupKnownIds $Journal DirectoryRoleAssignment assignmentId principalId $objectId) 'directory role assignment'
  $armRoles = Assert-MaesterCleanupCollection (Invoke-MaesterCleanupArmRequest $binding GET "/subscriptions/$($binding.subscriptionId)/providers/Microsoft.Authorization/roleAssignments" '2022-04-01' "&`$filter=principalId%20eq%20%27$objectId%27") 'principal Azure roles'
  Assert-MaesterCleanupKnownChildren $armRoles @(Get-MaesterCleanupKnownIds $Journal AzureRoleAssignment roleAssignmentId principalId $objectId) 'Azure role assignment'
}

function Assert-MaesterCleanupAdoAuthority {
  param($Record, $Binding)
  $connection = Invoke-MaesterCleanupAdoRequest $Binding GET '/_apis/connectionData?connectOptions=1&lastChangeId=-1&lastChangeId64=-1'
  if ($connection.StatusCode -eq 404) { throw 'The exact Azure DevOps organization could not be verified.' }
  Assert-MaesterCleanupEqual (Get-MaesterCleanupField $connection.Value 'instanceId') $Record.expected.organizationId 'Azure DevOps organization ID'
  $project = Invoke-MaesterCleanupAdoRequest $Binding GET "/_apis/projects/$($Record.expected.projectId)?api-version=7.1"
  if ($project.StatusCode -eq 404) { throw 'The exact Azure DevOps project could not be verified.' }
  Assert-MaesterCleanupEqual (Get-MaesterCleanupField $project.Value 'id') $Record.expected.projectId 'Azure DevOps project ID'
}

function Get-MaesterCleanupExchangeObject {
  param($Record)
  # Exchange documents that an unknown -Identity can return every object. Read
  # the documented unbounded inventory successfully, then match the receipt ID.
  # Provider errors (including typed collection 404) are never target absence.
  $isPrincipal=$Record.kind -ceq 'ExchangeServicePrincipal'
  $id=if ($isPrincipal) { $Record.exactIds.exchangeServicePrincipalId } else { $Record.exactIds.exchangeRoleAssignmentId }
  $field=if ($isPrincipal) { 'ObjectId' } else { 'Identity' }
  $items=@(if ($isPrincipal) { Get-ServicePrincipal -ErrorAction Stop } else { Get-ManagementRoleAssignment -ErrorAction Stop })
  $matchingObjects=@()
  foreach ($item in $items) {
    $candidate=[string](Get-MaesterCleanupField $item $field)
    if ([string]::IsNullOrWhiteSpace($candidate)) { throw 'Exchange inventory has incomplete exact identities; absence cannot be established.' }
    $equal=if ($isPrincipal) { $candidate -ieq $id } else { $candidate -ceq $id }
    if ($equal) { $matchingObjects+=,$item }
  }
  if ($matchingObjects.Count -gt 1) { throw 'Exchange inventory contains duplicate exact identities.' }
  if ($matchingObjects.Count -eq 0) { return @{StatusCode=404;Value=$null} }
  return @{StatusCode=200;Value=$matchingObjects[0]}
}

function Get-MaesterCleanupTarget {
  param($Record, $Journal, $Protection)
  $binding = $Journal.binding
  Assert-MaesterCleanupProtected $Record $Protection
  $kind = $Record.kind
  $expected = $Record.expected
  $ids = $Record.exactIds
  $path = ''; $provider = ''; $response = $null
  if ($kind -ceq 'WebAppAuthConfiguration') {
    $id = $expected.webAppResourceId
    if (-not $id.StartsWith("$($binding.resourceGroupId)/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Web App configuration is outside the bound resource group.' }
    $response = Invoke-MaesterCleanupArmRequest $binding GET $id (Get-MaesterCleanupRuntimeApiVersion $id)
    if ($response.StatusCode -ne 404) { throw 'Web App still exists; its authentication mutation cannot be discharged.' }
    return @{operationId=$Record.operationId; kind=$kind; action='AlreadyAbsent'; target=$id; snapshot=@{absent=$true}}
  }
  if ($Record.ownership -ceq 'Mutation') {
    $parent=@($Journal.records | Where-Object operationId -CEQ $Record.coveredByOperationId)
    if ($parent.Count -ne 1) { throw 'Covered mutation has no unique owned parent.' }
    $snapshot=@{expected=$expected;after=$Record.after}
    if ($parent[0].state -ceq 'deleted') {
      $parentState=Get-MaesterCleanupTarget $parent[0] $Journal $Protection
      if ($parentState.action -cne 'AlreadyAbsent') { throw 'Cleanup conflict: a previously deleted parent was restored or remains present; its covered mutation cannot be discharged.' }
      $snapshot.parentAbsence=@{kind=$parentState.kind;provider=$parentState.provider;target=$parentState.target}
    }
    return @{operationId=$Record.operationId; kind=$kind; action='CoveredByParent'; target=$Record.coveredByOperationId; snapshot=$snapshot}
  }
  switch ($kind) {
    GraphAppRoleAssignment { $provider='Graph'; $path="/v1.0/servicePrincipals/$($expected.principalId)/appRoleAssignments/$([uri]::EscapeDataString($ids.assignmentId))" }
    DirectoryRoleAssignment { $provider='Graph'; $path="/v1.0/roleManagement/directory/roleAssignments/$([uri]::EscapeDataString($ids.assignmentId))" }
    FederatedIdentityCredential { $provider='Graph'; $path="/v1.0/applications/$($expected.applicationObjectId)/federatedIdentityCredentials/$([uri]::EscapeDataString($ids.federatedCredentialId))" }
    OAuth2PermissionGrant { $provider='Graph'; $path="/v1.0/oauth2PermissionGrants/$([uri]::EscapeDataString($ids.grantId))" }
    EntraApplication { $provider='Graph'; $path="/v1.0/applications/$($ids.applicationObjectId)" }
    EntraServicePrincipal { $provider='Graph'; $path="/v1.0/servicePrincipals/$($ids.servicePrincipalId)" }
    AzureRoleAssignment { $provider='Arm'; $path=$ids.roleAssignmentId }
    ResourceLock { $provider='Arm'; $path=$ids.lockId }
    { $_ -in @('AdoRepository','AdoPipeline','AdoServiceConnection') } {
      $provider='Ado'; Assert-MaesterCleanupAdoAuthority $Record $binding
      $base="/$($expected.projectId)/_apis"
      $path = switch ($kind) {
        AdoRepository { "$base/git/repositories/$($ids.repositoryId)?api-version=7.1" }
        AdoPipeline { "$base/build/definitions/$($ids.pipelineId)?api-version=7.1" }
        AdoServiceConnection { "$base/serviceendpoint/endpoints/$($ids.serviceConnectionId)?api-version=7.1" }
      }
    }
    { $_ -in @('ExchangeServicePrincipal','ExchangeRoleAssignment') } {
      $provider='Exchange'; $path=if ($kind -eq 'ExchangeServicePrincipal') { $ids.exchangeServicePrincipalId } else { $ids.exchangeRoleAssignmentId }
      $response=Get-MaesterCleanupExchangeObject $Record
    }
    default { throw "No finite cleanup handler for '$kind'." }
  }
  if ($provider -eq 'Graph') {
    $readPath=$path
    if ($kind -ceq 'EntraApplication') { $readPath += '?$select=id,appId,displayName,passwordCredentials,keyCredentials,web,identifierUris,groupMembershipClaims,signInAudience' }
    elseif ($kind -ceq 'EntraServicePrincipal') { $readPath += '?$select=id,appId,appOwnerOrganizationId,passwordCredentials,keyCredentials' }
    $response=Invoke-MaesterCleanupGraphRequest $binding GET $readPath
  }
  elseif ($provider -eq 'Arm') { $api=if ($kind -eq 'ResourceLock') {'2016-09-01'} else {'2022-04-01'}; $response=Invoke-MaesterCleanupArmRequest $binding GET $path $api }
  elseif ($provider -eq 'Ado') { $response=Invoke-MaesterCleanupAdoRequest $binding GET $path }
  if ($response.StatusCode -eq 404) { return @{operationId=$Record.operationId;kind=$kind;action='AlreadyAbsent';provider=$provider;target=$path;snapshot=@{absent=$true}} }
  $value=$response.Value
  switch ($kind) {
    GraphAppRoleAssignment {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.assignmentId 'app role assignment ID' -CaseSensitive
      foreach ($key in @('principalId','resourceId','appRoleId')) { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value $key) $expected[$key] "app-role $key" }
    }
    DirectoryRoleAssignment {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.assignmentId 'directory role assignment ID' -CaseSensitive
      foreach ($key in @('principalId','roleDefinitionId','directoryScopeId')) { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value $key) $expected[$key] "directory-role $key" }
    }
    FederatedIdentityCredential {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.federatedCredentialId 'federated credential ID' -CaseSensitive
      foreach ($key in @('issuer','subject')) { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value $key) $expected[$key] "federated credential $key" -CaseSensitive }
      Assert-MaesterCleanupSet (Get-MaesterCleanupField $value 'audiences') $expected.audiences 'federated credential audiences'
    }
    OAuth2PermissionGrant {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.grantId 'delegated grant ID' -CaseSensitive
      foreach ($key in @('clientId','resourceId','consentType')) { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value $key) $expected[$key] "delegated grant $key" }
      Assert-MaesterCleanupSet @(([string](Get-MaesterCleanupField $value 'scope')).Split(' ',[StringSplitOptions]::RemoveEmptyEntries)) $Record.after.scopes 'delegated grant scopes'
      if ($expected.consentType -eq 'Principal') { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'principalId') (Get-MaesterCleanupField $expected 'principalId') 'delegated grant principal' }
      elseif ($null -ne (Get-MaesterCleanupField $value 'principalId')) { throw 'Cleanup conflict: AllPrincipals delegated grant has a non-null principalId.' }
    }
    EntraApplication {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.applicationObjectId 'application object ID'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'appId') $ids.appId 'application client ID'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'displayName') $expected.displayName 'application display name' -CaseSensitive
      Assert-MaesterCleanupGraphParent $Record $Journal $value
    }
    EntraServicePrincipal {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.servicePrincipalId 'service principal object ID'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'appId') $expected.appId 'service principal app ID'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'appOwnerOrganizationId') $binding.tenantId 'service principal owning tenant'
      Assert-MaesterCleanupGraphParent $Record $Journal $value
    }
    AzureRoleAssignment {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.roleAssignmentId 'Azure role assignment ID'
      foreach ($key in @('principalId','roleDefinitionId','scope')) { Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'properties') $key) $expected[$key] "Azure role $key" }
      if (Get-MaesterCleanupField $expected 'principalType') { Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'properties') 'principalType') $expected.principalType 'Azure role principal type' }
    }
    ResourceLock {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.lockId 'resource lock ID'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'properties') 'level') $expected.level 'resource lock level'
      if ($ids.lockId -notlike "$($expected.scope)/providers/Microsoft.Authorization/locks/*") { throw 'Resource lock scope differs from its recorded target.' }
      throw 'Resource locks require separate explicit unlock; cleanup never implicitly removes a live lock.'
    }
    ExchangeServicePrincipal {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'ObjectId') $ids.exchangeServicePrincipalId 'Exchange principal ID'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'AppId') $expected.appId 'Exchange app ID'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'ObjectId') $expected.servicePrincipalId 'Exchange directory principal'
      $assignments=@(Get-ManagementRoleAssignment -RoleAssignee $ids.exchangeServicePrincipalId -ErrorAction Stop)
      Assert-MaesterCleanupKnownChildren $assignments @(Get-MaesterCleanupKnownIds $Journal ExchangeRoleAssignment exchangeRoleAssignmentId servicePrincipalId $expected.servicePrincipalId) 'Exchange role assignment' 'Identity'
    }
    ExchangeRoleAssignment {
      Assert-MaesterCleanupEqual ([string](Get-MaesterCleanupField $value 'Identity')) $ids.exchangeRoleAssignmentId 'Exchange role identity' -CaseSensitive
      Assert-MaesterCleanupEqual ([string](Get-MaesterCleanupField $value 'Role')) $expected.roleName 'Exchange role'
      $assigned=@(Get-ManagementRoleAssignment -RoleAssignee $expected.servicePrincipalId -ErrorAction Stop)
      $exact=@($assigned | Where-Object { [string](Get-MaesterCleanupField $_ 'Identity') -ceq $ids.exchangeRoleAssignmentId -and [string](Get-MaesterCleanupField $_ 'Role') -ceq $expected.roleName })
      if ($exact.Count -ne 1) { throw 'Cleanup conflict: exact Exchange role assignment is no longer bound to the recorded directory principal.' }
    }
    AdoPipeline {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.pipelineId 'Azure DevOps pipeline ID'
      if (Get-MaesterCleanupField $expected 'pipelineName') { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'name') $expected.pipelineName 'pipeline name' -CaseSensitive }
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'project') 'id') $expected.projectId 'pipeline project'
      $repository=Get-MaesterCleanupField $value 'repository'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $repository 'id') $expected.repositoryId 'pipeline repository'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $repository 'defaultBranch') $expected.branch 'pipeline branch' -CaseSensitive
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'process') 'yamlFilename') $expected.yamlPath 'pipeline YAML path' -CaseSensitive
      $revision=Get-MaesterCleanupField $ids 'pipelineRevision' (Get-MaesterCleanupField $ids 'revision' (Get-MaesterCleanupField $Record.after 'revision'))
      if ($null -eq $revision) { throw 'Pipeline receipt has no exact revision; refusing deletion of potentially changed shared work.' }
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'revision') $revision 'pipeline revision'
    }
    AdoServiceConnection {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.serviceConnectionId 'Azure DevOps endpoint ID'
      if (Get-MaesterCleanupField $expected 'serviceConnectionName') { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'name') $expected.serviceConnectionName 'endpoint name' -CaseSensitive }
      if ((Get-MaesterCleanupField $value 'isShared') -ne $false) { throw 'The Azure DevOps service connection is shared or has unverifiable sharing state.' }
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'type') 'azurerm' 'endpoint type'
      $authorization=Get-MaesterCleanupField $value 'authorization'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $authorization 'scheme') 'WorkloadIdentityFederation' 'endpoint authorization scheme'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'url') 'https://management.azure.com/' 'endpoint resource URL' -CaseSensitive
      $parameters=Get-MaesterCleanupField $authorization 'parameters'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $parameters 'tenantid') $binding.tenantId 'endpoint tenant'
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'data') 'subscriptionId') $binding.subscriptionId 'endpoint subscription'
      $bindings=@($Journal.records | Where-Object { $_.kind -eq 'AdoServiceConnectionBinding' -and $_.coveredByOperationId -eq $Record.operationId })
      $appId=if ($bindings.Count -eq 1) { $bindings[0].expected.appId } else { Get-MaesterCleanupField $expected 'appId' }
      $liveAppId=[string](Get-MaesterCleanupField $parameters 'serviceprincipalid')
      if (-not $appId) {
        if ($bindings.Count -ne 0 -or $liveAppId -or (Get-MaesterCleanupField $value 'isReady') -ne $true -or (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'data') 'isDraft') -ne $true) { throw 'Endpoint has no exact recorded workload application binding and is not an unchanged unbound draft.' }
      } else { Assert-MaesterCleanupEqual $liveAppId $appId 'endpoint application binding' }
      $scope=if ($bindings.Count -eq 1) { Get-MaesterCleanupField $bindings[0].after 'scope' } else { Get-MaesterCleanupField $expected 'scope' }
      if (-not $scope) { throw 'Endpoint receipt has no exact ARM scope binding.' }
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $parameters 'scope') $scope 'endpoint ARM scope'
      $projectReferences=@((Get-MaesterCleanupField $value 'serviceEndpointProjectReferences' @()))
      if ($projectReferences.Count -ne 1) { throw 'Endpoint project sharing has changed.' }
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $projectReferences[0] 'projectReference') 'id') $expected.projectId 'endpoint project binding'
      if ($bindings.Count -eq 1) {
        Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'isReady') (Get-MaesterCleanupField $bindings[0].after 'isReady') 'endpoint ready state'
        Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'data') 'isDraft') (Get-MaesterCleanupField $bindings[0].after 'isDraft') 'endpoint draft state'
        foreach ($key in @('issuer','subject')) {
          $field=if ($key -eq 'issuer') {'workloadIdentityFederationIssuer'} else {'workloadIdentityFederationSubject'}
          Assert-MaesterCleanupEqual (Get-MaesterCleanupField $parameters $field) (Get-MaesterCleanupField $bindings[0].after $key) "endpoint federation $key" -CaseSensitive
        }
      }
      $permissions=Invoke-MaesterCleanupAdoRequest $binding GET "/$($expected.projectId)/_apis/pipelines/pipelinepermissions/endpoint/$($ids.serviceConnectionId)?api-version=7.1-preview.1"
      if ($permissions.StatusCode -ne 404) {
        $all=Get-MaesterCleanupField (Get-MaesterCleanupField $permissions.Value 'allPipelines') 'authorized' $false
        if ($all) {
          $allGrant=@($Journal.records | Where-Object { $_.kind -ceq 'AdoPipelineAuthorization' -and $_.coveredByOperationId -ceq $Record.operationId -and $_.after.allPipelinesAuthorized -eq $true -and $_.expected.resourceType -ceq 'endpoint' -and $_.expected.resourceId -ceq $ids.serviceConnectionId })
          if ($allGrant.Count -ne 1) { throw 'Endpoint all-pipelines permission is not covered by its exact owned mutation receipt.' }
          $projectPipelines=Assert-MaesterCleanupCollection (Invoke-MaesterCleanupAdoRequest $binding GET "/$($expected.projectId)/_apis/build/definitions?api-version=7.1") 'all-pipelines endpoint dependents'
          Assert-MaesterCleanupKnownChildren $projectPipelines @(Get-MaesterCleanupKnownIds $Journal AdoPipeline pipelineId) 'all-pipelines endpoint dependent'
        }
        $authorized=@((Get-MaesterCleanupField $permissions.Value 'pipelines' @()) | Where-Object { Get-MaesterCleanupField $_ 'authorized' $false })
        Assert-MaesterCleanupKnownChildren $authorized @(Get-MaesterCleanupKnownIds $Journal AdoPipeline pipelineId) 'endpoint-authorized pipeline'
      }
    }
    AdoRepository {
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'id') $ids.repositoryId 'Azure DevOps repository ID'
      if (Get-MaesterCleanupField $expected 'repositoryName') { Assert-MaesterCleanupEqual (Get-MaesterCleanupField $value 'name') $expected.repositoryName 'repository name' -CaseSensitive }
      Assert-MaesterCleanupEqual (Get-MaesterCleanupField (Get-MaesterCleanupField $value 'project') 'id') $expected.projectId 'repository project'
      $refs=Assert-MaesterCleanupCollection (Invoke-MaesterCleanupAdoRequest $binding GET "/$($expected.projectId)/_apis/git/repositories/$($ids.repositoryId)/refs?api-version=7.1") 'repository refs'
      $publications=@($Journal.records | Where-Object { $_.kind -eq 'AdoRepositoryPublication' -and $_.coveredByOperationId -eq $Record.operationId })
      # Old publication commits remain immutable receipts. Only each complete
      # chain's terminal publication can authorize the current branch tip. The
      # canonical journal has already rejected missing, cross-target or forked links.
      $supersededIds=@($publications | ForEach-Object { Get-MaesterCleanupField $_ 'supersedesOperationId' } | Where-Object { $_ })
      $terminalPublications=@($publications | Where-Object { $_.state -cne 'deleted' -and $_.operationId -cnotin $supersededIds })
      foreach ($ref in $refs) {
        $matchingPublications=@($terminalPublications | Where-Object { $_.expected.branch -ceq (Get-MaesterCleanupField $ref 'name') -and $_.after.commitId -ceq (Get-MaesterCleanupField $ref 'objectId') })
        if ($matchingPublications.Count -ne 1) { throw 'Repository has an unrecorded or changed branch/tag; preserving user work.' }
      }
      $repoResourceId="$($expected.projectId).$($ids.repositoryId)"
      $permissions=Invoke-MaesterCleanupAdoRequest $binding GET "/$($expected.projectId)/_apis/pipelines/pipelinepermissions/repository/$repoResourceId`?api-version=7.1-preview.1"
      if ($permissions.StatusCode -ne 404) {
        $all=Get-MaesterCleanupField (Get-MaesterCleanupField $permissions.Value 'allPipelines') 'authorized' $false
        if ($all) {
          $allGrant=@($Journal.records | Where-Object { $_.kind -ceq 'AdoPipelineAuthorization' -and $_.coveredByOperationId -ceq $Record.operationId -and $_.after.allPipelinesAuthorized -eq $true -and $_.expected.resourceType -ceq 'repository' -and $_.expected.resourceId -ceq $repoResourceId })
          if ($allGrant.Count -ne 1) { throw 'Repository all-pipelines permission is not covered by its exact owned mutation receipt.' }
          $projectPipelines=Assert-MaesterCleanupCollection (Invoke-MaesterCleanupAdoRequest $binding GET "/$($expected.projectId)/_apis/build/definitions?api-version=7.1") 'all-pipelines repository dependents'
          Assert-MaesterCleanupKnownChildren $projectPipelines @(Get-MaesterCleanupKnownIds $Journal AdoPipeline pipelineId) 'all-pipelines repository dependent'
        }
        $authorized=@((Get-MaesterCleanupField $permissions.Value 'pipelines' @()) | Where-Object { Get-MaesterCleanupField $_ 'authorized' $false })
        Assert-MaesterCleanupKnownChildren $authorized @(Get-MaesterCleanupKnownIds $Journal AdoPipeline pipelineId) 'repository-authorized pipeline'
      }
      $pullRequests=Assert-MaesterCleanupCollection (Invoke-MaesterCleanupAdoRequest $binding GET "/$($expected.projectId)/_apis/git/repositories/$($ids.repositoryId)/pullrequests?searchCriteria.status=all&api-version=7.1") 'repository pull requests'
      if ($pullRequests.Count) { throw 'Repository contains pull requests not owned by the setup receipt; preserving user collaboration.' }
      $definitions=Assert-MaesterCleanupCollection (Invoke-MaesterCleanupAdoRequest $binding GET "/$($expected.projectId)/_apis/build/definitions?repositoryId=$($ids.repositoryId)&repositoryType=TfsGit&api-version=7.1") 'repository pipeline dependents'
      Assert-MaesterCleanupKnownChildren $definitions @(Get-MaesterCleanupKnownIds $Journal AdoPipeline pipelineId repositoryId $ids.repositoryId) 'repository pipeline'
    }
  }
  # Do not retain tokens, credentials or whole provider objects in the approval hash.
  $snapshot=@{expected=$expected;exactIds=$ids;after=$Record.after}
  if ($kind -ceq 'AdoPipeline') { $snapshot.parentContents=@('pipeline definition','all associated builds','build history and artifacts') }
  return @{operationId=$Record.operationId;kind=$kind;action='Delete';provider=$provider;target=$path;snapshot=$snapshot}
}

function Initialize-MaesterCleanupExchange {
  param($Journal)
  if (-not @($Journal.records | Where-Object { $_.state -ne 'deleted' -and $_.kind -in @('ExchangeServicePrincipal','ExchangeRoleAssignment') }).Count) { return }
  if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) { throw 'ExchangeOnlineManagement must be installed before exact Exchange cleanup can proceed.' }
  Import-Module ExchangeOnlineManagement -ErrorAction Stop
  Connect-ExchangeOnlineSilent -TenantId $Journal.binding.tenantId
  $connections=@(Get-ConnectionInformation -ErrorAction Stop | Where-Object { [string]$_.State -eq 'Connected' })
  if ($connections.Count -ne 1 -or [string]$connections[0].TenantID -ine $Journal.binding.tenantId) { throw 'Exact Exchange cleanup requires one verified connection to the bound tenant; ambient or ambiguous sessions are not safe.' }
}

function New-MaesterOwnedCleanupPlan {
  param($Journal, $Protection)
  Assert-MaesterCleanupJournal $Journal
  $entries=@()
  foreach ($record in @($Journal.records | Where-Object state -NE 'deleted' | Sort-Object @{Expression={ $script:CleanupRank[$_.kind] }},operationId)) {
    $entries += ,(Get-MaesterCleanupTarget $record $Journal $Protection)
  }
  $payload=@{schemaVersion='1.0';phase='PostDownExternalCleanup';binding=$Journal.binding;journalHash=(Get-MaesterCleanupHash $Journal);entries=$entries}
  return @{PlanHash=(Get-MaesterCleanupHash $payload);Entries=$entries;Binding=$Journal.binding;Warning='Only these exact owned objects are removed. Reused/shared objects are preserved. Local receipts are unsigned; all live target tuples and dependencies are revalidated. Concurrent reprovisioning during down is unsupported.'}
}

function Write-MaesterCleanupPreview {
  param($Plan)
  Write-Host "Exact owned-object cleanup plan: $($Plan.PlanHash)"
  foreach ($entry in $Plan.Entries) { Write-Host "  $($entry.action): $($entry.kind) $($entry.target) [operation $($entry.operationId)]" }
  Write-Host $Plan.Warning
  if (@($Plan.Entries | Where-Object kind -CEQ 'AdoPipeline').Count) { Write-Host 'Owned Azure DevOps pipeline deletion also removes all associated builds, including their history and artifacts. Revision is freshly checked, but the provider has no revision-conditional delete; do not edit or run pipelines concurrently with down.' }
}

function Test-MaesterCleanupCanPrompt {
  return -not ($env:CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected)
}

function Confirm-MaesterCleanupPlan {
  param([string]$PlanHash, [string]$ApprovedPlanHash, [switch]$InteractiveConsent, [string]$Question='Remove the exact owned external objects shown above?')
  if ($ApprovedPlanHash) {
    if ($ApprovedPlanHash -cnotmatch '^[0-9a-f]{64}$' -or $ApprovedPlanHash -cne $PlanHash) { throw 'Cleanup approval hash is stale or does not match the fresh exact plan; no deletion was attempted.' }
    return
  }
  if (-not $InteractiveConsent) { throw "Explicit cleanup approval is required. Review the fresh plan and retry with -ApprovedPlanHash '$PlanHash', or use -InteractiveConsent for a default-No confirmation." }
  if (-not (Test-MaesterCleanupCanPrompt)) { throw 'Interactive cleanup approval is unavailable in CI, non-interactive azd, or redirected stdin. Use a reviewed exact approval hash.' }
  $answer=Read-Host "$Question [y/N]"
  if ($answer -cnotin @('y','Y','yes','YES')) { throw 'Cleanup was not approved; no deletion was attempted.' }
}

function Invoke-MaesterCleanupDelete {
  param($Entry, $Record, $Binding)
  switch ($Entry.provider) {
    Graph { $null=Invoke-MaesterCleanupGraphRequest $Binding DELETE $Entry.target }
    Arm { $api=if ($Record.kind -eq 'ResourceLock') {'2016-09-01'} else {'2022-04-01'}; $null=Invoke-MaesterCleanupArmRequest $Binding DELETE $Entry.target $api }
    Ado {
      $path=$Entry.target
      if ($Record.kind -eq 'AdoServiceConnection') { $path=$path.Replace('?api-version=7.1', "?projectIds=$($Record.expected.projectId)&api-version=7.1") }
      $null=Invoke-MaesterCleanupAdoRequest $Binding DELETE $path
    }
    Exchange {
      if ($Record.kind -eq 'ExchangeServicePrincipal') { Remove-ServicePrincipal -Identity $Record.exactIds.exchangeServicePrincipalId -Confirm:$false -ErrorAction Stop }
      else { Remove-ManagementRoleAssignment -Identity $Record.exactIds.exchangeRoleAssignmentId -Confirm:$false -ErrorAction Stop }
    }
    default { throw 'Unsupported exact deletion transport.' }
  }
}

function Test-MaesterCleanupExactAbsence {
  param($Entry, $Record, $Binding)
  switch ($Entry.provider) {
    Graph { $response=Invoke-MaesterCleanupGraphRequest $Binding GET $Entry.target; return $response.StatusCode -eq 404 }
    Arm { $api=if ($Record.kind -eq 'ResourceLock') {'2016-09-01'} else {'2022-04-01'}; $response=Invoke-MaesterCleanupArmRequest $Binding GET $Entry.target $api; return $response.StatusCode -eq 404 }
    Ado { $response=Invoke-MaesterCleanupAdoRequest $Binding GET $Entry.target; return $response.StatusCode -eq 404 }
    Exchange { $response=Get-MaesterCleanupExchangeObject $Record; return $response.StatusCode -eq 404 }
    default { throw 'Unsupported exact absence verification transport.' }
  }
}

function Test-MaesterOwnedCleanupPreDown {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][Collections.IDictionary]$Binding, [string]$ApprovedUnlockPlanHash, [switch]$InteractiveConsent, [switch]$PlanOnly)
  $session=Open-MaesterOwnershipJournal -ProjectRoot $ProjectRoot -Binding $Binding -RequireExisting
  try {
    $journal=Get-MaesterOwnershipJournal -Session $session
    Assert-MaesterCleanupJournal $journal
    Assert-MaesterCleanupArmAuthority $journal.binding
    $infraPath=Join-Path $PSScriptRoot 'Maester-InfrastructureOwnership.psm1'
    if (-not (Test-Path -LiteralPath $infraPath)) { throw 'Infrastructure ownership receipt verification is unavailable; refusing azd down.' }
    Import-Module $infraPath -ErrorAction Stop
    $infraArgs=@{ProjectRoot=$ProjectRoot;EnvironmentName=$journal.binding.environmentName;SolutionName=$journal.binding.solutionName;TenantId=$journal.binding.tenantId;SubscriptionId=$journal.binding.subscriptionId;ResourceGroupName=$journal.binding.resourceGroupId.Split('/')[-1]}
    $inventory=Test-MaesterInfrastructureOwnership @infraArgs
    if (-not $inventory.SafeToDelete) {
      if (-not $inventory.SafeToUnlock) { throw "Infrastructure ownership validation blocked down: $($inventory.BlockingReason)" }
      Write-Host "Exact owned resource-lock removal plan: $($inventory.PlanHash)"
      foreach ($id in $inventory.PresentOwnedLockIds) { Write-Host "  Unlock: $id" }
      Write-Host 'If you cancel the later azd deletion, these locks remain removed. Azure resources and external authorization are unchanged by this unlock step.'
      if (-not $PlanOnly) {
        Confirm-MaesterCleanupPlan -PlanHash $inventory.PlanHash -ApprovedPlanHash $ApprovedUnlockPlanHash -InteractiveConsent:$InteractiveConsent -Question 'Remove only these exact owned locks before azd down?'
        $null=Unlock-MaesterInfrastructureLocks @infraArgs -ApprovedPlanHash $inventory.PlanHash
        $inventory=Test-MaesterInfrastructureOwnership @infraArgs
        if (-not $inventory.SafeToDelete) { throw "Infrastructure remains unsafe to delete after exact unlock: $($inventory.BlockingReason)" }
      }
    }
    Write-Host (Get-MaesterCleanupField $inventory 'DeletionWarning' 'Deleting the dedicated owned resource group also removes child resources and stored contents. ARM inventory cannot enumerate every data-plane object.')
    Write-Host 'Pre-down external cleanup is read-only. External authorization remains in place until Azure absence is freshly verified by postdown. Concurrent reprovisioning during down is unsupported.'
    foreach ($record in @($journal.records | Where-Object state -NE 'deleted')) {
      $effect=if ($record.ownership -ceq 'Mutation') { "Discharge only after exact owned parent '$($record.coveredByOperationId)' or bound ARM resource is verified absent" } else { 'Delete only after fresh exact tuple and dependency verification' }
      Write-Host "  Postdown preview: $($record.kind) $(ConvertTo-MaesterCleanupCanonicalJson $record.exactIds) [operation $($record.operationId)]"
      Write-Host "    $effect; expected tuple: $(ConvertTo-MaesterCleanupCanonicalJson $record.expected)"
    }
    return @{Validated=$true;PlanOnly=[bool]$PlanOnly;SafeToDelete=[bool]$inventory.SafeToDelete;ExternalDeletionAttempted=$false;ResourceGroupId=$journal.binding.resourceGroupId;OwnedResourceIds=$inventory.OwnedResourceIds;UnlockPlanHash=$inventory.PlanHash;PresentOwnedLockIds=@($inventory.PresentOwnedLockIds)}
  } finally { $session.Dispose() }
}

function Invoke-MaesterOwnedCleanupPostDown {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][Collections.IDictionary]$Binding, [string]$ApprovedPlanHash, [switch]$InteractiveConsent, [switch]$AllowInteractiveGraphLogin, [switch]$AllowGraphContextReplacement, [switch]$PreviewOnly)
  $session=$null; $azureAbsent=$false
  try {
    $session=Open-MaesterOwnershipJournal -ProjectRoot $ProjectRoot -Binding $Binding -RequireExisting
    $journal=Get-MaesterOwnershipJournal -Session $session
    Assert-MaesterCleanupJournal $journal
    Assert-MaesterCleanupArmAuthority $journal.binding -RequireAbsent
    $azureAbsent=$true
    if (-not @($journal.records | Where-Object state -NE 'deleted').Count) { return @{Completed=$true;PlanHash=$null;DeletedOperationCount=0} }
    $protection=Initialize-MaesterCleanupGraph $journal -AllowInteractiveGraphLogin:$AllowInteractiveGraphLogin -AllowGraphContextReplacement:$AllowGraphContextReplacement
    Initialize-MaesterCleanupExchange $journal
    $plan=New-MaesterOwnedCleanupPlan $journal $protection
    Write-MaesterCleanupPreview $plan
    if ($PreviewOnly) { return $plan }
    Confirm-MaesterCleanupPlan -PlanHash $plan.PlanHash -ApprovedPlanHash $ApprovedPlanHash -InteractiveConsent:$InteractiveConsent
    $count=0
    foreach ($entry in @($plan.Entries | Where-Object action -NE 'CoveredByParent')) {
      # Recheck Azure and the entire local ledger at every destructive boundary.
      Assert-MaesterCleanupArmAuthority $journal.binding -RequireAbsent
      $journal=Get-MaesterOwnershipJournal -Session $session
      Assert-MaesterCleanupJournal $journal
      $record=@($journal.records | Where-Object operationId -CEQ $entry.operationId)[0]
      $fresh=Get-MaesterCleanupTarget $record $journal $protection
      if ($fresh.action -cne $entry.action -or (Get-MaesterCleanupHash $fresh) -cne (Get-MaesterCleanupHash $entry)) { throw 'The exact cleanup target changed after approval; review a fresh plan.' }
      $null=Set-MaesterOwnedOperationState -Session $session -OperationId $record.operationId -State deleting
      if ($entry.action -eq 'Delete') {
        Invoke-MaesterCleanupDelete $entry $record $journal.binding
        $absent=$false
        for ($attempt=1; $attempt -le 6; $attempt++) {
          if (Test-MaesterCleanupExactAbsence $entry $record $journal.binding) { $absent=$true; break }
          if ($attempt -lt 6) { Start-Sleep -Seconds 2 }
        }
        if (-not $absent) { throw "Deletion of '$($record.operationId)' was not confirmed absent within the bounded verification window. Its deleting receipt is retained." }
      }
      $null=Set-MaesterOwnedOperationState -Session $session -OperationId $record.operationId -State deleted
      $count++
    }
    foreach ($entry in @($plan.Entries | Where-Object action -EQ 'CoveredByParent')) {
      $journal=Get-MaesterOwnershipJournal -Session $session
      $record=@($journal.records | Where-Object operationId -CEQ $entry.operationId)[0]
      $parent=@($journal.records | Where-Object operationId -CEQ $record.coveredByOperationId)
      if ($parent.Count -ne 1 -or $parent[0].state -cne 'deleted') { throw 'Covered mutation parent was not independently verified removed.' }
      Assert-MaesterCleanupArmAuthority $journal.binding -RequireAbsent
      $parentState=Get-MaesterCleanupTarget $parent[0] $journal $protection
      if ($parentState.action -cne 'AlreadyAbsent') { throw 'Cleanup conflict: the exact covered parent is present again; its mutation receipt is retained.' }
      $null=Set-MaesterOwnedOperationState -Session $session -OperationId $record.operationId -State deleting
      $null=Set-MaesterOwnedOperationState -Session $session -OperationId $record.operationId -State deleted
      $count++
    }
    return @{Completed=$true;PlanHash=$plan.PlanHash;DeletedOperationCount=$count}
  } catch {
    if ($azureAbsent) {
      $literalRoot=$ProjectRoot.Replace("'", "''")
      $entrypoint=(Join-Path $PSScriptRoot 'Invoke-MaesterDown.ps1').Replace("'", "''")
      $retry="& '$entrypoint' -Phase PostDown -ProjectRoot '$literalRoot' -EnvironmentName '$($Binding.environmentName)' -SolutionName '$($Binding.solutionName)' -TenantId '$($Binding.tenantId)' -SubscriptionId '$($Binding.subscriptionId)' -InteractiveConsent"
      throw "Azure has been removed; external cleanup is incomplete. The ownership journal is retained. Resolve the blocker, then use this entrypoint in an interactive terminal to select fresh normal-browser sign-in if needed and review a fresh cleanup plan. A parent Process session is not transferred: $retry. $($_.Exception.Message)"
    }
    throw
  } finally { if ($null -ne $session) { $session.Dispose() } }
}

function Get-MaesterOwnedCleanupPlan {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][Collections.IDictionary]$Binding, [switch]$AllowInteractiveGraphLogin, [switch]$AllowGraphContextReplacement)
  return Invoke-MaesterOwnedCleanupPostDown -ProjectRoot $ProjectRoot -Binding $Binding -AllowInteractiveGraphLogin:$AllowInteractiveGraphLogin -AllowGraphContextReplacement:$AllowGraphContextReplacement -PreviewOnly
}

# Legacy entry points deliberately reject config-only cleanup rather than guessing IDs.
function Invoke-MaesterStandardPreDownCleanup {
  [CmdletBinding()]
  param([string]$ManagedIdentityPrincipalEnvName, [string]$ProjectRoot, [Collections.IDictionary]$Binding)
  if ($ManagedIdentityPrincipalEnvName) { Write-Verbose 'Legacy environment-variable names are not ownership evidence; only the bound journal is used.' }
  if (-not $ProjectRoot -or -not $Binding) { throw 'Legacy config-only cleanup is unsafe. A bound ownership journal and infrastructure receipt are required; use Test-MaesterOwnedCleanupPreDown.' }
  return Test-MaesterOwnedCleanupPreDown -ProjectRoot $ProjectRoot -Binding $Binding
}
function Invoke-MaesterAzureDevOpsPreDownCleanup {
  [CmdletBinding()]
  param([string]$ProjectRoot, [Collections.IDictionary]$Binding)
  if (-not $ProjectRoot -or -not $Binding) { throw 'Legacy config-only cleanup is unsafe. A bound ownership journal and infrastructure receipt are required; use Test-MaesterOwnedCleanupPreDown.' }
  return Test-MaesterOwnedCleanupPreDown -ProjectRoot $ProjectRoot -Binding $Binding
}

function Resolve-MaesterCleanupBinding {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$SolutionName, [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$SubscriptionId)
  if ($EnvironmentName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or $SolutionName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'Explicit valid environment and solution names are required to resolve a cleanup binding.' }
  foreach ($id in @($TenantId,$SubscriptionId)) { $guid=[guid]::Empty; if (-not [guid]::TryParse($id,[ref]$guid) -or $guid -eq [guid]::Empty) { throw 'Explicit nonempty selected tenant and subscription GUIDs are required.' } }
  $root=[IO.Path]::GetFullPath($ProjectRoot)
  $path=Join-Path $root ".azure/$EnvironmentName/maester-setup-ownership.json"
  $ancestor=$path
  while ($ancestor) {
    try { $attributes=[IO.File]::GetAttributes($ancestor) } catch [IO.FileNotFoundException] { $attributes=$null } catch [IO.DirectoryNotFoundException] { $attributes=$null }
    if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Cleanup binding paths cannot contain symbolic links or reparse points.' }
    $parent=[IO.Path]::GetDirectoryName($ancestor); if ($parent -eq $ancestor) { break }; $ancestor=$parent
  }
  $info=[IO.FileInfo]::new($path)
  if (-not $info.Exists) { throw 'Ownership journal is missing; configuration IDs cannot establish external ownership.' }
  if ($info.Length -le 0 -or $info.Length -gt 2MB) { throw 'Ownership journal has an unsupported size.' }
  $untrusted=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))) -AsHashtable -Depth 16 -ErrorAction Stop
  $binding=Get-MaesterCleanupField $untrusted 'binding'
  foreach ($anchor in @{environmentName=$EnvironmentName;solutionName=$SolutionName;tenantId=([guid]$TenantId).ToString();subscriptionId=([guid]$SubscriptionId).ToString()}.GetEnumerator()) {
    Assert-MaesterCleanupEqual (Get-MaesterCleanupField $binding $anchor.Key) $anchor.Value "selected $($anchor.Key) binding" -CaseSensitive
  }
  # Opening the canonical core rejects duplicates, unsafe metadata, forged schema,
  # mismatched immutable anchors, oversized files and races with lifecycle writers.
  $session=Open-MaesterOwnershipJournal -ProjectRoot $root -Binding $binding -RequireExisting
  try { return (Get-MaesterOwnershipJournal -Session $session).binding } finally { $session.Dispose() }
}

function Test-MaesterCleanupAzureAbsent {
  [CmdletBinding()]
  param([Parameter(Mandatory)][Collections.IDictionary]$Binding)
  Assert-MaesterCleanupArmAuthority $Binding -RequireAbsent
  return $true
}

Export-ModuleMember -Function Get-MaesterOwnedCleanupScopes,Resolve-MaesterCleanupBinding,Test-MaesterCleanupAzureAbsent,Test-MaesterOwnedCleanupPreDown,Invoke-MaesterOwnedCleanupPostDown,Get-MaesterOwnedCleanupPlan,Invoke-MaesterStandardPreDownCleanup,Invoke-MaesterAzureDevOpsPreDownCleanup
