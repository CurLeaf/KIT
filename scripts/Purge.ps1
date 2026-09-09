#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [string]$Root = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here "Purge.psm1") -Force
[void](Invoke-PurgeRepo -Root $Root)
exit 0
