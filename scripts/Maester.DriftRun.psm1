#Requires -Version 7.6
Set-StrictMode -Version Latest

# Host-local port of the adapter reviewed in azd-maester-containerappjob commit
# 5132a5320969d15ff8b707b5f4b97e2817aee3f3. Keep this copy independent until
# two native hosts have completed their own qualification.

Set-Variable -Name LockedDriftSuiteSha256 -Option ReadOnly -Scope Script -Value '4284b8a66d98ea82c3f3d6554f03188ab8dcf5cb6e72f11aec8538e08d5d3096'

function New-DriftSafeError {
    param([Parameter(Mandatory)][string]$Code)
    [InvalidOperationException]::new($Code)
}

function Get-DriftFullPath {
    param([Parameter(Mandatory)][string]$Path)
    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
}

function Test-DriftOwnedChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$LeafPattern
    )
    $fullPath = Get-DriftFullPath $Path
    $fullParent = Get-DriftFullPath $Parent
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($fullPath), $fullParent, $comparison)) { return $false }
    [IO.Path]::GetFileName($fullPath) -cmatch $LeafPattern
}

function Remove-DriftOwnedDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$LeafPattern
    )
    $fullPath = Get-DriftFullPath $Path
    if (-not (Test-DriftOwnedChildPath -Path $fullPath -Parent $Parent -LeafPattern $LeafPattern)) {
        throw (New-DriftSafeError 'drift.unsafeCleanupPath')
    }
    if ([IO.Directory]::Exists($fullPath)) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
    }
    if ([IO.Directory]::Exists($fullPath) -or [IO.File]::Exists($fullPath)) {
        throw (New-DriftSafeError 'drift.cleanupIncomplete')
    }
}

function Set-DriftPrivateDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }
    else {
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        if ([IO.File]::GetUnixFileMode($Path) -ne ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)) {
            throw (New-DriftSafeError 'drift.privateOutputNotProtected')
        }
    }
}

function New-MaesterDriftRunRoot {
    [CmdletBinding()]
    param()
    # Native exclusive creation retries collisions and returns only a fresh child.
    $directory = [IO.Directory]::CreateTempSubdirectory('maester-approved-drift-')
    try {
        $root = Get-DriftFullPath $directory.FullName
        $parent = Get-DriftFullPath $directory.Parent.FullName
        $leaf = $directory.Name
        $leafPattern = '^' + [regex]::Escape($leaf) + '\z'
        if (-not $leaf.StartsWith('maester-approved-drift-', [StringComparison]::Ordinal) -or -not (Test-DriftOwnedChildPath -Path $root -Parent $parent -LeafPattern $leafPattern)) { throw (New-DriftSafeError 'drift.runAllocationInvalid') }
        Set-DriftPrivateDirectory -Path $root
        $staging = Join-Path $root 'staging'
        $output = Join-Path $root 'output'
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        [IO.Directory]::CreateDirectory($output) | Out-Null
        Set-DriftPrivateDirectory -Path $staging
        Set-DriftPrivateDirectory -Path $output
        [pscustomobject]@{ Root=$root; StagingParent=$staging; OutputParent=$output; Parent=$parent; Leaf=$leaf }
    }
    catch {
        $setupException = $_.Exception
        # Bind recovery directly to the exclusive allocator receipt, including
        # failures before path normalization or privacy setup completed.
        $root = $directory.FullName
        $parent = $directory.Parent.FullName
        $leafPattern = '^' + [regex]::Escape($directory.Name) + '\z'
        try { Remove-DriftOwnedDirectory -Path $root -Parent $parent -LeafPattern $leafPattern }
        catch {
            $cleanup = New-DriftSafeError 'drift.runCleanupFailed'
            $cleanup.Data['RunRoot'] = [IO.Path]::GetFullPath($root)
            $cleanup.Data['SetupException'] = $setupException
            $cleanup.Data['CleanupException'] = $_.Exception
            throw $cleanup
        }
        $failure = New-DriftSafeError 'drift.privateOutputSetupFailed'
        $failure.Data['RunRoot'] = [IO.Path]::GetFullPath($root)
        $failure.Data['SetupException'] = $setupException
        throw $failure
    }
}

