#Requires -Version 7.6
# Setup-only helpers. Never copied into the federated assessment runtime.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PlainTextToken {
  param(
    [Parameter(Mandatory = $true)]
    $TokenValue
  )

  if ($TokenValue -is [string]) {
    return $TokenValue
  }

  if ($TokenValue -is [System.Security.SecureString]) {
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TokenValue)
    try {
      return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
      [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
  }

  return [string]$TokenValue
}

function Get-AzureDevOpsAccessToken {
  param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId
  )

  $cliToken = Get-AzCliAccessToken -Resource '499b84ac-1321-427f-aa17-267ca6975798' -TenantId $TenantId
  if (-not [string]::IsNullOrWhiteSpace($cliToken)) {
    return $cliToken.Trim()
  }

  try {
    $tokenParams = @{ ResourceUrl = '499b84ac-1321-427f-aa17-267ca6975798' }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
      $tokenParams['TenantId'] = $TenantId
    }
    $tokenResponse = Get-AzAccessToken @tokenParams
    $azToken = ConvertTo-PlainTextToken -TokenValue $tokenResponse.Token
    if (-not [string]::IsNullOrWhiteSpace($azToken)) {
      return $azToken.Trim()
    }
  }
  catch {
    Write-Verbose "Azure PowerShell Azure DevOps token acquisition failed: $($_.Exception.Message)"
  }

  throw 'Could not acquire an Azure DevOps token. Ensure the selected Azure CLI or Azure PowerShell account is authenticated for the target tenant.'
}

function Invoke-AdoRestMethod {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
    [string]$Method,

    [Parameter(Mandatory = $true)]
    [string]$Uri,

    [Parameter(Mandatory = $false)]
    [string]$Payload,

    [Parameter(Mandatory = $false)]
    [string]$TenantId
  )

  $token = Get-AzureDevOpsAccessToken -TenantId $TenantId
  $invokeParams = @{
    Method  = $Method
    Uri     = $Uri
    Headers = @{ Authorization = "Bearer $token" }
  }
  if ($PSBoundParameters.ContainsKey('Payload') -and $null -ne $Payload) {
    $invokeParams['Body'] = $Payload
    $invokeParams['ContentType'] = 'application/json'
  }

  $responseStatus = 0
  $responseHeaders = $null
  $response = Invoke-RestMethod @invokeParams -SkipHttpErrorCheck -StatusCodeVariable responseStatus -ResponseHeadersVariable responseHeaders
  $content = if ($null -eq $response) {
    ''
  }
  elseif ($response -is [string]) {
    $response
  }
  else {
    $response | ConvertTo-Json -Depth 50
  }

  return [pscustomobject]@{
    StatusCode = [int]$responseStatus
    Content    = $content
    ContinuationToken = $(if ($responseHeaders) { $responseHeaders['x-ms-continuationtoken'] } else { $null })
  }
}


