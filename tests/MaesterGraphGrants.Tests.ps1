BeforeDiscovery {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  $grantTargets = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter 'Grant-MaesterGraphPermissions.ps1' | ForEach-Object {
    @{ hooksRoot = $_.Directory.FullName; targetName = [IO.Path]::GetRelativePath($repoRoot, $_.FullName) }
  })
}

Describe 'Tenant-bound Maester Graph permission grants: <targetName>' -ForEach $grantTargets {
  BeforeAll {
    Import-Module (Join-Path $hooksRoot 'Maester-SetupHelpers.psm1') -Force
    Import-Module (Join-Path $hooksRoot 'Maester-ConsentPlan.psm1') -Force
    InModuleScope Maester-SetupHelpers {
    function script:Invoke-TestMaesterGraphGrant {
      param($TenantId, $PrincipalObjectId, $AppRoleValues, $PermissionProfile, $IncludeMailSend, $IncludeReportSettingsWrite)
      $plan = & $global:MaesterGrantTestPath @PSBoundParameters
      & $global:MaesterGrantTestPath @PSBoundParameters -Apply -ApprovedPlanHash $plan.planHash
    }
    }
    $global:MaesterGrantTestPath = Join-Path $hooksRoot 'Grant-MaesterGraphPermissions.ps1'
  }

  AfterAll {
    Remove-Module Maester-SetupHelpers, Maester-ConsentPlan -Force -ErrorAction SilentlyContinue
    Remove-Variable MaesterGrantTestPath, MaesterGrantTestState -Scope Global -ErrorAction SilentlyContinue
  }

  BeforeEach {
    $global:MaesterGrantTestState = @{}
    InModuleScope Maester-SetupHelpers {
      $global:MaesterGrantTestState.Tenant = '11111111-1111-4111-8111-111111111111'
      $global:MaesterGrantTestState.Principal = '22222222-2222-4222-8222-222222222222'
      $global:MaesterGrantTestState.Resource = '33333333-3333-4333-8333-333333333333'
      $global:MaesterGrantTestState.Requests = [Collections.Generic.List[object]]::new()
      $global:MaesterGrantTestState.TokenTenants = [Collections.Generic.List[string]]::new()
      $global:MaesterGrantTestState.Assignments = [Collections.Generic.List[object]]::new()
      $global:MaesterGrantTestState.LaterAssignments = @()
      $global:MaesterGrantTestState.NextLink = $null
      $global:MaesterGrantTestState.ListReads = 0
      $global:MaesterGrantTestState.ReadbackVisible = $true
      $global:MaesterGrantTestState.PrincipalType = 'ManagedIdentity'
      $global:MaesterGrantTestState.GraphCount = 1
      $global:MaesterGrantTestState.GraphAppId = '00000003-0000-0000-c000-000000000000'
      $global:MaesterGrantTestState.MalformedPage = $false
      $global:MaesterGrantTestState.PageFailure = $false
      $global:MaesterGrantTestState.EndlessPages = $false
      $global:MaesterGrantTestState.RoleNames = @(
        'Directory.Read.All', 'DirectoryRecommendations.Read.All', 'IdentityRiskEvent.Read.All',
        'Policy.Read.All', 'Policy.Read.ConditionalAccess', 'RoleManagement.Read.All',
        'Reports.Read.All', 'UserAuthenticationMethod.Read.All',
        'DeviceManagementConfiguration.Read.All', 'DeviceManagementServiceConfig.Read.All',
        'DeviceManagementManagedDevices.Read.All', 'DeviceManagementRBAC.Read.All',
        'PrivilegedAccess.Read.AzureAD', 'ReportSettings.Read.All', 'RoleEligibilitySchedule.Read.Directory',
        'SecurityIdentitiesHealth.Read.All', 'SecurityIdentitiesSensors.Read.All',
        'SharePointTenantSettings.Read.All', 'ThreatHunting.Read.All', 'Mail.Send'
      )
      $manifest = Get-Content (Join-Path (Split-Path $global:MaesterGrantTestPath -Parent) 'Maester-GraphPermissions.json') -Raw | ConvertFrom-Json -AsHashtable
      $global:MaesterGrantTestState.RoleIds = @{}
      foreach ($name in $manifest.applicationRoles.Keys) { $global:MaesterGrantTestState.RoleIds[$name] = $manifest.applicationRoles[$name].applicationRoleId }
      $global:MaesterGrantTestState.RoleNames += @($manifest.applicationRoles.Keys | Where-Object { $_ -notin $global:MaesterGrantTestState.RoleNames })
      $global:MaesterGrantTestState.Roles = @($global:MaesterGrantTestState.RoleNames | ForEach-Object {
        [pscustomobject]@{ id = $global:MaesterGrantTestState.RoleIds[$_]; value = $_; isEnabled = $true; allowedMemberTypes = @('Application') }
      })
      # Keep the real helper and REST/token forwarding path loaded while the script imports it.
      Mock Import-Module {} -ParameterFilter { $Name -like '*Maester-SetupHelpers.psm1' -or $Name -like '*Maester-ConsentPlan.psm1' }
      Mock Assert-GraphAccess {}
      Mock Test-MaesterGraphSession { $true }
      Mock Start-Sleep {}
      Mock Write-Host {}
      Mock Invoke-GraphRestRequest {
        param($Method, $Uri, $TenantId, $Body)
        $global:MaesterGrantTestState.Requests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body; Authorization = $TenantId })
        if ($TenantId -ne $global:MaesterGrantTestState.Tenant) { throw 'Request used the ambient tenant.' }
        $global:MaesterGrantTestState.TokenTenants.Add([string]$TenantId)
        if ($Uri -match '/servicePrincipals/[0-9a-f-]+\?') { return [pscustomobject]@{ id = $global:MaesterGrantTestState.Principal; appId = '44444444-4444-4444-8444-444444444444'; servicePrincipalType = $global:MaesterGrantTestState.PrincipalType } }
        if ($Uri -like '*/organization?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = $global:MaesterGrantTestState.Tenant }) } }
        if (([string]$Uri).StartsWith('https://graph.microsoft.com/v1.0/servicePrincipals?')) {
          return [pscustomobject]@{ value = @(for ($i = 0; $i -lt $global:MaesterGrantTestState.GraphCount; $i++) {
            [pscustomobject]@{ id = $global:MaesterGrantTestState.Resource; appId = $global:MaesterGrantTestState.GraphAppId; appRoles = $global:MaesterGrantTestState.Roles }
          }) }
        }
        if ($Method -eq 'POST') {
          $assignment = $Body | ConvertFrom-Json
          if ($global:MaesterGrantTestState.ReadbackVisible) { $global:MaesterGrantTestState.Assignments.Add($assignment) }
          return $assignment
        }
        $global:MaesterGrantTestState.ListReads++
        if ($global:MaesterGrantTestState.MalformedPage) { return [pscustomobject]@{ unexpected = @() } }
        if ($Uri -like '*skiptoken*') {
          if ($global:MaesterGrantTestState.PageFailure) { throw 'Synthetic page two failure.' }
          if ($global:MaesterGrantTestState.EndlessPages) {
            return [pscustomobject]@{ value = @(); '@odata.nextLink' = "https://graph.microsoft.com/v1.0/servicePrincipals/$($global:MaesterGrantTestState.Principal)/appRoleAssignments?`$skiptoken=$($global:MaesterGrantTestState.ListReads)" }
          }
          return [pscustomobject]@{ value = $global:MaesterGrantTestState.LaterAssignments; '@odata.nextLink' = $global:MaesterGrantTestState.NextLink }
        }
        $page = [pscustomobject]@{ value = @($global:MaesterGrantTestState.Assignments.ToArray()) }
        if ($global:MaesterGrantTestState.NextLink) { $page | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue $global:MaesterGrantTestState.NextLink }
        return $page
      }
    }
  }

  It 'preserves the original positional profile argument and managed-identity default' {
    InModuleScope Maester-SetupHelpers {
      $plan = & $global:MaesterGrantTestPath $global:MaesterGrantTestState.Tenant $global:MaesterGrantTestState.Principal 'Minimal'
      $plan.details.profile | Should -BeExactly 'Minimal'
      $plan.details.targetProvenance.targetType | Should -BeExactly 'ManagedIdentity'
      $plan.desired.Count | Should -Be 8
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'preserves original positional role and optional capability arguments' {
    InModuleScope Maester-SetupHelpers {
      $roles = @('Directory.Read.All', 'Mail.Send', 'ReportSettings.ReadWrite.All')
      $plan = & $global:MaesterGrantTestPath $global:MaesterGrantTestState.Tenant $global:MaesterGrantTestState.Principal 'Minimal' $roles $true $true
      $plan.details.profile | Should -BeExactly 'Minimal'
      $plan.details.includeMailSend | Should -BeTrue
      $plan.details.includeReportSettingsWrite | Should -BeTrue
      $plan.desired.Count | Should -Be 3
      $plan.details.targetProvenance.targetType | Should -BeExactly 'ManagedIdentity'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'binds principal lookup, plan inventory, apply and readback to the selected tenant' {
    InModuleScope Maester-SetupHelpers {
      Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All'
      @($global:MaesterGrantTestState.TokenTenants | Where-Object { $_ -ne $global:MaesterGrantTestState.Tenant }).Count | Should -Be 0
      $global:MaesterGrantTestState.TokenTenants.Count | Should -Be 8
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 1
      $global:MaesterGrantTestState.ListReads | Should -Be 3
      $body = ($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Body | ConvertFrom-Json
      $body.principalId | Should -Be $global:MaesterGrantTestState.Principal
      $body.resourceId | Should -Be $global:MaesterGrantTestState.Resource
      $body.appRoleId | Should -Be $global:MaesterGrantTestState.RoleIds['Directory.Read.All']
    }
  }

  It 'finds an exact grant on a later page without posting a duplicate' {
    InModuleScope Maester-SetupHelpers {
      $global:MaesterGrantTestState.NextLink = "https://graph.microsoft.com/v1.0/servicePrincipals/$($global:MaesterGrantTestState.Principal)/appRoleAssignments?`$skiptoken=page2"
      $global:MaesterGrantTestState.LaterAssignments = @([pscustomobject]@{ principalId = $global:MaesterGrantTestState.Principal; resourceId = $global:MaesterGrantTestState.Resource; appRoleId = $global:MaesterGrantTestState.RoleIds['Directory.Read.All'] })
      Mock Invoke-GraphRestRequest {
        param($Method, $Uri, $TenantId)
        $global:MaesterGrantTestState.Requests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Authorization = $TenantId })
        if ($TenantId -ne $global:MaesterGrantTestState.Tenant) { throw 'Request used the ambient tenant.' }
        $global:MaesterGrantTestState.TokenTenants.Add([string]$TenantId)
        if ($Uri -match '/servicePrincipals/[0-9a-f-]+\?') { return [pscustomobject]@{ id = $global:MaesterGrantTestState.Principal; appId = '44444444-4444-4444-8444-444444444444'; servicePrincipalType = $global:MaesterGrantTestState.PrincipalType } }
        if ($Uri -like '*/organization?*') { return [pscustomobject]@{ value = @() } }
        if (([string]$Uri).StartsWith('https://graph.microsoft.com/v1.0/servicePrincipals?')) { return [pscustomobject]@{ value = @([pscustomobject]@{ id = $global:MaesterGrantTestState.Resource; appId = $global:MaesterGrantTestState.GraphAppId; appRoles = $global:MaesterGrantTestState.Roles }) } }
        if ($Uri -like '*skiptoken*') { return [pscustomobject]@{ value = $global:MaesterGrantTestState.LaterAssignments } }
        return [pscustomobject]@{ value = @(); '@odata.nextLink' = $global:MaesterGrantTestState.NextLink }
      }
      Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
      $global:MaesterGrantTestState.TokenTenants.Count | Should -Be 8
      @($global:MaesterGrantTestState.TokenTenants | Where-Object { $_ -ne $global:MaesterGrantTestState.Tenant }).Count | Should -Be 0
    }
  }

  It 'rejects unsafe continuation <link> before any POST' -TestCases @(
    @{ link = 'https://other.example/v1.0/servicePrincipals/22222222-2222-4222-8222-222222222222/appRoleAssignments' }
    @{ link = 'http://graph.microsoft.com/v1.0/servicePrincipals/22222222-2222-4222-8222-222222222222/appRoleAssignments' }
    @{ link = 'https://graph.microsoft.com:444/v1.0/servicePrincipals/22222222-2222-4222-8222-222222222222/appRoleAssignments' }
    @{ link = 'https://user@graph.microsoft.com/v1.0/servicePrincipals/22222222-2222-4222-8222-222222222222/appRoleAssignments' }
    @{ link = 'https://graph.microsoft.com/v1.0/servicePrincipals/other/appRoleAssignments' }
    @{ link = '/v1.0/servicePrincipals/22222222-2222-4222-8222-222222222222/appRoleAssignments' }
  ) {
    param($link)
    InModuleScope Maester-SetupHelpers -Parameters @{ link = $link } {
      $global:MaesterGrantTestState.NextLink = $link
      { Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All' } | Should -Throw '*expected secure collection*'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
      $global:MaesterGrantTestState.Requests.Count | Should -Be 3
    }
  }

  It 'fails closed for repeated pages, page limits, incomplete responses and page failures' -TestCases @(
    @{ mode = 'loop'; expected = '*repeated a page*' }
    @{ mode = 'limit'; expected = '*exceeded its limit*' }
    @{ mode = 'malformed'; expected = '*missing its value collection*' }
    @{ mode = 'failure'; expected = '*Synthetic page two failure*' }
  ) {
    param($mode, $expected)
    InModuleScope Maester-SetupHelpers -Parameters @{ mode = $mode; expected = $expected } {
      $global:MaesterGrantTestState.NextLink = "https://graph.microsoft.com/v1.0/servicePrincipals/$($global:MaesterGrantTestState.Principal)/appRoleAssignments?`$skiptoken=page2"
      $global:MaesterGrantTestState.EndlessPages = $mode -eq 'limit'
      $global:MaesterGrantTestState.MalformedPage = $mode -eq 'malformed'
      $global:MaesterGrantTestState.PageFailure = $mode -eq 'failure'
      { Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All' } | Should -Throw $expected
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
      $global:MaesterGrantTestState.ListReads | Should -BeLessOrEqual 100
    }
  }

  It 'preserves <profile> permissions with IncludeMailSend=<mail>' -TestCases @(
    @{ profile = 'Minimal'; mail = $false; count = 8 }
    @{ profile = 'Minimal'; mail = $true; count = 9 }
    @{ profile = 'Extended'; mail = $false; count = 19 }
    @{ profile = 'Extended'; mail = $true; count = 20 }
  ) {
    param($profile, $mail, $count)
    InModuleScope Maester-SetupHelpers -Parameters @{ profile = $profile; mail = $mail; count = $count } {
      Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -PermissionProfile $profile -IncludeMailSend $mail
      $actual = @($global:MaesterGrantTestState.Assignments | ForEach-Object appRoleId | Sort-Object)
      $expected = @($global:MaesterGrantTestState.RoleNames[0..$(if ($profile -eq 'Minimal') { 7 } else { 18 })])
      if ($mail) { $expected += 'Mail.Send' }
      $actual.Count | Should -Be $count
      ($actual -join ',') | Should -Be (($expected | ForEach-Object { $global:MaesterGrantTestState.RoleIds[$_] } | Sort-Object) -join ',')
    }
  }

  It 'preserves explicit role selection and deduplicates requested values' {
    InModuleScope Maester-SetupHelpers {
      Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -PermissionProfile Extended -AppRoleValues 'Reports.Read.All','Reports.Read.All' -IncludeMailSend $true
      $global:MaesterGrantTestState.Assignments.Count | Should -Be 1
      $global:MaesterGrantTestState.Assignments[0].appRoleId | Should -Be $global:MaesterGrantTestState.RoleIds['Reports.Read.All']
    }
  }

  It 'validates all requested roles before posting and rejects disabled roles' -TestCases @(
    @{ disabled = $false }
    @{ disabled = $true }
  ) {
    param($disabled)
    InModuleScope Maester-SetupHelpers -Parameters @{ disabled = $disabled } {
      if ($disabled) { $global:MaesterGrantTestState.Roles[0].isEnabled = $false }
      $roles = if ($disabled) { @('Directory.Read.All') } else { @('Directory.Read.All', 'Unknown.Role') }
      { Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues $roles } | Should -Throw '*role*'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'does not mistake another principal or resource for the requested grant' {
    InModuleScope Maester-SetupHelpers {
      $global:MaesterGrantTestState.Assignments.Add([pscustomobject]@{ principalId = 'other'; resourceId = $global:MaesterGrantTestState.Resource; appRoleId = $global:MaesterGrantTestState.RoleIds['Directory.Read.All'] })
      $global:MaesterGrantTestState.Assignments.Add([pscustomobject]@{ principalId = $global:MaesterGrantTestState.Principal; resourceId = 'other'; appRoleId = $global:MaesterGrantTestState.RoleIds['Directory.Read.All'] })
      Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 1
    }
  }

  It 'fails rather than announcing success when exact readback never appears' {
    InModuleScope Maester-SetupHelpers {
      $global:MaesterGrantTestState.ReadbackVisible = $false
      { Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All' } | Should -Throw '*could not be verified*'
      $global:MaesterGrantTestState.ListReads | Should -Be 5
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 1
      Should -Invoke Start-Sleep -Times 2 -Exactly
      Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -eq 'Graph app role assignment completed and verified.' }
    }
  }

  It 'requires a unique Graph service principal before granting' -TestCases @(@{ count = 0 }, @{ count = 2 }) {
    param($count)
    InModuleScope Maester-SetupHelpers -Parameters @{ count = $count } {
      $global:MaesterGrantTestState.GraphCount = $count
      { Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All' } | Should -Throw '*Exactly one Microsoft Graph*'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }
  It 'rejects a different resource service principal even when the filtered result has one row' {
    InModuleScope Maester-SetupHelpers {
      $global:MaesterGrantTestState.GraphAppId = 'different-application'
      { Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All' } | Should -Throw '*not Microsoft Graph*'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'preserves partial existing grants and reruns without adding duplicates' {
    InModuleScope Maester-SetupHelpers {
      $global:MaesterGrantTestState.Assignments.Add([pscustomobject]@{ principalId = $global:MaesterGrantTestState.Principal; resourceId = $global:MaesterGrantTestState.Resource; appRoleId = $global:MaesterGrantTestState.RoleIds['Directory.Read.All'] })
      Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All','Reports.Read.All'
      Invoke-TestMaesterGraphGrant -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -AppRoleValues 'Directory.Read.All','Reports.Read.All'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 1
      $global:MaesterGrantTestState.Assignments.Count | Should -Be 2
    }
  }

  It 'returns a complete versioned Full plan by default without writes or mail' {
    InModuleScope Maester-SetupHelpers {
      $plan = & $global:MaesterGrantTestPath -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal
      $plan.schemaVersion | Should -Be '1.0'
      $plan.details.maesterVersion | Should -Be '2.3.0'
      $plan.details.consequences['Sites.Read.All'] | Should -Match 'documents and list items across all site collections'
      $plan.desired.Count | Should -Be 27
      $plan.missing.Count | Should -Be 27
      $plan.desired -join ',' | Should -Not -Match 'Mail.Send|ReportSettings.ReadWrite.All|AppRoleAssignment.ReadWrite.All'
      $plan.planHash | Should -Match '^[a-f0-9]{64}$'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'requires explicit current-plan approval before the first mutation' -ForEach @(@{ approved = '' }, @{ approved = ('a' * 64) }) {
    InModuleScope Maester-SetupHelpers -Parameters @{ approved = $approved } {
      { & $global:MaesterGrantTestPath -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -Apply -ApprovedPlanHash $approved } | Should -Throw '*requires approval*'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects stale approval after the desired capability or observed delta changes' {
    InModuleScope Maester-SetupHelpers {
      $grantParams = @{ TenantId = $global:MaesterGrantTestState.Tenant; PrincipalObjectId = $global:MaesterGrantTestState.Principal; PermissionProfile = 'Minimal' }
      $plan = & $global:MaesterGrantTestPath @grantParams
      { & $global:MaesterGrantTestPath @grantParams -IncludeMailSend $true -Apply -ApprovedPlanHash $plan.planHash } | Should -Throw '*requires approval*'
      $global:MaesterGrantTestState.Assignments.Add([pscustomobject]@{ principalId = $grantParams.PrincipalObjectId; resourceId = $global:MaesterGrantTestState.Resource; appRoleId = $global:MaesterGrantTestState.RoleIds['Directory.Read.All'] })
      { & $global:MaesterGrantTestPath @grantParams -Apply -ApprovedPlanHash $plan.planHash } | Should -Throw '*requires approval*'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'keeps both optional write capabilities separately selected in the plan' {
    InModuleScope Maester-SetupHelpers {
      $grantParams = @{ TenantId = $global:MaesterGrantTestState.Tenant; PrincipalObjectId = $global:MaesterGrantTestState.Principal; PermissionProfile = 'Minimal' }
      $mail = & $global:MaesterGrantTestPath @grantParams -IncludeMailSend $true
      $mail.desired -join ',' | Should -Match 'Mail.Send'
      $mail.desired -join ',' | Should -Not -Match 'ReportSettings.ReadWrite.All'
      $settings = & $global:MaesterGrantTestPath @grantParams -IncludeReportSettingsWrite $true
      $settings.desired -join ',' | Should -Match 'ReportSettings.ReadWrite.All'
      $settings.details.consequences['ReportSettings.ReadWrite.All'] | Should -Match 'Restoration can fail'
      $mail.details.consequences['Mail.Send'] | Should -Match 'Sends mail as a user'
      $settings.desired -join ',' | Should -Not -Match 'Mail.Send'
      { & $global:MaesterGrantTestPath @grantParams -AppRoleValues 'Mail.Send' } | Should -Throw '*separate IncludeMailSend*'
      { & $global:MaesterGrantTestPath @grantParams -AppRoleValues 'ReportSettings.ReadWrite.All' } | Should -Throw '*separate IncludeReportSettingsWrite*'
    }
  }

  It 'rejects non-managed runtime identities and permission-managing roles before writes' {
    InModuleScope Maester-SetupHelpers {
      $grantParams = @{ TenantId = $global:MaesterGrantTestState.Tenant; PrincipalObjectId = $global:MaesterGrantTestState.Principal }
      $global:MaesterGrantTestState.PrincipalType = 'Application'
      { & $global:MaesterGrantTestPath @grantParams } | Should -Throw '*managed identity*'
      { & $global:MaesterGrantTestPath @grantParams -AppRoleValues 'AppRoleAssignment.ReadWrite.All' } | Should -Throw '*write-capable or permission-managing*'
      { & $global:MaesterGrantTestPath @grantParams -AppRoleValues 'DelegatedPermissionGrant.ReadWrite.All' } | Should -Throw '*write-capable or permission-managing*'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects an application-role ID that differs from the reviewed manifest' {
    InModuleScope Maester-SetupHelpers {
      $global:MaesterGrantTestState.Roles[0].id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      { & $global:MaesterGrantTestPath -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -PermissionProfile Minimal } | Should -Throw '*reviewed manifest identifier*'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'discloses preserved optional permissions even when their desired capabilities are disabled' {
    InModuleScope Maester-SetupHelpers {
      foreach ($name in @('Mail.Send', 'ReportSettings.ReadWrite.All', 'Sites.Read.All')) {
        $global:MaesterGrantTestState.Assignments.Add([pscustomobject]@{ principalId = $global:MaesterGrantTestState.Principal; resourceId = $global:MaesterGrantTestState.Resource; appRoleId = $global:MaesterGrantTestState.RoleIds[$name] })
      }
      $plan = & $global:MaesterGrantTestPath -TenantId $global:MaesterGrantTestState.Tenant -PrincipalObjectId $global:MaesterGrantTestState.Principal -PermissionProfile Minimal
      @($plan.details.preservedExistingOptionalCapabilities) | Should -Be @('Mail.Send', 'ReportSettings.ReadWrite.All', 'Sites.Read.All')
      $plan.details.preservedExistingGraphRoles.Count | Should -Be 3
      $plan.details.consequences['ReportSettings.ReadWrite.All'] | Should -Match 'Restoration can fail'
      $plan.details.consequences['Sites.Read.All'] | Should -Match 'documents and list items'
      $plan.details.consequences['Mail.Send'] | Should -Match 'Sends mail as a user'
      $plan.details.existingAccessNotice | Should -Match 'does not configure or trigger report delivery'
      $plan.desired -join ',' | Should -Not -Match 'Mail.Send|ReportSettings.ReadWrite.All|Sites.Read.All'
      @($global:MaesterGrantTestState.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

}
