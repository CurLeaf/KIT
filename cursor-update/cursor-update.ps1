#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [ValidateSet("status", "fetch", "apply", "watch", "install")]
    [string]$Command = "status",
    [switch]$FromTask
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here "CursorUpdate.psm1") -Force

switch ($Command) {
    "status" {
        $s = Get-CursorUpdateStatus
        Write-Host (Format-CursorUpdateStatusLine $s)
        if ($s.Ok) { exit 0 }
        exit 1
    }
    "fetch" {
        $r = Invoke-CursorUpdateFetch
        Write-Host ("fetch ok={0} version={1} reason={2}" -f [int]$r.Ok, $r.Version, $r.Reason)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "apply" {
        $r = Invoke-CursorUpdateApply -FromTask:$FromTask
        Write-Host ("apply ok={0} reason={1}" -f [int]$r.Ok, $r.Reason)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "watch" {
        $r = Invoke-CursorUpdateWatch
        Write-Host ("watch fetch={0} toast={1} reason={2}" -f [int]$r.Fetched, [int]$r.Toast, $r.Reason)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "install" {
        $r = Install-CursorUpdateHost
        Write-Host ("install ok={0} protocol={1} watchTask={2} applyTask={3} settings={4}" -f [int]$r.Ok, [int]$r.Protocol, [int]$r.WatchTask, [int]$r.ApplyTask, [int]$r.Settings)
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    default {
        Write-Host ("not-implemented command={0}" -f $Command)
        exit 1
    }
}
