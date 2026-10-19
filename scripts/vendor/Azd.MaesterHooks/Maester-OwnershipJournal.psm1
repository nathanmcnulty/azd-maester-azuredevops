Set-StrictMode -Version Latest

# This is a local, fail-closed ownership ledger, not a remote transaction engine.
# Hold one session for the ENTIRE setup/down sequence, including provider calls.
# Always dispose it in finally. A successful Complete checkpoints a provider
# response, not verified remote state. Cleanup must independently GET exact IDs,
# validate their complete expected tuple, and verify absence before marking deleted.
# An unsigned local file is not evidence against an attacker who can rewrite it.

class MaesterOwnershipJournalSession : System.IDisposable {
  hidden [System.IO.FileStream] $Lock
  hidden [string] $Root
  hidden [string] $JournalPath
  hidden [string] $BindingJson

  MaesterOwnershipJournalSession([System.IO.FileStream] $lock, [string] $root, [string] $path, [string] $bindingJson) {
    $this.Lock = $lock
    $this.Root = $root
    $this.JournalPath = $path
    $this.BindingJson = $bindingJson
  }

  [void] Dispose() {
    if ($null -ne $this.Lock) { $this.Lock.Dispose(); $this.Lock = $null }
  }
}

$script:JournalMaximumBytes = 2MB
$script:JournalMaximumRecords = 512
$script:JournalBindingFields = @('environmentName', 'tenantId', 'subscriptionId', 'solutionName', 'resourceGroupId', 'setupClientId')
$script:JournalOptionalBindingFields = @('runtimeResourceId', 'runtimePrincipalId', 'adoOrganizationUrl', 'adoProjectId', 'organizationName', 'organizationId', 'projectName', 'projectId')
$script:JournalKindContracts = @{
  GraphAppRoleAssignment = @{ expected = @('principalId', 'resourceId', 'appRoleId'); ids = @('assignmentId'); ownership = 'Created'; values = @() }
  DirectoryRoleAssignment = @{ expected = @('principalId', 'roleDefinitionId', 'directoryScopeId'); ids = @('assignmentId'); ownership = 'Created'; values = @() }
  AzureRoleAssignment = @{ expected = @('principalId', 'roleDefinitionId', 'scope'); ids = @('roleAssignmentId'); ownership = 'Created'; values = @() }
  ExchangeServicePrincipal = @{ expected = @('appId', 'servicePrincipalId'); ids = @('exchangeServicePrincipalId'); ownership = 'Created'; values = @() }
  ExchangeRoleAssignment = @{ expected = @('servicePrincipalId', 'roleName'); ids = @('exchangeRoleAssignmentId'); ownership = 'Created'; values = @() }
  EntraApplication = @{ expected = @('purpose', 'displayName'); ids = @('applicationObjectId', 'appId'); ownership = 'Created'; values = @('redirectUris', 'identifierUris', 'groupMembershipClaims', 'enableIdTokenIssuance', 'enableAccessTokenIssuance', 'signInAudience') }
  EntraServicePrincipal = @{ expected = @('appId'); ids = @('servicePrincipalId'); ownership = 'Created'; values = @() }
  FederatedIdentityCredential = @{ expected = @('applicationObjectId', 'issuer', 'subject', 'audiences'); ids = @('federatedCredentialId'); ownership = 'Created'; values = @() }
  OAuth2PermissionGrant = @{ expected = @('clientId', 'resourceId', 'consentType'); ids = @('grantId'); ownership = @('Created', 'Mutation'); values = @('scopes') }
  ApplicationConfiguration = @{ expected = @('applicationObjectId', 'appId'); ids = @('applicationObjectId'); ownership = 'Mutation'; values = @('redirectUris', 'identifierUris', 'groupMembershipClaims', 'enableIdTokenIssuance', 'enableAccessTokenIssuance') }
  WebAppAuthConfiguration = @{ expected = @('webAppResourceId', 'appId'); ids = @('webAppResourceId'); ownership = 'Mutation'; values = @('enabled', 'issuer', 'allowedAudiences', 'allowedGroups', 'excludedPaths', 'requireAuthentication', 'requireHttps', 'unauthenticatedClientAction', 'defaultProvider', 'tokenStoreEnabled', 'clientId') }
  AdoRepository = @{ expected = @('organizationId', 'projectId'); ids = @('repositoryId'); ownership = 'Created'; values = @() }
  AdoServiceConnection = @{ expected = @('organizationId', 'projectId'); ids = @('serviceConnectionId'); ownership = 'Created'; values = @() }
  AdoServiceConnectionBinding = @{ expected = @('organizationId', 'projectId', 'serviceConnectionId', 'applicationObjectId', 'appId'); ids = @('serviceConnectionId'); ownership = 'Mutation'; values = @('appId', 'scope', 'isDraft', 'isReady', 'issuer', 'subject') }
  AdoPipeline = @{ expected = @('organizationId', 'projectId', 'repositoryId', 'yamlPath', 'branch'); ids = @('pipelineId'); ownership = 'Created'; values = @() }
  AdoPipelineAuthorization = @{ expected = @('organizationId', 'projectId', 'resourceType', 'resourceId'); ids = @('resourceId'); ownership = 'Mutation'; values = @('allPipelinesAuthorized', 'pipelineIds') }
  AdoRepositoryPublication = @{ expected = @('organizationId', 'projectId', 'repositoryId', 'branch'); ids = @('repositoryId'); ownership = 'Mutation'; values = @('commitId', 'files') }
  ResourceLock = @{ expected = @('scope', 'level'); ids = @('lockId'); ownership = 'Created'; values = @() }
}
$script:JournalOptionalExpectedFields = @{
  GraphAppRoleAssignment = @('roleValue')
  DirectoryRoleAssignment = @()
  AzureRoleAssignment = @('principalType', 'roleAssignmentId')
  ExchangeServicePrincipal = @('displayName')
  ExchangeRoleAssignment = @('appId')
  EntraApplication = @('webAppResourceId', 'creatorPrincipalId')
  EntraServicePrincipal = @('applicationObjectId', 'appOwnerOrganizationId', 'purpose', 'creatorPrincipalId')
  FederatedIdentityCredential = @('appId', 'servicePrincipalId')
  OAuth2PermissionGrant = @('principalId', 'appId', 'applicationObjectId', 'servicePrincipalId')
  ApplicationConfiguration = @('webAppResourceId')
  WebAppAuthConfiguration = @('applicationObjectId')
  AdoRepository = @('repositoryName')
  AdoServiceConnection = @('serviceConnectionName', 'servicePrincipalId', 'subscriptionId', 'scope', 'isShared')
  AdoServiceConnectionBinding = @('servicePrincipalId')
  AdoPipeline = @('branch', 'yamlPath', 'pipelineName', 'serviceConnectionId')
  AdoPipelineAuthorization = @('pipelineId')
  AdoRepositoryPublication = @('paths')
  ResourceLock = @('lockName')
}

