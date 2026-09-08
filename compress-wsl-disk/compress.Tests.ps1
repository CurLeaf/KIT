#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1 = Join-Path $here "compress.ps1"

Describe "compress.ps1 restarts Docker after compact" {
    It "defines Start-DockerDesktopFully that waits for the daemon" {
        $raw = Get-Content -LiteralPath $ps1 -Raw -Encoding UTF8
        $raw | Should Match "function Start-DockerDesktopFully"
        $fn = [regex]::Match($raw, "function Start-DockerDesktopFully[\s\S]*?\n\}")
        $fn.Success | Should Be $true
        $fn.Value | Should Match "Docker Desktop\.exe"
        $fn.Value | Should Match "Test-DockerDaemonReady"
    }

    It "force-kills the full Docker stack instead of returning early on an empty snapshot" {
        $raw = Get-Content -LiteralPath $ps1 -Raw -Encoding UTF8
        $fn = [regex]::Match($raw, "function Stop-DockerDesktopFully[\s\S]*?\nfunction ")
        $fn.Success | Should Be $true
        $fn.Value | Should Match "taskkill"
        $fn.Value | Should Match "/F"
        $fn.Value | Should Match "com\.docker\.service"
        $fn.Value | Should Not Match "CloseMainWindow"
        $names = [regex]::Match($raw, "function Get-DockerStackProcessNames[\s\S]*?\nfunction ")
        $names.Success | Should Be $true
        $names.Value | Should Match "com\.docker\.backend"
        $names.Value | Should Match "com\.docker\.dev-envs"
        $names.Value | Should Match "vpnkit"
    }

    It "force-stops leftover WSL vm processes after wsl --shutdown" {
        $raw = Get-Content -LiteralPath $ps1 -Raw -Encoding UTF8
        $fn = [regex]::Match($raw, "function Stop-WslFully[\s\S]*?\nfunction ")
        $fn.Success | Should Be $true
        $fn.Value | Should Match "wsl --shutdown"
        $fn.Value | Should Match "vmmemWSL"
        $fn.Value | Should Match "Stop-ProcessImagesForce"
        $helper = [regex]::Match($raw, "function Stop-ProcessImagesForce[\s\S]*?\nfunction ")
        $helper.Success | Should Be $true
        $helper.Value | Should Match "taskkill"
        $helper.Value | Should Match "/F"
    }

    It "calls Start-DockerDesktopFully after compact instead of only printing a hint" {
        $raw = Get-Content -LiteralPath $ps1 -Raw -Encoding UTF8
        $doneAt = $raw.IndexOf('[6/6] Done')
        $doneAt | Should BeGreaterThan 0
        $after = $raw.Substring($doneAt)
        $after | Should Match "Start-DockerDesktopFully"
        $after | Should Not Match "You can restart Docker Desktop now\."
    }
}
