BeforeAll {
  $root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Maester-OwnershipJournal.psm1')
  Import-Module (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Maester-ConsentPlan.psm1') -Force
  Import-Module (Join-Path $root 'scripts/Maester-AdoBootstrap.psm1') -Force
  InModuleScope Maester-AdoBootstrap {
    function script:Invoke-GraphRestRequest { param($Method, $Uri, $Body, $ContentType) throw 'Unmocked Graph tripwire.' }
    function script:Get-MaesterGraphSetupClientId { param($TenantId) '99999999-9999-4999-8999-999999999999' }
  }
}
Describe 'Azure DevOps runtime bootstrap and exact federation boundary' {
  BeforeEach {
    $script:savedAccount = $env:MAESTER_SETUP_ACCOUNT; $script:savedClient = $env:MAESTER_SETUP_CLIENT_ID
    $env:MAESTER_SETUP_ACCOUNT = 'operator@example.test'; $env:MAESTER_SETUP_CLIENT_ID = '99999999-9999-4999-8999-999999999999'
    $journalRoot = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    $global:MaesterBootstrapTestSession = Open-MaesterOwnershipJournal -ProjectRoot $journalRoot.FullName -Binding @{
      environmentName = 'test'; tenantId = '11111111-1111-4111-8111-111111111111'; subscriptionId = '22222222-2222-4222-8222-222222222222'
      solutionName = 'azure-devops'; resourceGroupId = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-test'
      setupClientId = $env:MAESTER_SETUP_CLIENT_ID; organizationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; projectId = '33333333-3333-4333-8333-333333333333'
    }
    InModuleScope Maester-AdoBootstrap {
      $script:parameters = @{
        TenantId = '11111111-1111-4111-8111-111111111111'; SubscriptionId = '22222222-2222-4222-8222-222222222222'
        ResourceGroupName = 'rg-test'; EnvironmentName = 'test'; Organization = 'org'; Project = 'project'
        RepositoryName = 'repo'; ServiceConnectionName = 'connection'; SubscriptionName = 'subscription'; SetupScopes = @('Application.Read.All','Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Directory.Read.All'); CreateRepositoryIfMissing = $true
      }
      $script:state = @{
        project = [pscustomobject]@{ id = '33333333-3333-4333-8333-333333333333'; name = 'project'; state = 'wellFormed' }
        repository = $null; endpoint = $null; application = $null; principal = $null; federations = @()
        writes = [Collections.Generic.List[object]]::new(); badCollection = $false; paginated = $false; roles = @(); directoryRoles = @()
      }
      $script:repo = [pscustomobject]@{ id = '44444444-4444-4444-8444-444444444444'; name = 'repo'; project = $script:state.project; remoteUrl = 'https://dev.azure.com/org/project/_git/repo' }
      $script:endpoint = [pscustomobject]@{
        id = '55555555-5555-4555-8555-555555555555'; name = 'connection'; type = 'AzureRM'; url = 'https://management.azure.com/'; isReady = $true; isShared = $false
        data = [pscustomobject]@{ subscriptionId = $script:parameters.SubscriptionId; isDraft = $false }
        authorization = [pscustomobject]@{ scheme = 'WorkloadIdentityFederation'; parameters = [pscustomobject]@{ tenantid = $script:parameters.TenantId; serviceprincipalid = '66666666-6666-4666-8666-666666666666'; scope = "/subscriptions/$($script:parameters.SubscriptionId)/resourceGroups/rg-test"; workloadIdentityFederationIssuer = 'https://vstoken.dev.azure.com/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; workloadIdentityFederationSubject = 'sc://org/project/connection' } }
        serviceEndpointProjectReferences = @([pscustomobject]@{ projectReference = $script:state.project })
      }
      $script:app = [pscustomobject]@{ id = '77777777-7777-4777-8777-777777777777'; appId = '66666666-6666-4666-8666-666666666666'; displayName = 'sc-app-maester-test'; signInAudience = 'AzureADMyOrg'; passwordCredentials = @(); keyCredentials = @(); identifierUris = @(); groupMembershipClaims = $null; web = @{ redirectUris = @(); implicitGrantSettings = @{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false } } }
      $script:sp = [pscustomobject]@{ id = '88888888-8888-4888-8888-888888888888'; appId = $script:app.appId; displayName = $script:app.displayName; servicePrincipalType = 'Application'; appOwnerOrganizationId = $script:parameters.TenantId; passwordCredentials = @(); keyCredentials = @() }
      $script:fic = [pscustomobject]@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; name = 'ado-test'; issuer = $script:endpoint.authorization.parameters.workloadIdentityFederationIssuer; subject = $script:endpoint.authorization.parameters.workloadIdentityFederationSubject; audiences = @('api://AzureADTokenExchange') }
      Mock Invoke-MaesterAdoRequest {
        param($Uri, $Method, $Body)
        if ($Uri -like '*/_apis/connectionData?*') { return [pscustomobject]@{ instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' } }
        if ($Method -and $Method -ne 'GET') {
          $script:state.writes.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
          if ($Uri -like '*/git/repositories?*') { $script:state.repository = $script:repo; return $script:repo }
          if ($Uri.Contains('/serviceendpoint/endpoints?')) { $script:state.endpoint = $script:endpoint | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $script:state.endpoint.authorization.parameters.serviceprincipalid = ''; $script:state.endpoint.data.isDraft = $true; return $script:state.endpoint }
          if ($Uri -like '*/serviceendpoint/endpoints/*') { $script:state.endpoint = $Body | ConvertTo-Json -Depth 20 | ConvertFrom-Json; return $script:state.endpoint }
          if ($Uri -like '*/pipelinePermissions/*') { return [pscustomobject]@{ allPipelines = @{ authorized = $true } } }
          throw "Unexpected ADO write $Method $Uri"
        }
        if ($Uri -like '*/projects/project?*') { return $script:state.project }
        if ($Uri -like '*/pipelinePermissions/*') { return [pscustomobject]@{ allPipelines = @{ authorized = $true }; pipelines = @() } }
        $values = if ($Uri -like '*/git/repositories?*') { @($script:state.repository | Where-Object { $_ }) } elseif ($Uri.Contains('/serviceendpoint/endpoints?')) { @($script:state.endpoint | Where-Object { $_ }) } else { throw "Unexpected ADO read $Uri" }
        if ($script:state.badCollection) { return [pscustomobject]@{} }
        $response = [pscustomobject]@{ value = @($values) }
        if ($script:state.paginated) { $response | Add-Member continuationToken next }
        return $response
      }
      Mock Invoke-GraphRestRequest {
        param($Uri, $Method, $Body)
        if ($Method -ne 'GET') {
          $script:state.writes.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = ($Body | ConvertFrom-Json) })
          if ($Uri -ceq 'https://graph.microsoft.com/v1.0/applications') { $script:state.application = $script:app; return $script:app }
          if ($Uri -ceq 'https://graph.microsoft.com/v1.0/servicePrincipals') { $script:state.principal = $script:sp; return $script:sp }
          if ($Uri -like '*/federatedIdentityCredentials') { $script:state.federations += $script:fic; return $script:fic }
          throw "Unexpected Graph write $Method $Uri"
        }
        if ($Uri -like '*/me?*') { return [pscustomobject]@{ id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; userPrincipalName = $env:MAESTER_SETUP_ACCOUNT } }
        if ($Uri -like "https://graph.microsoft.com/v1.0/applications/$($script:app.id)[?]*") { return $script:state.application }
        if ($Uri.StartsWith('https://graph.microsoft.com/v1.0/applications?')) { return [pscustomobject]@{ value = @($script:state.application | Where-Object { $_ }) } }
        if ($Uri.StartsWith('https://graph.microsoft.com/v1.0/servicePrincipals?')) { return [pscustomobject]@{ value = @($script:state.principal | Where-Object { $_ }) } }
        if ($Uri -like '*/federatedIdentityCredentials?*') { return [pscustomobject]@{ value = @($script:state.federations) } }
        if ($Uri -like '*/appRoleAssignments?*') { return [pscustomobject]@{ value = @($script:state.roles) } }
        if ($Uri -like '*/roleManagement/directory/roleAssignments?*') { return [pscustomobject]@{ value = @($script:state.directoryRoles) } }
        throw "Unexpected Graph read $Uri"
      }
    }
  }
  AfterEach { if ($global:MaesterBootstrapTestSession) { $global:MaesterBootstrapTestSession.Dispose() }; Remove-Variable MaesterBootstrapTestSession -Scope Global; $env:MAESTER_SETUP_ACCOUNT = $script:savedAccount; $env:MAESTER_SETUP_CLIENT_ID = $script:savedClient }
  AfterAll { Remove-Module Maester-AdoBootstrap -ErrorAction SilentlyContinue }
  It 'defaults to a stable read-only bootstrap plan with no unresolved FIC or permissions' {
    InModuleScope Maester-AdoBootstrap {
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      $plan.planHash | Should -BeExactly (Get-MaesterAdoBootstrapPlan -Parameters $parameters).planHash
      $plan.details.operations.kind | Should -Be @('Repository', 'Endpoint', 'Application')
      $plan.details.setupScopes | Should -Be @('Application.Read.All','Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Directory.Read.All')
      $state.writes.Count | Should -Be 0
    }
  }
  It 'executes only known approved stages and requires fresh exact FIC trust approval' {
    InModuleScope Maester-AdoBootstrap {
      $first = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      $result = Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $first.planHash
      $state.writes.Count | Should -Be 3
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be 3
      $result.NextPlan.details.operations.kind | Should -Be @('Principal')
      @($state.writes | Where-Object uri -like '*federatedIdentityCredentials*').Count | Should -Be 0
      $second = Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $result.NextPlan.planHash
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be 4
      $second.NextPlan.details.operations.kind | Should -Be @('Federation', 'EndpointBinding')
      $trust = @($second.NextPlan.details.operations | Where-Object kind -eq Federation)[0]
      $trust.body.issuer | Should -BeExactly $fic.issuer
      $trust.body.subject | Should -BeExactly $fic.subject
      $third = Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $second.NextPlan.planHash
      $third.NextPlan.missing.Count | Should -Be 0
      $state.writes.Count | Should -Be 6
      $identity = Get-MaesterAdoIdentity @parameters
      $identity.grantTarget.TargetType | Should -BeExactly FederatedApplication
      $identity.principalId | Should -BeExactly $sp.id
      $before = $state.writes.Count
      $null = Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $third.NextPlan.planHash
      $state.writes.Count | Should -Be $before
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $records.Count | Should -Be 6
      @($records | Where-Object state -ne applied).Count | Should -Be 0
      $bindingReceipt = @($records | Where-Object kind -eq AdoServiceConnectionBinding)[0]
      $bindingReceipt.coveredByOperationId | Should -BeExactly (@($records | Where-Object kind -eq AdoServiceConnection)[0].operationId)
      @($state.writes | Where-Object uri -match 'appRoleAssignments|roleAssignments|pipelinePermissions').Count | Should -Be 0
    }
  }
  It 'rejects stale approval before the first operation' {
    InModuleScope Maester-AdoBootstrap {
      $first = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      $state.repository = $repo
      { Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $first.planHash } | Should -Throw '*inventory changed*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'does not turn unreadable or paginated identity inventory into permission to create: <mode>' -ForEach @('badCollection','paginated') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state[$mode] = $true
      { Get-MaesterAdoBootstrapPlan -Parameters $parameters } | Should -Throw '*inventory*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'rejects an ambiguous application instead of adopting the first match' {
    InModuleScope Maester-AdoBootstrap {
      $state.application = @($app, $app)
      { Get-MaesterAdoBootstrapPlan -Parameters $parameters } | Should -Throw '*ambiguous*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'rejects wrong endpoint or principal provenance: <mode>' -ForEach @('tenant','subscription','type','scheme','project','client','owner','principalType','appAudience','setupClient','issuer','audience','duplicateTrust') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      switch ($mode) {
        tenant { $endpoint.authorization.parameters.tenantid = 'other' }
        subscription { $endpoint.data.subscriptionId = 'other' }
        type { $endpoint.type = 'other' }
        scheme { $endpoint.authorization.scheme = 'ServicePrincipal' }
        project { $endpoint.serviceEndpointProjectReferences = @() }
        client { $endpoint.authorization.parameters.serviceprincipalid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
        owner { $sp.appOwnerOrganizationId = 'other' }
        principalType { $sp.servicePrincipalType = 'ManagedIdentity' }
        appAudience { $app.signInAudience = 'AzureADMultipleOrgs' }
        setupClient { Mock Get-MaesterGraphSetupClientId { $script:app.appId } }
        issuer { $endpoint.authorization.parameters.workloadIdentityFederationIssuer = 'https://evil.example/trust' }
        audience { $fic.audiences = @('api://AzureADTokenExchange','extra') }
        duplicateTrust { $state.federations = @($fic,$fic) }
      }
      { Get-MaesterAdoIdentity @parameters } | Should -Throw
      $state.writes.Count | Should -Be 0
    }
  }
  It 'accepts exact tenant-issued federation without rewriting the opaque prefix' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp
      $endpoint.authorization.parameters.workloadIdentityFederationIssuer = "https://login.microsoftonline.com/$($parameters.TenantId)/v2.0"
      $endpoint.authorization.parameters.workloadIdentityFederationSubject = "/opaque-prefix/sc/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/$($endpoint.id)"
      $fic.issuer = $endpoint.authorization.parameters.workloadIdentityFederationIssuer; $fic.subject = $endpoint.authorization.parameters.workloadIdentityFederationSubject
      $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      $identity.grantTarget.ExpectedFederatedCredentialSubject | Should -BeExactly $fic.subject
      $state.writes.Count | Should -Be 0
    }
  }
  It 'rejects federation strings that do not bind the independently selected target: <mode>' -ForEach @('organization','legacySubject','modernTenant','modernOrganization','modernEndpoint','modernPrefix','modernWhitespace') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp
      if ($mode -like 'modern*') {
        $endpoint.authorization.parameters.workloadIdentityFederationIssuer = "https://login.microsoftonline.com/$($parameters.TenantId)/v2.0"
        $endpoint.authorization.parameters.workloadIdentityFederationSubject = "/opaque-prefix/sc/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/$($endpoint.id)"
      }
      switch ($mode) {
        organization { $endpoint.authorization.parameters.workloadIdentityFederationIssuer = 'https://vstoken.dev.azure.com/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }
        legacySubject { $endpoint.authorization.parameters.workloadIdentityFederationSubject = 'sc://org/other/connection' }
        modernTenant { $endpoint.authorization.parameters.workloadIdentityFederationIssuer = 'https://login.microsoftonline.com/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/v2.0' }
        modernOrganization { $endpoint.authorization.parameters.workloadIdentityFederationSubject = "/opaque-prefix/sc/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/$($endpoint.id)" }
        modernEndpoint { $endpoint.authorization.parameters.workloadIdentityFederationSubject = '/opaque-prefix/sc/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }
        modernPrefix { $endpoint.authorization.parameters.workloadIdentityFederationSubject = "/sc/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/$($endpoint.id)" }
        modernWhitespace { $endpoint.authorization.parameters.workloadIdentityFederationSubject = "/opaque prefix/sc/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/$($endpoint.id)" }
      }
      { Get-MaesterAdoBootstrapPlan -Parameters $parameters } | Should -Throw '*federation does not bind*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'rejects a missing authoritative organization instance ID' {
    InModuleScope Maester-AdoBootstrap {
      Mock Invoke-MaesterAdoRequest { [pscustomobject]@{} } -ParameterFilter { $Uri -like '*/_apis/connectionData?*' }
      { Get-MaesterAdoBootstrapPlan -Parameters $parameters } | Should -Throw '*OrganizationId*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'plans an exact RG scope repair without silently changing it during access setup' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $endpoint.authorization.parameters.scope = ''
      { Get-MaesterAdoIdentity @parameters } | Should -Throw '*resource-group scope*'
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      $plan.details.operations.kind | Should -Be @('EndpointBinding')
      $plan.details.operations[0].body.authorization.parameters.scope | Should -BeExactly "/subscriptions/$($parameters.SubscriptionId)/resourceGroups/rg-test"
      $state.writes.Count | Should -Be 0
    }
  }
  It 'invalidates approval when alternate trust or credential metadata changes' -ForEach @('federation','credential') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      if ($mode -eq 'federation') { $state.federations += [pscustomobject]@{ id = 'alternate'; name = 'alternate'; issuer = $fic.issuer; subject = 'other-subject'; audiences = @('api://AzureADTokenExchange') } }
      else { $app.passwordCredentials = @([pscustomobject]@{ keyId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z' }) }
      { Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*inventory changed*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'rejects an existing FIC name bound to another exact trust' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp
      $fic.subject = 'other-subject'; $state.federations = @($fic)
      { Get-MaesterAdoBootstrapPlan -Parameters $parameters } | Should -Throw '*another trust*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'plans and verifies endpoint readiness as an explicit binding delta' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $endpoint.isReady = $false
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      @($plan.details.operations | ForEach-Object kind) | Should -Be @('EndpointBinding')
      $result = Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash
      $result.Snapshot.endpoint.isReady | Should -BeTrue
      $result.NextPlan.missing.Count | Should -Be 0
    }
  }
  It 'rejects ignored endpoint binding writes despite a successful exact-ID response' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $endpoint.authorization.parameters.scope = ''
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      Mock Invoke-MaesterAdoRequest { $script:state.endpoint } -ParameterFilter { $Method -eq 'PUT' }
      { Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*binding readback*'
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $records[0].state | Should -BeExactly conflict
      { Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*unresolved outcome or conflict*'
      Should -Invoke Invoke-MaesterAdoRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }
  }
  It 'rejects shared or unreadable endpoint sharing inventory: <mode>' -ForEach @('shared','missing','string') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state.endpoint = $endpoint
      switch ($mode) {
        shared { $endpoint.isShared = $true }
        missing { $endpoint.PSObject.Properties.Remove('isShared') }
        string { $endpoint.isShared = 'false' }
      }
      { Get-MaesterAdoBootstrapPlan -Parameters $parameters } | Should -Throw '*explicitly nonshared*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'uses the captured setup-client identity with the exact tenant' {
    InModuleScope Maester-AdoBootstrap {
      $state.application = $app
      Mock Get-MaesterGraphSetupClientId { '99999999-9999-4999-8999-999999999999' }
      $null = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      Should -Invoke Get-MaesterGraphSetupClientId -Times 1 -Exactly -ParameterFilter { $TenantId -ceq $script:parameters.TenantId }
    }
  }
  It 'rejects malformed credential inventories before any writes: <mode>' -ForEach @('missing','notArray','keyId','duplicate','date') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state.application = $app
      $credential = [pscustomobject]@{ keyId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z' }
      $app.passwordCredentials = @($credential)
      switch ($mode) {
        missing { $app.PSObject.Properties.Remove('passwordCredentials') }
        notArray { $app.passwordCredentials = 'unreadable' }
        keyId { $credential.keyId = 'invalid' }
        duplicate { $app.passwordCredentials = @($credential,$credential) }
        date { $credential.endDateTime = 'invalid' }
      }
      { Get-MaesterAdoBootstrapPlan -Parameters $parameters } | Should -Throw '*inventory*'
      $state.writes.Count | Should -Be 0
    }
  }
  It 'projects only nonsecret credential and approved endpoint metadata into displayed plans' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp
      $app.passwordCredentials = @([pscustomobject]@{ keyId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z'; secretText = 'SECRET_FIXTURE'; hint = 'HINT_FIXTURE'; key = 'KEY_FIXTURE' })
      $endpoint.authorization.parameters | Add-Member secretText 'ENDPOINT_SECRET_FIXTURE'
      $json = Get-MaesterAdoBootstrapPlan -Parameters $parameters | ConvertTo-Json -Depth 100
      $json | Should -Not -Match 'SECRET_FIXTURE|HINT_FIXTURE|KEY_FIXTURE|secretText|"passwordCredentials"\s*:|"keyCredentials"\s*:'
      $json | Should -Match 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    }
  }
  It 'validates every expected binding GUID before any lookup: <name>' -ForEach @('ExpectedServiceConnectionId','ExpectedApplicationId','ExpectedApplicationObjectId','ExpectedPrincipalObjectId') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ name = $_ } {
      $parameters[$name] = "bad' or appId ne ''"
      { Get-MaesterAdoBootstrapPlan -Parameters $parameters } | Should -Throw '*non-empty GUID*'
      Should -Invoke Invoke-MaesterAdoRequest -Times 0
      Should -Invoke Invoke-GraphRestRequest -Times 0
    }
  }

  It 'checkpoints the repository before a subsequent endpoint create fails' {
    InModuleScope Maester-AdoBootstrap {
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      Mock Invoke-MaesterAdoRequest { throw 'synthetic endpoint failure' } -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/serviceendpoint/endpoints?*' }
      { Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*synthetic endpoint failure*'
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $records.Count | Should -Be 2
      $records[0].kind | Should -BeExactly 'AdoRepository'
      $records[0].state | Should -BeExactly 'applied'
      $records[0].exactIds.repositoryId | Should -BeExactly $repo.id
      $records[1].kind | Should -BeExactly 'AdoServiceConnection'
      $records[1].state | Should -BeExactly 'pending'
      $records[1].exactIds.Count | Should -Be 0
    }
  }
  It 'retains exact app IDs but stops on creation-response configuration drift: <_>' -ForEach @('redirectUris','identifierUris','groupMembershipClaims','enableIdTokenIssuance','enableAccessTokenIssuance','signInAudience') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ field = $_ } {
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      switch ($field) {
        redirectUris { $app.web.redirectUris = @('https://foreign.example/callback') }
        identifierUris { $app.identifierUris = @('https://foreign.example/identifier') }
        groupMembershipClaims { $app.groupMembershipClaims = 'All' }
        enableIdTokenIssuance { $app.web.implicitGrantSettings.enableIdTokenIssuance = $true }
        enableAccessTokenIssuance { $app.web.implicitGrantSettings.enableAccessTokenIssuance = $true }
        signInAudience { $app.signInAudience = 'AzureADMultipleOrgs' }
      }
      { Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*approved baseline field*'
      $record = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records | Where-Object kind -eq EntraApplication
      $record.state | Should -BeExactly conflict
      $record.exactIds.applicationObjectId | Should -BeExactly $app.id
      $record.after.groupMembershipClaims | Should -BeExactly None
      $record.after.signInAudience | Should -BeExactly AzureADMyOrg
      $state.writes.Count | Should -Be 3
    }
  }
  It 'rejects a changed exact application configuration readback after recording the create response' {
    InModuleScope Maester-AdoBootstrap {
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      Mock Invoke-GraphRestRequest {
        $copy = $script:state.application | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $copy.web.redirectUris = @('https://foreign.example/callback')
        $copy
      } -ParameterFilter { $Method -eq 'GET' -and $Uri -like 'https://graph.microsoft.com/v1.0/applications/77777777-7777-4777-8777-777777777777[?]*' }
      { Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*approved baseline field*'
      $record = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records | Where-Object kind -eq EntraApplication
      $record.state | Should -BeExactly conflict
      $record.exactIds.appId | Should -BeExactly $app.appId
      $record.after.redirectUris.Count | Should -Be 0
      $state.writes.Count | Should -Be 3
    }
  }
  It 'retains each exact create receipt when fresh post-stage inventory fails' {
    InModuleScope Maester-AdoBootstrap {
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      Mock Invoke-MaesterAdoRequest {
        if ($script:state.writes.Count -gt 0) { throw 'synthetic post-stage readback failure' }
        $script:state.project
      } -ParameterFilter { (-not $Method -or $Method -eq 'GET') -and $Uri -like '*/projects/project?*' }
      { Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*synthetic post-stage readback failure*'
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $records.Count | Should -Be 3
      @($records | Where-Object state -ne applied).Count | Should -Be 0
      ($records | Where-Object kind -eq EntraApplication).exactIds.applicationObjectId | Should -BeExactly $app.id
      ($records | Where-Object kind -eq EntraApplication).exactIds.appId | Should -BeExactly $app.appId
    }
  }
  It 'owns only a newly created federation on an adopted application' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      $result = Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $records.Count | Should -Be 1
      $records[0].kind | Should -BeExactly 'FederatedIdentityCredential'
      $records[0].expected.applicationObjectId | Should -BeExactly $app.id
      $records[0].exactIds.federatedCredentialId | Should -BeExactly $fic.id
      $null = Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $result.NextPlan.planHash
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be 1
      $state.writes.Count | Should -Be 1
    }
  }
  It 'does not turn reused complete bootstrap objects into owned receipts' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $plan = Get-MaesterAdoBootstrapPlan -Parameters $parameters
      $null = Invoke-MaesterAdoBootstrapPlan -OwnershipSession $global:MaesterBootstrapTestSession -Parameters $parameters -ApprovedPlanHash $plan.planHash
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be 0
      $state.writes.Count | Should -Be 0
    }
  }
  It 'journals exact endpoint and composite repository authorization with real core parent validation: <ownership>' -ForEach @('owned', 'adopted') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ ownership = $_ } {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      $state.authorized = @{}
      Mock Invoke-MaesterAdoRequest {
        if ($Method -eq 'PATCH') {
          $pending = @((Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records | Where-Object { $_.kind -eq 'AdoPipelineAuthorization' -and $_.state -eq 'pending' })
          $pending.Count | Should -Be 1
          $script:state.authorized[$Uri] = $true
          $script:state.writes.Add([pscustomobject]@{ method = $Method; uri = $Uri })
        }
        [pscustomobject]@{ allPipelines = @{ authorized = [bool]$script:state.authorized[$Uri] }; pipelines = @() }
      } -ParameterFilter { $Uri -like '*/pipelinePermissions/*' }
      if ($ownership -eq 'owned') {
        foreach ($parent in @(@{ kind = 'AdoRepository'; field = 'repositoryId'; id = $repo.id }, @{ kind = 'AdoServiceConnection'; field = 'serviceConnectionId'; id = $endpoint.id })) {
          $record = Start-MaesterOwnedOperation -Session $global:MaesterBootstrapTestSession -Key $parent.kind -Kind $parent.kind -Ownership Created -PlanHash ('a' * 64) -Expected @{ organizationId = $identity.snapshot.organization.id; projectId = $identity.snapshot.project.id }
          Complete-MaesterOwnedOperation -Session $global:MaesterBootstrapTestSession -OperationId $record.operationId -ExactIds @{ ($parent.field) = $parent.id } | Out-Null
        }
      }
      $delta = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters
      Invoke-MaesterAdoAccessDelta -Delta $delta -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64)
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $authorizations = @($records | Where-Object kind -eq AdoPipelineAuthorization)
      $authorizations.Count | Should -Be 2
      ($authorizations | Where-Object { $_.expected.resourceType -eq 'repository' }).exactIds.resourceId | Should -BeExactly "$($state.project.id).$($repo.id)"
      foreach ($record in $authorizations) {
        $record.before.allPipelinesAuthorized | Should -BeFalse
        $record.after.allPipelinesAuthorized | Should -BeTrue
        if ($ownership -eq 'owned') { $record.state | Should -BeExactly applied; $record.coveredByOperationId | Should -Not -BeNullOrEmpty }
        else { $record.state | Should -BeExactly applied; $record.coveredByOperationId | Should -BeNullOrEmpty }
      }
      $noop = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters
      @($noop.operations).Count | Should -Be 0
      Invoke-MaesterAdoAccessDelta -Delta $noop -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64)
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be $records.Count
      $state.writes.Count | Should -Be 2
    }
  }

}
