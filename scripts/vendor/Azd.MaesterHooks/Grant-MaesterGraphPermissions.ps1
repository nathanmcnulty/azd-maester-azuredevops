[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'ExpectedFederatedCredentialIssuer', Justification = 'The federation issuer is a nonsecret trust identifier included in the approval plan, not credential material.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'ExpectedFederatedCredentialSubject', Justification = 'The federation subject is a nonsecret trust identifier included in the approval plan, not credential material.')]
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TenantId,

  [Parameter(Mandatory = $true)]
  [string]$PrincipalObjectId,

  [Parameter(Mandatory = $false)]
  [ValidateSet('Minimal', 'Full', 'Extended')]
  [string]$PermissionProfile = 'Full',

  [Parameter(Mandatory = $false)]
  [string[]]$AppRoleValues,

  [Parameter(Mandatory = $false)]
  [bool]$IncludeMailSend = $false,

  [bool]$IncludeReportSettingsWrite = $false,

  [switch]$Apply,

  [string]$ApprovedPlanHash,

  [ValidateSet('ManagedIdentity', 'FederatedApplication')]
  [string]$TargetType = 'ManagedIdentity',

  [string]$ExpectedApplicationId,
  [string]$ExpectedApplicationObjectId,
  [string]$ExpectedFederatedCredentialIssuer,
  [string]$ExpectedFederatedCredentialSubject,

  # Optional for independent direct use; azd setup callers must supply their
  # lifetime-locked journal so each successful grant survives later failures.
  $OwnershipSession
)

$TargetType = if ($TargetType -ieq 'FederatedApplication') { 'FederatedApplication' } else { 'ManagedIdentity' }

$manifestPath = Join-Path $PSScriptRoot 'Maester-GraphPermissions.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
if ($manifest.schemaVersion -cne '1.0' -or $manifest.maesterVersion -cne '2.3.0' -or
    -not $manifest.profiles.ContainsKey($PermissionProfile)) {
  throw 'Unsupported Maester permission manifest or profile.'
}
if (-not $PSBoundParameters.ContainsKey('AppRoleValues')) {
  $AppRoleValues = @($manifest.profiles[$PermissionProfile])
  if ($IncludeMailSend) { $AppRoleValues += @($manifest.optionalCapabilities.MailSend) }
  if ($IncludeReportSettingsWrite) { $AppRoleValues += @($manifest.optionalCapabilities.ReportSettingsWrite) }
}
$allowedRoles = @($manifest.profiles.Values | ForEach-Object { $_ }) +
  @($manifest.optionalCapabilities.Values | ForEach-Object { $_ })
