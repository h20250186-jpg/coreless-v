# Dot-sourced by the scripts\*.ps1 drivers. Loads tools\paths.ps1 (your copy)
# or, if it does not exist, tools\paths.example.ps1 (the defaults).
$__paths = Join-Path $PSScriptRoot 'paths.ps1'
if (-not (Test-Path $__paths)) { $__paths = Join-Path $PSScriptRoot 'paths.example.ps1' }
. $__paths
Remove-Variable __paths
