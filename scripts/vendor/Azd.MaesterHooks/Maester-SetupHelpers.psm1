# Shared setup helper functions for azd-maester solutions
# Imported by azd hook scripts and Setup-PostDeploy.ps1 in each solution.

# ── Utilities ────────────────────────────────────────────────────────────────

function Test-CanPrompt {
  try {
    $null = $Host.UI.RawUI
    return $true
  }
  catch {
    return $false
  }
}

function ConvertTo-BoolOrDefault {
  param(
    [Parameter(Mandatory = $false)]
    [string]$Value,
    [Parameter(Mandatory = $true)]
    [bool]$Default
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $Default
  }

  switch ($Value.Trim().ToLower()) {
    'true' { return $true }
    'false' { return $false }
    default { return $Default }
  }
}

function Test-ModuleAvailable {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModuleName,
    [Parameter(Mandatory = $false)]
    [string]$InstallMessage
  )

  $available = Get-Module -ListAvailable -Name $ModuleName | Select-Object -First 1
  if ($available) {
    Import-Module $ModuleName -Force
    return $true
  }

  if (-not (Test-CanPrompt)) {
    Write-Warning "$ModuleName is not installed and this is a non-interactive session."
    return $false
  }

  if ($InstallMessage) {
    Write-Host $InstallMessage
  }

  $installChoice = Read-Host "Install PowerShell module '$ModuleName' now? (Y/N)"
  if (-not $installChoice -or $installChoice.Trim().ToUpper() -ne 'Y') {
    return $false
  }

  Install-Module -Name $ModuleName -Scope CurrentUser -Force -AllowClobber
  Import-Module $ModuleName -Force
  return $true
}

function Resolve-StepFailureAction {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StepName,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  Write-Warning ("{0} failed: {1}" -f $StepName, $Message)

  $failureActionOverride = $env:MAESTER_STEP_FAILURE_ACTION
  if (-not [string]::IsNullOrWhiteSpace($failureActionOverride)) {
    switch ($failureActionOverride.Trim().ToLowerInvariant()) {
      'stop' {
        Write-Warning "MAESTER_STEP_FAILURE_ACTION=Stop. Failing setup on '$StepName'."
        return 'Stop'
      }
      'skip' {
        Write-Warning "MAESTER_STEP_FAILURE_ACTION=Skip. Skipping '$StepName'."
        return 'Skip'
      }
    }
  }

  if (-not (Test-CanPrompt)) {
    Write-Warning "Non-interactive session detected. Skipping $StepName and continuing."
    return 'Skip'
  }

  Write-Host "Choose how to proceed after failure in '$StepName':"
  Write-Host '  [S] Stop setup (recommended if you need the feature enabled)'
  Write-Host '  [K] Skip this step and continue'
  $choice = Read-Host 'Enter S or K (default: K)'
  if ($choice -and $choice.Trim().ToUpper() -eq 'S') {
    return 'Stop'
  }

  return 'Skip'
}

# ── azd env helpers ──────────────────────────────────────────────────────────

function Set-AzdEnvValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Value
  )

  try {
    & azd env set $Name $Value | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Failed to persist $Name to azd environment."
    }
  }
  catch {
    Write-Warning "Failed to persist $Name to azd environment. Error: $($_.Exception.Message)"
  }
}

function Set-AzdEnvJsonArray {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$Values = @()
  )

  $serialized = (@($Values) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ';'
  Set-AzdEnvValue -Name $Name -Value $serialized
}

# ── Authentication helpers ────────────────────────────────────────────────────

