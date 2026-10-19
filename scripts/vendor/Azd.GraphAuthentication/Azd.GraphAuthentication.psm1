Set-StrictMode -Version Latest

function Resolve-AzdGraphScopeSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Scope
    )

    $unique = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in $Scope) {
        $normalized = if ($null -eq $entry) { '' } else { $entry.Trim() }
        if ($normalized -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,255}$') {
            throw 'Microsoft Graph scopes must be nonempty permission names without whitespace.'
        }
        if (-not $unique.ContainsKey($normalized)) {
            $unique[$normalized] = $normalized
        }
    }
    if ($unique.Count -eq 0) {
        throw 'At least one Microsoft Graph scope is required.'
    }
    return @($unique.Values | Sort-Object)
}

function Get-AzdGraphContextAssessment {
    param(
        [AllowNull()][object] $Context,
        [Parameter(Mandatory)][guid] $TenantId,
        [Parameter(Mandatory)][guid] $ExpectedClientId,
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][string] $ExpectedAccount,
        [Parameter(Mandatory)][string[]] $Scopes,
        [ValidateSet('CurrentUser', 'Process')][string] $ContextScope = 'CurrentUser'
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $missingScopes = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Context) {
        $reasons.Add('no Microsoft Graph context is available')
    }
    else {
        # Older or incomplete contexts cannot prove which application acquired
        # the token. Never infer the client from tenant, account, or scopes.
        $clientIdProperty = $Context.PSObject.Properties['ClientId']
        $contextClientId = [guid]::Empty
        if ($null -eq $clientIdProperty -or
            -not [guid]::TryParse([string] $clientIdProperty.Value, [ref] $contextClientId) -or
            $contextClientId -eq [guid]::Empty) {
            $reasons.Add('the context client ID is unavailable or invalid')
        }
        elseif ($contextClientId -ne $ExpectedClientId) {
            $reasons.Add('the context client ID does not match')
        }
        if ([string] $Context.TenantId -ine $TenantId.Guid) {
            $reasons.Add('the context tenant does not match')
        }
        if ([string] $Context.Environment -ine $Environment) {
            $reasons.Add('the context environment does not match')
        }
        if ([string] $Context.AuthType -ine 'Delegated') {
            $reasons.Add('the context is not delegated')
        }
        if ([string] $Context.ContextScope -ine $ContextScope) {
            $reasons.Add("the context scope does not match the required $ContextScope scope")
        }
        if ([string]::IsNullOrWhiteSpace([string] $Context.Account)) {
            $reasons.Add('the context has no selected account')
        }
        elseif ($ExpectedAccount -and [string] $Context.Account -ine $ExpectedAccount) {
            $reasons.Add('the context account does not match')
        }
        foreach ($scope in $Scopes) {
            if ($scope -notin @($Context.Scopes)) {
                $missingScopes.Add($scope)
            }
        }
        if ($missingScopes.Count -gt 0) {
            $reasons.Add("the context is missing scopes: $($missingScopes -join ', ')")
        }
    }

    return [pscustomobject]@{
        IsUsable = $reasons.Count -eq 0
        Reasons = @($reasons)
        MissingScopes = @($missingScopes)
    }
}