function Assert-MaesterDriftTenantContext {
    param([Parameter(Mandatory)][string]$ExpectedTenantId)
    $expected = [guid]::Empty
    if (-not [guid]::TryParse($ExpectedTenantId, [ref]$expected) -or $expected -eq [guid]::Empty) {
        throw (New-DriftSafeError 'drift.tenantConfigurationInvalid')
    }
    $mgTenant = $null
    $azTenant = $null
    try { $mgTenant = [guid]::Parse([string](Get-MgContext).TenantId) } catch { $mgTenant = $null }
    try { $azTenant = [guid]::Parse([string](Get-AzContext).Tenant.Id) } catch { $azTenant = $null }
    if ($null -eq $mgTenant -or $null -eq $azTenant -or $mgTenant -ne $expected -or $azTenant -ne $expected) {
        throw (New-DriftSafeError 'drift.tenantMismatch')
    }
}

function Assert-MaesterDriftSuite {
    param([Parameter(Mandatory)][string]$SuitePath)
    $fullPath = [IO.Path]::GetFullPath($SuitePath)
    if (-not [IO.File]::Exists($fullPath) -or [IO.Path]::GetFileName($fullPath) -cne 'MT1060Drift.tests.ps1') {
        throw (New-DriftSafeError 'drift.suiteMissing')
    }
    $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($hash -cne $script:LockedDriftSuiteSha256) { throw (New-DriftSafeError 'drift.suiteHashMismatch') }
    $fullPath
}

function Read-DriftJunitErrors {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path -Force).Length -eq 0) { throw (New-DriftSafeError 'drift.junitMissing') }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 4194304
    $reader = $null
    try {
        $reader = [Xml.XmlReader]::Create($Path, $settings)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        $root = $document.DocumentElement
        # JUnit has a "name" attribute: bypass PowerShell's XML property adapter.
        if ($null -eq $root -or $root.get_Name() -cne 'testsuites' -or -not $root.HasAttribute('errors')) { throw (New-DriftSafeError 'drift.junitInvalid') }
        $errors = 0L
        if (-not [long]::TryParse($root.GetAttribute('errors'), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$errors) -or $errors -lt 0) { throw (New-DriftSafeError 'drift.junitInvalid') }
        $errors
    }
    catch [InvalidOperationException] { throw }
    catch { throw (New-DriftSafeError 'drift.junitInvalid') }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
}

function Assert-MaesterDriftResults {
    param(
        [Parameter(Mandatory)]$MaesterResult,
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$SuitePath,
        [Parameter(Mandatory)][string]$JunitPath
    )
    $junitErrors = Read-DriftJunitErrors -Path $JunitPath
    if ($junitErrors -ne 0) { throw (New-DriftSafeError 'drift.junitErrors') }
    $tests = @($MaesterResult.Tests)
    $expectedCount = 4 * [int]$Receipt.CaseCount
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($caseId in @($Receipt.CaseIds)) {
        foreach ($suffix in 1..4) { [void]$expected.Add("MT1060.$caseId.$suffix") }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $suiteFullPath = [IO.Path]::GetFullPath($SuitePath)
    $suiteTests = @()
    foreach ($test in $tests) {
        if ($null -eq $test -or $test.Id -isnot [string]) { throw (New-DriftSafeError 'drift.resultAccounting') }
        $testPath = if ($test.ScriptBlockFile) { [IO.Path]::GetFullPath([string]$test.ScriptBlockFile) } else { $null }
        $isSuitePath = $testPath -and [string]::Equals($testPath, $suiteFullPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))
        $isDriftId = $test.Id.StartsWith('MT1060.', [StringComparison]::Ordinal)
        if ($isDriftId -or $isSuitePath) {
            if (-not $isSuitePath -or -not $isDriftId -or -not $expected.Contains($test.Id) -or -not $seen.Add($test.Id)) { throw (New-DriftSafeError 'drift.resultAccounting') }
            $suiteTests += $test
            $allowed = if ($test.Id -match '\.[34]\z') { @('Passed','Failed') } else { @('Passed') }
            if ($test.Result -isnot [string] -or -not (@($allowed | Where-Object { [string]::Equals($_, $test.Result, [StringComparison]::Ordinal) }).Count -eq 1)) { throw (New-DriftSafeError 'drift.resultAccounting') }
        }
    }
    if ($Receipt.CaseCount -lt 1 -or $suiteTests.Count -ne $expectedCount -or $seen.Count -ne $expected.Count) { throw (New-DriftSafeError 'drift.resultAccounting') }
    $MaesterResult
}

