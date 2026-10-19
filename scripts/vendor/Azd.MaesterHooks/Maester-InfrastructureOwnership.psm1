# Fresh, dedicated resource-group ownership. This is deliberately separate from
# Graph/setup ownership: infrastructure can exist before any setup client does.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Maester-SetupHelpers.psm1') -Force

$script:InfrastructureReceiptName = 'maester-infrastructure-ownership.json'
$script:InfrastructureMarker = 'maester-ownership-id'
$script:InfrastructureWarning = 'Deleting this dedicated resource group deletes the listed accounts and all their child resources and data. ARM resource listings do not enumerate all provider children or data-plane contents. Do not share this resource group or provision concurrently.'

function Assert-MaesterInfrastructurePath {
  param([string]$Path)
  $current = [IO.Path]::GetFullPath($Path)
  while ($current) {
    try { $attributes = [IO.File]::GetAttributes($current) }
    catch [IO.FileNotFoundException] { $attributes = $null }
    catch [IO.DirectoryNotFoundException] { $attributes = $null }
    if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Infrastructure ownership paths cannot contain symbolic links or reparse points.' }
    $parent = [IO.Path]::GetDirectoryName($current)
    if ($parent -eq $current) { break }
    $current = $parent
  }
}

function Get-MaesterInfrastructureHash {
  param([string]$Value)
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
}

function Get-MaesterInfrastructureSourceHash {
  param([string]$ProjectRoot)
  $infra = Join-Path $ProjectRoot 'infra'
  Assert-MaesterInfrastructurePath $infra
  $files = @(Get-ChildItem -LiteralPath $infra -Recurse -File | Where-Object { $_.Extension -eq '.bicep' -or $_.Name -eq 'main.parameters.json' } | Sort-Object FullName)
  if ($files.Count -eq 0 -or -not (Test-Path -LiteralPath (Join-Path $infra 'main.bicep') -PathType Leaf)) { throw 'The exact infrastructure sources are required for ownership verification.' }
  $lines = foreach ($file in $files) {
    Assert-MaesterInfrastructurePath $file.FullName
    '{0}:{1}' -f [IO.Path]::GetRelativePath($infra, $file.FullName).Replace('\', '/'), (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  Get-MaesterInfrastructureHash ($lines -join "`n")
}

function Get-MaesterInfrastructureEnvironment {
  param([string]$EnvironmentName, [string]$ProjectRoot)
  Push-Location -LiteralPath $ProjectRoot
  try { $json = & azd env get-values -e $EnvironmentName --output json; $exitCode = $LASTEXITCODE }
  finally { Pop-Location }
  if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($json -join ''))) { throw 'Could not read the explicitly selected azd environment.' }
  $values = ($json -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  if ($values -isnot [Collections.IDictionary] -or $values['AZURE_ENV_NAME'] -cne $EnvironmentName) { throw 'The selected azd environment identity does not match.' }
  return $values
}

function Set-MaesterInfrastructureResourceGroup {
  param([string]$EnvironmentName, [string]$ResourceGroupName, [string]$ProjectRoot)
  Push-Location -LiteralPath $ProjectRoot
  try { & azd env set AZURE_RESOURCE_GROUP $ResourceGroupName -e $EnvironmentName | Out-Null; $exitCode = $LASTEXITCODE }
  finally { Pop-Location }
  if ($exitCode -ne 0) { throw 'Could not pin the exact resource group in the selected azd environment.' }
}

function Resolve-MaesterInfrastructureContext {
  param([string]$ProjectRoot, [string]$EnvironmentName, [string]$SolutionName, [string]$TenantId, [string]$SubscriptionId, [string]$ResourceGroupName)
  if ($EnvironmentName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'An explicit safe azd environment name is required.' }
  if ($SolutionName -notin @('automation-account', 'function-app', 'container-app-job', 'azure-devops')) { throw 'An exact Maester solution name is required.' }
  $root = [IO.Path]::GetFullPath($ProjectRoot)
  Assert-MaesterInfrastructurePath $root
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'The project root does not exist.' }
  $values = Get-MaesterInfrastructureEnvironment $EnvironmentName $root
  foreach ($field in @('AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID')) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParse([string]$values[$field], [ref]$guid) -or $guid -eq [guid]::Empty) { throw "The selected environment requires $field." }
    $values[$field] = $guid.ToString()
  }
  $selectedGroup = [string]$values['AZURE_RESOURCE_GROUP']
  if ([string]::IsNullOrWhiteSpace($selectedGroup)) { $selectedGroup = "rg-$EnvironmentName" }
  if ($selectedGroup -cnotmatch '^[A-Za-z0-9_().-]{1,90}$' -or $selectedGroup.EndsWith('.')) { throw 'The selected resource-group name is invalid.' }
  foreach ($pair in @(
    @('AZURE_ENV_NAME', $EnvironmentName), @('AZURE_TENANT_ID', $values['AZURE_TENANT_ID']),
    @('AZURE_SUBSCRIPTION_ID', $values['AZURE_SUBSCRIPTION_ID']), @('AZURE_RESOURCE_GROUP', $selectedGroup))) {
    $ambient = [Environment]::GetEnvironmentVariable($pair[0])
    if ($ambient -and $ambient -ine $pair[1]) { throw "The process $($pair[0]) differs from the selected azd environment." }
  }
  if (($TenantId -and $TenantId -ine $values['AZURE_TENANT_ID']) -or
      ($SubscriptionId -and $SubscriptionId -ine $values['AZURE_SUBSCRIPTION_ID']) -or
      ($ResourceGroupName -and $ResourceGroupName -ine $selectedGroup)) { throw 'Explicit infrastructure target differs from the selected azd environment.' }
  Get-AzCliSubscriptionContext -SubscriptionId $values['AZURE_SUBSCRIPTION_ID'] -TenantId $values['AZURE_TENANT_ID'] | Out-Null
  return @{ root = $root; values = $values; binding = [ordered]@{
    environmentName = $EnvironmentName; solutionName = $SolutionName; tenantId = $values['AZURE_TENANT_ID'];
    subscriptionId = $values['AZURE_SUBSCRIPTION_ID']; resourceGroupId = "/subscriptions/$($values['AZURE_SUBSCRIPTION_ID'])/resourceGroups/$selectedGroup"
  }; resourceGroupName = $selectedGroup }
}

