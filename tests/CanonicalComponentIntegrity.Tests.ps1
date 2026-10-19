Describe 'Reviewed canonical component and permission evidence' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $lock = Get-Content (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
    $hooks = @($lock.components | Where-Object id -eq 'maester-azd-hooks')[0]
  }
  It 'pins the reviewed consent components and validates every vendored hash' {
    $hooks.version | Should -Be '2.1.0'
    $hooks.sourceRepository | Should -Be 'https://github.com/nathanmcnulty/azd-reference'
    $hooks.sourceRevision | Should -Be '552ade2f0267e6872bd681f9a1d8a67ac72d055b'
    $hooks.files.Count | Should -Be 10
    $coordinator = @($lock.components | Where-Object id -eq 'graph-delegated-authentication')[0]
    $coordinator.version | Should -Be '1.1.0'
    $coordinator.sourceRevision | Should -Be '552ade2f0267e6872bd681f9a1d8a67ac72d055b'
    foreach ($file in @($lock.components | ForEach-Object files)) {
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

Describe 'Maester 2.3 permission evidence semantics' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $evidence = Get-Content (Join-Path $root 'azd-permissions.json') -Raw | ConvertFrom-Json
    $manifest = Get-Content (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Maester-GraphPermissions.json') -Raw | ConvertFrom-Json
  }
  It 'preserves the exact reviewed Full27 Minimal8 and legacy Extended19 contracts' {
    $manifest.maesterVersion | Should -BeExactly '2.3.0'
    $manifest.profiles.Full.Count | Should -Be 27
    $manifest.profiles.Minimal.Count | Should -Be 8
    $manifest.profiles.Extended.Count | Should -Be 19
    $declared = @($evidence.requirements | Where-Object { $_.phase -eq 'runtime' -and $_.kind -eq 'application' } | ForEach-Object permission)
    foreach ($name in @($manifest.profiles.Full + $manifest.profiles.Minimal + $manifest.profiles.Extended + @('Mail.Send','ReportSettings.ReadWrite.All') | Sort-Object -Unique)) { $declared | Should -Contain $name }
  }
  It 'never declares runtime permission management or delegated full-user access' {
    $evidence.requirements.permission | Should -Not -Contain 'Directory.AccessAsUser.All'
    @($evidence.requirements | Where-Object { $_.phase -eq 'runtime' -and $_.permission -match 'AppRoleAssignment.ReadWrite|Application.ReadWrite|RoleManagement.ReadWrite|DelegatedPermissionGrant.ReadWrite' }).Count | Should -Be 0
    foreach ($name in @('Mail.Send','ReportSettings.ReadWrite.All')) {
      @($evidence.requirements | Where-Object permission -eq $name)[0].defaultEnabled | Should -BeFalse
    }
  }
  It 'declares optional runtime bootstrap write scope as setup-only authority' {
    $scope = @($evidence.requirements | Where-Object { $_.permission -eq 'Application.ReadWrite.All' -and $_.phase -eq 'deployment' })
    $scope.Count | Should -Be 1
    $scope[0].feature | Should -BeExactly 'runtime-bootstrap-or-easyauth'
    $scope[0].defaultEnabled | Should -BeFalse
    $scope[0].rationale | Should -Match 'complete selected setup scope union'
  }
}