function ConvertTo-MaesterJournalCanonicalJson {
  param([Parameter(Mandatory)]$Value)
  function Convert-CanonicalValue($item) {
    if ($item -is [System.Collections.IDictionary]) {
      $ordered = [ordered]@{}
      $keys = [string[]]@($item.Keys)
      [Array]::Sort($keys, [StringComparer]::Ordinal)
      foreach ($key in $keys) { $ordered[$key] = Convert-CanonicalValue $item[$key] }
      return $ordered
    }
    if ($item -is [System.Collections.IList]) {
      $values = [Collections.Generic.List[object]]::new()
      foreach ($child in $item) { $values.Add((Convert-CanonicalValue $child)) }
      return ,$values.ToArray()
    }
    return $item
  }
  return (Convert-CanonicalValue $Value | ConvertTo-Json -Depth 16 -Compress -WarningAction Stop)
}

function Assert-MaesterJournalFields {
  param($Value, [string[]]$Allowed, [string[]]$Required = @(), [string]$Label = 'object')
  if ($Value -isnot [System.Collections.IDictionary]) { throw "Ownership journal $Label must be a field map." }
  foreach ($key in $Value.Keys) {
    if ($key -isnot [string] -or $key -cnotin $Allowed) { throw "Ownership journal $Label contains an unsupported field." }
  }
  foreach ($key in $Required) {
    if (-not $Value.Contains($key)) { throw "Ownership journal $Label is missing '$key'." }
  }
}

function Assert-MaesterJournalGuid {
  param($Value)
  if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or $Value -eq [guid]::Empty.ToString()) {
    throw 'Ownership journal requires a nonempty lowercase GUID.'
  }
}