function Open-MaesterInfrastructureReceipt {
  param($Context)
  $path = Join-Path $Context.root ".azure/$($Context.binding.environmentName)/$script:InfrastructureReceiptName"
  Assert-MaesterInfrastructurePath $path
  Assert-MaesterInfrastructurePath "$path.lock"
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
  try { $lock = [IO.FileStream]::new("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch { throw 'Another infrastructure ownership operation holds the lifecycle lock.' }
  try {
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode("$path.lock", [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    return @{ path = $path; lock = $lock; context = $Context }
  } catch { $lock.Dispose(); throw }
}

function Assert-MaesterInfrastructureFields {
  param($Value, [string[]]$Fields)
  if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Fields.Count) { throw 'Infrastructure receipt schema is invalid.' }
  foreach ($key in $Value.Keys) { if ($key -cnotin $Fields) { throw 'Infrastructure receipt has unsupported fields.' } }
}

function Assert-MaesterInfrastructureId {
  param($Id, [string]$GroupId)
  if ($Id -isnot [string] -or $Id.Length -gt 2048 -or -not $Id.StartsWith("$GroupId/providers/", [StringComparison]::OrdinalIgnoreCase) -or
      $Id -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9_().-]+/providers/[A-Za-z0-9.-]+(?:/[A-Za-z0-9_().-]+)+$' -or
      $Id -match '(^|/)\.{1,2}(/|$)') { throw 'Infrastructure inventory contains an invalid or out-of-group resource ID.' }
}

function Assert-MaesterInfrastructureReceipt {
  param($Receipt, $Context)
  Assert-MaesterInfrastructureFields $Receipt @('schemaVersion', 'binding', 'state', 'ownershipId', 'sourceHash', 'preexistenceStatus', 'createStatus', 'createdAt', 'resourceIds', 'lockIds', 'lockStates', 'externalSetupStarted')
  $timestamp = [DateTimeOffset]::MinValue
  if ($Receipt.schemaVersion -isnot [int] -and $Receipt.schemaVersion -isnot [long]) { throw 'Infrastructure receipt schemaVersion must be an integer.' }
  foreach ($field in @('state', 'ownershipId', 'sourceHash', 'createdAt')) { if ($Receipt[$field] -isnot [string]) { throw 'Infrastructure receipt metadata must be text.' } }
  if (-not [DateTimeOffset]::TryParseExact($Receipt.createdAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$timestamp)) { throw 'Infrastructure receipt timestamp is invalid.' }
  if ($Receipt.externalSetupStarted -isnot [bool]) { throw 'Infrastructure external-setup marker must be a boolean.' }
  if ($Receipt.schemaVersion -ne 1 -or $Receipt.state -cnotin @('Pending', 'Created', 'Ready') -or
      $Receipt.preexistenceStatus -ne 404 -or $Receipt.createStatus -notin @(0, 201) -or
      ($Receipt.state -ne 'Pending' -and $Receipt.createStatus -ne 201) -or
      $Receipt.ownershipId -cnotmatch '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
      $Receipt.sourceHash -cnotmatch '^[0-9a-f]{64}$' -or $Receipt.createdAt -isnot [string]) { throw 'Infrastructure ownership proof is malformed or incomplete.' }
  Assert-MaesterInfrastructureFields $Receipt.binding @('environmentName', 'solutionName', 'tenantId', 'subscriptionId', 'resourceGroupId')
  foreach ($key in $Context.binding.Keys) { if ($Receipt.binding[$key] -ine $Context.binding[$key]) { throw 'Infrastructure receipt target binding differs from the selected environment.' } }
  foreach ($field in @('resourceIds', 'lockIds')) {
    if ($Receipt[$field] -isnot [Collections.IList] -or $Receipt[$field].Count -gt 256) { throw 'Infrastructure receipt inventory is invalid.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $Receipt[$field]) {
      Assert-MaesterInfrastructureId $id $Context.binding.resourceGroupId
      if (-not $seen.Add($id)) { throw 'Infrastructure receipt contains duplicate resource IDs.' }
    }
  }
  if ($Receipt.lockStates -isnot [Collections.IDictionary] -or $Receipt.lockStates.Count -ne $Receipt.lockIds.Count) { throw 'Infrastructure lock states are malformed.' }
  foreach ($id in $Receipt.lockIds) {
    if ($id -notmatch '/providers/Microsoft.Authorization/locks/[^/]+$' -or $id -inotIn $Receipt.resourceIds -or
        $Receipt.lockStates[$id] -cnotin @('Present', 'PendingRemoval', 'Removed')) { throw 'Infrastructure lock ownership is invalid.' }
  }
  if ($Receipt.state -ne 'Ready' -and ($Receipt.resourceIds.Count -ne 0 -or $Receipt.lockIds.Count -ne 0)) { throw 'Unfinished infrastructure ownership cannot contain an adopted inventory.' }
  if ($Receipt.state -eq 'Ready' -and $Receipt.resourceIds.Count -eq 0) { throw 'Infrastructure ownership has no declared resources.' }
}

function Read-MaesterInfrastructureReceipt {
  param($Session)
  Assert-MaesterInfrastructurePath $Session.path
  if (-not [IO.File]::Exists($Session.path)) { return $null }
  if ((Get-Item -LiteralPath $Session.path).Length -gt 256KB) { throw 'Infrastructure ownership receipt is too large.' }
  $json = [IO.File]::ReadAllText($Session.path)
  $document = [Text.Json.JsonDocument]::Parse($json)
  try {
    function Assert-UniqueKeys($Element) {
      if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
          if (-not $names.Add($property.Name)) { throw 'Infrastructure receipt has duplicate JSON keys.' }
          Assert-UniqueKeys $property.Value
        }
      } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) { foreach ($elementValue in $Element.EnumerateArray()) { Assert-UniqueKeys $elementValue } }
    }
    Assert-UniqueKeys $document.RootElement
  } finally { $document.Dispose() }
  $receipt = ConvertFrom-Json -InputObject $json -AsHashtable -DateKind String -Depth 12 -ErrorAction Stop
  Assert-MaesterInfrastructureReceipt $receipt $Session.context
  return $receipt
}

