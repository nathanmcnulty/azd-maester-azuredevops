BeforeDiscovery {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  $grantTargets = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter 'Grant-MaesterGraphPermissions.ps1' | ForEach-Object {
    @{ hooksRoot = $_.Directory.FullName; targetName = [IO.Path]::GetRelativePath($repoRoot, $_.FullName) }
  })
}

Describe 'Explicit federated Maester Graph grant targets (offline): <targetName>' -ForEach $grantTargets {
  BeforeAll {
    $savedSetupClientId = [Environment]::GetEnvironmentVariable('MAESTER_SETUP_CLIENT_ID')
    Import-Module (Join-Path $hooksRoot 'Maester-SetupHelpers.psm1') -Force
    Import-Module (Join-Path $hooksRoot 'Maester-ConsentPlan.psm1') -Force
    $global:MaesterFederatedGrantPath = Join-Path $hooksRoot 'Grant-MaesterGraphPermissions.ps1'
  }

  AfterAll {
    [Environment]::SetEnvironmentVariable('MAESTER_SETUP_CLIENT_ID', $savedSetupClientId)
    Remove-Module Maester-SetupHelpers, Maester-ConsentPlan -Force -ErrorAction SilentlyContinue
    Remove-Variable MaesterFederatedGrantPath, MaesterFederatedGrantState -Scope Global -ErrorAction SilentlyContinue
  }

  BeforeEach {
    $env:MAESTER_SETUP_CLIENT_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    InModuleScope Maester-SetupHelpers {
      $tenant = '11111111-1111-4111-8111-111111111111'
      $principal = '22222222-2222-4222-8222-222222222222'
      $applicationId = '44444444-4444-4444-8444-444444444444'
      $applicationObjectId = '55555555-5555-4555-8555-555555555555'
      $issuer = 'https://token.actions.githubusercontent.com'
      $subject = 'repo:example/maester:environment:production'
      $manifest = Get-Content (Join-Path (Split-Path $global:MaesterFederatedGrantPath -Parent) 'Maester-GraphPermissions.json') -Raw | ConvertFrom-Json -AsHashtable
      $global:MaesterFederatedGrantState = @{
        Tenant = $tenant
        Principal = $principal
        Resource = '33333333-3333-4333-8333-333333333333'
        ApplicationId = $applicationId
        ApplicationObjectId = $applicationObjectId
        SetupClientId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        Params = @{
          TenantId = $tenant; PrincipalObjectId = $principal; TargetType = 'FederatedApplication'
          ExpectedApplicationId = $applicationId; ExpectedApplicationObjectId = $applicationObjectId
          ExpectedFederatedCredentialIssuer = $issuer; ExpectedFederatedCredentialSubject = $subject
          AppRoleValues = @('Directory.Read.All')
        }
        ServicePrincipal = [pscustomobject]@{
          id = $principal; appId = $applicationId; servicePrincipalType = 'Application'; appOwnerOrganizationId = $tenant
          keyCredentials = @(); passwordCredentials = @()
        }
        Application = [pscustomobject]@{
          id = $applicationObjectId; appId = $applicationId; signInAudience = 'AzureADMyOrg'
          keyCredentials = @(); passwordCredentials = @()
        }
        FederatedCredentials = @([pscustomobject]@{
          id = '66666666-6666-4666-8666-666666666666'; name = 'production'
          issuer = $issuer; subject = $subject; audiences = @('api://AzureADTokenExchange')
        })
        LaterFederatedCredentials = @()
        FederatedNextLink = $null
        LaterNextLink = $null
        FederatedPageMode = 'valid'
        FederatedReads = 0
        Assignments = [Collections.Generic.List[object]]::new()
        Requests = [Collections.Generic.List[object]]::new()
        RoleId = $manifest.applicationRoles['Directory.Read.All'].applicationRoleId
      }
      # The real command and approval hash run, but every external boundary is a
      # strict double. Unexpected authentication or endpoints must fail the test.
      Mock Import-Module {} -ParameterFilter { $Name -like '*Maester-SetupHelpers.psm1' -or $Name -like '*Maester-ConsentPlan.psm1' }
      Mock Assert-GraphAccess { throw 'Unexpected authentication in an offline test.' }
      Mock Test-MaesterGraphSession { $true }
      Mock Get-MaesterGraphSetupClientId {
        param($TenantId)
        if ($TenantId -cne $global:MaesterFederatedGrantState.Tenant) { throw 'Setup-session lookup used an unselected tenant.' }
        return $global:MaesterFederatedGrantState.SetupClientId
      }
      Mock Start-Sleep {}
      Mock Write-Host {}
      Mock Invoke-GraphRestRequest {
        param($Method, $Uri, $TenantId, $Body)
        $state = $global:MaesterFederatedGrantState
        $state.Requests.Add([pscustomobject]@{ Method = $Method; Uri = [string]$Uri; TenantId = $TenantId; Body = $Body })
        if ($TenantId -cne $state.Tenant) { throw 'Request used an unselected tenant.' }
        $path = ([uri]$Uri).AbsolutePath
        if ($Method -eq 'GET' -and $path -ceq "/v1.0/servicePrincipals/$($state.Principal)") { return $state.ServicePrincipal }
        if ($Method -eq 'GET' -and $path -ceq "/v1.0/applications/$($state.ApplicationObjectId)") { return $state.Application }
        if ($Method -eq 'GET' -and $path -ceq "/v1.0/applications/$($state.ApplicationObjectId)/federatedIdentityCredentials") {
          $state.FederatedReads++
          if ($state.FederatedPageMode -eq 'missing-value') { return [pscustomobject]@{ unexpected = @() } }
          if ($state.FederatedPageMode -eq 'null-value') { return [pscustomobject]@{ value = $null } }
          if ($state.FederatedPageMode -eq 'object-value') { return [pscustomobject]@{ value = $state.FederatedCredentials[0] } }
          if ($state.FederatedPageMode -eq 'string-value') { return [pscustomobject]@{ value = 'not-a-collection' } }
          if ($state.FederatedPageMode -eq 'endless') {
            return [pscustomobject]@{ value = @(); '@odata.nextLink' = "https://graph.microsoft.com$path`?`$skiptoken=$($state.FederatedReads)" }
          }
          if ([string]$Uri -like '*skiptoken*') {
            if ($state.FederatedPageMode -eq 'failure') { throw 'Synthetic federated credential page failure.' }
            $page = [pscustomobject]@{ value = $state.LaterFederatedCredentials }
            if ($null -ne $state.LaterNextLink) { $page | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue $state.LaterNextLink }
            return $page
          }
          $page = [pscustomobject]@{ value = $state.FederatedCredentials }
          if ($null -ne $state.FederatedNextLink) { $page | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue $state.FederatedNextLink }
          return $page
        }
        if ($Method -eq 'GET' -and $path -ceq '/v1.0/servicePrincipals') {
          return [pscustomobject]@{ value = @([pscustomobject]@{
            id = $state.Resource; appId = '00000003-0000-0000-c000-000000000000'
            appRoles = @([pscustomobject]@{ id = $state.RoleId; value = 'Directory.Read.All'; isEnabled = $true; allowedMemberTypes = @('Application') })
          }) }
        }
        if ($path -ceq "/v1.0/servicePrincipals/$($state.Principal)/appRoleAssignments") {
          if ($Method -eq 'GET') { return [pscustomobject]@{ value = @($state.Assignments.ToArray()) } }
          if ($Method -eq 'POST') {
            $assignment = $Body | ConvertFrom-Json
            $state.Assignments.Add($assignment)
            return $assignment
          }
        }
        throw "Unexpected offline request: $Method $Uri"
      }
    }
  }

  It 'builds a read-only, tenant-bound plan with explicit validated target provenance' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $plan = & $global:MaesterFederatedGrantPath @parameters
      $target = $plan.details.targetProvenance
      $plan.planHash | Should -Match '^[a-f0-9]{64}$'
      $plan.tenantId | Should -BeExactly $state.Tenant
      $plan.principalObjectId | Should -BeExactly $state.Principal
      $target.targetType | Should -BeExactly 'FederatedApplication'
      $target.applicationId | Should -BeExactly $state.ApplicationId
      $target.applicationObjectId | Should -BeExactly $state.ApplicationObjectId
      $target.appOwnerOrganizationId | Should -BeExactly $state.Tenant
      $target.signInAudience | Should -BeExactly 'AzureADMyOrg'
      $target.selectedFederatedCredentialId | Should -BeExactly $state.FederatedCredentials[0].id
      $target.expectedIssuer | Should -BeExactly $state.Params.ExpectedFederatedCredentialIssuer
      $target.expectedSubject | Should -BeExactly $state.Params.ExpectedFederatedCredentialSubject
      $target.audience | Should -BeExactly 'api://AzureADTokenExchange'
      $target.existingTrustNotice | Should -Match 'can exercise the new application grants'
      @($target.preservedFederatedCredentials).Count | Should -Be 1
      @($target.preservedFederatedCredentials[0].audiences) | Should -Be @('api://AzureADTokenExchange')
      @($state.Requests | Where-Object Method -ne 'GET').Count | Should -Be 0
      @($state.Requests | Where-Object TenantId -ne $state.Tenant).Count | Should -Be 0
      @($state.Requests | Where-Object Uri -like '*/federatedIdentityCredentials*').Count | Should -Be 1
      Should -Invoke Assert-GraphAccess -Times 0 -Exactly
    }
  }

  It 'applies only the approved grant tuple, verifies readback and preserves idempotence' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $plan = & $global:MaesterFederatedGrantPath @parameters
      $null = & $global:MaesterFederatedGrantPath @parameters -Apply -ApprovedPlanHash $plan.planHash
      $posts = @($state.Requests | Where-Object Method -eq 'POST')
      $posts.Count | Should -Be 1
      $posts[0].Uri | Should -BeExactly "https://graph.microsoft.com/v1.0/servicePrincipals/$($state.Principal)/appRoleAssignments"
      $body = $posts[0].Body | ConvertFrom-Json
      $body.principalId | Should -BeExactly $state.Principal
      $body.resourceId | Should -BeExactly $state.Resource
      $body.appRoleId | Should -BeExactly $state.RoleId
      $state.Requests[-1].Method | Should -BeExactly 'GET'
      $state.Requests[-1].Uri | Should -BeLike '*/appRoleAssignments*'
      $fresh = & $global:MaesterFederatedGrantPath @parameters
      @($fresh.missing).Count | Should -Be 0
      $null = & $global:MaesterFederatedGrantPath @parameters -Apply -ApprovedPlanHash $fresh.planHash
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 1
      @($state.Requests | Where-Object { $_.Method -notin @('GET', 'POST') }).Count | Should -Be 0
    }
  }

  It 'requires an approved federated plan before mutation and cannot bypass validation with lowercase mode text' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $parameters.TargetType = 'federatedapplication'
      $plan = & $global:MaesterFederatedGrantPath @parameters
      $plan.details.targetProvenance.targetType | Should -BeExactly 'FederatedApplication'
      { & $global:MaesterFederatedGrantPath @parameters -Apply } | Should -Throw '*requires approval*'
      $state.FederatedCredentials[0].subject = 'unapproved-subject'
      { & $global:MaesterFederatedGrantPath @parameters -Apply -ApprovedPlanHash $plan.planHash } | Should -Throw '*Exactly one federated credential*'
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'retains the default managed-identity boundary instead of inferring a federated target' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      { & $global:MaesterFederatedGrantPath -TenantId $state.Tenant -PrincipalObjectId $state.Principal -AppRoleValues 'Directory.Read.All' } | Should -Throw '*managed identity*'
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
      $state.FederatedReads | Should -Be 0
    }
  }

  It 'rejects an extraneous <parameter> on the default managed-identity path, including an empty value' -ForEach @(
    @{ parameter = 'ExpectedApplicationId'; value = '44444444-4444-4444-8444-444444444444' }
    @{ parameter = 'ExpectedApplicationObjectId'; value = '55555555-5555-4555-8555-555555555555' }
    @{ parameter = 'ExpectedFederatedCredentialIssuer'; value = 'https://token.actions.githubusercontent.com' }
    @{ parameter = 'ExpectedFederatedCredentialSubject'; value = 'repo:example/maester:environment:production' }
    @{ parameter = 'ExpectedApplicationId'; value = '' }
    @{ parameter = 'ExpectedApplicationObjectId'; value = '' }
    @{ parameter = 'ExpectedFederatedCredentialIssuer'; value = '' }
    @{ parameter = 'ExpectedFederatedCredentialSubject'; value = '' }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ parameter = $parameter; value = $value } {
      $state = $global:MaesterFederatedGrantState
      $state.ServicePrincipal.servicePrincipalType = 'ManagedIdentity'
      $parameters = @{ TenantId = $state.Tenant; PrincipalObjectId = $state.Principal; AppRoleValues = @('Directory.Read.All') }
      $parameters[$parameter] = $value
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      $state.Requests.Count | Should -Be 0
    }
  }

  It 'requires explicit valid <parameter>: <label> before external reads' -ForEach @(
    @{ parameter = 'ExpectedApplicationId'; label = 'missing'; value = $null }
    @{ parameter = 'ExpectedApplicationObjectId'; label = 'missing'; value = $null }
    @{ parameter = 'ExpectedFederatedCredentialIssuer'; label = 'missing'; value = $null }
    @{ parameter = 'ExpectedFederatedCredentialSubject'; label = 'missing'; value = $null }
    @{ parameter = 'ExpectedApplicationId'; label = 'malformed GUID'; value = 'not-a-guid' }
    @{ parameter = 'ExpectedApplicationObjectId'; label = 'malformed GUID'; value = 'not-a-guid' }
    @{ parameter = 'ExpectedApplicationId'; label = 'empty GUID'; value = '00000000-0000-0000-0000-000000000000' }
    @{ parameter = 'ExpectedApplicationObjectId'; label = 'empty GUID'; value = '00000000-0000-0000-0000-000000000000' }
    @{ parameter = 'ExpectedFederatedCredentialIssuer'; label = 'blank'; value = ' ' }
    @{ parameter = 'ExpectedFederatedCredentialSubject'; label = 'blank'; value = ' ' }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ parameter = $parameter; value = $value } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params.Clone()
      if ($null -eq $value) { $parameters.Remove($parameter) } else { $parameters[$parameter] = $value }
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      $state.Requests.Count | Should -Be 0
    }
  }

  It 'rejects the verified setup-session client despite a different mutable environment client ID' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state.SetupClientId = $state.ApplicationId.ToUpperInvariant()
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw '*setup client*'
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'uses the verified setup-session identity instead of treating environment text as proof' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $env:MAESTER_SETUP_CLIENT_ID = $state.ApplicationId
      $plan = & $global:MaesterFederatedGrantPath @parameters
      $plan.details.targetProvenance.applicationId | Should -BeExactly $state.ApplicationId
      Should -Invoke Get-MaesterGraphSetupClientId -Times 1 -Exactly -ParameterFilter { $TenantId -eq $global:MaesterFederatedGrantState.Tenant }
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects invalid <object> evidence: <field>=<value>' -ForEach @(
    @{ object = 'ServicePrincipal'; field = 'id'; value = '99999999-9999-4999-8999-999999999999' }
    @{ object = 'ServicePrincipal'; field = 'id'; value = $null }
    @{ object = 'ServicePrincipal'; field = 'servicePrincipalType'; value = 'ManagedIdentity' }
    @{ object = 'ServicePrincipal'; field = 'servicePrincipalType'; value = 'application' }
    @{ object = 'ServicePrincipal'; field = 'appId'; value = '99999999-9999-4999-8999-999999999999' }
    @{ object = 'ServicePrincipal'; field = 'appOwnerOrganizationId'; value = '99999999-9999-4999-8999-999999999999' }
    @{ object = 'ServicePrincipal'; field = 'appOwnerOrganizationId'; value = $null }
    @{ object = 'Application'; field = 'id'; value = '99999999-9999-4999-8999-999999999999' }
    @{ object = 'Application'; field = 'appId'; value = '99999999-9999-4999-8999-999999999999' }
    @{ object = 'Application'; field = 'signInAudience'; value = 'AzureADMultipleOrgs' }
    @{ object = 'Application'; field = 'signInAudience'; value = 'AzureADandPersonalMicrosoftAccount' }
    @{ object = 'Application'; field = 'signInAudience'; value = 'azureadmyorg' }
    @{ object = 'Application'; field = 'signInAudience'; value = $null }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ object = $object; field = $field; value = $value } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state[$object].$field = $value
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects a missing or collection-shaped <object> lookup result' -ForEach @(
    @{ object = 'ServicePrincipal'; collection = $false }
    @{ object = 'ServicePrincipal'; collection = $true }
    @{ object = 'Application'; collection = $false }
    @{ object = 'Application'; collection = $true }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ object = $object; collection = $collection } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state[$object] = if ($collection) { [pscustomobject]@{ value = @($state[$object]) } } else { $null }
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects collection-shaped scalar proof in <object>.<field>' -ForEach @(
    @{ object = 'ServicePrincipal'; field = 'id' }
    @{ object = 'ServicePrincipal'; field = 'appId' }
    @{ object = 'ServicePrincipal'; field = 'servicePrincipalType' }
    @{ object = 'ServicePrincipal'; field = 'appOwnerOrganizationId' }
    @{ object = 'Application'; field = 'id' }
    @{ object = 'Application'; field = 'appId' }
    @{ object = 'Application'; field = 'signInAudience' }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ object = $object; field = $field } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state[$object].$field = @($state[$object].$field)
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'requires an exact selected issuer, subject and single Azure AD token-exchange audience: <label>' -ForEach @(
    @{ label = 'issuer case'; field = 'issuer'; value = 'https://TOKEN.actions.githubusercontent.com' }
    @{ label = 'issuer suffix'; field = 'issuer'; value = 'https://token.actions.githubusercontent.com/' }
    @{ label = 'subject case'; field = 'subject'; value = 'repo:example/maester:environment:Production' }
    @{ label = 'different subject'; field = 'subject'; value = 'repo:example/maester:ref:refs/heads/main' }
    @{ label = 'different audience'; field = 'audiences'; value = @('api://other') }
    @{ label = 'audience case'; field = 'audiences'; value = @('api://azureadtokenexchange') }
    @{ label = 'extra audience'; field = 'audiences'; value = @('api://AzureADTokenExchange', 'api://other') }
    @{ label = 'duplicate audience'; field = 'audiences'; value = @('api://AzureADTokenExchange', 'api://AzureADTokenExchange') }
    @{ label = 'scalar audience'; field = 'audiences'; value = 'api://AzureADTokenExchange' }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ field = $field; value = $value } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state.FederatedCredentials[0].$field = $value
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects absent, ambiguous or malformed federated trust inventories: <mode>' -ForEach @(
    @{ mode = 'empty' }
    @{ mode = 'duplicate-match' }
    @{ mode = 'duplicate-id' }
    @{ mode = 'null-row' }
    @{ mode = 'missing-id' }
    @{ mode = 'missing-name' }
    @{ mode = 'missing-issuer' }
    @{ mode = 'missing-subject' }
    @{ mode = 'missing-audiences' }
    @{ mode = 'empty-audiences' }
    @{ mode = 'malformed-unrelated-trust' }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ mode = $mode } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      switch ($mode) {
        'empty' { $state.FederatedCredentials = @() }
        'duplicate-match' {
          $duplicate = $state.FederatedCredentials[0].PSObject.Copy()
          $duplicate.id = '77777777-7777-4777-8777-777777777777'
          $duplicate.name = 'duplicate-match'
          $state.FederatedCredentials += $duplicate
        }
        'duplicate-id' { $state.FederatedCredentials += $state.FederatedCredentials[0].PSObject.Copy() }
        'null-row' { $state.FederatedCredentials += $null }
        'empty-audiences' { $state.FederatedCredentials[0].audiences = @() }
        'malformed-unrelated-trust' { $state.FederatedCredentials += [pscustomobject]@{ id = '77777777-7777-4777-8777-777777777777'; name = 'unrelated'; issuer = 'https://issuer.example'; subject = 'other' } }
        default { $state.FederatedCredentials[0].PSObject.Properties.Remove($mode.Substring('missing-'.Length)) }
      }
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects incomplete or malformed federated collection responses: <_>' -ForEach @('missing-value', 'null-value', 'object-value', 'string-value') {
    InModuleScope Maester-SetupHelpers -Parameters @{ mode = $_ } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state.FederatedPageMode = $mode
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects invalid complete FIC inventory <mode> with acrossPages=<acrossPages>' -ForEach @(
    foreach ($acrossPages in @($false, $true)) {
      foreach ($mode in @('duplicate-selected-name', 'duplicate-unrelated-name', 'duplicate-selected-tuple', 'duplicate-unrelated-tuple', 'multiple-unrelated-audiences')) {
        @{ mode = $mode; acrossPages = $acrossPages }
      }
    }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ mode = $mode; acrossPages = $acrossPages } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $selected = $state.FederatedCredentials[0]
      $other = [pscustomobject]@{
        id = '77777777-7777-4777-8777-777777777777'; name = 'unrelated-staging'
        issuer = 'https://issuer.example'; subject = 'unrelated-staging'; audiences = @('api://AzureADTokenExchange')
      }
      $invalid = [pscustomobject]@{
        id = '88888888-8888-4888-8888-888888888888'; name = 'unrelated-third'
        issuer = 'https://issuer.example'; subject = 'unrelated-third'; audiences = @('api://AzureADTokenExchange')
      }
      switch ($mode) {
        'duplicate-selected-name' { $invalid.name = $selected.name }
        'duplicate-unrelated-name' { $invalid.name = $other.name }
        'duplicate-selected-tuple' {
          $invalid.issuer = $selected.issuer
          $invalid.subject = $selected.subject
          # A different single audience must not conceal an impossible duplicate
          # issuer/subject tuple behind exactly one expected-audience match.
          $invalid.audiences = @('api://different-audience')
        }
        'duplicate-unrelated-tuple' {
          $invalid.issuer = $other.issuer
          $invalid.subject = $other.subject
        }
        'multiple-unrelated-audiences' { $invalid.audiences = @('api://AzureADTokenExchange', 'api://different-audience') }
      }
      $state.FederatedCredentials = @($selected, $other)
      if ($acrossPages) {
        $state.LaterFederatedCredentials = @($invalid)
        $state.FederatedNextLink = "https://graph.microsoft.com/v1.0/applications/$($state.ApplicationObjectId)/federatedIdentityCredentials?`$skiptoken=second"
      } else { $state.FederatedCredentials += $invalid }
      $expected = if ($mode -like '*name') { '*duplicate*name*' }
        elseif ($mode -like '*tuple') { '*duplicate*issuer*subject*' }
        else { '*audiences*' }
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw $expected
      $state.FederatedReads | Should -Be $(if ($acrossPages) { 2 } else { 1 })
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects a non-string federated continuation even when string coercion would look terminal' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state.FederatedNextLink = @()
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      $state.FederatedReads | Should -Be 1
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'finds the selected trust on a later page and binds all existing trusts in stable order' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $selected = $state.FederatedCredentials[0]
      $other = [pscustomobject]@{
        id = '77777777-7777-4777-8777-777777777777'; name = 'other-environment'
        issuer = $selected.issuer; subject = 'repo:example/maester:environment:staging'; audiences = @('api://AzureADTokenExchange')
      }
      $state.FederatedCredentials = @($other)
      $state.LaterFederatedCredentials = @($selected)
      $state.FederatedNextLink = "https://graph.microsoft.com/v1.0/applications/$($state.ApplicationObjectId)/federatedIdentityCredentials?`$skiptoken=second"
      $paged = & $global:MaesterFederatedGrantPath @parameters
      $state.FederatedReads | Should -Be 2
      @($paged.details.targetProvenance.preservedFederatedCredentials).Count | Should -Be 2
      $paged.details.targetProvenance.selectedFederatedCredentialId | Should -BeExactly $selected.id
      ($paged.details | ConvertTo-Json -Depth 20) | Should -Match 'staging'
      $state.FederatedNextLink = $null
      $state.FederatedCredentials = @($selected, $other)
      $unpaged = & $global:MaesterFederatedGrantPath @parameters
      $paged.planHash | Should -BeExactly $unpaged.planHash
      @($state.Requests | Where-Object Uri -like '*federatedIdentityCredentials*filter*').Count | Should -Be 0
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'does not stop enumerating after a first-page match when a duplicate appears later' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $duplicate = $state.FederatedCredentials[0].PSObject.Copy()
      $duplicate.id = '77777777-7777-4777-8777-777777777777'
      $duplicate.name = 'ambiguous-later-trust'
      $state.LaterFederatedCredentials = @($duplicate)
      $state.FederatedNextLink = "https://graph.microsoft.com/v1.0/applications/$($state.ApplicationObjectId)/federatedIdentityCredentials?`$skiptoken=second"
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      $state.FederatedReads | Should -Be 2
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects unsafe federated pagination before following <link>' -ForEach @(
    @{ link = 'https://other.example/v1.0/applications/55555555-5555-4555-8555-555555555555/federatedIdentityCredentials' }
    @{ link = 'http://graph.microsoft.com/v1.0/applications/55555555-5555-4555-8555-555555555555/federatedIdentityCredentials' }
    @{ link = 'https://graph.microsoft.com:444/v1.0/applications/55555555-5555-4555-8555-555555555555/federatedIdentityCredentials' }
    @{ link = 'https://user@graph.microsoft.com/v1.0/applications/55555555-5555-4555-8555-555555555555/federatedIdentityCredentials' }
    @{ link = 'https://graph.microsoft.com/v1.0/applications/55555555-5555-4555-8555-555555555555/federatedIdentityCredentials#fragment' }
    @{ link = 'https://graph.microsoft.com/v1.0/applications/99999999-9999-4999-8999-999999999999/federatedIdentityCredentials' }
    @{ link = 'https://graph.microsoft.com/beta/applications/55555555-5555-4555-8555-555555555555/federatedIdentityCredentials' }
    @{ link = '/v1.0/applications/55555555-5555-4555-8555-555555555555/federatedIdentityCredentials' }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ link = $link } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state.FederatedNextLink = $link
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw '*expected secure collection*'
      $state.FederatedReads | Should -Be 1
      @($state.Requests | Where-Object Uri -eq $link).Count | Should -Be 0
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'fails closed for federated continuation <_>' -ForEach @('loop', 'endless', 'failure') {
    InModuleScope Maester-SetupHelpers -Parameters @{ mode = $_ } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $state.FederatedNextLink = "https://graph.microsoft.com/v1.0/applications/$($state.ApplicationObjectId)/federatedIdentityCredentials?`$skiptoken=second"
      if ($mode -eq 'loop') { $state.LaterNextLink = $state.FederatedNextLink } else { $state.FederatedPageMode = $mode }
      $expected = if ($mode -eq 'failure') { '*Synthetic federated credential page failure*' } else { '*exceeded its limit or repeated a page*' }
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw $expected
      $state.FederatedReads | Should -Be $(if ($mode -eq 'endless') { 100 } else { 2 })
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects malformed or duplicate credential metadata: <mode>' -ForEach @(
    @{ mode = 'array keyId'; field = 'keyId'; value = @('88888888-8888-4888-8888-888888888888') }
    @{ mode = 'empty keyId'; field = 'keyId'; value = '00000000-0000-0000-0000-000000000000' }
    @{ mode = 'invalid keyId'; field = 'keyId'; value = 'not-a-guid' }
    @{ mode = 'array startDateTime'; field = 'startDateTime'; value = @('2026-01-01T00:00:00Z') }
    @{ mode = 'array endDateTime'; field = 'endDateTime'; value = @('2027-01-01T00:00:00Z') }
    @{ mode = 'invalid date'; field = 'endDateTime'; value = 'not-a-date' }
    @{ mode = 'duplicate keyId'; field = ''; value = $null }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ mode = $mode; field = $field; value = $value } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $credential = [pscustomobject]@{
        keyId = '88888888-8888-4888-8888-888888888888'
        startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z'
      }
      $state.Application.keyCredentials = @($credential)
      if ($mode -eq 'duplicate keyId') { $state.Application.keyCredentials += $credential.PSObject.Copy() }
      else { $credential.$field = $value }
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'requires complete <object>.<inventory> metadata rather than assuming no alternate credentials: <mode>' -ForEach @(
    foreach ($object in @('Application', 'ServicePrincipal')) {
      foreach ($inventory in @('keyCredentials', 'passwordCredentials')) {
        foreach ($mode in @('missing', 'null', 'scalar', 'malformed-row')) {
          @{ object = $object; inventory = $inventory; mode = $mode }
        }
      }
    }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ object = $object; inventory = $inventory; mode = $mode } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      switch ($mode) {
        'missing' { $state[$object].PSObject.Properties.Remove($inventory) }
        'null' { $state[$object].$inventory = $null }
        'scalar' { $state[$object].$inventory = 'not-a-collection' }
        'malformed-row' { $state[$object].$inventory = @([pscustomobject]@{ displayName = 'unknown-credential' }) }
      }
      { & $global:MaesterFederatedGrantPath @parameters } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'describes alternate credentials by owner and safe metadata without leaking credential material' {
    InModuleScope Maester-SetupHelpers {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      foreach ($object in @('Application', 'ServicePrincipal')) {
        $state[$object].keyCredentials = @([pscustomobject]@{
          keyId = '88888888-8888-4888-8888-888888888888'; type = 'AsymmetricX509Cert'; usage = 'Verify'
          startDateTime = '2026-01-01T01:00:00+01:00'; endDateTime = '2027-01-01T01:00:00+01:00'
          key = 'synthetic-certificate-material'; customKeyIdentifier = 'synthetic-certificate-hint'
        })
        $state[$object].passwordCredentials = @([pscustomobject]@{
          keyId = '99999999-9999-4999-8999-999999999999'
          startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z'
          secretText = 'synthetic-secret-marker'; hint = 'synthetic-password-hint'; displayName = 'synthetic-display-name'
        })
      }
      $plan = & $global:MaesterFederatedGrantPath @parameters
      $metadata = @($plan.details.targetProvenance.existingApplicationCredentials)
      $metadata.Count | Should -Be 4
      @($metadata | Where-Object ownerType -eq 'application').Count | Should -Be 2
      @($metadata | Where-Object ownerType -eq 'servicePrincipal').Count | Should -Be 2
      @($metadata | Where-Object type -eq 'keyCredentials').Count | Should -Be 2
      @($metadata | Where-Object type -eq 'passwordCredentials').Count | Should -Be 2
      foreach ($credential in $metadata) {
        $credential.startDateTime | Should -BeExactly '2026-01-01T00:00:00.0000000+00:00'
        $credential.endDateTime | Should -BeExactly '2027-01-01T00:00:00.0000000+00:00'
      }
      ($plan | ConvertTo-Json -Depth 30) | Should -Not -Match 'synthetic-'
      @($state.Requests | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
  }

  It 'invalidates a reviewed plan after <drift> while keeping the desired grants unchanged' -ForEach @(
    @{ drift = 'selected FIC ID' }
    @{ drift = 'selected FIC name' }
    @{ drift = 'additional FIC' }
    @{ drift = 'existing key credential' }
    @{ drift = 'existing password credential' }
    @{ drift = 'service principal credential' }
    @{ drift = 'application client ID' }
    @{ drift = 'application object ID' }
  ) {
    InModuleScope Maester-SetupHelpers -Parameters @{ drift = $drift } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $plan = & $global:MaesterFederatedGrantPath @parameters
      switch ($drift) {
        'selected FIC ID' { $state.FederatedCredentials[0].id = '77777777-7777-4777-8777-777777777777' }
        'selected FIC name' { $state.FederatedCredentials[0].name = 'renamed-production' }
        'additional FIC' {
          $other = $state.FederatedCredentials[0].PSObject.Copy()
          $other.id = '77777777-7777-4777-8777-777777777777'
          $other.name = 'other-trust'
          $other.subject = 'repo:example/other:environment:production'
          $state.FederatedCredentials += $other
        }
        'existing key credential' {
          $state.Application.keyCredentials = @([pscustomobject]@{
            keyId = '88888888-8888-4888-8888-888888888888'; type = 'AsymmetricX509Cert'; usage = 'Verify'
            startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z'
          })
        }
        'existing password credential' {
          $state.Application.passwordCredentials = @([pscustomobject]@{
            keyId = '99999999-9999-4999-8999-999999999999'; displayName = 'existing-password'
            startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z'
          })
        }
        'service principal credential' {
          $state.ServicePrincipal.passwordCredentials = @([pscustomobject]@{
            keyId = '99999999-9999-4999-8999-999999999999'
            startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z'
          })
        }
        'application client ID' {
          $parameters.ExpectedApplicationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
          $state.ServicePrincipal.appId = $parameters.ExpectedApplicationId
          $state.Application.appId = $parameters.ExpectedApplicationId
        }
        'application object ID' {
          $parameters.ExpectedApplicationObjectId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
          $state.ApplicationObjectId = $parameters.ExpectedApplicationObjectId
          $state.Application.id = $parameters.ExpectedApplicationObjectId
        }
      }
      $changed = & $global:MaesterFederatedGrantPath @parameters
      $changed.desired | Should -Be $plan.desired
      $changed.missing | Should -Be $plan.missing
      $changed.planHash | Should -Not -Be $plan.planHash
      { & $global:MaesterFederatedGrantPath @parameters -Apply -ApprovedPlanHash $plan.planHash } | Should -Throw '*requires approval*'
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'invalidates approval after an unrelated preserved trust changes: <_>' -ForEach @('issuer', 'subject', 'audiences', 'name') {
    InModuleScope Maester-SetupHelpers -Parameters @{ field = $_ } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $other = $state.FederatedCredentials[0].PSObject.Copy()
      $other.id = '77777777-7777-4777-8777-777777777777'
      $other.name = 'other-trust'
      $other.subject = 'repo:example/other:environment:staging'
      $state.FederatedCredentials += $other
      $plan = & $global:MaesterFederatedGrantPath @parameters
      switch ($field) {
        'issuer' { $other.issuer = 'https://issuer.example' }
        'subject' { $other.subject = 'repo:example/another:environment:staging' }
        'audiences' { $other.audiences = @('api://different-audience') }
        'name' { $other.name = 'renamed-other-trust' }
      }
      { & $global:MaesterFederatedGrantPath @parameters -Apply -ApprovedPlanHash $plan.planHash } | Should -Throw '*requires approval*'
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }

  It 'rejects invalid runtime provenance discovered during Apply before a first mutation' -ForEach @('ServicePrincipal', 'Application', 'FederatedCredentials') {
    InModuleScope Maester-SetupHelpers -Parameters @{ object = $_ } {
      $state = $global:MaesterFederatedGrantState
      $parameters = $state.Params
      $plan = & $global:MaesterFederatedGrantPath @parameters
      switch ($object) {
        'ServicePrincipal' { $state.ServicePrincipal.appOwnerOrganizationId = '99999999-9999-4999-8999-999999999999' }
        'Application' { $state.Application.signInAudience = 'AzureADMultipleOrgs' }
        'FederatedCredentials' { $state.FederatedCredentials = @() }
      }
      { & $global:MaesterFederatedGrantPath @parameters -Apply -ApprovedPlanHash $plan.planHash } | Should -Throw
      @($state.Requests | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
  }
}