foreach ($roleValue in $AppRoleValues) {
  if ($roleValue -match '(?i)(ReadWrite|AccessAsUser|(^|\.)(Write|Create|Delete|Manage)(\.|$))' -and
      $roleValue -ne 'ReportSettings.ReadWrite.All') {
    throw "Runtime permission '$roleValue' is write-capable or permission-managing and is not an approved assessment capability."
  }
  if ($roleValue -notin $allowedRoles) { throw "Role '$roleValue' is not in the reviewed assessment/capability manifest." }
  if ($roleValue -eq 'Mail.Send' -and -not $IncludeMailSend) { throw 'Mail.Send requires the separate IncludeMailSend capability.' }
  if ($roleValue -eq 'ReportSettings.ReadWrite.All' -and -not $IncludeReportSettingsWrite) { throw 'ReportSettings.ReadWrite.All requires the separate IncludeReportSettingsWrite capability.' }
}
if (@($AppRoleValues).Count -eq 0) { throw 'At least one reviewed application role must be selected.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Complete enumeration is required before any grant decision. Never send a token
# to a continuation outside this principal's Microsoft Graph collection.
function Get-MaesterGraphAssignmentList {
  param([string]$TenantId, [string]$PrincipalObjectId)

  $collectionUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/appRoleAssignments"
  $nextUri = "${collectionUri}?`$top=999"
  $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $assignments = [System.Collections.Generic.List[object]]::new()
  while ($nextUri) {
    $pageUri = $null
    if (-not [uri]::TryCreate($nextUri, [UriKind]::Absolute, [ref]$pageUri) -or
        $pageUri.Scheme -ne 'https' -or $pageUri.Host -ne 'graph.microsoft.com' -or
        $pageUri.Port -ne 443 -or $pageUri.UserInfo -or $pageUri.Fragment -or
        $pageUri.AbsolutePath -cne ([uri]$collectionUri).AbsolutePath) {
      throw 'Graph assignment continuation does not target the expected secure collection.'
    }
    if ($visited.Count -ge 100 -or -not $visited.Add($nextUri)) {
      throw 'Graph assignment pagination exceeded its limit or repeated a page.'
    }
    $page = Invoke-GraphRestRequest -Method GET -Uri $nextUri -TenantId $TenantId
    if ($null -eq $page -or -not $page.PSObject.Properties['value'] -or $null -eq $page.value) {
      throw 'Graph assignment response is missing its value collection.'
    }
    foreach ($assignment in @($page.value)) {
      $assignments.Add($assignment)
    }
    if ($page.PSObject.Properties['@odata.nextLink'] -and $null -ne $page.'@odata.nextLink' -and $page.'@odata.nextLink' -isnot [string]) {
      throw 'Graph collection continuation must be a string or null.'
    }
    $nextUri = if ($page.PSObject.Properties['@odata.nextLink']) { $page.'@odata.nextLink' } else { $null }
  }
  return $assignments.ToArray()
}

# Runtime applications are an explicit opt-in contract. The host must bind the
# expected app and federation to its own deployment endpoint before calling us.
function Get-MaesterFederatedCredentialInventory {
  param([string]$TenantId, [string]$ApplicationObjectId)
  $collectionUri = "https://graph.microsoft.com/v1.0/applications/$ApplicationObjectId/federatedIdentityCredentials"
  $nextUri = $collectionUri
  $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $trusts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $credentials = [Collections.Generic.List[object]]::new()
  while ($nextUri) {
    $pageUri = $null
    if (-not [uri]::TryCreate($nextUri, [UriKind]::Absolute, [ref]$pageUri) -or
        $pageUri.Scheme -cne 'https' -or $pageUri.Host -ine 'graph.microsoft.com' -or
        $pageUri.Port -ne 443 -or $pageUri.UserInfo -or $pageUri.Fragment -or
        $pageUri.AbsolutePath -cne ([uri]$collectionUri).AbsolutePath) {
      throw 'Federated credential continuation does not target the expected secure collection.'
    }
    if ($visited.Count -ge 100 -or -not $visited.Add($nextUri)) {
      throw 'Federated credential pagination exceeded its limit or repeated a page.'
    }
    $page = Invoke-GraphRestRequest -Method GET -Uri $nextUri -TenantId $TenantId
    if ($null -eq $page -or -not $page.PSObject.Properties['value'] -or $page.value -isnot [array]) {
      throw 'Federated credential response is missing its value array.'
    }
    foreach ($credential in $page.value) {
      foreach ($property in @('id', 'name', 'issuer', 'subject')) {
        if ($null -eq $credential -or -not $credential.PSObject.Properties[$property] -or
            $credential.$property -isnot [string] -or [string]::IsNullOrWhiteSpace($credential.$property)) {
          throw "Federated credential inventory contains a missing or malformed $property."
        }
      }
      if (-not $credential.PSObject.Properties['audiences'] -or $credential.audiences -isnot [array] -or
          $credential.audiences.Count -ne 1 -or
          @($credential.audiences | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count) {
        throw 'Federated credential inventory contains malformed audiences; exactly one non-empty audience is required.'
      }
      if (-not $ids.Add($credential.id)) { throw 'Federated credential inventory contains a duplicate credential ID.' }
      if (-not $names.Add($credential.name)) { throw 'Federated credential inventory contains a duplicate credential name.' }
      $trustKey = '{0}:{1}{2}:{3}' -f $credential.issuer.Length, $credential.issuer, $credential.subject.Length, $credential.subject
      if (-not $trusts.Add($trustKey)) { throw 'Federated credential inventory contains a duplicate issuer and subject trust.' }
      $credentials.Add([ordered]@{
        id = $credential.id; name = $credential.name; issuer = $credential.issuer
        subject = $credential.subject; audiences = @($credential.audiences | Sort-Object -CaseSensitive)
      })
    }
    if ($page.PSObject.Properties['@odata.nextLink'] -and $null -ne $page.'@odata.nextLink' -and $page.'@odata.nextLink' -isnot [string]) {
      throw 'Graph collection continuation must be a string or null.'
    }
    $nextUri = if ($page.PSObject.Properties['@odata.nextLink']) { $page.'@odata.nextLink' } else { $null }
  }
  return @($credentials.ToArray() | Sort-Object { $_.id })
}

function Get-MaesterExistingCredentialMetadata {
  param($Object, [string]$OwnerType)
  foreach ($type in @('keyCredentials', 'passwordCredentials')) {
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$type] -or $Object.$type -isnot [array]) {
      throw "Runtime $OwnerType response is missing its $type inventory."
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($credential in $Object.$type) {
      $keyId = [guid]::Empty
      if ($null -eq $credential -or -not $credential.PSObject.Properties['keyId'] -or
          $credential.keyId -isnot [string] -or
          -not [guid]::TryParse($credential.keyId, [ref]$keyId) -or $keyId -eq [guid]::Empty -or
          -not $ids.Add($keyId.ToString())) {
        throw "Runtime $OwnerType $type inventory contains a missing, invalid or duplicate keyId."
      }
      foreach ($dateName in @('startDateTime', 'endDateTime')) {
        $parsedDate = [DateTimeOffset]::MinValue
        if (-not $credential.PSObject.Properties[$dateName] -or
            ($credential.$dateName -isnot [string] -and $credential.$dateName -isnot [datetime] -and $credential.$dateName -isnot [DateTimeOffset]) -or
            -not [DateTimeOffset]::TryParse([string]$credential.$dateName, [ref]$parsedDate)) {
          throw "Runtime $OwnerType $type inventory contains a missing or invalid $dateName."
        }
      }
      # Deliberately exclude secretText, certificate material, hints and display names.
      [ordered]@{
        ownerType = $OwnerType; type = $type; keyId = $keyId.ToString()
        startDateTime = ([DateTimeOffset]::Parse([string]$credential.startDateTime)).ToUniversalTime().ToString('o')
        endDateTime = ([DateTimeOffset]::Parse([string]$credential.endDateTime)).ToUniversalTime().ToString('o')
      }
    }
  }
}

function Assert-MaesterGraphStringProperties {
  param($Object, [string[]]$Properties)
  foreach ($property in $Properties) {
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$property] -or
        $Object.$property -isnot [string] -or [string]::IsNullOrWhiteSpace($Object.$property)) {
      throw "Runtime identity response contains a missing or malformed $property."
    }
  }
}

