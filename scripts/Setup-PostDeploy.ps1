#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$EnvironmentName,

  [Parameter(Mandatory = $false)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory = $false)]
  [string]$TenantId,

  [Parameter(Mandatory = $false)]
  [string]$SecurityGroupObjectId,

  [Parameter(Mandatory = $false)]
  [string]$SecurityGroupDisplayName,

  [Parameter(Mandatory = $false)]
  [ValidateSet('Minimal', 'Full', 'Extended')]
  [string]$PermissionProfile = 'Full',

  [Parameter(Mandatory = $false)]
  [switch]$IncludeExchange,

  [Parameter(Mandatory = $false)]
  [switch]$IncludeTeams,

  [Parameter(Mandatory = $false)]
  [switch]$IncludeAzure,

  [Parameter(Mandatory = $false)]
  [string[]]$AzureScopes,

  [Parameter(Mandatory = $false)]
  [string]$AdoOrganization,

  [Parameter(Mandatory = $false)]
  [string]$AdoProject,

  [Parameter(Mandatory = $false)]
  [string]$AdoRepositoryName,

  [Parameter(Mandatory = $false)]
  [string]$AdoPipelineName,

  [Parameter(Mandatory = $false)]
  [string]$AdoServiceConnectionName,

  [Parameter(Mandatory = $false)]
  [string]$PipelineYamlPath,

  [Parameter(Mandatory = $false)]
  [string]$DefaultBranch,

  [Parameter(Mandatory = $false)]
  [string]$ScheduleCron,

  [Parameter(Mandatory = $false)]
  [bool]$CreateRepositoryIfMissing,

  [Parameter(Mandatory = $false)]
  [bool]$PushPipelineFiles,

  [Parameter(Mandatory = $false)]
  [bool]$ValidatePipelineRun,

  [Parameter(Mandatory = $false)]
  [bool]$FailOnTestFailures,
  [switch]$IncludeMailSend,
  [switch]$IncludeReportSettingsWrite,
  [switch]$Bootstrap,
  [switch]$IncludeRuntimeApplicationBootstrap,
  [switch]$ApplyBootstrap,
  [string]$ApprovedBootstrapPlanHash,
  [switch]$Apply,
  [string]$ApprovedPlanHash,
  [switch]$InteractiveConsent,
  [switch]$AllowInteractiveGraphLogin,
  [switch]$AllowGraphContextReplacement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvValue {
  param(
    [Parameter(Mandatory = $true)]
    $Lines,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($Lines -is [hashtable]) {
    if ($Lines.ContainsKey($Name)) {
      return [string]$Lines[$Name]
    }
    return $null
  }

  foreach ($line in @($Lines)) {
    if ($line -like "$Name=*") {
      return $line.Split('=', 2)[1].Trim('"')
    }
  }

  return $null
}

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

function Test-RequiredValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Name is required."
  }

  return $Value.Trim()
}
function Get-OptionalPropertyValue {
  param(
    [Parameter(Mandatory = $false)]
    $InputObject,

    [Parameter(Mandatory = $true)]
    [string[]]$PropertyNames
  )

  if ($null -eq $InputObject) {
    return $null
  }

  foreach ($propertyName in $PropertyNames) {
    $property = $InputObject.PSObject.Properties | Where-Object { $_.Name -ieq $propertyName } | Select-Object -First 1
    if ($property) {
      return $property.Value
    }
  }

  return $null
}
function Push-RepositoryFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl,

    [Parameter(Mandatory = $true)]
    [string]$Branch,

    [Parameter(Mandatory = $true)]
    [string]$BearerToken,

    [Parameter(Mandatory = $true)]
    [object[]]$Files,

    [string]$ExpectedBranchObjectId
  )

  $tempPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("maester-ado-{0}" -f ([guid]::NewGuid().ToString('N')))
  New-Item -Path $tempPath -ItemType Directory -Force | Out-Null

  $header = "http.extraheader=AUTHORIZATION: bearer $BearerToken"

  try {
    & git -c $header clone $RepositoryUrl $tempPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "git clone failed for '$RepositoryUrl'."
    }

    if ($ExpectedBranchObjectId) {
      & git -C $tempPath checkout -B $Branch "origin/$Branch" | Out-Null
    } else {
      & git -C $tempPath checkout -B $Branch | Out-Null
    }
    if ($LASTEXITCODE -ne 0) {
      throw "git checkout -B $Branch failed."
    }

    if ($ExpectedBranchObjectId) {
      $currentHead = & git -C $tempPath rev-parse HEAD
      if ($LASTEXITCODE -ne 0 -or [string]$currentHead -cne $ExpectedBranchObjectId) { throw 'Repository branch changed after approval; generate a fresh setup plan before publishing files.' }
    }

    foreach ($file in $Files) {
      $targetPath = Join-Path -Path $tempPath -ChildPath $file.Path
      $targetDir = Split-Path -Path $targetPath -Parent
      if (-not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
      }

      Set-Content -LiteralPath $targetPath -Value $file.Content -Encoding utf8 -NoNewline
    }

    & git -C $tempPath add --all | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw 'git add failed.'
    }

    # Git filters and line-ending normalization must not change reviewed bytes.
    # Compare raw file objects with staged blobs without changing Git settings.
    foreach ($file in $Files) {
      $targetPath = Join-Path $tempPath $file.Path
      $rawBlob = [string](& git -C $tempPath hash-object --no-filters -- $targetPath)
      if ($LASTEXITCODE -ne 0 -or $rawBlob -cnotmatch '^[a-f0-9]{40}$') { throw 'Could not verify the raw publication blob.' }
      $stagedBlob = [string](& git -C $tempPath rev-parse ":$($file.Path)")
      if ($LASTEXITCODE -ne 0 -or $stagedBlob -cne $rawBlob) { throw "Git changed reviewed publication bytes for '$($file.Path)'; review repository filter/line-ending settings before retrying." }
    }

    $statusOutput = & git -C $tempPath status --porcelain
    if ($LASTEXITCODE -ne 0) {
      throw 'git status failed.'
    }

    if (-not $statusOutput) {
      return [pscustomobject]@{
        Pushed     = $false
        Changed    = $false
        Branch     = $Branch
        Repository = $RepositoryUrl
        CommitId   = [string](& git -C $tempPath rev-parse HEAD)
      }
    }

    & git -C $tempPath -c user.name='maester-setup' -c user.email='maester-setup@local' commit -m 'chore: bootstrap maester pipeline files' | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw 'git commit failed.'
    }

    & git -C $tempPath -c $header push origin $Branch | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "git push origin $Branch failed."
    }

    return [pscustomobject]@{
      Pushed     = $true
      Changed    = $true
      Branch     = $Branch
      Repository = $RepositoryUrl
      CommitId   = [string](& git -C $tempPath rev-parse HEAD)
    }
  }
  finally {
    if (Test-Path -Path $tempPath) {
      Remove-DirectoryQuiet -Path $tempPath
    }
  }
}

