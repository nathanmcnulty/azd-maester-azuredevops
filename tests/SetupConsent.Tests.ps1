BeforeAll {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  # Use the production planner, with all remote authorities replaced by fixtures.
  Import-Module (Join-Path $repoRoot 'scripts/vendor/Azd.MaesterHooks/Maester-ConsentPlan.psm1') -Force
  Import-Module (Join-Path $repoRoot 'scripts/Maester-SetupConsent.psm1') -Force
}

Describe 'Reviewed deployment setup access (offline)' {
  BeforeAll {
    InModuleScope Maester-SetupConsent {
      function script:Invoke-GraphRestRequest { }
      function script:Get-MaesterAdoIdentity { }
      function script:Get-MaesterAdoAccessDelta { }
      function script:Get-MaesterAdoPipelineInventory { }
      function script:Invoke-MaesterAdoAccessDelta { }
      function script:Get-ServicePrincipal { }
      function script:Get-ManagementRoleAssignment { }
      function script:New-ServicePrincipal { }
      function script:New-ManagementRoleAssignment { }
    }
  }
  BeforeEach {
    $script:savedAccount = $env:MAESTER_SETUP_ACCOUNT
    $script:savedClient = $env:MAESTER_SETUP_CLIENT_ID
    $env:MAESTER_SETUP_ACCOUNT = 'operator@example.test'
    $env:MAESTER_SETUP_CLIENT_ID = '99999999-9999-4999-8999-999999999999'
    InModuleScope Maester-SetupConsent {
      $script:testState = @{
        tenant = '11111111-1111-4111-8111-111111111111'
        principal = '22222222-2222-4222-8222-222222222222'
        user = '33333333-3333-4333-8333-333333333333'
        app = '44444444-4444-4444-8444-444444444444'
        operations = [Collections.Generic.List[object]]::new()
        storageAssignments = @(); teamsAssignments = @(); graphCalls = 0
        groups = @(); malformed = $false; paginated = $false
        easyApps = @(); easyPrincipals = @(); easyGrants = @(); auth = [pscustomobject]@{ properties = @{} }
        exchangePrincipals = @(); exchangeRoles = @()
      }
      $script:parameters = @{
        TenantId = $script:testState.tenant; SubscriptionId = $script:testState.tenant
        PrincipalObjectId = $script:testState.principal
        ResourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.App/jobs/job-test'
        StorageAccount = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/storage'; name = 'storage' }
        ArmHeaders = @{ Authorization = 'offline-only' }; PermissionProfile = 'Full'; AdoParameters = @{}
        IncludeMailSend = $false; IncludeReportSettingsWrite = $false
      }
      Mock Get-MaesterAdoIdentity {
        [pscustomobject]@{ principalId = $script:testState.principal; principal = [pscustomobject]@{ id = $script:testState.principal; appId = $script:testState.app; displayName = 'runtime-app'; servicePrincipalType = 'Application' }; inventory = @{ endpoint = 'verified' }; grantTarget = @{ TargetType = 'FederatedApplication'; ExpectedApplicationId = $script:testState.app; ExpectedApplicationObjectId = $script:testState.app; ExpectedFederatedCredentialIssuer = 'https://vstoken.dev.azure.com/organization'; ExpectedFederatedCredentialSubject = 'sc://org/project/connection' } }
      }
      Mock Get-MaesterAdoPipelineInventory { @{ pipeline = $null; branchObjectId = '' } }
      Mock Get-MaesterAdoAccessDelta { @{ inventory = @{}; operations = @() } }
      Mock Invoke-MaesterAdoAccessDelta { }
      # Scope fake script resolution to the planner and its apply path.
      Mock Join-Path {
        $global:setupGrantFixture
      } -ParameterFilter { $ChildPath -eq 'vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1' }
      Mock Invoke-GraphRestRequest {
        param($Method, $Uri, $Body)
        if ($Method -ne 'GET') {
          $script:testState.operations.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
          if ($Uri -eq 'https://graph.microsoft.com/v1.0/applications') { return [pscustomobject]@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } }
          if ($Uri -eq 'https://graph.microsoft.com/v1.0/servicePrincipals') { return [pscustomobject]@{ id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } }
          return [pscustomobject]@{ id = 'created-assignment' }
        }
        if ($Uri -like '*/me?*') { return [pscustomobject]@{ id = $script:testState.user; userPrincipalName = $env:MAESTER_SETUP_ACCOUNT } }
        if ($Uri -like "*/servicePrincipals/$($script:testState.principal)[?]*") {
          return [pscustomobject]@{ id = $script:testState.principal; appId = $script:testState.app; displayName = 'test-managed-identity'; servicePrincipalType = 'ManagedIdentity' }
        }
        if ($Uri -like '*/roleManagement/directory/roleDefinitions?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'teams-role'; displayName = 'Teams Reader'; isBuiltIn = $true }) } }
        if ($Uri -like '*/roleManagement/directory/roleAssignments?*') { return [pscustomobject]@{ value = @($script:testState.teamsAssignments) } }
        if ($Uri -like '*/applications?*') { return [pscustomobject]@{ value = @($script:testState.easyApps) } }
        if ($Uri -like '*/oauth2PermissionGrants?*') { return [pscustomobject]@{ value = @($script:testState.easyGrants) } }
        if ($Uri -like '*00000003-0000-0000-c000-000000000000*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'graph-resource'; appId = '00000003-0000-0000-c000-000000000000' }) } }
        if ($Uri -like '*00000002-0000-0ff1-ce00-000000000000*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'exchange-resource'; appId = '00000002-0000-0ff1-ce00-000000000000'; appRoles = @([pscustomobject]@{ id = 'dc50a0fb-09a3-484d-be87-e023b12c6440'; value = 'Exchange.ManageAsApp'; isEnabled = $true; allowedMemberTypes = @('Application') }) }) } }
        if ($Uri -like '*/servicePrincipals?*') { return [pscustomobject]@{ value = @($script:testState.easyPrincipals) } }
        if ($Uri -like '*/appRoleAssignments?*') { return [pscustomobject]@{ value = @() } }
        if ($Uri -like '*/groups/55555555-5555-4555-8555-555555555555?*') { return [pscustomobject]@{ id = '55555555-5555-4555-8555-555555555555'; securityEnabled = $true } }
        if ($Uri -like '*/groups?*') { return [pscustomobject]@{ value = @($script:testState.groups) } }
        throw "Unexpected offline Graph request: $Method $Uri"
      }
      Mock Invoke-RestMethod {
        param($Method, $Uri, $Body)
        if ($Method -ne 'GET') {
          $script:testState.operations.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
          return [pscustomobject]@{ id = 'created-arm-assignment' }
        }
        if ($Uri -like '*/authsettingsV2?*') { return $script:testState.auth }
        if ($script:testState.malformed) { return [pscustomobject]@{ wrong = @() } }
        $runtime = @('acdd72a7-3385-48ef-bd42-f606fba81ae7', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe', 'de139f84-1756-47ae-9be6-808fbbe84772' | ForEach-Object { [pscustomobject]@{ id = "existing-$_"; properties = @{ principalId = $script:testState.principal; roleDefinitionId = "/subscriptions/$($script:testState.tenant)/providers/Microsoft.Authorization/roleDefinitions/$_" } } })
        $result = [pscustomobject]@{ value = @($script:testState.storageAssignments) + $runtime }
        if ($script:testState.paginated) { $result | Add-Member nextLink 'https://management.azure.com/next' }
        return $result
      }
      Mock Get-ServicePrincipal { @($script:testState.exchangePrincipals) }
      Mock Get-ManagementRoleAssignment { @($script:testState.exchangeRoles) }
      Mock New-ServicePrincipal { $script:testState.operations.Add([pscustomobject]@{ method = 'New-ServicePrincipal' }) }
      Mock New-ManagementRoleAssignment { $script:testState.operations.Add([pscustomobject]@{ method = 'New-ManagementRoleAssignment' }) }
      Mock Write-Host { }
    }
    $global:setupGrantFixture = Join-Path $TestDrive 'Grant.ps1'
    Set-Content -LiteralPath $global:setupGrantFixture -Value @'
param($TenantId, $PrincipalObjectId, $PermissionProfile, $IncludeMailSend, $IncludeReportSettingsWrite, [switch]$Apply, $ApprovedPlanHash, $TargetType, $ExpectedApplicationId, $ExpectedApplicationObjectId, $ExpectedFederatedCredentialIssuer, $ExpectedFederatedCredentialSubject)
$plan = New-MaesterConsentPlan -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId -Capability GraphApplicationRoles -ManifestVersion 'test-1' -ManifestSha256 ('a' * 64) -Desired @('graph-role') -Missing @('graph-role') -Details @{ profile = $PermissionProfile; mail = $IncludeMailSend; reportSettingsWrite = $IncludeReportSettingsWrite }
if ($Apply) { Assert-MaesterConsentPlanApproval -Plan $plan -ApprovedPlanHash $ApprovedPlanHash; $global:setupGraphApplied++ }
else { $plan }
'@
    $global:setupGraphApplied = 0
  }
  AfterEach {
    $env:MAESTER_SETUP_ACCOUNT = $script:savedAccount
    $env:MAESTER_SETUP_CLIENT_ID = $script:savedClient
    Remove-Variable setupGrantFixture, setupGraphApplied -Scope Global -ErrorAction SilentlyContinue
  }
  AfterAll { Remove-Module Maester-SetupConsent, Maester-ConsentPlan -Force -ErrorAction SilentlyContinue }

  It 'plans concrete categorized grants with no writes and a stable hash' {
    InModuleScope Maester-SetupConsent {
      $first = Get-MaesterSetupAccessPlan @parameters
      $second = Get-MaesterSetupAccessPlan @parameters
      $first.planHash | Should -BeExactly $second.planHash
      $first.details.operations[0].category | Should -BeExactly 'StorageReader'
      $first.details.operations[0].body.properties.principalId | Should -BeExactly $testState.user
      $first.details.graphPlanHash | Should -BeExactly $first.details.graphPlan.planHash
      $first.manifestSha256 | Should -BeExactly ('a' * 64)
      $testState.operations.Count | Should -Be 0
    }
    $global:setupGraphApplied | Should -Be 0
  }
  It 'rejects missing and stale approval before every write' {
    InModuleScope Maester-SetupConsent {
      $plan = Get-MaesterSetupAccessPlan @parameters
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash ('0' * 64) } | Should -Throw '*changed after review*'
      $parameters.IncludeMailSend = $true
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*changed after review*'
      $testState.operations.Count | Should -Be 0
    }
    $global:setupGraphApplied | Should -Be 0
  }
  It 'requires new approval for each changed option or target' -ForEach @('IncludeReportSettingsWrite', 'IncludeTeams', 'PermissionProfile', 'ResourceId') {
    InModuleScope Maester-SetupConsent -Parameters @{ changed = $_ } {
      $plan = Get-MaesterSetupAccessPlan @parameters
      if ($changed -eq 'PermissionProfile') { $parameters[$changed] = 'Extended' }
      elseif ($changed -eq 'ResourceId') { $parameters[$changed] += '-other' }
      else { $parameters[$changed] = $true }
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*changed after review*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'rejects failed incomplete and paginated authority inventory without writes' -ForEach @('malformed', 'paginated') {
    InModuleScope Maester-SetupConsent -Parameters @{ shape = $_ } {
      $testState[$shape] = $true
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*access inventory*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'applies only the revalidated reviewed operations and separate Graph hash' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams = $true
      $plan = Get-MaesterSetupAccessPlan @parameters
      $result = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash
      $testState.operations.Count | Should -Be 2
      $result.Receipts.TEAMS_READER_ROLE_ASSIGNMENT_IDS | Should -Contain 'created-assignment'
      ($testState.operations | Where-Object uri -like '*roleManagement*').body | Should -Match 'teams-role'
    }
    $global:setupGraphApplied | Should -Be 1
  }
  It 'preserves already present storage grants without recreating them' {
    InModuleScope Maester-SetupConsent {
      $testState.storageAssignments = @([pscustomobject]@{ id = 'existing'; properties = @{ principalId = $testState.user; roleDefinitionId = "/subscriptions/$($testState.tenant)/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1" } })
      $plan = Get-MaesterSetupAccessPlan @parameters
      $plan.details.operations.Count | Should -Be 0
      $null = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'shows new Easy Auth scopes and creates application dependencies in reviewed order' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $plan = Get-MaesterSetupAccessPlan @parameters
      $plan.details.easyAuth.missingDelegatedScopes.Count | Should -Be 4
      @($plan.details.operations | Where-Object category -like 'EasyAuth*' | ForEach-Object receipt) | Should -Be @('EasyAuthApplication', 'EasyAuthPrincipal', '', '')
      $result = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash
      $result.EasyAuth.clientId | Should -BeExactly 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      $result.EasyAuth.principalId | Should -BeExactly 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
      $result.Plan.details.easyAuth.clientId | Should -BeExactly '{easyAuthClientId}'
      $result.Plan.details.easyAuth.principalId | Should -BeExactly '{easyAuthPrincipalId}'
      { Assert-MaesterConsentPlanApproval -Plan $result.Plan -ApprovedPlanHash $plan.planHash } | Should -Not -Throw
      @($testState.operations | ForEach-Object body) -join ' ' | Should -Not -Match '\{easyAuth'
      @($testState.operations | Where-Object uri -like '*oauth2PermissionGrants').Count | Should -Be 1
    }
  }
  It 'retains existing Easy Auth delegated permissions and adds only reviewed missing scopes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $testState.easyApps = @([pscustomobject]@{ id = 'existing-app'; appId = 'existing-client'; displayName = 'maester-easyauth-webapp'; signInAudience = 'AzureADMyOrg'; groupMembershipClaims = 'SecurityGroup'; web = @{ redirectUris = @('https://webapp.azurewebsites.net/.auth/login/aad/callback'); implicitGrantSettings = @{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false } } })
      $testState.easyPrincipals = @([pscustomobject]@{ id = 'existing-sp'; appId = 'existing-client'; appOwnerOrganizationId = $testState.tenant })
      $testState.easyGrants = @([pscustomobject]@{ id = 'existing-grant'; clientId = 'existing-sp'; resourceId = 'graph-resource'; consentType = 'AllPrincipals'; scope = 'openid User.Read User.ReadBasic.All' })
      $plan = Get-MaesterSetupAccessPlan @parameters
      $plan.details.easyAuth.missingDelegatedScopes | Should -Be @('profile', 'email')
      $consent = @($plan.details.operations | Where-Object category -eq 'EasyAuthConsent')
      $consent.Count | Should -Be 1
      $consent[0].method | Should -BeExactly 'PATCH'
      $consent[0].body.scope | Should -Match 'User.ReadBasic.All'
      @($plan.details.operations | Where-Object receipt -in @('EasyAuthApplication','EasyAuthPrincipal')).Count | Should -Be 0
    }
  }
  It 'reuses matching Easy Auth configuration and fully consented scopes without access writes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $testState.easyApps = @([pscustomobject]@{ id = 'existing-app'; appId = 'existing-client'; displayName = 'maester-easyauth-webapp'; signInAudience = 'AzureADMyOrg'; groupMembershipClaims = 'SecurityGroup'; web = @{ redirectUris = @('https://webapp.azurewebsites.net/.auth/login/aad/callback'); implicitGrantSettings = @{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false } } })
      $testState.easyPrincipals = @([pscustomobject]@{ id = 'existing-sp'; appId = 'existing-client'; appOwnerOrganizationId = $testState.tenant })
      $testState.easyGrants = @([pscustomobject]@{ id = 'existing-grant'; clientId = 'existing-sp'; resourceId = 'graph-resource'; consentType = 'AllPrincipals'; scope = 'openid profile email User.Read User.ReadBasic.All' })
      $first = Get-MaesterSetupAccessPlan @parameters
      $authOperation = @($first.details.operations | Where-Object category -eq 'EasyAuthConfiguration')[0]
      $testState.auth = $authOperation.body | ConvertTo-Json -Depth 30 | ConvertFrom-Json
      $plan = Get-MaesterSetupAccessPlan @parameters
      @($plan.details.operations | Where-Object category -like 'EasyAuth*').Count | Should -Be 0
      $plan.details.easyAuth.missingDelegatedScopes.Count | Should -Be 0
    }
  }
  It 'rejects ambiguous Easy Auth applications before every permission write' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $testState.easyApps = @([pscustomobject]@{ id = 'one' }, [pscustomobject]@{ id = 'two' })
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*application name is ambiguous*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'requires a new approval when existing Easy Auth configuration changes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $plan = Get-MaesterSetupAccessPlan @parameters
      $testState.auth = [pscustomobject]@{ properties = @{ platform = @{ enabled = $true } } }
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*changed after review*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'plans Exchange application access service principal and RBAC separately before writing' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      $plan = Get-MaesterSetupAccessPlan @parameters
      $exchange = @($plan.details.operations | Where-Object category -eq 'Exchange')
      $exchange.Count | Should -Be 3
      $exchange[0].body.appRoleId | Should -BeExactly 'dc50a0fb-09a3-484d-be87-e023b12c6440'
      $exchange[1].body.ObjectId | Should -BeExactly $testState.principal
      $exchange[2].body.App | Should -BeExactly $testState.principal
      $testState.operations.Count | Should -Be 0
      $null = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash
      $testState.operations.Count | Should -Be 4
    }
  }
  It 'rejects a wrong Exchange resource application before permission writes' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      Mock Invoke-GraphRestRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'unexpected-resource'; appId = '00000003-0000-0000-c000-000000000000' }) } } -ParameterFilter { $Uri -like '*00000002-0000-0ff1-ce00-000000000000*' }
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*verified Exchange resource*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'rejects a malformed Exchange resource before permission writes' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      Mock Invoke-GraphRestRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'unexpected-resource' }) } } -ParameterFilter { $Uri -like '*00000002-0000-0ff1-ce00-000000000000*' }
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*verified Exchange resource*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'fails closed when the selected Exchange inventory cannot be read' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      Mock Get-ServicePrincipal { throw 'Exchange inventory denied' }
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*Exchange inventory denied*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'binds Azure Reader to each exact selected subscription' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeAzure = $true
      $parameters.AzureScopes = @('/subscriptions/66666666-6666-4666-8666-666666666666')
      $plan = Get-MaesterSetupAccessPlan @parameters
      $azure = @($plan.details.operations | Where-Object category -eq 'AzureReader')
      $azure[0].body.properties.roleDefinitionId | Should -BeExactly '/subscriptions/66666666-6666-4666-8666-666666666666/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7'
      $parameters.AzureScopes = @('/subscriptions/77777777-7777-4777-8777-777777777777')
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*changed after review*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'rejects an ambiguous security group before application changes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupDisplayName = 'duplicate-name'
      $testState.groups = @([pscustomobject]@{ id = 'one' }, [pscustomobject]@{ id = 'two' })
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*ambiguous*'
      $testState.operations.Count | Should -Be 0
    }
  }
}