$federationParameters = @('ExpectedApplicationId', 'ExpectedApplicationObjectId', 'ExpectedFederatedCredentialIssuer', 'ExpectedFederatedCredentialSubject')
if ($TargetType -ceq 'ManagedIdentity' -and @($federationParameters | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count) {
  throw 'Federated application parameters require explicit TargetType FederatedApplication.'
}
if ($TargetType -ceq 'FederatedApplication') {
  foreach ($name in @('TenantId', 'ExpectedApplicationId', 'ExpectedApplicationObjectId')) {
    $value = [guid]::Empty
    if (-not [guid]::TryParse([string](Get-Variable -Name $name -ValueOnly), [ref]$value) -or $value -eq [guid]::Empty) {
      throw "$name must be a non-empty GUID for a federated application target."
    }
    Set-Variable -Name $name -Value $value.ToString()
  }
  $issuerUri = $null
  if (-not [uri]::TryCreate($ExpectedFederatedCredentialIssuer, [UriKind]::Absolute, [ref]$issuerUri) -or
      $issuerUri.Scheme -cne 'https' -or $issuerUri.Port -ne 443 -or $issuerUri.UserInfo -or $issuerUri.Query -or $issuerUri.Fragment -or
      $ExpectedFederatedCredentialIssuer -cmatch '\s' -or
      [string]::IsNullOrWhiteSpace($ExpectedFederatedCredentialSubject) -or $ExpectedFederatedCredentialSubject -cmatch '[\x00-\x1f\x7f]') {
    throw 'A federated application target requires an exact HTTPS issuer and non-empty subject without control characters.'
  }
}

if ([string]::IsNullOrWhiteSpace($TenantId)) { throw 'TenantId must identify the selected deployment tenant.' }
$principalGuid = [guid]::Empty
if (-not [guid]::TryParse($PrincipalObjectId, [ref]$principalGuid) -or $principalGuid -eq [guid]::Empty) {
  throw 'PrincipalObjectId must be a non-empty GUID.'
}
$PrincipalObjectId = $principalGuid.ToString()

Import-Module (Join-Path $PSScriptRoot 'Maester-SetupHelpers.psm1')
# A caller can initialize a broader, explicitly selected setup union once. This
# standalone command also reuses only an already authorized matching session.
if (-not (Test-MaesterGraphSession -TenantId $TenantId)) {
  Assert-GraphAccess -TenantId $TenantId -Scopes (Get-MaesterSetupScopes)
}
Import-Module (Join-Path $PSScriptRoot 'Maester-ConsentPlan.psm1') -Force
$principalSelect = 'id,appId,servicePrincipalType'
if ($TargetType -ceq 'FederatedApplication') { $principalSelect += ',appOwnerOrganizationId,keyCredentials,passwordCredentials' }
$principal = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/${PrincipalObjectId}?`$select=$principalSelect" -TenantId $TenantId
Assert-MaesterGraphStringProperties -Object $principal -Properties @('id', 'appId', 'servicePrincipalType')
$targetProvenance = [ordered]@{ targetType = $TargetType; applicationId = $principal.appId }
if ($TargetType -ceq 'ManagedIdentity') {
  if ([string]$principal.id -ine $PrincipalObjectId -or [string]$principal.servicePrincipalType -cne 'ManagedIdentity') {
    throw 'Assessment application roles may only target the explicitly selected managed identity, never the setup client.'
  }
} else {
  Assert-MaesterGraphStringProperties -Object $principal -Properties @('appOwnerOrganizationId')
  $setupClientId = Get-MaesterGraphSetupClientId -TenantId $TenantId
  if ($ExpectedApplicationId -ieq $setupClientId) { throw 'The runtime application must never be the verified setup client.' }
  if ([string]$principal.id -ine $PrincipalObjectId -or [string]$principal.servicePrincipalType -cne 'Application' -or
      [string]$principal.appId -ine $ExpectedApplicationId -or [string]$principal.appOwnerOrganizationId -ine $TenantId) {
    throw 'The federated runtime service principal must match the explicit application and belong to the selected tenant.'
  }
  $application = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/${ExpectedApplicationObjectId}?`$select=id,appId,signInAudience,keyCredentials,passwordCredentials" -TenantId $TenantId
  Assert-MaesterGraphStringProperties -Object $application -Properties @('id', 'appId', 'signInAudience')
  if ([string]$application.id -ine $ExpectedApplicationObjectId -or [string]$application.appId -ine $ExpectedApplicationId -or
      [string]$application.signInAudience -cne 'AzureADMyOrg') {
    throw 'The federated runtime application must match the explicit object/client IDs and be single-tenant.'
  }
  $existingCredentials = @(
    Get-MaesterExistingCredentialMetadata -Object $application -OwnerType 'application'
    Get-MaesterExistingCredentialMetadata -Object $principal -OwnerType 'servicePrincipal'
  ) | Sort-Object { $_.ownerType }, { $_.type }, { $_.keyId }
  $federatedCredentials = @(Get-MaesterFederatedCredentialInventory -TenantId $TenantId -ApplicationObjectId $ExpectedApplicationObjectId)
  $matchingCredentials = @($federatedCredentials | Where-Object {
    $_.issuer -ceq $ExpectedFederatedCredentialIssuer -and $_.subject -ceq $ExpectedFederatedCredentialSubject -and
    $_.audiences.Count -eq 1 -and $_.audiences[0] -ceq 'api://AzureADTokenExchange'
  })
  if ($matchingCredentials.Count -ne 1) {
    throw 'Exactly one federated credential must match the expected issuer, subject and single token-exchange audience.'
  }
  $targetProvenance = [ordered]@{
    targetType = $TargetType; applicationId = $ExpectedApplicationId; applicationObjectId = $ExpectedApplicationObjectId
    appOwnerOrganizationId = $TenantId; signInAudience = 'AzureADMyOrg'
    selectedFederatedCredentialId = $matchingCredentials[0].id
    expectedIssuer = $ExpectedFederatedCredentialIssuer; expectedSubject = $ExpectedFederatedCredentialSubject
    audience = 'api://AzureADTokenExchange'
    preservedFederatedCredentials = @($federatedCredentials)
    existingApplicationCredentials = @($existingCredentials)
    existingTrustNotice = 'All existing federated trusts and application/service-principal credentials are preserved and can exercise the new application grants. Approval applies to this whole runtime identity, not only the selected pipeline trust. Credential metadata is displayed; secret and certificate material is excluded.'
  }
}