function Get-AzCliSubscriptionContext {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    [Parameter(Mandatory = $false)]
    [string]$TenantId
  )

  # Only ARM can attest the current subscription state; CLI account list/show
  # is a local login cache and can remain Enabled after a subscription is disabled.
  $subscriptionGuid = [guid]::Empty
  $tenantGuid = [guid]::Empty
  if (-not [guid]::TryParse($SubscriptionId, [ref]$subscriptionGuid) -or $subscriptionGuid -eq [guid]::Empty) {
    throw 'An explicit non-empty subscription GUID is required.'
  }
  if (-not [string]::IsNullOrWhiteSpace($TenantId) -and
      (-not [guid]::TryParse($TenantId, [ref]$tenantGuid) -or $tenantGuid -eq [guid]::Empty)) {
    throw 'The expected tenant must be a non-empty GUID.'
  }
  $SubscriptionId = $subscriptionGuid.ToString()
  $metadataJson = (& az rest --method get --url "https://management.azure.com/subscriptions/${SubscriptionId}?api-version=2022-12-01" --subscription $SubscriptionId --output json 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($metadataJson)) {
    throw "Unable to read current ARM metadata for subscription '$SubscriptionId'. Sign in with az login --tenant <tenant-id> using normal broker/browser authentication."
  }
  try {
    $metadata = $metadataJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  }
  catch {
    throw "Invalid ARM metadata for subscription '$SubscriptionId'."
  }
  $actualTenant = [guid]::Empty
  if ($metadata -isnot [System.Collections.IDictionary] -or
      [string]$metadata.subscriptionId -ine $SubscriptionId -or
      [string]$metadata.id -ine "/subscriptions/$SubscriptionId" -or
      -not [guid]::TryParse([string]$metadata.tenantId, [ref]$actualTenant) -or
      $actualTenant -eq [guid]::Empty -or
      [string]::IsNullOrWhiteSpace([string]$metadata.displayName)) {
    throw "Missing or invalid ARM subscription identity/tenant metadata for '$SubscriptionId'."
  }
  if ($tenantGuid -ne [guid]::Empty -and $actualTenant -ne $tenantGuid) {
    throw "Subscription '$SubscriptionId' belongs to tenant '$actualTenant', not selected tenant '$TenantId'."
  }
  if ([string]$metadata.state -cne 'Enabled') {
    throw "Subscription '$SubscriptionId' must currently be Enabled; ARM returned '$($metadata.state)'."
  }

  # Preserve the account-shaped fields consumed by hooks (ARM id is a resource path).
  return [pscustomobject]@{
    id = $SubscriptionId
    name = [string]$metadata.displayName
    tenantId = $actualTenant.ToString()
    state = [string]$metadata.state
  }
}

function Get-AzCliAccessToken {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Resource,
    [Parameter(Mandatory = $false)]
    [string]$TenantId,
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId
  )

  if ([string]::IsNullOrWhiteSpace($TenantId) -and [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    throw 'An explicit TenantId or SubscriptionId is required for Azure CLI token acquisition.'
  }
  $expectedTenant = [guid]::Empty
  if (-not [string]::IsNullOrWhiteSpace($TenantId) -and
      (-not [guid]::TryParse($TenantId, [ref]$expectedTenant) -or $expectedTenant -eq [guid]::Empty)) {
    throw 'An explicit non-empty tenant GUID is required for Azure CLI token acquisition.'
  }
  if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $context = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
    $SubscriptionId = $context.id
    $expectedTenant = [guid]$context.tenantId
  }

  try {
    $tokenArgs = @('account', 'get-access-token', '--resource', $Resource, '-o', 'json')
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
      $tokenArgs += @('--subscription', $SubscriptionId)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($TenantId)) {
      # Azure CLI accepts either --subscription or --tenant for this command,
      # but not both. A subscription is already tenant-bound and is the more
      # precise selector for deployment management tokens.
      $tokenArgs += @('--tenant', $TenantId)
    }

    $tokenJson = (& az @tokenArgs 2>$null)
    if ($LASTEXITCODE -eq 0 -and $tokenJson) {
      $tokenData = $tokenJson | ConvertFrom-Json
      if (-not [string]::IsNullOrWhiteSpace([string]$tokenData.accessToken) -and
          [string]$tokenData.tenant -ieq $expectedTenant.ToString() -and
          ([string]::IsNullOrWhiteSpace($SubscriptionId) -or [string]$tokenData.subscription -ieq $SubscriptionId)) {
        return $tokenData.accessToken
      }
    }
  }
  catch {
    Write-Verbose "az cli token acquisition failed for ${Resource}: $($_.Exception.Message)"
  }

  return $null
}

# The setup identity is never used by a hosted runner. Its complete delegated
# scope union is chosen before connection; no helper silently requests more access.
$script:MaesterGraphSession = $null

function Get-MaesterSetupScopes {
  [CmdletBinding()]
  param([switch]$IncludeTeams, [switch]$IncludeWebApp)

  $scopes = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'Directory.Read.All')
  if ($IncludeTeams) { $scopes += 'RoleManagement.ReadWrite.Directory' }
  if ($IncludeWebApp) {
    $scopes += @('Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Group.Read.All')
  }
  return @($scopes | Sort-Object -Unique)
}

