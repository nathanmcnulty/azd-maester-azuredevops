#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$IncludeExchange = 'false',

  [Parameter(Mandatory = $false)]
  [string]$IncludeTeams = 'false',

  [Parameter(Mandatory = $false)]
  [string]$IncludeAzure = 'false',

  [Parameter(Mandatory = $false)]
  [string]$IncludeWebApp = 'false',

  [Parameter(Mandatory = $false)]
  [string]$StorageAccountName,

  [Parameter(Mandatory = $false)]
  [string]$WebAppName,

  [Parameter(Mandatory = $false)]
  [string]$WebAppResourceGroup,

  [Parameter(Mandatory = $false)]
  [string]$TenantId,

  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$ClientId,

  [Parameter(Mandatory = $false)]
  [string]$MailRecipient = '',

  [Parameter(Mandatory = $false)]
  [string]$FailOnTestFailures = 'false',

  [Parameter(Mandatory = $false)]
  [switch]$EnableApprovedDrift,

  [Parameter(Mandatory = $false)]
  [string]$DriftInputRoot,

  [Parameter(Mandatory = $false)]
  [string]$DriftExpectedBaselineManifestSha256,

  [Parameter(Mandatory = $false)]
  [string]$DriftExpectedTenantId,

  [Parameter(Mandatory = $false)]
  [string]$DriftEnvironment,

  [Parameter(Mandatory = $false)]
  [string]$DriftRunId,

  [Parameter(Mandatory = $false)]
  [string]$DriftProducerId,

  [Parameter(Mandatory = $false)]
  [string]$DriftProducerRevision,

  [Parameter(Mandatory = $false)]
  [ValidateRange(1, 60)]
  [int]$DriftMaxAgeMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Bool {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return $Value.Trim().ToLower() -eq 'true'
}

function Assert-ApprovedDriftCliOptions {
  param(
    [Parameter(Mandatory = $true)][bool]$Enabled,
    [Parameter(Mandatory = $true)][System.Collections.IDictionary]$BoundParameters,
    [string]$InputRoot,
    [string]$ExpectedBaselineManifestSha256,
    [string]$ExpectedTenantId,
    [string]$ConfiguredTenantId,
    [string]$Environment,
    [string]$RunId,
    [string]$ProducerId,
    [string]$ProducerRevision,
    [string]$StorageAccountName,
    [string]$MailRecipient,
    [bool]$IncludeWebApp
  )

  $driftParameterNames = @(
    'DriftInputRoot', 'DriftExpectedBaselineManifestSha256', 'DriftExpectedTenantId',
    'DriftEnvironment', 'DriftRunId', 'DriftProducerId', 'DriftProducerRevision',
    'DriftMaxAgeMinutes'
  )
  if (-not $Enabled) {
    foreach ($name in $driftParameterNames) {
      if ($BoundParameters.ContainsKey($name)) { throw 'drift.optionsRequireEnablement' }
    }
    return
  }

  foreach ($value in @($InputRoot, $ExpectedBaselineManifestSha256, $ExpectedTenantId, $ConfiguredTenantId, $Environment, $RunId, $ProducerId, $ProducerRevision)) {
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'drift.optionsIncomplete' }
  }
  if ($ExpectedBaselineManifestSha256 -cnotmatch '^[0-9a-f]{64}\z' -or $ProducerRevision -cnotmatch '^[0-9a-f]{40}\z') {
    throw 'drift.optionsInvalid'
  }
  if (-not [string]::Equals($ExpectedTenantId, $ConfiguredTenantId, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'drift.tenantConfigurationMismatch'
  }
  if (-not [string]::IsNullOrWhiteSpace($MailRecipient) -or $IncludeWebApp) {
    throw 'drift.publishingAudienceUnsupported'
  }
  if ([string]::IsNullOrWhiteSpace($StorageAccountName)) { throw 'drift.storageDestinationRequired' }
  if ($StorageAccountName -cnotmatch '^[a-z0-9]{3,24}\z') { throw 'drift.storageDestinationInvalid' }
}