function Copy-MaesterJournalInput {
  param([Parameter(Mandatory)]$Value)
  $copy = ConvertFrom-Json -InputObject (ConvertTo-MaesterJournalCanonicalJson $Value) -AsHashtable -DateKind String -Depth 16 -ErrorAction Stop
  function ConvertTo-NormalizedJournalIdentifiers($item) {
    if ($item -is [System.Collections.IDictionary]) {
      foreach ($key in @($item.Keys)) {
        $value = $item[$key]
        if ($value -is [string] -and $key -cmatch '(?:Id|^appId)$' -and $value -match '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { $item[$key] = $value.ToLowerInvariant() }
        elseif ($value -is [string] -and $value -cmatch '^/subscriptions/([0-9a-fA-F-]{36})(/|$)') { $item[$key] = $value.Replace($Matches[1], $Matches[1].ToLowerInvariant()) }
        else { ConvertTo-NormalizedJournalIdentifiers $value }
      }
    } elseif ($item -is [System.Collections.IList]) {
      foreach ($child in $item) { ConvertTo-NormalizedJournalIdentifiers $child }
    }
  }
  ConvertTo-NormalizedJournalIdentifiers $copy
  return $copy
}

function Assert-MaesterJournalArmId {
  param($Value, [string]$SubscriptionId, [switch]$ResourceGroupOnly)
  if ($Value -isnot [string] -or $Value.Length -gt 2048 -or $Value -match '[%?#\\\s]' -or $Value -match '(^|/)\.{1,2}(/|$)' -or $Value.Contains('//')) {
    throw 'Ownership journal contains an unsafe ARM target.'
  }
  $pattern = '^/subscriptions/(?<subscription>[0-9a-f-]{36})/resourceGroups/(?<group>[A-Za-z0-9_().-]{1,90})$'
  if (-not $ResourceGroupOnly) { $pattern = '^/subscriptions/(?<subscription>[0-9a-f-]{36})(?:/(?:resourceGroups/[A-Za-z0-9_().-]{1,90}|providers/[A-Za-z0-9.-]+)(?:/[A-Za-z0-9_().-]+)*)?$|^/providers/Microsoft.Management/managementGroups/[A-Za-z0-9_().-]+(?:/providers/Microsoft.Authorization/(?:roleAssignments|roleDefinitions)/[0-9a-f-]{36})?$|^/providers/Microsoft.Authorization/roleDefinitions/[0-9a-f-]{36}$' }
  if ($Value -cnotmatch $pattern) { throw 'Ownership journal contains an invalid ARM target.' }
  if ($Matches.ContainsKey('subscription')) {
    Assert-MaesterJournalGuid $Matches.subscription
    if ($SubscriptionId -and $Matches.subscription -cne $SubscriptionId) { throw 'Ownership journal ARM target has a different subscription binding.' }
  }
}

function Assert-MaesterJournalBinding {
  param($Binding)
  Assert-MaesterJournalFields $Binding @($script:JournalBindingFields + $script:JournalOptionalBindingFields) $script:JournalBindingFields 'binding'
  foreach ($field in @('tenantId', 'subscriptionId', 'setupClientId')) { Assert-MaesterJournalGuid $Binding[$field] }
  foreach ($field in @('environmentName', 'solutionName')) {
    if ($Binding[$field] -isnot [string] -or $Binding[$field] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw "Ownership journal has an unsafe $field." }
  }
  Assert-MaesterJournalArmId $Binding.resourceGroupId $Binding.subscriptionId -ResourceGroupOnly
  foreach ($field in $script:JournalOptionalBindingFields) {
    if ($Binding.Contains($field)) { Assert-MaesterJournalMetadataValue $field $Binding[$field] $Binding 'binding' '' }
  }
}

function Assert-MaesterJournalSafePath {
  param([Parameter(Mandatory)][string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  $current = $fullPath
  while ($current) {
    # GetAttributes also detects dangling symlinks on supported .NET platforms.
    try { $attributes = [IO.File]::GetAttributes($current) }
    catch [IO.FileNotFoundException] { $attributes = $null }
    catch [IO.DirectoryNotFoundException] { $attributes = $null }
    if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Ownership journal paths must not contain reparse points or symbolic links.' }
    $parent = [IO.Path]::GetDirectoryName($current)
    if ($parent -eq $current) { break }
    $current = $parent
  }
}

function Assert-MaesterJournalSession {
  param($Session)
  if ($Session -isnot [MaesterOwnershipJournalSession] -or $null -eq $Session.Lock -or -not $Session.Lock.CanRead) { throw 'An open ownership journal session is required; keep its lifecycle lock until provider work finishes.' }
  $binding = ConvertFrom-Json -InputObject $Session.BindingJson -AsHashtable -DateKind String -Depth 16 -ErrorAction Stop
  Assert-MaesterJournalBinding $binding
  $expected = Join-Path $Session.Root ".azure/$($binding.environmentName)/maester-setup-ownership.json"
  if ($expected -cne $Session.JournalPath) { throw 'Ownership journal session path binding changed.' }
  Assert-MaesterJournalSafePath $Session.JournalPath
  Assert-MaesterJournalSafePath "$($Session.JournalPath).lock"
  return $binding
}

function Assert-MaesterJournalJsonKeys {
  param([System.Text.Json.JsonElement]$Element)
  if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($property in $Element.EnumerateObject()) {
      if (-not $names.Add($property.Name)) { throw 'Ownership journal JSON contains duplicate field names.' }
      Assert-MaesterJournalJsonKeys $property.Value
    }
  } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
    foreach ($child in $Element.EnumerateArray()) { Assert-MaesterJournalJsonKeys $child }
  }
}

function Read-MaesterJournalFile {
  param([MaesterOwnershipJournalSession]$Session)
  $binding = Assert-MaesterJournalSession $Session
  $info = [IO.FileInfo]::new($Session.JournalPath)
  if (-not $info.Exists) { throw 'Ownership journal is missing. Configuration IDs are not ownership evidence.' }
  if ($info.Length -le 0 -or $info.Length -gt $script:JournalMaximumBytes) { throw 'Ownership journal exceeds the supported size or is empty.' }
  $json = [IO.File]::ReadAllText($Session.JournalPath, [Text.UTF8Encoding]::new($false, $true))
  if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:JournalMaximumBytes) { throw 'Ownership journal exceeds the supported size.' }
  $options = [System.Text.Json.JsonDocumentOptions]::new()
  $options.MaxDepth = 16
  $document = [System.Text.Json.JsonDocument]::Parse($json, $options)
  try { Assert-MaesterJournalJsonKeys $document.RootElement } finally { $document.Dispose() }
  $journal = ConvertFrom-Json -InputObject $json -AsHashtable -DateKind String -Depth 16 -ErrorAction Stop
  Assert-MaesterJournalDocument $journal $binding
  return $journal
}

