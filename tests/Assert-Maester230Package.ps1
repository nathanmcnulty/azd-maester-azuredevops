#Requires -Version 7.6
# Read-only archive/member check used by actual-package qualification scripts.
function Assert-Maester230Package {
  param([Parameter(Mandatory)][string]$PackagePath, [Parameter(Mandatory)]$Module)
  $expected = '95F720822D04271F5E15F4665BC017111DC72E17B97E5D0525CB4EC2FF5BD0B0'
  if ((Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash -cne $expected) { throw 'Unreviewed Maester package bytes.' }
  $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
  try {
    $members = @($archive.Entries | Where-Object { $_.FullName -in @('Maester.psd1','Maester.psm1') -or $_.FullName.StartsWith('maester-tests/',[StringComparison]::Ordinal) -or $_.FullName.StartsWith('assets/',[StringComparison]::Ordinal) } | Where-Object { -not $_.FullName.EndsWith('/') })
    foreach ($entry in $members) {
      $stream = $entry.Open()
      try { $expectedMember = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
      finally { $stream.Dispose() }
      $actualPath = Join-Path $Module.ModuleBase $entry.FullName
      if (-not (Test-Path -LiteralPath $actualPath -PathType Leaf) -or (Get-FileHash -LiteralPath $actualPath -Algorithm SHA256).Hash -cne $expectedMember) { throw 'Imported module bytes differ from reviewed package.' }
    }
    if (@($members | Where-Object FullName -Like 'maester-tests/*.Tests.ps1').Count -ne 519) { throw 'Unexpected reviewed test inventory.' }
  }
  finally { $archive.Dispose() }
}