function Write-MaesterInfrastructureReceipt {
  param($Session, $Receipt)
  if (-not $Session.lock.CanWrite) { throw 'Infrastructure ownership requires its lifetime lock.' }
  Assert-MaesterInfrastructureReceipt $Receipt $Session.context
  Assert-MaesterInfrastructurePath $Session.path
  $temporary = "$($Session.path).$([guid]::NewGuid().ToString('N')).tmp"
  $stream = $null
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Receipt | ConvertTo-Json -Depth 12 -Compress))
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($temporary, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
    $stream.Dispose(); $stream = $null
    [IO.File]::Move($temporary, $Session.path, $true)
  } finally {
    if ($stream) { $stream.Dispose() }
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
  }
}

function Invoke-MaesterInfrastructureArm {
  param($Context, [ValidateSet('GET', 'PUT', 'DELETE')][string]$Method, [string]$Path, $Body)
  # Never follow a nextLink or response-controlled host, or print/persist tokens.
  if (-not $Path.StartsWith($Context.binding.resourceGroupId, [StringComparison]::OrdinalIgnoreCase) -or $Path -match '[#\s]' -or $Path.Contains('..')) { throw 'Infrastructure request escaped its exact resource group.' }
  $token = Get-AzCliAccessToken -Resource 'https://management.azure.com/' -SubscriptionId $Context.binding.subscriptionId -TenantId $Context.binding.tenantId
  if ([string]::IsNullOrWhiteSpace($token)) { throw 'An exact tenant/subscription ARM token could not be acquired.' }
  try {
    $parameters = @{ Method = $Method; Uri = "https://management.azure.com$Path"; Headers = @{ Authorization = "Bearer $token" }; SkipHttpErrorCheck = $true; MaximumRedirection = 0; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress; $parameters.ContentType = 'application/json' }
    try { $response = Invoke-WebRequest @parameters }
    catch { throw 'ARM infrastructure request outcome is unknown; ownership remains unresolved. Inspect the exact target before retrying.' }
    $value = $null
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
      try { $value = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop }
      catch { throw 'ARM infrastructure response is malformed; ownership remains unresolved.' }
    }
    return @{ StatusCode = [int]$response.StatusCode; Value = $value }
  } finally { $token = $null }
}