function Remove-DirectoryQuiet {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return
  }

  try {
    [System.IO.Directory]::Delete($Path, $true)
    return
  }
  catch {
    $previousProgressPreference = $ProgressPreference
    try {
      $ProgressPreference = 'SilentlyContinue'
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    finally {
      $ProgressPreference = $previousProgressPreference
    }
  }
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $projectRoot

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-SetupHelpers.psm1') -Force
Import-Module Az.Accounts -Force

$envLines = @{}
try {
  $initialEnvArgs = @('env', 'get-values', '--output', 'json')
  if ($EnvironmentName) { $initialEnvArgs += @('-e', $EnvironmentName) }
  $envLines = (& azd @initialEnvArgs 2>$null | ConvertFrom-Json -AsHashtable)
}
catch {
  $envLines = @{}
}

if (-not $SubscriptionId) {
  $SubscriptionId = if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { Get-EnvValue -Lines $envLines -Name 'AZURE_SUBSCRIPTION_ID' }
}
if (-not $TenantId) {
  $TenantId = if ($env:AZURE_TENANT_ID) { $env:AZURE_TENANT_ID } else { Get-EnvValue -Lines $envLines -Name 'AZURE_TENANT_ID' }
}
if (-not $EnvironmentName) {
  $EnvironmentName = if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { Get-EnvValue -Lines $envLines -Name 'AZURE_ENV_NAME' }
  if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
    $EnvironmentName = 'dev'
  }
}
if (-not $ResourceGroupName) {
  $ResourceGroupName = if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { Get-EnvValue -Lines $envLines -Name 'AZURE_RESOURCE_GROUP' }
  if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = "rg-$EnvironmentName"
  }
}
if (-not $PSBoundParameters.ContainsKey('PermissionProfile')) {
  $permissionProfileValue = if ($env:PERMISSION_PROFILE) { $env:PERMISSION_PROFILE } else { Get-EnvValue -Lines $envLines -Name 'PERMISSION_PROFILE' }
  if (-not [string]::IsNullOrWhiteSpace($permissionProfileValue)) {
    $PermissionProfile = $permissionProfileValue
  }
}

if (-not $PSBoundParameters.ContainsKey('IncludeExchange')) {
  $includeExchangeValue = if ($env:INCLUDE_EXCHANGE) { $env:INCLUDE_EXCHANGE } else { Get-EnvValue -Lines $envLines -Name 'INCLUDE_EXCHANGE' }
  $IncludeExchange = ConvertTo-BoolOrDefault -Value $includeExchangeValue -Default $false
}
if (-not $PSBoundParameters.ContainsKey('IncludeTeams')) {
  $includeTeamsValue = if ($env:INCLUDE_TEAMS) { $env:INCLUDE_TEAMS } else { Get-EnvValue -Lines $envLines -Name 'INCLUDE_TEAMS' }
  $IncludeTeams = ConvertTo-BoolOrDefault -Value $includeTeamsValue -Default $false
}
if (-not $PSBoundParameters.ContainsKey('IncludeAzure')) {
  $includeAzureValue = if ($env:INCLUDE_AZURE) { $env:INCLUDE_AZURE } else { Get-EnvValue -Lines $envLines -Name 'INCLUDE_AZURE' }
  $IncludeAzure = ConvertTo-BoolOrDefault -Value $includeAzureValue -Default $false
}