function Write-MaesterJournalFile {
  param([MaesterOwnershipJournalSession]$Session, $Journal)
  $binding = Assert-MaesterJournalSession $Session
  Assert-MaesterJournalDocument $Journal $binding
  $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes((ConvertTo-MaesterJournalCanonicalJson $Journal))
  if ($bytes.Length -gt $script:JournalMaximumBytes) { throw 'Ownership journal exceeds the supported size.' }
  $temporaryPath = "$($Session.JournalPath).$([guid]::NewGuid().ToString('N')).tmp"
  $stream = $null
  try {
    $stream = [IO.FileStream]::new($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
    $stream.Dispose(); $stream = $null
    Assert-MaesterJournalSession $Session | Out-Null
    Move-MaesterJournalCheckpoint $temporaryPath $Session.JournalPath
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
    if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
  }
}

function Move-MaesterJournalCheckpoint {
  param([string]$Source, [string]$Destination)
  # Same-directory rename is atomic; do not truncate or delete the previous file.
  [IO.File]::Move($Source, $Destination, $true)
}

function Assert-MaesterJournalMetadataValue {
  param([string]$Name, $Value, $Binding, [string]$Section, [string]$Kind)
  # A missing provider property is different from an empty list/false value.
  # Only the allowlisted mutation value maps may represent such absence.
  if ($Section -cin @('before', 'after') -and ($null -eq $Value -or $Value -ceq '')) { return }
  $guidFields = @('tenantId', 'subscriptionId', 'setupClientId', 'runtimePrincipalId', 'principalId', 'creatorPrincipalId', 'appRoleId', 'appId', 'applicationObjectId', 'servicePrincipalId', 'appOwnerOrganizationId', 'clientId', 'organizationId', 'projectId', 'adoProjectId', 'repositoryId', 'serviceConnectionId', 'exchangeServicePrincipalId', 'coveredByOperationId')
  $armFields = @('resourceGroupId', 'runtimeResourceId', 'webAppResourceId', 'roleAssignmentId', 'lockId')
  $subscription = if ($Kind -ceq 'AzureRoleAssignment' -and $Name -cin @('scope', 'roleDefinitionId', 'roleAssignmentId')) { '' } else { $Binding.subscriptionId }
  if ($Name -cin $guidFields) { Assert-MaesterJournalGuid $Value; return }
  if ($Name -cin $armFields) { Assert-MaesterJournalArmId $Value $subscription; return }
  if ($Name -cin @('resourceId', 'roleDefinitionId')) {
    if ($Name -ceq 'resourceId' -and $Kind -ceq 'AdoPipelineAuthorization' -and $Value -is [string] -and $Value -cmatch '^([0-9a-f-]{36})\.([0-9a-f-]{36})$') {
      Assert-MaesterJournalGuid $Matches[1]
      Assert-MaesterJournalGuid $Matches[2]
      return
    }
    if ($Name -ceq 'resourceId' -or $Kind -ceq 'DirectoryRoleAssignment') { Assert-MaesterJournalGuid $Value; return }
    if ($Value -is [string] -and $Value.StartsWith('/')) { Assert-MaesterJournalArmId $Value $subscription } else { Assert-MaesterJournalGuid $Value }
    return
  }
  if ($Name -ceq 'scope') { Assert-MaesterJournalArmId $Value $subscription; return }
  if ($Name -ceq 'directoryScopeId') {
    if ($Value -cne '/' -and $Value -cnotmatch '^/administrativeUnits/[0-9a-f-]{36}$') { throw 'Ownership journal has an unsafe directory scope.' }
    if ($Value -cne '/') { Assert-MaesterJournalGuid ($Value.Split('/')[-1]) }
    return
  }
  if ($Name -cin @('assignmentId', 'grantId', 'federatedCredentialId')) {
    # Conservative accepted representation, not a claim that Graph documents a
    # universal ID charset. Provider handlers must still EscapeDataString IDs.
    if ($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z0-9_~.-]{1,512}$' -or $Value -cin @('.', '..')) { throw 'Ownership journal has an unsafe opaque provider ID.' }
    return
  }
  if ($Name -ceq 'exchangeRoleAssignmentId') {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 _.@:/\\-]{0,511}$') { throw 'Ownership journal has an unsafe Exchange assignment identity.' }
    return
  }
  if ($Name -cin @('pipelineId', 'pipelineRevision')) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[1-9][0-9]{0,9}$' -or [long]$Value -gt [int]::MaxValue) { throw 'Ownership journal requires a positive pipeline ID string.' }
    return
  }
  if ($Name -ceq 'revision') {
    if ($Value -isnot [long] -and $Value -isnot [int]) { throw 'Ownership journal requires an integer pipeline revision.' }
    if ($Value -lt 1 -or $Value -gt [int]::MaxValue) { throw 'Ownership journal has an invalid pipeline revision.' }
    return
  }
  if ($Name -cin @('enabled', 'requireAuthentication', 'requireHttps', 'tokenStoreEnabled', 'allPipelinesAuthorized', 'enableIdTokenIssuance', 'enableAccessTokenIssuance', 'isShared', 'isDraft', 'isReady')) {
    if ($Value -isnot [bool]) { throw 'Ownership journal requires a Boolean configuration value.' }
    return
  }
  if ($Name -cin @('issuer', 'adoOrganizationUrl')) {
    $uri = $null
    if ($Value -isnot [string] -or $Value.Length -gt 2048 -or -not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Ownership journal accepts only safe HTTPS metadata URLs without credentials, query or fragment.' }
    if ($Name -ceq 'adoOrganizationUrl' -and $Value -cnotmatch '^https://dev\.azure\.com/[A-Za-z0-9][A-Za-z0-9-]{0,63}/?$') { throw 'Ownership journal has an invalid ADO organization URL.' }
    return
  }
  if ($Name -cin @('audiences', 'redirectUris', 'identifierUris', 'allowedAudiences', 'allowedGroups', 'excludedPaths', 'scopes', 'pipelineIds', 'paths', 'files')) {
    if ($Value -isnot [System.Collections.IList] -or $Value.Count -gt 256) { throw 'Ownership journal requires a bounded metadata array.' }
    foreach ($item in $Value) {
      if ($Name -ceq 'allowedGroups') { Assert-MaesterJournalGuid $item; continue }
      if ($Name -ceq 'pipelineIds') { Assert-MaesterJournalMetadataValue 'pipelineId' $item $Binding $Section $Kind; continue }
      if ($Name -ceq 'files' -and $item -is [System.Collections.IDictionary]) {
        Assert-MaesterJournalFields $item @('path', 'blobId') @('path', 'blobId') 'file identity'
        Assert-MaesterJournalMetadataValue 'path' $item.path $Binding $Section $Kind
        if ($null -ne $item.blobId) { Assert-MaesterJournalMetadataValue 'commitId' $item.blobId $Binding $Section $Kind }
        continue
      }
      $field = switch ($Name) {
        'scopes' { 'permissionName' }
        'paths' { 'path' }
        'files' { 'path' }
        'redirectUris' { 'issuer' }
        default { 'text' }
      }
      Assert-MaesterJournalMetadataValue $field $item $Binding $Section $Kind
    }
    return
  }
  if ($Name -ceq 'commitId') {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{40}$') { throw 'Ownership journal requires an exact Git object ID.' }
    return
  }
  if ($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 2048 -or $Value -match '[\x00-\x1f\x7f]') { throw 'Ownership journal has an unsafe metadata string.' }
  if ($Name -cin @('path', 'yamlPath')) {
    # ADO's exact definition yamlFilename normally starts with one slash;
    # publication file paths remain relative to the repository root.
    if ($Value -match '(^|/)\.{1,2}(/|$)' -or $Value -match '[\\:?*<>|]' -or $Value.Contains('//') -or $Value -ceq '/' -or ($Name -ceq 'path' -and $Value.StartsWith('/'))) { throw 'Ownership journal has an unsafe repository path.' }
  }
  if ($Name -ceq 'permissionName' -and $Value -cnotmatch '^[A-Za-z][A-Za-z0-9_.-]{0,127}$') { throw 'Ownership journal has an invalid permission name.' }
  $enums = @{
    purpose = @('Runtime', 'EasyAuth')
    consentType = @('AllPrincipals', 'Principal')
    principalType = @('ServicePrincipal', 'User', 'Group')
    resourceType = @('repository', 'endpoint')
    level = @('CanNotDelete', 'ReadOnly')
    groupMembershipClaims = @('None', 'SecurityGroup', 'All', 'DirectoryRole', 'ApplicationGroup')
    signInAudience = @('AzureADMyOrg', 'AzureADMultipleOrgs', 'AzureADandPersonalMicrosoftAccount', 'PersonalMicrosoftAccount')
    unauthenticatedClientAction = @('RedirectToLoginPage', 'Return401', 'Return403', 'AllowAnonymous')
    defaultProvider = @('azureactivedirectory')
  }
  if ($enums.ContainsKey($Name) -and $Value -cnotin $enums[$Name]) { throw 'Ownership journal has an unsupported metadata enum value.' }
}