function Test-AzdGraphProbe {
    param([Parameter(Mandatory)][string] $ProbeUri)

    try {
        Invoke-MgGraphRequest -Method GET -Uri $ProbeUri -OutputType PSObject -ErrorAction Stop | Out-Null
        return [pscustomobject]@{ Succeeded = $true; ErrorType = $null }
    }
    catch {
        $statusCode = $null
        foreach ($propertyName in 'ResponseStatusCode', 'StatusCode') {
            if ($_.Exception.PSObject.Properties.Name -contains $propertyName) {
                $statusCode = $_.Exception.$propertyName
                break
            }
        }
        if ($null -eq $statusCode -and $_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            foreach ($propertyName in 'StatusCode', 'Status') {
                if ($_.Exception.Response.PSObject.Properties.Name -contains $propertyName) {
                    $statusCode = $_.Exception.Response.$propertyName
                    break
                }
            }
        }
        $numericStatus = if ($null -ne $statusCode) {
            try { [int] $statusCode } catch { $null }
        }
        else { $null }
        $errorType = $_.Exception.GetType().FullName
        $classification = if ($null -ne $numericStatus) {
            if ($numericStatus -eq 401) { 'authentication' }
            elseif ($numericStatus -eq 403) { 'authorization' }
            elseif ($numericStatus -eq 429) { 'throttled' }
            elseif ($numericStatus -ge 500) { 'provider' }
            else { 'request' }
        }
        elseif ($errorType -match '(?i)(MsalUiRequired|AuthenticationRequired)') {
            'authentication'
        }
        else { 'transport' }
        return [pscustomobject]@{
            Succeeded = $false
            Classification = $classification
            StatusCode = $numericStatus
            ErrorType = $errorType
        }
    }
}

function New-AzdGraphSessionResult {
    param(
        [Parameter(Mandatory)][object] $Context,
        [Parameter(Mandatory)][string[]] $Scopes,
        [Parameter(Mandatory)][bool] $ConnectInvoked,
        [Parameter(Mandatory)][bool] $ContextReused
    )

    return [pscustomobject] [ordered]@{
        tenantId = [string] $Context.TenantId
        clientId = ([guid] $Context.ClientId).Guid
        environment = [string] $Context.Environment
        account = [string] $Context.Account
        authType = [string] $Context.AuthType
        contextScope = [string] $Context.ContextScope
        grantedScopes = @($Scopes)
        connectInvoked = $ConnectInvoked
        contextReused = $ContextReused
        probeSucceeded = $true
    }
}