Describe 'Consumer setup entrypoint contract' {
  BeforeAll {
    $setup = Get-Content (Join-Path $repoRoot 'scripts/Setup-PostDeploy.ps1') -Raw
    $wrapper = Get-Content (Join-Path $repoRoot 'scripts/Run-AzdPostProvision.ps1') -Raw
  }
  It 'binds the complete session once and never reconnects or shadows Graph SDK commands' {
    [regex]::Matches($setup, 'Assert-GraphAccess -TenantId').Count | Should -Be 1
    $setup | Should -Match 'Get-MaesterSetupScopes -IncludeTeams:\$IncludeTeams -IncludeWebApp:\$includeWebApp'
    $setup | Should -Not -Match 'Invoke-MgGraphRequest|Connect-MgGraphSilent|Directory.AccessAsUser.All'
    $setup | Should -Match '-ClientId \$env:MAESTER_SETUP_CLIENT_ID -ExpectedAccount \$env:MAESTER_SETUP_ACCOUNT'
    $setup | Should -Match 'AllowContextReplacement:\$AllowGraphContextReplacement'
  }
  It 'supports Full Minimal and legacy Extended without remapping legacy values' {
    $setup | Should -Match "ValidateSet\('Minimal', 'Full', 'Extended'\)"
    $wrapper | Should -Match "ValidateSet\('Minimal', 'Full', 'Extended'\)"
    $setup | Should -Not -Match "if.*PermissionProfile.*-eq.*Extended.*\$PermissionProfile\s*=\s*'Full'"
  }
  It 'keeps mail and report-setting write capabilities explicitly separate' {
    $setup | Should -Match '\[switch\]\$IncludeMailSend'
    $setup | Should -Match '\[switch\]\$IncludeReportSettingsWrite'
    $setup | Should -Not -Match 'includeMailSend\s*=.*MAIL_RECIPIENT'
    $setup | Should -Match 'if \(-not \$Apply\)'
    $wrapper | Should -Match 'if \(\$setupResult\) \{ return \$setupResult \}'
  }
}