function Assert-MaesterInfrastructureGroup {
  param($Response, $Receipt, $Context)
  if ($Response.StatusCode -ne 200 -or $Response.Value -isnot [Collections.IDictionary] -or
      $Response.Value['id'] -ine $Context.binding.resourceGroupId -or
      $Response.Value['tags'] -isnot [Collections.IDictionary] -or
      $Response.Value['tags'][$script:InfrastructureMarker] -cne $Receipt.ownershipId -or
      $Response.Value['properties'] -isnot [Collections.IDictionary] -or
      $Response.Value['properties']['provisioningState'] -cne 'Succeeded') { throw 'The live resource group does not match the proven created ownership marker and target.' }
}

function Initialize-MaesterInfrastructureOwnership {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName, [string]$TenantId, [string]$SubscriptionId, [string]$ResourceGroupName)
  $context = Resolve-MaesterInfrastructureContext @PSBoundParameters
  $session = Open-MaesterInfrastructureReceipt $context
  try {
    $receipt = Read-MaesterInfrastructureReceipt $session
    if ($receipt) {
      if ($receipt.state -eq 'Pending') { throw 'Resource-group creation has an unresolved pending receipt. A query cannot promote it to owned; reconcile it manually.' }
      if ($receipt.sourceHash -cne (Get-MaesterInfrastructureSourceHash $context.root)) { throw 'Infrastructure sources differ from the ownership receipt. Review the changed deployment before proceeding.' }
      $group = Invoke-MaesterInfrastructureArm $context GET "$($context.binding.resourceGroupId)?api-version=2021-04-01"
      Assert-MaesterInfrastructureGroup $group $receipt $context
      return [pscustomobject]@{ Owned = $true; State = $receipt.state; ResourceGroupId = $context.binding.resourceGroupId }
    }
    $group = Invoke-MaesterInfrastructureArm $context GET "$($context.binding.resourceGroupId)?api-version=2021-04-01"
    if ($group.StatusCode -eq 200 -and $group.Value -is [Collections.IDictionary] -and $group.Value['id'] -ieq $context.binding.resourceGroupId) {
      Write-Warning 'This resource group already exists. Provisioning may continue, but automatic down is blocked because it was not created with an ownership receipt.'
      return [pscustomobject]@{ Owned = $false; State = 'Existing'; ResourceGroupId = $context.binding.resourceGroupId }
    }
    if ($group.StatusCode -ne 404) { throw 'Could not prove the exact resource group was absent. No create was attempted.' }
    $location = [string]$context.values['AZURE_LOCATION']
    if ($location -cnotmatch '^[a-zA-Z0-9]+$') { throw 'An explicit Azure location is required before resource-group creation.' }
    Set-MaesterInfrastructureResourceGroup $EnvironmentName $context.resourceGroupName $context.root
    $receipt = [ordered]@{
      schemaVersion = 1; binding = $context.binding; state = 'Pending'; ownershipId = [guid]::NewGuid().ToString();
      sourceHash = Get-MaesterInfrastructureSourceHash $context.root; preexistenceStatus = 404; createStatus = 0;
      createdAt = [DateTimeOffset]::UtcNow.ToString('o'); resourceIds = @(); lockIds = @(); lockStates = @{}; externalSetupStarted = $false
    }
    Write-MaesterInfrastructureReceipt $session $receipt
    # https://learn.microsoft.com/rest/api/resources/resource-groups/create-or-update?view=rest-resources-2021-04-01
    # Azure's documented RG create/update operation has 201 Created and 200 OK.
    # It has no documented atomic create-only/If-None-Match contract. A concurrent
    # creator may therefore receive an update; that outcome is NEVER adopted.
    $created = Invoke-MaesterInfrastructureArm $context PUT "$($context.binding.resourceGroupId)?api-version=2021-04-01" @{ location = $location; tags = @{ $script:InfrastructureMarker = $receipt.ownershipId; 'azd-env-name' = $EnvironmentName } }
    if ($created.StatusCode -ne 201 -or $created.Value -isnot [Collections.IDictionary] -or
        $created.Value['id'] -ine $context.binding.resourceGroupId -or $created.Value['tags'] -isnot [Collections.IDictionary] -or
        $created.Value['tags'][$script:InfrastructureMarker] -cne $receipt.ownershipId) {
      throw 'Resource-group creation did not return exact 201 Created proof. Its pending receipt remains unresolved; automatic down is blocked.'
    }
    $receipt.state = 'Created'; $receipt.createStatus = 201
    Write-MaesterInfrastructureReceipt $session $receipt
    return [pscustomobject]@{ Owned = $true; State = 'Created'; ResourceGroupId = $context.binding.resourceGroupId }
  } finally { $session.lock.Dispose() }
}

