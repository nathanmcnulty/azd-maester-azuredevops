#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/Maester.DriftInputs.psm1') -Force
    function Write-FixtureJson($Path, $Value) {
        [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40 -Compress), [Text.UTF8Encoding]::new($false))
    }
    function Update-Fixture($Fixture, [switch]$ApproveBaseline) {
        Write-FixtureJson (Join-Path $Fixture.Args.InputRoot 'baseline-manifest.json') $Fixture.Baseline
        if ($ApproveBaseline) { $Fixture.Args.ExpectedBaselineManifestSha256 = (Get-FileHash (Join-Path $Fixture.Args.InputRoot 'baseline-manifest.json')).Hash.ToLowerInvariant() }
        $Fixture.Current.baselineManifestSha256 = $Fixture.Args.ExpectedBaselineManifestSha256
        Write-FixtureJson (Join-Path $Fixture.Args.InputRoot 'current-manifest.json') $Fixture.Current
    }
    function New-DriftFixture {
        param([int]$Count=1, $Data=@{enabled=$true}, $Schema=@{type='object';properties=@{enabled=@{type='boolean'}};required=@('enabled');additionalProperties=$false})
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $parent = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root,$parent
        $args = @{InputRoot=$root;StagingParent=$parent;ExpectedBaselineManifestSha256=('0'*64);TenantId='00000000-0000-0000-0000-000000000001';Environment='fixture';RunId='00000000-0000-0000-0000-000000000002';ProducerId='fixture-export';ProducerRevision=('a'*40);Now=[datetimeoffset]'2026-10-16T12:00:00Z'}
        $b = @{schemaVersion='1.0';tenantId=$args.TenantId;environment='fixture';host='azuredevops';revision=('b'*40);approvalReference='fixture-only';normalizationRevision='identity.v1';cases=@()}
        $c = @{schemaVersion='1.0';tenantId=$args.TenantId;environment='fixture';host='azuredevops';runId=$args.RunId;baselineManifestSha256=('0'*64);producerId='fixture-export';producerRevision=('a'*40);normalizationRevision='identity.v1';capturedAt='2026-10-16T11:59:00Z';cases=@()}
        foreach ($index in 1..$Count) {
            $id = "case-$index"
            foreach ($side in 'baseline','current') { Write-FixtureJson (Join-Path $root "$id.$side.json") $Data }
            $path = Join-Path $root "$id.baseline.json"
            $hash = (Get-FileHash $path).Hash.ToLowerInvariant(); $length=(Get-Item $path).Length
            $b.cases += @{id=$id;sha256=$hash;length=$length;schemaRevision='fixture.v1';schema=$Schema;excludeProperties=@()}
            $c.cases += @{id=$id;sha256=$hash;length=$length}
        }
        $fixture = @{Args=$args;Baseline=$b;Current=$c}
        Update-Fixture $fixture -ApproveBaseline
        $fixture
    }
    function Set-CurrentBytes($Fixture, [byte[]]$Bytes) {
        $path = Join-Path $Fixture.Args.InputRoot 'case-1.current.json'
        [IO.File]::WriteAllBytes($path, $Bytes)
        $Fixture.Current.cases[0].sha256=(Get-FileHash $path).Hash.ToLowerInvariant()
        $Fixture.Current.cases[0].length=$Bytes.Length
        Update-Fixture $Fixture
    }
}