function Assert-MaesterJournalMetadata {
  param($Value, [string[]]$Allowed, [string[]]$Required, $Binding, [string]$Section, [string]$Kind)
  Assert-MaesterJournalFields $Value $Allowed $Required $Section
  if ($Value.Count -gt 32) { throw 'Ownership journal metadata has too many fields.' }
  foreach ($key in $Value.Keys) {
    Assert-MaesterJournalMetadataValue $key $Value[$key] $Binding $Section $Kind
    if ($key -ceq 'tenantId' -and $Value[$key] -cne $Binding.tenantId) { throw 'Ownership journal tenant metadata does not match its binding.' }
    if ($key -ceq 'subscriptionId' -and $Value[$key] -cne $Binding.subscriptionId) { throw 'Ownership journal subscription metadata does not match its binding.' }
    if ($key -cin @('appId', 'clientId') -and $Value[$key] -ceq $Binding.setupClientId) { throw 'Ownership journal cannot own or mutate the protected setup client.' }
    foreach ($anchor in @('runtimeResourceId', 'runtimePrincipalId', 'organizationId', 'projectId')) {
      if ($key -ceq $anchor -and $Binding.Contains($anchor) -and $Value[$key] -cne $Binding[$anchor]) { throw "Ownership journal $anchor metadata differs from its immutable binding." }
    }
    if ($key -ceq 'projectId' -and $Binding.Contains('adoProjectId') -and $Value[$key] -cne $Binding.adoProjectId) { throw 'Ownership journal project metadata differs from its immutable binding.' }
  }
}

