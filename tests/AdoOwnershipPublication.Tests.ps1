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
    if ('clone' -in $args -or 'checkout' -in $args -or 'add' -in $args -or 'commit' -in $args) { return }
    if ('hash-object' -in $args) { return ('b' * 40) }
    if ('rev-parse' -in $args) {
      if ($args[-1] -like ':*') { return ('b' * 40) }
      if ('--verify' -in $args -and $f.Empty -and -not $f.Committed) { $global:LASTEXITCODE = 1; return }
      return $(if ($f.Committed) { 'c' * 40 } else { 'a' * 40 })
    }
    if ('status' -in $args) { if ($f.Changed) { $f.Committed = $true; return ' M azure-pipelines.yml' }; return }
    if ('push' -in $args) {
      $f.Pushes++
      $records = (Get-MaesterOwnershipJournal -Session $f.Session).records
      $publication = @($records | Where-Object kind -eq AdoRepositoryPublication)
      if ($publication.Count -ne 1 -or $publication[0].state -cne 'pending') { throw 'Publication reached Git before its pending checkpoint.' }
      if ($f.FailPush) { $global:LASTEXITCODE = 1 }
      return
    }
    throw "Unexpected offline git invocation: $($args -join ' ')"
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
    $global:PublicationJournalFixture = @{ Session = $script:publicationSession; Changed = $true; Committed = $false; Empty = $false; FailPush = $false; Pushes = 0 }
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
}