function Connect-AzdGraphSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $TenantId,

        [Parameter(Mandatory)]
        [guid] $ExpectedClientId,

        [Parameter(Mandatory)]
        [string[]] $Scopes,

        [Parameter(Mandatory)]
        [string] $ProbeUri,

        [string] $Environment = 'Global',

        [Parameter(Mandatory)]
        [string] $ExpectedAccount,

        [switch] $AllowInteractive,

        [switch] $AllowContextReplacement,

        [ValidateRange(60, 900)]
        [int] $ClientTimeoutSeconds = 300,

        [ValidateSet('CurrentUser', 'Process')]
        [string] $ContextScope = 'CurrentUser'
    )

    if ($TenantId -eq [guid]::Empty) { throw 'TenantId must identify a nonempty tenant.' }
    # Validate the application binding before any Graph command, including
    # environment discovery. The SDK default is never a solution-owned client.
    if ($ExpectedClientId -eq [guid]::Empty -or
        $ExpectedClientId -eq [guid]'14d82eec-204b-4c2f-b7e8-296a70dab67e') {
        throw 'ExpectedClientId must identify a nonempty solution-owned application, not Microsoft Graph Command Line Tools.'
    }
    $expectedAccountName = $ExpectedAccount.Trim()
    if ($expectedAccountName -notmatch '^[^@\s]+@[^@\s]+$') {
        throw 'ExpectedAccount must be a nonempty user principal name.'
    }
    if ($ProbeUri -notmatch '^/(v1\.0|beta)/(?!/)[^\u0000-\u001F]+$' -or
        -not [System.Uri]::IsWellFormedUriString($ProbeUri, [System.UriKind]::Relative)) {
        throw 'ProbeUri must be a well-formed relative Microsoft Graph v1.0 or beta URI without control characters.'
    }
    $requiredScopes = @(Resolve-AzdGraphScopeSet -Scope $Scopes)
    $environments = @(Get-MgEnvironment | Where-Object Name -IEQ $Environment)
    if ($environments.Count -ne 1) {
        throw "Microsoft Graph environment '$Environment' is not available in the installed authentication module."
    }
    $environmentName = [string] $environments[0].Name
    $context = Get-MgContext
    # SDK connection failure can clean up the previously selected context.
    # Do not risk persisted user sessions when opting into Process scope.
    if ($ContextScope -ieq 'Process' -and $null -ne $context) {
        $scopeProperty = $context.PSObject.Properties['ContextScope']
        if ($null -eq $scopeProperty -or [string] $scopeProperty.Value -ine 'Process') {
            throw 'Process-scoped Graph authentication cannot replace an inherited non-Process context, even with replacement authorization. Start a fresh pwsh -NoProfile process and rerun setup without disconnecting existing sessions.'
        }
    }
    $assessment = Get-AzdGraphContextAssessment `
        -Context $context `
        -TenantId $TenantId `
        -ExpectedClientId $ExpectedClientId `
        -Environment $environmentName `
        -ContextScope $ContextScope `
        -ExpectedAccount $expectedAccountName `
        -Scopes $requiredScopes

    if ($assessment.IsUsable) {
        $probe = Test-AzdGraphProbe -ProbeUri $ProbeUri
        if ($probe.Succeeded) {
            return New-AzdGraphSessionResult `
                -Context $context `
                -Scopes $requiredScopes `
                -ConnectInvoked $false `
                -ContextReused $true
        }
        if ($probe.Classification -ne 'authentication') {
            throw "The Microsoft Graph read-only probe failed without an authentication error. Authentication was not started. Classification: $($probe.Classification); error type: $($probe.ErrorType)."
        }
        if (-not $AllowInteractive) {
            throw "The matching Microsoft Graph context is not usable in this process. Rerun from an interactive desktop session. Probe error type: $($probe.ErrorType)."
        }
    }
    elseif ($null -ne $context -and -not $AllowContextReplacement) {
        throw "The existing Microsoft Graph context cannot be replaced without explicit authorization: $($assessment.Reasons -join '; ')."
    }
    elseif (-not $AllowInteractive) {
        throw "A usable Microsoft Graph context is required for noninteractive execution: $($assessment.Reasons -join '; ')."
    }

    if (-not $AllowInteractive) {
        throw 'Interactive Microsoft Graph authentication was not authorized.'
    }

    $connectParameters = @{
        TenantId = $TenantId.Guid
        ClientId = $ExpectedClientId.Guid
        Environment = $environmentName
        Scopes = $requiredScopes
        ContextScope = $ContextScope
        ClientTimeout = $ClientTimeoutSeconds
        NoWelcome = $true
        ErrorAction = 'Stop'
    }
    try {
        Connect-MgGraph @connectParameters | Out-Null
    }
    catch {
        throw "Interactive Microsoft Graph authentication through the normal broker or browser flow failed. The coordinator did not request an alternate authentication flow; SDK-internal fallback may still occur. Error type: $($_.Exception.GetType().FullName)."
    }

    $context = Get-MgContext
    $assessment = Get-AzdGraphContextAssessment `
        -Context $context `
        -TenantId $TenantId `
        -ExpectedClientId $ExpectedClientId `
        -Environment $environmentName `
        -ContextScope $ContextScope `
        -ExpectedAccount $expectedAccountName `
        -Scopes $requiredScopes
    if (-not $assessment.IsUsable) {
        throw "Microsoft Graph authentication completed without the required session properties: $($assessment.Reasons -join '; ')."
    }

    $probe = Test-AzdGraphProbe -ProbeUri $ProbeUri
    if (-not $probe.Succeeded) {
        throw "Microsoft Graph authentication completed, but the read-only session probe failed. Probe error type: $($probe.ErrorType)."
    }
    return New-AzdGraphSessionResult `
        -Context $context `
        -Scopes $requiredScopes `
        -ConnectInvoked $true `
        -ContextReused $false
}

Export-ModuleMember -Function @(
    'Connect-AzdGraphSession',
    'Resolve-AzdGraphScopeSet'
)