function Assert-MaesterJournalDocument {
  param($Journal, $Binding)
  Assert-MaesterJournalFields $Journal @('schemaVersion', 'binding', 'records') @('schemaVersion', 'binding', 'records') 'document'
  if ($Journal.schemaVersion -cne '1.0') { throw 'Unsupported ownership journal schema version.' }
  Assert-MaesterJournalBinding $Journal.binding
  if ((ConvertTo-MaesterJournalCanonicalJson $Journal.binding) -cne (ConvertTo-MaesterJournalCanonicalJson $Binding)) { throw 'Ownership journal binding does not match the selected deployment.' }
  if ($Journal.records -isnot [System.Collections.IList] -or $Journal.records.Count -gt $script:JournalMaximumRecords) { throw 'Ownership journal records must be a bounded array.' }
  $operations = @{}
  $activeKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($record in $Journal.records) {
    $fields = @('operationId', 'key', 'kind', 'planHash', 'ownership', 'state', 'expected', 'exactIds', 'before', 'after', 'coveredByOperationId', 'createdUtc', 'updatedUtc')
    Assert-MaesterJournalFields $record $fields $fields 'record'
    Assert-MaesterJournalGuid $record.operationId
    if ($operations.ContainsKey($record.operationId)) { throw 'Ownership journal contains duplicate operation IDs.' }
    $operations[$record.operationId] = $record
    if ($record.key -isnot [string] -or $record.key -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,255}$' -or $record.key -match '(^|/)\.{1,2}(/|$)') { throw 'Ownership journal contains an unsafe operation key.' }
    if ($record.planHash -isnot [string] -or $record.planHash -cnotmatch '^[0-9a-f]{64}$') { throw 'Ownership journal requires an exact lowercase SHA256 plan hash.' }
    if ($record.kind -isnot [string] -or $record.kind -cnotin @($script:JournalKindContracts.Keys)) { throw 'Ownership journal contains an unsupported operation kind.' }
    $contract = $script:JournalKindContracts[$record.kind]
    if ($record.ownership -cnotin @($contract.ownership) -or $record.state -cnotin @('pending', 'applied', 'deleting', 'deleted', 'conflict')) { throw 'Ownership journal contains an invalid ownership or state value.' }
    if ($record.state -cne 'deleted' -and -not $activeKeys.Add($record.key)) { throw 'Ownership journal contains duplicate active operation keys.' }
    $expectedAllowed = @($contract.expected + $script:JournalOptionalExpectedFields[$record.kind] + @('tenantId', 'runtimeResourceId', 'runtimePrincipalId'))
    Assert-MaesterJournalMetadata $record.expected $expectedAllowed $contract.expected $Binding 'expected' $record.kind
    $requiredIds = if ($record.state -cin @('applied', 'deleting', 'deleted')) { $contract.ids } else { @() }
    $allowedIds = @($contract.ids)
    if ($record.kind -ceq 'AdoPipeline') { $allowedIds += @('revision', 'pipelineRevision') }
    if ($record.kind -ceq 'AdoRepositoryPublication') { $allowedIds += 'commitId' }
    Assert-MaesterJournalMetadata $record.exactIds $allowedIds $requiredIds $Binding 'exactIds' $record.kind
    if ($record.state -ceq 'pending' -and $record.exactIds.Count) { throw 'Pending ownership journal operations cannot claim response IDs.' }
    foreach ($id in $record.exactIds.Keys) {
      if ($record.expected.Contains($id) -and $record.expected[$id] -cne $record.exactIds[$id]) { throw 'Ownership journal response identity differs from the expected identity.' }
    }
    if ($record.kind -ceq 'AdoPipeline' -and $record.exactIds.Contains('revision') -and $record.exactIds.Contains('pipelineRevision') -and [long]$record.exactIds.revision -ne [long]$record.exactIds.pipelineRevision) { throw 'Ownership journal pipeline revision metadata disagrees.' }
    if ($record.kind -ceq 'AdoPipelineAuthorization') {
      if ($record.expected.resourceType -ceq 'repository') {
        if (-not $record.expected.resourceId.StartsWith("$($record.expected.projectId).", [StringComparison]::Ordinal)) { throw 'Ownership journal repository authorization must identify its exact project and repository.' }
      } else { Assert-MaesterJournalGuid $record.expected.resourceId }
    }
    if ($record.kind -ceq 'OAuth2PermissionGrant' -and $record.expected.Contains('servicePrincipalId') -and $record.expected.servicePrincipalId -cne $record.expected.clientId) { throw 'Ownership journal OAuth client and service principal identities disagree.' }
    if ($record.kind -ceq 'AzureRoleAssignment') {
      foreach ($ids in @($record.expected, $record.exactIds)) {
        if ($ids.Contains('roleAssignmentId') -and $ids.roleAssignmentId -cnotmatch ('^' + [regex]::Escape($record.expected.scope) + '/providers/Microsoft\.Authorization/roleAssignments/[0-9a-f-]{36}$')) { throw 'Ownership journal role assignment is outside its explicit scope.' }
      }
      if ($record.expected.scope -cmatch '^/subscriptions/([0-9a-f-]{36})(?:/|$)') {
        $scopeSubscription = $Matches[1]
        if ($record.expected.roleDefinitionId -cmatch '^/subscriptions/([0-9a-f-]{36})/' -and $Matches[1] -cne $scopeSubscription) { throw 'Ownership journal role definition is in a different subscription from its scope.' }
      }
    }
    Assert-MaesterJournalMetadata $record.before $contract.values @() $Binding 'before' $record.kind
    Assert-MaesterJournalMetadata $record.after $contract.values @() $Binding 'after' $record.kind
    if ($null -ne $record.coveredByOperationId) {
      Assert-MaesterJournalGuid $record.coveredByOperationId
      if ($record.ownership -cne 'Mutation') { throw 'Only mutations may be covered by an owned parent operation.' }
    } elseif ($record.ownership -ceq 'Mutation' -and ($record.before.Count -eq 0 -or $record.after.Count -eq 0)) {
      throw 'A shared mutation requires sanitized before and after values.'
    }
    foreach ($timestamp in @($record.createdUtc, $record.updatedUtc)) {
      $parsed = [DateTimeOffset]::MinValue
      if ($timestamp -isnot [string] -or -not [DateTimeOffset]::TryParseExact($timestamp, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed) -or $parsed.Offset -ne [TimeSpan]::Zero) { throw 'Ownership journal has an invalid UTC checkpoint timestamp.' }
    }
  }
  foreach ($record in $Journal.records) {
    if ($null -eq $record.coveredByOperationId) { continue }
    if (-not $operations.ContainsKey($record.coveredByOperationId)) { throw 'Ownership journal references a missing parent operation.' }
    $parent = $operations[$record.coveredByOperationId]
    if ($parent.ownership -cne 'Created' -or $parent.state -ceq 'pending' -or $parent.exactIds.Count -eq 0 -or $parent.operationId -ceq $record.operationId) { throw 'Ownership journal parent does not prove an acknowledged owned creation.' }
    # A finite relationship map prevents an unrelated coincident ID from
    # becoming deletion coverage. Every required parent identity must match.
    $sameProject = $parent.expected.Contains('organizationId') -and $parent.expected.Contains('projectId') -and $record.expected.Contains('organizationId') -and $record.expected.Contains('projectId') -and $record.expected.organizationId -ceq $parent.expected.organizationId -and $record.expected.projectId -ceq $parent.expected.projectId
    $matchesParent = switch ($record.kind) {
      ApplicationConfiguration { $parent.kind -ceq 'EntraApplication' -and $record.expected.applicationObjectId -ceq $parent.exactIds.applicationObjectId -and $record.expected.appId -ceq $parent.exactIds.appId }
      OAuth2PermissionGrant { $parent.kind -ceq 'EntraServicePrincipal' -and $record.expected.clientId -ceq $parent.exactIds.servicePrincipalId -and (-not $record.expected.Contains('appId') -or $record.expected.appId -ceq $parent.expected.appId) }
      AdoServiceConnectionBinding { $sameProject -and $parent.kind -ceq 'AdoServiceConnection' -and $record.expected.serviceConnectionId -ceq $parent.exactIds.serviceConnectionId }
      AdoPipelineAuthorization {
        $sameProject -and (($record.expected.resourceType -ceq 'endpoint' -and $parent.kind -ceq 'AdoServiceConnection' -and $record.expected.resourceId -ceq $parent.exactIds.serviceConnectionId) -or
          ($record.expected.resourceType -ceq 'repository' -and $parent.kind -ceq 'AdoRepository' -and $record.expected.resourceId -ceq "$($parent.expected.projectId).$($parent.exactIds.repositoryId)"))
      }
      AdoRepositoryPublication { $sameProject -and $parent.kind -ceq 'AdoRepository' -and $record.expected.repositoryId -ceq $parent.exactIds.repositoryId }
      default { $false }
    }
    if (-not $matchesParent) { throw 'Ownership journal covered mutation does not identify its exact owned parent.' }
  }
}

