Describe 'Maintained PowerShell baseline' {
  It 'enforces PowerShell 7.6 on every owned script and module before execution' {
    $scripts = Get-ChildItem (Join-Path $PSScriptRoot '../scripts') -File |
      Where-Object Extension -In '.ps1', '.psm1'
    $scripts.Count | Should -Be 15
    foreach ($file in $scripts) {
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
      $errors | Should -BeNullOrEmpty
      $ast.ScriptRequirements.RequiredPSVersion | Should -Be ([version]'7.6') -Because $file.Name
    }
  }

  It 'checks the generated pipeline agent before the Azure authentication task' {
    $template = Get-Content (Join-Path $PSScriptRoot '../pipelines/template-maester.yml') -Raw
    $preflight = $template.IndexOf('  - task: PowerShell@2')
    $authentication = $template.IndexOf('  - task: AzureCLI@2')
    $preflight | Should -BeGreaterOrEqual 0
    $authentication | Should -BeGreaterThan $preflight
    $step = $template.Substring($preflight, $authentication - $preflight)
    $step | Should -Match 'pwsh: true'
    $step | Should -Match '\$PSVersionTable.PSVersion -lt \[version\]''7\.6'''
    $step | Should -Match "throw 'PowerShell 7\.6 or newer is required"
    $step | Should -Not -Match 'continueOnError: true|condition:'
  }
}
