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
        permissions = @{}; writes = [Collections.Generic.List[object]]::new(); badCollection = $false; paginated = $false; roles = @(); directoryRoles = @()
      }
      $script:repo = [pscustomobject]@{ id = '44444444-4444-4444-8444-444444444444'; name = 'repo'; project = $script:state.project; remoteUrl = 'https://dev.azure.com/org/project/_git/repo' }
      $script:pipeline = [pscustomobject]@{ id = 17; projectId = $script:state.project.id; repositoryId = $script:repo.id }
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
          if ($Uri -like '*/pipelinePermissions/*') {
            $prior = if ($script:state.permissions.ContainsKey($Uri)) { $script:state.permissions[$Uri].pipelines } else { @() }
            $selectedIds = @($Body.pipelines | ForEach-Object { [string]$_.id })
            $all = if ($script:state.permissions.ContainsKey($Uri)) { $script:state.permissions[$Uri].allPipelines.authorized } else { $false }
            $script:state.permissions[$Uri] = [pscustomobject]@{ allPipelines = @{ authorized = $all }; pipelines = @($prior | Where-Object { [string]$_.id -notin $selectedIds }) + @($Body.pipelines) }
            return $script:state.permissions[$Uri]
          }
          throw "Unexpected ADO write $Method $Uri"
        }
        if ($Uri -like '*/projects/project?*') { return $script:state.project }
        if ($Uri -like '*/pipelinePermissions/*') {
          if ($script:state.permissions.ContainsKey($Uri)) { return $script:state.permissions[$Uri] }
          return [pscustomobject]@{ allPipelines = @{ authorized = $false }; pipelines = @() }
        }
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
      Mock Invoke-MaesterAdoRequest {
        if (-not $script:state.permissions.ContainsKey($Uri)) {
          $script:state.permissions[$Uri] = [pscustomobject]@{ allPipelines = @{ authorized = $false }; pipelines = @(@{ id = 99; authorized = $true }, @{ id = 8; authorized = $false }, @{ id = 11; authorized = $true }) }
        }
        if ($Method -eq 'PATCH') {
          $pending = @((Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records | Where-Object { $_.kind -eq 'AdoPipelineAuthorization' -and $_.state -eq 'pending' })
          $pending.Count | Should -Be 1
          $Body.Keys.Count | Should -Be 1
          $Body.ContainsKey('allPipelines') | Should -BeFalse
          @($Body.pipelines).Count | Should -Be 1
          $Body.pipelines[0].id | Should -Be 17
          $Body.pipelines[0].authorized | Should -BeTrue
          $script:state.permissions[$Uri].pipelines += @($Body.pipelines)
          $script:state.writes.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
        }
        $script:state.permissions[$Uri]
      } -ParameterFilter { $Uri -like '*/pipelinePermissions/*' }
      if ($ownership -eq 'owned') {
        foreach ($parent in @(@{ kind = 'AdoRepository'; field = 'repositoryId'; id = $repo.id }, @{ kind = 'AdoServiceConnection'; field = 'serviceConnectionId'; id = $endpoint.id })) {
          $record = Start-MaesterOwnedOperation -Session $global:MaesterBootstrapTestSession -Key $parent.kind -Kind $parent.kind -Ownership Created -PlanHash ('a' * 64) -Expected @{ organizationId = $identity.snapshot.organization.id; projectId = $identity.snapshot.project.id }
          Complete-MaesterOwnedOperation -Session $global:MaesterBootstrapTestSession -OperationId $record.operationId -ExactIds @{ ($parent.field) = $parent.id } | Out-Null
        }
      }
      $delta = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline
      Invoke-MaesterAdoAccessDelta -Delta $delta -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64)
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $authorizations = @($records | Where-Object kind -eq AdoPipelineAuthorization)
      $authorizations.Count | Should -Be 2
      ($authorizations | Where-Object { $_.expected.resourceType -eq 'repository' }).exactIds.resourceId | Should -BeExactly "$($state.project.id).$($repo.id)"
      foreach ($record in $authorizations) {
        $record.before.allPipelinesAuthorized | Should -BeFalse
        $record.after.allPipelinesAuthorized | Should -BeFalse
        $record.expected.pipelineId | Should -BeExactly '17'
        $record.before.pipelineIds | Should -Be @('11', '99')
        $record.after.pipelineIds | Should -Be @('11', '17', '99')
        if ($ownership -eq 'owned') { $record.state | Should -BeExactly applied; $record.coveredByOperationId | Should -Not -BeNullOrEmpty }
        else { $record.state | Should -BeExactly applied; $record.coveredByOperationId | Should -BeNullOrEmpty }
      }
      $noop = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline
      @($noop.operations).Count | Should -Be 0
      Invoke-MaesterAdoAccessDelta -Delta $noop -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64)
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be $records.Count
      $state.writes.Count | Should -Be 2
    }
  }
  It 'rejects broad all-pipelines access on either selected resource before any writes: <resource>' -ForEach @('endpoint', 'repository') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ resource = $_ } {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      $resourceId = if ($resource -eq 'endpoint') { $endpoint.id } else { "$($state.project.id).$($repo.id)" }
      $uri = "$($identity.snapshot.root)/pipelines/pipelinePermissions/$resource/${resourceId}?api-version=7.1-preview.1"
      $state.permissions[$uri] = [pscustomobject]@{ allPipelines = @{ authorized = $true }; pipelines = @(@{ id = 17; authorized = $true }) }
      { Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline } | Should -Throw '*all-pipelines authorization*'
      $state.writes.Count | Should -Be 0
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be 0
    }
  }
  It 'requires an exact verified pipeline binding before looking up permissions: <mode>' -ForEach @('missingId', 'invalidId', 'zeroId', 'wrongProject', 'wrongRepository') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      switch ($mode) {
        missingId { $pipeline.PSObject.Properties.Remove('id') }
        invalidId { $pipeline.id = '17 OR 1=1' }
        zeroId { $pipeline.id = 0 }
        wrongProject { $pipeline.projectId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
        wrongRepository { $pipeline.repositoryId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
      }
      { Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline } | Should -Throw
      Should -Invoke Invoke-MaesterAdoRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*/pipelinePermissions/*' }
      $state.writes.Count | Should -Be 0
    }
  }
  It 'rejects malformed or ambiguous exact authorization inventories: <mode>' -ForEach @('missingAll', 'stringAll', 'missingPipelines', 'scalarPipelines', 'invalidId', 'zeroId', 'duplicateId', 'conflictingDuplicate', 'stringAuthorized', 'missingAuthorized', 'nullEntry') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      $permission = [pscustomobject]@{ allPipelines = @{ authorized = $false }; pipelines = @(@{ id = 99; authorized = $true }) }
      switch ($mode) {
        missingAll { $permission.PSObject.Properties.Remove('allPipelines') }
        stringAll { $permission.allPipelines.authorized = 'false' }
        missingPipelines { $permission.PSObject.Properties.Remove('pipelines') }
        scalarPipelines { $permission.pipelines = 'unreadable' }
        invalidId { $permission.pipelines[0].id = 'invalid' }
        zeroId { $permission.pipelines[0].id = 0 }
        duplicateId { $permission.pipelines += @{ id = 99; authorized = $true } }
        conflictingDuplicate { $permission.pipelines += @{ id = 99; authorized = $false } }
        stringAuthorized { $permission.pipelines[0].authorized = 'true' }
        missingAuthorized { $permission.pipelines[0].Remove('authorized') }
        nullEntry { $permission.pipelines = @($null) }
      }
      $state.permissions["$($identity.snapshot.root)/pipelines/pipelinePermissions/endpoint/$($endpoint.id)?api-version=7.1-preview.1"] = $permission
      { Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline } | Should -Throw '*authorization inventory*'
      $state.writes.Count | Should -Be 0
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be 0
    }
  }
  It 'normalizes reordered numeric permissions and changes only the selected pipeline authorization' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      foreach ($resource in @(@{ type = 'endpoint'; id = $endpoint.id }, @{ type = 'repository'; id = "$($state.project.id).$($repo.id)" })) {
        $state.permissions["$($identity.snapshot.root)/pipelines/pipelinePermissions/$($resource.type)/$($resource.id)?api-version=7.1-preview.1"] = [pscustomobject]@{ allPipelines = @{ authorized = $false }; pipelines = @(@{ id = 99; authorized = $true }, @{ id = 17; authorized = $false }, @{ id = 8; authorized = $false }) }
      }
      $delta = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline
      $delta.inventory.endpoint.pipelines.id | Should -Be @('8', '17', '99')
      $delta.inventory.endpoint.pipelines[1].authorized | Should -BeFalse
      # Ordering and JSON number/string representations have no authority meaning.
      foreach ($uri in @($state.permissions.Keys)) { $state.permissions[$uri].pipelines = @(@{ id = '8'; authorized = $false }, @{ id = '99'; authorized = $true }, @{ id = '17'; authorized = $false }) }
      Invoke-MaesterAdoAccessDelta -Delta $delta -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64)
      $state.writes.Count | Should -Be 2
      foreach ($write in $state.writes) {
        $write.method | Should -BeExactly PATCH
        $write.body.Keys.Count | Should -Be 1
        $write.body.ContainsKey('allPipelines') | Should -BeFalse
        @($write.body.pipelines).Count | Should -Be 1
        $write.body.pipelines[0].id | Should -Be 17
        $write.body.pipelines[0].authorized | Should -BeTrue
        $observed = $state.permissions[$write.uri]
        @($observed.pipelines | Where-Object { [string]$_.id -ceq '99' -and $_.authorized }).Count | Should -Be 1
        @($observed.pipelines | Where-Object { [string]$_.id -ceq '8' -and -not $_.authorized }).Count | Should -Be 1
      }
    }
  }
  It 'records conflicts and stops before authorizing later resources on contradictory readback: <mode>' -ForEach @('broadAccess', 'lostUnrelatedGrant', 'selectedMissing', 'unexpectedGrant') {
    InModuleScope Maester-AdoBootstrap -Parameters @{ mode = $_ } {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      $state.readbackMode = $mode
      Mock Invoke-MaesterAdoRequest {
        if ($Method -eq 'PATCH') {
          $script:state.writes.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
        }
        $values = @(@{ id = 99; authorized = $true })
        $all = $false
        if ($script:state.writes.Count -gt 0) {
          $values += @{ id = 17; authorized = $true }
          switch ($script:state.readbackMode) {
            broadAccess { $all = $true }
            lostUnrelatedGrant { $values = @(@{ id = 17; authorized = $true }) }
            selectedMissing { $values = @(@{ id = 99; authorized = $true }) }
            unexpectedGrant { $values += @{ id = 100; authorized = $true } }
          }
        }
        [pscustomobject]@{ allPipelines = @{ authorized = $all }; pipelines = $values }
      } -ParameterFilter { $Uri -like '*/pipelinePermissions/*' }
      $delta = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline
      @($delta.operations).Count | Should -Be 2
      { Invoke-MaesterAdoAccessDelta -Delta $delta -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64) } | Should -Throw
      $state.writes.Count | Should -Be 1
      $state.writes[0].uri | Should -Match '/pipelinePermissions/endpoint/'
      Should -Invoke Invoke-MaesterAdoRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Uri -like '*/pipelinePermissions/repository/*' }
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $records.Count | Should -Be 1
      $records[0].state | Should -BeExactly conflict
      $records[0].expected.pipelineId | Should -BeExactly '17'
      $records[0].before.pipelineIds | Should -Be @('99')
      $records[0].after.pipelineIds | Should -Be @('17', '99')
      $records[0].exactIds.resourceId | Should -BeExactly $endpoint.id
    }
  }
  It 'never clears a concurrent broad grant and stops on its post-PATCH readback' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      $state.racingBroadGrant = $false; $state.selectedGranted = $false
      Mock Invoke-MaesterAdoRequest {
        if ($Method -eq 'PATCH') {
          # Another administrator broadens access after the final GET. Model
          # ADO's partial update semantics so writing allPipelines=false here
          # would silently overwrite their concurrently changed grant.
          $script:state.racingBroadGrant = $true
          if ($Body.ContainsKey('allPipelines')) { $script:state.racingBroadGrant = $Body.allPipelines.authorized }
          $script:state.selectedGranted = $Body.pipelines[0].authorized
          $script:state.writes.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
        }
        $values = @(@{ id = 99; authorized = $true })
        if ($script:state.selectedGranted) { $values += @{ id = 17; authorized = $true } }
        [pscustomobject]@{ allPipelines = @{ authorized = $script:state.racingBroadGrant }; pipelines = $values }
      } -ParameterFilter { $Uri -like '*/pipelinePermissions/*' }
      $delta = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline
      { Invoke-MaesterAdoAccessDelta -Delta $delta -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64) } | Should -Throw '*all-pipelines authorization*'
      $state.racingBroadGrant | Should -BeTrue
      $state.selectedGranted | Should -BeTrue
      $state.writes.Count | Should -Be 1
      $state.writes[0].body.Keys.Count | Should -Be 1
      $state.writes[0].body.ContainsKey('allPipelines') | Should -BeFalse
      @($state.writes[0].body.pipelines).Count | Should -Be 1
      $state.writes[0].body.pipelines[0].id | Should -Be 17
      Should -Invoke Invoke-MaesterAdoRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Uri -like '*/pipelinePermissions/repository/*' }
      $records = (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records
      $records.Count | Should -Be 1
      $records[0].state | Should -BeExactly conflict
      $records[0].exactIds.resourceId | Should -BeExactly $endpoint.id
    }
  }
  It 'rejects authorization drift immediately before the first PATCH without writing or claiming ownership' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      $delta = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline
      $state.permissions[$delta.operations[0].uri] = [pscustomobject]@{ allPipelines = @{ authorized = $false }; pipelines = @(@{ id = 99; authorized = $true }) }
      { Invoke-MaesterAdoAccessDelta -Delta $delta -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64) } | Should -Throw '*changed after approval*'
      $state.writes.Count | Should -Be 0
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be 0
    }
  }
  It 'performs no authorization writes or ownership claims when the exact pipeline is already granted' {
    InModuleScope Maester-AdoBootstrap {
      $state.repository = $repo; $state.endpoint = $endpoint; $state.application = $app; $state.principal = $sp; $state.federations = @($fic)
      $identity = Get-MaesterAdoIdentity @parameters
      Mock Invoke-MaesterAdoRequest { [pscustomobject]@{ allPipelines = @{ authorized = $false }; pipelines = @(@{ id = 99; authorized = $true }, @{ id = 17; authorized = $true }) } } -ParameterFilter { $Uri -like '*/pipelinePermissions/*' }
      $delta = Get-MaesterAdoAccessDelta -Identity $identity -Parameters $parameters -Pipeline $pipeline
      $delta.pipelineId | Should -BeExactly '17'
      @($delta.operations).Count | Should -Be 0
      Invoke-MaesterAdoAccessDelta -Delta $delta -Parameters $parameters -OwnershipSession $global:MaesterBootstrapTestSession -ApprovedPlanHash ('a' * 64)
      $state.writes.Count | Should -Be 0
      (Get-MaesterOwnershipJournal -Session $global:MaesterBootstrapTestSession).records.Count | Should -Be 0
    }
  }

}
