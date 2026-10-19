BeforeAll {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  $script:helperPath = Join-Path $repoRoot 'scripts/vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1'
  Import-Module (Join-Path $repoRoot 'scripts/vendor/Azd.GraphAuthentication/Azd.GraphAuthentication.psd1') -Force
  $script:sdkCommandBefore = Get-Command Invoke-MgGraphRequest
  Import-Module $script:helperPath -Force
}

AfterAll {
  Remove-Module Maester-SetupHelpers, Azd.GraphAuthentication -Force -ErrorAction SilentlyContinue
  Remove-Variable MaesterSetupSessionTestState -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Canonical Maester setup Graph session boundary' {
  BeforeEach {
    $global:MaesterSetupSessionTestState = @{
      Tenant = '11111111-1111-4111-8111-111111111111'
      Client = '22222222-2222-4222-8222-222222222222'
      Account = 'admin@example.com'
      Requests = [Collections.Generic.List[object]]::new()
      Connections = [Collections.Generic.List[object]]::new()
      ProbeFailure = $null
    }
    $state = $global:MaesterSetupSessionTestState
    $state.ExpectedContext = [pscustomobject]@{
      TenantId = $state.Tenant
      ClientId = $state.Client
      Environment = 'Global'
      Account = $state.Account
      AuthType = 'Delegated'
      ContextScope = 'Process'
      Scopes = @(Get-MaesterSetupScopes -IncludeTeams -IncludeWebApp)
    }
    $state.Context = $state.ExpectedContext.PSObject.Copy()
    $state.ServicePrincipal = [pscustomobject]@{
      value = @([pscustomobject]@{
        id = '33333333-3333-4333-8333-333333333333'
        appId = $state.Client
        appOwnerOrganizationId = $state.Tenant
      })
    }
    $state.Application = [pscustomobject]@{
      value = @([pscustomobject]@{
        id = '44444444-4444-4444-8444-444444444444'
        appId = $state.Client
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $true
        publicClient = [pscustomobject]@{ redirectUris = @('http://localhost') }
      })
    }
    $script:connectionParameters = @{
      TenantId = $state.Tenant
      ClientId = $state.Client
      ExpectedAccount = $state.Account
      Scopes = @(Get-MaesterSetupScopes -IncludeTeams -IncludeWebApp)
    }
    InModuleScope Maester-SetupHelpers { $script:MaesterGraphSession = $null }

    Mock Get-MgEnvironment -ModuleName Azd.GraphAuthentication { [pscustomobject]@{ Name = 'Global' } }
    Mock Get-MgContext -ModuleName Azd.GraphAuthentication { $global:MaesterSetupSessionTestState.Context }
    Mock Connect-MgGraph -ModuleName Azd.GraphAuthentication {
      param($TenantId, $ClientId, $Environment, $Scopes, $ContextScope, $ClientTimeout, $NoWelcome, $UseDeviceAuthentication, $AccessToken)
      $global:MaesterSetupSessionTestState.Connections.Add([pscustomobject]@{
        TenantId = $TenantId; ClientId = $ClientId; Environment = $Environment
        Scopes = @($Scopes); ContextScope = $ContextScope; ClientTimeout = $ClientTimeout
        NoWelcome = $NoWelcome; UseDeviceAuthentication = $UseDeviceAuthentication; AccessToken = $AccessToken
      })
      $global:MaesterSetupSessionTestState.Context = $global:MaesterSetupSessionTestState.ExpectedContext.PSObject.Copy()
    }
    Mock Invoke-MgGraphRequest -ModuleName Azd.GraphAuthentication {
      param($Method, $Uri)
      $global:MaesterSetupSessionTestState.Requests.Add([pscustomobject]@{ Source = 'Coordinator'; Method = $Method; Uri = $Uri })
      if ($global:MaesterSetupSessionTestState.ProbeFailure) { throw $global:MaesterSetupSessionTestState.ProbeFailure }
      [pscustomobject]@{ value = @([pscustomobject]@{ id = $global:MaesterSetupSessionTestState.Tenant }) }
    }
    Mock Invoke-MgGraphRequest -ModuleName Maester-SetupHelpers {
      param($Method, $Uri, $Body, $ContentType, $OutputType)
      $global:MaesterSetupSessionTestState.Requests.Add([pscustomobject]@{
        Source = 'Helper'; Method = $Method; Uri = $Uri; Body = $Body; ContentType = $ContentType; OutputType = $OutputType
      })
      if ($Uri -like '/v1.0/servicePrincipals?*') { return $global:MaesterSetupSessionTestState.ServicePrincipal }
      if ($Uri -like '/v1.0/applications?*') { return $global:MaesterSetupSessionTestState.Application }
      [pscustomobject]@{ id = 'mock-response' }
    }
    Mock Get-AzCliAccessToken -ModuleName Maester-SetupHelpers { throw 'Graph setup must never acquire an Azure CLI token.' }
    Mock Invoke-RestMethod -ModuleName Maester-SetupHelpers { throw 'Graph setup must use the verified SDK session.' }
    Mock Read-Host -ModuleName Maester-SetupHelpers { throw 'Graph setup must never silently prompt.' }
  }

  AfterEach {
    Should -Invoke Get-AzCliAccessToken -ModuleName Maester-SetupHelpers -Times 0 -Exactly
    Should -Invoke Invoke-RestMethod -ModuleName Maester-SetupHelpers -Times 0 -Exactly
    Should -Invoke Read-Host -ModuleName Maester-SetupHelpers -Times 0 -Exactly
  }

  It 'selects the complete exact scope union for <selection>' -ForEach @(
    @{ selection = 'base'; teams = $false; web = $false; extra = @() }
    @{ selection = 'Teams'; teams = $true; web = $false; extra = @('RoleManagement.ReadWrite.Directory') }
    @{ selection = 'Web App'; teams = $false; web = $true; extra = @('Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Group.Read.All') }
    @{ selection = 'Teams and Web App'; teams = $true; web = $true; extra = @('RoleManagement.ReadWrite.Directory', 'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Group.Read.All') }
  ) {
    $expected = @(@('Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'Directory.Read.All') + $extra | Sort-Object -Unique)
    @(Get-MaesterSetupScopes -IncludeTeams:$teams -IncludeWebApp:$web) | Should -Be $expected
  }

  It 'reuses the exact Process delegated SDK session and verifies the tenant-owned public setup app' {
    Assert-GraphAccess @connectionParameters

    Test-MaesterGraphSession -TenantId $global:MaesterSetupSessionTestState.Tenant | Should -BeTrue
    Test-MaesterGraphSession -TenantId '55555555-5555-4555-8555-555555555555' | Should -BeFalse
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    Should -Invoke Invoke-MgGraphRequest -ModuleName Azd.GraphAuthentication -Times 1 -Exactly -ParameterFilter {
      $Method -eq 'GET' -and $Uri -eq '/v1.0/organization?$select=id&$top=1'
    }
    @($global:MaesterSetupSessionTestState.Requests | Where-Object Source -eq 'Helper').Count | Should -Be 2
    @($global:MaesterSetupSessionTestState.Requests | Where-Object Method -ne 'GET').Count | Should -Be 0
  }

  It 'returns only the captured setup client for the matching verified tenant' {
    { Get-MaesterGraphSetupClientId -TenantId $connectionParameters.TenantId } | Should -Throw '*verified setup session*'
    Assert-GraphAccess @connectionParameters
    $originalClient = $env:MAESTER_SETUP_CLIENT_ID
    try {
      $env:MAESTER_SETUP_CLIENT_ID = '99999999-9999-4999-8999-999999999999'
      Get-MaesterGraphSetupClientId -TenantId $connectionParameters.TenantId | Should -BeExactly $connectionParameters.ClientId
      { Get-MaesterGraphSetupClientId -TenantId '55555555-5555-4555-8555-555555555555' } | Should -Throw '*verified setup session*'
    } finally { $env:MAESTER_SETUP_CLIENT_ID = $originalClient }
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
  }

  It 'retains the global SDK command without installing an impersonating global helper' {
    $after = Get-Command Invoke-MgGraphRequest
    $after.ModuleName | Should -BeExactly $sdkCommandBefore.ModuleName
    $after.CommandType | Should -Be $sdkCommandBefore.CommandType
    $after.Definition | Should -BeExactly $sdkCommandBefore.Definition
    Assert-GraphAccess @connectionParameters
    (Get-Command Invoke-MgGraphRequest).Definition | Should -BeExactly $sdkCommandBefore.Definition
  }

  It 'passes tenant, client, account and the complete union to one explicitly authorized SDK connection' {
    $global:MaesterSetupSessionTestState.Context = $null
    Assert-GraphAccess @connectionParameters -AllowInteractive
    $connection = @($global:MaesterSetupSessionTestState.Connections)[0]

    $global:MaesterSetupSessionTestState.Connections.Count | Should -Be 1
    $connection.TenantId | Should -BeExactly $connectionParameters.TenantId
    $connection.ClientId | Should -BeExactly $connectionParameters.ClientId
    $connection.Environment | Should -BeExactly 'Global'
    $connection.ContextScope | Should -BeExactly 'Process'
    $connection.Scopes | Should -Be $connectionParameters.Scopes
    $connection.UseDeviceAuthentication | Should -BeNullOrEmpty
    $connection.AccessToken | Should -BeNullOrEmpty
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeTrue
  }

  It 'rejects an otherwise matching CurrentUser setup context with <authorization>' -ForEach @(
    @{ authorization = 'neither authorization'; interactive = $false; replacement = $false }
    @{ authorization = 'interactive authorization only'; interactive = $true; replacement = $false }
    @{ authorization = 'replacement authorization only'; interactive = $false; replacement = $true }
    @{ authorization = 'both authorizations'; interactive = $true; replacement = $true }
  ) {
    $global:MaesterSetupSessionTestState.Context.ContextScope = 'CurrentUser'
    { Assert-GraphAccess @connectionParameters -AllowInteractive:$interactive -AllowContextReplacement:$replacement } |
      Should -Throw '*cannot replace an inherited non-Process context*fresh pwsh -NoProfile*'
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeFalse
  }

  It 'replaces a mismatched Process context only when explicitly authorized and never carries replacement authority into later writes' {
    $global:MaesterSetupSessionTestState.Context.ClientId = '55555555-5555-4555-8555-555555555555'
    Assert-GraphAccess @connectionParameters -AllowInteractive -AllowContextReplacement

    $global:MaesterSetupSessionTestState.Connections.Count | Should -Be 1
    $global:MaesterSetupSessionTestState.Connections[0].ContextScope | Should -BeExactly 'Process'
    Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' | Out-Null
    $global:MaesterSetupSessionTestState.Requests.Clear()
    $global:MaesterSetupSessionTestState.Context.ContextScope = 'CurrentUser'

    { Invoke-GraphRestRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body @{} } |
      Should -Throw '*cannot replace an inherited non-Process context*fresh pwsh -NoProfile*'
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 1 -Exactly -ParameterFilter { $ContextScope -ceq 'Process' }
  }

  It 'accepts a localhost public-client redirect without enabling fallback public-client flows' {
    $global:MaesterSetupSessionTestState.Application.value[0].isFallbackPublicClient = $false
    { Assert-GraphAccess @connectionParameters } | Should -Not -Throw
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeTrue
  }

  It 'rejects invalid <field> configuration before any SDK or CLI operation' -ForEach @(
    @{ field = 'TenantId'; value = '' }
    @{ field = 'TenantId'; value = 'not-a-guid' }
    @{ field = 'TenantId'; value = '00000000-0000-0000-0000-000000000000' }
    @{ field = 'ClientId'; value = '' }
    @{ field = 'ClientId'; value = 'not-a-guid' }
    @{ field = 'ClientId'; value = '00000000-0000-0000-0000-000000000000' }
    @{ field = 'ClientId'; value = '14d82eec-204b-4c2f-b7e8-296a70dab67e' }
    @{ field = 'ExpectedAccount'; value = '' }
    @{ field = 'ExpectedAccount'; value = 'admin' }
  ) {
    $connectionParameters[$field] = $value
    { Assert-GraphAccess @connectionParameters -AllowInteractive -AllowContextReplacement } | Should -Throw
    Should -Invoke Get-MgContext -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
  }

  It 'rejects inherited context drift in <field> without fallback authentication or consent' -ForEach @(
    @{ field = 'ClientId'; value = '55555555-5555-4555-8555-555555555555' }
    @{ field = 'ClientId'; value = '14d82eec-204b-4c2f-b7e8-296a70dab67e' }
    @{ field = 'ClientId'; value = '' }
    @{ field = 'TenantId'; value = '55555555-5555-4555-8555-555555555555' }
    @{ field = 'Account'; value = 'other@example.com' }
    @{ field = 'Environment'; value = 'USGov' }
    @{ field = 'Scopes'; value = @('Directory.Read.All') }
    @{ field = 'AuthType'; value = 'AppOnly' }
  ) {
    $global:MaesterSetupSessionTestState.Context.$field = $value
    { Assert-GraphAccess @connectionParameters -AllowInteractive } | Should -Throw '*cannot be replaced without explicit authorization*'
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeFalse
  }

  It 'rejects a missing SDK ClientId instead of inferring it from tenant and account' {
    $global:MaesterSetupSessionTestState.Context.PSObject.Properties.Remove('ClientId')
    { Assert-GraphAccess @connectionParameters -AllowInteractive } | Should -Throw '*context client ID is unavailable or invalid*'
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
  }

  It 'rejects a missing session noninteractively instead of falling back to another authentication method' {
    $global:MaesterSetupSessionTestState.Context = $null
    { Connect-MgGraphSilent @connectionParameters } | Should -Throw '*required for noninteractive execution*'
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
  }

  It 'does not request another authentication flow when the authorized SDK connection fails' {
    $global:MaesterSetupSessionTestState.Context = $null
    Mock Connect-MgGraph -ModuleName Azd.GraphAuthentication { throw 'Synthetic broker cancellation.' }
    { Assert-GraphAccess @connectionParameters -AllowInteractive } | Should -Throw '*The coordinator did not request an alternate authentication flow*'
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 1 -Exactly
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeFalse
  }

  It 'supports the real helper from a strict-mode caller with ordinary unpaged Graph responses' {
    & {
      Set-StrictMode -Version Latest
      Assert-GraphAccess @connectionParameters
    }
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeTrue
  }

  It 'fails closed for invalid tenant-owned setup-app metadata: <case>' -ForEach @(
    @{ case = 'foreign app owner'; target = 'ServicePrincipal'; field = 'appOwnerOrganizationId'; value = '55555555-5555-4555-8555-555555555555' }
    @{ case = 'missing app owner'; target = 'ServicePrincipal'; field = 'appOwnerOrganizationId'; value = $null }
    @{ case = 'wrong service-principal client'; target = 'ServicePrincipal'; field = 'appId'; value = '55555555-5555-4555-8555-555555555555' }
    @{ case = 'wrong application client'; target = 'Application'; field = 'appId'; value = '55555555-5555-4555-8555-555555555555' }
    @{ case = 'multitenant application'; target = 'Application'; field = 'signInAudience'; value = 'AzureADMultipleOrgs' }
    @{ case = 'missing audience'; target = 'Application'; field = 'signInAudience'; value = $null }
    @{ case = 'missing public-client configuration'; target = 'Application'; field = 'publicClient'; value = $null }
    @{ case = 'unapproved redirect'; target = 'Application'; field = 'publicClient'; value = [pscustomobject]@{ redirectUris = @('https://attacker.example/') } }
  ) {
    $global:MaesterSetupSessionTestState[$target].value[0].$field = $value
    { Assert-GraphAccess @connectionParameters } | Should -Throw '*tenant-owned, single-tenant public client*'
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeFalse
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    @($global:MaesterSetupSessionTestState.Requests | Where-Object Method -ne 'GET').Count | Should -Be 0
  }

  It 'rejects ambiguous, incomplete or paged <target> bootstrap metadata: <case>' -ForEach @(
    @{ target = 'ServicePrincipal'; case = 'empty'; count = 0; paged = $false }
    @{ target = 'ServicePrincipal'; case = 'duplicate'; count = 2; paged = $false }
    @{ target = 'ServicePrincipal'; case = 'paged'; count = 1; paged = $true }
    @{ target = 'Application'; case = 'empty'; count = 0; paged = $false }
    @{ target = 'Application'; case = 'duplicate'; count = 2; paged = $false }
    @{ target = 'Application'; case = 'paged'; count = 1; paged = $true }
  ) {
    $response = $global:MaesterSetupSessionTestState[$target]
    $response.value = @($response.value * $count)
    if ($paged) { $response | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue 'https://graph.microsoft.com/v1.0/applications?$skiptoken=next' }
    { Assert-GraphAccess @connectionParameters } | Should -Throw '*tenant-owned, single-tenant public client*'
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeFalse
  }

  It 'clears the previous verified session when reinitialization fails' {
    Assert-GraphAccess @connectionParameters
    $global:MaesterSetupSessionTestState.Application.value[0].signInAudience = 'AzureADMultipleOrgs'
    { Assert-GraphAccess @connectionParameters } | Should -Throw
    Test-MaesterGraphSession -TenantId $connectionParameters.TenantId | Should -BeFalse
    { Invoke-GraphRestRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body @{} } | Should -Throw '*Assert-GraphAccess*'
    @($global:MaesterSetupSessionTestState.Requests | Where-Object Method -ne 'GET').Count | Should -Be 0
  }

  It 'requires an initialized verified session before any Graph operation' {
    { Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' } | Should -Throw '*Assert-GraphAccess*'
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
  }

  It 'revalidates the real coordinator before each SDK operation and preserves body forwarding' {
    Assert-GraphAccess @connectionParameters
    $global:MaesterSetupSessionTestState.Requests.Clear()
    Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' -TenantId $connectionParameters.TenantId | Out-Null
    Invoke-GraphRestRequest -Method POST -Uri 'https://graph.microsoft.com/beta/servicePrincipals' -Body @{ displayName = 'test-only' } | Out-Null
    Invoke-GraphRestRequest -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals/mock' -Body '{"displayName":"changed"}' -ContentType 'application/json' | Out-Null

    $requests = @($global:MaesterSetupSessionTestState.Requests)
    ($requests.Source -join ',') | Should -BeExactly 'Coordinator,Helper,Coordinator,Helper,Coordinator,Helper'
    ($requests[3].Body | ConvertFrom-Json).displayName | Should -BeExactly 'test-only'
    $requests[5].Body | Should -BeExactly '{"displayName":"changed"}'
    $requests[5].ContentType | Should -BeExactly 'application/json'
    $requests[5].OutputType | Should -BeExactly 'PSObject'
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
  }

  It 'rejects unsafe Graph URI <uri> before revalidation or transport' -ForEach @(
    @{ uri = 'http://graph.microsoft.com/v1.0/organization' }
    @{ uri = 'https://graph.microsoft.com:444/v1.0/organization' }
    @{ uri = 'https://graph.microsoft.com.attacker.example/v1.0/organization' }
    @{ uri = 'https://user@graph.microsoft.com/v1.0/organization' }
    @{ uri = 'https://graph.microsoft.com/v1.0/organization#fragment' }
    @{ uri = '/v1.0/organization' }
    @{ uri = 'https://graph.microsoft.com/other/organization' }
    @{ uri = 'https://graph.microsoft.com/v1.0/../organization' }
    @{ uri = 'https://management.azure.com/v1.0/organization' }
  ) {
    Assert-GraphAccess @connectionParameters
    $global:MaesterSetupSessionTestState.Requests.Clear()
    { Invoke-GraphRestRequest -Method POST -Uri $uri -Body @{} } | Should -Throw '*absolute HTTPS Microsoft Graph URI*'
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
  }

  It 'rejects a request with a different tenant before transport' {
    Assert-GraphAccess @connectionParameters
    $global:MaesterSetupSessionTestState.Requests.Clear()
    { Invoke-GraphRestRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -TenantId '55555555-5555-4555-8555-555555555555' -Body @{} } | Should -Throw '*request tenant differs*'
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
  }

  It 'refuses a write after <field> drifts and never reauthenticates or self-grants at the write boundary' -ForEach @(
    @{ field = 'ClientId'; value = '55555555-5555-4555-8555-555555555555' }
    @{ field = 'TenantId'; value = '55555555-5555-4555-8555-555555555555' }
    @{ field = 'Account'; value = 'other@example.com' }
    @{ field = 'Environment'; value = 'USGov' }
    @{ field = 'ContextScope'; value = 'CurrentUser' }
    @{ field = 'Scopes'; value = @('Directory.Read.All') }
    @{ field = 'AuthType'; value = 'AppOnly' }
  ) {
    Assert-GraphAccess @connectionParameters
    $global:MaesterSetupSessionTestState.Requests.Clear()
    $global:MaesterSetupSessionTestState.Context.$field = $value
    $expectedError = if ($field -eq 'ContextScope') { '*cannot replace an inherited non-Process context*fresh pwsh -NoProfile*' } else { '*cannot be replaced without explicit authorization*' }
    { Invoke-GraphRestRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body @{} } | Should -Throw $expectedError
    $global:MaesterSetupSessionTestState.Requests.Count | Should -Be 0
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
  }

  It 'does not reconnect or write after the existing session probe fails authentication' {
    Assert-GraphAccess @connectionParameters
    $global:MaesterSetupSessionTestState.Requests.Clear()
    $failure = [Exception]::new('Synthetic expired session.')
    $failure | Add-Member -NotePropertyName StatusCode -NotePropertyValue 401
    $global:MaesterSetupSessionTestState.ProbeFailure = $failure
    { Invoke-GraphRestRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body @{} } | Should -Throw '*not usable in this process*'
    @($global:MaesterSetupSessionTestState.Requests | Where-Object Source -eq 'Helper').Count | Should -Be 0
    Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
  }
}