function Import-MaesterGraphCoordinator {
  $vendorPath = Join-Path $PSScriptRoot '../Azd.GraphAuthentication/Azd.GraphAuthentication.psd1'
  $sourcePath = Join-Path $PSScriptRoot '../graph-delegated-authentication/Azd.GraphAuthentication.psd1'
  $modulePath = if (Test-Path -LiteralPath $vendorPath) { $vendorPath } else { $sourcePath }
  if (-not (Test-Path -LiteralPath $modulePath)) {
    throw 'Synchronize graph-delegated-authentication 1.1.0 alongside maester-azd-hooks before setup.'
  }
  Import-Module $modulePath -ErrorAction Stop
}

function Assert-GraphAccess {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [string[]]$Scopes = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'Directory.Read.All'),
    [string]$ClientId = $env:MAESTER_SETUP_CLIENT_ID,
    [string]$ExpectedAccount = $env:MAESTER_SETUP_ACCOUNT,
    [switch]$AllowInteractive,
    [switch]$AllowContextReplacement
  )

  $script:MaesterGraphSession = $null
  $tenantGuid = [guid]::Empty
  $clientGuid = [guid]::Empty
  if (-not [guid]::TryParse($TenantId, [ref]$tenantGuid) -or $tenantGuid -eq [guid]::Empty -or
      -not [guid]::TryParse($ClientId, [ref]$clientGuid) -or $clientGuid -eq [guid]::Empty -or
      $clientGuid -eq [guid]'14d82eec-204b-4c2f-b7e8-296a70dab67e' -or
      $ExpectedAccount -notmatch '^[^@\s]+@[^@\s]+$') {
    throw 'Provide the selected tenant, tenant-owned MAESTER_SETUP_CLIENT_ID and explicit MAESTER_SETUP_ACCOUNT UPN. Complete authorized administrator bootstrap first; the setup client cannot create or consent itself.'
  }
  Import-MaesterGraphCoordinator
  $requiredScopes = @(Resolve-AzdGraphScopeSet -Scope $Scopes)
  $connection = @{
    TenantId = $tenantGuid
    ExpectedClientId = $clientGuid
    ExpectedAccount = $ExpectedAccount
    Environment = 'Global'
    ContextScope = 'Process'
    Scopes = $requiredScopes
    ProbeUri = '/v1.0/organization?$select=id&$top=1'
    AllowInteractive = $AllowInteractive
    AllowContextReplacement = $AllowContextReplacement
  }
  $null = Connect-AzdGraphSession @connection

  # A custom client id alone is insufficient: reject an app owned by another
  # tenant or an application that is not configured as a single-tenant public client.
  $servicePrincipals = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/servicePrincipals?`$filter=appId eq '$clientGuid'&`$select=id,appId,appOwnerOrganizationId" -OutputType PSObject -ErrorAction Stop
  $applications = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/applications?`$filter=appId eq '$clientGuid'&`$select=id,appId,signInAudience,isFallbackPublicClient,publicClient" -OutputType PSObject -ErrorAction Stop
  if (@($servicePrincipals.value).Count -ne 1 -or @($applications.value).Count -ne 1 -or
      ($servicePrincipals.PSObject.Properties['@odata.nextLink'] -and $servicePrincipals.'@odata.nextLink') -or
      ($applications.PSObject.Properties['@odata.nextLink'] -and $applications.'@odata.nextLink') -or
      [string]$servicePrincipals.value[0].appId -ine $clientGuid.ToString() -or
      [string]$servicePrincipals.value[0].appOwnerOrganizationId -ine $tenantGuid.ToString() -or
      [string]$applications.value[0].appId -ine $clientGuid.ToString() -or
      [string]$applications.value[0].signInAudience -cne 'AzureADMyOrg' -or
      'http://localhost' -notin @($applications.value[0].publicClient.redirectUris)) {
    throw 'The selected setup client must be a tenant-owned, single-tenant public client with the localhost redirect URI. Ask an authorized administrator to complete bootstrap.'
  }
  $script:MaesterGraphSession = @{
    TenantId = $tenantGuid
    ExpectedClientId = $clientGuid
    ExpectedAccount = $ExpectedAccount
    Environment = 'Global'
    ContextScope = 'Process'
    Scopes = $requiredScopes
    ProbeUri = '/v1.0/organization?$select=id&$top=1'
  }
}