if (-not $PSBoundParameters.ContainsKey('AzureScopes')) {
  $rawScopes = if ($env:AZURE_RBAC_SCOPES) { $env:AZURE_RBAC_SCOPES } else { Get-EnvValue -Lines $envLines -Name 'AZURE_RBAC_SCOPES' }
  if ($rawScopes) {
    $AzureScopes = @($rawScopes -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }
}
if ($IncludeAzure -and (-not $AzureScopes -or $AzureScopes.Count -eq 0)) {
  $AzureScopes = @("/subscriptions/$SubscriptionId")
}

if (-not $SecurityGroupObjectId) {
  if ($env:SECURITY_GROUP_OBJECT_ID) {
    $SecurityGroupObjectId = $env:SECURITY_GROUP_OBJECT_ID
  }
  elseif ($env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID) {
    $SecurityGroupObjectId = $env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID
  }
  else {
    $SecurityGroupObjectId = Get-EnvValue -Lines $envLines -Name 'SECURITY_GROUP_OBJECT_ID'
    if (-not $SecurityGroupObjectId) {
      $SecurityGroupObjectId = Get-EnvValue -Lines $envLines -Name 'EASY_AUTH_SECURITY_GROUP_OBJECT_ID'
    }
  }
}
if (-not $SecurityGroupDisplayName) {
  if ($env:SECURITY_GROUP_DISPLAY_NAME) {
    $SecurityGroupDisplayName = $env:SECURITY_GROUP_DISPLAY_NAME
  }
  else {
    $SecurityGroupDisplayName = Get-EnvValue -Lines $envLines -Name 'SECURITY_GROUP_DISPLAY_NAME'
  }
}

if (-not $AdoOrganization) {
  $AdoOrganization = if ($env:AZDO_ORGANIZATION) { $env:AZDO_ORGANIZATION } else { Get-EnvValue -Lines $envLines -Name 'AZDO_ORGANIZATION' }
}
if (-not $AdoProject) {
  $AdoProject = if ($env:AZDO_PROJECT) { $env:AZDO_PROJECT } else { Get-EnvValue -Lines $envLines -Name 'AZDO_PROJECT' }
}
if (-not $AdoRepositoryName) {
  $AdoRepositoryName = if ($env:AZDO_REPOSITORY) { $env:AZDO_REPOSITORY } else { Get-EnvValue -Lines $envLines -Name 'AZDO_REPOSITORY' }
}
if (-not $AdoPipelineName) {
  $AdoPipelineName = if ($env:AZDO_PIPELINE_NAME) { $env:AZDO_PIPELINE_NAME } else { Get-EnvValue -Lines $envLines -Name 'AZDO_PIPELINE_NAME' }
}
if (-not $AdoServiceConnectionName) {
  $AdoServiceConnectionName = if ($env:AZDO_SERVICE_CONNECTION_NAME) { $env:AZDO_SERVICE_CONNECTION_NAME } else { Get-EnvValue -Lines $envLines -Name 'AZDO_SERVICE_CONNECTION_NAME' }
}
if (-not $PipelineYamlPath) {
  $PipelineYamlPath = if ($env:AZDO_PIPELINE_YAML_PATH) { $env:AZDO_PIPELINE_YAML_PATH } else { Get-EnvValue -Lines $envLines -Name 'AZDO_PIPELINE_YAML_PATH' }
}
if (-not $DefaultBranch) {
  $DefaultBranch = if ($env:AZDO_DEFAULT_BRANCH) { $env:AZDO_DEFAULT_BRANCH } else { Get-EnvValue -Lines $envLines -Name 'AZDO_DEFAULT_BRANCH' }
}
if (-not $ScheduleCron) {
  $ScheduleCron = if ($env:AZDO_SCHEDULE_CRON) { $env:AZDO_SCHEDULE_CRON } else { Get-EnvValue -Lines $envLines -Name 'AZDO_SCHEDULE_CRON' }
}

if (-not $PSBoundParameters.ContainsKey('CreateRepositoryIfMissing')) {
  $createRepoIfMissingValue = if ($env:AZDO_CREATE_REPO_IF_MISSING) { $env:AZDO_CREATE_REPO_IF_MISSING } else { Get-EnvValue -Lines $envLines -Name 'AZDO_CREATE_REPO_IF_MISSING' }
  $CreateRepositoryIfMissing = ConvertTo-BoolOrDefault -Value $createRepoIfMissingValue -Default $true
}
if (-not $PSBoundParameters.ContainsKey('PushPipelineFiles')) {
  $pushPipelineFilesValue = if ($env:AZDO_PUSH_PIPELINE_FILES) { $env:AZDO_PUSH_PIPELINE_FILES } else { Get-EnvValue -Lines $envLines -Name 'AZDO_PUSH_PIPELINE_FILES' }
  $PushPipelineFiles = ConvertTo-BoolOrDefault -Value $pushPipelineFilesValue -Default $true
}
if (-not $PSBoundParameters.ContainsKey('ValidatePipelineRun')) {
  $validatePipelineRunValue = if ($env:AZDO_VALIDATE_PIPELINE_RUN) { $env:AZDO_VALIDATE_PIPELINE_RUN } else { Get-EnvValue -Lines $envLines -Name 'AZDO_VALIDATE_PIPELINE_RUN' }
  $ValidatePipelineRun = ConvertTo-BoolOrDefault -Value $validatePipelineRunValue -Default $true
}
if (-not $PSBoundParameters.ContainsKey('FailOnTestFailures')) {
  # Always default to $false; do not persist across deployments since the old default was $true
  # and stored env values of 'true' would otherwise propagate indefinitely, causing pipeline failures.
  $FailOnTestFailures = $false
}

$SubscriptionId = Test-RequiredValue -Value $SubscriptionId -Name 'SubscriptionId'
$AdoOrganization = Test-RequiredValue -Value $AdoOrganization -Name 'AdoOrganization'
$AdoProject = Test-RequiredValue -Value $AdoProject -Name 'AdoProject'
$AdoRepositoryName = Test-RequiredValue -Value $AdoRepositoryName -Name 'AdoRepositoryName'
$AdoPipelineName = Test-RequiredValue -Value $AdoPipelineName -Name 'AdoPipelineName'
$AdoServiceConnectionName = Test-RequiredValue -Value $AdoServiceConnectionName -Name 'AdoServiceConnectionName'
if ([string]::IsNullOrWhiteSpace($PipelineYamlPath)) {
  $PipelineYamlPath = '/azure-pipelines.yml'
}
if ([string]::IsNullOrWhiteSpace($DefaultBranch)) {
  $DefaultBranch = 'main'
}
if ([string]::IsNullOrWhiteSpace($ScheduleCron)) {
  $ScheduleCron = '0 0 * * 0'
}

# Validate fresh ARM metadata before authentication or any target/permission writes.
if ([string]::IsNullOrWhiteSpace($TenantId)) {
  throw 'TenantId is required to validate the intended setup target.'
}
$selectedSubscription = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
$SubscriptionId = $selectedSubscription.id
$TenantId = $selectedSubscription.tenantId

$existingContext = Get-AzContext -ErrorAction SilentlyContinue
$requiresLogin = $true
if ($existingContext -and $existingContext.Subscription -and $existingContext.Subscription.Id -eq $SubscriptionId) {
  if (-not $TenantId -or ($existingContext.Tenant -and $existingContext.Tenant.Id -eq $TenantId)) {
    $requiresLogin = $false
  }
}

$managementToken = Get-AzCliAccessToken `
  -Resource 'https://management.azure.com/' `
  -TenantId $TenantId `
  -SubscriptionId $SubscriptionId
if (-not [string]::IsNullOrWhiteSpace($managementToken)) {
  # Refresh Az PowerShell from the target Azure CLI session so an expired
  # cached Az context cannot block post-provision setup.
  $accountId = (& az account show --subscription $SubscriptionId --query user.name -o tsv 2>$null)
  if ([string]::IsNullOrWhiteSpace($accountId)) {
    $accountId = 'azure-cli'
  }

  Connect-AzAccount `
    -AccessToken $managementToken `
    -AccountId $accountId `
    -Tenant $TenantId `
    -Subscription $SubscriptionId `
    -SkipContextPopulation | Out-Null
}
elseif ($requiresLogin) {
  $connectParameters = @{ Subscription = $SubscriptionId }
  if ($TenantId) {
    $connectParameters['Tenant'] = $TenantId
  }
  Connect-AzAccount @connectParameters | Out-Null
}

