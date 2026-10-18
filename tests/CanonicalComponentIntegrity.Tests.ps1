Describe 'Reviewed canonical component and permission evidence' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $lock = Get-Content (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
    $hooks = @($lock.components | Where-Object id -eq 'maester-azd-hooks')[0]
  }
  It 'pins the reviewed pilot revision and validates all eight vendored hashes' {
    $hooks.version | Should -Be '1.0.0'
    $hooks.sourceRepository | Should -Be 'https://github.com/nathanmcnulty/azd-reference'
    $hooks.sourceRevision | Should -Be 'fd26f7351f36c569067ae37edcb35d6b6cc40f29'
    $hooks.files.Count | Should -Be 8
    foreach ($file in $hooks.files) {
      (Get-FileHash -LiteralPath (Join-Path $root $file.target) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $file.sha256
    }
  }
  It 'keeps every permission evidence hash current' {
    $permissions = Get-Content (Join-Path $root 'azd-permissions.json') -Raw | ConvertFrom-Json
    foreach ($requirement in $permissions.requirements) {
      foreach ($evidence in $requirement.evidence) {
        (Get-FileHash -LiteralPath (Join-Path $root $evidence.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $evidence.sha256
      }
    }
  }
}
