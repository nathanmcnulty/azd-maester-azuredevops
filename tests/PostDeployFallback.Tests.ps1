BeforeAll {
  $setupPath = Join-Path $PSScriptRoot '../scripts/Setup-PostDeploy.ps1'
  $tokens = $null
  $parseErrors = $null
  $setupAst = [Management.Automation.Language.Parser]::ParseFile(
    $setupPath,
    [ref]$tokens,
    [ref]$parseErrors
  )
  $parseErrors | Should -BeNullOrEmpty

  foreach ($functionName in @('Push-RepositoryFiles', 'Remove-DirectoryQuiet')) {
    $definition = $setupAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
      }, $true) | Select-Object -First 1
    $definition | Should -Not -BeNullOrEmpty
    . ([scriptblock]::Create($definition.Extent.Text))
  }
}

Describe 'Azure DevOps repository staging path' {
  BeforeEach {
    $script:originalTemp = $env:TEMP
    $script:globalLastExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $script:hadGlobalLastExitCode = $null -ne $script:globalLastExitCode
    if ($script:hadGlobalLastExitCode) {
      $script:originalGlobalLastExitCode = $script:globalLastExitCode.Value
    }
    $script:cloneDestination = $null
    $script:failClone = $false
    $script:filterChangesBytes = $false
    $script:writtenBytes = $null
    Remove-Item Env:TEMP -ErrorAction SilentlyContinue

    function git {
      if ($args -contains 'clone') {
        $script:cloneDestination = [string]$args[-1]
        if ($script:failClone) {
          $global:LASTEXITCODE = 1
          return
        }
      }
      $global:LASTEXITCODE = 0
      if ($args -contains 'hash-object') { $script:writtenBytes = [IO.File]::ReadAllBytes([string]$args[-1]); return ('a' * 40) }
      if ($args -contains 'rev-parse') { if ($script:filterChangesBytes -and [string]$args[-1] -like ':*') { return ('b' * 40) }; return ('a' * 40) }
    }
  }

  AfterEach {
    if ($null -eq $script:originalTemp) {
      Remove-Item Env:TEMP -ErrorAction SilentlyContinue
    }
    else {
      $env:TEMP = $script:originalTemp
    }
    Remove-Item Function:\git -ErrorAction SilentlyContinue
    if ($script:hadGlobalLastExitCode) {
      $global:LASTEXITCODE = $script:originalGlobalLastExitCode
    }
    else {
      Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    }
  }

  It 'uses the platform temporary directory when TEMP is absent and cleans a no-change clone' {
    $result = Push-RepositoryFiles `
      -RepositoryUrl 'https://example.invalid/repository' `
      -Branch 'main' `
      -BearerToken 'fixture-token' `
      -Files @([pscustomobject]@{ Path = 'azure-pipelines.yml'; Content = 'fixture' })

    [Text.Encoding]::UTF8.GetString($script:writtenBytes) | Should -BeExactly 'fixture'
    $result.CommitId | Should -BeExactly ('a' * 40)
    $result.Pushed | Should -BeFalse
    $result.Changed | Should -BeFalse
    $script:cloneDestination | Should -Not -BeNullOrEmpty
    $script:cloneDestination | Should -BeLike "$([IO.Path]::GetTempPath())*"
    Test-Path -LiteralPath $script:cloneDestination | Should -BeFalse
  }

  It 'blocks publication when Git filters transform reviewed bytes' {
    $script:filterChangesBytes = $true
    { Push-RepositoryFiles -RepositoryUrl 'https://example.invalid/repository' -Branch main -BearerToken 'fixture-token' -Files @([pscustomobject]@{ Path = 'azure-pipelines.yml'; Content = "fixture`r`n" }) } | Should -Throw '*Git changed reviewed publication bytes*'
    [Text.Encoding]::UTF8.GetString($script:writtenBytes) | Should -BeExactly "fixture`r`n"
    Test-Path -LiteralPath $script:cloneDestination | Should -BeFalse
  }

  It 'preserves the clone failure and cleans its staging directory when TEMP is absent' {
    $script:failClone = $true

    {
      Push-RepositoryFiles `
        -RepositoryUrl 'https://example.invalid/repository' `
        -Branch 'main' `
        -BearerToken 'fixture-token' `
        -Files @([pscustomobject]@{ Path = 'azure-pipelines.yml'; Content = 'fixture' })
    } | Should -Throw "git clone failed for 'https://example.invalid/repository'."

    $script:cloneDestination | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $script:cloneDestination | Should -BeFalse
  }
}