function Complete-MaesterInfrastructureOwnership {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName, [string]$TenantId, [string]$SubscriptionId, [string]$ResourceGroupName)
  $context = Resolve-MaesterInfrastructureContext @PSBoundParameters
  $session = Open-MaesterInfrastructureReceipt $context
  try {
    $receipt = Read-MaesterInfrastructureReceipt $session
    if (-not $receipt) { Write-Warning 'No fresh infrastructure ownership receipt exists; automatic down remains blocked.'; return }
    if ($receipt.state -eq 'Pending') { throw 'Unresolved resource-group creation cannot be finalized from deployment outputs.' }
    if ($receipt.sourceHash -cne (Get-MaesterInfrastructureSourceHash $context.root)) { throw 'Infrastructure source changed after resource-group ownership capture.' }
    $group = Invoke-MaesterInfrastructureArm $context GET "$($context.binding.resourceGroupId)?api-version=2021-04-01"
    Assert-MaesterInfrastructureGroup $group $receipt $context
    if ($context.values['MAESTER_INFRASTRUCTURE_OWNERSHIP_ID'] -cne $receipt.ownershipId) { throw 'Deployment ownership output belongs to a different or missing resource-group incarnation.' }
    $resources = ConvertFrom-Json -InputObject ([string]$context.values['MAESTER_OWNED_RESOURCE_IDS']) -NoEnumerate -ErrorAction Stop
    $locks = ConvertFrom-Json -InputObject ([string]$context.values['MAESTER_OWNED_LOCK_IDS']) -NoEnumerate -ErrorAction Stop
    if ($resources -isnot [Collections.IList] -or $locks -isnot [Collections.IList]) { throw 'Exact declared-resource outputs must be JSON arrays.' }
    # Validate the new output independently even when retaining a prior inventory.
    $candidate = $receipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable -DateKind String
    $candidate.resourceIds = @($resources); $candidate.lockIds = @($locks); $candidate.lockStates = @{}; $candidate.state = 'Ready'
    foreach ($id in $locks) { $candidate.lockStates[$id] = 'Present' }
    Assert-MaesterInfrastructureReceipt $candidate $context
    if ($receipt.state -eq 'Ready' -and
        (@($resources | Where-Object { $_ -inotIn $receipt.resourceIds }).Count -gt 0 -or
         @($locks | Where-Object { $_ -inotIn $receipt.lockIds }).Count -gt 0)) {
      throw 'A repeated deployment added an unproven resource or lock ID; it cannot be silently adopted.'
    }
    # Automation repeat/runtime-only provisioning intentionally omits preserved
    # runbook/schedule/non-runtime declarations. Retain the original proven IDs;
    # a subset from the same source/RG never adopts anything from live inventory.
    if ($receipt.state -ne 'Ready') {
      $receipt.resourceIds = @($resources); $receipt.lockIds = @($locks); $receipt.lockStates = @{}
      foreach ($id in $locks) { $receipt.lockStates[$id] = 'Present' }
    }
    # Repeated completion must not erase pending or removed lock history.
    $receipt.state = 'Ready'
    Write-MaesterInfrastructureReceipt $session $receipt
  } finally { $session.lock.Dispose() }
}