Describe 'Approved data-only drift input preparation' {
    It 'stages exact verified bytes and generated settings without changing inputs or process state' {
        $f=New-DriftFixture -Count 2
        $before=@(Get-ChildItem $f.Args.InputRoot | Get-FileHash | Select-Object Path,Hash | ConvertTo-Json)
        $ambient=[Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
        $parameters=$f.Args; $result=Initialize-MaesterDriftInput @parameters
        $result.CaseCount | Should -Be 2
        $result.BaselineManifestSha256 | Should -BeExactly $parameters.ExpectedBaselineManifestSha256
        foreach ($id in $result.CaseIds) {
            (Get-FileHash (Join-Path $result.StageRoot "$id/current.json")).Hash | Should -BeExactly (Get-FileHash (Join-Path $f.Args.InputRoot "$id.current.json")).Hash
            (Get-Content (Join-Path $result.StageRoot "$id/settings.json") -Raw | ConvertFrom-Json).ExcludeProperties.Count | Should -Be 0
        }
        if ($IsWindows) { (Get-Acl $result.StageRoot).AreAccessRulesProtected | Should -BeTrue }
        else { [IO.File]::GetUnixFileMode($result.StageRoot) | Should -Be ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) }
        @(Get-ChildItem $f.Args.InputRoot | Get-FileHash | Select-Object Path,Hash | ConvertTo-Json) | Should -BeExactly $before
        [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process') | Should -BeExactly $ambient
    }
    It 'does not accept manifest-self-declared approval as the external expected digest' {
        $f=New-DriftFixture; $f.Baseline.approvalReference='different'; Update-Fixture $f
        $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.baselineApprovalMismatch*'
        @(Get-ChildItem $p.StagingParent).Count | Should -Be 0
    }
    It 'rejects a foreign or stale current manifest for <field>' -ForEach @(
        @{field='tenantId';value='00000000-0000-0000-0000-000000000003'},@{field='environment';value='foreign'},@{field='host';value='containerappjob'},@{field='runId';value='00000000-0000-0000-0000-000000000003'},@{field='producerId';value='foreign'},@{field='producerRevision';value=('c'*40)},@{field='normalizationRevision';value='foreign'},@{field='capturedAt';value='2026-10-16T10:00:00Z'},@{field='capturedAt';value='2026-10-16T12:02:00Z'},@{field='capturedAt';value='2026-10-16T12:00:00+00:00'}
    ) {
        $f=New-DriftFixture; $f.Current[$field]=$value; Update-Fixture $f
        $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.*'
    }
    It 'rejects unknown or executable files without executing them' {
        $f=New-DriftFixture; "throw 'must-not-execute'" | Set-Content (Join-Path $f.Args.InputRoot 'payload.ps1')
        $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.fileParity*'
    }
    It 'rejects missing, duplicate, traversing, or extra cases and manifest keys' {
        foreach ($variant in 'missing','duplicate','traversal','unknown') {
            $f=New-DriftFixture
            switch ($variant) {
                'missing' { $f.Current.cases=@() }
                'duplicate' { $f.Baseline.cases += $f.Baseline.cases[0]; $f.Current.cases += $f.Current.cases[0] }
                'traversal' { $f.Baseline.cases[0].id='../escape'; $f.Current.cases[0].id='../escape' }
                'unknown' { $f.Current.secret='must-not-project' }
            }
            Update-Fixture $f -ApproveBaseline; $p=$f.Args
            { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.*'
        }
    }
    It 'rejects malformed, scalar, empty, case-colliding, and deeply nested JSON roots' {
        foreach ($text in @('{','1','[]','{}','{"enabled":true,"enabled":false}','{"enabled":true,"Enabled":false}',(('['*33)+'0'+(']'*33)))) {
            $f=New-DriftFixture; Set-CurrentBytes $f ([Text.Encoding]::UTF8.GetBytes($text)); $p=$f.Args
            { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.*'
        }
    }
    It 'rejects changed bytes, incorrect lengths and invalid UTF-8' {
        $f=New-DriftFixture; [IO.File]::WriteAllText((Join-Path $f.Args.InputRoot 'case-1.current.json'), '{"enabled":false}')
        $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.fileChanged*'
        $f=New-DriftFixture; $f.Current.cases[0].length=1; Update-Fixture $f; $p=$f.Args
        { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.fileChanged*'
        $f=New-DriftFixture; Set-CurrentBytes $f ([byte[]]@(255,254)); $p=$f.Args
        { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.inputsInvalid*'
    }
    It 'rejects data outside the approved closed schema and does not echo planted values' {
        $f=New-DriftFixture; Set-CurrentBytes $f ([Text.Encoding]::UTF8.GetBytes('{"enabled":true,"secret":"DRIFT-PRIVATE-CANARY"}'))
        $p=$f.Args; $failure=$null
        try { Initialize-MaesterDriftInput @p } catch { $failure=$_ | Out-String }
        $failure | Should -Not -BeNullOrEmpty
        $failure | Should -Not -Match 'DRIFT-PRIVATE-CANARY'
    }
    It 'refuses remote schema references, open objects and unbounded strings' {
        foreach ($variant in 'reference','open','unbounded') {
            $f=New-DriftFixture
            switch ($variant) {
                'reference' { $f.Baseline.cases[0].schema['$ref']='https://must-not-be-requested.invalid/schema' }
                'open' { $f.Baseline.cases[0].schema.additionalProperties=$true }
                'unbounded' { $f.Baseline.cases[0].schema.properties.enabled=@{type='string'} }
            }
            Update-Fixture $f -ApproveBaseline; $p=$f.Args
            { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.*'
        }
    }
    It 'rejects files above one MiB and more than 32 cases before staging' {
        $f=New-DriftFixture; Set-CurrentBytes $f ([byte[]]::new(1048577))
        $f.Current.cases[0].length=1048576; Update-Fixture $f; $p=$f.Args
        { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.fileSize*'
        $f=New-DriftFixture -Count 33; $p=$f.Args
        { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.*'
    }
    It 'enforces the sixteen-MiB total even when every file and schema is individually valid' {
        $schema=@{type='object';additionalProperties=$false;required=@('items');properties=@{items=@{type='array';maxItems=256;items=@{type='string';maxLength=4096}}}}
        $f=New-DriftFixture -Count 14 -Data @{items=@((1..256 | ForEach-Object { 'x'*2500 }))} -Schema $schema
        $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.totalSize*'
        @(Get-ChildItem $p.StagingParent).Count | Should -Be 0
    }
    It 'rejects root links and staging inside the input root' {
        $f=New-DriftFixture
        $link=Join-Path $TestDrive ('link-'+[guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType $(if ($IsWindows) {'Junction'} else {'SymbolicLink'}) -Path $link -Target $f.Args.InputRoot
        $p=$f.Args.Clone(); $p.InputRoot=$link
        { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.linkRejected*'
        $p=$f.Args.Clone(); $p.StagingParent=$p.InputRoot
        { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.stagingInsideInput*'
    }
    It 'preserves an existing staging collision and its unrelated contents' {
        $f=New-DriftFixture
        $collision=Join-Path $f.Args.StagingParent ('maester-drift-'+('0'*32))
        $null=New-Item -ItemType Directory -Path $collision
        $marker=Join-Path $collision 'unrelated.txt'; 'preserve' | Set-Content $marker
        InModuleScope Maester.DriftInputs -Parameters @{Parameters=$f.Args;Collision=$collision} {
            Mock Join-Path {
                param($Path,$ChildPath)
                if ($ChildPath -like 'maester-drift-*') { return $Collision }
                [IO.Path]::Combine($Path,$ChildPath)
            }
            { Initialize-MaesterDriftInput @Parameters } | Should -Throw '*drift.stagingCollision*'
        }
        Test-Path -LiteralPath $marker | Should -BeTrue
        Get-Content -LiteralPath $marker | Should -BeExactly 'preserve'
    }
    It 'rejects boolean and numeric current header <header> before any staging' -ForEach @(
        @{header='schemaVersion'},@{header='tenantId'},@{header='environment'},@{header='host'},@{header='runId'},@{header='baselineManifestSha256'},@{header='producerId'},@{header='producerRevision'},@{header='normalizationRevision'},@{header='capturedAt'}
    ) {
        foreach ($value in @($true,42)) {
            $f=New-DriftFixture; $f.Current[$header]=$value
            Write-FixtureJson (Join-Path $f.Args.InputRoot 'current-manifest.json') $f.Current
            $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.manifestType*'
            @(Get-ChildItem $p.StagingParent).Count | Should -Be 0
        }
    }
    It 'rejects boolean and numeric approved baseline headers and ordinally different current text' {
        foreach ($header in 'schemaVersion','tenantId','environment','host','revision','approvalReference','normalizationRevision') {
            foreach ($value in @($true,42)) {
                $f=New-DriftFixture; $f.Baseline[$header]=$value; Update-Fixture $f -ApproveBaseline
                $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.manifestType*'
            }
        }
        $f=New-DriftFixture; $f.Current.environment="fix$([char]0x00AD)ture"
        Write-FixtureJson (Join-Path $f.Args.InputRoot 'current-manifest.json') $f.Current
        $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.targetBinding*'
    }
    It 'rejects same-directory staging with trailing separators in either orientation' {
        foreach ($orientation in 'input','parent','both') {
            $f=New-DriftFixture; $p=$f.Args; $p.StagingParent=$p.InputRoot
            if ($orientation -in 'input','both') { $p.InputRoot += [IO.Path]::DirectorySeparatorChar }
            if ($orientation -in 'parent','both') { $p.StagingParent += [IO.Path]::DirectorySeparatorChar }
            { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.stagingInsideInput*'
        }
    }
    It 'cleans a partial private stage after write failure even with a trailing parent separator' {
        $f=New-DriftFixture; $f.Args.StagingParent += [IO.Path]::DirectorySeparatorChar
        InModuleScope Maester.DriftInputs -Parameters @{Parameters=$f.Args} {
            Mock Join-Path {
                param($Path,$ChildPath)
                if ($ChildPath -eq 'current.json') { throw 'synthetic-private-write-error' }
                [IO.Path]::Combine($Path,$ChildPath)
            }
            { Initialize-MaesterDriftInput @Parameters } | Should -Throw '*drift.inputsInvalid*'
        }
        @(Get-ChildItem $f.Args.StagingParent).Count | Should -Be 0
    }
    It 'reports failed partial-stage deletion without leaking values or losing the recovery path' {
        $f=New-DriftFixture
        $failure=InModuleScope Maester.DriftInputs -Parameters @{Parameters=$f.Args} {
            Mock Join-Path {
                param($Path,$ChildPath)
                if ($ChildPath -eq 'current.json') { throw 'synthetic-private-write-error' }
                [IO.Path]::Combine($Path,$ChildPath)
            }
            Mock Remove-Item { throw 'synthetic-private-cleanup-error' }
            try { Initialize-MaesterDriftInput @Parameters } catch { $_ }
        }
        $failure.Exception.Message | Should -BeExactly 'drift.stagingCleanupFailed'
        $failure.Exception.InnerException | Should -BeNullOrEmpty
        ($failure | Out-String) | Should -Not -Match 'synthetic-private-'
        $stage=$failure.Exception.Data['StageRoot']
        [IO.Path]::GetDirectoryName($stage) | Should -BeExactly $f.Args.StagingParent
        Test-Path -LiteralPath (Join-Path $stage 'case-1/baseline.json') | Should -BeTrue
    }
    It 'rejects whitespace-padded GUIDs and newline-terminated trusted labels or digests' {
        foreach ($field in 'TenantId','RunId','Environment','ProducerId','ProducerRevision','ExpectedBaselineManifestSha256') {
            $f=New-DriftFixture; $f.Args[$field]+="`n"; $p=$f.Args
            { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.*'
            @(Get-ChildItem $p.StagingParent).Count | Should -Be 0
        }
    }
    It 'rejects newline-terminated case identifiers, revisions, exclusions and timestamps' {
        foreach ($field in 'id','schemaRevision','excludeProperties','capturedAt') {
            $f=New-DriftFixture
            switch ($field) {
                'id' { $f.Baseline.cases[0].id+="`n"; $f.Current.cases[0].id+="`n"; $expected='drift.caseIdentity' }
                'schemaRevision' { $f.Baseline.cases[0].schemaRevision+="`n"; $expected='drift.invalidLabel' }
                'excludeProperties' { $f.Baseline.cases[0].excludeProperties=@("enabled`n"); $expected='drift.exclusions' }
                'capturedAt' { $f.Current.capturedAt+="`n"; $expected='drift.inputFreshness' }
            }
            Update-Fixture $f -ApproveBaseline; $p=$f.Args
            { Initialize-MaesterDriftInput @p } | Should -Throw "*$expected*"
        }
    }
    It 'rejects deceptive enum and required keywords instead of silently relaxing approved schemas' {
        foreach ($keyword in 'enum','required') {
            $f=New-DriftFixture
            if ($keyword -eq 'enum') {
                $f.Baseline.cases[0].schema.properties.enabled["e$([char]0x00AD)num"]=@($true)
                Set-CurrentBytes $f ([Text.Encoding]::UTF8.GetBytes('{"enabled":false}'))
            }
            else {
                $f.Baseline.cases[0].schema.Remove('required')
                $f.Baseline.cases[0].schema["r$([char]0x00AD)equired"]=@('enabled')
                $f.Baseline.cases[0].schema.properties.other=@{type='boolean'}
                Set-CurrentBytes $f ([Text.Encoding]::UTF8.GetBytes('{"other":true}'))
            }
            Update-Fixture $f -ApproveBaseline; $p=$f.Args
            { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.schemaUnsupported*'
            @(Get-ChildItem $p.StagingParent).Count | Should -Be 0
        }
    }
    It 'requires ordinal schema type values and manifest field names' {
        $f=New-DriftFixture; $f.Baseline.cases[0].schema.type="ob$([char]0x00AD)ject"
        Update-Fixture $f -ApproveBaseline; $p=$f.Args
        { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.schemaUnsupported*'
        $f=New-DriftFixture
        $f.Current["p$([char]0x00AD)roducerId"]=$f.Current.producerId
        $f.Current.Remove('producerId')
        Write-FixtureJson (Join-Path $f.Args.InputRoot 'current-manifest.json') $f.Current
        $p=$f.Args; { Initialize-MaesterDriftInput @p } | Should -Throw '*drift.manifestShape*'
    }
}