function Get-MaesterAdoProperty {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return ,$Object[$Name] } }
  elseif ($Object.PSObject.Properties[$Name]) { return ,$Object.$Name }
  return $Default
}
function Assert-MaesterAdoGuid {
  param([string]$Value, [string]$Name)
  $guid = [guid]::Empty
  if (-not [guid]::TryParse($Value, [ref]$guid) -or $guid -eq [guid]::Empty) { throw "$Name must be a non-empty GUID." }
}
function Invoke-MaesterAdoRequest {
  param([string]$Uri, [string]$TenantId, [string]$Method = 'GET', $Body)
  $parameters = @{ Method = $Method; Uri = $Uri; TenantId = $TenantId }
  if ($null -ne $Body) { $parameters.Payload = $Body | ConvertTo-Json -Depth 40 -Compress }
  $response = Invoke-AdoRestMethod @parameters
  if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300 -or [string]::IsNullOrWhiteSpace($response.Content)) {
    throw "Azure DevOps $Method failed or returned no inventory: $Uri (HTTP $($response.StatusCode))."
  }
  if ((Get-MaesterAdoProperty $response 'ContinuationToken')) { throw 'Azure DevOps inventory is incomplete; continuation must be resolved before planning.' }
  return ($response.Content | ConvertFrom-Json)
}
function Get-MaesterAdoCollection {
  param([string]$Uri, [string]$TenantId, [switch]$Graph)
  $response = if ($Graph) { Invoke-GraphRestRequest -Method GET -Uri $Uri } else { Invoke-MaesterAdoRequest -Uri $Uri -TenantId $TenantId }
  if ($null -eq $response -or -not $response.PSObject.Properties['value'] -or $response.value -isnot [array]) { throw "Incomplete identity inventory: $Uri" }
  foreach ($name in @('@odata.nextLink', 'nextLink', 'continuationToken')) {
    if (Get-MaesterAdoProperty $response $name) { throw "Paginated identity inventory must be completed before planning: $Uri" }
  }
  return @($response.value)
}
function Get-MaesterAdoCredentialMetadata {
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

function Get-MaesterAdoBootstrapSnapshot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName, [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$Organization, [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$RepositoryName, [Parameter(Mandatory)][string]$ServiceConnectionName,
    [string]$ExpectedServiceConnectionId, [string]$ExpectedApplicationId,
    [string]$ExpectedApplicationObjectId, [string]$ExpectedPrincipalObjectId,
    [string]$SubscriptionName, [string[]]$SetupScopes = @('Application.Read.All','AppRoleAssignment.ReadWrite.All','Directory.Read.All','Application.ReadWrite.All'), [bool]$CreateRepositoryIfMissing = $true
  )
  Assert-MaesterAdoGuid $TenantId TenantId; Assert-MaesterAdoGuid $SubscriptionId SubscriptionId
  foreach ($name in @('ExpectedServiceConnectionId','ExpectedApplicationId','ExpectedApplicationObjectId','ExpectedPrincipalObjectId')) {
    $value = Get-Variable -Name $name -ValueOnly
    if ($value) { Assert-MaesterAdoGuid $value $name }
  }
  if ($Organization -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { throw 'Use an exact Azure DevOps organization name.' }
  foreach ($value in @($Project, $RepositoryName, $ServiceConnectionName, $ResourceGroupName, $EnvironmentName)) {
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\r\n]') { throw 'Explicit single-line bootstrap target names are required.' }
  }
  # Resolve the organization independently of endpoint-provided trust strings.
  # ConnectionData.instanceId is the authoritative host instance identifier.
  $connectionData = Invoke-MaesterAdoRequest -Uri "https://dev.azure.com/$Organization/_apis/connectionData?api-version=7.1-preview.1" -TenantId $TenantId
  Assert-MaesterAdoGuid ([string](Get-MaesterAdoProperty $connectionData 'instanceId' '')) OrganizationId
  $organizationId = ([guid]$connectionData.instanceId).ToString()
  $projectEncoded = [uri]::EscapeDataString($Project)
  $root = "https://dev.azure.com/$Organization/$projectEncoded/_apis"
  $projectInfo = Invoke-MaesterAdoRequest -Uri "https://dev.azure.com/$Organization/_apis/projects/${projectEncoded}?api-version=7.1" -TenantId $TenantId
  Assert-MaesterAdoGuid ([string]$projectInfo.id) ProjectId
  if ($projectInfo.name -cne $Project -or $projectInfo.state -ine 'wellFormed') { throw 'The exact Azure DevOps project must exist and be well formed.' }
  $repositories = @(Get-MaesterAdoCollection -Uri "$root/git/repositories?api-version=7.1" -TenantId $TenantId | Where-Object { $_.name -ceq $RepositoryName })
  $connections = @(Get-MaesterAdoCollection -Uri "$root/serviceendpoint/endpoints?endpointNames=$([uri]::EscapeDataString($ServiceConnectionName))&api-version=7.1" -TenantId $TenantId)
  if ($repositories.Count -gt 1 -or $connections.Count -gt 1) { throw 'Repository or service connection inventory is ambiguous.' }
  $repository = if ($repositories.Count) { $repositories[0] } else { $null }
  $endpoint = if ($connections.Count) { $connections[0] } else { $null }
  if ($repository) {
    Assert-MaesterAdoGuid ([string]$repository.id) RepositoryId
    if ($repository.project.id -ine $projectInfo.id) { throw 'Repository does not belong to the selected project.' }
    $cloneUri = $null
    if (-not [uri]::TryCreate([string]$repository.remoteUrl, [UriKind]::Absolute, [ref]$cloneUri) -or
        $cloneUri.Scheme -cne 'https' -or $cloneUri.Host -cne 'dev.azure.com' -or $cloneUri.Port -ne 443 -or
        $cloneUri.UserInfo -or $cloneUri.Query -or $cloneUri.Fragment) { throw 'Repository clone URL is not the selected official Azure DevOps destination.' }
    $segments = @($cloneUri.AbsolutePath.Trim('/').Split('/') | ForEach-Object { [uri]::UnescapeDataString($_) })
    if ($segments.Count -ne 4 -or $segments[0] -cne $Organization -or $segments[1] -notin @($Project, [string]$projectInfo.id) -or
        $segments[2] -cne '_git' -or $segments[3] -notin @($RepositoryName, [string]$repository.id)) { throw 'Repository clone URL differs from the selected organization, project or repository.' }

  }
  if ($ExpectedServiceConnectionId -and (-not $endpoint -or $endpoint.id -ine $ExpectedServiceConnectionId)) { throw 'The selected service connection differs from the recorded exact endpoint.' }
  $clientId = ''
  if ($endpoint) {
    Assert-MaesterAdoGuid ([string]$endpoint.id) ServiceConnectionId
    if ($endpoint.name -cne $ServiceConnectionName -or $endpoint.type -ine 'azurerm' -or
        $endpoint.authorization.scheme -cne 'WorkloadIdentityFederation' -or
        $endpoint.authorization.parameters.tenantid -ine $TenantId -or $endpoint.data.subscriptionId -ine $SubscriptionId -or
        $endpoint.url -cne 'https://management.azure.com/') { throw 'Service connection type, scheme, tenant or subscription differs from the selected target.' }
    if ((Get-MaesterAdoProperty $endpoint 'isShared') -isnot [bool] -or $endpoint.isShared -ne $false) { throw 'The runtime service connection must be explicitly nonshared.' }
    $refs = @($endpoint.serviceEndpointProjectReferences)
    if ($refs.Count -ne 1 -or $refs[0].projectReference.id -ine $projectInfo.id) { throw 'The runtime service connection must belong only to the selected project.' }
    $clientId = [string](Get-MaesterAdoProperty $endpoint.authorization.parameters 'serviceprincipalid' '')
    if ($clientId) { Assert-MaesterAdoGuid $clientId RuntimeApplicationId }
  }
  if ($ExpectedApplicationId -and $clientId -and $clientId -ine $ExpectedApplicationId) { throw 'The service connection references a different runtime application.' }
  $displayName = "sc-app-maester-$($EnvironmentName.ToLowerInvariant())"
  $appFilter = if ($clientId) { "appId eq '$clientId'" } elseif ($ExpectedApplicationId) { "appId eq '$ExpectedApplicationId'" } else { "displayName eq '$($displayName.Replace("'", "''"))'" }
  $apps = @(Get-MaesterAdoCollection -Graph -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$([uri]::EscapeDataString($appFilter))&`$select=id,appId,displayName,signInAudience,passwordCredentials,keyCredentials,identifierUris,groupMembershipClaims,web")
  if ($apps.Count -gt 1) { throw 'Runtime application inventory is ambiguous.' }
  $app = if ($apps.Count) { $apps[0] } else { $null }
  if (($clientId -or $ExpectedApplicationId -or $ExpectedApplicationObjectId) -and -not $app) { throw 'The recorded runtime application is missing; never replace it by display name.' }
  if ($app) {
    Assert-MaesterAdoGuid ([string]$app.id) ApplicationObjectId; Assert-MaesterAdoGuid ([string]$app.appId) ApplicationId
    if ($app.appId -ieq (Get-MaesterGraphSetupClientId -TenantId $TenantId)) { throw 'The runtime application must be separate from the authenticated setup client.' }
    if ($app.signInAudience -cne 'AzureADMyOrg' -or
        ($clientId -and $app.appId -ine $clientId) -or
        ($ExpectedApplicationId -and $app.appId -ine $ExpectedApplicationId) -or
        ($ExpectedApplicationObjectId -and $app.id -ine $ExpectedApplicationObjectId)) { throw 'Runtime application is not the exact selected single-tenant application.' }
  }
  $principals = @(if ($app) { Get-MaesterAdoCollection -Graph -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id,appId,displayName,servicePrincipalType,appOwnerOrganizationId,passwordCredentials,keyCredentials" })
  if ($principals.Count -gt 1) { throw 'Runtime service principal inventory is ambiguous.' }
  $principal = if ($principals.Count) { $principals[0] } else { $null }
  if ($ExpectedPrincipalObjectId -and (-not $principal -or $principal.id -ine $ExpectedPrincipalObjectId)) { throw 'Runtime principal differs from the recorded exact identity.' }
  if ($principal) {
    Assert-MaesterAdoGuid ([string]$principal.id) PrincipalObjectId
    if ($principal.appId -ine $app.appId -or $principal.appOwnerOrganizationId -ine $TenantId -or $principal.servicePrincipalType -cne 'Application') { throw 'Runtime principal must be the tenant-owned Application service principal.' }
  }
  $credentialMetadata = @(
    if ($app) { Get-MaesterAdoCredentialMetadata -Object $app -OwnerType application }
    if ($principal) { Get-MaesterAdoCredentialMetadata -Object $principal -OwnerType servicePrincipal }
  )
  $existingAppRoles = @(); $existingDirectoryRoles = @()
  if ($principal) {
    $existingAppRoles = @(Get-MaesterAdoCollection -Graph -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignments?`$top=999")
    foreach ($assignment in $existingAppRoles) {
      if ($assignment.principalId -ine $principal.id -or -not $assignment.id -or -not $assignment.resourceId -or -not $assignment.appRoleId) { throw 'Incomplete or unexpected existing application role assignment.' }
      $resource = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($assignment.resourceId)?`$select=id,appId,displayName,appRoles"
      if ($resource.id -ine $assignment.resourceId) { throw 'Existing application role resource could not be verified.' }
      $roles = @($resource.appRoles | Where-Object { $_.id -ieq $assignment.appRoleId })
      if ($roles.Count -ne 1) { throw 'Existing application role cannot be resolved for bootstrap review.' }
      $assignment | Add-Member -NotePropertyName resolvedPermission -NotePropertyValue ([ordered]@{ resource = $resource.displayName; resourceAppId = $resource.appId; role = $roles[0].value }) -Force
    }
    $existingDirectoryRoles = @(Get-MaesterAdoCollection -Graph -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($principal.id)'&`$expand=roleDefinition")
    foreach ($role in $existingDirectoryRoles) {
      if ($role.principalId -ine $principal.id -or -not $role.id -or -not $role.roleDefinitionId -or -not $role.directoryScopeId -or -not $role.roleDefinition.displayName) { throw 'Incomplete directory-role inventory for bootstrap review.' }
    }
  }
  $federations = @(if ($app) { Get-MaesterAdoCollection -Graph -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)/federatedIdentityCredentials?`$select=id,name,issuer,subject,audiences" })
  $issuer = if ($endpoint) { [string](Get-MaesterAdoProperty $endpoint.authorization.parameters 'workloadIdentityFederationIssuer' '') } else { '' }
  $subject = if ($endpoint) { [string](Get-MaesterAdoProperty $endpoint.authorization.parameters 'workloadIdentityFederationSubject' '') } else { '' }
  if ($endpoint -and ([string]::IsNullOrWhiteSpace($issuer) -or [string]::IsNullOrWhiteSpace($subject))) { throw 'The selected endpoint did not return a complete federation issuer and subject.' }
  if ($endpoint) {
    $issuerUri = $null
    if (-not [uri]::TryCreate($issuer, [UriKind]::Absolute, [ref]$issuerUri) -or $issuerUri.Scheme -cne 'https' -or
        $issuerUri.Port -ne 443 -or $issuerUri.UserInfo -or $issuerUri.Query -or $issuerUri.Fragment -or
        $issuerUri.Host -notin @('vstoken.dev.azure.com', 'login.microsoftonline.com')) { throw 'Unrecognized Azure DevOps workload federation issuer.' }
    if ($issuerUri.Host -ceq 'vstoken.dev.azure.com') {
      if ($issuer -cne "https://vstoken.dev.azure.com/$organizationId" -or $subject -cne "sc://$Organization/$Project/$ServiceConnectionName") {
        throw 'Legacy federation does not bind the selected organization, project and service connection.'
      }
    } else {
      # Microsoft Entra owns the opaque prefix. Bind its stable ADO suffix to the
      # independently read organization and exact endpoint; never synthesize it.
      $suffix = "/sc/$organizationId/$(([guid]$endpoint.id).ToString())"
      if ($issuer -cne "https://login.microsoftonline.com/$(([guid]$TenantId).ToString())/v2.0" -or
          $subject -match '[\s\x00-\x1f\x7f]' -or -not $subject.EndsWith($suffix, [StringComparison]::Ordinal) -or
          $subject.Length -le $suffix.Length) {
        throw 'Microsoft Entra federation does not bind the selected tenant, organization and exact service connection.'
      }
    }
  }
  $safeFederations = @(); $federationIds = @{}; $federationNames = @{}; $federationTrusts = @{}
  foreach ($f in $federations) {
    foreach ($property in @('id','name','issuer','subject')) {
      if ((Get-MaesterAdoProperty $f $property) -isnot [string] -or [string]::IsNullOrWhiteSpace($f.$property)) { throw 'Malformed existing federation inventory.' }
    }
    if ($f.audiences -isnot [array] -or $f.audiences.Count -ne 1 -or $f.audiences[0] -isnot [string] -or [string]::IsNullOrWhiteSpace($f.audiences[0])) { throw 'Malformed existing federation audience inventory.' }
    $trust = $f.issuer + [char]0 + $f.subject
    if ($federationIds.ContainsKey($f.id) -or $federationNames.ContainsKey($f.name) -or $federationTrusts.ContainsKey($trust)) { throw 'Ambiguous duplicate existing federation inventory.' }
    $federationIds[$f.id] = $true; $federationNames[$f.name] = $true; $federationTrusts[$trust] = $true
    $safeFederations += [pscustomobject][ordered]@{ id = $f.id; name = $f.name; issuer = $f.issuer; subject = $f.subject; audiences = @($f.audiences) }
  }
  $federations = @($safeFederations | Sort-Object id)
  $matching = @($federations | Where-Object { $_.issuer -ceq $issuer -and $_.subject -ceq $subject })
  if ($matching.Count -gt 1 -or ($matching.Count -eq 1 -and (@($matching[0].audiences).Count -ne 1 -or $matching[0].audiences[0] -cne 'api://AzureADTokenExchange'))) { throw 'Federated trust is ambiguous or has an unexpected audience.' }
  # Only nonsecret identity/binding fields may enter a displayed approval plan.
  $safeProject = [pscustomobject][ordered]@{ id = $projectInfo.id; name = $projectInfo.name; state = $projectInfo.state }
  $safeRepository = if ($repository) { [pscustomobject][ordered]@{ id = $repository.id; name = $repository.name; project = $safeProject; remoteUrl = $repository.remoteUrl; defaultBranch = (Get-MaesterAdoProperty $repository 'defaultBranch' '') } } else { $null }
  $safeApplication = if ($app) { [pscustomobject][ordered]@{ id = $app.id; appId = $app.appId; displayName = $app.displayName; signInAudience = $app.signInAudience; configuration = Get-MaesterApplicationCreationBaseline $app } } else { $null }
  $safePrincipal = if ($principal) { [pscustomobject][ordered]@{ id = $principal.id; appId = $principal.appId; displayName = $principal.displayName; servicePrincipalType = $principal.servicePrincipalType; appOwnerOrganizationId = $principal.appOwnerOrganizationId } } else { $null }
  $safeEndpoint = if ($endpoint) {
    $data = [ordered]@{}
    foreach ($field in @('subscriptionId','subscriptionName','environment','scopeLevel','creationMode','isDraft')) {
      if ($endpoint.data.PSObject.Properties[$field]) { $data[$field] = $endpoint.data.$field }
    }
    [pscustomobject][ordered]@{
      id = $endpoint.id; name = $endpoint.name; type = $endpoint.type; url = $endpoint.url
      isReady = $endpoint.isReady; isShared = $endpoint.isShared; data = [pscustomobject]$data
      authorization = [pscustomobject][ordered]@{ scheme = $endpoint.authorization.scheme; parameters = [pscustomobject][ordered]@{
        tenantid = $TenantId; serviceprincipalid = $clientId; scope = [string](Get-MaesterAdoProperty $endpoint.authorization.parameters 'scope' '')
        workloadIdentityFederationIssuer = $issuer; workloadIdentityFederationSubject = $subject
      } }
      serviceEndpointProjectReferences = @([pscustomobject]@{ name = $ServiceConnectionName; projectReference = [pscustomobject]@{ id = $projectInfo.id; name = $projectInfo.name } })
    }
  } else { $null }
  [pscustomobject][ordered]@{ organization = [pscustomobject][ordered]@{ id = $organizationId; name = $Organization }; project = $safeProject; repository = $safeRepository; endpoint = $safeEndpoint; application = $safeApplication; principal = $safePrincipal
    credentialMetadata = @($credentialMetadata | Sort-Object ownerType,type,keyId)
    existingAppRoles = @($existingAppRoles | ForEach-Object { [ordered]@{ id = $_.id; principalId = $_.principalId; resourceId = $_.resourceId; appRoleId = $_.appRoleId; resolvedPermission = $_.resolvedPermission } } | Sort-Object { $_.id })
    existingDirectoryRoles = @($existingDirectoryRoles | ForEach-Object { [ordered]@{ id = $_.id; principalId = $_.principalId; roleDefinitionId = $_.roleDefinitionId; directoryScopeId = $_.directoryScopeId; roleName = $_.roleDefinition.displayName } } | Sort-Object { $_.id })
    inventoryLimits = @('Inherited/group-based directory access, Azure RBAC outside the selected deployment scope and workload-specific Exchange/Teams RBAC are not fully enumerated here. New federation can exercise every existing permission of this application, including those outside the inventoried Graph roles. All existing passwords, keys and federations retain access.')
    federations = $federations; matchingFederation = $matching; issuer = $issuer; subject = $subject; root = $root
    scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"; displayName = $displayName
  }
}
function Get-MaesterAdoBootstrapPlan {
  param([Parameter(Mandatory)][hashtable]$Parameters)
  $s = Get-MaesterAdoBootstrapSnapshot @Parameters
  $operator = Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
  if ($operator.userPrincipalName -ine $env:MAESTER_SETUP_ACCOUNT) { throw 'Bootstrap requires the explicitly selected setup account.' }
  $ops = [Collections.Generic.List[object]]::new()
  if (-not $s.repository) {
    if (-not $Parameters.CreateRepositoryIfMissing) { throw 'The selected repository is missing and repository creation is disabled.' }
    $ops.Add(@{ method = 'POST'; uri = "$($s.root)/git/repositories?api-version=7.1"; body = @{ name = $Parameters.RepositoryName; project = @{ id = $s.project.id } }; kind = 'Repository' })
  }
  if (-not $s.endpoint) {
    $body = @{ name = $Parameters.ServiceConnectionName; type = 'AzureRM'; url = 'https://management.azure.com/'; isShared = $false; isReady = $true
      data = @{ subscriptionId = $Parameters.SubscriptionId; subscriptionName = $Parameters.SubscriptionName; environment = 'AzureCloud'; scopeLevel = 'Subscription'; creationMode = 'Manual'; isDraft = $true }
      authorization = @{ scheme = 'WorkloadIdentityFederation'; parameters = @{ tenantid = $Parameters.TenantId; scope = $s.scope } }
      serviceEndpointProjectReferences = @(@{ name = $Parameters.ServiceConnectionName; projectReference = @{ id = $s.project.id; name = $s.project.name } }) }
    $ops.Add(@{ method = 'POST'; uri = "$($s.root)/serviceendpoint/endpoints?api-version=7.1"; body = $body; kind = 'Endpoint' })
  }
  if (-not $s.application) {
    $ops.Add(@{ method = 'POST'; uri = 'https://graph.microsoft.com/v1.0/applications'; body = @{ displayName = $s.displayName; signInAudience = 'AzureADMyOrg'; identifierUris = @(); groupMembershipClaims = $null; web = @{ redirectUris = @(); implicitGrantSettings = @{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false } } }; kind = 'Application' })
  } elseif (-not $s.principal) {
    $ops.Add(@{ method = 'POST'; uri = 'https://graph.microsoft.com/v1.0/servicePrincipals'; body = @{ appId = $s.application.appId }; kind = 'Principal' })
  }
  # Trust is planned only after endpoint, app and principal IDs exist. Newly
  # created identifiers never authorize an unreviewed federation or rebind.
  if ($s.endpoint -and $s.application -and $s.principal) {
    if ($s.matchingFederation.Count -eq 0) {
      $name = "ado-$($Parameters.EnvironmentName.ToLowerInvariant())"
      if (@($s.federations | Where-Object name -eq $name).Count) { throw 'The planned federation name already identifies another trust.' }
      $ops.Add(@{ method = 'POST'; uri = "https://graph.microsoft.com/v1.0/applications/$($s.application.id)/federatedIdentityCredentials"; body = @{ name = $name; issuer = $s.issuer; subject = $s.subject; audiences = @('api://AzureADTokenExchange') }; kind = 'Federation' })
    }
    $ep = $s.endpoint
    $needsBinding = ([string](Get-MaesterAdoProperty $ep.authorization.parameters 'serviceprincipalid' '') -ine $s.application.appId) -or
      ([string](Get-MaesterAdoProperty $ep.authorization.parameters 'scope' '') -ine $s.scope) -or
      ((Get-MaesterAdoProperty $ep.data 'isDraft' $false) -eq $true) -or $ep.isReady -ne $true
    if ($needsBinding) {
      $body = $ep | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
      $body.authorization.parameters.serviceprincipalid = $s.application.appId
      $body.authorization.parameters.scope = $s.scope
      $body.data.isDraft = $false
      $body.isReady = $true
      $ops.Add(@{ method = 'PUT'; uri = "$($s.root)/serviceendpoint/endpoints/$($ep.id)?api-version=7.1"; body = $body; kind = 'EndpointBinding' })
    }
  }
  $requested = @{}; foreach ($k in $Parameters.Keys) { $requested[$k] = $Parameters[$k] }
  $values = @($ops | ForEach-Object { "$($_.kind):$($_.method):$($_.uri)" })
  New-MaesterConsentPlan -TenantId $Parameters.TenantId -PrincipalObjectId $operator.id -Capability 'AzureDevOpsRuntimeBootstrap' `
    -ManifestVersion '1.0' -ManifestSha256 ((Get-FileHash $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()) `
    -Desired $values -Missing $values -Details @{ setupClientId = $env:MAESTER_SETUP_CLIENT_ID; setupAccount = $env:MAESTER_SETUP_ACCOUNT; parameters = $requested; setupScopes = $Parameters.SetupScopes; inventory = $s; operations = @($ops.ToArray()); nextStep = 'Stop after these exact operations. Regenerate a fresh bootstrap plan for newly resolved identities or a separate setup access plan. No Graph grants, RBAC, pipeline permissions or assessment run is authorized here.' }
}
function Get-MaesterOwnershipOperationKey {
  param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Target)
  $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Target))).ToLowerInvariant()
  return "$Kind`:$hash"
}

function Get-MaesterAdoOwnershipBinding {
  param([Parameter(Mandatory)][hashtable]$Parameters, [Parameter(Mandatory)]$Snapshot)
  if ([string]$Snapshot.organization.name -cne [string]$Parameters.Organization -or [string]$Snapshot.organization.name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { throw 'Ownership organization must match the exact reviewed Azure DevOps organization.' }
  @{
    environmentName = $Parameters.EnvironmentName; tenantId = $Parameters.TenantId.ToLowerInvariant()
    subscriptionId = $Parameters.SubscriptionId.ToLowerInvariant(); solutionName = 'azure-devops'
    resourceGroupId = "/subscriptions/$($Parameters.SubscriptionId.ToLowerInvariant())/resourceGroups/$($Parameters.ResourceGroupName)"
    setupClientId = $env:MAESTER_SETUP_CLIENT_ID.ToLowerInvariant()
    organizationName = [string]$Snapshot.organization.name; organizationId = [string]$Snapshot.organization.id
    projectName = [string]$Snapshot.project.name; projectId = [string]$Snapshot.project.id
    adoOrganizationUrl = "https://dev.azure.com/$($Snapshot.organization.name)"; adoProjectId = [string]$Snapshot.project.id
  }
}

function Assert-MaesterOwnershipApplyReady {
  param([Parameter(Mandatory)]$Session)
  $journal = Get-MaesterOwnershipJournal -Session $Session
  if (@($journal.records | Where-Object { $_.state -in @('pending', 'deleting', 'conflict') }).Count) {
    throw 'An earlier ownership operation has an unresolved outcome or conflict. Inspect its exact receipt before applying more changes.'
  }
}

function Find-MaesterOwnedOperationId {
  param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][string]$IdField, [string]$Id)
  if (-not $Id) { return '' }
  $records = @((Get-MaesterOwnershipJournal -Session $Session).records | Where-Object {
    $_.kind -ceq $Kind -and $_.ownership -ceq 'Created' -and $_.state -ceq 'applied' -and
    (Get-MaesterAdoProperty $_.exactIds $IdField '') -ceq $Id
  })
  if ($records.Count -gt 1) { throw 'Ownership journal has ambiguous parent receipts.' }
  if ($records.Count -eq 1) { return [string]$records[0].operationId }
  return ''
}

function Get-MaesterEndpointBindingState {
  param($Endpoint)
  @{
    appId = [string](Get-MaesterAdoProperty $Endpoint.authorization.parameters 'serviceprincipalid' '')
    scope = [string](Get-MaesterAdoProperty $Endpoint.authorization.parameters 'scope' '')
    isDraft = [bool](Get-MaesterAdoProperty $Endpoint.data 'isDraft' $false); isReady = [bool]$Endpoint.isReady
    issuer = [string](Get-MaesterAdoProperty $Endpoint.authorization.parameters 'workloadIdentityFederationIssuer' '')
    subject = [string](Get-MaesterAdoProperty $Endpoint.authorization.parameters 'workloadIdentityFederationSubject' '')
  }
}

function Get-MaesterApplicationCreationBaseline {
  param($Application)
  $web = Get-MaesterAdoProperty $Application 'web'
  $implicit = Get-MaesterAdoProperty $web 'implicitGrantSettings'
  $groups = [string](Get-MaesterAdoProperty $Application 'groupMembershipClaims' '')
  $redirects = Get-MaesterAdoProperty $web 'redirectUris' @()
  $identifiers = Get-MaesterAdoProperty $Application 'identifierUris' @()
  @{
    redirectUris = @($redirects | Where-Object { $null -ne $_ })
    identifierUris = @($identifiers | Where-Object { $null -ne $_ })
    groupMembershipClaims = $(if ($groups) { $groups } else { 'None' })
    enableIdTokenIssuance = [bool](Get-MaesterAdoProperty $implicit 'enableIdTokenIssuance' $false)
    enableAccessTokenIssuance = [bool](Get-MaesterAdoProperty $implicit 'enableAccessTokenIssuance' $false)
    signInAudience = [string](Get-MaesterAdoProperty $Application 'signInAudience' 'AzureADMyOrg')
  }
}

function Assert-MaesterApplicationCreationState {
  param($Application, [hashtable]$Baseline, [switch]$Partial)
  $has = { param($value, $name) $null -ne $value -and $(if ($value -is [Collections.IDictionary]) { $value.Contains($name) } else { $null -ne $value.PSObject.Properties[$name] }) }
  $web = Get-MaesterAdoProperty $Application 'web'
  $implicit = Get-MaesterAdoProperty $web 'implicitGrantSettings'
  $actual = Get-MaesterApplicationCreationBaseline $Application
  foreach ($field in $Baseline.Keys) {
    $source = switch ($field) { redirectUris { $web }; { $_ -in @('enableIdTokenIssuance','enableAccessTokenIssuance') } { $implicit }; default { $Application } }
    if (-not (& $has $source $field)) {
      if ($Partial) { continue }
      throw "Application creation readback omitted baseline field '$field'."
    }
    $raw = Get-MaesterAdoProperty $source $field
    if ($field -in @('enableIdTokenIssuance','enableAccessTokenIssuance') -and $raw -isnot [bool]) { throw "Application creation returned malformed baseline field '$field'." }
    $expectedValue = $Baseline[$field]; $actualValue = $actual[$field]
    if ($expectedValue -is [array]) {
      if ($raw -isnot [Collections.IList] -or (@($actualValue | Sort-Object -CaseSensitive) -join [char]0) -cne (@($expectedValue | Sort-Object -CaseSensitive) -join [char]0)) { throw "Application creation differs from approved baseline field '$field'." }
    } elseif ($actualValue -cne $expectedValue) { throw "Application creation differs from approved baseline field '$field'." }
  }
}

function Start-MaesterAdoBootstrapOwnership {
  param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Operation)
  $s = $Plan.details.inventory
  $args = @{ Session = $Session; Key = (Get-MaesterOwnershipOperationKey -Kind "Bootstrap-$($Operation.kind)" -Target $Operation.uri); PlanHash = $Plan.planHash; Ownership = 'Created' }
  switch ($Operation.kind) {
    Repository { $args.Kind = 'AdoRepository'; $args.Expected = @{ organizationId = $s.organization.id; projectId = $s.project.id; repositoryName = $Operation.body.name } }
    Endpoint {
      $args.Kind = 'AdoServiceConnection'; $args.Expected = @{ organizationId = $s.organization.id; projectId = $s.project.id
        serviceConnectionName = $Operation.body.name; tenantId = $Plan.details.parameters.TenantId; subscriptionId = $Plan.details.parameters.SubscriptionId; scope = $s.scope; isShared = $false }
    }
    Application { $args.Kind = 'EntraApplication'; $args.Expected = @{ purpose = 'Runtime'; displayName = $Operation.body.displayName; creatorPrincipalId = $Plan.principalObjectId }; $args.After = Get-MaesterApplicationCreationBaseline $Operation.body }
    Principal { $args.Kind = 'EntraServicePrincipal'; $args.Expected = @{ appId = $Operation.body.appId; creatorPrincipalId = $Plan.principalObjectId } }
    Federation {
      $args.Kind = 'FederatedIdentityCredential'; $args.Expected = @{ applicationObjectId = $s.application.id
        issuer = $Operation.body.issuer; subject = $Operation.body.subject; audiences = @($Operation.body.audiences) }
    }
    EndpointBinding {
      $args.Kind = 'AdoServiceConnectionBinding'; $args.Ownership = 'Mutation'
      $args.Expected = @{ organizationId = $s.organization.id; projectId = $s.project.id; serviceConnectionId = $s.endpoint.id
        applicationObjectId = $s.application.id; appId = $s.application.appId }
      $args.Before = Get-MaesterEndpointBindingState $s.endpoint; $args.After = Get-MaesterEndpointBindingState $Operation.body
      $parent = Find-MaesterOwnedOperationId -Session $Session -Kind AdoServiceConnection -IdField serviceConnectionId -Id $s.endpoint.id
      if ($parent) { $args.CoveredByOperationId = $parent }
    }
    default { throw 'Unsupported bootstrap ownership operation.' }
  }
  (Start-MaesterOwnedOperation @args).operationId
}

function Invoke-MaesterAdoBootstrapPlan {
  param([Parameter(Mandatory)][hashtable]$Parameters, [Parameter(Mandatory)][string]$ApprovedPlanHash, $OwnershipSession)
  if (-not $OwnershipSession) { throw 'An open ownership journal session is required before bootstrap application.' }
  Assert-MaesterOwnershipApplyReady -Session $OwnershipSession
  $plan = Get-MaesterAdoBootstrapPlan -Parameters $Parameters
  if ($plan.planHash -cne $ApprovedPlanHash) { throw 'Bootstrap inventory changed. Review and approve a fresh bootstrap plan.' }
  Assert-MaesterConsentPlanApproval -Plan $plan -ApprovedPlanHash $ApprovedPlanHash
  $receipts = [Collections.Generic.List[object]]::new()
  foreach ($op in $plan.details.operations) {
    $operationId = Start-MaesterAdoBootstrapOwnership -Session $OwnershipSession -Plan $plan -Operation $op
    $response = if ($op.uri.StartsWith('https://graph.microsoft.com/')) {
      Invoke-GraphRestRequest -Method $op.method -Uri $op.uri -Body ($op.body | ConvertTo-Json -Depth 40 -Compress) -ContentType 'application/json'
    } else { Invoke-MaesterAdoRequest -Uri $op.uri -TenantId $Parameters.TenantId -Method $op.method -Body $op.body }
    if (-not $response.id) { throw "Bootstrap $($op.kind) returned no exact identifier; stop and inspect before retrying." }
    $ids = switch ($op.kind) {
      Repository { @{ repositoryId = [string]$response.id } }
      Endpoint { @{ serviceConnectionId = [string]$response.id } }
      EndpointBinding { @{ serviceConnectionId = [string]$response.id } }
      Application { @{ applicationObjectId = [string]$response.id; appId = [string]$response.appId } }
      Principal { @{ servicePrincipalId = [string]$response.id } }
      Federation { @{ federatedCredentialId = [string]$response.id } }
    }
    # Checkpoint the exact response BEFORE subsequent writes or readback. A
    # failing readback must not erase evidence of an already-created object.
    Complete-MaesterOwnedOperation -Session $OwnershipSession -OperationId $operationId -ExactIds $ids | Out-Null
    if ($op.kind -eq 'Application') {
      try {
        $baseline = Get-MaesterApplicationCreationBaseline $op.body
        Assert-MaesterApplicationCreationState -Application $response -Baseline $baseline -Partial
        $createdApp = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($response.id)?`$select=id,appId,signInAudience,identifierUris,groupMembershipClaims,web"
        if ($createdApp.id -ine $response.id -or $createdApp.appId -ine $response.appId) { throw 'Application creation readback returned a different exact identity.' }
        Assert-MaesterApplicationCreationState -Application $createdApp -Baseline $baseline
      } catch {
        Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $operationId -State conflict | Out-Null
        throw
      }
    }
    $receipts.Add([pscustomobject]@{ kind = $op.kind; id = [string]$response.id; operationId = $operationId; baseline = $(if ($op.kind -eq 'Application') { $baseline } else { $null }) })
  }
  # Fresh service inventories verify all outputs and reveal any next-stage delta.
  $result = Get-MaesterAdoBootstrapPlan -Parameters $Parameters
  $snapshot = $result.details.inventory
  foreach ($receipt in $receipts) {
    $actualId = switch ($receipt.kind) {
      Repository { [string]$snapshot.repository.id }
      Endpoint { [string]$snapshot.endpoint.id }
      EndpointBinding { [string]$snapshot.endpoint.id }
      Application { [string]$snapshot.application.id }
      Principal { [string]$snapshot.principal.id }
      Federation { if (@($snapshot.matchingFederation).Count -eq 1) { [string]$snapshot.matchingFederation[0].id } else { '' } }
    }
    if ($receipt.kind -eq 'EndpointBinding' -and ($snapshot.endpoint.authorization.parameters.serviceprincipalid -ine $snapshot.application.appId -or
        $snapshot.endpoint.authorization.parameters.scope -ine $snapshot.scope -or
        (Get-MaesterAdoProperty $snapshot.endpoint.data 'isDraft' $false) -eq $true -or $snapshot.endpoint.isReady -ne $true)) {
      Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $receipt.operationId -State conflict | Out-Null
      throw 'Bootstrap endpoint binding readback differs from the approved exact application, scope, draft state or readiness.'
    }
    if ($receipt.id -ine $actualId) { Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $receipt.operationId -State conflict | Out-Null; throw "Bootstrap $($receipt.kind) exact readback could not be verified. Stop and inspect before retrying." }
    if ($receipt.kind -eq 'Application') {
      foreach ($field in $receipt.baseline.Keys) {
        $expected = $receipt.baseline[$field] | ConvertTo-Json -Depth 5 -Compress
        $actual = $snapshot.application.configuration[$field] | ConvertTo-Json -Depth 5 -Compress
        if ($actual -cne $expected) {
          Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $receipt.operationId -State conflict | Out-Null
          throw "Application creation stage readback differs from approved baseline field '$field'."
        }
      }
    }
  }
  [pscustomobject]@{ AppliedPlan = $plan; NextPlan = $result; Snapshot = $result.details.inventory }
}
function Get-MaesterAdoIdentity {
  param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName, [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$Organization, [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$RepositoryName, [Parameter(Mandatory)][string]$ServiceConnectionName,
    [string]$ExpectedServiceConnectionId, [string]$ExpectedApplicationId, [string]$ExpectedApplicationObjectId,
    [string]$ExpectedPrincipalObjectId, [string]$SubscriptionName, [string[]]$SetupScopes = @('Application.Read.All','AppRoleAssignment.ReadWrite.All','Directory.Read.All','Application.ReadWrite.All'), [bool]$CreateRepositoryIfMissing = $true)
  $s = Get-MaesterAdoBootstrapSnapshot @PSBoundParameters
  if (-not $s.repository -or -not $s.endpoint -or -not $s.application -or -not $s.principal -or $s.matchingFederation.Count -ne 1) { throw 'Runtime bootstrap is incomplete. Review a -Bootstrap plan before setup access.' }
  if ($s.endpoint.authorization.parameters.serviceprincipalid -ine $s.application.appId -or
      [string](Get-MaesterAdoProperty $s.endpoint.authorization.parameters 'scope' '') -ine $s.scope -or
      (Get-MaesterAdoProperty $s.endpoint.data 'isDraft' $false) -eq $true -or $s.endpoint.isReady -ne $true) { throw 'The exact endpoint binding or resource-group scope requires a reviewed -Bootstrap update.' }
  [pscustomobject]@{ principalId = $s.principal.id; principal = $s.principal; snapshot = $s; inventory = $s
    grantTarget = @{ TargetType = 'FederatedApplication'; ExpectedApplicationId = $s.application.appId; ExpectedApplicationObjectId = $s.application.id; ExpectedFederatedCredentialIssuer = $s.issuer; ExpectedFederatedCredentialSubject = $s.subject } }
}
function Get-MaesterAdoPipelineInventory {
  param($Identity, [hashtable]$Configuration, [hashtable]$Parameters)
  $s = $Identity.snapshot
  if (-not $Configuration.pipelineName -or -not $Configuration.yamlPath -or -not $Configuration.branch) { throw 'Exact pipeline name, YAML path and branch are required for setup planning.' }
  if ($Configuration.branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Configuration.branch.Contains('..') -or $Configuration.branch.EndsWith('/')) { throw 'Unsupported pipeline branch name.' }
  if ($Configuration.yamlPath -match '(^/|[\\:\x00-\x1f\x7f]|(^|/)\.\.?(/|$))') { throw 'Pipeline YAML must be a repository-relative path without traversal.' }
  $definitions = @(Get-MaesterAdoCollection -Uri "$($s.root)/build/definitions?name=$([uri]::EscapeDataString($Configuration.pipelineName))&api-version=7.1" -TenantId $Parameters.TenantId)
  if ($definitions.Count -gt 1) { throw 'Pipeline name is ambiguous.' }
  $pipeline = $null
  if ($definitions.Count -eq 1) {
    $id = [string]$definitions[0].id
    if ($id -notmatch '^[1-9][0-9]*$') { throw 'Pipeline inventory returned an invalid exact definition ID.' }
    $definition = Invoke-MaesterAdoRequest -Uri "$($s.root)/build/definitions/${id}?api-version=7.1" -TenantId $Parameters.TenantId
    if ([string]$definition.revision -cnotmatch '^[1-9][0-9]*$') { throw 'Pipeline inventory returned no valid definition revision.' }
    if ([string]$definition.id -cne $id -or $definition.name -cne $Configuration.pipelineName -or
        $definition.project.id -ine $s.project.id -or $definition.repository.id -ine $s.repository.id -or
        $definition.process.yamlFilename.TrimStart('/') -cne $Configuration.yamlPath -or
        $definition.repository.defaultBranch -cne "refs/heads/$($Configuration.branch)") { throw 'Existing pipeline does not match the exact selected project, repository, YAML path and branch.' }
    $pipeline = [ordered]@{ id = $definition.id; name = $definition.name; revision = $definition.revision; projectId = $s.project.id; repositoryId = $definition.repository.id; yamlPath = $definition.process.yamlFilename; branch = $definition.repository.defaultBranch }
  }
  $refs = @(Get-MaesterAdoCollection -Uri "$($s.root)/git/repositories/$($s.repository.id)/refs?filter=$([uri]::EscapeDataString('heads/' + $Configuration.branch))&api-version=7.1" -TenantId $Parameters.TenantId | Where-Object { $_.name -ceq "refs/heads/$($Configuration.branch)" })
  if ($refs.Count -gt 1 -or ($refs.Count -eq 1 -and $refs[0].objectId -cnotmatch '^[a-f0-9]{40}$')) { throw 'Selected branch inventory is ambiguous or malformed.' }
  if (-not $refs.Count -and (Get-MaesterAdoProperty $s.repository 'defaultBranch')) { throw 'The selected branch is absent from an existing non-empty repository. Create and review it separately before setup.' }
  [ordered]@{ pipeline = $pipeline; branchObjectId = $(if ($refs.Count) { $refs[0].objectId } else { '' }) }
}
function Assert-MaesterAdoPipelineBinding {
  param([Parameter(Mandatory)]$Identity, [Parameter(Mandatory)][hashtable]$Configuration,
    [Parameter(Mandatory)][hashtable]$Parameters, $ExpectedPipeline, [string]$CreatedPipelineId)
  $current = (Get-MaesterAdoPipelineInventory -Identity $Identity -Configuration $Configuration -Parameters $Parameters).pipeline
  if ($CreatedPipelineId) {
    if ($CreatedPipelineId -notmatch '^[1-9][0-9]*$' -or -not $current -or [string]$current.id -cne $CreatedPipelineId) {
      throw 'Created pipeline could not be read back against the approved exact targets.'
    }
  } elseif ($ExpectedPipeline) {
    if (-not $current -or [string]$current.id -cne [string]$ExpectedPipeline.id -or
        [string]$current.revision -cne [string]$ExpectedPipeline.revision) {
      throw 'Pipeline identity or definition revision changed after approval.'
    }
  } elseif ($current) { throw 'A pipeline appeared after the reviewed creation plan; review a fresh plan.' }
  return $current
}
function Get-MaesterAdoAccessDelta {
  param($Identity, [hashtable]$Parameters)
  $s = $Identity.snapshot
  $operations = @(); $inventory = [ordered]@{}
  foreach ($resource in @(@{ type = 'endpoint'; id = $s.endpoint.id }, @{ type = 'repository'; id = "$($s.project.id).$($s.repository.id)" })) {
    $uri = "$($s.root)/pipelines/pipelinePermissions/$($resource.type)/$($resource.id)?api-version=7.1-preview.1"
    $permissions = Invoke-MaesterAdoRequest -Uri $uri -TenantId $Parameters.TenantId
    if ($null -eq (Get-MaesterAdoProperty $permissions 'allPipelines') -or $null -eq (Get-MaesterAdoProperty $permissions.allPipelines 'authorized')) { throw 'Unreadable Azure DevOps pipeline authorization inventory.' }
    $inventory[$resource.type] = $permissions
    if ($permissions.allPipelines.authorized -ne $true) {
      $operations += @{ method = 'PATCH'; uri = $uri; body = @{ allPipelines = @{ authorized = $true }; pipelines = @() }; resourceType = $resource.type; resourceId = $resource.id; organizationId = $s.organization.id; projectId = $s.project.id; repositoryId = $s.repository.id; consequence = "Authorize every pipeline in the exact selected project to use this $($resource.type)." }
    }
  }
  [ordered]@{ inventory = $inventory; operations = $operations; consequence = 'Existing project-wide pipeline access is preserved; newly needed project-wide access requires exact aggregate plan approval.' }
}
function Invoke-MaesterAdoAccessDelta {
  param($Delta, [hashtable]$Parameters, $OwnershipSession, [string]$ApprovedPlanHash)
  if (-not $OwnershipSession) { throw 'An open ownership journal session is required before ADO authorization.' }
  foreach ($op in $Delta.operations) {
    $old = $Delta.inventory[$op.resourceType]
    $before = @{ allPipelinesAuthorized = [bool]$old.allPipelines.authorized
      pipelineIds = @($old.pipelines | Where-Object { $_.authorized -eq $true } | ForEach-Object { [string]$_.id }) }
    $args = @{ Session = $OwnershipSession; Key = "Authorization:$($op.resourceType):$($op.resourceId)"; Kind = 'AdoPipelineAuthorization'
      PlanHash = $ApprovedPlanHash; Ownership = 'Mutation'; Expected = @{ organizationId = $op.organizationId; projectId = $op.projectId; resourceType = $op.resourceType; resourceId = $op.resourceId }
      Before = $before; After = @{ allPipelinesAuthorized = $true; pipelineIds = @() } }
    $parent = if ($op.resourceType -eq 'endpoint') {
      Find-MaesterOwnedOperationId -Session $OwnershipSession -Kind AdoServiceConnection -IdField serviceConnectionId -Id $op.resourceId
    } else { Find-MaesterOwnedOperationId -Session $OwnershipSession -Kind AdoRepository -IdField repositoryId -Id $op.repositoryId }
    if ($parent) { $args.CoveredByOperationId = $parent }
    $operationId = (Start-MaesterOwnedOperation @args).operationId
    $null = Invoke-MaesterAdoRequest -Uri $op.uri -TenantId $Parameters.TenantId -Method $op.method -Body $op.body
    Complete-MaesterOwnedOperation -Session $OwnershipSession -OperationId $operationId -ExactIds @{ resourceId = $op.resourceId } | Out-Null
    $readback = Invoke-MaesterAdoRequest -Uri $op.uri -TenantId $Parameters.TenantId
    if ($readback.allPipelines.authorized -ne $true) {
      Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $operationId -State conflict | Out-Null
      throw 'Azure DevOps pipeline authorization could not be verified.'
    }
  }
}
Export-ModuleMember -Function Get-MaesterApplicationCreationBaseline, Assert-MaesterApplicationCreationState, Assert-MaesterOwnershipApplyReady, Get-MaesterOwnershipOperationKey, Get-MaesterAdoOwnershipBinding, Find-MaesterOwnedOperationId, Get-MaesterAdoBootstrapPlan, Invoke-MaesterAdoBootstrapPlan, Get-MaesterAdoIdentity, Get-MaesterAdoAccessDelta, Invoke-MaesterAdoAccessDelta, Get-MaesterAdoPipelineInventory, Assert-MaesterAdoPipelineBinding