function Get-MaesterInfrastructureInventory {
  param($Context, [string]$Path)
  $response = Invoke-MaesterInfrastructureArm $Context GET $Path
  if ($response.StatusCode -ne 200 -or $response.Value -isnot [Collections.IDictionary] -or
      $response.Value['value'] -isnot [Collections.IList] -or $response.Value['nextLink']) { throw 'Infrastructure inventory is incomplete, paginated, or unavailable. Automatic down is blocked.' }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($resource in $response.Value['value']) {
    if ($resource -isnot [Collections.IDictionary]) { throw 'Infrastructure inventory contains a malformed resource.' }
    Assert-MaesterInfrastructureId $resource['id'] $Context.binding.resourceGroupId
    if (-not $seen.Add($resource['id'])) { throw 'Infrastructure inventory contains duplicate IDs.' }
  }
  return ,@($response.Value['value'])
}

function Test-MaesterInfrastructureReceiptLive {
  param($Session)
  $context = $Session.context
  $receipt = Read-MaesterInfrastructureReceipt $Session
  if (-not $receipt -or $receipt.state -ne 'Ready') { throw 'A completed, proven fresh-resource-group ownership receipt is required for automatic down.' }
  if ($receipt.sourceHash -cne (Get-MaesterInfrastructureSourceHash $context.root)) { throw 'Infrastructure source hash differs from the recorded deployment.' }
  $group = Invoke-MaesterInfrastructureArm $context GET "$($context.binding.resourceGroupId)?api-version=2021-04-01"
  Assert-MaesterInfrastructureGroup $group $receipt $context
  $resources = Get-MaesterInfrastructureInventory $context "$($context.binding.resourceGroupId)/resources?api-version=2021-04-01"
  foreach ($resource in $resources) { if ($resource.id -inotIn $receipt.resourceIds) { throw "Unowned resource blocks down: $($resource.id)" } }
  $locks = Get-MaesterInfrastructureInventory $context "$($context.binding.resourceGroupId)/providers/Microsoft.Authorization/locks?api-version=2016-09-01"
  foreach ($lock in $locks) {
    if ($lock.id -inotIn $receipt.lockIds -or $lock.properties -isnot [Collections.IDictionary] -or
        $lock.properties['level'] -cne 'CanNotDelete') { throw "Unowned or changed resource lock blocks down: $($lock.id)" }
    if ($receipt.lockStates[$lock.id] -eq 'Removed') { throw 'A previously removed lock was recreated. Explicit reconciliation is required.' }
  }
  $lockIds = @($locks | ForEach-Object { $_.id } | Sort-Object)
  $plan = [ordered]@{ binding = $receipt.binding; ownershipId = $receipt.ownershipId; sourceHash = $receipt.sourceHash;
    resourceIds = @($receipt.resourceIds | Sort-Object); lockIds = @($receipt.lockIds | Sort-Object); presentLockIds = $lockIds;
    lockStates = @($receipt.lockIds | Sort-Object | ForEach-Object { [ordered]@{ id = $_; state = $receipt.lockStates[$_] } }) }
  return [pscustomobject]@{
    SafeToDelete = ($locks.Count -eq 0 -and @($receipt.lockStates.Values | Where-Object { $_ -eq 'PendingRemoval' }).Count -eq 0); SafeToUnlock = $true; ResourceGroupId = $context.binding.resourceGroupId;
    OwnedResourceIds = @($receipt.resourceIds); OwnedLockIds = @($receipt.lockIds); PresentOwnedLockIds = $lockIds;
    PlanHash = Get-MaesterInfrastructureHash ($plan | ConvertTo-Json -Depth 8 -Compress);
    InventoryScope = 'DedicatedResourceGroupArmListedResources'; DeletionWarning = $script:InfrastructureWarning;
    BlockingReason = $(if ($locks.Count -or @($receipt.lockStates.Values | Where-Object { $_ -eq 'PendingRemoval' }).Count) { 'Exact owned resource locks require separate explicit removal approval or pending-removal reconciliation.' } else { '' })
  }
}

