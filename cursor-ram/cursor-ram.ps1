#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [ValidateSet("status", "apply", "watch", "hold", "pack", "park", "purge", "install", "ensure-docker")]
    [string]$Command = "status",
    [switch]$Dev,
    [int]$Hours = 2,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PackArgs
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here "CursorRam.psm1") -Force

switch ($Command) {
    "status" {
        $s = Get-CursorRamStatus
        Write-Host (Format-CursorRamStatusLine $s)
        if ($s.Ok) { exit 0 }
        exit 1
    }
    "apply" {
        $r = Invoke-CursorRamApply
        Write-Host ("apply ok={0} reason={1} wsl={2} mcp={3} preview={4}" -f [int]$r.Ok, $r.Reason, [int]$r.WslStopped, [int]$r.McpMoved, [int]$r.PreviewRemoved)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "watch" {
        $r = Invoke-CursorRamWatch
        Write-Host ("watch changed={0} reason={1}" -f [int]$r.Changed, $r.Reason)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "hold" {
        Set-CursorRamHold -Hours $Hours
        Write-Host ("hold hours={0} until={1}" -f $Hours, (Get-CursorRamHold).until)
        exit 0
    }
    "pack" {
        $r = Invoke-CursorRamPack -Arguments $PackArgs -WorkingDirectory (Get-Location).Path
        Write-Host ("pack ok={0} reason={1} cwd={2} exit={3}" -f [int]$r.Ok, $r.Reason, $r.WslCwd, $r.ExitCode)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "park" {
        $r = Invoke-CursorRamPark -Dev:$Dev
        Write-Host ("park ok={0} reason={1} stopped={2}" -f [int]$r.Ok, $r.Reason, $r.Stopped)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "purge" {
        $r = Invoke-CursorRamPurge
        Write-Host ("purge ok={0} reason={1} vhdx={2} unreg={3}" -f [int]$r.Ok, $r.Reason, [int]$r.RemovedVhdx, [int]$r.Unregistered)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "install" {
        $r = Install-CursorRamHost
        Write-Host ("install ok={0} reason={1} watchTask={2} apply={3} docker={4}" -f [int]$r.Ok, $r.Reason, [int]$r.WatchTask, [int]$r.Apply, [int]$r.Docker)
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
    "ensure-docker" {
        $r = Invoke-CursorRamEnsureDocker
        Write-Host ("ensure-docker ok={0} reason={1}" -f [int]$r.Ok, $r.Reason)
        if ($r.Reason -eq "lock") { exit 3 }
        if (-not $r.Ok) { exit 1 }
        exit 0
    }
}