function Open-MaesterOwnershipJournal {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Binding,
    [switch]$RequireExisting,
    [ValidateRange(0, 30000)][int]$LockTimeoutMilliseconds = 5000
  )
  $bindingCopy = Copy-MaesterJournalInput $Binding
  Assert-MaesterJournalBinding $bindingCopy
  if (-not [IO.Path]::IsPathFullyQualified($ProjectRoot) -or $ProjectRoot -match '(^|[\\/])\.{1,2}([\\/]|$)') { throw 'Ownership journal requires an absolute project root without traversal.' }
  $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
  if (-not [IO.Directory]::Exists($root)) { throw 'Ownership journal project root does not exist.' }
  Assert-MaesterJournalSafePath $root
  $path = Join-Path $root ".azure/$($bindingCopy.environmentName)/maester-setup-ownership.json"
  Assert-MaesterJournalSafePath $path
  if ($RequireExisting -and -not [IO.File]::Exists($path)) { throw 'Ownership journal is missing. Configuration IDs are not ownership evidence.' }
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
  Assert-MaesterJournalSafePath $path
  $lockPath = "$path.lock"
  Assert-MaesterJournalSafePath $lockPath
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $lock = $null
  do {
    try { $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] {
      if ($watch.ElapsedMilliseconds -ge $LockTimeoutMilliseconds) { throw 'Ownership journal lifecycle lock is held by another setup/down operation, or cannot be opened.' }
      Start-Sleep -Milliseconds ([Math]::Min(50, [Math]::Max(1, $LockTimeoutMilliseconds - $watch.ElapsedMilliseconds)))
    }
  } while ($null -eq $lock)
  $session = [MaesterOwnershipJournalSession]::new($lock, $root, $path, (ConvertTo-MaesterJournalCanonicalJson $bindingCopy))
  try {
    Assert-MaesterJournalSession $session | Out-Null
    if ([IO.File]::Exists($path)) { Read-MaesterJournalFile $session | Out-Null }
    elseif ($RequireExisting) { throw 'Ownership journal disappeared while opening its lifecycle lock.' }
    else { Write-MaesterJournalFile $session @{ schemaVersion = '1.0'; binding = $bindingCopy; records = @() } }
    return $session
  } catch { $session.Dispose(); throw }
}

function Get-MaesterOwnershipJournal {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Session)
  Assert-MaesterJournalSession $Session | Out-Null
  return (Read-MaesterJournalFile $Session)
}

