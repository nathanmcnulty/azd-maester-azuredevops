# Execute the unchanged production azd wrappers, shared orchestration, journal,
# infrastructure validation and finite cleanup handlers. Only provider/auth
# boundaries and the wrapper's checkout root are redirected to offline fixtures.
BeforeAll {
  $script:consumerRoot = Split-Path $PSScriptRoot -Parent
  $script:consumerScripts = Join-Path $script:consumerRoot 'scripts'
  $script:vendor = Join-Path $script:consumerScripts 'vendor/Azd.MaesterHooks'
  Import-Module (Join-Path $script:vendor 'Maester-OwnershipJournal.psm1')
  Import-Module (Join-Path $script:vendor 'Maester-InfrastructureOwnership.psm1')
  Import-Module (Join-Path $script:vendor 'Maester-PreDownCleanup.psm1')

  function Invoke-OfflineAdoDown {
    param([ValidateSet('PreDown','PostDown')][string]$Phase, [hashtable]$Options = @{})
    $f = $global:AdoDownFixture
    & (Join-Path $script:consumerScripts "Run-Azd$Phase.ps1") -EnvironmentName 'down-test' -TenantId $f.Binding.tenantId -SubscriptionId $f.Binding.subscriptionId -ResourceGroupName 'rg-down-test' @Options
  }
  function Get-OfflineDownJournal {
    $f = $global:AdoDownFixture
    $s = Open-MaesterOwnershipJournal -ProjectRoot $f.Root -Binding $f.Binding -RequireExisting
    try { Get-MaesterOwnershipJournal -Session $s } finally { $s.Dispose() }
  }
  function Add-OfflineDownRecord {
    param($Session, [string]$Kind, [hashtable]$Expected, [hashtable]$ExactIds, [string]$Ownership = 'Created', [hashtable]$Before, [hashtable]$After, [string]$Parent, [string]$Key, [string]$SupersedesOperationId)
    $args = @{ Session = $Session; Key = $(if ($Key) { $Key } else { "$Kind`:$([guid]::NewGuid())" }); Kind = $Kind; PlanHash = ('a' * 64); Ownership = $Ownership; Expected = $Expected }
    if ($Before) { $args.Before = $Before }; if ($After) { $args.After = $After }; if ($Parent) { $args.CoveredByOperationId = $Parent }
    if ($SupersedesOperationId) { $args.SupersedesOperationId = $SupersedesOperationId }
    $record = Start-MaesterOwnedOperation @args
    Complete-MaesterOwnedOperation -Session $Session -OperationId $record.operationId -ExactIds $ExactIds | Out-Null
    $record.operationId
  }
  function Initialize-OfflineDownReceipts {
    param([switch]$Adopted, [switch]$SharedMutation, [switch]$Draft, [switch]$PipelineScopedPermissions, [switch]$StagedPublications)
    $f = $global:AdoDownFixture
    $f.PipelineScopedPermissions = [bool]$PipelineScopedPermissions
    $infraArgs = @{ ProjectRoot = $f.Root; EnvironmentName = 'down-test'; SolutionName = 'azure-devops'; TenantId = $f.Binding.tenantId; SubscriptionId = $f.Binding.subscriptionId; ResourceGroupName = 'rg-down-test' }
    Initialize-MaesterInfrastructureOwnership @infraArgs | Out-Null
    $f.Environment.MAESTER_INFRASTRUCTURE_OWNERSHIP_ID = $f.Group.tags['maester-ownership-id']
    Complete-MaesterInfrastructureOwnership @infraArgs | Out-Null
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null
    $session = Open-MaesterOwnershipJournal -ProjectRoot $f.Root -Binding $f.Binding
    try {
      if (-not $Adopted) {
        $repo = Add-OfflineDownRecord $session AdoRepository @{ organizationId = $f.Org; projectId = $f.Project; repositoryName = 'repo' } @{ repositoryId = $f.Repo }
        $endpoint = Add-OfflineDownRecord $session AdoServiceConnection @{ organizationId = $f.Org; projectId = $f.Project; serviceConnectionName = 'connection'; tenantId = $f.Binding.tenantId; subscriptionId = $f.Binding.subscriptionId; scope = $f.Binding.resourceGroupId; isShared = $false } @{ serviceConnectionId = $f.Endpoint }
        $null = Add-OfflineDownRecord $session EntraApplication @{ purpose = 'Runtime'; displayName = 'runtime-app'; creatorPrincipalId = $f.Creator } @{ applicationObjectId = $f.App; appId = $f.Client } -After @{ redirectUris = @(); identifierUris = @(); groupMembershipClaims = 'None'; enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false; signInAudience = 'AzureADMyOrg' }
        if ($Draft) {
          $f.Draft = $true
          foreach ($kind in @('Principal','Federation','Pipeline')) { $f.Present[$kind] = $false }
        } else {
        $null = Add-OfflineDownRecord $session EntraServicePrincipal @{ appId = $f.Client; creatorPrincipalId = $f.Creator } @{ servicePrincipalId = $f.Principal }
        $null = Add-OfflineDownRecord $session AdoServiceConnectionBinding @{ organizationId = $f.Org; projectId = $f.Project; serviceConnectionId = $f.Endpoint; applicationObjectId = $f.App; appId = $f.Client } @{ serviceConnectionId = $f.Endpoint } -Ownership Mutation -Parent $endpoint -Before @{ appId = ''; scope = $f.Binding.resourceGroupId; isDraft = $true; isReady = $true; issuer = $f.Issuer; subject = $f.Subject } -After @{ appId = $f.Client; scope = $f.Binding.resourceGroupId; isDraft = $false; isReady = $true; issuer = $f.Issuer; subject = $f.Subject }
        $publicationBefore = ''
        $preparation = ''
        if ($StagedPublications) {
          $publicationBefore = 'c' * 40
          $preparation = Add-OfflineDownRecord $session AdoRepositoryPublication @{ organizationId = $f.Org; projectId = $f.Project; repositoryId = $f.Repo; branch = 'refs/heads/main' } @{ repositoryId = $f.Repo; commitId = $publicationBefore } -Key "PreparationPublication:$($f.Repo):refs/heads/main" -Ownership Mutation -Parent $repo -Before @{ commitId = ''; files = @('azure-pipelines.yml') } -After @{ commitId = $publicationBefore; files = @('azure-pipelines.yml') }
        }
        $null = Add-OfflineDownRecord $session AdoPipeline @{ organizationId = $f.Org; projectId = $f.Project; repositoryId = $f.Repo; pipelineName = 'pipeline'; yamlPath = '/azure-pipelines.yml'; branch = 'refs/heads/main'; serviceConnectionId = $f.Endpoint } @{ pipelineId = '12'; pipelineRevision = '3' }
        foreach ($target in @(@{ type = 'endpoint'; id = $f.Endpoint; parent = $endpoint }, @{ type = 'repository'; id = "$($f.Project).$($f.Repo)"; parent = $repo })) {
          $expected = @{ organizationId = $f.Org; projectId = $f.Project; resourceType = $target.type; resourceId = $target.id }
          $after = @{ allPipelinesAuthorized = $true; pipelineIds = @() }
          if ($PipelineScopedPermissions) {
            $expected.pipelineId = '12'
            $after = @{ allPipelinesAuthorized = $false; pipelineIds = @('12') }
          }
          $null = Add-OfflineDownRecord $session AdoPipelineAuthorization $expected @{ resourceId = $target.id } -Ownership Mutation -Parent $target.parent -Before @{ allPipelinesAuthorized = $false; pipelineIds = @() } -After $after
        }
        $null = Add-OfflineDownRecord $session AdoRepositoryPublication @{ organizationId = $f.Org; projectId = $f.Project; repositoryId = $f.Repo; branch = 'refs/heads/main' } @{ repositoryId = $f.Repo; commitId = ('a' * 40) } -Key "Publication:$($f.Repo):refs/heads/main" -Ownership Mutation -Parent $repo -SupersedesOperationId $preparation -Before @{ commitId = $publicationBefore; files = @('azure-pipelines.yml') } -After @{ commitId = ('a' * 40); files = @('azure-pipelines.yml') }
        }
      }
      if (-not $Draft) { $null = Add-OfflineDownRecord $session FederatedIdentityCredential @{ applicationObjectId = $f.App; issuer = $f.Issuer; subject = $f.Subject; audiences = @('api://AzureADTokenExchange') } @{ federatedCredentialId = $f.Fic } }
      if ($SharedMutation) {
        $op = Add-OfflineDownRecord $session AdoPipelineAuthorization @{ organizationId = $f.Org; projectId = $f.Project; resourceType = 'endpoint'; resourceId = $f.Endpoint } @{ resourceId = $f.Endpoint } -Ownership Mutation -Before @{ allPipelinesAuthorized = $false; pipelineIds = @() } -After @{ allPipelinesAuthorized = $true; pipelineIds = @() }
      }
    } finally { $session.Dispose() }
    $f.Deletes.Clear(); $f.Reads.Clear()
  }
}
Describe 'Actual Azure DevOps down wrappers with stateful offline providers' {
  BeforeEach {
    $root = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
    Copy-Item -LiteralPath (Join-Path $script:consumerRoot 'infra') -Destination $root -Recurse
    $tenant = '11111111-1111-4111-8111-111111111111'; $subscription = '22222222-2222-4222-8222-222222222222'
    $group = "/subscriptions/$subscription/resourceGroups/rg-down-test"
    $global:AdoDownFixture = @{
      Root = $root; ScriptsRoot = $script:consumerScripts; Org = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; Project = '33333333-3333-4333-8333-333333333333'
      Repo = '44444444-4444-4444-8444-444444444444'; Endpoint = '55555555-5555-4555-8555-555555555555'
      Client = '66666666-6666-4666-8666-666666666666'; App = '77777777-7777-4777-8777-777777777777'; Principal = '88888888-8888-4888-8888-888888888888'
      Fic = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; Creator = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
      Issuer = 'https://vstoken.dev.azure.com/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; Subject = 'sc://org/project/connection'
      Binding = @{ environmentName = 'down-test'; solutionName = 'azure-devops'; tenantId = $tenant; subscriptionId = $subscription; resourceGroupId = $group; setupClientId = '99999999-9999-4999-8999-999999999999'; organizationName = 'org'; organizationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; projectName = 'project'; projectId = '33333333-3333-4333-8333-333333333333'; adoOrganizationUrl = 'https://dev.azure.com/org'; adoProjectId = '33333333-3333-4333-8333-333333333333' }
      Environment = @{ AZURE_ENV_NAME = 'down-test'; AZURE_TENANT_ID = $tenant; AZURE_SUBSCRIPTION_ID = $subscription; AZURE_RESOURCE_GROUP = 'rg-down-test'; AZURE_LOCATION = 'westeurope'; MAESTER_OWNED_RESOURCE_IDS = ('["' + "$group/providers/Microsoft.Storage/storageAccounts/storage" + '"]'); MAESTER_OWNED_LOCK_IDS = '[]' }
      Group = $null; ArmPresent = $false; Present = @{ Repository = $true; Endpoint = $true; Application = $true; Principal = $true; Federation = $true; Pipeline = $true; SetupClient = $true }
      Deletes = [Collections.Generic.List[string]]::new(); Reads = [Collections.Generic.List[string]]::new(); FailDeleteKind = ''; ForeignPipeline = $false; UnrelatedProjectPipeline = $false; ChangedRepo = $false; GraphSessions = 0; Draft = $false
      PipelineScopedPermissions = $false; EndpointAuthorizedPipelineIds = @('12'); RepositoryAuthorizedPipelineIds = @('12'); RetainDeletedPipelinePermissions = $false; CurrentCommit = ('a' * 40)
    }
    $script:savedAmbient = @{}
    foreach ($name in @('AZURE_ENV_NAME','AZURE_TENANT_ID','AZURE_SUBSCRIPTION_ID','AZURE_RESOURCE_GROUP','CI','AZD_NON_INTERACTIVE')) { $script:savedAmbient[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }
    Mock Split-Path { $global:AdoDownFixture.Root } -ParameterFilter { $Parent -and [string]$Path -ceq $global:AdoDownFixture.ScriptsRoot }
    Mock Write-Host {}
    Mock Write-Host -ModuleName Maester-PreDownCleanup {}
    Mock Get-MaesterInfrastructureEnvironment -ModuleName Maester-InfrastructureOwnership { $global:AdoDownFixture.Environment }
    Mock Set-MaesterInfrastructureResourceGroup -ModuleName Maester-InfrastructureOwnership {}
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-InfrastructureOwnership { @{ id = $SubscriptionId; tenantId = $TenantId; state = 'Enabled' } }
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-PreDownCleanup { @{ id = $SubscriptionId; tenantId = $TenantId; state = 'Enabled' } }
    Mock Invoke-MaesterInfrastructureArm -ModuleName Maester-InfrastructureOwnership {
      param($Context, $Method, $Path, $Body)
      $f = $global:AdoDownFixture
      if ($Method -eq 'PUT') { $f.Group = @{ id = $Context.binding.resourceGroupId; tags = $Body.tags; properties = @{ provisioningState = 'Succeeded' } }; $f.ArmPresent = $true; return @{ StatusCode = 201; Value = $f.Group } }
      if ($Method -ne 'GET') { throw 'Unexpected infrastructure mutation.' }
      if ($Path -like '*/resources?*') { return @{ StatusCode = 200; Value = @{ value = @(@{ id = "$($f.Binding.resourceGroupId)/providers/Microsoft.Storage/storageAccounts/storage" }) } } }
      if ($Path -like '*/Microsoft.Authorization/locks?*') { return @{ StatusCode = 200; Value = @{ value = @() } } }
      @{ StatusCode = $(if ($f.ArmPresent) { 200 } else { 404 }); Value = $f.Group }
    }
    Mock Invoke-MaesterCleanupArmRequest -ModuleName Maester-PreDownCleanup {
      param($Binding, $Method, $ResourceId)
      $f = $global:AdoDownFixture; $f.Reads.Add("ARM:$ResourceId")
      if ($Method -ne 'GET') { throw 'Unexpected ARM cleanup mutation.' }
      if ($ResourceId -like '*/Microsoft.Authorization/roleAssignments') { return @{ StatusCode = 200; Value = @{ value = @() } } }
      @{ StatusCode = $(if ($f.ArmPresent) { 200 } else { 404 }); Value = $f.Group }
    }
    Mock Initialize-MaesterCleanupGraph -ModuleName Maester-PreDownCleanup {
      $f = $global:AdoDownFixture; $f.GraphSessions++
      @{ clientIds = @($f.Binding.setupClientId); objectIds = @() }
    }
    Mock Test-MaesterCleanupCanPrompt -ModuleName Maester-PreDownCleanup { $true }
    Mock Read-Host -ModuleName Maester-PreDownCleanup { '' }
    Mock Start-Sleep -ModuleName Maester-PreDownCleanup { throw 'Unexpected retry delay; offline deletes should read absent immediately.' }
    Mock Invoke-MaesterCleanupGraphRequest -ModuleName Maester-PreDownCleanup {
      param($Binding, $Method, $Path)
      $f = $global:AdoDownFixture; $f.Reads.Add("Graph:$Method`:$Path")
      $kind = if ($Path -like "*/federatedIdentityCredentials/$($f.Fic)*") { 'Federation' } elseif ($Path -like "/v1.0/applications/$($f.App)*" -and $Path -notlike '*/owners?*' -and $Path -notlike '*/federatedIdentityCredentials') { 'Application' } elseif ($Path -like "/v1.0/servicePrincipals/$($f.Principal)*" -and $Path -notmatch '/(owners|memberOf|ownedObjects|appRoleAssignments|appRoleAssignedTo)(\?|$)') { 'Principal' } else { '' }
      if ($kind) {
        if ($Method -eq 'DELETE') { $f.Deletes.Add($kind); if ($f.FailDeleteKind -eq $kind) { throw "Synthetic $kind delete failure" }; $f.Present[$kind] = $false; return @{ StatusCode = 204; Value = $null } }
        if (-not $f.Present[$kind]) { return @{ StatusCode = 404; Value = $null } }
        $value = switch ($kind) {
          Federation { @{ id = $f.Fic; issuer = $f.Issuer; subject = $f.Subject; audiences = @('api://AzureADTokenExchange') } }
          Application { @{ id = $f.App; appId = $f.Client; displayName = 'runtime-app'; passwordCredentials = @(); keyCredentials = @(); signInAudience = 'AzureADMyOrg'; groupMembershipClaims = $null; web = @{ redirectUris = @(); implicitGrantSettings = @{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false } }; identifierUris = @() } }
          Principal { @{ id = $f.Principal; appId = $f.Client; appOwnerOrganizationId = $f.Binding.tenantId; passwordCredentials = @(); keyCredentials = @() } }
        }
        return @{ StatusCode = 200; Value = $value }
      }
      if ($Method -ne 'GET') { throw "Unexpected Graph mutation $Path" }
      $values = @()
      if ($Path -like '*/owners?*') { $values = @(@{ id = $f.Creator }) }
      elseif ($Path -like '*/federatedIdentityCredentials') { if ($f.Present.Federation) { $values = @(@{ id = $f.Fic }) } }
      elseif ($Path -match '^/v1[.]0/servicePrincipals[?]') { if ($f.Present.Principal) { $values = @(@{ id = $f.Principal; appId = $f.Client }) } }
      elseif ($Path -notmatch '/(memberOf|ownedObjects|appRoleAssignments|appRoleAssignedTo|oauth2PermissionGrants|roleAssignments)(\?|$)') { throw "Unexpected Graph inventory $Path" }
      @{ StatusCode = 200; Value = @{ value = $values } }
    }
    Mock Invoke-MaesterCleanupAdoRequest -ModuleName Maester-PreDownCleanup {
      param($Binding, $Method, $Path)
      $f = $global:AdoDownFixture; $f.Reads.Add("ADO:$Method`:$Path")
      if ($Binding.adoOrganizationUrl -cne 'https://dev.azure.com/org') { throw 'Wrong ADO organization transport binding.' }
      if ($Path -like '/_apis/connectionData?*') { return @{ StatusCode = 200; Value = @{ instanceId = $f.Org } } }
      if ($Path -like '/_apis/projects/*') { return @{ StatusCode = 200; Value = @{ id = $f.Project } } }
      $kind = if ($Path -match '/build/definitions/12\?') { 'Pipeline' } elseif ($Path -match '/serviceendpoint/endpoints/[^/]+\?') { 'Endpoint' } elseif ($Path -match '/git/repositories/[^/]+\?') { 'Repository' } else { '' }
      if ($kind) {
        if ($Method -eq 'DELETE') {
          $f.Deletes.Add($kind)
          if ($f.FailDeleteKind -eq $kind) { throw "Synthetic $kind delete failure" }
          $f.Present[$kind] = $false
          # Model both provider outcomes explicitly: permission inventories can
          # omit the removed pipeline or retain a stale entry that must block.
          if ($kind -eq 'Pipeline' -and -not $f.RetainDeletedPipelinePermissions) {
            $f.EndpointAuthorizedPipelineIds = @($f.EndpointAuthorizedPipelineIds | Where-Object { $_ -cne '12' })
            $f.RepositoryAuthorizedPipelineIds = @($f.RepositoryAuthorizedPipelineIds | Where-Object { $_ -cne '12' })
          }
          return @{ StatusCode = 204; Value = $null }
        }
        if (-not $f.Present[$kind]) { return @{ StatusCode = 404; Value = $null } }
        $value = switch ($kind) {
          Pipeline { @{ id = 12; name = 'pipeline'; revision = 3; project = @{ id = $f.Project }; repository = @{ id = $f.Repo; defaultBranch = 'refs/heads/main' }; process = @{ yamlFilename = '/azure-pipelines.yml' } } }
          Repository { @{ id = $f.Repo; name = 'repo'; project = @{ id = $f.Project } } }
          Endpoint { @{ id = $f.Endpoint; name = 'connection'; type = 'AzureRM'; url = 'https://management.azure.com/'; isShared = $false; isReady = $true; data = @{ subscriptionId = $f.Binding.subscriptionId; isDraft = $f.Draft }; authorization = @{ scheme = 'WorkloadIdentityFederation'; parameters = @{ tenantid = $f.Binding.tenantId; serviceprincipalid = $(if ($f.Draft) { '' } else { $f.Client }); scope = $f.Binding.resourceGroupId; workloadIdentityFederationIssuer = $f.Issuer; workloadIdentityFederationSubject = $f.Subject } }; serviceEndpointProjectReferences = @(@{ projectReference = @{ id = $f.Project } }) } }
        }
        return @{ StatusCode = 200; Value = $value }
      }
      if ($Method -ne 'GET') { throw "Unexpected ADO mutation $Path" }
      if ($Path -like '*/pipelinepermissions/*') {
        $pipelines = @()
        if ($f.PipelineScopedPermissions) {
          $ids = if ($Path -like '*/pipelinepermissions/endpoint/*') { $f.EndpointAuthorizedPipelineIds } else { $f.RepositoryAuthorizedPipelineIds }
          $pipelines = @($ids | ForEach-Object { @{ id = [int]$_; authorized = $true } })
        }
        return @{ StatusCode = 200; Value = @{ allPipelines = @{ authorized = (-not $f.Draft -and -not $f.PipelineScopedPermissions) }; pipelines = $pipelines } }
      }
      $values = @()
      if ($Path -like '*/refs?*') { if (-not $f.Draft) { $values = @(@{ name = 'refs/heads/main'; objectId = $(if ($f.ChangedRepo) { 'b' * 40 } else { $f.CurrentCommit }) }) } }
      elseif ($Path -like '*/build/definitions?*') {
        if ($f.Present.Pipeline) { $values += @{ id = 12 } }
        if ($f.ForeignPipeline -or ($f.UnrelatedProjectPipeline -and $Path -notlike '*repositoryId=*')) { $values += @{ id = 77 } }
      }
      elseif ($Path -notlike '*/pullrequests?*') { throw "Unexpected ADO inventory $Path" }
      @{ StatusCode = 200; Value = @{ value = $values } }
    }
    Mock Invoke-RestMethod { throw 'Network tripwire.' }
    Mock Invoke-WebRequest { throw 'Network tripwire.' }
  }
  AfterEach {
    foreach ($name in $script:savedAmbient.Keys) { [Environment]::SetEnvironmentVariable($name, $script:savedAmbient[$name]) }
    Remove-Variable AdoDownFixture -Scope Global
  }

  It 'runs real predown read-only, then exact approved postdown deletes only owned objects and is idempotent' {
    Initialize-OfflineDownReceipts
    $f = $global:AdoDownFixture
    $before = Get-OfflineDownJournal | ConvertTo-Json -Depth 30
    (Invoke-OfflineAdoDown PreDown @{ PlanOnly = $true; InteractiveConsent = $true }).ExternalDeletionAttempted | Should -BeFalse
    $f.Deletes.Count | Should -Be 0
    $f.GraphSessions | Should -Be 0
    (Get-OfflineDownJournal | ConvertTo-Json -Depth 30) | Should -BeExactly $before
    $f.ArmPresent = $false
    $plan = Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true }
    $plan.Entries.Count | Should -Be 10
    (Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = $plan.PlanHash }).Completed | Should -BeTrue
    $f.Deletes | Should -Be @('Federation','Pipeline','Endpoint','Repository','Principal','Application')
    $f.Present.SetupClient | Should -BeTrue
    @((Get-OfflineDownJournal).records | Where-Object state -ne deleted).Count | Should -Be 0
    (Invoke-OfflineAdoDown PostDown).Completed | Should -BeTrue
    $f.Deletes.Count | Should -Be 6
  }
  It 'stops an interactive predown request in CI before lock or cleanup changes' {
    Initialize-OfflineDownReceipts
    $f = $global:AdoDownFixture
    $readsBefore = $f.Reads.Count
    $savedCi = [Environment]::GetEnvironmentVariable('CI')
    try {
      [Environment]::SetEnvironmentVariable('CI', 'true')
      { Invoke-OfflineAdoDown PreDown @{ InteractiveConsent = $true } } | Should -Throw '*this process cannot prompt*Down stopped before changing owned locks or Azure resources*'
    } finally { [Environment]::SetEnvironmentVariable('CI', $savedCi) }
    $f.Deletes.Count | Should -Be 0
    $f.GraphSessions | Should -Be 0
    $f.Reads.Count | Should -Be $readsBefore
  }
  It 'refuses direct postdown while Azure still exists before Graph authentication or delete' {
    Initialize-OfflineDownReceipts
    { Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = ('a' * 64) } } | Should -Throw '*still exists*'
    $global:AdoDownFixture.Deletes.Count | Should -Be 0
    $global:AdoDownFixture.GraphSessions | Should -Be 0
  }
  It 'cleans an interrupted first bootstrap stage with an unchanged unbound ready draft endpoint' {
    Initialize-OfflineDownReceipts -Draft
    $f = $global:AdoDownFixture; $f.ArmPresent = $false
    $plan = Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true }
    $plan.Entries.Count | Should -Be 3
    (Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = $plan.PlanHash }).Completed | Should -BeTrue
    $f.Deletes | Should -Be @('Endpoint','Repository','Application')
    $f.Present.SetupClient | Should -BeTrue
  }
  It 'blocks both actual wrappers when an external-setup marker survives a missing setup journal' {
    Initialize-OfflineDownReceipts -Adopted
    $f = $global:AdoDownFixture
    Remove-Item -LiteralPath (Join-Path $f.Root '.azure/down-test/maester-setup-ownership.json')
    { Invoke-OfflineAdoDown PreDown } | Should -Throw '*ownership journal is missing*'
    $f.ArmPresent = $false
    { Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true } } | Should -Throw '*ownership journal is missing*'
    $f.Deletes.Count | Should -Be 0
    $f.GraphSessions | Should -Be 0
  }
  It 'preserves all remote state for omitted approval, default-No cancellation and stale approval' {
    Initialize-OfflineDownReceipts
    $f = $global:AdoDownFixture; $f.ArmPresent = $false
    { Invoke-OfflineAdoDown PostDown } | Should -Throw '*Explicit cleanup approval*'
    { Invoke-OfflineAdoDown PostDown @{ InteractiveConsent = $true; AllowInteractiveGraphLogin = $true } } | Should -Throw '*not approved*'
    { Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = ('0' * 64) } } | Should -Throw '*hash is stale*'
    $f.Deletes.Count | Should -Be 0
    @((Get-OfflineDownJournal).records | Where-Object state -ne applied).Count | Should -Be 0
  }
  It 'preserves adopted parents and their existing all-pipeline permission while deleting only a new owned FIC' {
    Initialize-OfflineDownReceipts -Adopted
    $f = $global:AdoDownFixture; $f.ArmPresent = $false
    $plan = Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true }
    (Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = $plan.PlanHash }).Completed | Should -BeTrue
    $f.Deletes | Should -Be @('Federation')
    foreach ($kind in @('Repository','Endpoint','Application','Principal','Pipeline','SetupClient')) { $f.Present[$kind] | Should -BeTrue }
  }
  It 'blocks adopted shared authorization mutations instead of silently claiming restoration' {
    Initialize-OfflineDownReceipts -Adopted -SharedMutation
    { Invoke-OfflineAdoDown PreDown } | Should -Throw '*shared mutation*'
    $global:AdoDownFixture.ArmPresent = $false
    { Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = ('a' * 64) } } | Should -Throw '*shared mutation*'
    $global:AdoDownFixture.Deletes.Count | Should -Be 0
  }
  It 'cleans exact owned pipeline permissions on owned parents despite unrelated project pipelines' {
    Initialize-OfflineDownReceipts -PipelineScopedPermissions
    $f = $global:AdoDownFixture; $f.UnrelatedProjectPipeline = $true
    (Invoke-OfflineAdoDown PreDown).ExternalDeletionAttempted | Should -BeFalse
    $f.Deletes.Count | Should -Be 0
    $f.ArmPresent = $false
    $plan = Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true }
    $permissions = @((Get-OfflineDownJournal).records | Where-Object kind -eq AdoPipelineAuthorization)
    $permissions.Count | Should -Be 2
    foreach ($permission in $permissions) {
      $permission.expected.pipelineId | Should -BeExactly '12'
      $permission.after.allPipelinesAuthorized | Should -BeFalse
      $permission.after.pipelineIds | Should -Be @('12')
    }
    (Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = $plan.PlanHash }).Completed | Should -BeTrue
    $f.Deletes | Should -Be @('Federation','Pipeline','Endpoint','Repository','Principal','Application')
    $f.UnrelatedProjectPipeline | Should -BeTrue
    @($f.Reads | Where-Object { $_ -like 'ADO:GET:*/build/definitions?api-version=*' }).Count | Should -Be 0
    @((Get-OfflineDownJournal).records | Where-Object state -ne deleted).Count | Should -Be 0
  }
  It 'blocks foreign authorized pipeline IDs on an owned <_> before deleting anything' -ForEach @('endpoint','repository') {
    Initialize-OfflineDownReceipts -PipelineScopedPermissions
    $f = $global:AdoDownFixture; $f.ArmPresent = $false; $f.UnrelatedProjectPipeline = $true
    if ($_ -eq 'endpoint') { $f.EndpointAuthorizedPipelineIds += '77' } else { $f.RepositoryAuthorizedPipelineIds += '77' }
    { Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true } } | Should -Throw "*unrecorded $_-authorized pipeline '77'*"
    $f.Deletes.Count | Should -Be 0
    @((Get-OfflineDownJournal).records | Where-Object state -ne applied).Count | Should -Be 0
  }
  It 'retains owned parents and permission receipts if a deleted pipeline remains in permission inventories' {
    Initialize-OfflineDownReceipts -PipelineScopedPermissions
    $f = $global:AdoDownFixture; $f.ArmPresent = $false; $f.RetainDeletedPipelinePermissions = $true
    $plan = Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true }
    { Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = $plan.PlanHash } } | Should -Throw "*unrecorded endpoint-authorized pipeline '12'*"
    $f.Deletes | Should -Be @('Federation','Pipeline')
    $f.Present.Endpoint | Should -BeTrue
    $f.Present.Repository | Should -BeTrue
    $records = (Get-OfflineDownJournal).records
    ($records | Where-Object kind -eq AdoPipeline).state | Should -BeExactly deleted
    @($records | Where-Object { $_.kind -eq 'AdoPipelineAuthorization' -and $_.state -eq 'applied' }).Count | Should -Be 2
  }
  It 'retains preparation and final publication receipts and cleans their owned repository at the terminal commit' {
    Initialize-OfflineDownReceipts -PipelineScopedPermissions -StagedPublications
    $f = $global:AdoDownFixture; $f.ArmPresent = $false
    $publications = @((Get-OfflineDownJournal).records | Where-Object kind -eq AdoRepositoryPublication)
    $publications.Count | Should -Be 2
    $preparation = $publications | Where-Object key -like 'PreparationPublication:*'
    $scheduled = $publications | Where-Object key -like 'Publication:*'
    $preparation.after.commitId | Should -BeExactly ('c' * 40)
    $preparation.exactIds.commitId | Should -BeExactly ('c' * 40)
    $scheduled.before.commitId | Should -BeExactly $preparation.after.commitId
    $scheduled.after.commitId | Should -BeExactly ('a' * 40)
    $scheduled.exactIds.commitId | Should -BeExactly ('a' * 40)
    $scheduled.supersedesOperationId | Should -BeExactly $preparation.operationId
    $plan = Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true }
    @($plan.Entries | Where-Object kind -eq AdoRepositoryPublication).Count | Should -Be 2
    @((Get-OfflineDownJournal).records | Where-Object { $_.kind -eq 'AdoRepositoryPublication' -and $_.state -eq 'applied' }).Count | Should -Be 2
    (Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = $plan.PlanHash }).Completed | Should -BeTrue
    $f.Deletes | Should -Be @('Federation','Pipeline','Endpoint','Repository','Principal','Application')
    @((Get-OfflineDownJournal).records | Where-Object { $_.kind -eq 'AdoRepositoryPublication' -and $_.state -eq 'deleted' }).Count | Should -Be 2
  }
  It 'preserves an owned repository when its linked publication branch is at a <_> commit' -ForEach @('foreign','superseded') {
    Initialize-OfflineDownReceipts -PipelineScopedPermissions -StagedPublications
    $f = $global:AdoDownFixture; $f.ArmPresent = $false
    $f.CurrentCommit = if ($_ -eq 'foreign') { 'b' * 40 } else { 'c' * 40 }
    { Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true } } | Should -Throw '*preserving user work*'
    $f.Deletes.Count | Should -Be 0
    $f.Present.Repository | Should -BeTrue
    @((Get-OfflineDownJournal).records | Where-Object { $_.kind -eq 'AdoRepositoryPublication' -and $_.state -eq 'applied' }).Count | Should -Be 2
  }
  It 'retains partial cleanup receipts and retries only remaining exact objects with a fresh approval' {
    Initialize-OfflineDownReceipts
    $f = $global:AdoDownFixture; $f.ArmPresent = $false
    $plan = Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true }
    $f.FailDeleteKind = 'Endpoint'
    { Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = $plan.PlanHash } } | Should -Throw '*external cleanup is incomplete*'
    $records = (Get-OfflineDownJournal).records
    ($records | Where-Object kind -eq FederatedIdentityCredential).state | Should -BeExactly deleted
    ($records | Where-Object kind -eq AdoPipeline).state | Should -BeExactly deleted
    ($records | Where-Object kind -eq AdoServiceConnection).state | Should -BeExactly deleting
    $f.FailDeleteKind = ''
    $retry = Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true }
    $retry.PlanHash | Should -Not -BeExactly $plan.PlanHash
    (Invoke-OfflineAdoDown PostDown @{ ApprovedPlanHash = $retry.PlanHash }).Completed | Should -BeTrue
    @($f.Deletes | Where-Object { $_ -eq 'Federation' }).Count | Should -Be 1
    @($f.Deletes | Where-Object { $_ -eq 'Pipeline' }).Count | Should -Be 1
    @((Get-OfflineDownJournal).records | Where-Object state -ne deleted).Count | Should -Be 0
  }
  It 'preserves foreign project pipeline dependencies or concurrent repository commits: <_>' -ForEach @('pipeline','repository') {
    Initialize-OfflineDownReceipts
    $f = $global:AdoDownFixture; $f.ArmPresent = $false
    if ($_ -eq 'pipeline') { $f.ForeignPipeline = $true } else { $f.ChangedRepo = $true }
    $expected = if ($_ -eq 'pipeline') { '*unrecorded*' } else { '*preserving user work*' }
    { Invoke-OfflineAdoDown PostDown @{ PlanOnly = $true } } | Should -Throw $expected
    $f.Deletes.Count | Should -Be 0
  }
}
