[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-PreProvision.psm1') -Force

Invoke-MaesterPreProvision `
  -SolutionName 'azure-devops' `
  -SubscriptionId $SubscriptionId `
  -TenantId $TenantId `
  -Location $env:AZURE_LOCATION `
  -RequireGit `
  -RequireAdopsModule

function Get-AzdEnvironmentValues {
  $json = (& azd env get-values --output json 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($json -join ''))) {
    throw 'Could not read azd environment values for Azure DevOps preflight.'
  }

  return ($json | ConvertFrom-Json -AsHashtable)
}

function Get-AzureDevOpsAccessToken {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId
  )

  $token = & az account get-access-token `
    --subscription $SubscriptionId `
    --resource '499b84ac-1321-427f-aa17-267ca6975798' `
    --query accessToken `
    -o tsv 2>$null

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'Could not acquire an Azure DevOps token for preflight. Ensure azd/az authentication is active for the selected subscription.'
  }

  return ([string]$token).Trim()
}

function Invoke-AzureDevOpsPreflight {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId
  )

  $envValues = Get-AzdEnvironmentValues
  $organization = [string]$envValues['AZDO_ORGANIZATION']
  $projectName = [string]$envValues['AZDO_PROJECT']
  $repositoryName = [string]$envValues['AZDO_REPOSITORY']

  if ([string]::IsNullOrWhiteSpace($organization) -or [string]::IsNullOrWhiteSpace($projectName)) {
    throw 'AZDO_ORGANIZATION and AZDO_PROJECT are required for Azure DevOps preflight.'
  }

  $token = Get-AzureDevOpsAccessToken -SubscriptionId $SubscriptionId
  $headers = @{ Authorization = "Bearer $token" }
  $projectEncoded = [System.Uri]::EscapeDataString($projectName)
  $projectUri = "https://dev.azure.com/$organization/_apis/projects/$($projectEncoded)?api-version=7.1"
  $projectStatus = 0
  $project = Invoke-RestMethod -Method GET -Uri $projectUri -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable projectStatus
  if ($projectStatus -ge 400 -or -not $project.id) {
    throw "Azure DevOps project '$projectName' was not accessible in organization '$organization'. HTTP $projectStatus"
  }

  $repositoriesUri = "https://dev.azure.com/$organization/$($projectEncoded)/_apis/git/repositories?api-version=7.1-preview.1"
  $repositoriesStatus = 0
  $repositories = Invoke-RestMethod -Method GET -Uri $repositoriesUri -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable repositoriesStatus
  if ($repositoriesStatus -ge 400) {
    throw "Azure DevOps repositories could not be read for project '$projectName'. HTTP $repositoriesStatus"
  }

  $existingRepository = @($repositories.value | Where-Object { $_.name -ieq $repositoryName }) | Select-Object -First 1
  if ($existingRepository) {
    Write-Host "Azure DevOps preflight passed: project '$projectName' and repository '$repositoryName' are accessible."
    return
  }

  $createRepositoryValue = [string]$envValues['AZDO_CREATE_REPO_IF_MISSING']
  if ($createRepositoryValue -and $createRepositoryValue.Trim().ToLowerInvariant() -eq 'false') {
    throw "Azure DevOps repository '$repositoryName' was not found and AZDO_CREATE_REPO_IF_MISSING=false."
  }

  $gitNamespaceId = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87'
  $createRepositoryBit = 256
  $securityToken = "repoV2/$($project.id)"
  $permissionUri = "https://dev.azure.com/$organization/_apis/permissions/$gitNamespaceId/$($createRepositoryBit)?tokens=$([System.Uri]::EscapeDataString($securityToken))&alwaysAllowAdministrators=false&api-version=7.1"
  $permissionStatus = 0
  $permissionResponse = Invoke-RestMethod -Method GET -Uri $permissionUri -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable permissionStatus
  if ($permissionStatus -ge 400) {
    throw "Azure DevOps Git CreateRepository permission could not be checked for project '$projectName'. HTTP $permissionStatus"
  }

  $canCreateRepository = [bool](@($permissionResponse.value)[0])
  if (-not $canCreateRepository) {
    throw "Azure DevOps preflight failed: the current identity cannot create Git repositories in project '$projectName'. Grant active Code access (Basic or a Visual Studio subscription) and the project-level 'Create repository' permission before running azd up."
  }

  Write-Host "Azure DevOps preflight passed: repository '$repositoryName' can be created in project '$projectName'."
}

$effectiveSubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { $env:AZURE_SUBSCRIPTION_ID }
Invoke-AzureDevOpsPreflight -SubscriptionId $effectiveSubscriptionId
