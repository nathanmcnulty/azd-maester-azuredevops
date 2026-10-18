#Requires -Version 7.6
Set-StrictMode -Version Latest

# Host-local port of the adapter reviewed in azd-maester-containerappjob commit
# 5132a5320969d15ff8b707b5f4b97e2817aee3f3. Keep this copy independent until
# two native hosts have completed their own qualification.

function Test-DriftOrdinalMember {
    param($Value, [string[]]$Allowed)
    if ($Value -isnot [string]) { return $false }
    foreach ($candidate in $Allowed) {
        if ([string]::Equals($Value, $candidate, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Assert-DriftShape {
    param($Value, [string[]]$Fields)
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Fields.Count) { throw 'drift.manifestShape' }
    foreach ($key in $Value.Keys) { if (-not (Test-DriftOrdinalMember $key $Fields)) { throw 'drift.manifestShape' } }
}

function Assert-DriftLabel {
    param($Value)
    if ($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}\z') { throw 'drift.invalidLabel' }
}

function Assert-DriftTextFields {
    param($Value, [string[]]$Fields)
    foreach ($field in $Fields) { if ($Value[$field] -isnot [string]) { throw 'drift.manifestType' } }
}

function Assert-DriftBinding {
    param($Value, [hashtable]$Expected)
    foreach ($field in $Expected.Keys) {
        if (-not [string]::Equals($Value[$field], $Expected[$field], [StringComparison]::Ordinal)) { throw 'drift.targetBinding' }
    }
}

function Assert-DriftGuid {
    param($Value)
    $parsed = [guid]::Empty
    if ($Value -isnot [string] -or -not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty -or -not [string]::Equals($Value, $parsed.ToString('D'), [StringComparison]::OrdinalIgnoreCase)) { throw 'drift.invalidGuid' }
}

function Assert-DriftDigest {
    param($Value)
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}\z') { throw 'drift.invalidDigest' }
}

function Assert-DriftPath {
    param([string]$Path)
    $cursor = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $cursor) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'drift.linkRejected' }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
}

function Assert-DriftJsonKeys {
    param([Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $keys.Add($property.Name)) { throw 'drift.duplicateJsonKey' }
            Assert-DriftJsonKeys $property.Value
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($child in $Element.EnumerateArray()) { Assert-DriftJsonKeys $child }
    }
}

function Read-DriftJson {
    param([string]$Path, [ref]$TotalBytes)
    Assert-DriftPath $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buffer = [byte[]]::new(1048577)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -eq 0 -or $count -gt 1048576) { throw 'drift.fileSize' }
        $TotalBytes.Value += $count
        if ($TotalBytes.Value -gt 16777216) { throw 'drift.totalSize' }
        $bytes = [byte[]]::new($count)
        [Array]::Copy($buffer, $bytes, $count)
    }
    finally { $stream.Dispose() }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 32
    $document = [Text.Json.JsonDocument]::Parse($text, $options)
    try { Assert-DriftJsonKeys $document.RootElement } finally { $document.Dispose() }
    [pscustomobject]@{
        Bytes = $bytes; Text = $text; Length = $count
        Hash = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($bytes))
        Value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 32 -DateKind String -ErrorAction Stop
    }
}

# A closed, reference-free JSON Schema subset. Schemas themselves are covered by
# the independently selected baseline manifest digest; they execute no code.
function Assert-DriftSchema {
    param($Schema)
    if ($Schema -isnot [Collections.IDictionary] -or -not (Test-DriftOrdinalMember 'type' @($Schema.Keys)) -or -not (Test-DriftOrdinalMember $Schema['type'] @('object','array','string','number','integer','boolean','null'))) { throw 'drift.schemaUnsupported' }
    $allowed = @('type','enum')
    switch -CaseSensitive ($Schema.type) {
        'object' {
            $allowed += @('properties','required','additionalProperties')
            if ($Schema.additionalProperties -isnot [bool] -or $Schema.additionalProperties -or $Schema.properties -isnot [Collections.IDictionary] -or $Schema.properties.Count -lt 1 -or $Schema.properties.Count -gt 128) { throw 'drift.schemaOpenObject' }
            foreach ($name in $Schema.properties.Keys) {
                if ($name -cnotmatch '^[A-Za-z_][A-Za-z0-9_.-]{0,63}\z') { throw 'drift.schemaPropertyName' }
                Assert-DriftSchema $Schema.properties[$name]
            }
            if ($Schema.Contains('required')) {
                if ($Schema.required -isnot [array]) { throw 'drift.schemaRequired' }
                $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($name in $Schema.required) {
                    if ($name -isnot [string] -or -not (Test-DriftOrdinalMember $name @($Schema.properties.Keys)) -or -not $seen.Add($name)) { throw 'drift.schemaRequired' }
                }
            }
        }
        'array' {
            $allowed += @('items','maxItems')
            if ($Schema.maxItems -isnot [long] -or $Schema.maxItems -lt 1 -or $Schema.maxItems -gt 256) { throw 'drift.schemaArrayBound' }
            Assert-DriftSchema $Schema.items
        }
        'string' {
            $allowed += 'maxLength'
            if ($Schema.maxLength -isnot [long] -or $Schema.maxLength -lt 1 -or $Schema.maxLength -gt 4096) { throw 'drift.schemaStringBound' }
        }
    }
    foreach ($key in $Schema.Keys) { if (-not (Test-DriftOrdinalMember $key $allowed)) { throw 'drift.schemaUnsupported' } }
    if ($Schema.Contains('enum') -and ($Schema.enum -isnot [array] -or $Schema.enum.Count -lt 1 -or $Schema.enum.Count -gt 64)) { throw 'drift.schemaEnum' }
}

