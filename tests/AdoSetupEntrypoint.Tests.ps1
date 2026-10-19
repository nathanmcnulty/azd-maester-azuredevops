# Offline integration: execute production entrypoint statements, retaining the
# real target resolver and both planners. Provider boundaries never authenticate
# or contact Azure/Graph/ADO; unexpected network/CLI requests fail closed.
Describe 'Azure DevOps setup entrypoint and reviewed planner integration (offline)' {
  BeforeAll {
    $script:entryRoot = Split-Path $PSScriptRoot -Parent
    $script:entryScripts = Join-Path $script:entryRoot 'scripts'
    Import-Module (Join-Path $script:entryScripts 'vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1') -Force
    Import-Module (Join-Path $script:entryScripts 'vendor/Azd.MaesterHooks/Maester-ConsentPlan.psm1') -Force
    Import-Module (Join-Path $script:entryScripts 'Maester-AdoBootstrap.psm1') -Force
    Import-Module (Join-Path $script:entryScripts 'Maester-SetupConsent.psm1') -Force
    $script:entryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:entryScripts 'Setup-PostDeploy.ps1'), [ref]$null, [ref]$null)
    # Load unchanged helper definitions first, so script-local functions can be
    # mocked rather than shadowing Pester mocks when the entrypoint executes.
    $definitions = @($script:entryAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
    . ([scriptblock]::Create($definitions.Extent.Text -join "`n"))
    $main = @($script:entryAst.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] })
    # All actual parameter binding, guards, imports, resolver dot-source,
    # rendering, planning, application and early returns remain unchanged.
    $script:entryMain = [scriptblock]::Create($script:entryAst.ParamBlock.Extent.Text + "`n" +
      '$PSScriptRoot = $global:AdoEntrypointFixture.ScriptsRoot' + "`n" + ($main.Extent.Text -join "`n"))

    function Get-AzContext { $global:AdoEntrypointFixture.Context }
    function Connect-AzAccount { param($AccessToken, $AccountId, $Tenant, $Subscription, [switch]$SkipContextPopulation) throw 'Unmocked authentication tripwire.' }
    function Get-AzAccessToken { param($ResourceUrl, $TenantId) throw 'Unmocked token tripwire.' }
    function Invoke-AzRestMethod { param($Method, $Path) throw 'Unmocked ARM tripwire.' }
    function Connect-ADOPS { param($Organization, $OAuthToken, [switch]$SkipVerification) throw 'Unmocked ADOPS tripwire.' }
    function Get-ADOPSPipeline { param($Project, $Organization, $Name) throw 'Unmocked pipeline read tripwire.' }
    function New-ADOPSPipeline { param($Project, $Name, $Repository, $YamlPath, $Organization) throw 'Unmocked pipeline write tripwire.' }
    function Start-ADOPSPipeline { param($Project, $Name, $Branch, $Organization) throw 'Unmocked pipeline run tripwire.' }
    function Invoke-ADOPSRestMethod { param($Method, $Uri, $Body, $ContentType) throw 'Unmocked ADOPS HTTP tripwire.' }
    function Invoke-GraphRestRequest { throw 'Unmocked Graph tripwire.' }

    function global:az {
      $f = $global:AdoEntrypointFixture; $global:LASTEXITCODE = 0
      $f.Events.Add("az:$($args -join ' ')")
      if ($args[0] -eq 'rest' -and $args[2] -eq 'get') { return ($f.SubscriptionMetadata | ConvertTo-Json -Compress) }
      if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
        if ('--subscription' -notin $args -and '--tenant' -notin $args) { throw 'Unscoped token request.' }
        return (@{ accessToken = 'offline-token'; tenant = $f.Tenant; subscription = $f.Subscription } | ConvertTo-Json -Compress)
      }
      if (($args -join ' ') -like 'account show *--query user.name*') { return 'operator@example.test' }
      throw "Unexpected offline az invocation: $($args -join ' ')"
    }
    function global:azd {
      $f = $global:AdoEntrypointFixture; $global:LASTEXITCODE = 0
      if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') { return ($f.Environment | ConvertTo-Json -Compress) }
      if ($args[0] -eq 'env' -and $args[1] -eq 'set') {
        if ($args[2] -cne '-e' -or $args[3] -cne 'offline') { throw 'Environment writes must name the exact reviewed environment.' }
        $f.Writes.Add([pscustomobject]@{ provider = 'azd'; uri = ($args -join ' '); body = $null })
        $f.Environment[[string]$args[4]] = [string]$args[5]; return
      }
      throw "Unexpected offline azd invocation: $($args -join ' ')"
    }
    function global:git { throw 'No real git may run in offline setup tests.' }
    function global:Invoke-AdoEntrypointGraphFixture {
      param($Method, $Uri, $Body)
      $f = $global:AdoEntrypointFixture
      $f.Events.Add("Graph:$Method`:$Uri")
      if ($Method -ne 'GET') {
        $f.Writes.Add([pscustomobject]@{ provider = 'Graph'; uri = $Uri; body = $Body })
        if ($Uri -ceq 'https://graph.microsoft.com/v1.0/applications') { $f.Application = $f.NewApplication; return $f.Application }
        if ($Uri -ceq 'https://graph.microsoft.com/v1.0/servicePrincipals') { $f.Principal = $f.NewPrincipal; return $f.Principal }
        if ($Uri -like '*/federatedIdentityCredentials') { $f.Federations = @($f.NewFederation); return $f.NewFederation }
        return [pscustomobject]@{ id = 'created-graph-assignment' }
      }
      if ($Uri -like '*/me?*') { return [pscustomobject]@{ id = $f.Operator; userPrincipalName = 'operator@example.test' } }
      if ($Uri.StartsWith('https://graph.microsoft.com/v1.0/applications?')) { return [pscustomobject]@{ value = @($f.Application | Where-Object { $_ }) } }
      if ($Uri.StartsWith('https://graph.microsoft.com/v1.0/servicePrincipals?')) { return [pscustomobject]@{ value = @($f.Principal | Where-Object { $_ }) } }
      if ($Uri -like '*/federatedIdentityCredentials?*') { return [pscustomobject]@{ value = @($f.Federations) } }
      if ($Uri -like '*/appRoleAssignments?*') { return [pscustomobject]@{ value = @() } }
      if ($Uri -like '*/roleManagement/directory/roleAssignments?*') { return [pscustomobject]@{ value = @() } }
      if ($Uri -like '*/roleManagement/directory/roleDefinitions?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'teams-reader'; displayName = 'Teams Reader'; isBuiltIn = $true }) } }
      throw "Unexpected offline Graph request: $Method $Uri"
    }
    function global:Invoke-AdoEntrypointAdoFixture {
      param($Method = 'GET', $Uri, $Body)
      $f = $global:AdoEntrypointFixture; $f.Events.Add("ADO:$Method`:$Uri")
      if ($Method -ne 'GET') {
        $f.Writes.Add([pscustomobject]@{ provider = 'ADO'; uri = $Uri; body = $Body })
        if ($Uri.Contains('/git/repositories?')) { $f.Repository = $f.NewRepository; return $f.Repository }
        if ($Uri.Contains('/serviceendpoint/endpoints?')) {
          $f.Endpoint = $f.NewEndpoint | ConvertTo-Json -Depth 30 | ConvertFrom-Json
          $f.Endpoint.authorization.parameters.serviceprincipalid = ''; $f.Endpoint.data.isDraft = $true
          return $f.Endpoint
        }
        if ($Uri -like '*/serviceendpoint/endpoints/*') { $f.Endpoint = $Body | ConvertTo-Json -Depth 30 | ConvertFrom-Json; return $f.Endpoint }
        if ($Uri -like '*/pipelinePermissions/*') { $f.Authorized[$Uri] = $true; return [pscustomobject]@{ id = 'authorization'; allPipelines = @{ authorized = $true } } }
        throw "Unexpected offline ADO write: $Method $Uri"
      }
      if ($Uri -ceq 'https://dev.azure.com/org/_apis/connectionData?api-version=7.1-preview.1') { return [pscustomobject]@{ instanceId = $f.OrganizationId } }
      if ($Uri -like '*/projects/project?*') { return $f.Project }
      if ($Uri.Contains('/git/repositories?')) { return [pscustomobject]@{ value = @($f.Repository | Where-Object { $_ }) } }
      if ($Uri.Contains('/serviceendpoint/endpoints?')) { return [pscustomobject]@{ value = @($f.Endpoint | Where-Object { $_ }) } }
      if ($Uri -like '*/pipelinePermissions/*') { return [pscustomobject]@{ allPipelines = @{ authorized = ($f.FullyGranted -or [bool]$f.Authorized[$Uri]) }; pipelines = @() } }
      if ($Uri.Contains('/build/definitions?')) { return [pscustomobject]@{ value = @($f.Pipeline | Where-Object { $_ }) } }
      if ($Uri -like '*/build/definitions/*') {
        $f.DefinitionReads++
        if ($f.MutateDefinitionAt -gt 0 -and $f.DefinitionReads -ge $f.MutateDefinitionAt) { $f.Pipeline.revision++ }
        return $f.Pipeline
      }
      if ($Uri -like '*/refs?*') {
        $f.BranchReads++
        $head = if ($f.DriftBranchAt -gt 0 -and $f.BranchReads -ge $f.DriftBranchAt) { 'b' * 40 } else { $f.BranchHead }
        return [pscustomobject]@{ value = @([pscustomobject]@{ name = "refs/heads/$($f.Branch)"; objectId = $head }) }
      }
      throw "Unexpected offline ADO read: $Uri"
    }
    function Invoke-OfflineAdoEntrypoint {
      param([hashtable]$Overrides = @{}, [switch]$ActualFile)
      $parameters = @{
        SubscriptionId = $global:AdoEntrypointFixture.Subscription; TenantId = $global:AdoEntrypointFixture.Tenant
        EnvironmentName = 'offline'; ResourceGroupName = 'rg-offline'; AdoOrganization = 'org'; AdoProject = 'project'
        AdoRepositoryName = 'repo'; AdoPipelineName = 'pipeline'; AdoServiceConnectionName = 'connection'
      }
      foreach ($key in $Overrides.Keys) { $parameters[$key] = $Overrides[$key] }
      if ($ActualFile) { & (Join-Path $script:entryScripts 'Setup-PostDeploy.ps1') @parameters }
      else { & $script:entryMain @parameters }
    }
    function Assert-NoAdoEntrypointWrites {
      $global:AdoEntrypointFixture.Writes.Count | Should -Be 0
      $global:AdoEntrypointFixture.GraphApplied.Count | Should -Be 0
      Should -Invoke Push-RepositoryFiles -Times 0 -Exactly
      Should -Invoke New-ADOPSPipeline -Times 0 -Exactly
      Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
    }
    InModuleScope Maester-AdoBootstrap {
      function script:Invoke-GraphRestRequest { }
      function script:Get-MaesterGraphSetupClientId { $env:MAESTER_SETUP_CLIENT_ID }
    }
    InModuleScope Maester-SetupConsent { function script:Invoke-GraphRestRequest { } }
    $script:grantFixture = Join-Path $TestDrive 'Grant-EntrypointFixture.ps1'
    Set-Content $script:grantFixture @'
param($TenantId, $PrincipalObjectId, $PermissionProfile, $IncludeMailSend, $IncludeReportSettingsWrite,
  $TargetType, $ExpectedApplicationId, $ExpectedApplicationObjectId, $ExpectedFederatedCredentialIssuer,
  $ExpectedFederatedCredentialSubject, [switch]$Apply, $ApprovedPlanHash)
$details = @{ profile = $PermissionProfile; mail = $IncludeMailSend; reportSettingsWrite = $IncludeReportSettingsWrite
  targetType = $TargetType; applicationId = $ExpectedApplicationId; applicationObjectId = $ExpectedApplicationObjectId
  issuer = $ExpectedFederatedCredentialIssuer; subject = $ExpectedFederatedCredentialSubject }
$missing = @(); if (-not $global:AdoEntrypointFixture.FullyGranted) { $missing = @('Directory.Read.All') }
$plan = New-MaesterConsentPlan -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId -Capability 'GraphApplicationRoles' -ManifestVersion 'entrypoint-fixture' -ManifestSha256 ('a' * 64) -Desired @('Directory.Read.All') -Missing $missing -Details $details
if ($Apply) {
  Assert-MaesterConsentPlanApproval -Plan $plan -ApprovedPlanHash $ApprovedPlanHash
  $global:AdoEntrypointFixture.GraphApplied.Add($PSBoundParameters)
  $global:AdoEntrypointFixture.Writes.Add([pscustomobject]@{ provider = 'GraphGrant'; uri = $PrincipalObjectId; body = $details })
  if ($global:AdoEntrypointFixture.AfterGraphGrant) { & $global:AdoEntrypointFixture.AfterGraphGrant }
} else { $plan }
'@
    $consentAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:entryScripts 'vendor/Azd.MaesterHooks/Maester-ConsentPlan.psm1'), [ref]$null, [ref]$null)
    $confirm = $consentAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Confirm-MaesterConsentPlan' }, $true)
    $confirmStatements = @($confirm.Body.EndBlock.Statements | Where-Object { $_.Extent.Text -notlike '*Non-interactive permission expansion requires an explicit approved plan hash*' })
    # A local terminal-input provider is necessary because this AST block is
    # invoked from an exported-module mock (whose command scope differs from
    # Pester's test scope). The real confirmation statements stay unchanged.
    $terminalFixture = 'function Read-Host { param([string]$Prompt) $global:AdoEntrypointFixture.InteractivePrompts.Add($Prompt); return [string]::Empty }'
    $script:interactiveConfirm = [scriptblock]::Create($confirm.Body.ParamBlock.Extent.Text + "`n" + $terminalFixture + "`n" + ($confirmStatements.Extent.Text -join "`n"))
    $script:environmentNames = @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_ENV_NAME', 'AZURE_RESOURCE_GROUP', 'PERMISSION_PROFILE', 'INCLUDE_EXCHANGE', 'INCLUDE_TEAMS', 'INCLUDE_AZURE', 'AZURE_RBAC_SCOPES', 'SECURITY_GROUP_OBJECT_ID', 'EASY_AUTH_SECURITY_GROUP_OBJECT_ID', 'SECURITY_GROUP_DISPLAY_NAME', 'AZDO_ORGANIZATION', 'AZDO_PROJECT', 'AZDO_REPOSITORY', 'AZDO_PIPELINE_NAME', 'AZDO_SERVICE_CONNECTION_NAME', 'AZDO_PIPELINE_YAML_PATH', 'AZDO_DEFAULT_BRANCH', 'AZDO_SCHEDULE_CRON', 'AZDO_CREATE_REPO_IF_MISSING', 'AZDO_PUSH_PIPELINE_FILES', 'AZDO_VALIDATE_PIPELINE_RUN', 'INCLUDE_MAIL_SEND', 'INCLUDE_REPORT_SETTINGS_WRITE', 'MAIL_RECIPIENT', 'MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP', 'MAESTER_SETUP_ACCOUNT', 'MAESTER_SETUP_CLIENT_ID', 'AZDO_SERVICE_CONNECTION_ID', 'AZDO_WORKLOAD_APP_ID', 'AZDO_WORKLOAD_APP_OBJECT_ID', 'AZDO_WORKLOAD_SERVICE_PRINCIPAL_OBJECT_ID', 'CI', 'AZD_NON_INTERACTIVE')
  }
  BeforeEach {
    $script:savedEnvironment = @{}
    foreach ($name in $script:environmentNames) { $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }
    $env:MAESTER_SETUP_ACCOUNT = 'operator@example.test'; $env:MAESTER_SETUP_CLIENT_ID = '99999999-9999-4999-8999-999999999999'
    $tenant = '11111111-1111-4111-8111-111111111111'; $subscription = '22222222-2222-4222-8222-222222222222'
    $project = [pscustomobject]@{ id = '33333333-3333-4333-8333-333333333333'; name = 'project'; state = 'wellFormed' }
    $repo = [pscustomobject]@{ id = '44444444-4444-4444-8444-444444444444'; name = 'repo'; project = $project; remoteUrl = 'https://dev.azure.com/org/project/_git/repo'; defaultBranch = 'refs/heads/main' }
    $endpoint = [pscustomobject]@{
      id = '55555555-5555-4555-8555-555555555555'; name = 'connection'; type = 'AzureRM'; url = 'https://management.azure.com/'; isReady = $true; isShared = $false
      data = [pscustomobject]@{ subscriptionId = $subscription; isDraft = $false }
      authorization = [pscustomobject]@{ scheme = 'WorkloadIdentityFederation'; parameters = [pscustomobject]@{
        tenantid = $tenant; serviceprincipalid = '66666666-6666-4666-8666-666666666666'; scope = "/subscriptions/$subscription/resourceGroups/rg-offline"
        workloadIdentityFederationIssuer = 'https://vstoken.dev.azure.com/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; workloadIdentityFederationSubject = 'sc://org/project/connection'
      } }
      serviceEndpointProjectReferences = @([pscustomobject]@{ projectReference = $project })
    }
    $app = [pscustomobject]@{ id = '77777777-7777-4777-8777-777777777777'; appId = '66666666-6666-4666-8666-666666666666'; displayName = 'sc-app-maester-offline'; signInAudience = 'AzureADMyOrg'; passwordCredentials = @(); keyCredentials = @() }
    $principal = [pscustomobject]@{ id = '88888888-8888-4888-8888-888888888888'; appId = $app.appId; displayName = $app.displayName; servicePrincipalType = 'Application'; appOwnerOrganizationId = $tenant; passwordCredentials = @(); keyCredentials = @() }
    $fic = [pscustomobject]@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; name = 'ado-offline'; issuer = $endpoint.authorization.parameters.workloadIdentityFederationIssuer; subject = $endpoint.authorization.parameters.workloadIdentityFederationSubject; audiences = @('api://AzureADTokenExchange') }
    $global:AdoEntrypointFixture = @{
      ScriptsRoot = $script:entryScripts; GrantFixture = $script:grantFixture; Tenant = $tenant; Subscription = $subscription; Operator = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      OrganizationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; Project = $project; Repository = $repo; Endpoint = $endpoint; Application = $app; Principal = $principal; Federations = @($fic)
      NewRepository = $repo; NewEndpoint = $endpoint; NewApplication = $app; NewPrincipal = $principal; NewFederation = $fic
      Events = [Collections.Generic.List[string]]::new(); Writes = [Collections.Generic.List[object]]::new(); GraphApplied = [Collections.Generic.List[object]]::new(); GraphSessions = [Collections.Generic.List[object]]::new()
      InteractivePrompts = [Collections.Generic.List[string]]::new(); InteractiveConfirm = $script:interactiveConfirm; RunResponseMutation = ''; FullyGranted = $false; AfterGraphGrant = $null; DefinitionReads = 0; MutateDefinitionAt = 0; ValidationMutation = ''; ValidationDefinitionReads = 0; CreatedPipelineReturnId = ''; OnPipelineCreated = $null
      Authorized = @{}; Branch = 'main'; BranchHead = 'a' * 40; BranchReads = 0; DriftBranchAt = 0; PushedFiles = @(); ArmReads = 0
      Environment = @{ AZURE_ENV_NAME = 'offline'; AZURE_SUBSCRIPTION_ID = $subscription; AZURE_RESOURCE_GROUP = 'rg-offline'; STORAGE_ACCOUNT_NAME = 'offlineaccount'; WEB_APP_ENABLED = 'false' }
      SubscriptionMetadata = @{ id = "/subscriptions/$subscription"; subscriptionId = $subscription; tenantId = $tenant; displayName = 'Offline subscription'; state = 'Enabled' }
      Context = [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $subscription; Name = 'Offline subscription' }; Tenant = [pscustomobject]@{ Id = $tenant } }
      Storage = [pscustomobject]@{ id = "/subscriptions/$subscription/resourceGroups/rg-offline/providers/Microsoft.Storage/storageAccounts/offlineaccount"; name = 'offlineaccount'; type = 'Microsoft.Storage/storageAccounts'; tags = @{ workload = 'maester'; solution = 'azure-devops'; environment = 'offline'; managedBy = 'azd' } }
      Pipeline = [pscustomobject]@{ id = 12; name = 'pipeline'; revision = 3; project = $project; repository = [pscustomobject]@{ id = $repo.id; defaultBranch = 'refs/heads/main' }; process = [pscustomobject]@{ yamlFilename = '/azure-pipelines.yml' } }
    }
    $global:AdoEntrypointFixture.NewPipeline = $global:AdoEntrypointFixture.Pipeline | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $global:LASTEXITCODE = 0
    Mock Import-Module { }
    Mock Get-Module { [pscustomobject]@{ Name = $Name } } -ParameterFilter { $ListAvailable -and $Name -in @('ADOPS', 'ExchangeOnlineManagement') }
    Mock Set-Location { }
    Mock Write-Host { }
    Mock Write-Host -ModuleName Maester-ConsentPlan { }
    Mock Write-Warning { }
    Mock Connect-AzAccount { $global:AdoEntrypointFixture.Events.Add('AzContextRefresh') }
    Mock Assert-GraphAccess {
      $global:AdoEntrypointFixture.GraphSessions.Add(@{ TenantId = $TenantId; ClientId = $ClientId; Account = $ExpectedAccount; Scopes = @($Scopes); AllowInteractive = [bool]$AllowInteractive; AllowContextReplacement = [bool]$AllowContextReplacement })
      $global:AdoEntrypointFixture.Events.Add('GraphSession')
    }
    Mock Invoke-AzRestMethod {
      if ($Method -cne 'GET') { throw 'Unexpected ARM discovery mutation.' }
      $global:AdoEntrypointFixture.Events.Add('TargetMetadata')
      if ($Path -like '*/Microsoft.Web/sites/*') {
        $f = $global:AdoEntrypointFixture
        return [pscustomobject]@{ Content = (@{ id = "/subscriptions/$($f.Subscription)/resourceGroups/rg-offline/providers/Microsoft.Web/sites/offline-webapp"; name = 'offline-webapp'; type = 'Microsoft.Web/sites'; kind = 'app'; properties = @{ defaultHostName = 'offline-webapp.azurewebsites.net' }; tags = $f.Storage.tags } | ConvertTo-Json -Depth 20) }
      }
      [pscustomobject]@{ Content = ($global:AdoEntrypointFixture.Storage | ConvertTo-Json -Depth 20) }
    }
    Mock Invoke-RestMethod { throw 'Unexpected script-level HTTP call.' }
    Mock Invoke-GraphRestRequest { throw 'Unexpected script-level Graph call.' }
    Mock Connect-ADOPS { $global:AdoEntrypointFixture.Events.Add('ADOPSConnect') }
    Mock Get-ADOPSPipeline { $global:AdoEntrypointFixture.Pipeline }
    Mock New-ADOPSPipeline {
      $f = $global:AdoEntrypointFixture
      $f.Writes.Add([pscustomobject]@{ provider = 'Pipeline'; uri = $Name })
      $f.Pipeline = $f.NewPipeline | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      if ($f.OnPipelineCreated) { & $f.OnPipelineCreated }
      $returnedId = if ($f.CreatedPipelineReturnId) { $f.CreatedPipelineReturnId } else { $f.Pipeline.id }
      [pscustomobject]@{ id = $returnedId; name = $Name }
    }
    Mock Start-ADOPSPipeline { throw 'A validation run is forbidden without approved execution.' }
    Mock Invoke-ADOPSRestMethod {
      param($Method, $Uri, $Body)
      $f = $global:AdoEntrypointFixture
      if ($Method -eq 'GET' -and $Uri -like '*/build/definitions/*') {
        $f.ValidationDefinitionReads++
        switch ($f.ValidationMutation) {
          id { $f.Pipeline.id = 99 }
          revision { $f.Pipeline.revision++ }
          repository { $f.Pipeline.repository.id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
        }
        return $f.Pipeline
      }
      if ($Method -eq 'POST' -and $Uri -like '*/pipelines/*/runs?*') {
        $f.Writes.Add([pscustomobject]@{ provider = 'Run'; uri = $Uri; body = $Body })
        $requested = if ($Body -is [string]) { $Body | ConvertFrom-Json } else { $Body }
        $response = [pscustomobject]@{ id = 23; state = 'completed'; result = 'succeeded'; pipeline = @{ id = $f.Pipeline.id; revision = $f.Pipeline.revision }; resources = $requested.resources }
        switch ($f.RunResponseMutation) {
          source { $response.resources.repositories.self.version = 'c' * 40 }
          branch { $response.resources.repositories.self.refName = 'refs/heads/other' }
          missingSource { $response.resources = $null }
          missingProperty { $response.PSObject.Properties.Remove('resources') }
        }
        return $response
      }
      if ($Method -eq 'GET' -and $Uri -like '*/pipelines/*/runs/*') { return [pscustomobject]@{ state = 'completed'; result = 'succeeded'; _links = @{ web = @{ href = 'https://dev.azure.com/org/project/_build/results?buildId=23' } } } }
      throw "Unexpected validation request: $Method $Uri"
    }
    Mock Start-Sleep { throw 'No polling delay is allowed in offline tests.' }
    Mock Push-RepositoryFiles {
      $f = $global:AdoEntrypointFixture; $f.PushedFiles = @($Files)
      $f.Writes.Add([pscustomobject]@{ provider = 'Git'; uri = $RepositoryUrl; body = @{ branch = $Branch; expectedHead = $ExpectedBranchObjectId } })
      [pscustomobject]@{ Pushed = $true; Changed = $true; Branch = $Branch; Repository = $RepositoryUrl; CommitId = $f.BranchHead }
    }
    Mock New-Item { } -ParameterFilter { $Path -like '*/outputs*' }
    Mock Set-Content { $global:AdoEntrypointFixture.Writes.Add([pscustomobject]@{ provider = 'File'; uri = $Path; body = $Value }) } -ParameterFilter { $Path -like '*/outputs/*' }
    Mock Invoke-GraphRestRequest -ModuleName Maester-AdoBootstrap { param($Method, $Uri, $Body) Invoke-AdoEntrypointGraphFixture @PSBoundParameters }
    Mock Invoke-GraphRestRequest -ModuleName Maester-SetupConsent { param($Method, $Uri, $Body) Invoke-AdoEntrypointGraphFixture @PSBoundParameters }
    Mock Invoke-MaesterAdoRequest -ModuleName Maester-AdoBootstrap { param($Method = 'GET', $Uri, $Body) Invoke-AdoEntrypointAdoFixture -Method $Method -Uri $Uri -Body $Body }
    Mock Join-Path -ModuleName Maester-SetupConsent { $global:AdoEntrypointFixture.GrantFixture } -ParameterFilter { $ChildPath -eq 'vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1' }
    Mock Invoke-RestMethod -ModuleName Maester-SetupConsent {
      param($Method, $Uri, $Body)
      $f = $global:AdoEntrypointFixture; $f.Events.Add("ARM:$Method`:$Uri")
      if ($Method -ne 'GET') { $f.Writes.Add([pscustomobject]@{ provider = 'ARM'; uri = $Uri; body = $Body }); return [pscustomobject]@{ id = "assignment-$($f.Writes.Count)" } }
      $f.ArmReads++
      if ($f.FullyGranted) {
        $rows = @(
          @{ principal = $f.Principal.id; role = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' }
          @{ principal = $f.Principal.id; role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' }
          @{ principal = $f.Operator; role = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' }
        )
        return [pscustomobject]@{ value = @($rows | ForEach-Object { [pscustomobject]@{ id = "assignment-$($_.role)"; properties = @{ principalId = $_.principal; roleDefinitionId = "/subscriptions/$($f.Subscription)/providers/Microsoft.Authorization/roleDefinitions/$($_.role)" } } }) }
      }
      return [pscustomobject]@{ value = @() }
    }
  }
  AfterEach {
    foreach ($name in $script:environmentNames) { [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name]) }
  }
  AfterAll {
    Remove-Module Maester-AdoBootstrap, Maester-SetupConsent, Maester-SetupHelpers, Maester-ConsentPlan -Force -ErrorAction SilentlyContinue
    Remove-Item function:az, function:azd, function:git, function:Invoke-AdoEntrypointGraphFixture, function:Invoke-AdoEntrypointAdoFixture -ErrorAction SilentlyContinue
    Remove-Variable AdoEntrypointFixture -Scope Global -ErrorAction SilentlyContinue
  }

  It 'runs the entire default entrypoint as a stable no-write aggregate plan' {
    $first = Invoke-OfflineAdoEntrypoint -ActualFile
    $second = Invoke-OfflineAdoEntrypoint
    $first.capability | Should -BeExactly 'DeploymentSetupAccess'
    $first.planHash | Should -BeExactly $second.planHash
    $first.details.pipelineConfiguration.pushFiles | Should -BeTrue
    $first.details.pipelineConfiguration.validateRun | Should -BeTrue
    $first.details.pipelineInventory.pipeline.id | Should -Be 12
    $first.details.pipelineInventory.branchObjectId | Should -BeExactly ('a' * 40)
    @($first.details.adoAccess.operations).Count | Should -Be 2
    Assert-NoAdoEntrypointWrites
    Should -Invoke Connect-ADOPS -Times 0 -Exactly
  }

  It 'loads setup identity bootstrap scope choice and recipient from the verified named environment in a fresh shell' {
    $f = $global:AdoEntrypointFixture
    $env:MAESTER_SETUP_ACCOUNT = $null; $env:MAESTER_SETUP_CLIENT_ID = $null
    $f.Environment.MAESTER_SETUP_ACCOUNT = 'operator@example.test'
    $f.Environment.MAESTER_SETUP_CLIENT_ID = '99999999-9999-4999-8999-999999999999'
    $f.Environment.MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP = 'true'
    $f.Environment.MAIL_RECIPIENT = 'saved-reports@example.test'
    $plan = Invoke-OfflineAdoEntrypoint -ActualFile
    $f.GraphSessions.Count | Should -Be 1
    $f.GraphSessions[0].ClientId | Should -BeExactly $f.Environment.MAESTER_SETUP_CLIENT_ID
    $f.GraphSessions[0].Account | Should -BeExactly $f.Environment.MAESTER_SETUP_ACCOUNT
    $f.GraphSessions[0].Scopes | Should -Contain 'Application.ReadWrite.All'
    $env:MAIL_RECIPIENT | Should -BeExactly 'saved-reports@example.test'
    $plan.details.includeMailSend | Should -BeFalse
    $plan.details.setupClientId | Should -BeExactly $f.Environment.MAESTER_SETUP_CLIENT_ID
    $plan.details.setupAccount | Should -BeExactly $f.Environment.MAESTER_SETUP_ACCOUNT
    Assert-NoAdoEntrypointWrites
  }
  It 'rejects invalid bootstrap scope selection before Graph connection: <_>' -ForEach @('process', 'namedEnvironment') {
    if ($_ -eq 'process') { $env:MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP = 'yes' }
    else { $global:AdoEntrypointFixture.Environment.MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP = 'yes' }
    { Invoke-OfflineAdoEntrypoint -ActualFile } | Should -Throw '*MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP*true or false*'
    $global:AdoEntrypointFixture.GraphSessions.Count | Should -Be 0
    Assert-NoAdoEntrypointWrites
  }
  It 'never infers Mail.Send or report-settings writes from a configured recipient' {
    $env:MAIL_RECIPIENT = 'reports@example.test'
    $plan = Invoke-OfflineAdoEntrypoint
    $plan.details.includeMailSend | Should -BeFalse
    $plan.details.includeReportSettingsWrite | Should -BeFalse
    $plan.details.graphPlan.details.mail | Should -BeFalse
    $plan.details.graphPlan.details.reportSettingsWrite | Should -BeFalse
    Assert-NoAdoEntrypointWrites
  }
  It 'binds explicit optional capabilities and preserves the requested permission profile: <_>' -ForEach @('Minimal', 'Full', 'Extended') {
    $selectedProfile = $_
    $plan = Invoke-OfflineAdoEntrypoint @{ PermissionProfile = $selectedProfile; IncludeMailSend = $true; IncludeReportSettingsWrite = $true }
    $plan.details.graphPlan.details.profile | Should -BeExactly $selectedProfile
    $plan.details.graphPlan.details.mail | Should -BeTrue
    $plan.details.graphPlan.details.reportSettingsWrite | Should -BeTrue
    $plan.details.graphPlan.details.targetType | Should -BeExactly 'FederatedApplication'
    $plan.details.graphPlan.details.applicationObjectId | Should -BeExactly $global:AdoEntrypointFixture.Application.id
    $plan.details.graphPlan.details.issuer | Should -BeExactly $global:AdoEntrypointFixture.NewFederation.issuer
    Assert-NoAdoEntrypointWrites
  }
  It 'honors explicit false capabilities over true environment defaults' {
    $env:INCLUDE_MAIL_SEND = 'true'; $env:INCLUDE_REPORT_SETTINGS_WRITE = 'true'
    $plan = Invoke-OfflineAdoEntrypoint @{ IncludeMailSend = $false; IncludeReportSettingsWrite = $false }
    $plan.details.includeMailSend | Should -BeFalse
    $plan.details.includeReportSettingsWrite | Should -BeFalse
    Assert-NoAdoEntrypointWrites
  }
  It 'rejects malformed capability environment flags before Graph connection: <_>' -ForEach @('INCLUDE_MAIL_SEND', 'INCLUDE_REPORT_SETTINGS_WRITE') {
    $flag = $_
    [Environment]::SetEnvironmentVariable($flag, 'yes')
    { Invoke-OfflineAdoEntrypoint } | Should -Throw '*must be true or false*'
    $global:AdoEntrypointFixture.GraphSessions.Count | Should -Be 0
    Assert-NoAdoEntrypointWrites
  }
  It 'authenticates exactly once with the selected deduplicated scope union: <_>' -ForEach @('access', 'bootstrap', 'runtimeSwitch', 'runtimeEnvironment', 'teamsBootstrap', 'webTeamsBootstrap') {
    $mode = $_
    $parameters = @{}
    if ($mode -in @('bootstrap', 'teamsBootstrap', 'webTeamsBootstrap')) { $parameters.Bootstrap = $true }
    if ($mode -eq 'runtimeSwitch') { $parameters.IncludeRuntimeApplicationBootstrap = $true }
    if ($mode -eq 'runtimeEnvironment') { $env:MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP = 'true' }
    if ($mode -in @('teamsBootstrap', 'webTeamsBootstrap')) { $parameters.IncludeTeams = $true }
    if ($mode -eq 'webTeamsBootstrap') { $global:AdoEntrypointFixture.Environment.WEB_APP_ENABLED = 'true'; $global:AdoEntrypointFixture.Environment.WEB_APP_NAME = 'offline-webapp' }
    $null = Invoke-OfflineAdoEntrypoint $parameters
    $sessions = $global:AdoEntrypointFixture.GraphSessions
    $sessions.Count | Should -Be 1
    $sessions[0].TenantId | Should -BeExactly $global:AdoEntrypointFixture.Tenant
    $sessions[0].ClientId | Should -BeExactly $env:MAESTER_SETUP_CLIENT_ID
    $sessions[0].Account | Should -BeExactly $env:MAESTER_SETUP_ACCOUNT
    $expected = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'Directory.Read.All')
    if ($mode -ne 'access') { $expected += 'Application.ReadWrite.All' }
    if ($mode -in @('teamsBootstrap', 'webTeamsBootstrap')) { $expected += 'RoleManagement.ReadWrite.Directory' }
    if ($mode -eq 'webTeamsBootstrap') { $expected += @('DelegatedPermissionGrant.ReadWrite.All', 'Group.Read.All') }
    @($sessions[0].Scopes) | Should -Be @($expected | Sort-Object -Unique)
    $sessions[0].AllowInteractive | Should -BeFalse
    Assert-NoAdoEntrypointWrites
  }
  It 'requires an exact aggregate hash before every type of write: <_>' -ForEach @('missing', 'stale', 'graphOnly', 'bootstrapOnly') {
    $approval = $_
    $plan = Invoke-OfflineAdoEntrypoint
    $hash = switch ($approval) { missing { '' } stale { '0' * 64 } graphOnly { $plan.details.graphPlanHash } bootstrapOnly { (Invoke-OfflineAdoEntrypoint @{ Bootstrap = $true }).planHash } }
    { Invoke-OfflineAdoEntrypoint @{ Apply = $true; ApprovedPlanHash = $hash } } | Should -Throw
    Assert-NoAdoEntrypointWrites
  }
  It 'rejects an aggregate approval after selected capability or publication input changes: <_>' -ForEach @('mail', 'report', 'profile', 'schedule', 'run', 'push', 'definition', 'branch') {
    $change = $_
    $plan = Invoke-OfflineAdoEntrypoint
    $parameters = @{ Apply = $true; ApprovedPlanHash = $plan.planHash }
    switch ($change) {
      mail { $parameters.IncludeMailSend = $true }
      report { $parameters.IncludeReportSettingsWrite = $true }
      profile { $parameters.PermissionProfile = 'Minimal' }
      schedule { $parameters.ScheduleCron = '15 6 * * 1' }
      run { $parameters.ValidatePipelineRun = $false }
      push { $parameters.PushPipelineFiles = $false }
      definition { $global:AdoEntrypointFixture.Pipeline.revision++ }
      branch { $global:AdoEntrypointFixture.BranchHead = 'b' * 40 }
    }
    { Invoke-OfflineAdoEntrypoint $parameters } | Should -Throw '*changed after review*'
    Assert-NoAdoEntrypointWrites
  }
  It 'revalidates live branch evidence again after displaying the approved aggregate and before grants' {
    $plan = Invoke-OfflineAdoEntrypoint
    $global:AdoEntrypointFixture.DriftBranchAt = $global:AdoEntrypointFixture.BranchReads + 2
    { Invoke-OfflineAdoEntrypoint @{ Apply = $true; ApprovedPlanHash = $plan.planHash } } | Should -Throw '*changed after review*'
    $global:AdoEntrypointFixture.BranchReads | Should -Be 3
    Assert-NoAdoEntrypointWrites
  }
  It 'stops a bootstrap apply at its reviewed stage without permission or pipeline continuation' {
    $f = $global:AdoEntrypointFixture
    $f.Repository = $null; $f.Endpoint = $null; $f.Application = $null; $f.Principal = $null; $f.Federations = @()
    $plan = Invoke-OfflineAdoEntrypoint @{ Bootstrap = $true }
    $plan.details.operations.kind | Should -Be @('Repository', 'Endpoint', 'Application')
    Assert-NoAdoEntrypointWrites
    $result = Invoke-OfflineAdoEntrypoint @{ ApplyBootstrap = $true; ApprovedBootstrapPlanHash = $plan.planHash }
    $result.NextPlan.details.operations.kind | Should -Be @('Principal')
    @($f.Writes | Where-Object provider -in @('ADO', 'Graph')).Count | Should -Be 3
    @($f.Writes | Where-Object { $_.uri -match 'roleAssignments|appRoleAssignments|pipelinePermissions|federatedIdentityCredentials' }).Count | Should -Be 0
    $f.GraphApplied.Count | Should -Be 0
    $f.BranchReads | Should -Be 0
    Should -Invoke Connect-ADOPS -Times 0 -Exactly
    Should -Invoke Push-RepositoryFiles -Times 0 -Exactly
    Should -Invoke New-ADOPSPipeline -Times 0 -Exactly
  }
  It 'returns after a completed bootstrap even when pipeline publication and validation default true' {
    $plan = Invoke-OfflineAdoEntrypoint @{ Bootstrap = $true }
    $result = Invoke-OfflineAdoEntrypoint @{ ApplyBootstrap = $true; ApprovedBootstrapPlanHash = $plan.planHash }
    @($result.NextPlan.missing).Count | Should -Be 0
    @($global:AdoEntrypointFixture.Writes | Where-Object provider -ne azd).Count | Should -Be 0
    $global:AdoEntrypointFixture.GraphApplied.Count | Should -Be 0
    $global:AdoEntrypointFixture.BranchReads | Should -Be 0
    Should -Invoke Connect-ADOPS -Times 0 -Exactly
    Should -Invoke Push-RepositoryFiles -Times 0 -Exactly
  }
  It 'rejects mixed bootstrap and permission stages before Graph connection' {
    { Invoke-OfflineAdoEntrypoint @{ Bootstrap = $true; Apply = $true; ApprovedPlanHash = 'a' * 64 } } | Should -Throw '*separate stages*'
    $global:AdoEntrypointFixture.GraphSessions.Count | Should -Be 0
    Assert-NoAdoEntrypointWrites
  }
  It 'checks every target boundary before any writes: <_>' -ForEach @('subscriptionTenant', 'subscriptionState', 'azContext', 'environment', 'storageScope', 'storageTags', 'endpointTenant', 'endpointScope', 'principalOwner', 'federationAudience', 'pipelineRepository', 'pipelineYaml', 'pipelineBranch') {
    $target = $_
    $f = $global:AdoEntrypointFixture
    switch ($target) {
      subscriptionTenant { $f.SubscriptionMetadata.tenantId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
      subscriptionState { $f.SubscriptionMetadata.state = 'Disabled' }
      azContext { $f.Context.Tenant.Id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
      environment { $f.Environment.AZURE_ENV_NAME = 'other' }
      storageScope { $f.Storage.id = $f.Storage.id.Replace('rg-offline', 'rg-other') }
      storageTags { $f.Storage.tags.solution = 'other' }
      endpointTenant { $f.Endpoint.authorization.parameters.tenantid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
      endpointScope { $f.Endpoint.authorization.parameters.scope = "/subscriptions/$($f.Subscription)" }
      principalOwner { $f.Principal.appOwnerOrganizationId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
      federationAudience { $f.Federations[0].audiences = @('other-audience') }
      pipelineRepository { $f.Pipeline.repository.id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
      pipelineYaml { $f.Pipeline.process.yamlFilename = '/another.yml' }
      pipelineBranch { $f.Pipeline.repository.defaultBranch = 'refs/heads/other' }
    }
    { Invoke-OfflineAdoEntrypoint @{ Apply = $true; ApprovedPlanHash = 'a' * 64 } } | Should -Throw
    Assert-NoAdoEntrypointWrites
    if ($target -in @('subscriptionTenant', 'subscriptionState', 'azContext', 'environment', 'storageScope', 'storageTags')) { $f.GraphSessions.Count | Should -Be 0 }
  }




  It 'requires an explicitly nonshared endpoint before planning any bootstrap or access: <_>' -ForEach @('shared', 'missing', 'string', 'null') {
    $f = $global:AdoEntrypointFixture
    switch ($_) {
      shared { $f.Endpoint.isShared = $true }
      missing { $f.Endpoint.PSObject.Properties.Remove('isShared') }
      string { $f.Endpoint.isShared = 'false' }
      null { $f.Endpoint.isShared = $null }
    }
    { Invoke-OfflineAdoEntrypoint @{ Bootstrap = $true } -ActualFile } | Should -Throw '*explicitly nonshared*'
    Assert-NoAdoEntrypointWrites
  }
  It 'accepts modern federation only when its issuer and subject bind the selected tenant organization and endpoint' {
    $f = $global:AdoEntrypointFixture
    $issuer = "https://login.microsoftonline.com/$($f.Tenant)/v2.0"
    $subject = "opaque-prefix/sc/$($f.OrganizationId)/$($f.Endpoint.id)"
    $f.Endpoint.authorization.parameters.workloadIdentityFederationIssuer = $issuer
    $f.Endpoint.authorization.parameters.workloadIdentityFederationSubject = $subject
    $f.Federations[0].issuer = $issuer; $f.Federations[0].subject = $subject
    $plan = Invoke-OfflineAdoEntrypoint -ActualFile
    $plan.details.inventory.adoIdentity.organization.id | Should -BeExactly $f.OrganizationId
    $plan.details.inventory.adoIdentity.organization.name | Should -BeExactly 'org'
    $plan.details.graphPlan.details.issuer | Should -BeExactly $issuer
    $plan.details.graphPlan.details.subject | Should -BeExactly $subject
    Assert-NoAdoEntrypointWrites
  }
  It 'rejects a matching FIC whose returned trust names another selected authority: <_>' -ForEach @('legacyIssuerOrg', 'legacySubjectOrg', 'legacySubjectProject', 'legacySubjectConnection', 'modernTenant', 'modernSubjectOrg', 'modernSubjectEndpoint', 'modernIssuerSuffix') {
    $mode = $_; $f = $global:AdoEntrypointFixture; $other = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    $issuer = $f.Endpoint.authorization.parameters.workloadIdentityFederationIssuer
    $subject = $f.Endpoint.authorization.parameters.workloadIdentityFederationSubject
    if ($mode -like 'modern*') { $issuer = "https://login.microsoftonline.com/$($f.Tenant)/v2.0"; $subject = "opaque-prefix/sc/$($f.OrganizationId)/$($f.Endpoint.id)" }
    switch ($mode) {
      legacyIssuerOrg { $issuer = "https://vstoken.dev.azure.com/$other" }
      legacySubjectOrg { $subject = 'sc://other/project/connection' }
      legacySubjectProject { $subject = 'sc://org/other/connection' }
      legacySubjectConnection { $subject = 'sc://org/project/other' }
      modernTenant { $issuer = "https://login.microsoftonline.com/$other/v2.0" }
      modernSubjectOrg { $subject = "opaque-prefix/sc/$other/$($f.Endpoint.id)" }
      modernSubjectEndpoint { $subject = "opaque-prefix/sc/$($f.OrganizationId)/$other" }
      modernIssuerSuffix { $issuer += '/' }
    }
    # Match the existing FIC too: failure must be provenance validation, not a
    # convenient mismatch between two equally untrusted provider responses.
    $f.Endpoint.authorization.parameters.workloadIdentityFederationIssuer = $issuer
    $f.Endpoint.authorization.parameters.workloadIdentityFederationSubject = $subject
    $f.Federations[0].issuer = $issuer; $f.Federations[0].subject = $subject
    { Invoke-OfflineAdoEntrypoint @{ Bootstrap = $true } } | Should -Throw
    Assert-NoAdoEntrypointWrites
  }
  It 'rejects missing or invalid organization identity before Graph inventory: <_>' -ForEach @('', 'not-a-guid', '00000000-0000-0000-0000-000000000000') {
    $global:AdoEntrypointFixture.OrganizationId = $_
    { Invoke-OfflineAdoEntrypoint @{ Bootstrap = $true } } | Should -Throw '*non-empty GUID*'
    @($global:AdoEntrypointFixture.Events | Where-Object { $_ -like 'Graph:*' }).Count | Should -Be 0
    Assert-NoAdoEntrypointWrites
  }
  It 'rejects malformed persisted exact identity IDs before ADO or Graph inventory: <_>' -ForEach @('AZDO_SERVICE_CONNECTION_ID', 'AZDO_WORKLOAD_APP_ID', 'AZDO_WORKLOAD_APP_OBJECT_ID', 'AZDO_WORKLOAD_SERVICE_PRINCIPAL_OBJECT_ID') {
    $global:AdoEntrypointFixture.Environment[$_] = 'not-a-guid'
    { Invoke-OfflineAdoEntrypoint } | Should -Throw '*must be a non-empty GUID*'
    @($global:AdoEntrypointFixture.Events | Where-Object { $_ -like 'ADO:*' -or $_ -like 'Graph:*' }).Count | Should -Be 0
    Assert-NoAdoEntrypointWrites
  }
  It 'rejects a clone URL outside the reviewed official repository: <_>' -ForEach @('https://evil.example/org/project/_git/repo', 'https://dev.azure.com/org/other/_git/repo', 'https://credential@dev.azure.com/org/project/_git/repo') {
    $global:AdoEntrypointFixture.Repository.remoteUrl = $_
    { Invoke-OfflineAdoEntrypoint } | Should -Throw '*Repository clone URL*'
    Assert-NoAdoEntrypointWrites
  }
  It 'rejects executable or multiline runtime template values before every write: <_>' -ForEach @("report'@example.test", '$(Run-Anything)', "value`nvalue", 'value`value', 'value"value') {
    $env:MAIL_RECIPIENT = $_
    { Invoke-OfflineAdoEntrypoint @{ Apply = $true; ApprovedPlanHash = 'a' * 64 } } | Should -Throw '*Pipeline settings must be literal*'
    Assert-NoAdoEntrypointWrites
  }
  It 'never includes raw credential material in an entrypoint aggregate plan' {
    $f = $global:AdoEntrypointFixture
    $f.Application.passwordCredentials = @([pscustomobject]@{ keyId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z'; secretText = 'DO_NOT_DISCLOSE_SECRET_FIXTURE'; hint = 'DO_NOT_DISCLOSE_HINT_FIXTURE' })
    $f.Endpoint.authorization.parameters | Add-Member serviceprincipalkey 'DO_NOT_DISCLOSE_ENDPOINT_FIXTURE'
    $plan = Invoke-OfflineAdoEntrypoint
    $json = $plan | ConvertTo-Json -Depth 100
    $json | Should -Not -Match 'DO_NOT_DISCLOSE|"secretText"\s*:|"passwordCredentials"\s*:|"keyCredentials"\s*:|"serviceprincipalkey"\s*:'
    $json | Should -Match 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    Assert-NoAdoEntrypointWrites
  }
  It 'requires separate fresh approval for all three bootstrap stages and then returns a new access plan' {
    $f = $global:AdoEntrypointFixture
    $f.Repository = $null; $f.Endpoint = $null; $f.Application = $null; $f.Principal = $null; $f.Federations = @()
    $first = Invoke-OfflineAdoEntrypoint @{ Bootstrap = $true } -ActualFile
    $stage1 = Invoke-OfflineAdoEntrypoint @{ ApplyBootstrap = $true; ApprovedBootstrapPlanHash = $first.planHash } -ActualFile
    $f.Environment.AZDO_REPOSITORY_CREATED | Should -BeExactly 'true'
    $count = $f.Writes.Count
    { Invoke-OfflineAdoEntrypoint @{ ApplyBootstrap = $true; ApprovedBootstrapPlanHash = $first.planHash } -ActualFile } | Should -Throw '*inventory changed*'
    $f.Writes.Count | Should -Be $count
    $stage2 = Invoke-OfflineAdoEntrypoint @{ ApplyBootstrap = $true; ApprovedBootstrapPlanHash = $stage1.NextPlan.planHash } -ActualFile
    $stage2.NextPlan.details.operations.kind | Should -Be @('Federation', 'EndpointBinding')
    $stage3 = Invoke-OfflineAdoEntrypoint @{ ApplyBootstrap = $true; ApprovedBootstrapPlanHash = $stage2.NextPlan.planHash } -ActualFile
    @($stage3.NextPlan.missing).Count | Should -Be 0
    $f.Environment.AZDO_WORKLOAD_APP_OBJECT_ID | Should -BeExactly $f.Application.id
    $f.Environment.AZDO_WORKLOAD_SERVICE_PRINCIPAL_OBJECT_ID | Should -BeExactly $f.Principal.id
    $f.Environment.AZDO_SERVICE_CONNECTION_ID | Should -BeExactly $f.Endpoint.id
    $count = $f.Writes.Count
    $access = Invoke-OfflineAdoEntrypoint @{ IncludeRuntimeApplicationBootstrap = $true } -ActualFile
    $access.capability | Should -BeExactly 'DeploymentSetupAccess'
    $access.planHash | Should -Not -BeExactly $stage3.NextPlan.planHash
    $f.Writes.Count | Should -Be $count
    $f.GraphApplied.Count | Should -Be 0
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
    Should -Invoke Push-RepositoryFiles -Times 0 -Exactly
  }
  It 'rejects approval after a runtime evidence source file changes' {
    $plan = Invoke-OfflineAdoEntrypoint
    $source = Get-Content (Join-Path $script:entryScripts 'Maester.AssessmentEvidence.psm1') -Raw
    $global:AdoEntrypointFixture.ChangedEvidence = $source + "`n# changed after review"
    Mock Get-Content { [IO.File]::ReadAllText($Path) }
    Mock Get-Content { $global:AdoEntrypointFixture.ChangedEvidence } -ParameterFilter { $Path -like '*/Maester.AssessmentEvidence.psm1' }
    { Invoke-OfflineAdoEntrypoint @{ Apply = $true; ApprovedPlanHash = $plan.planHash } } | Should -Throw '*changed after review*'
    Assert-NoAdoEntrypointWrites
  }
  It 'runs the actual unchanged script file through approved access and actual pipeline validation control flow' {
    $plan = Invoke-OfflineAdoEntrypoint @{ PushPipelineFiles = $false } -ActualFile
    Assert-NoAdoEntrypointWrites
    $null = Invoke-OfflineAdoEntrypoint @{ PushPipelineFiles = $false; Apply = $true; ApprovedPlanHash = $plan.planHash } -ActualFile
    $global:AdoEntrypointFixture.GraphApplied.Count | Should -Be 1
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
    Should -Invoke Invoke-ADOPSRestMethod -Times 1 -Exactly -ParameterFilter { $Method -ceq 'POST' -and $Uri -like 'https://dev.azure.com/org/project/_apis/pipelines/12/runs?*pipelineVersion=3*' }
    $run = @($global:AdoEntrypointFixture.Writes | Where-Object provider -eq 'Run')[0]
    $body = if ($run.body -is [string]) { $run.body | ConvertFrom-Json } else { $run.body }
    $body.resources.repositories.self.refName | Should -BeExactly 'refs/heads/main'
    $body.resources.repositories.self.version | Should -BeExactly ('a' * 40)
    Should -Invoke Push-RepositoryFiles -Times 0 -Exactly
    Should -Invoke Start-Sleep -Times 0 -Exactly
    @($global:AdoEntrypointFixture.Writes | Where-Object { $_.provider -eq 'azd' -and $_.uri -match 'AZDO_LAST_PIPELINE_RUN_ID 23$' }).Count | Should -Be 1
    @($global:AdoEntrypointFixture.Writes | Where-Object provider -eq File).Count | Should -Be 1
  }

  It 'rejects pipeline replacement or mutation after approved grants and before reuse: <_>' -ForEach @('id', 'revision', 'repository', 'yaml', 'branch', 'missing') {
    $f = $global:AdoEntrypointFixture; $f.PipelineMutation = $_
    $parameters = @{ PushPipelineFiles = $false }
    $plan = Invoke-OfflineAdoEntrypoint $parameters
    $f.AfterGraphGrant = {
      $state = $global:AdoEntrypointFixture
      switch ($state.PipelineMutation) {
        id { $state.Pipeline.id = 99 }
        revision { $state.Pipeline.revision++ }
        repository { $state.Pipeline.repository.id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
        yaml { $state.Pipeline.process.yamlFilename = '/wrong.yml' }
        branch { $state.Pipeline.repository.defaultBranch = 'refs/heads/wrong' }
        missing { $state.Pipeline = $null }
      }
    }
    $parameters.Apply = $true; $parameters.ApprovedPlanHash = $plan.planHash
    { Invoke-OfflineAdoEntrypoint $parameters -ActualFile } | Should -Throw '*pipeline*'
    $f.GraphApplied.Count | Should -Be 1
    @($f.Writes | Where-Object provider -eq 'Run').Count | Should -Be 0
    Should -Invoke New-ADOPSPipeline -Times 0 -Exactly
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
  }
  It 'rejects a newly created pipeline whose exact readback differs from its returned ID or reviewed target: <_>' -ForEach @('returnedId', 'repository', 'yaml', 'branch') {
    $f = $global:AdoEntrypointFixture; $f.Pipeline = $null
    switch ($_) {
      returnedId { $f.CreatedPipelineReturnId = '99' }
      repository { $f.NewPipeline.repository.id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
      yaml { $f.NewPipeline.process.yamlFilename = '/wrong.yml' }
      branch { $f.NewPipeline.repository.defaultBranch = 'refs/heads/wrong' }
    }
    $parameters = @{ PushPipelineFiles = $false }
    $plan = Invoke-OfflineAdoEntrypoint $parameters
    $parameters.Apply = $true; $parameters.ApprovedPlanHash = $plan.planHash
    { Invoke-OfflineAdoEntrypoint $parameters -ActualFile } | Should -Throw '*pipeline*'
    $f.GraphApplied.Count | Should -Be 1
    Should -Invoke New-ADOPSPipeline -Times 1 -Exactly
    @($f.Writes | Where-Object provider -eq 'Run').Count | Should -Be 0
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
  }
  It 'validates a newly created exact definition and pins its readback ID revision and immutable source for the run' {
    $f = $global:AdoEntrypointFixture; $f.Pipeline = $null; $f.NewPipeline.id = 24; $f.NewPipeline.revision = 7
    $parameters = @{ PushPipelineFiles = $false }
    $plan = Invoke-OfflineAdoEntrypoint $parameters
    $parameters.Apply = $true; $parameters.ApprovedPlanHash = $plan.planHash
    $null = Invoke-OfflineAdoEntrypoint $parameters -ActualFile
    Should -Invoke New-ADOPSPipeline -Times 1 -Exactly
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
    $runs = @($f.Writes | Where-Object provider -eq 'Run')
    $runs.Count | Should -Be 1
    $runs[0].uri | Should -Match '/pipelines/24/runs\?.*pipelineVersion=7'
    $payload = if ($runs[0].body -is [string]) { $runs[0].body | ConvertFrom-Json } else { $runs[0].body }
    $payload.resources.repositories.self.version | Should -BeExactly ('a' * 40)
    $f.ValidationDefinitionReads | Should -Be 1
  }
  It 'revalidates the approved pipeline again immediately before invoking validation' {
    $f = $global:AdoEntrypointFixture
    $parameters = @{ PushPipelineFiles = $false }
    $plan = Invoke-OfflineAdoEntrypoint $parameters
    $f.AfterGraphGrant = { $global:AdoEntrypointFixture.MutateDefinitionAt = $global:AdoEntrypointFixture.DefinitionReads + 3 }
    $parameters.Apply = $true; $parameters.ApprovedPlanHash = $plan.planHash
    { Invoke-OfflineAdoEntrypoint $parameters -ActualFile } | Should -Throw '*pipeline*'
    $f.GraphApplied.Count | Should -Be 1
    $f.ValidationDefinitionReads | Should -Be 0
    @($f.Writes | Where-Object provider -eq 'Run').Count | Should -Be 0
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
  }
  It 'rejects a final validation readback race before the exact run POST: <_>' -ForEach @('id', 'revision', 'repository') {
    $f = $global:AdoEntrypointFixture
    $parameters = @{ PushPipelineFiles = $false }
    $plan = Invoke-OfflineAdoEntrypoint $parameters
    $f.ValidationMutation = $_
    $parameters.Apply = $true; $parameters.ApprovedPlanHash = $plan.planHash
    { Invoke-OfflineAdoEntrypoint $parameters -ActualFile } | Should -Throw '*pipeline*'
    $f.GraphApplied.Count | Should -Be 1
    $f.ValidationDefinitionReads | Should -Be 1
    @($f.Writes | Where-Object provider -eq 'Run').Count | Should -Be 0
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
  }

  It 'reports an already queued run as unverified when its response changes the pinned source: <_>' -ForEach @('source', 'branch', 'missingSource', 'missingProperty') {
    $f = $global:AdoEntrypointFixture; $f.RunResponseMutation = $_
    $parameters = @{ PushPipelineFiles = $false }
    $plan = Invoke-OfflineAdoEntrypoint $parameters
    $parameters.Apply = $true; $parameters.ApprovedPlanHash = $plan.planHash
    { Invoke-OfflineAdoEntrypoint $parameters -ActualFile } | Should -Throw '*queued*exact requested repository ref and source commit*'
    @($f.Writes | Where-Object provider -eq 'Run').Count | Should -Be 1
    @($f.Writes | Where-Object { $_.provider -eq 'azd' -and $_.uri -match 'AZDO_LAST_PIPELINE_RUN_ID' }).Count | Should -Be 0
    @($f.Writes | Where-Object provider -eq 'File').Count | Should -Be 0
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
  }
  It 'does not need permission approval when pregranted access has no selected publication or run action' {
    $global:AdoEntrypointFixture.FullyGranted = $true
    $plan = Invoke-OfflineAdoEntrypoint @{ PushPipelineFiles = $false; ValidatePipelineRun = $false }
    @($plan.details.graphPlan.missing).Count | Should -Be 0
    @($plan.details.operations).Count | Should -Be 0
    @($plan.details.adoAccess.operations).Count | Should -Be 0
    @($plan.missing).Count | Should -Be 0
    Assert-NoAdoEntrypointWrites
  }
  It 'requires default-No approval for each publication action even when all access is already granted: <_>' -ForEach @('push', 'create', 'run') {
    $f = $global:AdoEntrypointFixture; $f.FullyGranted = $true
    $parameters = @{ PushPipelineFiles = $false; ValidatePipelineRun = $false }
    switch ($_) { push { $parameters.PushPipelineFiles = $true }; create { $f.Pipeline = $null }; run { $parameters.ValidatePipelineRun = $true } }
    $plan = Invoke-OfflineAdoEntrypoint $parameters
    @($plan.details.graphPlan.missing).Count | Should -Be 0
    @($plan.details.operations).Count | Should -Be 0
    @($plan.details.adoAccess.operations).Count | Should -Be 0
    @($plan.missing).Count | Should -BeGreaterThan 0
    # The host is headless. Run the actual confirmation statements with only
    # their console-capability guard excluded; integrity, empty-delta bypass,
    # default-No prompt, answer handling and approval return are unchanged.
    Mock Confirm-MaesterConsentPlan { & $global:AdoEntrypointFixture.InteractiveConfirm -Plan $Plan }
    $parameters.InteractiveConsent = $true; $parameters.AllowInteractiveGraphLogin = $true
    { Invoke-OfflineAdoEntrypoint $parameters -ActualFile } | Should -Throw '*not approved*'
    $f.InteractivePrompts.Count | Should -Be 1
    $f.InteractivePrompts[0] | Should -Match '\[y/N\]'
    Assert-NoAdoEntrypointWrites
  }
  It 'fails closed in a real headless InteractiveConsent session for pregranted access with publication selected' {
    $global:AdoEntrypointFixture.FullyGranted = $true; $env:CI = 'true'
    { Invoke-OfflineAdoEntrypoint @{ InteractiveConsent = $true; AllowInteractiveGraphLogin = $true } -ActualFile } | Should -Throw '*Non-interactive permission expansion requires*'
    Assert-NoAdoEntrypointWrites
  }
  It 'publishes only reviewed rendered runtime files, including evidence, with exact file hashes and branch guard' {
    $env:MAIL_RECIPIENT = 'reports@example.test'
    $parameters = @{ IncludeMailSend = $true; IncludeReportSettingsWrite = $true; ValidatePipelineRun = $false; PermissionProfile = 'Minimal'; ScheduleCron = '15 6 * * 1' }
    $plan = Invoke-OfflineAdoEntrypoint $parameters
    $parameters.Apply = $true; $parameters.ApprovedPlanHash = $plan.planHash
    $null = Invoke-OfflineAdoEntrypoint $parameters
    $f = $global:AdoEntrypointFixture
    $f.GraphApplied.Count | Should -Be 1
    $f.GraphApplied[0].ApprovedPlanHash | Should -BeExactly $plan.details.graphPlanHash
    $files = @($f.PushedFiles)
    $files.Count | Should -Be 7
    @($files.Path) | Should -Contain 'scripts/Maester.AssessmentEvidence.psm1'
    @($files.Path | Where-Object { $_ -match 'Setup|Grant|Bootstrap|vendor' }).Count | Should -Be 0
    foreach ($file in $files) {
      $evidence = @($plan.details.pipelineConfiguration.files | Where-Object path -eq $file.Path)
      $evidence.Count | Should -Be 1
      $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($file.Content))).ToLowerInvariant()
      $hash | Should -BeExactly $evidence[0].sha256
    }
    ($files | Where-Object Path -eq 'scripts/Maester.AssessmentEvidence.psm1').Content | Should -BeExactly (Get-Content (Join-Path $script:entryScripts 'Maester.AssessmentEvidence.psm1') -Raw)
    $yaml = ($files | Where-Object Path -eq 'azure-pipelines.yml').Content
    $yaml | Should -Not -Match '__[A-Z_]+__'
    foreach ($text in @("ServiceConnection: 'connection'", "PermissionProfile: 'Minimal'", "IncludeMailSend: 'true'", "IncludeReportSettingsWrite: 'true'", "MailRecipient: 'reports@example.test'", "TenantId: '$($f.Tenant)'", "SubscriptionId: '$($f.Subscription)'", "ClientId: '$($f.Application.appId)'", "StorageAccountName: 'offlineaccount'", '15 6 * * 1')) { $yaml | Should -Match ([regex]::Escape($text)) }
    Should -Invoke Push-RepositoryFiles -Times 1 -Exactly -ParameterFilter { $ExpectedBranchObjectId -ceq ('a' * 40) -and $Branch -ceq 'main' }
    Should -Invoke Start-ADOPSPipeline -Times 0 -Exactly
    @($f.Writes | Where-Object provider -eq ARM).Count | Should -Be 3
    @($f.Writes | Where-Object { $_.provider -eq 'ADO' -and $_.uri -like '*/pipelinePermissions/*' }).Count | Should -Be 2
    @($f.Writes | Where-Object provider -eq azd).Count | Should -BeGreaterThan 0
  }
}