function Test-MaesterGraphSession {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$TenantId)
  return $null -ne $script:MaesterGraphSession -and $TenantId -ieq $script:MaesterGraphSession.TenantId.ToString()
}

function Get-MaesterGraphSetupClientId {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$TenantId)
  if (-not (Test-MaesterGraphSession -TenantId $TenantId)) {
    throw 'The selected tenant must have a verified setup session before identifying its setup client.'
  }
  return $script:MaesterGraphSession.ExpectedClientId.ToString()
}

function Invoke-GraphRestRequest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
    [Parameter(Mandatory)][string]$Uri,
    $Body,
    [string]$ContentType = 'application/json',
    [string]$TenantId
  )

  if ($null -eq $script:MaesterGraphSession) {
    throw 'Call Assert-GraphAccess once with the complete selected setup-scope union before Graph requests.'
  }
  if ($TenantId -and $TenantId -ine $script:MaesterGraphSession.TenantId.ToString()) {
    throw 'The request tenant differs from the verified setup session.'
  }
  $parsed = $null
  if (-not [uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed) -or
      $parsed.Scheme -cne 'https' -or $parsed.Host -ine 'graph.microsoft.com' -or
      $parsed.Port -ne 443 -or $parsed.UserInfo -or $parsed.Fragment -or
      $parsed.AbsolutePath -notmatch '^/(v1\.0|beta)/') {
    throw 'Graph requests must target an absolute HTTPS Microsoft Graph URI.'
  }
  # No reconnect or context replacement at a write boundary. A changed client,
  # account, tenant, cloud, context scope or scope set fails closed before the request.
  $null = Connect-AzdGraphSession @script:MaesterGraphSession
  $invokeParams = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
  if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
    $invokeParams.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 }
    $invokeParams.ContentType = $ContentType
  }
  return Invoke-MgGraphRequest @invokeParams
}

function Connect-MgGraphSilent {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [string[]]$Scopes = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'Directory.Read.All'),
    [string]$ClientId = $env:MAESTER_SETUP_CLIENT_ID,
    [string]$ExpectedAccount = $env:MAESTER_SETUP_ACCOUNT
  )
  Assert-GraphAccess -TenantId $TenantId -Scopes $Scopes -ClientId $ClientId -ExpectedAccount $ExpectedAccount
}

function Connect-ExchangeOnlineSilent {
  param(
    [Parameter(Mandatory = $false)]
    [string]$Organization,
    [Parameter(Mandatory = $false)]
    [string]$TenantId
  )

  # Do not infer the target from Organization or the ambient CLI/Exchange session.
  # Keeping this non-mandatory avoids an interactive parameter prompt on old callers.
  if ([string]::IsNullOrWhiteSpace($TenantId)) {
    throw 'TenantId is required for Exchange Online. Pass the validated selected tenant explicitly.'
  }
  $token = Get-AzCliAccessToken -Resource 'https://outlook.office365.com' -TenantId $TenantId
  if (-not $token) {
    throw "Exchange Online token acquisition failed for tenant '$TenantId'. Run az login --tenant $TenantId using normal broker/browser authentication, then retry."
  }
  $connectArgs = @{
    AccessToken = $token
    ShowBanner = $false
  }
  if (-not [string]::IsNullOrWhiteSpace($Organization)) {
    $connectArgs['Organization'] = $Organization
  }
  Connect-ExchangeOnline @connectArgs | Out-Null
}

function Confirm-AzureLogin {
  param([Parameter(Mandatory = $false)][string]$TenantId)

  $tenantGuid = [guid]::Empty
  if (-not [guid]::TryParse($TenantId, [ref]$tenantGuid) -or $tenantGuid -eq [guid]::Empty) {
    throw 'An explicit non-empty tenant GUID is required for Azure login.'
  }

  try {
    $tokenArgs = @('account', 'get-access-token', '--resource', 'https://graph.microsoft.com', '--output', 'none')
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
      $tokenArgs += @('--tenant', $TenantId)
    }
    $null = & az @tokenArgs 2>$null
    if ($LASTEXITCODE -eq 0) {
      return
    }
  }
  catch {
  }

  Write-Host 'No active Azure CLI login detected. Opening Azure login...'
  $loginArgs = @('login')
  if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
    $loginArgs += @('--tenant', $TenantId)
  }
  & az @loginArgs | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Azure login failed.'
  }
}

