#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [ValidateSet("status", "watch", "sync", "restart")]
    [string]$Command = "status",
    [switch]$Api
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here "KaringNet.psm1") -Force

switch ($Command) {
    "status" {
        $s = Get-KaringNetStatus -Api:$Api
        Write-Host ("karing={0} service={1} port3057={2} port3067={3} ok={4}" -f $s.Karing, $s.Service, $s.Port3057, $s.Port3067, $s.Ok)
        if ($Api -and $null -ne $s.GroupNow) {
            foreach ($k in @($s.GroupNow.Keys)) {
                Write-Host ("group {0}={1}" -f $k, $s.GroupNow[$k])
            }
        }
        if ($s.Ok) { exit 0 }
        exit 1
    }
    "watch" {
        $r = Invoke-KaringNetWatch
        Write-Host ("watch changed={0}" -f $r.Changed)
        exit 0
    }
    "sync" {
        $r = Sync-KaringNetProfile
        Write-Host ("sync ok={0} wrote={1} reason={2}" -f $r.Ok, $r.Wrote, $r.Reason)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "restart" {
        $r = Restart-KaringNetCore
        Write-Host ("restart ok={0} reason={1}" -f $r.Ok, $r.Reason)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
}