$currentContext = Get-AzContext
if (-not $currentContext -or -not $currentContext.Subscription -or -not $currentContext.Tenant -or
    [string]::IsNullOrWhiteSpace($currentContext.Tenant.Id) -or
    $currentContext.Subscription.Id -ne $SubscriptionId -or
    ($TenantId -and $currentContext.Tenant.Id -ne $TenantId)) {
  throw 'Azure PowerShell context could not be confirmed for the selected subscription and tenant. Authenticate to the selected target and retry setup.'
}
if (-not $TenantId -and $currentContext -and $currentContext.Tenant) {
  $TenantId = $currentContext.Tenant.Id
}

$subscriptionName = (Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId).name
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionName)) {
  if ($currentContext -and $currentContext.Subscription) {
    $subscriptionName = $currentContext.Subscription.Name
  }
  else {
    throw 'Could not determine subscription name from current Azure context.'
  }
}

. (Join-Path $PSScriptRoot 'Resolve-DeploymentTargets.ps1')
$deploymentValues = Get-MaesterDeploymentValues -EnvironmentName $EnvironmentName -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
$targets = Resolve-MaesterDeploymentTargets -EnvironmentValues $deploymentValues -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -EnvironmentName $EnvironmentName -SolutionName 'azure-devops' -GetResource {
  param($path)
  (Invoke-AzRestMethod -Method GET -Path $path).Content | ConvertFrom-Json
}
$storageResource = $targets.StorageAccount
$webAppResource = $targets.WebApp

