<#
.SYNOPSIS
Writes the full AdminDeck catalog (every script, its metadata and parsed parameters) as JSON.
Used by the macOS app, which reads scripts through pwsh rather than parsing PowerShell itself.

.EXAMPLE
pwsh -NoProfile -File ./AdminDeck/Export-AdCatalog.ps1 -RepoRoot . -OutFile catalog.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$OutFile,
    [string]$ModulePath
)
$ErrorActionPreference = 'Stop'
if (-not $ModulePath) { $ModulePath = Join-Path $PSScriptRoot 'AdminDeck.Catalog.psm1' }
Import-Module $ModulePath -Force

$root = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$scripts = foreach ($s in (Get-AdScriptCatalog -RepoRoot $root)) {
    $p = Get-AdScriptParameters -Path $s.Path
    $s | Add-Member -NotePropertyName Parameters -NotePropertyValue ([object[]]@($p.Parameters)) -PassThru |
        Add-Member -NotePropertyName ParameterSets -NotePropertyValue ([string[]]@($p.ParameterSets)) -PassThru |
        Add-Member -NotePropertyName ParseErrors -NotePropertyValue ([string[]]@($p.ParseErrors)) -PassThru
}
$out = [ordered]@{
    repoRoot     = $root
    generated    = (Get-Date).ToString('o')
    psVersion    = $PSVersionTable.PSVersion.ToString()
    knownModules = [string[]]@(Get-AdKnownModules)
    scripts      = [object[]]@($scripts)
}
$json = $out | ConvertTo-Json -Depth 8 -Compress
if ($OutFile) { [IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding $false)) }
else { $json }
