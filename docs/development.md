# PowerShell and test baseline

Use PowerShell 7.6 or newer for local setup, azd hooks, validation and pipeline
execution. All owned scripts and the validation module enforce this minimum
before executing their bodies. Immutable vendored sources and dated historical
receipts retain their reviewed versions.

Run the offline suite from the repository root in PowerShell 7.6 or newer:

```powershell
$PSVersionTable.PSVersion
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.41.0 -Scope CurrentUser -Force
Import-Module Pester -RequiredVersion 6.2.0 -Force
(Get-Module Pester).Version
Invoke-Pester -Path ./tests -CI
```

CI installs and explicitly imports Pester 6.2.0 and records both selected
versions. Setup-session boundary tests load the actual Graph Authentication 2.41.0
SDK but mock every authentication/request boundary. CI obtains that package using
the existing SHA-256-verified runtime lock installer; it never signs in. The pipeline runner uses the separate hash-verified runtime package
lock, which already selects Pester 6.2.0.

The generated Azure DevOps pipeline checks its agent's `pwsh` version before
the Azure CLI service-connection task. Its selected agent image must supply
PowerShell 7.6 or newer. An older agent fails this check; the pipeline does not
install or select an older runtime. Existing generated repositories receive
the updated template and runner only when setup successfully pushes those files.

Offline validation does not prove the selected Azure DevOps agent, service
connection, workload permissions, pipeline execution or report publication.
Those remain separate live acceptance gates in the backlog.