function Invoke-MaesterApprovedDrift {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$OutputParent,
        [Parameter(Mandatory)][string]$TestsPath,
        [Parameter(Mandatory)][string]$SuitePath,
        [Parameter(Mandatory)][hashtable]$MaesterInvokeParameters
    )
    $expectedStageParent = Join-Path (Get-DriftFullPath $RunRoot) 'staging'
    $junitPath = Join-Path $OutputParent 'pester-junit.xml'
    $result = $null
    $invokeError = $null
    try {
        if (-not (Test-DriftOwnedChildPath -Path $OutputParent -Parent $RunRoot -LeafPattern '^output\z')) { throw (New-DriftSafeError 'drift.outputScope') }
        $testsFullPath = Get-DriftFullPath $TestsPath
        $suiteFullPath = Get-DriftFullPath $SuitePath
        $scopePrefix = $testsFullPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $suiteFullPath.StartsWith($scopePrefix, $comparison)) { throw (New-DriftSafeError 'drift.suiteScope') }
        if (-not (Test-DriftOwnedChildPath -Path $Receipt.StageRoot -Parent $expectedStageParent -LeafPattern '^maester-drift-[0-9a-f]{32}\z')) { throw (New-DriftSafeError 'drift.stageScope') }
        $suite = Assert-MaesterDriftSuite -SuitePath $SuitePath
        $MaesterInvokeParameters['DriftRoot'] = $Receipt.StageRoot
        $MaesterInvokeParameters['PassThru'] = $true
        $MaesterInvokeParameters['OutputFolder'] = $OutputParent
        $MaesterInvokeParameters['OutputFolderFileName'] = 'approved-drift'
        $config = $MaesterInvokeParameters['PesterConfiguration']
        $config.Run.ExcludePath = @()
        $config.Run.PassThru = $true
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputFormat = 'JUnitXml'
        $config.TestResult.OutputPath = $junitPath
        $config.TestResult.OutputEncoding = 'UTF8'
        $config.TestResult.TestSuiteName = 'MaesterApprovedDrift'
        $result = Invoke-Maester @MaesterInvokeParameters
        $result = Assert-MaesterDriftResults -MaesterResult $result -Receipt $Receipt -SuitePath $suite -JunitPath $junitPath
        foreach ($reportName in @('approved-drift.html', 'approved-drift.json', 'approved-drift.md', 'approved-drift-summary.md')) {
            $reportPath = Join-Path $OutputParent $reportName
            if (-not [IO.File]::Exists($reportPath) -or (Get-Item -LiteralPath $reportPath -Force).Length -eq 0) {
                throw (New-DriftSafeError 'drift.reportMissing')
            }
        }
    }
    catch {
        $invokeError = $_.Exception
    }
    finally {
        try { Remove-DriftOwnedDirectory -Path $Receipt.StageRoot -Parent $expectedStageParent -LeafPattern '^maester-drift-[0-9a-f]{32}\z' }
        catch {
            $cleanup = New-DriftSafeError 'drift.stagingCleanupFailed'
            $cleanup.Data['StageRoot'] = [IO.Path]::GetFullPath($Receipt.StageRoot)
            if ($null -ne $invokeError) { $cleanup.Data['InvocationException'] = $invokeError }
            throw $cleanup
        }
    }
    if ($null -ne $invokeError) {
        $failure = New-DriftSafeError 'drift.runFailed'
        $failure.Data['InvocationException'] = $invokeError
        throw $failure
    }
    [pscustomobject]@{ Result=$result; OutputHtmlPath=(Join-Path $OutputParent 'approved-drift.html'); OutputJsonPath=(Join-Path $OutputParent 'approved-drift.json'); OutputMarkdownPath=(Join-Path $OutputParent 'approved-drift.md'); OutputSummaryPath=(Join-Path $OutputParent 'approved-drift-summary.md'); JunitPath=$junitPath }
}

Export-ModuleMember -Function New-MaesterDriftRunRoot, Assert-MaesterDriftTenantContext, Assert-MaesterDriftSuite, Assert-MaesterDriftResults, Invoke-MaesterApprovedDrift, Remove-DriftOwnedDirectory
