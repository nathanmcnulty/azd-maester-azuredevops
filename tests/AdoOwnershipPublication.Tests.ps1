# Exercise the production publication function with an in-memory Git provider.
# No remote, authentication, CLI executable or Azure service is contacted.
BeforeAll {
  $root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Maester-OwnershipJournal.psm1')
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Setup-PostDeploy.ps1'), [ref]$null, [ref]$null)
  foreach ($name in @('Push-RepositoryFiles', 'Remove-DirectoryQuiet')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  function global:git {
    $f = $global:PublicationJournalFixture; $global:LASTEXITCODE = 0
    if ('clone' -in $args) {
      $f.Committed = $false
      $f.ClonedHead = if ($f.Empty) { '' } else { $f.CurrentHead }
      $f.LocalHead = $f.ClonedHead
      $f.AppliedReceipts = @{}
      foreach ($record in @((Get-MaesterOwnershipJournal -Session $f.Session).records | Where-Object { $_.kind -ceq 'AdoRepositoryPublication' -and $_.state -ceq 'applied' })) {
        $f.AppliedReceipts[$record.operationId] = ($record | ConvertTo-Json -Depth 30 -Compress)
      }
      return
    }
    if ('checkout' -in $args -or 'add' -in $args) { return }
    if ('commit' -in $args) { $f.Committed = $true; $f.LocalHead = $f.NextCommit; $f.Commits++; return }
    if ('hash-object' -in $args) { return ('b' * 40) }
    if ('rev-parse' -in $args) {
      if ($args[-1] -like ':*') { return ('b' * 40) }
      if ('--verify' -in $args -and $f.Empty -and -not $f.Committed) { $global:LASTEXITCODE = 1; return }
      return $f.LocalHead
    }
    if ('status' -in $args) { if ($f.Changed) { return ' M azure-pipelines.yml' }; return }
    if ('push' -in $args) {
      $f.Pushes++
      $records = (Get-MaesterOwnershipJournal -Session $f.Session).records
      $publication = @($records | Where-Object kind -eq AdoRepositoryPublication)
      $pending = @($publication | Where-Object state -CEQ pending)
      if ($pending.Count -ne 1 -or $publication.Count -ne ($f.AppliedReceipts.Count + 1)) { throw 'Publication reached Git without exactly one new pending checkpoint.' }
      foreach ($operationId in $f.AppliedReceipts.Keys) {
        $prior = @($publication | Where-Object operationId -CEQ $operationId)
        if ($prior.Count -ne 1 -or ($prior[0] | ConvertTo-Json -Depth 30 -Compress) -cne $f.AppliedReceipts[$operationId]) { throw 'Publication changed a prior applied receipt before Git push.' }
      }
      if ($pending[0].after.commitId -cne $f.LocalHead -or $pending[0].before.commitId -cne $f.ClonedHead -or -not $pending[0].key.EndsWith(":$($f.LocalHead)") -or $pending[0].exactIds.Count -ne 0) { throw 'Publication did not checkpoint the exact new commit before Git push.' }
      if ($f.AppliedReceipts.Count) {
        $predecessor = @($publication | Where-Object operationId -CEQ $pending[0].supersedesOperationId)
        if ($predecessor.Count -ne 1 -or $predecessor[0].state -cne 'applied' -or $predecessor[0].after.commitId -cne $f.ClonedHead -or -not $pending[0].coveredByOperationId -or $predecessor[0].coveredByOperationId -cne $pending[0].coveredByOperationId) { throw 'Publication successor did not checkpoint its exact owned predecessor before Git push.' }
      }
      $lease = "--force-with-lease=refs/heads/main:$($f.ClonedHead)"
      if ($lease -cnotin $args -or 'HEAD:refs/heads/main' -cnotin $args) { throw 'Publication did not condition its push on the exact reviewed ref or absence.' }
      if ($f.RemoteChangeBeforePush) { $f.CurrentHead = $f.RemoteChangeBeforePush; $f.Empty = $false }
      $remoteHead = if ($f.Empty) { '' } else { $f.CurrentHead }
      if ($remoteHead -cne $f.ClonedHead) { $global:LASTEXITCODE = 1; return }
      $f.CheckedPushes++
      if ($f.FailPush) { $global:LASTEXITCODE = 1 }
      else { $f.CurrentHead = $f.LocalHead; $f.Empty = $false }
      return
    }
    throw "Unexpected offline git invocation: $($args -join ' ')"
  }
  function Add-FixtureOwnedRepository {
    param($Session, [hashtable]$Publication)
    $parent = Start-MaesterOwnedOperation -Session $Session -Key Repository -Kind AdoRepository -Ownership Created -PlanHash ('a' * 64) -Expected @{ organizationId = $Publication.Expected.organizationId; projectId = $Publication.Expected.projectId }
    Complete-MaesterOwnedOperation -Session $Session -OperationId $parent.operationId -ExactIds @{ repositoryId = $Publication.Expected.repositoryId } | Out-Null
    $Publication.CoveredByOperationId = $parent.operationId
    return $parent.operationId
  }
}
Describe 'Publication ownership boundaries (offline)' {
  BeforeEach {
    $journalRoot = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    $script:publicationSession = Open-MaesterOwnershipJournal -ProjectRoot $journalRoot.FullName -Binding @{
      environmentName = 'test'; tenantId = '11111111-1111-4111-8111-111111111111'; subscriptionId = '22222222-2222-4222-8222-222222222222'
      solutionName = 'azure-devops'; resourceGroupId = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-test'
      setupClientId = '99999999-9999-4999-8999-999999999999'; organizationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; projectId = '33333333-3333-4333-8333-333333333333'
    }
    $script:publication = @{ Key = 'Publication:repo:main'; Kind = 'AdoRepositoryPublication'; Ownership = 'Mutation'; PlanHash = ('a' * 64)
      Expected = @{ organizationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; projectId = '33333333-3333-4333-8333-333333333333'; repositoryId = '44444444-4444-4444-8444-444444444444'; branch = 'refs/heads/main' } }
    $global:PublicationJournalFixture = @{ Session = $script:publicationSession; Changed = $true; Committed = $false; Empty = $false; FailPush = $false; Pushes = 0; CheckedPushes = 0; Commits = 0; CurrentHead = ('a' * 40); NextCommit = ('c' * 40); RemoteChangeBeforePush = '' }
    $script:publicationArguments = @{ RepositoryUrl = 'https://dev.azure.com/org/project/_git/repo'; Branch = 'main'; BearerToken = 'offline-token'
      Files = @(@{ Path = 'azure-pipelines.yml'; Content = 'reviewed' }); OwnershipSession = $script:publicationSession; PublicationOwnership = $script:publication }
    Mock Invoke-RestMethod { throw 'Network tripwire.' }
  }
  AfterEach { $script:publicationSession.Dispose(); Remove-Variable PublicationJournalFixture -Scope Global }
  AfterAll { Remove-Item Function:global:git -ErrorAction SilentlyContinue }

  It 'records exact before and after commit metadata on an adopted repository without claiming its ownership' {
    $result = Push-RepositoryFiles -RepositoryUrl 'https://dev.azure.com/org/project/_git/repo' -Branch main -BearerToken 'secret-fixture-never-persist' -Files @(@{ Path = 'azure-pipelines.yml'; Content = 'reviewed' }) -ExpectedBranchObjectId ('a' * 40) -OwnershipSession $script:publicationSession -PublicationOwnership $script:publication
    $result.Pushed | Should -BeTrue
    $records = (Get-MaesterOwnershipJournal -Session $script:publicationSession).records
    $records.Count | Should -Be 1
    $records[0].kind | Should -BeExactly AdoRepositoryPublication
    $records[0].state | Should -BeExactly applied
    $records[0].ownership | Should -BeExactly Mutation
    $records[0].coveredByOperationId | Should -BeNullOrEmpty
    $records[0].before.commitId | Should -BeExactly ('a' * 40)
    $records[0].after.commitId | Should -BeExactly ('c' * 40)
    $records[0].exactIds.commitId | Should -BeExactly ('c' * 40)
    $records[0].key | Should -BeExactly "Publication:repo:main:$('c' * 40)"
    $records[0].after.files | Should -Be @('azure-pipelines.yml')
    ($records | ConvertTo-Json -Depth 20) | Should -Not -Match 'secret-fixture|reviewed'
  }
  It 'links publication to a previously checkpointed owned repository' {
    $parent = Start-MaesterOwnedOperation -Session $script:publicationSession -Key Repository -Kind AdoRepository -Ownership Created -PlanHash ('a' * 64) -Expected @{ organizationId = $script:publication.Expected.organizationId; projectId = $script:publication.Expected.projectId }
    Complete-MaesterOwnedOperation -Session $script:publicationSession -OperationId $parent.operationId -ExactIds @{ repositoryId = $script:publication.Expected.repositoryId } | Out-Null
    $script:publication.CoveredByOperationId = $parent.operationId
    $null = Push-RepositoryFiles -RepositoryUrl 'https://dev.azure.com/org/project/_git/repo' -Branch main -BearerToken 'offline-token' -Files @(@{ Path = 'azure-pipelines.yml'; Content = 'reviewed' }) -ExpectedBranchObjectId ('a' * 40) -OwnershipSession $script:publicationSession -PublicationOwnership $script:publication
    $child = @((Get-MaesterOwnershipJournal -Session $script:publicationSession).records | Where-Object kind -eq AdoRepositoryPublication)[0]
    $child.state | Should -BeExactly applied
    $child.coveredByOperationId | Should -BeExactly $parent.operationId
  }
  It 'appends preparation, schedule activation and a later runtime update as one immutable owned publication chain' {
    $parentId = Add-FixtureOwnedRepository -Session $script:publicationSession -Publication $script:publication
    $priorReceipts = @{}
    $previousId = $null
    $stages = @(
      @{ Key = 'PreparationPublication:repo:main'; PlanHash = ('b' * 64); Before = ('a' * 40); Commit = ('c' * 40); Content = 'trigger: none' }
      @{ Key = 'Publication:repo:main'; PlanHash = ('c' * 64); Before = ('c' * 40); Commit = ('d' * 40); Content = 'schedules: reviewed activation' }
      @{ Key = 'Publication:repo:main'; PlanHash = ('d' * 64); Before = ('d' * 40); Commit = ('e' * 40); Content = 'schedules: reviewed runtime update' }
    )
    foreach ($stage in $stages) {
      $script:publication.Key = $stage.Key
      $script:publication.PlanHash = $stage.PlanHash
      $script:publicationArguments.Files = @(@{ Path = 'azure-pipelines.yml'; Content = $stage.Content })
      $global:PublicationJournalFixture.NextCommit = $stage.Commit
      $result = Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId $stage.Before
      $result.Pushed | Should -BeTrue
      $result.CommitId | Should -BeExactly $stage.Commit
      $records = (Get-MaesterOwnershipJournal -Session $script:publicationSession).records
      foreach ($record in $records | Where-Object { $priorReceipts.ContainsKey($_.operationId) }) {
        ($record | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $priorReceipts[$record.operationId]
      }
      $publications = @($records | Where-Object kind -CEQ AdoRepositoryPublication)
      $publications.Count | Should -Be ($priorReceipts.Count + 1)
      $current = $publications[-1]
      $current.state | Should -BeExactly applied
      $current.key | Should -BeExactly "$($stage.Key):$($stage.Commit)"
      $current.planHash | Should -BeExactly $stage.PlanHash
      $current.coveredByOperationId | Should -BeExactly $parentId
      $current.before.commitId | Should -BeExactly $stage.Before
      $current.after.commitId | Should -BeExactly $stage.Commit
      $current.exactIds.commitId | Should -BeExactly $stage.Commit
      $current.exactIds.repositoryId | Should -BeExactly $script:publication.Expected.repositoryId
      if ($previousId) { $current.supersedesOperationId | Should -BeExactly $previousId }
      else { $current.Contains('supersedesOperationId') | Should -BeFalse }
      $priorReceipts[$current.operationId] = ($current | ConvertTo-Json -Depth 30 -Compress)
      $previousId = $current.operationId
    }
    $records.Count | Should -Be 4
    @($publications | Where-Object state -CNE applied).Count | Should -Be 0
    $global:PublicationJournalFixture.Pushes | Should -Be 3
    $global:PublicationJournalFixture.CheckedPushes | Should -Be 3
    $global:PublicationJournalFixture.CurrentHead | Should -BeExactly ('e' * 40)
  }
  It 'preserves the current chain without a new receipt, commit or push on an unchanged rerun' {
    $null = Add-FixtureOwnedRepository -Session $script:publicationSession -Publication $script:publication
    $null = Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('a' * 40)
    $global:PublicationJournalFixture.NextCommit = 'd' * 40
    $null = Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('c' * 40)
    $before = (Get-MaesterOwnershipJournal -Session $script:publicationSession) | ConvertTo-Json -Depth 30 -Compress
    $global:PublicationJournalFixture.Changed = $false
    $global:PublicationJournalFixture.NextCommit = 'e' * 40
    $result = Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('d' * 40)
    $result.Pushed | Should -BeFalse
    $result.Changed | Should -BeFalse
    $result.CommitId | Should -BeExactly ('d' * 40)
    ((Get-MaesterOwnershipJournal -Session $script:publicationSession) | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
    $global:PublicationJournalFixture.Commits | Should -Be 2
    $global:PublicationJournalFixture.Pushes | Should -Be 2
    $global:PublicationJournalFixture.CheckedPushes | Should -Be 2
  }
  It 'refuses a stale historical predecessor even when the cloned branch matches that reviewed commit' {
    $null = Add-FixtureOwnedRepository -Session $script:publicationSession -Publication $script:publication
    $null = Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('a' * 40)
    $global:PublicationJournalFixture.NextCommit = 'd' * 40
    $null = Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('c' * 40)
    $before = (Get-MaesterOwnershipJournal -Session $script:publicationSession) | ConvertTo-Json -Depth 30 -Compress
    # A reviewed remote rollback must not fork the historical preparation receipt.
    $global:PublicationJournalFixture.CurrentHead = 'c' * 40
    $global:PublicationJournalFixture.NextCommit = 'e' * 40
    $failure = { Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('c' * 40) } | Should -Throw '*predecessor does not match*' -PassThru
    $failure.Exception.Data['MaesterPublicationBindingChanged'] | Should -BeTrue
    ((Get-MaesterOwnershipJournal -Session $script:publicationSession) | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
    $global:PublicationJournalFixture.Pushes | Should -Be 2
    $global:PublicationJournalFixture.CurrentHead | Should -BeExactly ('c' * 40)
  }
  It 'refuses repeated publication in an adopted repository after allowing its initial publication' {
    $initial = Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('a' * 40)
    $initial.Pushed | Should -BeTrue
    $before = (Get-MaesterOwnershipJournal -Session $script:publicationSession) | ConvertTo-Json -Depth 30 -Compress
    $global:PublicationJournalFixture.NextCommit = 'd' * 40
    $failure = { Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('c' * 40) } | Should -Throw '*same exact owned repository*' -PassThru
    $failure.Exception.Data['MaesterPublicationBindingChanged'] | Should -BeTrue
    $records = (Get-MaesterOwnershipJournal -Session $script:publicationSession).records
    $records.Count | Should -Be 1
    $records[0].coveredByOperationId | Should -BeNullOrEmpty
    ((Get-MaesterOwnershipJournal -Session $script:publicationSession) | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
    $global:PublicationJournalFixture.Pushes | Should -Be 1
    $global:PublicationJournalFixture.CurrentHead | Should -BeExactly ('c' * 40)
  }
  It 'keeps an ambiguous successor pending with its predecessor immutable and refuses another publication before push' {
    $parentId = Add-FixtureOwnedRepository -Session $script:publicationSession -Publication $script:publication
    $null = Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('a' * 40)
    $prior = @((Get-MaesterOwnershipJournal -Session $script:publicationSession).records | Where-Object kind -CEQ AdoRepositoryPublication)[0]
    $priorSnapshot = $prior | ConvertTo-Json -Depth 30 -Compress
    $global:PublicationJournalFixture.NextCommit = 'd' * 40
    $global:PublicationJournalFixture.FailPush = $true
    { Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('c' * 40) } | Should -Throw '*unresolved*'
    $records = (Get-MaesterOwnershipJournal -Session $script:publicationSession).records
    $publications = @($records | Where-Object kind -CEQ AdoRepositoryPublication)
    $publications.Count | Should -Be 2
    ($publications[0] | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $priorSnapshot
    $pending = @($publications | Where-Object state -CEQ pending)
    $pending.Count | Should -Be 1
    $pending[0].supersedesOperationId | Should -BeExactly $prior.operationId
    $pending[0].coveredByOperationId | Should -BeExactly $parentId
    $pending[0].before.commitId | Should -BeExactly ('c' * 40)
    $pending[0].after.commitId | Should -BeExactly ('d' * 40)
    $pending[0].exactIds.Count | Should -Be 0
    $global:PublicationJournalFixture.CheckedPushes | Should -Be 2
    $before = (Get-MaesterOwnershipJournal -Session $script:publicationSession) | ConvertTo-Json -Depth 30 -Compress
    $global:PublicationJournalFixture.FailPush = $false
    $global:PublicationJournalFixture.NextCommit = 'e' * 40
    $failure = { Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId ('c' * 40) } | Should -Throw '*prior publication outcome is unresolved*' -PassThru
    $failure.Exception.Data['MaesterPublicationBindingChanged'] | Should -BeTrue
    ((Get-MaesterOwnershipJournal -Session $script:publicationSession) | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
    $global:PublicationJournalFixture.Pushes | Should -Be 2
  }
  It 'keeps an ambiguous push outcome pending instead of claiming rollback or success' {
    $global:PublicationJournalFixture.FailPush = $true
    { Push-RepositoryFiles -RepositoryUrl 'https://dev.azure.com/org/project/_git/repo' -Branch main -BearerToken 'offline-token' -Files @(@{ Path = 'azure-pipelines.yml'; Content = 'reviewed' }) -ExpectedBranchObjectId ('a' * 40) -OwnershipSession $script:publicationSession -PublicationOwnership $script:publication } | Should -Throw '*unresolved*'
    $records = (Get-MaesterOwnershipJournal -Session $script:publicationSession).records
    $records.Count | Should -Be 1
    $records[0].state | Should -BeExactly pending
    $records[0].exactIds.Count | Should -Be 0
    $global:PublicationJournalFixture.Pushes | Should -Be 1
  }
  It 'leaves the ownership journal unchanged when reviewed source files need no publication' {
    $global:PublicationJournalFixture.Changed = $false
    $result = Push-RepositoryFiles -RepositoryUrl 'https://dev.azure.com/org/project/_git/repo' -Branch main -BearerToken 'offline-token' -Files @(@{ Path = 'azure-pipelines.yml'; Content = 'reviewed' }) -ExpectedBranchObjectId ('a' * 40) -OwnershipSession $script:publicationSession -PublicationOwnership $script:publication
    $result.Pushed | Should -BeFalse
    (Get-MaesterOwnershipJournal -Session $script:publicationSession).records.Count | Should -Be 0
    $global:PublicationJournalFixture.Pushes | Should -Be 0
  }
  It 'refuses an unreviewed commit when an approved empty repository was initialized before clone' {
    { Push-RepositoryFiles -RepositoryUrl 'https://dev.azure.com/org/project/_git/repo' -Branch main -BearerToken 'offline-token' -Files @(@{ Path = 'azure-pipelines.yml'; Content = 'reviewed' }) -ExpectedBranchObjectId '' -OwnershipSession $script:publicationSession -PublicationOwnership $script:publication } | Should -Throw '*expected to be empty*'
    (Get-MaesterOwnershipJournal -Session $script:publicationSession).records.Count | Should -Be 0
    $global:PublicationJournalFixture.Pushes | Should -Be 0
  }
  It 'publishes an approved empty repository only while its cloned HEAD remains unborn' {
    $global:PublicationJournalFixture.Empty = $true
    $result = Push-RepositoryFiles -RepositoryUrl 'https://dev.azure.com/org/project/_git/repo' -Branch main -BearerToken 'offline-token' -Files @(@{ Path = 'azure-pipelines.yml'; Content = 'reviewed' }) -ExpectedBranchObjectId '' -OwnershipSession $script:publicationSession -PublicationOwnership $script:publication
    $result.Pushed | Should -BeTrue
    $records = (Get-MaesterOwnershipJournal -Session $script:publicationSession).records
    $records[0].before.commitId | Should -BeNullOrEmpty
    $records[0].after.commitId | Should -BeExactly ('c' * 40)
  }
  It 'rejects remote ref changes at the push boundary and keeps the exact publication pending: <_>' -ForEach @('existing', 'absent') {
    $f = $global:PublicationJournalFixture
    if ($_ -eq 'absent') { $f.Empty = $true; $expected = '' } else { $expected = 'a' * 40 }
    $f.RemoteChangeBeforePush = 'b' * 40
    { Push-RepositoryFiles @publicationArguments -ExpectedBranchObjectId $expected } | Should -Throw '*unresolved*'
    $f.CurrentHead | Should -BeExactly ('b' * 40)
    $records = (Get-MaesterOwnershipJournal -Session $script:publicationSession).records
    $records.Count | Should -Be 1
    $records[0].state | Should -BeExactly pending
    $records[0].before.commitId | Should -BeExactly $expected
    $records[0].after.commitId | Should -BeExactly ('c' * 40)
    $records[0].exactIds.Count | Should -Be 0
  }

}