function Start-MaesterOwnedOperation {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][string]$PlanHash,
    [Parameter(Mandatory)][ValidateSet('Created', 'Mutation')][string]$Ownership,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Expected,
    [System.Collections.IDictionary]$Before = @{},
    [System.Collections.IDictionary]$After = @{},
    [string]$CoveredByOperationId
  )
  $journal = Get-MaesterOwnershipJournal $Session
  $existing = @($journal.records | Where-Object { $_.key -ceq $Key -and $_.state -cne 'deleted' })
  if ($existing.Count) { throw "Ownership operation '$Key' already exists ($($existing[0].state)); do not repeat the remote write. Inspect the existing receipt." }
  $now = [DateTimeOffset]::UtcNow.ToString('o')
  $record = @{
    operationId = [guid]::NewGuid().ToString()
    key = $Key
    kind = $Kind
    planHash = $PlanHash.ToLowerInvariant()
    ownership = $Ownership
    state = 'pending'
    expected = Copy-MaesterJournalInput $Expected
    exactIds = @{}
    before = Copy-MaesterJournalInput $Before
    after = Copy-MaesterJournalInput $After
    coveredByOperationId = if ($CoveredByOperationId) { $CoveredByOperationId.ToLowerInvariant() } else { $null }
    createdUtc = $now
    updatedUtc = $now
  }
  if ($CoveredByOperationId) {
    $parent = @($journal.records | Where-Object { $_.operationId -ceq $record.coveredByOperationId })
    if ($parent.Count -ne 1 -or $parent[0].state -cne 'applied' -or $parent[0].ownership -cne 'Created') { throw 'A covering parent must be an applied owned creation before the child mutation starts.' }
  }
  $tuple = ConvertTo-MaesterJournalCanonicalJson $record.expected
  if ($script:JournalKindContracts.ContainsKey($Kind)) {
    $identityFields = $script:JournalKindContracts[$Kind].expected
    $identity = @{}
    foreach ($field in $identityFields) { $identity[$field] = $record.expected[$field] }
    $tuple = ConvertTo-MaesterJournalCanonicalJson $identity
    foreach ($prior in @($journal.records | Where-Object { $_.state -cne 'deleted' -and $_.kind -ceq $Kind })) {
      $priorIdentity = @{}
      foreach ($field in $identityFields) { $priorIdentity[$field] = $prior.expected[$field] }
      if ((ConvertTo-MaesterJournalCanonicalJson $priorIdentity) -ceq $tuple) { throw 'The same active ownership target tuple already exists under another operation key; do not repeat the remote write.' }
    }
  }
  $journal.records = @($journal.records) + @($record)
  Write-MaesterJournalFile $Session $journal
  return (Copy-MaesterJournalInput $record)
}

function Complete-MaesterOwnedOperation {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][string]$OperationId,
    [Parameter(Mandatory)][System.Collections.IDictionary]$ExactIds,
    [System.Collections.IDictionary]$After
  )
  $journal = Get-MaesterOwnershipJournal $Session
  $id = $OperationId.ToLowerInvariant()
  Assert-MaesterJournalGuid $id
  $matchingRecords = @($journal.records | Where-Object { $_.operationId -ceq $id })
  if ($matchingRecords.Count -ne 1) { throw 'Ownership operation was not found.' }
  $record = $matchingRecords[0]
  $ids = Copy-MaesterJournalInput $ExactIds
  if ($record.state -ceq 'applied') {
    foreach ($key in $record.exactIds.Keys) {
      if (-not $ids.Contains($key) -or $ids[$key] -cne $record.exactIds[$key]) { throw 'An applied ownership receipt cannot be replaced with different response metadata.' }
    }
    if ($PSBoundParameters.ContainsKey('After') -and (ConvertTo-MaesterJournalCanonicalJson $record.after) -cne (ConvertTo-MaesterJournalCanonicalJson (Copy-MaesterJournalInput $After))) { throw 'An applied ownership receipt cannot be replaced with different response metadata.' }
    if ((ConvertTo-MaesterJournalCanonicalJson $record.exactIds) -cne (ConvertTo-MaesterJournalCanonicalJson $ids)) {
      $record.exactIds = $ids
      $record.updatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
      Write-MaesterJournalFile $Session $journal
    }
    return (Copy-MaesterJournalInput $record)
  }
  if ($record.state -cne 'pending') { throw 'Only the original pending operation may acknowledge a provider response.' }
  $record.exactIds = $ids
  if ($PSBoundParameters.ContainsKey('After')) { $record.after = Copy-MaesterJournalInput $After }
  $record.state = 'applied'
  $record.updatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
  Write-MaesterJournalFile $Session $journal
  return (Copy-MaesterJournalInput $record)
}

function Set-MaesterOwnedOperationState {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][string]$OperationId,
    [Parameter(Mandatory)][ValidateSet('deleting', 'deleted', 'conflict')][string]$State
  )
  $journal = Get-MaesterOwnershipJournal $Session
  $id = $OperationId.ToLowerInvariant()
  Assert-MaesterJournalGuid $id
  $matchingRecords = @($journal.records | Where-Object { $_.operationId -ceq $id })
  if ($matchingRecords.Count -ne 1) { throw 'Ownership operation was not found.' }
  $record = $matchingRecords[0]
  if ($record.state -ceq $State) { return (Copy-MaesterJournalInput $record) }
  $allowed = @{ pending = @('conflict'); applied = @('deleting', 'conflict'); deleting = @('deleted', 'conflict'); deleted = @(); conflict = @() }
  if ($State -cnotin $allowed[$record.state]) { throw "Invalid ownership journal state transition from '$($record.state)' to '$State'." }
  if ($State -ceq 'deleting' -and @($journal.records | Where-Object { $_.coveredByOperationId -ceq $id -and $_.state -cin @('pending', 'conflict') }).Count) { throw 'An owned parent has an unresolved covered mutation; cleanup must stop.' }
  $record.state = $State
  $record.updatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
  Write-MaesterJournalFile $Session $journal
  return (Copy-MaesterJournalInput $record)
}

Export-ModuleMember -Function Open-MaesterOwnershipJournal, Get-MaesterOwnershipJournal, Start-MaesterOwnedOperation, Complete-MaesterOwnedOperation, Set-MaesterOwnedOperationState
