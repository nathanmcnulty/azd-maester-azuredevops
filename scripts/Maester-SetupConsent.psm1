#Requires -Version 7.6
# Read-only access planning and exact-plan application for deployment operators.
# Hosted runners never import this module or grant their own access.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MaesterSetupCollection {
  param([Parameter(Mandatory)][string]$Uri, [hashtable]$ArmHeaders)
  $response = if ($ArmHeaders) {
    Invoke-RestMethod -Method GET -Uri $Uri -Headers $ArmHeaders
  } else { Invoke-GraphRestRequest -Method GET -Uri $Uri }
  if ($null -eq $response -or -not $response.PSObject.Properties['value'] -or $response.value -isnot [array]) {
    throw "Incomplete access inventory: $Uri"
  }
  foreach ($property in @('nextLink', '@odata.nextLink')) {
    if ($response.PSObject.Properties[$property] -and $response.$property) {
      throw "Paginated access inventory requires a complete read before setup: $Uri"
    }
  }
  return @($response.value)
}

function Get-MaesterSetupProperty {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  if ($Object -is [Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
  } elseif ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
  return $Default
}

function Test-MaesterSetupDesiredState {
  param($Actual, $Desired)
  if ($null -eq $Desired) { return $null -eq $Actual }
  if ($Desired -is [Collections.IDictionary]) {
    if ($null -eq $Actual) { return $false }
    foreach ($key in $Desired.Keys) {
      # Preserve empty arrays and require every requested property to be present.
      if ($Actual -is [Collections.IDictionary]) {
        if (-not $Actual.Contains($key)) { return $false }
        $actualValue = $Actual[$key]
      } else {
        if (-not $Actual.PSObject.Properties[$key]) { return $false }
        $actualValue = $Actual.$key
      }
      if (-not (Test-MaesterSetupDesiredState -Actual $actualValue -Desired $Desired[$key])) { return $false }
    }
    return $true
  }
  if ($Desired -is [Collections.IEnumerable] -and $Desired -isnot [string]) {
    $actualValues = @($Actual); $desiredValues = @($Desired)
    if ($actualValues.Count -ne $desiredValues.Count) { return $false }
    for ($i = 0; $i -lt $desiredValues.Count; $i++) {
      if (-not (Test-MaesterSetupDesiredState $actualValues[$i] $desiredValues[$i])) { return $false }
    }
    return $true
  }
  return $Actual -ceq $Desired
}

function New-MaesterSetupOperation {
  param([string]$Category, [string]$Method, [string]$Uri, $Body, [string]$Receipt)
  [pscustomobject][ordered]@{ category = $Category; method = $Method; uri = $Uri; body = $Body; receipt = $Receipt }
}

function Get-MaesterSetupAccessPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$PrincipalObjectId,
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][hashtable]$AdoParameters,
    [hashtable]$PipelineConfiguration = @{},
    [Parameter(Mandatory)]$StorageAccount,
    $WebApp,
    [string]$SecurityGroupObjectId,
    [string]$SecurityGroupDisplayName,
    [Parameter(Mandatory)][hashtable]$ArmHeaders,
    [ValidateSet('Minimal', 'Full', 'Extended')][string]$PermissionProfile = 'Full',
    [bool]$IncludeMailSend = $false,
    [bool]$IncludeReportSettingsWrite = $false,
    [switch]$IncludeExchange,
    [switch]$IncludeTeams,
    [switch]$IncludeAzure,
    [string[]]$AzureScopes
  )
  $ado = Get-MaesterAdoIdentity @AdoParameters
  if ($ado.principalId -ine $PrincipalObjectId) { throw 'ADO identity differs from the reviewed runtime principal.' }
  $grantTarget = $ado.grantTarget
  $grantScript = Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1'
  $graphPlan = & $grantScript -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId `
    -PermissionProfile $PermissionProfile -IncludeMailSend $IncludeMailSend -IncludeReportSettingsWrite $IncludeReportSettingsWrite @grantTarget
  if (-not $graphPlan -or $graphPlan.schemaVersion -cne '1.0' -or $graphPlan.planHash -notmatch '^[a-f0-9]{64}$') {
    throw 'The canonical Graph permission planner did not return a versioned plan.'
  }
  $operations = [Collections.Generic.List[object]]::new()
  $inventory = [ordered]@{}
  $principal = $ado.principal
  $inventory['principal'] = [ordered]@{ id = $principal.id; appId = $principal.appId; displayName = $principal.displayName }
  $inventory['adoIdentity'] = $ado.inventory
  # Runtime Azure access is separate from Graph assessment access and is planned
  # at exact already-validated deployment resource IDs.
  $baseRoles = @(
    @{ scope = $ResourceId; role = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' }
    @{ scope = $StorageAccount.id; role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' }
  )
  if ($WebApp) { $baseRoles += @{ scope = $WebApp.id; role = 'de139f84-1756-47ae-9be6-808fbbe84772' } }
  $baseInventory = [ordered]@{}
  foreach ($role in $baseRoles) {
    $roleId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$($role.role)"
    $assignments = @(Get-MaesterSetupCollection -Uri "https://management.azure.com$($role.scope)/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()&api-version=2022-04-01" -ArmHeaders $ArmHeaders)
    $matches = @($assignments | Where-Object { $_.properties.principalId -eq $PrincipalObjectId -and $_.properties.roleDefinitionId -eq $roleId })
    if ($matches.Count -gt 1) { throw 'Ambiguous runtime Azure role assignment inventory.' }
    $baseInventory["$($role.scope):$($role.role)"] = @($matches | ForEach-Object id | Sort-Object)
    if ($matches.Count -eq 0) {
      $operations.Add((New-MaesterSetupOperation 'RuntimeAzureAccess' 'PUT' "$($role.scope)/providers/Microsoft.Authorization/roleAssignments/{assignmentId}?api-version=2022-04-01" `
        ([ordered]@{ properties = [ordered]@{ roleDefinitionId = $roleId; principalId = $PrincipalObjectId; principalType = 'ServicePrincipal' } }) 'AZDO_BASE_ROLE_ASSIGNMENT_IDS'))
    }
  }
  $inventory['runtimeAzureAccess'] = $baseInventory

  $user = Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
  if (-not $user.id -or $user.userPrincipalName -ine $env:MAESTER_SETUP_ACCOUNT) {
    throw 'Storage reader access requires the explicitly selected setup account.'
  }
  $inventory['operator'] = [ordered]@{ id = $user.id; userPrincipalName = $user.userPrincipalName }
  $storageRoleId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
  $storageAssignments = @(Get-MaesterSetupCollection -Uri "https://management.azure.com$($StorageAccount.id)/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()&api-version=2022-04-01" -ArmHeaders $ArmHeaders)
  $storageMatches = @($storageAssignments | Where-Object { $_.properties.principalId -eq $user.id -and $_.properties.roleDefinitionId -eq $storageRoleId })
  $inventory['storageReader'] = @($storageMatches | ForEach-Object id | Sort-Object)
  if ($storageMatches.Count -eq 0) {
    $operations.Add((New-MaesterSetupOperation 'StorageReader' 'PUT' "$($StorageAccount.id)/providers/Microsoft.Authorization/roleAssignments/{assignmentId}?api-version=2022-04-01" `
      ([ordered]@{ properties = [ordered]@{ roleDefinitionId = $storageRoleId; principalId = $user.id; principalType = 'User' } }) ''))
  }

  if ($IncludeExchange) {
    $exchange = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000002-0000-0ff1-ce00-000000000000'&`$select=id,appId,appRoles")
    if ($exchange.Count -ne 1 -or (Get-MaesterSetupProperty $exchange[0] 'appId') -cne '00000002-0000-0ff1-ce00-000000000000' -or
        [string]::IsNullOrWhiteSpace([string](Get-MaesterSetupProperty $exchange[0] 'id'))) {
      throw 'Exactly one verified Exchange resource service principal is required.'
    }
    $roleId = 'dc50a0fb-09a3-484d-be87-e023b12c6440'
    $roles = @($exchange[0].appRoles | Where-Object { $_.id -eq $roleId -and $_.value -eq 'Exchange.ManageAsApp' -and $_.isEnabled -eq $true -and 'Application' -in $_.allowedMemberTypes })
    if ($roles.Count -ne 1) { throw 'Exchange.ManageAsApp must be an enabled application role.' }
    $assignments = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/appRoleAssignments?`$top=999")
    $matches = @($assignments | Where-Object { $_.principalId -eq $PrincipalObjectId -and $_.resourceId -eq $exchange[0].id -and $_.appRoleId -eq $roleId })
    $inventory['exchangeApplicationRole'] = @($matches | ForEach-Object id | Sort-Object)
    if ($matches.Count -eq 0) {
      $operations.Add((New-MaesterSetupOperation 'Exchange' 'POST' "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/appRoleAssignments" `
        ([ordered]@{ principalId = $PrincipalObjectId; resourceId = $exchange[0].id; appRoleId = $roleId }) 'EXO_APPROLE_ASSIGNMENT_IDS'))
    }
    # The Exchange session is established by the entrypoint before planning. A
    # failed or unavailable inventory is never treated as permission to grant.
    $exchangePrincipals = @(Get-ServicePrincipal -ErrorAction Stop | Where-Object { $_.ObjectId -eq $PrincipalObjectId -or $_.AppId -eq $principal.appId })
    if ($exchangePrincipals.Count -gt 1 -or ($exchangePrincipals.Count -eq 1 -and
        ($exchangePrincipals[0].ObjectId -ne $PrincipalObjectId -or $exchangePrincipals[0].AppId -ne $principal.appId))) {
      throw 'Exchange service principal identity is ambiguous or does not match the federated runtime application.'
    }
    $exchangeRoles = @()
    if ($exchangePrincipals.Count -eq 1) {
      $exchangeRoles = @(Get-ManagementRoleAssignment -RoleAssignee $PrincipalObjectId -ErrorAction Stop | Where-Object { [string]$_.Role -eq 'View-Only Configuration' })
    } else {
      $operations.Add((New-MaesterSetupOperation 'Exchange' 'New-ServicePrincipal' $PrincipalObjectId `
        ([ordered]@{ AppId = $principal.appId; ObjectId = $PrincipalObjectId; DisplayName = $principal.displayName }) ''))
    }
    $inventory['exchangeServicePrincipal'] = @($exchangePrincipals | ForEach-Object { [ordered]@{ ObjectId = [string]$_.ObjectId; AppId = [string]$_.AppId } })
    $inventory['exchangeRbac'] = @($exchangeRoles | ForEach-Object { [string]$_.Identity } | Sort-Object)
    if ($exchangeRoles.Count -eq 0) {
      $operations.Add((New-MaesterSetupOperation 'Exchange' 'New-ManagementRoleAssignment' $PrincipalObjectId `
        ([ordered]@{ Role = 'View-Only Configuration'; App = $PrincipalObjectId }) ''))
    }
  }
  if ($IncludeTeams) {
    $definitions = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=displayName eq 'Teams Reader'&`$select=id,displayName,isBuiltIn")
    if ($definitions.Count -ne 1 -or $definitions[0].displayName -cne 'Teams Reader' -or $definitions[0].isBuiltIn -ne $true) { throw 'Exactly one built-in Teams Reader role definition is required.' }
    $definitionId = $definitions[0].id
    $assignments = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$PrincipalObjectId' and roleDefinitionId eq '$definitionId' and directoryScopeId eq '/'&`$select=id,principalId,roleDefinitionId,directoryScopeId")
    if (@($assignments | Where-Object { $_.principalId -ne $PrincipalObjectId -or $_.roleDefinitionId -ne $definitionId -or $_.directoryScopeId -ne '/' }).Count) { throw 'Unexpected Teams role assignment inventory.' }
    $inventory['teams'] = @($assignments | ForEach-Object id | Sort-Object)
    if ($assignments.Count -eq 0) {
      $operations.Add((New-MaesterSetupOperation 'Teams' 'POST' 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
        ([ordered]@{ principalId = $PrincipalObjectId; roleDefinitionId = $definitionId; directoryScopeId = '/' }) 'TEAMS_READER_ROLE_ASSIGNMENT_IDS'))
    }
  }
  $azureInventory = [ordered]@{}
  if ($IncludeAzure) {
    foreach ($scope in @($AzureScopes | Sort-Object -Unique)) {
      if ($scope -notmatch '^/subscriptions/[0-9a-fA-F-]{36}$' -and $scope -notmatch '^/providers/Microsoft.Management/managementGroups/[A-Za-z0-9_.()-]+$') {
        throw "Azure Reader scope must be an explicit subscription or management group: $scope"
      }
      $roleRoot = if ($scope -like '/subscriptions/*') { $scope } else { '' }
      $roleId = "$roleRoot/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
      $assignments = @(Get-MaesterSetupCollection -Uri "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()&api-version=2022-04-01" -ArmHeaders $ArmHeaders)
      $matches = @($assignments | Where-Object { $_.properties.principalId -eq $PrincipalObjectId -and $_.properties.roleDefinitionId -eq $roleId })
      $azureInventory[$scope] = @($matches | ForEach-Object id | Sort-Object)
      if ($matches.Count -eq 0) {
        $operations.Add((New-MaesterSetupOperation 'AzureReader' 'PUT' "$scope/providers/Microsoft.Authorization/roleAssignments/{assignmentId}?api-version=2022-04-01" `
          ([ordered]@{ properties = [ordered]@{ roleDefinitionId = $roleId; principalId = $PrincipalObjectId; principalType = 'ServicePrincipal' } }) 'AZURE_ROLE_ASSIGNMENT_IDS'))
      }
    }
  }
  $inventory['azureReader'] = $azureInventory

  $easyAuth = $null
  if ($WebApp) {
    if (-not $SecurityGroupObjectId) {
      if (-not $SecurityGroupDisplayName) { throw 'An explicit Easy Auth security group is required before planning.' }
      $escaped = [uri]::EscapeDataString("'$($SecurityGroupDisplayName.Replace("'", "''"))'")
      $groups = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq $escaped&`$select=id,securityEnabled")
      if ($groups.Count -ne 1) { throw 'Security group name is missing or ambiguous; provide its exact object ID.' }
      $SecurityGroupObjectId = [string]$groups[0].id
    }
    $groupGuid = [guid]::Empty
    if (-not [guid]::TryParse($SecurityGroupObjectId, [ref]$groupGuid) -or $groupGuid -eq [guid]::Empty) { throw 'SecurityGroupObjectId must be a non-empty GUID.' }
    $group = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/${SecurityGroupObjectId}?`$select=id,securityEnabled"
    if ($group.id -ine $SecurityGroupObjectId -or $group.securityEnabled -ne $true) { throw 'Easy Auth requires the exact enabled security group.' }
    $displayName = "maester-easyauth-$($WebApp.name)"
    $escapedName = [uri]::EscapeDataString("'$($displayName.Replace("'", "''"))'")
    $apps = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq $escapedName")
    if ($apps.Count -gt 1) { throw 'Easy Auth application name is ambiguous; do not consent a first match.' }
    $app = if ($apps.Count -eq 1) { $apps[0] } else { $null }
    if ($app -and ($app.displayName -cne $displayName -or $app.signInAudience -cne 'AzureADMyOrg')) { throw 'Easy Auth application must be the exact single-tenant application.' }
    $appId = if ($app) { [string]$app.appId } else { '{easyAuthClientId}' }
    $redirectUri = "https://$($WebApp.properties.defaultHostName)/.auth/login/aad/callback"
    $redirects = @(@(Get-MaesterSetupProperty (Get-MaesterSetupProperty $app 'web') 'redirectUris' @()) + $redirectUri | Sort-Object -Unique)
    $appBody = [ordered]@{ groupMembershipClaims = 'SecurityGroup'; web = [ordered]@{ redirectUris = $redirects; implicitGrantSettings = [ordered]@{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false } } }
    $inventory['easyAuthApplication'] = if ($app) { [ordered]@{ id = $app.id; appId = $app.appId; groupMembershipClaims = (Get-MaesterSetupProperty $app 'groupMembershipClaims'); web = (Get-MaesterSetupProperty $app 'web') } } else { $null }
    if (-not $app) {
      $appBody['displayName'] = $displayName; $appBody['signInAudience'] = 'AzureADMyOrg'; $appBody['identifierUris'] = @()
      $operations.Add((New-MaesterSetupOperation 'EasyAuth' 'POST' 'https://graph.microsoft.com/v1.0/applications' $appBody 'EasyAuthApplication'))
    } else {
      $web = Get-MaesterSetupProperty $app 'web'
      $implicit = Get-MaesterSetupProperty $web 'implicitGrantSettings'
      if ((Get-MaesterSetupProperty $app 'groupMembershipClaims') -cne 'SecurityGroup' -or
          (Get-MaesterSetupProperty $implicit 'enableIdTokenIssuance') -ne $true -or
          (Get-MaesterSetupProperty $implicit 'enableAccessTokenIssuance') -ne $false -or
          $redirectUri -notin @(Get-MaesterSetupProperty $web 'redirectUris' @())) {
        $operations.Add((New-MaesterSetupOperation 'EasyAuth' 'PATCH' "https://graph.microsoft.com/v1.0/applications/$($app.id)" $appBody ''))
      }
    }
    $servicePrincipals = @(if ($app) { @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$appId'") } else { @() })
    if ($servicePrincipals.Count -gt 1) { throw 'Easy Auth service principal is ambiguous.' }
    $sp = if ($servicePrincipals.Count -eq 1) { $servicePrincipals[0] } else { $null }
    if ($sp -and ($sp.appId -ine $appId -or $sp.appOwnerOrganizationId -ine $TenantId)) { throw 'Easy Auth service principal is not owned by the selected tenant.' }
    $spId = if ($sp) { [string]$sp.id } else { '{easyAuthPrincipalId}' }
    $inventory['easyAuthPrincipal'] = if ($sp) { [string]$sp.id } else { $null }
    if (-not $sp) {
      $operations.Add((New-MaesterSetupOperation 'EasyAuth' 'POST' 'https://graph.microsoft.com/v1.0/servicePrincipals' ([ordered]@{ appId = $appId }) 'EasyAuthPrincipal'))
    }
    $graph = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appId")
    if ($graph.Count -ne 1 -or $graph[0].appId -ne '00000003-0000-0000-c000-000000000000') { throw 'Exactly one Microsoft Graph resource is required for Easy Auth.' }
    $grants = @(if ($sp) { @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$spId' and resourceId eq '$($graph[0].id)' and consentType eq 'AllPrincipals'") } else { @() })
    if ($grants.Count -gt 1) { throw 'Easy Auth tenant-wide delegated grant is ambiguous.' }
    $grant = if ($grants.Count -eq 1) { $grants[0] } else { $null }
    if ($grant -and ($grant.clientId -ne $spId -or $grant.resourceId -ne $graph[0].id -or $grant.consentType -cne 'AllPrincipals')) { throw 'Unexpected Easy Auth delegated grant target.' }
    $currentScopes = if ($grant) { @($grant.scope -split '\s+' | Where-Object { $_ }) } else { @() }
    $desiredScopes = @($currentScopes + @('openid', 'profile', 'email', 'User.Read') | Sort-Object -Unique)
    $missingScopes = @('openid', 'profile', 'email', 'User.Read' | Where-Object { $_ -notin $currentScopes })
    $inventory['easyAuthGrant'] = if ($grant) { [ordered]@{ id = $grant.id; scope = ($currentScopes | Sort-Object) -join ' ' } } else { $null }
    if ($missingScopes.Count -gt 0) {
      if ($grant) {
        $operations.Add((New-MaesterSetupOperation 'EasyAuthConsent' 'PATCH' "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" ([ordered]@{ scope = $desiredScopes -join ' ' }) ''))
      } else {
        $operations.Add((New-MaesterSetupOperation 'EasyAuthConsent' 'POST' 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' ([ordered]@{ clientId = $spId; consentType = 'AllPrincipals'; resourceId = $graph[0].id; scope = $desiredScopes -join ' ' }) ''))
      }
    }
    $authUri = "$($WebApp.id)/config/authsettingsV2?api-version=2023-12-01"
    $currentAuth = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$authUri" -Headers $ArmHeaders
    if ($null -eq $currentAuth -or -not $currentAuth.PSObject.Properties['properties']) { throw 'Easy Auth current settings could not be read.' }
    $inventory['easyAuthSettings'] = $currentAuth.properties
    $authBody = [ordered]@{ properties = [ordered]@{
      platform = [ordered]@{ enabled = $true }
      globalValidation = [ordered]@{ requireAuthentication = $true; unauthenticatedClientAction = 'RedirectToLoginPage' }
      httpSettings = [ordered]@{ requireHttps = $true }
      identityProviders = [ordered]@{ azureActiveDirectory = [ordered]@{
        enabled = $true
        registration = [ordered]@{ clientId = $appId; openIdIssuer = "https://login.microsoftonline.com/$TenantId/v2.0" }
        validation = [ordered]@{ allowedAudiences = @("https://$($WebApp.properties.defaultHostName)"); defaultAuthorizationPolicy = [ordered]@{ allowedPrincipals = [ordered]@{ groups = @($SecurityGroupObjectId) } } }
      } }
      login = [ordered]@{ routes = @{} }
    } }
    # A matching configuration is reused without another write or consent.
    if (-not (Test-MaesterSetupDesiredState -Actual $currentAuth -Desired $authBody)) {
      $operations.Add((New-MaesterSetupOperation 'EasyAuthConfiguration' 'PUT' $authUri $authBody ''))
    }
    $easyAuth = [ordered]@{ objectId = $(if ($app) { [string]$app.id } else { '' }); clientId = $appId; principalId = $spId; displayName = $displayName; securityGroupId = $SecurityGroupObjectId; graphResourceId = [string]$graph[0].id; missingDelegatedScopes = $missingScopes }
  }
  $details = @{
    subscriptionId = $SubscriptionId; resourceId = $ResourceId; storageAccountId = $StorageAccount.id
    setupClientId = $env:MAESTER_SETUP_CLIENT_ID; setupAccount = $env:MAESTER_SETUP_ACCOUNT
    graphPlanHash = $graphPlan.planHash; graphPlan = $graphPlan; grantTarget = $grantTarget
    pipelineConfiguration = $PipelineConfiguration
    includeExchange = [bool]$IncludeExchange; includeTeams = [bool]$IncludeTeams; includeAzure = [bool]$IncludeAzure
    includeMailSend = $IncludeMailSend; includeReportSettingsWrite = $IncludeReportSettingsWrite
    azureScopes = @($AzureScopes | Sort-Object -Unique); easyAuth = $easyAuth; inventory = $inventory; operations = @($operations.ToArray())
  }
  $adoAccess = Get-MaesterAdoAccessDelta -Identity $ado -Parameters $AdoParameters
  $details['adoAccess'] = $adoAccess
  $details['pipelineInventory'] = Get-MaesterAdoPipelineInventory -Identity $ado -Configuration $PipelineConfiguration -Parameters $AdoParameters
  $operationValues = @($operations | ForEach-Object { "$($_.method):$($_.uri)" })
  $adoOperations = @($adoAccess.operations | ForEach-Object { "$($_.method):$($_.uri)" })
  # Publication, definition creation and queuing are consequential actions even
  # when every permission is already present. They must never take the no-delta
  # interactive auto-approval path. Hashes/targets remain in the details above.
  $pipelineActions = @()
  if (Get-MaesterSetupProperty $PipelineConfiguration 'pipelineName') {
    if (-not $details.pipelineInventory.pipeline) { $pipelineActions += "PipelineCreate:$($PipelineConfiguration.pipelineName)" }
    if ($PipelineConfiguration.pushFiles) { $pipelineActions += "RepositoryPublish:$($PipelineConfiguration.repositoryId):$($PipelineConfiguration.branch)" }
    if ($PipelineConfiguration.validateRun) { $pipelineActions += "PipelineRun:$($PipelineConfiguration.pipelineName):$($PipelineConfiguration.branch)" }
  }
  $details['pipelineActions'] = $pipelineActions
  $operationValues += $adoOperations + $pipelineActions
  $missing = @($graphPlan.missing | ForEach-Object { "Graph:$_" }) + $operationValues
  $desired = @($graphPlan.desired | ForEach-Object { "Graph:$_" }) + $operationValues
  New-MaesterConsentPlan -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId -Capability 'DeploymentSetupAccess' `
    -ManifestVersion $graphPlan.manifestVersion -ManifestSha256 $graphPlan.manifestSha256 `
    -Desired $desired -Missing $missing -Details $details
}

function Get-MaesterApplicationConfigurationReceipt {
  param($Application)
  $web = Get-MaesterSetupProperty $Application 'web'
  $implicit = Get-MaesterSetupProperty $web 'implicitGrantSettings'
  @{
    redirectUris = @(Get-MaesterSetupProperty $web 'redirectUris' @())
    groupMembershipClaims = [string](Get-MaesterSetupProperty $Application 'groupMembershipClaims' '')
    enableIdTokenIssuance = [bool](Get-MaesterSetupProperty $implicit 'enableIdTokenIssuance' $false)
    enableAccessTokenIssuance = [bool](Get-MaesterSetupProperty $implicit 'enableAccessTokenIssuance' $false)
  }
}

function Get-MaesterWebAuthReceipt {
  param($Properties)
  $validation = Get-MaesterSetupProperty $Properties 'globalValidation'
  $aad = Get-MaesterSetupProperty (Get-MaesterSetupProperty $Properties 'identityProviders') 'azureActiveDirectory'
  $aadValidation = Get-MaesterSetupProperty $aad 'validation'
  @{
    enabled = [bool](Get-MaesterSetupProperty (Get-MaesterSetupProperty $Properties 'platform') 'enabled' $false)
    issuer = [string](Get-MaesterSetupProperty (Get-MaesterSetupProperty $aad 'registration') 'openIdIssuer' '')
    allowedAudiences = @(Get-MaesterSetupProperty $aadValidation 'allowedAudiences' @())
    requireAuthentication = [bool](Get-MaesterSetupProperty $validation 'requireAuthentication' $false)
    unauthenticatedClientAction = [string](Get-MaesterSetupProperty $validation 'unauthenticatedClientAction' '')
    requireHttps = [bool](Get-MaesterSetupProperty (Get-MaesterSetupProperty $Properties 'httpSettings') 'requireHttps' $false)
    allowedGroups = @(Get-MaesterSetupProperty (Get-MaesterSetupProperty (Get-MaesterSetupProperty $aadValidation 'defaultAuthorizationPolicy') 'allowedPrincipals') 'groups' @())
  }
}

function Get-MaesterSetupOwnershipSpecification {
  param($Session, $Plan, $Operation, $ResolvedBody, [string]$ResolvedUri, $EasyAuth)
  $args = @{ Session = $Session; Key = (Get-MaesterOwnershipOperationKey -Kind "Access-$($Operation.category)" -Target "$($Operation.method):$ResolvedUri")
    PlanHash = $Plan.planHash; Ownership = 'Created' }
  $parent = ''; $ids = @{}
  switch ($Operation.category) {
    { $_ -in @('RuntimeAzureAccess', 'StorageReader', 'AzureReader') } {
      $assignmentId = $ResolvedUri.Split('?')[0]
      $args.Kind = 'AzureRoleAssignment'; $args.Expected = @{ principalId = $ResolvedBody.properties.principalId
        roleDefinitionId = $ResolvedBody.properties.roleDefinitionId; principalType = $ResolvedBody.properties.principalType
        scope = $assignmentId.Substring(0, $assignmentId.IndexOf('/providers/Microsoft.Authorization/roleAssignments/'))
        roleAssignmentId = $assignmentId }
      $args.Key = Get-MaesterOwnershipOperationKey -Kind AzureRoleAssignment -Target "$($args.Expected.principalId):$($args.Expected.roleDefinitionId):$($args.Expected.scope)"
      $ids = @{ roleAssignmentId = $assignmentId }
    }
    Teams {
      $args.Kind = 'DirectoryRoleAssignment'; $args.Expected = @{ principalId = $ResolvedBody.principalId
        roleDefinitionId = $ResolvedBody.roleDefinitionId; directoryScopeId = $ResolvedBody.directoryScopeId }
    }
    Exchange {
      switch ($Operation.method) {
        New-ServicePrincipal {
          $args.Kind = 'ExchangeServicePrincipal'; $args.Expected = @{ appId = $ResolvedBody.AppId; servicePrincipalId = $ResolvedBody.ObjectId }
        }
        New-ManagementRoleAssignment {
          $args.Kind = 'ExchangeRoleAssignment'; $args.Expected = @{ servicePrincipalId = $ResolvedBody.App; roleName = $ResolvedBody.Role }
        }
        default {
          $args.Kind = 'GraphAppRoleAssignment'; $args.Expected = @{ principalId = $ResolvedBody.principalId
            resourceId = $ResolvedBody.resourceId; appRoleId = $ResolvedBody.appRoleId; roleValue = 'Exchange.ManageAsApp' }
        }
      }
    }
    EasyAuth {
      switch ($Operation.receipt) {
        EasyAuthApplication { $args.Kind = 'EntraApplication'; $args.Expected = @{ purpose = 'EasyAuth'; displayName = $ResolvedBody.displayName; creatorPrincipalId = $Plan.details.inventory.operator.id }; $args.After = Get-MaesterApplicationCreationBaseline $ResolvedBody }
        EasyAuthPrincipal { $args.Kind = 'EntraServicePrincipal'; $args.Expected = @{ appId = $ResolvedBody.appId; creatorPrincipalId = $Plan.details.inventory.operator.id } }
        default {
          $args.Kind = 'ApplicationConfiguration'; $args.Ownership = 'Mutation'
          $args.Expected = @{ applicationObjectId = $EasyAuth.objectId; appId = $EasyAuth.clientId }
          $args.Before = Get-MaesterApplicationConfigurationReceipt $Plan.details.inventory.easyAuthApplication
          $args.After = Get-MaesterApplicationConfigurationReceipt $ResolvedBody
          $ids = @{ applicationObjectId = $EasyAuth.objectId }
          $parent = Find-MaesterOwnedOperationId -Session $Session -Kind EntraApplication -IdField applicationObjectId -Id $EasyAuth.objectId
        }
      }
    }
    EasyAuthConsent {
      $args.Kind = 'OAuth2PermissionGrant'
      $graph = $Plan.details.inventory.easyAuthGrant
      $args.Expected = @{ clientId = $EasyAuth.principalId
        resourceId = $Plan.details.easyAuth.graphResourceId; consentType = 'AllPrincipals' }
      $args.After = @{ scopes = @([string]$ResolvedBody.scope -split '\s+' | Where-Object { $_ } | Sort-Object -Unique) }
      if ($Operation.method -eq 'PATCH') {
        $args.Ownership = 'Mutation'; $args.Before = @{ scopes = @([string]$graph.scope -split '\s+' | Where-Object { $_ } | Sort-Object -Unique) }
        $ids = @{ grantId = [string]$graph.id }
      }
      $parent = Find-MaesterOwnedOperationId -Session $Session -Kind EntraServicePrincipal -IdField servicePrincipalId -Id $EasyAuth.principalId
      if (-not $parent) { $parent = Find-MaesterOwnedOperationId -Session $Session -Kind EntraApplication -IdField applicationObjectId -Id $EasyAuth.objectId }
    }
    EasyAuthConfiguration {
      $args.Kind = 'WebAppAuthConfiguration'; $args.Ownership = 'Mutation'
      $webAppId = $ResolvedUri.Split('/config/authsettingsV2?')[0]
      $args.Expected = @{ webAppResourceId = $webAppId; appId = $EasyAuth.clientId }
      $args.Before = Get-MaesterWebAuthReceipt $Plan.details.inventory.easyAuthSettings
      $args.After = Get-MaesterWebAuthReceipt $ResolvedBody.properties
      $ids = @{ webAppResourceId = $webAppId }
    }
    default { throw "Unsupported ownership category '$($Operation.category)'." }
  }
  if ($parent -and $args.Ownership -eq 'Mutation') { $args.CoveredByOperationId = $parent }
  @{ Arguments = $args; KnownIds = $ids }
}

function Assert-MaesterSetupOperationResult {
  param($Ownership, $Operation, $Response, $ExactIds, $ResolvedBody, $ResolvedUri, $PlanParameters)
  # Exact IDs are already durable. Failed verification is a conflict and must
  # stop this approved sequence before another provider write or publication.
  $observed = $Response; $fields = @()
  switch ($Ownership.Kind) {
    GraphAppRoleAssignment { $fields = @('principalId', 'resourceId', 'appRoleId') }
    DirectoryRoleAssignment { $fields = @('principalId', 'roleDefinitionId', 'directoryScopeId') }
    AzureRoleAssignment {
      if ((Get-MaesterSetupProperty $Response 'id') -ine $ExactIds.roleAssignmentId) { throw 'Azure role assignment returned a different exact target.' }
      $observed = Get-MaesterSetupProperty $Response 'properties'
      $fields = @('principalId', 'roleDefinitionId', 'principalType')
      $scope = Get-MaesterSetupProperty $observed 'scope'
      if ($null -ne $scope -and $scope -ine $Ownership.Expected.scope) { throw 'Azure role assignment returned a different scope.' }
    }
    EntraServicePrincipal {
      if ((Get-MaesterSetupProperty $Response 'appId') -ine $Ownership.Expected.appId) { throw 'Easy Auth service principal creation returned the wrong application.' }
      $ownerTenant = Get-MaesterSetupProperty $Response 'appOwnerOrganizationId'
      if ($null -ne $ownerTenant -and $ownerTenant -ine $PlanParameters.TenantId) { throw 'Easy Auth service principal returned a different owner tenant.' }
    }
    ExchangeServicePrincipal {
      if ((Get-MaesterSetupProperty $Response 'ObjectId') -ine $Ownership.Expected.servicePrincipalId -or
          (Get-MaesterSetupProperty $Response 'AppId') -ine $Ownership.Expected.appId) { throw 'Exchange returned identity tuple does not match the approved service principal.' }
    }
    ExchangeRoleAssignment {
      $matches = @(Get-ManagementRoleAssignment -RoleAssignee $Ownership.Expected.servicePrincipalId -ErrorAction Stop |
        Where-Object { [string]$_.Identity -ceq $ExactIds.exchangeRoleAssignmentId -and [string]$_.Role -ceq $Ownership.Expected.roleName })
      if ($matches.Count -ne 1) { throw 'Exchange role readback does not match the exact approved principal and role.' }
    }
    OAuth2PermissionGrant {
      if ($Operation.method -ceq 'PATCH') { $observed = Invoke-GraphRestRequest -Method GET -Uri $ResolvedUri }
      if ((Get-MaesterSetupProperty $observed 'id') -cne $ExactIds.grantId) { throw 'Delegated grant readback returned a different exact target.' }
      $fields = @('clientId', 'resourceId', 'consentType')
      if ($null -ne (Get-MaesterSetupProperty $observed 'principalId')) { throw 'Tenant-wide delegated grant returned a user-scoped principal.' }
      $scopes = @(([string](Get-MaesterSetupProperty $observed 'scope' '')) -split '\s+' | Where-Object { $_ } | Sort-Object -Unique)
      if (($scopes -join ' ') -cne (@($Ownership.After.scopes | Sort-Object -Unique) -join ' ')) { throw 'Delegated grant readback does not match the approved scopes.' }
    }
    ApplicationConfiguration {
      $observed = Invoke-GraphRestRequest -Method GET -Uri $ResolvedUri
      if ((Get-MaesterSetupProperty $observed 'id') -ine $ExactIds.applicationObjectId -or
          (Get-MaesterSetupProperty $observed 'appId') -ine $Ownership.Expected.appId -or
          -not (Test-MaesterSetupDesiredState -Actual $observed -Desired $ResolvedBody)) { throw 'Application configuration readback does not match the approved exact target and values.' }
    }
    WebAppAuthConfiguration {
      $observed = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$ResolvedUri" -Headers $PlanParameters.ArmHeaders
      if (-not (Test-MaesterSetupDesiredState -Actual $observed -Desired $ResolvedBody)) { throw 'Web App authentication readback does not match the approved values.' }
    }
  }
  foreach ($field in $fields) {
    $value = Get-MaesterSetupProperty $observed $field
    if ($null -eq $value -or [string]$value -ine [string]$Ownership.Expected[$field]) { throw "Provider returned identity tuple differs from the approved $field." }
  }
}

function Invoke-MaesterSetupAccessPlan {
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$PlanParameters, [Parameter(Mandatory)][string]$ApprovedPlanHash, $OwnershipSession)
  # Read every selected authority again before the first write; stale reviews do
  # not authorize new roles, identities, applications, groups, or consent scopes.
  if (-not $OwnershipSession) { throw 'An open ownership journal session is required before setup access.' }
  Assert-MaesterOwnershipApplyReady -Session $OwnershipSession
  $plan = Get-MaesterSetupAccessPlan @PlanParameters
  if ($ApprovedPlanHash -cne $plan.planHash) { throw 'Setup access changed after review. Generate and approve the new plan before applying.' }
  Assert-MaesterConsentPlanApproval -Plan $plan -ApprovedPlanHash $ApprovedPlanHash
  $graphPlan = $plan.details.graphPlan
  $grantScript = Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1'
  $grantTarget = @{}; foreach ($key in $plan.details.grantTarget.Keys) { $grantTarget[$key] = $plan.details.grantTarget[$key] }
  $null = & $grantScript -TenantId $PlanParameters.TenantId -PrincipalObjectId $PlanParameters.PrincipalObjectId `
    -PermissionProfile $PlanParameters.PermissionProfile -IncludeMailSend $PlanParameters.IncludeMailSend `
    -IncludeReportSettingsWrite $PlanParameters.IncludeReportSettingsWrite -Apply -ApprovedPlanHash $graphPlan.planHash -OwnershipSession $OwnershipSession @grantTarget
  $receipts = @{ AZDO_BASE_ROLE_ASSIGNMENT_IDS = @(); EXO_APPROLE_ASSIGNMENT_IDS = @(); TEAMS_READER_ROLE_ASSIGNMENT_IDS = @(); AZURE_ROLE_ASSIGNMENT_IDS = @() }
  # Keep the reviewed, hashed plan immutable; resolved IDs are execution output.
  $easyAuth = if ($plan.details.easyAuth) { $plan.details.easyAuth | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable } else { $null }
  foreach ($plannedOperation in @($plan.details.operations)) {
    $operation = $plannedOperation | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json -AsHashtable
    $body = $operation.body | ConvertTo-Json -Depth 30 -Compress
    if ($easyAuth) {
      $body = $body.Replace('{easyAuthClientId}', [string]$easyAuth.clientId).Replace('{easyAuthPrincipalId}', [string]$easyAuth.principalId)
    }
    if ($body -match '\{easyAuth(Client|Principal)Id\}') { throw 'Easy Auth creation did not return the expected exact identifiers.' }
    $uri = $operation.uri.Replace('{assignmentId}', [guid]::NewGuid().ToString())
    $resolvedBody = $body | ConvertFrom-Json -AsHashtable
    $specification = Get-MaesterSetupOwnershipSpecification -Session $OwnershipSession -Plan $plan -Operation $operation -ResolvedBody $resolvedBody -ResolvedUri $uri -EasyAuth $easyAuth
    $ownershipArguments = $specification.Arguments
    $operationId = (Start-MaesterOwnedOperation @ownershipArguments).operationId
    $response = $null
    switch ($operation.method) {
      'New-ServicePrincipal' { $parameters = $operation.body; $response = New-ServicePrincipal @parameters -ErrorAction Stop }
      'New-ManagementRoleAssignment' { $parameters = $operation.body; $response = New-ManagementRoleAssignment @parameters -ErrorAction Stop }
      default {
        if ($operation.uri.StartsWith('https://graph.microsoft.com/')) {
          $response = Invoke-GraphRestRequest -Method $operation.method -Uri $operation.uri -Body $body -ContentType 'application/json'
        } else {
          $response = Invoke-RestMethod -Method $operation.method -Uri "https://management.azure.com$uri" -Headers $PlanParameters.ArmHeaders -Body $body -ContentType 'application/json'
        }
      }
    }
    $ids = $specification.KnownIds
    switch ($ownershipArguments.Kind) {
      { $_ -in @('GraphAppRoleAssignment', 'DirectoryRoleAssignment') } { $ids = @{ assignmentId = [string]$response.id } }
      EntraApplication { $ids = @{ applicationObjectId = [string]$response.id; appId = [string]$response.appId } }
      EntraServicePrincipal { $ids = @{ servicePrincipalId = [string]$response.id } }
      ExchangeServicePrincipal {
        $identity = Get-MaesterSetupProperty $response 'Identity' (Get-MaesterSetupProperty $response 'ObjectId' '')
        $ids = @{ exchangeServicePrincipalId = [string]$identity }
      }
      ExchangeRoleAssignment { $ids = @{ exchangeRoleAssignmentId = [string](Get-MaesterSetupProperty $response 'Identity' '') } }
      OAuth2PermissionGrant { if ($operation.method -eq 'POST') { $ids = @{ grantId = [string]$response.id } } }
    }
    # Persist each response before another provider operation, including before
    # interpreting output used by the following Easy Auth creation step.
    Complete-MaesterOwnedOperation -Session $OwnershipSession -OperationId $operationId -ExactIds $ids | Out-Null
    try {
      Assert-MaesterSetupOperationResult -Ownership $ownershipArguments -Operation $operation -Response $response -ExactIds $ids -ResolvedBody $resolvedBody -ResolvedUri $uri -PlanParameters $PlanParameters
      if ($ownershipArguments.Kind -eq 'EntraApplication') {
        Assert-MaesterApplicationCreationState -Application $response -Baseline $ownershipArguments.After -Partial
        $createdApp = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($response.id)?`$select=id,appId,signInAudience,identifierUris,groupMembershipClaims,web"
        if ($createdApp.id -ine $response.id -or $createdApp.appId -ine $response.appId) { throw 'Application creation readback returned a different exact identity.' }
        Assert-MaesterApplicationCreationState -Application $createdApp -Baseline $ownershipArguments.After
      }
    } catch {
      Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $operationId -State conflict | Out-Null
      throw
    }
    switch ($operation.receipt) {
      'EasyAuthApplication' {
        if (-not $response.id -or -not $response.appId) { throw 'Easy Auth application creation returned no identifiers.' }
        $easyAuth.objectId = [string]$response.id; $easyAuth.clientId = [string]$response.appId
      }
      'EasyAuthPrincipal' {
        if (-not $response.id -or $response.appId -ine $easyAuth.clientId) { Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $operationId -State conflict | Out-Null; throw 'Easy Auth service principal creation returned the wrong application.' }
        $easyAuth.principalId = [string]$response.id
      }
      { $_ -in $receipts.Keys } {
        if (-not $response.id) { throw 'Permission write returned no assignment receipt.' }
        $receipts[$operation.receipt] += [string]$response.id
      }
    }
  }
  Invoke-MaesterAdoAccessDelta -Delta $plan.details.adoAccess -Parameters $PlanParameters.AdoParameters -OwnershipSession $OwnershipSession -ApprovedPlanHash $plan.planHash
  [pscustomobject]@{ Plan = $plan; Receipts = $receipts; EasyAuth = $easyAuth; PrincipalDisplayName = $plan.details.inventory.principal.displayName }
}

Export-ModuleMember -Function Get-MaesterSetupAccessPlan, Invoke-MaesterSetupAccessPlan