function Assert-ApprovedDriftOutputScope {
  param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string[]]$WorkspaceRoots
  )
  $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RunRoot))
  $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  foreach ($workspace in $WorkspaceRoots) {
    if ([string]::IsNullOrWhiteSpace($workspace)) { continue }
    $boundary = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($workspace))
    $prefix = $boundary.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ([string]::Equals($root, $boundary, $comparison) -or $root.StartsWith($prefix, $comparison)) {
      throw 'drift.outputInsideWorkspace'
    }
  }
}

function Remove-ApprovedDriftRunRoot {
  if (-not $EnableApprovedDrift -or $null -eq $approvedDriftRun) { return }
  Remove-DriftOwnedDirectory `
    -Path $approvedDriftRun.Root `
    -Parent $approvedDriftRun.Parent `
    -LeafPattern ('^' + [regex]::Escape($approvedDriftRun.Leaf) + '\z')
}

function ConvertTo-PlainTextToken {
  param([Parameter(Mandatory = $true)]$TokenValue)

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

function Get-AzAccessTokenPlainText {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceUrl,

    [Parameter(Mandatory = $false)]
    [string]$Tenant
  )

  $tokenParams = @{
    ResourceUrl = $ResourceUrl
  }

  if (-not [string]::IsNullOrWhiteSpace($Tenant)) {
    $tokenParams['TenantId'] = $Tenant
  }

  $tokenResponse = Get-AzAccessToken @tokenParams -AsSecureString
  return (ConvertTo-PlainTextToken -TokenValue $tokenResponse.Token).Trim()
}

function Get-JwtTokenSummary {
  param([Parameter(Mandatory = $true)][string]$Token)

  $tokenText = [string]$Token
  $tokenText = $tokenText.Trim()

  $dotCount = ([regex]::Matches($tokenText, '\.')).Count
  if ($dotCount -lt 2) {
    return [pscustomobject]@{
      AppId  = ''
      Tid    = ''
      Aud    = ''
      IdType = ''
      HasScp = $false
      IsJwt  = $false
      Length = $tokenText.Length
      DotCount = $dotCount
    }
  }

  try {
    Add-Type -AssemblyName System.IdentityModel.Tokens.Jwt -ErrorAction SilentlyContinue
    $tokenHandler = [System.IdentityModel.Tokens.Jwt.JwtSecurityTokenHandler]::new()
    $jwt = $tokenHandler.ReadJwtToken($tokenText)
    $claimMap = @{}
    foreach ($claim in $jwt.Claims) {
      if (-not $claimMap.ContainsKey($claim.Type)) {
        $claimMap[$claim.Type] = $claim.Value
      }
    }

    $appidClaim = ''
    if ($claimMap.ContainsKey('appid')) {
      $appidClaim = [string]$claimMap['appid']
    }

    $tidClaim = ''
    if ($claimMap.ContainsKey('tid')) {
      $tidClaim = [string]$claimMap['tid']
    }

    $idtypClaim = ''
    if ($claimMap.ContainsKey('idtyp')) {
      $idtypClaim = [string]$claimMap['idtyp']
    }

    $hasScpClaim = $claimMap.ContainsKey('scp') -and -not [string]::IsNullOrWhiteSpace([string]$claimMap['scp'])

    return [pscustomobject]@{
      AppId  = $appidClaim
      Tid    = $tidClaim
      Aud    = [string]$jwt.Audiences -join ','
      IdType = $idtypClaim
      HasScp = $hasScpClaim
      IsJwt  = $true
      Length = $tokenText.Length
      DotCount = $dotCount
    }
  }
  catch {
    return [pscustomobject]@{
      AppId  = ''
      Tid    = ''
      Aud    = ''
      IdType = ''
      HasScp = $false
      IsJwt  = $false
      Length = $tokenText.Length
      DotCount = $dotCount
    }
  }
}

function Compress-FileToGzip {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InputFilePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputFilePath
  )

  $inputBytes = [System.IO.File]::ReadAllBytes($InputFilePath)
  $outputDirectory = Split-Path -Path $OutputFilePath -Parent
  if (-not (Test-Path -Path $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
  }

  $outStream = [System.IO.File]::Open($OutputFilePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
  try {
    $gzipStream = New-Object System.IO.Compression.GzipStream($outStream, [System.IO.Compression.CompressionMode]::Compress)
    try {
      $gzipStream.Write($inputBytes, 0, $inputBytes.Length)
    }
    finally {
      $gzipStream.Dispose()
    }
  }
  finally {
    $outStream.Dispose()
  }
}

function Get-NUnitFailureCount {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -Path $Path)) {
    throw "Required Maester NUnit result file was not generated: $Path"
  }

  [xml]$xml = Get-Content -Path $Path -Raw
  if ($xml.'test-results' -and $xml.'test-results'.failures) {
    return [int]$xml.'test-results'.failures
  }

  if ($xml.testRun -and $xml.testRun.ResultSummary -and $xml.testRun.ResultSummary.Counters -and $xml.testRun.ResultSummary.Counters.failed) {
    return [int]$xml.testRun.ResultSummary.Counters.failed
  }

  throw "Maester NUnit result file has no recognized failure count: $Path"
}

$includeExchangeBool = ConvertTo-Bool -Value $IncludeExchange
$includeTeamsBool = ConvertTo-Bool -Value $IncludeTeams
$includeWebAppBool = ConvertTo-Bool -Value $IncludeWebApp
$failOnTestFailuresBool = ConvertTo-Bool -Value $FailOnTestFailures

Assert-ApprovedDriftCliOptions `
  -Enabled $EnableApprovedDrift `
  -BoundParameters $PSBoundParameters `
  -InputRoot $DriftInputRoot `
  -ExpectedBaselineManifestSha256 $DriftExpectedBaselineManifestSha256 `
  -ExpectedTenantId $DriftExpectedTenantId `
  -ConfiguredTenantId $TenantId `
  -Environment $DriftEnvironment `
  -RunId $DriftRunId `
  -ProducerId $DriftProducerId `
  -ProducerRevision $DriftProducerRevision `
  -StorageAccountName $StorageAccountName `
  -MailRecipient $MailRecipient `
  -IncludeWebApp $includeWebAppBool

Write-Host 'Installing hash-verified PowerShell modules...'
$lockPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime-packages.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw -ErrorAction Stop | ConvertFrom-Json
$versions = @{}
foreach ($package in $lock.packages) { $versions[[string]$package.name] = [string]$package.version }
$tempRoot = if ([string]::IsNullOrWhiteSpace($env:AGENT_TEMPDIRECTORY)) { [IO.Path]::GetTempPath() } else { $env:AGENT_TEMPDIRECTORY }
$moduleRoot = Join-Path $tempRoot "maester-modules-$([guid]::NewGuid().ToString('N'))"
& (Join-Path $PSScriptRoot 'Install-LockedModules.ps1') -LockPath $lockPath -DestinationRoot $moduleRoot
$env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"

foreach ($name in @('PackageManagement', 'PowerShellGet', 'Az.Accounts', 'Az.Storage', 'Microsoft.Graph.Authentication', 'Pester', 'Maester')) {
  if (-not $versions.ContainsKey($name)) { throw "Runtime package lock is missing '$name'." }
  Import-Module $name -RequiredVersion $versions[$name] -Force -ErrorAction Stop
}
if ($includeExchangeBool) {
  Import-Module ExchangeOnlineManagement -RequiredVersion $versions['ExchangeOnlineManagement'] -Force -ErrorAction Stop
}
if ($includeTeamsBool) {
  Import-Module MicrosoftTeams -RequiredVersion $versions['MicrosoftTeams'] -Force -ErrorAction Stop
}
if ($includeWebAppBool) {
  Import-Module Az.Websites -RequiredVersion $versions['Az.Websites'] -Force -ErrorAction Stop
}

if ([string]::IsNullOrWhiteSpace($env:idToken) -or [string]::IsNullOrWhiteSpace($env:servicePrincipalId) -or
    [string]::IsNullOrWhiteSpace($env:tenantId)) {
  throw 'Azure DevOps workload identity token was not supplied by the service connection.'
}
if ($env:tenantId -ine $TenantId) { throw 'Azure DevOps service connection tenant differs from the configured Maester tenant.' }
if ([string]::IsNullOrWhiteSpace($ClientId) -or $env:servicePrincipalId -ine $ClientId) {
  throw 'Azure DevOps service connection application differs from the configured Maester application.'
}
$serviceSubscriptionId = (& az account show --query id --output tsv --only-show-errors) -join ''
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serviceSubscriptionId)) { throw 'Azure CLI did not return the service connection subscription.' }
if ([string]::IsNullOrWhiteSpace($SubscriptionId) -or $serviceSubscriptionId -ine $SubscriptionId) {
  throw 'Azure DevOps service connection subscription differs from the configured Maester subscription.'
}
Connect-AzAccount -ServicePrincipal -ApplicationId $env:servicePrincipalId -Tenant $env:tenantId `
  -FederatedToken $env:idToken -Subscription $serviceSubscriptionId -ErrorAction Stop | Out-Null

$azCtx = Get-AzContext -ErrorAction SilentlyContinue
if ($azCtx -and $azCtx.Subscription) {
  Update-AzConfig -DefaultSubscriptionForLogin $azCtx.Subscription.Id -WarningAction SilentlyContinue | Out-Null
}

Write-Host 'Acquiring Microsoft Graph token and connecting...'
$graphAccessToken = Get-AzAccessTokenPlainText -ResourceUrl 'https://graph.microsoft.com' -Tenant $TenantId
$graphSecureToken = ConvertTo-SecureString -String $graphAccessToken -AsPlainText -Force
Connect-MgGraph -AccessToken $graphSecureToken -NoWelcome

if ($includeExchangeBool) {
  Write-Host 'Connecting to Exchange Online with workload identity token...'
  $outlookToken = Get-AzAccessTokenPlainText -ResourceUrl 'https://outlook.office365.com' -Tenant $TenantId

  $exoOrganization = $null
  try {
    $domainsResponse = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$select=id,isInitial'
    if ($domainsResponse -and $domainsResponse.value) {
      $initialDomain = @($domainsResponse.value | Where-Object { $_.isInitial -eq $true }) | Select-Object -First 1
      if ($initialDomain -and $initialDomain.id) {
        $exoOrganization = $initialDomain.id
      }
    }
  }
  catch {
    Write-Warning ("Could not resolve tenant initial domain for Exchange. Error: {0}" -f $_.Exception.Message)
  }

  $exoBaseArgs = @{
    AccessToken = $outlookToken
    ShowBanner  = $false
  }
  if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
    $exoBaseArgs['AppId'] = $ClientId
  }

  $exoConnected = $false
  $exoMaxAttempts = 3
  $exoRetryDelay = 20
  for ($exoAttempt = 1; $exoAttempt -le $exoMaxAttempts; $exoAttempt++) {
    try {
      $connectedThisAttempt = $false

      if ($exoOrganization) {
        try {
          $argsWithOrg = @{} + $exoBaseArgs
          $argsWithOrg['Organization'] = $exoOrganization
          Connect-ExchangeOnline @argsWithOrg | Out-Null
          $connectedThisAttempt = $true
        }
        catch {
          Write-Verbose ("Exchange connection with Organization '{0}' failed. Retrying without Organization. Error: {1}" -f $exoOrganization, $_.Exception.Message)
        }
      }

      if (-not $connectedThisAttempt) {
        Connect-ExchangeOnline @exoBaseArgs | Out-Null
        $connectedThisAttempt = $true
      }

      if ($connectedThisAttempt) {
        $exoConnected = $true
        Write-Host 'Exchange Online connection established.'
        break
      }
    }
    catch {
      if ($exoAttempt -lt $exoMaxAttempts) {
        Write-Warning ("Exchange Online connection attempt {0}/{1} failed: {2}. Retrying in {3}s..." -f $exoAttempt, $exoMaxAttempts, $_.Exception.Message, $exoRetryDelay)
        Start-Sleep -Seconds $exoRetryDelay
        $exoRetryDelay = [Math]::Min($exoRetryDelay * 2, 120)
      }
      else {
        Write-Warning ("Exchange Online connection failed after {0} attempts. Exchange-related tests may be skipped. Last error: {1}" -f $exoMaxAttempts, $_.Exception.Message)
      }
    }
  }

  if ($exoConnected) {
    try {
      $ippsConnectArgs = @{
        AccessToken = $outlookToken
        ShowBanner  = $false
      }
      if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
        $ippsConnectArgs['AppId'] = $ClientId
      }
      if ($exoOrganization) {
        $ippsConnectArgs['Organization'] = $exoOrganization
      }
      Connect-IPPSSession @ippsConnectArgs | Out-Null

      Write-Host 'Security & Compliance (IPPS) connection established.'
    }
    catch {
      Write-Warning ("Security & Compliance (IPPS) connection failed. Compliance-related tests may be skipped. Error: {0}" -f $_.Exception.Message)
    }
  }
}

if ($includeTeamsBool) {
  Write-Host 'Connecting to Microsoft Teams with workload identity tokens...'
  try {
    $teamsToken = Get-AzAccessTokenPlainText -ResourceUrl '48ac35b8-9aa8-4d74-927d-1f4a14a0b239' -Tenant $TenantId

    $graphTokenSummary = Get-JwtTokenSummary -Token $graphAccessToken
    $teamsTokenSummary = Get-JwtTokenSummary -Token $teamsToken
    Write-Host ("Teams token summary: Graph(idtyp={0}, appid={1}, aud={2}); Teams(idtyp={3}, appid={4}, aud={5})" -f $graphTokenSummary.IdType, $graphTokenSummary.AppId, $graphTokenSummary.Aud, $teamsTokenSummary.IdType, $teamsTokenSummary.AppId, $teamsTokenSummary.Aud)
    Write-Host ("Teams token format: GraphIsJwt={0}, TeamsIsJwt={1}, GraphLength={2}, TeamsLength={3}, GraphDots={4}, TeamsDots={5}" -f $graphTokenSummary.IsJwt, $teamsTokenSummary.IsJwt, $graphTokenSummary.Length, $teamsTokenSummary.Length, $graphTokenSummary.DotCount, $teamsTokenSummary.DotCount)

    if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
      if (-not [string]::IsNullOrWhiteSpace($graphTokenSummary.AppId) -and $graphTokenSummary.AppId -ne $ClientId) {
        Write-Warning ("Graph access token appid '{0}' does not match expected workload identity client id '{1}'." -f $graphTokenSummary.AppId, $ClientId)
      }
      if (-not [string]::IsNullOrWhiteSpace($teamsTokenSummary.AppId) -and $teamsTokenSummary.AppId -ne $ClientId) {
        Write-Warning ("Teams access token appid '{0}' does not match expected workload identity client id '{1}'." -f $teamsTokenSummary.AppId, $ClientId)
      }
    }

    $tokenAttempts = @(
      [pscustomobject]@{
        Name   = 'graph-resource-url'
        Tokens = @($graphAccessToken, $teamsToken)
      }
    )

    $legacyGraphToken = $null
    try {
      $legacyGraphToken = ConvertTo-PlainTextToken -TokenValue (Get-AzAccessToken -ResourceTypeName MSGraph).Token
      if (-not [string]::IsNullOrWhiteSpace($legacyGraphToken) -and $legacyGraphToken -ne $graphAccessToken) {
        $tokenAttempts += [pscustomobject]@{
          Name   = 'graph-resource-type'
          Tokens = @($legacyGraphToken, $teamsToken)
        }
      }
    }
    catch {
      Write-Verbose ("Could not acquire fallback Graph token via ResourceTypeName. Error: {0}" -f $_.Exception.Message)
    }

    $teamsConnected = $false
    $teamsConnectionModes = @(
      [pscustomobject]@{
        Name = 'without-tenant'
        UseTenant = $false
      },
      [pscustomobject]@{
        Name = 'with-tenant'
        UseTenant = $true
      }
    )

    foreach ($attempt in $tokenAttempts) {
      foreach ($mode in $teamsConnectionModes) {
        if ($mode.UseTenant -and [string]::IsNullOrWhiteSpace($TenantId)) {
          continue
        }

        try {
          if ($mode.UseTenant) {
            Connect-MicrosoftTeams -AccessTokens $attempt.Tokens -TenantId $TenantId | Out-Null
          }
          else {
            Connect-MicrosoftTeams -AccessTokens $attempt.Tokens | Out-Null
          }
          $teamsConnected = $true
          Write-Host ("Microsoft Teams connection established (token mode: {0}, auth mode: {1})." -f $attempt.Name, $mode.Name)
          break
        }
        catch {
          Write-Warning ("Microsoft Teams connection attempt '{0}/{1}' failed: {2}" -f $attempt.Name, $mode.Name, $_.Exception.Message)
        }
      }

      if ($teamsConnected) {
        break
      }
    }

    if (-not $teamsConnected) {
      Write-Warning 'Microsoft Teams connection failed. Teams-related tests may be skipped. Non-interactive app auth requires a supported Teams directory role (for example Teams Administrator or Teams Communications Administrator).'
    }
  }
  catch {
    Write-Warning ("Microsoft Teams connection failed. Teams-related tests may be skipped. Error: {0}" -f $_.Exception.Message)
  }
}

$workingDirectory = Get-Location
$approvedDriftRun = $null
$approvedDriftReceipt = $null
$approvedDriftRunResult = $null
$approvedDriftPrimaryFailure = $null

try {
  if ($EnableApprovedDrift) {
    Import-Module (Join-Path $PSScriptRoot 'Maester.DriftInputs.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'Maester.DriftRun.psm1') -Force -ErrorAction Stop
    Assert-MaesterDriftTenantContext -ExpectedTenantId $DriftExpectedTenantId
    $approvedDriftRun = New-MaesterDriftRunRoot
    Assert-ApprovedDriftOutputScope -RunRoot $approvedDriftRun.Root -WorkspaceRoots @(
      $workingDirectory.Path, $env:BUILD_SOURCESDIRECTORY, $env:SYSTEM_DEFAULTWORKINGDIRECTORY
    )
    $outputFolder = $approvedDriftRun.OutputParent
  }
  else {
    $outputFolder = Join-Path -Path $workingDirectory -ChildPath 'test-results'
    if (-not (Test-Path -Path $outputFolder)) {
      New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
    }
  }

  $maesterModule = Get-Module -Name Maester -ListAvailable |
    Where-Object { $_.Version -eq [version]'2.2.0' } |
    Select-Object -First 1
  if (-not $maesterModule) {
    throw 'Maester module version 2.2.0 was not found after installation.'
  }

  $moduleRoot = Split-Path -Path $maesterModule.Path -Parent
  $testsCandidates = @(
    (Join-Path -Path $moduleRoot -ChildPath 'maester-tests')
    (Join-Path -Path $moduleRoot -ChildPath 'tests')
  )
  $testsRoot = $null
  foreach ($candidate in $testsCandidates) {
    if (-not (Test-Path -Path $candidate -PathType Container)) {
      continue
    }

    $testFile = Get-ChildItem -Path $candidate -Recurse -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($testFile) {
      $testsRoot = $candidate
      break
    }
  }

  if (-not $testsRoot) {
    throw "Could not locate the embedded Maester 2.2.0 tests under module path '$moduleRoot'."
  }

  Write-Host "Using embedded Maester 2.2.0 tests from '$testsRoot'."

  if ($EnableApprovedDrift) {
    try {
      $approvedDriftReceipt = Initialize-MaesterDriftInput `
        -InputRoot $DriftInputRoot `
        -StagingParent $approvedDriftRun.StagingParent `
        -ExpectedBaselineManifestSha256 $DriftExpectedBaselineManifestSha256 `
        -TenantId $DriftExpectedTenantId `
        -Environment $DriftEnvironment `
        -RunId $DriftRunId `
        -ProducerId $DriftProducerId `
        -ProducerRevision $DriftProducerRevision `
        -MaxAgeMinutes $DriftMaxAgeMinutes
    }
    catch {
      $failure = [InvalidOperationException]::new('drift.inputPreparationFailed')
      $failure.Data['PreparationException'] = $_.Exception
      throw $failure
    }
  }

  $resultsXmlPath = if ($EnableApprovedDrift) { $null } else { Join-Path -Path $outputFolder -ChildPath 'test-results.xml' }
  $latestHtmlPath = if ($EnableApprovedDrift) { $null } else { Join-Path -Path $outputFolder -ChildPath 'latest.html' }

  $pesterConfiguration = New-PesterConfiguration
  # Exclude ambient drift before discovery. The explicit approved adapter removes
  # only this exclusion after validating and privately staging approved bytes.
  $pesterConfiguration.Run.ExcludePath = @((Join-Path -Path $testsRoot -ChildPath 'Maester/Drift/MT1060Drift.tests.ps1'))
  if (-not $EnableApprovedDrift) {
    $pesterConfiguration.TestResult.Enabled = $true
    $pesterConfiguration.TestResult.OutputPath = $resultsXmlPath
  }

  $maesterInvokeParameters = @{
    Path = $testsRoot
    PesterConfiguration = $pesterConfiguration
    OutputFolder = $outputFolder
    NonInteractive = $true
    WarningAction = 'SilentlyContinue'
  }

  Write-Host 'Running Maester tests...'
  # Pipelines must stay non-interactive; never allow device-code/browser auth prompts.
  $previousDriftRoot = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'Process')
  try {
    if ($EnableApprovedDrift) {
      [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', $approvedDriftReceipt.StageRoot, 'Process')
      $approvedDriftRunResult = Invoke-MaesterApprovedDrift `
        -Receipt $approvedDriftReceipt `
        -RunRoot $approvedDriftRun.Root `
        -OutputParent $approvedDriftRun.OutputParent `
        -TestsPath $testsRoot `
        -SuitePath (Join-Path $testsRoot 'Maester/Drift/MT1060Drift.tests.ps1') `
        -MaesterInvokeParameters $maesterInvokeParameters
    }
    else {
      [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', [System.Management.Automation.Language.NullString]::Value, 'Process')
      Invoke-Maester @maesterInvokeParameters
    }
  }
  catch {
    $invocationException = $_.Exception
    if ($EnableApprovedDrift) {
      $failure = [InvalidOperationException]::new('drift.runFailed')
      $failure.Data['InvocationException'] = $invocationException
      throw $failure
    }
    throw
  }
  finally {
    $restoreDriftRoot = if ($null -eq $previousDriftRoot) { [System.Management.Automation.Language.NullString]::Value } else { $previousDriftRoot }
    [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', $restoreDriftRoot, 'Process')
  }
  Write-Host 'Maester execution completed.'

  if ($EnableApprovedDrift) {
    $latestHtmlPath = $approvedDriftRunResult.OutputHtmlPath
    $resultsXmlPath = $approvedDriftRunResult.JunitPath
    if (-not (Test-Path -LiteralPath $latestHtmlPath -PathType Leaf) -or (Get-Item -LiteralPath $latestHtmlPath).Length -eq 0) {
      throw 'No nonempty approved drift HTML report was generated.'
    }
    Write-Host 'Selected approved drift HTML report.'
  }
  else {
    $generatedHtml = Get-ChildItem -Path $outputFolder -Filter 'TestResults*.html' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $generatedHtml) {
      $generatedHtml = Get-ChildItem -Path $outputFolder -Filter '*.html' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }

    if (-not $generatedHtml) {
      throw "No Maester HTML report file was generated in '$outputFolder'."
    }

    if ($generatedHtml.FullName -ne $latestHtmlPath) {
      Copy-Item -Path $generatedHtml.FullName -Destination $latestHtmlPath -Force
    }

    Write-Host "Selected Maester HTML report: $($generatedHtml.Name)"
  }

  $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $archiveGzipPath = Join-Path -Path $outputFolder -ChildPath "maester-report-$timestamp.html.gz"
  Compress-FileToGzip -InputFilePath $latestHtmlPath -OutputFilePath $archiveGzipPath

  if (-not [string]::IsNullOrWhiteSpace($StorageAccountName)) {
    Write-Host "Uploading reports to storage account '$StorageAccountName'..."
    $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount

    Set-AzStorageBlobContent -File $latestHtmlPath -Container 'latest' -Blob 'latest.html' -Context $storageContext -Force | Out-Null
    Set-AzStorageBlobContent -File $archiveGzipPath -Container 'archive' -Blob (Split-Path -Path $archiveGzipPath -Leaf) -Context $storageContext -Force | Out-Null
  }
  else {
    Write-Warning 'StorageAccountName was not provided. Skipping report upload to Azure Storage.'
  }

  if ($includeWebAppBool -and -not [string]::IsNullOrWhiteSpace($WebAppName) -and -not [string]::IsNullOrWhiteSpace($WebAppResourceGroup)) {
    Write-Host "Publishing latest report to Web App '$WebAppName'..."
    $webPackageDir = Join-Path -Path $outputFolder -ChildPath 'webapp-package'
    if (Test-Path -Path $webPackageDir) {
      Remove-Item -Path $webPackageDir -Recurse -Force
    }
    New-Item -Path $webPackageDir -ItemType Directory -Force | Out-Null

    Copy-Item -Path $latestHtmlPath -Destination (Join-Path -Path $webPackageDir -ChildPath 'index.html') -Force

    $zipPath = Join-Path -Path $outputFolder -ChildPath 'webapp-latest.zip'
    if (Test-Path -Path $zipPath) {
      Remove-Item -Path $zipPath -Force
    }
    Compress-Archive -Path (Join-Path -Path $webPackageDir -ChildPath '*') -DestinationPath $zipPath -Force

    Publish-AzWebApp -ResourceGroupName $WebAppResourceGroup -Name $WebAppName -ArchivePath $zipPath -Force | Out-Null
  }
  elseif ($includeWebAppBool) {
    Write-Warning 'IncludeWebApp=true but WebAppName/WebAppResourceGroup was not provided. Skipping web app publish.'
  }

  $failureCount = if ($EnableApprovedDrift) {
    @($approvedDriftRunResult.Result.Tests | Where-Object Result -EQ 'Failed').Count
  }
  else {
    Get-NUnitFailureCount -Path $resultsXmlPath
  }
  if ($failureCount -gt 0) {
    $failureMessage = "$failureCount Maester test(s) failed."
    if ($failOnTestFailuresBool) {
      Write-Host "AZD_MAESTER_RESULT=FINDINGS;FAILED=$failureCount"
      throw $failureMessage
    }

    Write-Warning "$failureMessage Continuing because FailOnTestFailures=false."
  }

  Write-Host 'Maester pipeline run completed successfully.'
  Write-Host "Results XML: $resultsXmlPath"
  Write-Host "Latest HTML: $latestHtmlPath"
  Write-Host "Archive gzip: $archiveGzipPath"
}
catch {
  $approvedDriftPrimaryFailure = $_.Exception
  throw
}
finally {
  if ($EnableApprovedDrift -and $null -ne $approvedDriftRun) {
    try {
      Remove-ApprovedDriftRunRoot
    }
    catch {
      $failure = [InvalidOperationException]::new('drift.runCleanupFailed')
      $failure.Data['RunRoot'] = $approvedDriftRun.Root
      $failure.Data['CleanupException'] = $_.Exception
      if ($null -ne $approvedDriftPrimaryFailure) { $failure.Data['PrimaryException'] = $approvedDriftPrimaryFailure }
      throw $failure
    }
  }
}
