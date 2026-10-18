#Requires -Version 7.6
BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $runnerPath = Join-Path $repoRoot 'scripts/Invoke-MaesterAzureDevOpsRun.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$null, [ref]$null)
    $guard = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ApprovedDriftOutputScope'}, $true)
    . ([scriptblock]::Create($guard.Extent.Text))
    Import-Module (Join-Path $repoRoot 'scripts/Maester.DriftRun.psm1') -Force
    $source = Get-Content -LiteralPath $runnerPath -Raw
    $allocation = $source.IndexOf('    $approvedDriftRun = New-MaesterDriftRunRoot')
    $end = $source.IndexOf('    $outputFolder =', $allocation)
    if ($allocation -lt 0 -or $end -lt $allocation) { throw 'Production allocation boundary missing.' }
    $script:allocationBlock = [scriptblock]::Create($source.Substring($allocation, $end - $allocation))
}
Describe 'Drift output stays outside pipeline publication' {
    It 'rejects a root equal to or below any workspace boundary: <selector>' -ForEach @(
        @{selector='working';equal=$false}, @{selector='sources';equal=$false},
        @{selector='default';equal=$false}, @{selector='working';equal=$true}
    ) {
        $working = Join-Path $TestDrive 'working'
        $sources = Join-Path $TestDrive 'sources'
        $default = Join-Path $TestDrive 'default'
        $boundary = switch ($selector) {working {$working};sources {$sources};default {$default}}
        $root = if ($equal) {$boundary} else {Join-Path $boundary 'test-results/private-run'}
        { Assert-ApprovedDriftOutputScope -RunRoot $root -WorkspaceRoots @($working,$sources,$default) } |
            Should -Throw '*drift.outputInsideWorkspace*'
    }
    It 'allows a sibling with the same textual prefix and normal external temporary output' {
        $workspace = Join-Path $TestDrive 'work'
        foreach ($root in @((Join-Path $TestDrive 'work-other/private-run'), (Join-Path $TestDrive 'temp/private-run'))) {
            { Assert-ApprovedDriftOutputScope -RunRoot $root -WorkspaceRoots @($workspace,'','') } | Should -Not -Throw
        }
    }
    It 'rejects actual allocation under TEMP in the workspace before input/report writes' {
        $workspace = Join-Path $TestDrive 'workspace'
        $temporary = Join-Path $workspace 'test-results'
        $null = New-Item -ItemType Directory -Path $temporary
        $oldTemp = $env:TEMP; $oldTmp = $env:TMP; $oldTmpDir = $env:TMPDIR
        $oldSources = $env:BUILD_SOURCESDIRECTORY; $oldDefault = $env:SYSTEM_DEFAULTWORKINGDIRECTORY
        $approvedDriftRun = $null
        try {
            $env:TEMP=$temporary; $env:TMP=$temporary; $env:TMPDIR=$temporary
            $env:BUILD_SOURCESDIRECTORY=$workspace; $env:SYSTEM_DEFAULTWORKINGDIRECTORY=$workspace
            $workingDirectory = [pscustomobject]@{Path=$workspace}
            $caught=$null
            try { . $script:allocationBlock; throw 'Unexpectedly reached input/report writes.' } catch {$caught=$_}
            $caught.Exception.Message | Should -BeExactly 'drift.outputInsideWorkspace'
            $approvedDriftRun | Should -Not -BeNullOrEmpty
            $approvedDriftRun.Root | Should -BeLike "$temporary*"
            # Model final-cleanup failure: the surviving allocated tree is still empty.
            @(Get-ChildItem -LiteralPath $approvedDriftRun.Root -Recurse -File -Force).Count | Should -Be 0
        }
        finally {
            if ($null -ne $approvedDriftRun) {
                Remove-DriftOwnedDirectory -Path $approvedDriftRun.Root -Parent $approvedDriftRun.Parent -LeafPattern ('^'+[regex]::Escape($approvedDriftRun.Leaf)+'\z')
            }
            foreach ($entry in @(@{name='TEMP';value=$oldTemp},@{name='TMP';value=$oldTmp},@{name='TMPDIR';value=$oldTmpDir},@{name='BUILD_SOURCESDIRECTORY';value=$oldSources},@{name='SYSTEM_DEFAULTWORKINGDIRECTORY';value=$oldDefault})) {
                [Environment]::SetEnvironmentVariable($entry.name,$(if($null -eq $entry.value){[NullString]::Value}else{$entry.value}),'Process')
            }
        }
    }
}