# Authentication for Graph setup belongs exclusively to the dedicated public
# client. Selected runtime capabilities are not approval of any access changes.
Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-ConsentPlan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester-AdoBootstrap.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester-SetupConsent.psm1') -Force
$includeWebApp = $null -ne $webAppResource
# A manual retry in a fresh shell reads configuration from the already-verified
# named azd environment, without persisting or broadening any setup authority.
foreach ($name in @('MAESTER_SETUP_CLIENT_ID','MAESTER_SETUP_ACCOUNT','MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP','MAIL_RECIPIENT')) {
  if (-not [Environment]::GetEnvironmentVariable($name) -and $deploymentValues[$name]) {
    [Environment]::SetEnvironmentVariable($name, [string]$deploymentValues[$name])
  }
}
$bootstrapSelection = $env:MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP
if ($bootstrapSelection -and $bootstrapSelection -notin @('true','false')) { throw 'MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP must be true or false.' }
foreach ($capability in @('IncludeMailSend', 'IncludeReportSettingsWrite')) {
  $key = if ($capability -eq 'IncludeMailSend') { 'INCLUDE_MAIL_SEND' } else { 'INCLUDE_REPORT_SETTINGS_WRITE' }
  if (-not $PSBoundParameters.ContainsKey($capability)) {
    $value = if ([Environment]::GetEnvironmentVariable($key)) { [Environment]::GetEnvironmentVariable($key) } else { Get-EnvValue $envLines $key }
    if ($null -ne $value -and $value -notin @('true', 'false')) { throw "$key must be true or false." }
    Set-Variable -Name $capability -Value ($value -eq 'true')
  }
}
if ($PermissionProfile -notin @('Minimal', 'Full', 'Extended')) { throw 'Unknown permission profile. Choose Minimal, Full, or legacy Extended.' }
if ($ApplyBootstrap) { $Bootstrap = $true }
if ($Bootstrap -and ($Apply -or $ApprovedPlanHash)) { throw 'Bootstrap and setup access approval are separate stages.' }
if ($AllowGraphContextReplacement -and -not $AllowInteractiveGraphLogin) { throw 'Context replacement requires explicit interactive login and replacement approval.' }
if ($InteractiveConsent -and -not $AllowInteractiveGraphLogin) {
  if ($env:CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected) { throw 'Interactive setup is unavailable; use an existing exact session and explicit approved plan hash.' }
  $answer = Read-Host "Allow normal browser sign-in if needed for setup account '$env:MAESTER_SETUP_ACCOUNT' and tenant '$TenantId'? [y/N]"
  $AllowInteractiveGraphLogin = $answer -match '^(?i:y|yes)$'
}
if ($Bootstrap -or $env:MAESTER_SETUP_INCLUDE_RUNTIME_BOOTSTRAP -eq 'true') { $IncludeRuntimeApplicationBootstrap = $true }
$setupScopes = @(Get-MaesterSetupScopes -IncludeTeams:$IncludeTeams -IncludeWebApp:$includeWebApp)
if ($IncludeRuntimeApplicationBootstrap) { $setupScopes += 'Application.ReadWrite.All' }
$setupScopes = @($setupScopes | Sort-Object -Unique)
Assert-GraphAccess -TenantId $TenantId -ClientId $env:MAESTER_SETUP_CLIENT_ID -ExpectedAccount $env:MAESTER_SETUP_ACCOUNT `
  -Scopes $setupScopes -AllowInteractive:$AllowInteractiveGraphLogin -AllowContextReplacement:$AllowGraphContextReplacement
$adoParameters = @{
  TenantId = $TenantId; SubscriptionId = $SubscriptionId; ResourceGroupName = $ResourceGroupName; EnvironmentName = $EnvironmentName
  Organization = $AdoOrganization; Project = $AdoProject; RepositoryName = $AdoRepositoryName; ServiceConnectionName = $AdoServiceConnectionName
  SubscriptionName = $subscriptionName; SetupScopes = $setupScopes; CreateRepositoryIfMissing = $CreateRepositoryIfMissing
}
foreach ($binding in @(
  @('ExpectedServiceConnectionId', 'AZDO_SERVICE_CONNECTION_ID'), @('ExpectedApplicationId', 'AZDO_WORKLOAD_APP_ID'),
  @('ExpectedApplicationObjectId', 'AZDO_WORKLOAD_APP_OBJECT_ID'), @('ExpectedPrincipalObjectId', 'AZDO_WORKLOAD_SERVICE_PRINCIPAL_OBJECT_ID')
)) {
  $value = if ([Environment]::GetEnvironmentVariable($binding[1])) { [Environment]::GetEnvironmentVariable($binding[1]) } else { Get-EnvValue $envLines $binding[1] }
  if ($value) { $adoParameters[$binding[0]] = $value }
}
if ($Bootstrap) {
  $bootstrapPlan = Get-MaesterAdoBootstrapPlan -Parameters $adoParameters
  Write-Host ($bootstrapPlan | ConvertTo-Json -Depth 100)
  if ($InteractiveConsent) { $ApprovedBootstrapPlanHash = Confirm-MaesterConsentPlan -Plan $bootstrapPlan; $ApplyBootstrap = $true }
  if (-not $ApplyBootstrap) { Write-Host 'Bootstrap plan only. Review the exact operations and use -ApplyBootstrap -ApprovedBootstrapPlanHash.'; return $bootstrapPlan }
  $bootstrapResult = Invoke-MaesterAdoBootstrapPlan -Parameters $adoParameters -ApprovedPlanHash $ApprovedBootstrapPlanHash
  if (@($bootstrapResult.AppliedPlan.details.operations | Where-Object kind -eq 'Repository').Count) {
    $repositoryCreatedByEnvironment = $true
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_REPOSITORY_CREATED' -Value 'true'
  }
  if (@($bootstrapResult.NextPlan.missing).Count -eq 0) {
    $snapshot = $bootstrapResult.Snapshot
    foreach ($entry in @(
      @('AZDO_SERVICE_CONNECTION_ID', $snapshot.endpoint.id), @('AZDO_WORKLOAD_APP_ID', $snapshot.application.appId),
      @('AZDO_WORKLOAD_APP_OBJECT_ID', $snapshot.application.id), @('AZDO_WORKLOAD_SERVICE_PRINCIPAL_OBJECT_ID', $snapshot.principal.id),
      @('AZDO_REPOSITORY_ID', $snapshot.repository.id)
    )) { Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name $entry[0] -Value $entry[1] }
    Write-Host 'Runtime bootstrap verified. Stop here; generate and approve a separate fresh setup access plan.'
  } else {
    Write-Host 'This bootstrap stage completed. Newly resolved identities require a fresh -Bootstrap plan and exact approval before further operations.'
  }
  return $bootstrapResult
}
$adoIdentity = Get-MaesterAdoIdentity @adoParameters
$servicePrincipal = $adoIdentity.principal
$aadApplication = $adoIdentity.snapshot.application
$repository = $adoIdentity.snapshot.repository
$repositoryId = [string]$repository.id
$repositoryUrl = [string]$repository.remoteUrl
$serviceConnectionId = [string]$adoIdentity.snapshot.endpoint.id
$workloadIdentityDisplayName = [string]$aadApplication.displayName
$repositoryCreatedByEnvironment = ConvertTo-BoolOrDefault -Value (Get-EnvValue $envLines 'AZDO_REPOSITORY_CREATED') -Default $false
$securityGroupSource = if ($SecurityGroupObjectId) { 'explicit object ID' } else { 'explicit display name' }
$armHeaders = @{ Authorization = "Bearer $managementToken" }
if ([string]::IsNullOrWhiteSpace($managementToken)) {
  $managementToken = ConvertTo-PlainTextToken (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -TenantId $TenantId).Token
  if ([string]::IsNullOrWhiteSpace($managementToken)) { throw 'A target-bound ARM token is required for complete access planning.' }
  $armHeaders.Authorization = "Bearer $managementToken"
}
if ($IncludeExchange) {
  if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) { throw 'Install the reviewed ExchangeOnlineManagement module before planning Exchange access.' }
  $orgResponse = Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains'
  $domains = @($orgResponse.value | ForEach-Object { $_.verifiedDomains } | Where-Object { $_.isInitial -eq $true })
  if ($domains.Count -ne 1) { throw 'Exactly one initial tenant domain is required for Exchange access planning.' }
  $exoOrganization = $domains[0].name
  Connect-ExchangeOnlineSilent -Organization $exoOrganization -TenantId $TenantId
}

$pipelineTemplatePath = Join-Path -Path $projectRoot -ChildPath 'pipelines/template-maester.yml'
if (-not (Test-Path -Path $pipelineTemplatePath)) {
  throw "Pipeline template was not found: $pipelineTemplatePath"
}

$pipelineRepoPath = $PipelineYamlPath.Trim()
if ([string]::IsNullOrWhiteSpace($pipelineRepoPath)) {
  $pipelineRepoPath = '/azure-pipelines.yml'
}
$pipelineRepoPath = $pipelineRepoPath.TrimStart('/')

$templateContent = Get-Content -Path $pipelineTemplatePath -Raw
$runnerScriptContent = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-MaesterAzureDevOpsRun.ps1') -Raw
$moduleInstallerContent = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Install-LockedModules.ps1') -Raw
$driftInputsContent = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Maester.DriftInputs.psm1') -Raw
$assessmentEvidenceContent = Get-Content -Path (Join-Path $PSScriptRoot 'Maester.AssessmentEvidence.psm1') -Raw
$driftRunContent = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Maester.DriftRun.psm1') -Raw
$moduleLockContent = Get-Content -Path (Join-Path -Path $projectRoot -ChildPath 'runtime-packages.lock.json') -Raw

$replacementMap = @{
  '__SERVICE_CONNECTION__' = $AdoServiceConnectionName
  '__DEFAULT_BRANCH__' = $DefaultBranch
  '__SCHEDULE_CRON__' = $ScheduleCron
  '__PERMISSION_PROFILE__' = $PermissionProfile
  '__INCLUDE_MAIL_SEND__' = ([bool]$IncludeMailSend).ToString().ToLower()
  '__INCLUDE_REPORT_SETTINGS_WRITE__' = ([bool]$IncludeReportSettingsWrite).ToString().ToLower()
  '__INCLUDE_EXCHANGE__' = ([bool]$IncludeExchange).ToString().ToLower()
  '__INCLUDE_TEAMS__' = ([bool]$IncludeTeams).ToString().ToLower()
  '__INCLUDE_AZURE__' = ([bool]$IncludeAzure).ToString().ToLower()
  '__INCLUDE_WEB_APP__' = ([bool]$includeWebApp).ToString().ToLower()
  '__STORAGE_ACCOUNT_NAME__' = $storageResource.name
  '__WEB_APP_NAME__' = $(if ($webAppResource) { $webAppResource.name } else { '' })
  '__WEB_APP_RESOURCE_GROUP__' = $(if ($webAppResource) { $ResourceGroupName } else { '' })
  '__TENANT_ID__' = $TenantId
  '__SUBSCRIPTION_ID__' = $SubscriptionId
  '__CLIENT_ID__' = $aadApplication.AppId
  '__MAIL_RECIPIENT__' = $(if ($env:MAIL_RECIPIENT) { $env:MAIL_RECIPIENT } else { '' })
  '__FAIL_ON_TEST_FAILURES__' = $FailOnTestFailures.ToString().ToLower()
}

foreach ($value in $replacementMap.Values) {
  if ([string]$value -match '[\r\n\x22\x27\x60$]') { throw 'Pipeline settings must be literal single-line values without quotes, backticks or dollar-sign expansions.' }
}
$renderedPipeline = $templateContent
foreach ($key in $replacementMap.Keys) {
  $renderedPipeline = $renderedPipeline.Replace($key, [string]$replacementMap[$key])
}

$pipelineFiles = @(
  [pscustomobject]@{
    Path = $pipelineRepoPath
    Content = $renderedPipeline
  },
  [pscustomobject]@{
    Path = 'scripts/Invoke-MaesterAzureDevOpsRun.ps1'
    Content = $runnerScriptContent
  },
  [pscustomobject]@{
    Path = 'scripts/Install-LockedModules.ps1'
    Content = $moduleInstallerContent
  },
  [pscustomobject]@{
    Path = 'scripts/Maester.DriftInputs.psm1'
    Content = $driftInputsContent
  },
  [pscustomobject]@{
    Path = 'scripts/Maester.DriftRun.psm1'
    Content = $driftRunContent
  },
  [pscustomobject]@{ Path = 'scripts/Maester.AssessmentEvidence.psm1'; Content = $assessmentEvidenceContent },
  [pscustomobject]@{
    Path = 'runtime-packages.lock.json'
    Content = $moduleLockContent
  }
)

# The rendered runtime files and exact publication destination are part of the
# reviewed aggregate plan. A later source edit invalidates that approval.
$fileEvidence = @($pipelineFiles | ForEach-Object {
  [ordered]@{ path = $_.Path; sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_.Content))).ToLowerInvariant() }
})
$pipelineConfiguration = @{
  repositoryId = $repositoryId; repositoryUrl = $repositoryUrl; pipelineName = $AdoPipelineName
  yamlPath = $pipelineRepoPath; branch = $DefaultBranch; schedule = $ScheduleCron
  pushFiles = $PushPipelineFiles; validateRun = $ValidatePipelineRun; files = $fileEvidence
}
$accessPlanParameters = @{
  TenantId = $TenantId; SubscriptionId = $SubscriptionId; PrincipalObjectId = $servicePrincipal.id
  ResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
  StorageAccount = $storageResource; WebApp = $webAppResource; ArmHeaders = $armHeaders
  AdoParameters = $adoParameters; PipelineConfiguration = $pipelineConfiguration
  SecurityGroupObjectId = $SecurityGroupObjectId; SecurityGroupDisplayName = $SecurityGroupDisplayName
  PermissionProfile = $PermissionProfile; IncludeMailSend = [bool]$IncludeMailSend; IncludeReportSettingsWrite = [bool]$IncludeReportSettingsWrite
  IncludeExchange = $IncludeExchange; IncludeTeams = $IncludeTeams; IncludeAzure = $IncludeAzure; AzureScopes = $AzureScopes
}
if (-not (Get-Module -ListAvailable -Name ADOPS)) { throw 'Install the reviewed ADOPS setup dependency before applying pipeline configuration.' }
Import-Module ADOPS -Force

$accessPlan = Get-MaesterSetupAccessPlan @accessPlanParameters
Write-Host ($accessPlan | ConvertTo-Json -Depth 100)
if ($InteractiveConsent) { $ApprovedPlanHash = Confirm-MaesterConsentPlan -Plan $accessPlan; $Apply = $true }
if (-not $Apply) { Write-Host 'Plan only. No grants, app changes, pipeline permissions, file pushes, runs or receipts were written.'; return $accessPlan }
$accessResult = Invoke-MaesterSetupAccessPlan -PlanParameters $accessPlanParameters -ApprovedPlanHash $ApprovedPlanHash
$approvedPipeline = $accessResult.Plan.details.pipelineInventory.pipeline
# Rebind before publishing files or reusing a pipeline after access writes.
$pipelineBinding = Assert-MaesterAdoPipelineBinding -Identity $adoIdentity -Configuration $pipelineConfiguration -Parameters $adoParameters -ExpectedPipeline $approvedPipeline
$baseRoleAssignmentIds = @($accessResult.Receipts.AZDO_BASE_ROLE_ASSIGNMENT_IDS)
$exoAppRoleAssignmentIds = @($accessResult.Receipts.EXO_APPROLE_ASSIGNMENT_IDS)
$teamsRoleAssignmentIds = @($accessResult.Receipts.TEAMS_READER_ROLE_ASSIGNMENT_IDS)
$azureRoleAssignmentIds = @($accessResult.Receipts.AZURE_ROLE_ASSIGNMENT_IDS)
$exchangeSetupStatus = if ($IncludeExchange) { 'configured' } else { 'disabled' }
$teamsSetupStatus = if ($IncludeTeams) { 'configured' } else { 'disabled' }
$azureSetupStatus = if ($IncludeAzure) { 'configured' } else { 'disabled' }
foreach ($name in $accessResult.Receipts.Keys) {
  # Receipts from earlier successful runs remain valid and must not be discarded.
  $existing = @(Get-EnvValue $envLines $name) -split ';' | Where-Object { $_ }
  Set-MaesterAzdEnvJsonArray -EnvironmentName $EnvironmentName -Name $name -Values @($existing + $accessResult.Receipts[$name] | Sort-Object -Unique)
}
foreach ($entry in @(@('SETUP_EXCHANGE_STATUS', $exchangeSetupStatus), @('SETUP_TEAMS_STATUS', $teamsSetupStatus), @('SETUP_AZURE_STATUS', $azureSetupStatus))) {
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name $entry[0] -Value $entry[1]
}
if ($accessResult.EasyAuth) {
  foreach ($entry in @(@('EASY_AUTH_ENTRA_APP_OBJECT_ID', $accessResult.EasyAuth.objectId), @('EASY_AUTH_ENTRA_APP_CLIENT_ID', $accessResult.EasyAuth.clientId), @('EASY_AUTH_ENTRA_APP_DISPLAY_NAME', $accessResult.EasyAuth.displayName))) {
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name $entry[0] -Value $entry[1]
  }
  $SecurityGroupObjectId = $accessResult.EasyAuth.securityGroupId
}
$devOpsToken = Get-AzureDevOpsAccessToken -TenantId $TenantId
Connect-ADOPS -Organization $AdoOrganization -OAuthToken $devOpsToken -SkipVerification | Out-Null

$pushResult = [pscustomobject]@{
  Pushed     = $false
  Changed    = $false
  Branch     = $DefaultBranch
  Repository = $repositoryUrl
}

$manualFilesPath = $null
if ($PushPipelineFiles) {
  try {
    $pushResult = Push-RepositoryFiles -RepositoryUrl $repositoryUrl -Branch $DefaultBranch -BearerToken $devOpsToken -Files $pipelineFiles -ExpectedBranchObjectId $accessResult.Plan.details.pipelineInventory.branchObjectId
    if ($pushResult.Pushed) {
      Write-Host "Pipeline files pushed to repository '$AdoRepositoryName' branch '$DefaultBranch'."
    }
    elseif (-not $pushResult.Changed) {
      Write-Host 'Pipeline files were already up to date. No push was required.'
    }
  }
  catch {
    Write-Warning "Automatic pipeline file push failed. Falling back to manual instructions. Error: $($_.Exception.Message)"

    $manualFilesPath = Join-Path -Path $projectRoot -ChildPath ("outputs/{0}-pipeline-files" -f $EnvironmentName)
    if (Test-Path -Path $manualFilesPath) {
      Remove-DirectoryQuiet -Path $manualFilesPath
    }
    New-Item -Path $manualFilesPath -ItemType Directory -Force | Out-Null

    foreach ($file in $pipelineFiles) {
      $target = Join-Path -Path $manualFilesPath -ChildPath $file.Path
      $targetDir = Split-Path -Path $target -Parent
      if (-not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
      }
      Set-Content -LiteralPath $target -Value $file.Content -Encoding utf8 -NoNewline
    }

    Write-Warning "Manual pipeline files created at: $manualFilesPath"
  }
}

if (-not $PushPipelineFiles) {
  Write-Host 'PushPipelineFiles=false, skipping automatic repository push.'
}

Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_PIPELINE_FILES_PUSHED' -Value $pushResult.Pushed.ToString().ToLower()
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_FAIL_ON_TEST_FAILURES' -Value $FailOnTestFailures.ToString().ToLower()
if ($manualFilesPath) {
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_MANUAL_PIPELINE_FILES_PATH' -Value $manualFilesPath
}
else {
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_MANUAL_PIPELINE_FILES_PATH' -Value ''
}

# Re-read again at the definition boundary; never adopt a same-name replacement.
$pipelineBinding = Assert-MaesterAdoPipelineBinding -Identity $adoIdentity -Configuration $pipelineConfiguration -Parameters $adoParameters -ExpectedPipeline $approvedPipeline
$pipeline = $pipelineBinding
if (-not $pipeline) {
  Write-Host "Creating pipeline '$AdoPipelineName'..."
  try {
    $createdPipeline = New-ADOPSPipeline -Project $AdoProject -Name $AdoPipelineName -Repository $AdoRepositoryName -YamlPath "/$pipelineRepoPath" -Organization $AdoOrganization
    $pipelineBinding = Assert-MaesterAdoPipelineBinding -Identity $adoIdentity -Configuration $pipelineConfiguration -Parameters $adoParameters -CreatedPipelineId ([string]$createdPipeline.id)
    $pipeline = $pipelineBinding
  } catch {
    if ($manualFilesPath) {
      throw "Pipeline creation failed because the YAML file is not yet in repository '$AdoRepositoryName'. Upload files from '$manualFilesPath' and rerun Setup-PostDeploy.ps1. Error: $($_.Exception.Message)"
    }
    throw
  }
}

Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_PIPELINE_NAME' -Value $AdoPipelineName
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_PIPELINE_ID' -Value ([string]$pipeline.id)

$pipelineUrl = "https://dev.azure.com/$AdoOrganization/$AdoProject/_build?definitionId=$($pipeline.id)"
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_PIPELINE_URL' -Value $pipelineUrl

$validationResult = [pscustomobject]@{
  ValidationPassed = 'skipped'
  PipelineName     = $AdoPipelineName
  PipelineId       = $pipeline.id
  RunId            = 'n/a'
  FinalState       = 'skipped'
  FinalResult      = 'skipped'
  RunUrl           = $pipelineUrl
  CompletedAt      = (Get-Date).ToString('o')
}

if ($ValidatePipelineRun) {
  if ($manualFilesPath) { throw 'Pipeline files require manual publication. Review a fresh plan after upload before validation.' }
  $pipelineBinding = Assert-MaesterAdoPipelineBinding -Identity $adoIdentity -Configuration $pipelineConfiguration -Parameters $adoParameters -ExpectedPipeline $pipelineBinding
  $sourceVersion = if ($PushPipelineFiles) { [string](Get-OptionalPropertyValue -InputObject $pushResult -PropertyNames 'CommitId') } else { [string]$accessResult.Plan.details.pipelineInventory.branchObjectId }
  if ($sourceVersion -cnotmatch '^[a-f0-9]{40}$') { throw 'An exact reviewed or published source commit is required before validation.' }
  Write-Host 'Starting and validating initial Azure DevOps pipeline run...'
  $validationResult = & "$PSScriptRoot\Invoke-PipelineValidation.ps1" `
    -AdoOrganization $AdoOrganization `
    -AdoProject $AdoProject `
    -PipelineName $AdoPipelineName `
    -Branch $DefaultBranch `
    -TimeoutMinutes 30 `
    -ExpectedPipelineBinding $pipelineBinding `
    -ExpectedSourceVersion $sourceVersion `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -PassThru

  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_LAST_PIPELINE_RUN_ID' -Value ([string]$validationResult.RunId)
  if ($validationResult.RunUrl) {
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AZDO_LAST_PIPELINE_RUN_URL' -Value $validationResult.RunUrl
  }
}
$summaryDir = Join-Path -Path $projectRoot -ChildPath 'outputs'
if (-not (Test-Path -Path $summaryDir)) {
  New-Item -Path $summaryDir -ItemType Directory -Force | Out-Null
}

$summaryPath = Join-Path -Path $summaryDir -ChildPath ("{0}-setup-summary.md" -f $EnvironmentName)
$summaryLines = @()
$summaryLines += '# Deployment and Validation Summary'
$summaryLines += ''
$summaryLines += "Generated: $(Get-Date -Format u)"
$summaryLines += "Environment: $EnvironmentName"
$summaryLines += "Subscription: $SubscriptionId"
$summaryLines += "Resource group: $ResourceGroupName"
$summaryLines += "Azure DevOps organization: $AdoOrganization"
$summaryLines += "Azure DevOps project: $AdoProject"
$summaryLines += "Azure DevOps repository: $AdoRepositoryName"
$summaryLines += "Azure DevOps repository id: $repositoryId"
$summaryLines += "Azure DevOps pipeline: $AdoPipelineName"
$summaryLines += "Azure DevOps pipeline id: $($pipeline.id)"
$summaryLines += "Azure DevOps pipeline url: $pipelineUrl"
$summaryLines += "Azure DevOps service connection: $AdoServiceConnectionName"
$summaryLines += "Azure DevOps service connection id: $serviceConnectionId"
$summaryLines += "Workload identity app display name: $workloadIdentityDisplayName"
$summaryLines += "Workload identity appId: $($aadApplication.AppId)"
$summaryLines += "Workload identity app objectId: $($aadApplication.Id)"
$summaryLines += "Workload identity service principal objectId: $($servicePrincipal.Id)"
$summaryLines += "Repository auto-create enabled: $($CreateRepositoryIfMissing.ToString().ToLower())"
$summaryLines += "Pipeline auto-push enabled: $($PushPipelineFiles.ToString().ToLower())"
$summaryLines += "Pipeline validation enabled: $($ValidatePipelineRun.ToString().ToLower())"
$summaryLines += "Fail pipeline step on Maester failed tests: $($FailOnTestFailures.ToString().ToLower())"
$summaryLines += "Pipeline files push result: $($pushResult.Pushed.ToString().ToLower())"
$summaryLines += "Manual pipeline files path: $(if ($manualFilesPath) { $manualFilesPath } else { 'n/a' })"
$summaryLines += "Schedule cron: $ScheduleCron"
$summaryLines += "Default branch: $DefaultBranch"
$summaryLines += "Include web app: $($includeWebApp.ToString().ToLower())"
$summaryLines += "Include Exchange: $([bool]$IncludeExchange)"
$summaryLines += "Include Teams: $([bool]$IncludeTeams)"
$summaryLines += "Include Azure: $([bool]$IncludeAzure)"
$summaryLines += "Permission profile: $PermissionProfile"
$summaryLines += "Azure RBAC scopes: $(@($AzureScopes) -join ';')"
$summaryLines += "Exchange setup status: $exchangeSetupStatus"
$summaryLines += "Teams setup status: $teamsSetupStatus"
$summaryLines += "Azure setup status: $azureSetupStatus"
$summaryLines += "Security group object id: $(if ($SecurityGroupObjectId) { $SecurityGroupObjectId } else { 'n/a' })"
$summaryLines += "Security group display name: $(if ($SecurityGroupDisplayName) { $SecurityGroupDisplayName } else { 'n/a' })"
$summaryLines += ''
$summaryLines += '## Resources Created'
$summaryLines += "- Storage Account: $($storageResource.name)"
$summaryLines += "- Web App: $(if ($webAppResource) { $webAppResource.name } else { 'not deployed' })"
$summaryLines += ''
$summaryLines += '## Role Assignments Created'
$summaryLines += "- Base Azure role assignment ids: $(@($baseRoleAssignmentIds) -join ';')"
$summaryLines += "- Exchange app role assignment ids: $(@($exoAppRoleAssignmentIds) -join ';')"
$summaryLines += "- Teams role assignment ids: $(@($teamsRoleAssignmentIds) -join ';')"
$summaryLines += "- Azure role assignment ids: $(@($azureRoleAssignmentIds) -join ';')"
$summaryLines += ''
$summaryLines += '## Validation Results'
$summaryLines += "- Initial pipeline run status: $($validationResult.FinalResult)"
$summaryLines += "- Initial pipeline run id: $($validationResult.RunId)"
$summaryLines += "- Initial pipeline run url: $($validationResult.RunUrl)"
$summaryLines += "- Validation completed at: $($validationResult.CompletedAt)"

Set-Content -Path $summaryPath -Value ($summaryLines -join [Environment]::NewLine) -Encoding utf8
Write-Host "Deployment summary written to: $summaryPath"