$graphServicePrincipal = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'" -TenantId $TenantId
if (@($graphServicePrincipal.value).Count -ne 1 -or
    ($graphServicePrincipal.PSObject.Properties['@odata.nextLink'] -and $graphServicePrincipal.'@odata.nextLink')) {
  throw 'Exactly one Microsoft Graph service principal must be returned in the selected tenant.'
}

$resourceServicePrincipal = $graphServicePrincipal.value[0]
if ($resourceServicePrincipal.appId -ne '00000003-0000-0000-c000-000000000000') {
  throw 'The returned service principal is not Microsoft Graph.'
}
$appRoles = @($resourceServicePrincipal.appRoles | Where-Object { $_.value -and $_.isEnabled -and $_.allowedMemberTypes -contains 'Application' })
$existingAssignmentList = @(Get-MaesterGraphAssignmentList -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId)

# Validate the complete requested role set before making the first assignment.
$requestedRoles = @(
  foreach ($appRoleValue in @($AppRoleValues | Select-Object -Unique)) {
    $match = @($appRoles | Where-Object { $_.value -eq $appRoleValue })
    if ($match.Count -ne 1) {
      throw "Exactly one enabled application role '$appRoleValue' must exist on Microsoft Graph."
    }
    if (-not $manifest.applicationRoles.ContainsKey($appRoleValue) -or
        [string]$match[0].id -ine [string]$manifest.applicationRoles[$appRoleValue].applicationRoleId) {
      throw "Application role '$appRoleValue' does not match the reviewed manifest identifier."
    }
    $match[0]
  }
)
$missingRoles = @($requestedRoles | Where-Object {
  $roleId = $_.id
  -not @($existingAssignmentList | Where-Object {
    $_.principalId -eq $PrincipalObjectId -and $_.resourceId -eq $resourceServicePrincipal.id -and $_.appRoleId -eq $roleId
  }).Count
})
# A narrower desired profile does not revoke previously granted capabilities.
# Show their effective permission surface, including optional writes, during review.
$existingGraphRoles = @(
  foreach ($assignment in $existingAssignmentList) {
    if ($assignment.principalId -ne $PrincipalObjectId -or $assignment.resourceId -ne $resourceServicePrincipal.id) { continue }
    $existingRole = @($resourceServicePrincipal.appRoles | Where-Object { $_.id -eq $assignment.appRoleId })
    $roleName = if ($existingRole.Count -eq 1) { [string]$existingRole[0].value } else { 'unresolved-role' }
    "$($resourceServicePrincipal.id)/$($assignment.appRoleId)/$roleName"
  }
) | Sort-Object -Unique
$existingOptionalCapabilities = @(
  foreach ($name in @('Mail.Send', 'ReportSettings.ReadWrite.All', 'Sites.Read.All')) {
    $roleId = $manifest.applicationRoles[$name].applicationRoleId
    if (@($existingAssignmentList | Where-Object {
      $_.principalId -eq $PrincipalObjectId -and $_.resourceId -eq $resourceServicePrincipal.id -and $_.appRoleId -eq $roleId
    }).Count) { $name }
  }
)
$effectiveRoles = @($AppRoleValues) + @($existingOptionalCapabilities)
$consequences = [ordered]@{}
foreach ($supplement in @($manifest.reviewedSupplements)) {
  if ($supplement.role -in $effectiveRoles -and $supplement.ContainsKey('consequence')) {
    $consequences[$supplement.role] = $supplement.consequence
  }
}
if ('Mail.Send' -in $effectiveRoles) { $consequences['Mail.Send'] = $manifest.capabilityConsequences.MailSend }
if ('ReportSettings.ReadWrite.All' -in $effectiveRoles) { $consequences['ReportSettings.ReadWrite.All'] = $manifest.capabilityConsequences.ReportSettingsWrite }
$plan = New-MaesterConsentPlan -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId `
  -Capability 'GraphApplicationRoles' -ManifestVersion $manifest.manifestVersion `
  -ManifestSha256 (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() `
  -Desired @($requestedRoles | ForEach-Object { "$($resourceServicePrincipal.id)/$($_.id)/$($_.value)" }) `
  -Missing @($missingRoles | ForEach-Object { "$($resourceServicePrincipal.id)/$($_.id)/$($_.value)" }) `
  -Details @{ targetProvenance = $targetProvenance; maesterVersion = $manifest.maesterVersion; profile = $PermissionProfile; includeMailSend = $IncludeMailSend; includeReportSettingsWrite = $IncludeReportSettingsWrite; consequences = $consequences; preservedExistingGraphRoles = @($existingGraphRoles); preservedExistingOptionalCapabilities = @($existingOptionalCapabilities); existingAccessNotice = 'Existing grants are preserved. A disabled desired capability does not revoke existing access; existing report-setting write authority can still permit tenant privacy changes during assessment. Existing Mail.Send authority alone does not configure or trigger report delivery.' }
if (-not $Apply) { return $plan }
Assert-MaesterConsentPlanApproval -Plan $plan -ApprovedPlanHash $ApprovedPlanHash

if ($null -ne $OwnershipSession) {
  Import-Module (Join-Path $PSScriptRoot 'Maester-OwnershipJournal.psm1') -ErrorAction Stop
  $journal = Get-MaesterOwnershipJournal -Session $OwnershipSession
  if ($journal.binding.tenantId -ine $TenantId -or
      ($journal.binding.Contains('runtimePrincipalId') -and $journal.binding.runtimePrincipalId -ine $PrincipalObjectId)) {
    throw 'The ownership journal does not match this Graph grant target.'
  }
  if (@($journal.records | Where-Object { $_.state -in @('pending', 'deleting', 'conflict') }).Count) {
    throw 'The ownership journal contains unresolved operations. Resolve them before granting more access.'
  }
}
$createdAssignment = $false
foreach ($role in $requestedRoles) {
  $alreadyAssigned = @($existingAssignmentList | Where-Object {
    $_.principalId -eq $PrincipalObjectId -and $_.resourceId -eq $resourceServicePrincipal.id -and $_.appRoleId -eq $role.id
  })
  if ($alreadyAssigned.Count -gt 0) {
    Write-Host "App role '$($role.value)' already assigned."
    continue
  }

  $body = @{
    principalId = $PrincipalObjectId
    resourceId  = $resourceServicePrincipal.id
    appRoleId   = $role.id
  } | ConvertTo-Json

  $ownershipOperation = $null
  if ($null -ne $OwnershipSession) {
    $expected = @{ principalId = $PrincipalObjectId.ToLowerInvariant(); resourceId = ([string]$resourceServicePrincipal.id).ToLowerInvariant(); appRoleId = ([string]$role.id).ToLowerInvariant() }
    $ownershipOperation = Start-MaesterOwnedOperation -Session $OwnershipSession -Key "graph-role:$($expected.principalId):$($expected.resourceId):$($expected.appRoleId)" `
      -Kind GraphAppRoleAssignment -Ownership Created -PlanHash $plan.planHash -Expected $expected
  }
  $response = Invoke-GraphRestRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/appRoleAssignments" -Body $body -ContentType 'application/json' -TenantId $TenantId
  if ($null -ne $OwnershipSession) {
    # A missing/malformed response remains pending; never discover an ID by name
    # or automatically repeat the POST after an uncertain outcome.
    $hasId = $null -ne $response -and $(if ($response -is [System.Collections.IDictionary]) { $response.Contains('id') } else { $null -ne $response.PSObject.Properties['id'] })
    if (-not $hasId -or [string]::IsNullOrWhiteSpace([string]$response.id)) {
      throw 'Graph grant returned no exact assignment ID. Ownership remains pending; stop and review the uncertain write.'
    }
    $null = Complete-MaesterOwnedOperation -Session $OwnershipSession -OperationId $ownershipOperation.operationId -ExactIds @{ assignmentId = [string]$response.id }
    foreach ($field in @('principalId', 'resourceId', 'appRoleId')) {
      $hasField = if ($response -is [System.Collections.IDictionary]) { $response.Contains($field) } else { $null -ne $response.PSObject.Properties[$field] }
      if (-not $hasField -or [string]$response.$field -ine $expected[$field]) {
        $null = Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $ownershipOperation.operationId -State conflict
        throw 'Graph grant response identity differs from the approved tuple. The exact returned ID is retained as a conflict; no later grants were attempted.'
      }
    }
  }
  $createdAssignment = $true
}

# Read back exact principal/resource/role tuples before reporting completion.
# A short, read-only retry permits normal directory propagation after creation.
if ($createdAssignment) {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $observedAssignments = @(Get-MaesterGraphAssignmentList -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId)
    $missingRoles = @($requestedRoles | Where-Object {
      $roleId = $_.id
      -not @($observedAssignments | Where-Object {
        $_.principalId -eq $PrincipalObjectId -and $_.resourceId -eq $resourceServicePrincipal.id -and $_.appRoleId -eq $roleId
      }).Count
    })
    if ($missingRoles.Count -eq 0) { break }
    if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
  }
  if ($missingRoles.Count -gt 0) {
    throw "Graph assignments could not be verified for: $($missingRoles.value -join ', '). Rerun after directory propagation; existing grants will be preserved."
  }
}

Write-Host 'Graph app role assignment completed and verified.'
return $plan