function Select-AzureRbacScopes {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DefaultSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceTypeName = 'managed identity'
  )

  if (-not (Test-CanPrompt)) {
    Write-Warning "-IncludeAzure was specified but interactive prompting is not available. Defaulting Azure RBAC scope to subscription '/subscriptions/$DefaultSubscriptionId'."
    return @("/subscriptions/$DefaultSubscriptionId")
  }

  $items = @()

  try {
    $mgJson = & az account management-group list -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $mgJson) {
      $mgs = $mgJson | ConvertFrom-Json
      foreach ($mg in @($mgs)) {
        $mgName = if ($mg.name) { $mg.name } elseif ($mg.id -and ($mg.id -split '/')[-1]) { ($mg.id -split '/')[-1] } else { $null }
        if (-not $mgName) { continue }
        $mgDisplayName = if ($mg.displayName) { $mg.displayName } else { $mgName }
        $items += [pscustomobject]@{
          Label = "MG  | $mgDisplayName ($mgName)"
          Scope = "/providers/Microsoft.Management/managementGroups/$mgName"
        }
      }
    }
  }
  catch {
  }

  $subsJson = az account list --query "[].{name:name,id:id,isDefault:isDefault}" -o json
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to enumerate subscriptions for Azure scope selection.'
  }

  $subs = $subsJson | ConvertFrom-Json
  foreach ($sub in @($subs)) {
    $items += [pscustomobject]@{
      Label = "SUB | $($sub.name) ($($sub.id))"
      Scope = "/subscriptions/$($sub.id)"
    }
  }

  if ($items.Count -eq 0) {
    Write-Warning "No management groups or subscriptions were discovered. Defaulting Azure RBAC scope to subscription '/subscriptions/$DefaultSubscriptionId'."
    return @("/subscriptions/$DefaultSubscriptionId")
  }

  Write-Host "Select one or more Azure RBAC scopes to grant the $ResourceTypeName Reader access."
  Write-Host 'Enter one or more numbers separated by commas. Press Enter to use the current subscription.'
  for ($index = 0; $index -lt $items.Count; $index++) {
    Write-Host ("[{0}] {1}" -f ($index + 1), $items[$index].Label)
  }

  $selection = Read-Host 'Selection'
  if ([string]::IsNullOrWhiteSpace($selection)) {
    return @("/subscriptions/$DefaultSubscriptionId")
  }

  $selectedScopes = @()
  $parts = @($selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  foreach ($part in $parts) {
    $value = 0
    if (-not [int]::TryParse($part, [ref]$value)) {
      throw "Invalid selection '$part'. Expected a number or comma-separated numbers."
    }

    $selectedIndex = $value - 1
    if ($selectedIndex -lt 0 -or $selectedIndex -ge $items.Count) {
      throw "Selection '$value' is out of range."
    }

    $selectedScopes += $items[$selectedIndex].Scope
  }

  return @($selectedScopes | Sort-Object -Unique)
}

# ── Graph / Azure RBAC assignment helpers ────────────────────────────────────

function Grant-ServicePrincipalAppRoleAssignment {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PrincipalObjectId,
    [Parameter(Mandatory = $true)]
    [string]$ResourceAppId,
    [Parameter(Mandatory = $true)]
    [Guid]$AppRoleId
  )

  $spResponse = Invoke-GraphRestRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '{0}'&`$select=id" -f $ResourceAppId)
  if (-not $spResponse.value -or $spResponse.value.Count -eq 0) {
    throw "Service principal for resource appId '$ResourceAppId' was not found in this tenant."
  }

  $resourceSpId = $spResponse.value[0].id
  $existing = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/appRoleAssignments"
  $match = @($existing.value | Where-Object { $_.resourceId -eq $resourceSpId -and $_.appRoleId -eq $AppRoleId }) | Select-Object -First 1
  if ($match) {
    return $null
  }

  $body = @{
    principalId = $PrincipalObjectId
    resourceId  = $resourceSpId
    appRoleId   = $AppRoleId
  } | ConvertTo-Json

  $created = Invoke-GraphRestRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/appRoleAssignments" -Body $body -ContentType 'application/json'
  if ($created -and $created.id) {
    return $created.id
  }

  return $null
}

function Get-DirectoryRoleDefinitionId {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RoleDisplayName
  )

  $escaped = $RoleDisplayName.Replace("'", "''")
  $defs = Invoke-GraphRestRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=displayName eq '{0}'&`$select=id,displayName" -f $escaped)
  if (-not $defs.value -or $defs.value.Count -eq 0) {
    throw "Directory role definition '$RoleDisplayName' was not found."
  }

  return $defs.value[0].id
}