function Initialize-MaesterDriftInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputRoot,
        [Parameter(Mandatory)][string]$StagingParent,
        [Parameter(Mandatory)][string]$ExpectedBaselineManifestSha256,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ProducerId,
        [Parameter(Mandatory)][string]$ProducerRevision,
        [ValidateRange(1,60)][int]$MaxAgeMinutes = 30,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )
    $ErrorActionPreference = 'Stop'
    $stage = $null
    $stageCreated = $false
    try {
        Assert-DriftDigest $ExpectedBaselineManifestSha256
        Assert-DriftGuid $TenantId; Assert-DriftGuid $RunId
        Assert-DriftLabel $Environment; Assert-DriftLabel $ProducerId
        if ($ProducerRevision -cnotmatch '^[0-9a-f]{40}\z') { throw 'drift.producerRevision' }
        $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($InputRoot))
        $parent = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($StagingParent))
        Assert-DriftPath $root; Assert-DriftPath $parent
        if (-not [IO.Directory]::Exists($root) -or -not [IO.Directory]::Exists($parent)) { throw 'drift.directoryRequired' }
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if ($parent.Equals($root, $comparison) -or $parent.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'drift.stagingInsideInput' }
        $inventory = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in [IO.DirectoryInfo]::new($root).EnumerateFileSystemInfos()) {
            if ($inventory.Count -ge 66 -or $entry -isnot [IO.FileInfo] -or $entry.Attributes -band [IO.FileAttributes]::ReparsePoint -or -not $inventory.Add($entry.Name)) { throw 'drift.fileInventory' }
        }
        $total = 0L
        $baseline = Read-DriftJson (Join-Path $root 'baseline-manifest.json') ([ref]$total)
        if ($baseline.Hash -cne $ExpectedBaselineManifestSha256) { throw 'drift.baselineApprovalMismatch' }
        $current = Read-DriftJson (Join-Path $root 'current-manifest.json') ([ref]$total)
        $b = $baseline.Value; $c = $current.Value
        Assert-DriftShape $b @('schemaVersion','tenantId','environment','host','revision','approvalReference','normalizationRevision','cases')
        Assert-DriftShape $c @('schemaVersion','tenantId','environment','host','runId','baselineManifestSha256','producerId','producerRevision','normalizationRevision','capturedAt','cases')
        Assert-DriftTextFields $b @('schemaVersion','tenantId','environment','host','revision','approvalReference','normalizationRevision')
        Assert-DriftTextFields $c @('schemaVersion','tenantId','environment','host','runId','baselineManifestSha256','producerId','producerRevision','normalizationRevision','capturedAt')
        Assert-DriftBinding $b @{schemaVersion='1.0';host='azuredevops';tenantId=$TenantId;environment=$Environment}
        Assert-DriftBinding $c @{schemaVersion='1.0';host='azuredevops';tenantId=$TenantId;environment=$Environment;runId=$RunId;producerId=$ProducerId;producerRevision=$ProducerRevision;baselineManifestSha256=$baseline.Hash;normalizationRevision=$b.normalizationRevision}
        if ($b.revision -cnotmatch '^[0-9a-f]{40}\z') { throw 'drift.baselineRevision' }
        Assert-DriftLabel $b.approvalReference; Assert-DriftLabel $b.normalizationRevision
        $captured = [datetimeoffset]::MinValue
        if ($c.capturedAt -isnot [string] -or $c.capturedAt -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z\z' -or -not [datetimeoffset]::TryParse($c.capturedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$captured) -or $captured -gt $Now.AddMinutes(1) -or $captured -lt $Now.AddMinutes(-$MaxAgeMinutes)) { throw 'drift.inputFreshness' }
        if ($b.cases -isnot [array] -or $b.cases.Count -lt 1 -or $b.cases.Count -gt 32 -or $c.cases -isnot [array] -or $c.cases.Count -ne $b.cases.Count) { throw 'drift.caseCount' }
        $currentCases = @{}
        foreach ($case in $c.cases) {
            Assert-DriftShape $case @('id','sha256','length')
            if ($case.id -isnot [string] -or $case.id -cnotmatch '^[a-z][a-z0-9-]{0,31}\z' -or $currentCases.ContainsKey($case.id)) { throw 'drift.caseIdentity' }
            $currentCases[$case.id] = $case
        }
        $expectedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$expectedFiles.Add('baseline-manifest.json'); [void]$expectedFiles.Add('current-manifest.json')
        $prepared = [Collections.Generic.List[object]]::new()
        foreach ($case in $b.cases) {
            Assert-DriftShape $case @('id','sha256','length','schemaRevision','schema','excludeProperties')
            if ($case.id -isnot [string] -or $case.id -cnotmatch '^[a-z][a-z0-9-]{0,31}\z' -or -not $currentCases.ContainsKey($case.id) -or -not $expectedFiles.Add($case.id + '.baseline.json')) { throw 'drift.caseIdentity' }
            [void]$expectedFiles.Add($case.id + '.current.json')
            Assert-DriftLabel $case.schemaRevision
            Assert-DriftSchema $case.schema
            if ($case.schema.type -cne 'object') { throw 'drift.objectRootRequired' }
            if ($case.excludeProperties -isnot [array] -or $case.excludeProperties.Count -gt 32) { throw 'drift.exclusions' }
            $exclusions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($name in $case.excludeProperties) {
                if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z_][A-Za-z0-9_.-]{0,63}\z' -or -not $exclusions.Add($name)) { throw 'drift.exclusions' }
            }
            $pair = @{}
            foreach ($side in 'baseline','current') {
                $record = if ($side -eq 'baseline') { $case } else { $currentCases[$case.id] }
                Assert-DriftDigest $record.sha256
                if ($record.length -isnot [long] -or $record.length -lt 1 -or $record.length -gt 1048576) { throw 'drift.fileLength' }
                $data = Read-DriftJson (Join-Path $root ($case.id + '.' + $side + '.json')) ([ref]$total)
                if ($data.Hash -cne $record.sha256 -or $data.Length -ne $record.length) { throw 'drift.fileChanged' }
                if ($data.Value -isnot [Collections.IDictionary] -or $data.Value.Count -eq 0) { throw 'drift.objectRootRequired' }
                if (-not (Test-Json -Json $data.Text -Schema ($case.schema | ConvertTo-Json -Depth 32 -Compress) -ErrorAction Stop)) { throw 'drift.schemaMismatch' }
                $pair[$side] = $data.Bytes
            }
            $prepared.Add([pscustomobject]@{ Id=$case.id; Baseline=$pair.baseline; Current=$pair.current; Exclusions=@($case.excludeProperties) })
        }
        if (-not $expectedFiles.SetEquals($inventory)) { throw 'drift.fileParity' }
        # No input-derived path is used for the owned private staging root.
        $stage = Join-Path $parent ('maester-drift-' + [guid]::NewGuid().ToString('N'))
        if ([IO.Directory]::Exists($stage)) { throw 'drift.stagingCollision' }
        if ($IsWindows) {
            $null = [IO.Directory]::CreateDirectory($stage)
            $stageCreated = $true
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            Set-Acl -LiteralPath $stage -AclObject $acl
        }
        else {
            $null = [IO.Directory]::CreateDirectory($stage, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
            $stageCreated = $true
        }
        foreach ($case in $prepared) {
            $folder = Join-Path $stage $case.Id
            $null = [IO.Directory]::CreateDirectory($folder)
            [IO.File]::WriteAllBytes((Join-Path $folder 'baseline.json'), $case.Baseline)
            [IO.File]::WriteAllBytes((Join-Path $folder 'current.json'), $case.Current)
            [IO.File]::WriteAllText((Join-Path $folder 'settings.json'), (@{ ExcludeProperties=$case.Exclusions } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        }
        [pscustomobject]@{ StageRoot=$stage; CaseCount=$prepared.Count; CaseIds=@($prepared.Id); BaselineManifestSha256=$baseline.Hash; CurrentManifestSha256=$current.Hash; RunId=$RunId }
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '^drift\.[A-Za-z]+\z') { $_.Exception.Message } else { 'drift.inputsInvalid' }
        # Only the freshly allocated, receipt-owned root is removed on failure.
        if ($stageCreated) {
            try {
                if (-not $stage -or [IO.Path]::GetDirectoryName($stage) -cne $parent -or [IO.Path]::GetFileName($stage) -cnotmatch '^maester-drift-[0-9a-f]{32}\z') { throw 'unsafe-cleanup-path' }
                if ([IO.Directory]::Exists($stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
                if (Test-Path -LiteralPath $stage -ErrorAction Stop) { throw 'cleanup-incomplete' }
            }
            catch {
                $failure = [InvalidOperationException]::new('drift.stagingCleanupFailed')
                $failure.Data['StageRoot'] = $stage
                throw $failure
            }
        }
        throw [InvalidOperationException]::new($code)
    }
}

Export-ModuleMember -Function Initialize-MaesterDriftInput