function Test-MaesterInfrastructureOwnership {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName, [string]$TenantId, [string]$SubscriptionId, [string]$ResourceGroupName)
  $session = $null
  try {
    $context = Resolve-MaesterInfrastructureContext @PSBoundParameters
    $session = Open-MaesterInfrastructureReceipt $context
    Test-MaesterInfrastructureReceiptLive $session
  } catch {
    [pscustomobject]@{ SafeToDelete = $false; SafeToUnlock = $false; ResourceGroupId = ''; OwnedResourceIds = @(); OwnedLockIds = @();
      PresentOwnedLockIds = @(); PlanHash = ''; InventoryScope = 'Unverified'; DeletionWarning = $script:InfrastructureWarning; BlockingReason = $_.Exception.Message }
  } finally { if ($session) { $session.lock.Dispose() } }
}

function Unlock-MaesterInfrastructureLocks {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName, [string]$TenantId, [string]$SubscriptionId, [string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ApprovedPlanHash)
  $parameters = @{} + $PSBoundParameters; $parameters.Remove('ApprovedPlanHash')
  $context = Resolve-MaesterInfrastructureContext @parameters
  $session = Open-MaesterInfrastructureReceipt $context
  try {
    $plan = Test-MaesterInfrastructureReceiptLive $session
    if (-not $plan.SafeToUnlock -or $plan.PlanHash -cne $ApprovedPlanHash) { throw 'The approved infrastructure lock-removal plan changed; no locks were removed.' }
    $receipt = Read-MaesterInfrastructureReceipt $session
    foreach ($id in $receipt.lockIds) {
      $current = Invoke-MaesterInfrastructureArm $context GET "$id`?api-version=2016-09-01"
      if ($current.StatusCode -eq 404) {
        $receipt.lockStates[$id] = 'Removed'; Write-MaesterInfrastructureReceipt $session $receipt; continue
      }
      if ($current.StatusCode -ne 200 -or $current.Value -isnot [Collections.IDictionary] -or $current.Value['id'] -ine $id -or
          $current.Value['properties'] -isnot [Collections.IDictionary] -or $current.Value['properties']['level'] -cne 'CanNotDelete') { throw 'Exact owned lock changed before removal; no further locks were removed.' }
      if ($receipt.lockStates[$id] -eq 'Removed' -or $id -inotIn $plan.PresentOwnedLockIds) {
        throw 'The exact lock was not present in the approved removal plan or was already removed. No further locks were removed.'
      }
      $receipt.lockStates[$id] = 'PendingRemoval'; Write-MaesterInfrastructureReceipt $session $receipt
      $deleted = Invoke-MaesterInfrastructureArm $context DELETE "$id`?api-version=2016-09-01"
      if ($deleted.StatusCode -notin @(200, 202, 204, 404)) { throw 'Owned lock removal failed; its pending state must be reconciled before down.' }
      $after = Invoke-MaesterInfrastructureArm $context GET "$id`?api-version=2016-09-01"
      if ($after.StatusCode -ne 404) { throw 'Owned lock removal is not verified absent; automatic down remains blocked.' }
      $receipt.lockStates[$id] = 'Removed'; Write-MaesterInfrastructureReceipt $session $receipt
    }
    Test-MaesterInfrastructureReceiptLive $session
  } finally { $session.lock.Dispose() }
}