function Get-DirectoryRoleAssignmentId {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PrincipalObjectId,
    [Parameter(Mandatory = $true)]
    [string]$RoleDefinitionId
  )

  $existing = Invoke-GraphRestRequest -Method GET -Uri (
    "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '{0}' and roleDefinitionId eq '{1}' and directoryScopeId eq '/'&`$select=id" -f $PrincipalObjectId, $RoleDefinitionId
  )

  if ($existing.value -and $existing.value.Count -gt 0) {
    return $existing.value[0].id
  }

  return $null
}

function Test-DirectoryRoleAssignment {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PrincipalObjectId,
    [Parameter(Mandatory = $true)]
    [string]$RoleDisplayName
  )

  $roleDefinitionId = Get-DirectoryRoleDefinitionId -RoleDisplayName $RoleDisplayName

  $existingId = Get-DirectoryRoleAssignmentId -PrincipalObjectId $PrincipalObjectId -RoleDefinitionId $roleDefinitionId
  if ($existingId) {
    return $null
  }

  $body = @{
    principalId      = $PrincipalObjectId
    roleDefinitionId = $roleDefinitionId
    directoryScopeId = '/'
  } | ConvertTo-Json

  $created = Invoke-GraphRestRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' -Body $body -ContentType 'application/json'
  if ($created -and $created.id) {
    return $created.id
  }

  return $null
}

function Test-AzureReaderRoleAssignment {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Scope,
    [Parameter(Mandatory = $true)]
    [string]$PrincipalObjectId,
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId
  )

  $readerRoleGuid = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  $roleDefinitionId = if ($Scope -like '/providers/Microsoft.Management/managementGroups/*') {
    "/providers/Microsoft.Authorization/roleDefinitions/$readerRoleGuid"
  }
  else {
    "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$readerRoleGuid"
  }

  $armToken = az account get-access-token --subscription $SubscriptionId --resource https://management.azure.com/ --query accessToken -o tsv
  $armHeaders = @{ Authorization = "Bearer $armToken" }

  # Pre-check: look for an existing Reader assignment for this principal at this scope
  $existingPath = "$Scope/providers/Microsoft.Authorization/roleAssignments?`$filter=principalId eq '$PrincipalObjectId' and atScope()&api-version=2022-04-01"
  try {
    $existingPayload = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$existingPath" -Headers $armHeaders
    $existingMatch = @($existingPayload.value | Where-Object {
        $_.properties.roleDefinitionId -like "*$readerRoleGuid"
      }) | Select-Object -First 1
    if ($existingMatch) {
      return $null
    }
  }
  catch {
    # Pre-check failed, proceed to try the PUT anyway
  }

  $assignmentName = [guid]::NewGuid().ToString()
  $path = "$Scope/providers/Microsoft.Authorization/roleAssignments/${assignmentName}?api-version=2022-04-01"
  $body = @{
    properties = @{
      roleDefinitionId = $roleDefinitionId
      principalId      = $PrincipalObjectId
      principalType    = 'ServicePrincipal'
    }
  } | ConvertTo-Json -Depth 10 -Compress

  try {
    $response = Invoke-RestMethod -Method PUT -Uri "https://management.azure.com$path" -Headers $armHeaders -Body $body -ContentType 'application/json' -SkipHttpErrorCheck -StatusCodeVariable putStatus
    if ($putStatus -in @(200, 201)) {
      if ($response -and $response.id) {
        return $response.id
      }
      return $null
    }
    # 409 Conflict means the assignment already exists (race condition with pre-check)
    if ($putStatus -eq 409) {
      return $null
    }
    # Any other non-success status is a real error
    throw "Azure RBAC Reader assignment failed at scope '$Scope'. HTTP $putStatus"
  }
  catch {
    if ($_.Exception.Message -match 'RoleAssignmentExists|Conflict' -or ($putStatus -and $putStatus -eq 409)) {
      return $null
    }
    throw "Azure RBAC Reader assignment failed at scope '$Scope': $($_.Exception.Message)"
  }
}