function Register-MaesterExternalSetupStarted {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName, [string]$TenantId, [string]$SubscriptionId, [string]$ResourceGroupName)
  $context = Resolve-MaesterInfrastructureContext @PSBoundParameters
  $session = Open-MaesterInfrastructureReceipt $context
  try {
    $receipt = Read-MaesterInfrastructureReceipt $session
    if (-not $receipt) {
      Write-Warning 'External setup is untracked by an infrastructure receipt. Automatic down remains blocked.'
      return [pscustomobject]@{ Tracked = $false; ExternalSetupStarted = $false }
    }
    if ($receipt.state -ne 'Ready') { throw 'Complete infrastructure ownership before starting external setup.' }
    if ($receipt.sourceHash -cne (Get-MaesterInfrastructureSourceHash $context.root)) { throw 'Infrastructure sources differ from the recorded deployment.' }
    if (-not $receipt.externalSetupStarted) {
      $receipt.externalSetupStarted = $true
      Write-MaesterInfrastructureReceipt $session $receipt
    }
    return [pscustomobject]@{ Tracked = $true; ExternalSetupStarted = $true }
  } finally { $session.lock.Dispose() }
}

function Resolve-MaesterInfrastructureBinding {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName, [string]$TenantId, [string]$SubscriptionId, [string]$ResourceGroupName)
  $context = Resolve-MaesterInfrastructureContext @PSBoundParameters
  $session = Open-MaesterInfrastructureReceipt $context
  try {
    $receipt = Read-MaesterInfrastructureReceipt $session
    if (-not $receipt -or $receipt.state -ne 'Ready') { throw 'A complete infrastructure ownership receipt is required.' }
    return [pscustomobject]@{
      EnvironmentName = $receipt.binding.environmentName; SolutionName = $receipt.binding.solutionName;
      TenantId = $receipt.binding.tenantId; SubscriptionId = $receipt.binding.subscriptionId;
      ResourceGroupId = $receipt.binding.resourceGroupId; ResourceGroupName = $context.resourceGroupName;
      OwnedResourceIds = @($receipt.resourceIds); OwnedLockIds = @($receipt.lockIds); State = $receipt.state; ExternalSetupStarted = $receipt.externalSetupStarted
    }
  } finally { $session.lock.Dispose() }
}

Export-ModuleMember -Function Register-MaesterExternalSetupStarted, Resolve-MaesterInfrastructureBinding, Initialize-MaesterInfrastructureOwnership, Complete-MaesterInfrastructureOwnership, Test-MaesterInfrastructureOwnership, Unlock-MaesterInfrastructureLocks
