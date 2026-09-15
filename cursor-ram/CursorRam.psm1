#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:RuntimeDir = Join-Path $env:LOCALAPPDATA "KIT\cursor-ram"
$script:FactsProvider = $null
$script:WslStopper = $null
$script:DesktopWslRoot = "D:\docker\DockerDesktopWSL"

function Set-CursorRamRuntimeDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:RuntimeDir = $Path
}

function Get-CursorRamRuntimeDir { return $script:RuntimeDir }

function Get-CursorRamLockPath { return (Join-Path $script:RuntimeDir "cursor-ram.lock") }
function Get-CursorRamLogPath { return (Join-Path $script:RuntimeDir "cursor-ram.log") }
function Get-CursorRamHoldPath { return (Join-Path $script:RuntimeDir "hold.json") }

function Initialize-CursorRamRuntimeDir {
    if (-not (Test-Path -LiteralPath $script:RuntimeDir)) {
        New-Item -ItemType Directory -Path $script:RuntimeDir -Force | Out-Null
    }
}

function Write-CursorRamLog {
    param([string]$Message)
    Initialize-CursorRamRuntimeDir
    $line = "{0} {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath (Get-CursorRamLogPath) -Value $line -Encoding UTF8
}

function Get-CursorRamLockInfo {
    $path = Get-CursorRamLockPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-CursorRamLockStale {
    param($Info)
    if ($null -eq $Info) { return $true }
    try {
        if ((Get-Date) -gt [datetime]$Info.expiresAt) { return $true }
    } catch {
        return $true
    }
    try {
        [void](Get-Process -Id ([int]$Info.pid) -ErrorAction Stop)
        return $false
    } catch {
        return $true
    }
}

function Lock-CursorRam {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$TtlSec = 60
    )
    Initialize-CursorRamRuntimeDir
    $path = Get-CursorRamLockPath
    if (Test-Path -LiteralPath $path) {
        $info = Get-CursorRamLockInfo
        if (-not (Test-CursorRamLockStale $info)) { return $false }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $payload = @{
        pid       = $PID
        command   = $Command
        expiresAt = (Get-Date).AddSeconds($TtlSec).ToString("o")
    } | ConvertTo-Json -Compress
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($payload)
            $fs.Write($bytes, 0, $bytes.Length)
        } finally {
            $fs.Close()
        }
        return $true
    } catch {
        return $false
    }
}

function Unlock-CursorRam {
    $info = Get-CursorRamLockInfo
    if ($null -eq $info) { return }
    if ([int]$info.pid -ne $PID) { return }
    $path = Get-CursorRamLockPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function ConvertFrom-CursorRamWslList {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $t = $Text -replace "`0", ""
    $rows = @()
    foreach ($line in ($t -split "\r?\n")) {
        $s = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -match '^NAME\s+STATE') { continue }
        $s = $s -replace '^\*\s*', ""
        if ($s -match '^(?<name>\S+)\s+(?<state>Running|Stopped|Starting|Stopping)\b') {
            $rows += [pscustomobject]@{
                Name  = $Matches.name
                State = $Matches.state
            }
        }
    }
    return $rows
}

function ConvertTo-CursorRamStatus {
    param(
        [Parameter(Mandatory = $true)]$Facts
    )
    $desktop = [bool]$Facts.DesktopProcess -or [bool]$Facts.DesktopDistro -or [bool]$Facts.DesktopVhdx -or [bool]$Facts.DesktopStartup
    $wslLeak = [bool]$Facts.WslRunning -and (-not [bool]$Facts.HoldActive) -and (-not [bool]$Facts.Building)
    $preview = [bool]$Facts.NativePreview -or ([int]$Facts.TscPreview -gt 0)
    $play = [bool]$Facts.PlaywrightMcp
    $reason = "ok"
    $ok = $true
    if ($desktop) { $ok = $false; $reason = "desktop" }
    elseif ($wslLeak) { $ok = $false; $reason = "wsl" }
    elseif ($preview) { $ok = $false; $reason = "preview" }
    elseif ($play) { $ok = $false; $reason = "playwright" }
    return [pscustomobject]@{
        Ok              = $ok
        Reason          = $reason
        FreeGB          = [double]$Facts.FreeGB
        CompressionGB   = [double]$Facts.CompressionGB
        DesktopProcess  = [bool]$Facts.DesktopProcess
        DesktopDistro   = [bool]$Facts.DesktopDistro
        DesktopVhdx     = [bool]$Facts.DesktopVhdx
        DesktopStartup  = [bool]$Facts.DesktopStartup
        WslRunning      = [bool]$Facts.WslRunning
        HoldActive      = [bool]$Facts.HoldActive
        Building        = [bool]$Facts.Building
        NativePreview   = [bool]$Facts.NativePreview
        TscPreview      = [int]$Facts.TscPreview
        PlaywrightMcp   = [bool]$Facts.PlaywrightMcp
        CursorWindows   = [int]$Facts.CursorWindows
        Vinext          = [int]$Facts.Vinext
        Uni             = [int]$Facts.Uni
    }
}

function Format-CursorRamStatusLine {
    param($Status)
    return ("ok={0} reason={1} free={2} compression={3} desktop={4} distro={5} vhdx={6} start={7} wsl={8} hold={9} build={10} preview={11} tsc={12} playwright={13} windows={14} vinext={15} uni={16}" -f `
        [int]$Status.Ok, $Status.Reason, $Status.FreeGB, $Status.CompressionGB, `
        [int]$Status.DesktopProcess, [int]$Status.DesktopDistro, [int]$Status.DesktopVhdx, [int]$Status.DesktopStartup, `
        [int]$Status.WslRunning, [int]$Status.HoldActive, [int]$Status.Building, `
        [int]$Status.NativePreview, $Status.TscPreview, [int]$Status.PlaywrightMcp, `
        $Status.CursorWindows, $Status.Vinext, $Status.Uni)
}

function Set-CursorRamFactsProvider {
    param($Block)
    $script:FactsProvider = $Block
}

function Get-CursorRamWslRaw {
    try {
        $text = & wsl.exe -l -v 2>$null | Out-String
        return ($text -replace "`0", "")
    } catch {
        return ""
    }
}

function Get-CursorRamFacts {
    if ($null -ne $script:FactsProvider) {
        return & $script:FactsProvider
    }
    $os = Get-CimInstance Win32_OperatingSystem
    $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $comp = 0.0
    $mcp = Get-Process -Name "Memory Compression" -ErrorAction SilentlyContinue
    if ($mcp) { $comp = [math]::Round($mcp.WorkingSet64 / 1GB, 2) }
    $procs = @(Get-CimInstance Win32_Process | Select-Object Name, CommandLine, ProcessId)
    $desktopProc = $false
    $building = $false
    $tscPreview = 0
    $vinext = 0
    $uni = 0
    foreach ($p in $procs) {
        $n = [string]$p.Name
        $c = [string]$p.CommandLine
        if ($n -match '^(Docker Desktop|com\.docker\.backend|com\.docker\.build)\.exe$') { $desktopProc = $true }
        if (Test-CursorRamDockerBusy -Name $n -CommandLine $c) { $building = $true }
        if ($n -eq "tsc.exe" -and $c -match 'native-preview') { $tscPreview++ }
        if ($c -match 'vinext') { $vinext++ }
        if ($c -match 'vite-plugin-uni|uni\.js') { $uni++ }
    }
    $rows = @(ConvertFrom-CursorRamWslList (Get-CursorRamWslRaw))
    $desktopDistro = $false
    $wslRunning = $false
    foreach ($r in $rows) {
        if ($r.Name -match 'docker-desktop') { $desktopDistro = $true }
        if ($r.State -eq "Running") { $wslRunning = $true }
    }
    $startup = $false
    $starts = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    foreach ($st in $starts) {
        if ([string]$st.Command -match 'Docker Desktop') { $startup = $true }
    }
    $play = $false
    $mcpPath = Join-Path $env:USERPROFILE ".cursor\mcp.json"
    if (Test-Path -LiteralPath $mcpPath) {
        try {
            $j = Get-Content -LiteralPath $mcpPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $j.mcpServers -and $null -ne $j.mcpServers.playwright) { $play = $true }
        } catch { }
    }
    $extRoot = Join-Path $env:USERPROFILE ".cursor\extensions"
    $preview = $false
    if (Test-Path -LiteralPath $extRoot) {
        $preview = @(Get-ChildItem -LiteralPath $extRoot -Directory -Filter "typescriptteam.native-preview-*" -ErrorAction SilentlyContinue).Count -gt 0
    }
    $windows = @((Get-Process Cursor -ErrorAction SilentlyContinue) | Where-Object { $_.MainWindowTitle }).Count
    return [pscustomobject]@{
        FreeGB          = $free
        CompressionGB   = $comp
        DesktopProcess  = $desktopProc
        DesktopDistro   = $desktopDistro
        DesktopVhdx     = (Test-Path -LiteralPath $script:DesktopWslRoot)
        DesktopStartup  = $startup
        WslRunning      = $wslRunning
        HoldActive      = (Test-CursorRamHoldActive)
        Building        = $building
        NativePreview   = $preview
        TscPreview      = $tscPreview
        PlaywrightMcp   = $play
        CursorWindows   = $windows
        Vinext          = $vinext
        Uni             = $uni
    }
}

function Get-CursorRamStatus {
    return (ConvertTo-CursorRamStatus -Facts (Get-CursorRamFacts))
}

function Set-CursorRamWslStopper {
    param($Block)
    $script:WslStopper = $Block
}

function Test-CursorRamHoldActive {
    $h = Get-CursorRamHold
    if ($null -eq $h) { return $false }
    try {
        return ((Get-Date) -lt [datetime]$h.until)
    } catch {
        return $false
    }
}

function Get-CursorRamHold {
    $path = Get-CursorRamHoldPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Set-CursorRamHold {
    param([int]$Hours = 2)
    Initialize-CursorRamRuntimeDir
    $payload = @{
        until = (Get-Date).AddHours($Hours).ToString("o")
        hours = $Hours
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Get-CursorRamHoldPath), $payload)
}

function Clear-CursorRamHold {
    $path = Get-CursorRamHoldPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Stop-CursorRamWsl {
    if ($null -ne $script:WslStopper) {
        & $script:WslStopper
        return
    }
    & wsl.exe --shutdown | Out-Null
}

function Invoke-CursorRamWatch {
    if (-not (Lock-CursorRam -Command "watch" -TtlSec 60)) {
        return [pscustomobject]@{ Ok = $false; Changed = $false; Reason = "lock" }
    }
    try {
        if (Test-CursorRamHoldActive) {
            return [pscustomobject]@{ Ok = $true; Changed = $false; Reason = "hold" }
        }
        $facts = Get-CursorRamFacts
        if ([bool]$facts.Building) {
            return [pscustomobject]@{ Ok = $true; Changed = $false; Reason = "build" }
        }
        if ([bool]$facts.WslRunning) {
            Stop-CursorRamWsl
            Write-CursorRamLog "watch shutdown"
            return [pscustomobject]@{ Ok = $true; Changed = $true; Reason = "shutdown" }
        }
        return [pscustomobject]@{ Ok = $true; Changed = $false; Reason = "idle" }
    } finally {
        Unlock-CursorRam
    }
}

$script:McpPath = Join-Path $env:USERPROFILE ".cursor\mcp.json"
$script:McpSidecarPath = Join-Path $env:USERPROFILE ".cursor\mcp.playwright.json"
$script:ExtensionRoot = Join-Path $env:USERPROFILE ".cursor\extensions"

function Set-CursorRamMcpPaths {
    param([string]$McpPath, [string]$SidecarPath)
    $script:McpPath = $McpPath
    $script:McpSidecarPath = $SidecarPath
}

function Set-CursorRamExtensionRoot {
    param([string]$Path)
    $script:ExtensionRoot = $Path
}

function Move-CursorRamPlaywrightMcp {
    param([string]$McpJson)
    if ([string]::IsNullOrWhiteSpace($McpJson)) {
        return [pscustomobject]@{ Json = $McpJson; Sidecar = $null; Moved = $false }
    }
    $j = $McpJson | ConvertFrom-Json
    $hasPlaywright = $false
    if ($null -ne $j.PSObject.Properties['mcpServers'] -and $null -ne $j.mcpServers) {
        $hasPlaywright = $null -ne $j.mcpServers.PSObject.Properties['playwright']
    }
    if (-not $hasPlaywright) {
        return [pscustomobject]@{ Json = $McpJson; Sidecar = $null; Moved = $false }
    }
    $play = $j.mcpServers.playwright
    $j.mcpServers.PSObject.Properties.Remove("playwright")
    $sideObj = [pscustomobject]@{
        mcpServers = [pscustomobject]@{ playwright = $play }
    }
    return [pscustomobject]@{
        Json    = ($j | ConvertTo-Json -Depth 12)
        Sidecar = ($sideObj | ConvertTo-Json -Depth 12)
        Moved   = $true
    }
}

function Remove-CursorRamNativePreviewDirs {
    $removed = 0
    if (-not (Test-Path -LiteralPath $script:ExtensionRoot)) {
        return $removed
    }
    $dirs = @(Get-ChildItem -LiteralPath $script:ExtensionRoot -Directory -Filter "typescriptteam.native-preview-*" -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force
        $removed++
    }
    return $removed
}

function Invoke-CursorRamApply {
    if (-not (Lock-CursorRam -Command "apply" -TtlSec 120)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock"; WslStopped = $false; McpMoved = $false; PreviewRemoved = $false }
    }
    try {
        $wslStopped = $false
        if (-not (Test-CursorRamHoldActive)) {
            $facts = Get-CursorRamFacts
            if ([bool]$facts.WslRunning) {
                Stop-CursorRamWsl
                $wslStopped = $true
            }
        }
        $mcpMoved = $false
        if (Test-Path -LiteralPath $script:McpPath) {
            $raw = Get-Content -LiteralPath $script:McpPath -Raw -Encoding UTF8
            $moved = Move-CursorRamPlaywrightMcp $raw
            if ($moved.Moved) {
                [System.IO.File]::WriteAllText($script:McpPath, $moved.Json)
                [System.IO.File]::WriteAllText($script:McpSidecarPath, $moved.Sidecar)
                $mcpMoved = $true
            }
        }
        $previewRemoved = (Remove-CursorRamNativePreviewDirs) -gt 0
        Write-CursorRamLog ("apply wsl={0} mcp={1} preview={2}" -f [int]$wslStopped, [int]$mcpMoved, [int]$previewRemoved)
        return [pscustomobject]@{
            Ok             = $true
            Reason         = "ok"
            WslStopped     = $wslStopped
            McpMoved       = $mcpMoved
            PreviewRemoved = $previewRemoved
        }
    } finally {
        Unlock-CursorRam
    }
}

$script:PackRunner = $null
$script:ParkStopper = $null
$script:UbuntuName = "Ubuntu"

function Set-CursorRamPackRunner { param($Block) $script:PackRunner = $Block }
function Set-CursorRamParkStopper { param($Block) $script:ParkStopper = $Block }
function Set-CursorRamUbuntuName { param([string]$Name) $script:UbuntuName = $Name }

function ConvertTo-CursorRamWslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)
    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    $root = [System.IO.Path]::GetPathRoot($full)
    $drive = $root.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring($root.Length).Replace("\", "/")
    return "/mnt/$drive/$rest"
}

function Invoke-CursorRamPack {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )
    if ($null -eq $Arguments) { $Arguments = @() }
    $packArgs = @($Arguments)
    if ($packArgs.Count -gt 0 -and $packArgs[0] -eq "--") {
        $packArgs = @($packArgs | Select-Object -Skip 1)
    }
    if ($packArgs.Count -lt 1) {
        return [pscustomobject]@{ Ok = $false; Reason = "no-command"; WslCwd = $null; Command = $null; ExitCode = 1 }
    }
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = (Get-Location).Path
    }
    $cwd = ConvertTo-CursorRamWslPath $WorkingDirectory
    $cmd = ($packArgs -join " ")
    if (-not (Lock-CursorRam -Command "pack" -TtlSec 7200)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock"; WslCwd = $cwd; Command = $cmd; ExitCode = 3 }
    }
    try {
        if ($null -eq $script:PackRunner) {
            $names = @((ConvertFrom-CursorRamWslList (Get-CursorRamWslRaw)) | ForEach-Object { $_.Name })
            if ($names -notcontains $script:UbuntuName) {
                return [pscustomobject]@{ Ok = $false; Reason = "no-ubuntu"; WslCwd = $cwd; Command = $cmd; ExitCode = 1 }
            }
        }
        Set-CursorRamHold -Hours 2
        $exit = 0
        if ($null -ne $script:PackRunner) {
            $ran = & $script:PackRunner $cwd $cmd
            $exit = [int]$ran.ExitCode
        } else {
            $inner = ("cd '{0}' && {1}" -f $cwd, $cmd)
            & wsl.exe -d $script:UbuntuName -- bash -lc $inner
            $exit = $LASTEXITCODE
        }
        Clear-CursorRamHold
        $null = Invoke-CursorRamApply
        return [pscustomobject]@{
            Ok       = ($exit -eq 0)
            Reason   = $(if ($exit -eq 0) { "ok" } else { "pack-failed" })
            WslCwd   = $cwd
            Command  = $cmd
            ExitCode = $exit
        }
    } finally {
        Unlock-CursorRam
    }
}

function Select-CursorRamParkTargets {
    param(
        $Processes,
        [switch]$Dev
    )
    $out = @()
    if (-not $Dev) { return $out }
    foreach ($p in @($Processes)) {
        $n = [string]$p.Name
        $c = [string]$p.CommandLine
        if ($n -eq "Cursor.exe") { continue }
        if ($c -match 'vinext' -or $c -match 'vite-plugin-uni|uni\.js' -or $c -match 'mcp-chrome|@playwright/mcp') {
            $out += $p
        }
    }
    return $out
}

function Invoke-CursorRamPark {
    param([switch]$Dev)
    if (-not (Lock-CursorRam -Command "park" -TtlSec 60)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock"; Stopped = 0 }
    }
    try {
        $procs = @(Get-CimInstance Win32_Process | Select-Object Name, CommandLine, ProcessId)
        $targets = @(Select-CursorRamParkTargets -Processes $procs -Dev:$Dev)
        $n = 0
        foreach ($t in $targets) {
            if ($null -ne $script:ParkStopper) {
                & $script:ParkStopper $t
            } else {
                Stop-Process -Id ([int]$t.ProcessId) -Force -ErrorAction SilentlyContinue
            }
            $n++
        }
        return [pscustomobject]@{ Ok = $true; Reason = "ok"; Stopped = $n }
    } finally {
        Unlock-CursorRam
    }
}

$script:TaskRunner = $null
$script:PurgeHook = $null
$script:WslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$script:WatchTask = "KIT-CursorRam-Watch"
$script:WatchLogonTask = "KIT-CursorRam-WatchLogon"

function Set-CursorRamDesktopWslRoot { param([string]$Path) $script:DesktopWslRoot = $Path }
function Set-CursorRamWslConfigPath { param([string]$Path) $script:WslConfigPath = $Path }
function Set-CursorRamTaskRunner { param($Block) $script:TaskRunner = $Block }
function Set-CursorRamPurgeHook { param($Block) $script:PurgeHook = $Block }

function Update-CursorRamWslConfig {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { $Raw = "" }
    $text = $Raw -replace "`r`n", "`n"
    if ($text -notmatch '\[wsl2\]') {
        $text = $text.TrimEnd() + "`n[wsl2]`n"
    }
    if ($text -match '(?m)^memory=') {
        $text = [regex]::Replace($text, '(?m)^memory=.*$', "memory=3GB")
    } else {
        $text = [regex]::Replace($text, '\[wsl2\]', "[wsl2]`nmemory=3GB")
    }
    if ($text -match '(?m)^processors=') {
        $text = [regex]::Replace($text, '(?m)^processors=.*$', "processors=4")
    } else {
        $text = [regex]::Replace($text, '\[wsl2\]', "[wsl2]`nprocessors=4")
    }
    return ($text -replace "`n", "`r`n")
}

function Invoke-CursorRamSchtasks {
    param([string[]]$ArgumentList)
    if ($null -ne $script:TaskRunner) {
        return [bool](& $script:TaskRunner $ArgumentList)
    }
    & schtasks.exe @ArgumentList | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-CursorRamPurge {
    if (-not (Lock-CursorRam -Command "purge" -TtlSec 600)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock"; RemovedVhdx = $false; Unregistered = $false }
    }
    try {
        Stop-CursorRamWsl
        $unreg = $false
        $removed = $false
        if ($null -ne $script:PurgeHook) {
            $null = & $script:PurgeHook
            $unreg = $true
        } else {
            Get-Process -Name "Docker Desktop","com.docker.backend","com.docker.build" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            $svc = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne "Stopped") {
                Stop-Service -Name "com.docker.service" -Force -ErrorAction SilentlyContinue
            }
            $uninst = "C:\Program Files\Docker\Docker\Docker Desktop Installer.exe"
            if (Test-Path -LiteralPath $uninst) {
                Start-Process -FilePath $uninst -ArgumentList @("uninstall") -Wait -ErrorAction SilentlyContinue
            }
            foreach ($name in @("docker-desktop", "docker-desktop-data")) {
                & wsl.exe --unregister $name 2>$null | Out-Null
            }
            $unreg = $true
            $distros = @(ConvertFrom-CursorRamWslList (Get-CursorRamWslRaw) | ForEach-Object { $_.Name })
            if ($distros -notcontains $script:UbuntuName) {
                & wsl.exe --install -d $script:UbuntuName --no-launch | Out-Null
            }
            $engine = @'
set -e
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y docker.io
fi
sudo service docker start || true
'@
            & wsl.exe -d $script:UbuntuName -- bash -lc $engine | Out-Null
        }
        if (Test-Path -LiteralPath $script:DesktopWslRoot) {
            Remove-Item -LiteralPath $script:DesktopWslRoot -Recurse -Force
            $removed = $true
        }
        $cfgRaw = ""
        if (Test-Path -LiteralPath $script:WslConfigPath) {
            $cfgRaw = Get-Content -LiteralPath $script:WslConfigPath -Raw -Encoding UTF8
        }
        [System.IO.File]::WriteAllText($script:WslConfigPath, (Update-CursorRamWslConfig $cfgRaw))
        Write-CursorRamLog ("purge removedVhdx={0}" -f [int]$removed)
        return [pscustomobject]@{
            Ok           = $true
            Reason       = "ok"
            RemovedVhdx  = $removed
            Unregistered = $unreg
        }
    } finally {
        Unlock-CursorRam
    }
}

function Install-CursorRamHost {
    $st = Get-CursorRamStatus
    if ($st.DesktopProcess -or $st.DesktopDistro -or $st.DesktopVhdx -or $st.DesktopStartup) {
        return [pscustomobject]@{ Ok = $false; Reason = "desktop"; WatchTask = $false; Apply = $false }
    }
    $vbs = Join-Path $PSScriptRoot "cursor-ram.vbs"
    $watchTr = ('wscript.exe "{0}"' -f $vbs)
    $watchOk = (Invoke-CursorRamSchtasks @(
        "/Create", "/TN", $script:WatchTask, "/TR", $watchTr,
        "/SC", "MINUTE", "/MO", "15", "/RL", "HIGHEST", "/F"
    )) -and (Invoke-CursorRamSchtasks @(
        "/Create", "/TN", $script:WatchLogonTask, "/TR", $watchTr,
        "/SC", "ONLOGON", "/RL", "HIGHEST", "/F"
    ))
    $apply = Invoke-CursorRamApply
    return [pscustomobject]@{
        Ok        = [bool]$watchOk
        Reason    = $(if ($watchOk) { "ok" } else { "task" })
        WatchTask = [bool]$watchOk
        Apply     = [bool]$apply.Ok
    }
}

$script:DockerCliInstaller = $null
$script:UserPathStore = $null

function Set-CursorRamDockerCliInstaller { param($Block) $script:DockerCliInstaller = $Block }
function Set-CursorRamUserPathStore { param($Value) $script:UserPathStore = $Value }

function Get-CursorRamDockerBinDir { return (Join-Path $script:RuntimeDir "bin") }
function Get-CursorRamDockerCliPath { return (Join-Path (Get-CursorRamDockerBinDir) "cli\docker.exe") }
function Get-CursorRamDockerShimPath { return (Join-Path (Get-CursorRamDockerBinDir) "docker.exe") }
function Get-CursorRamDockerHostJsonPath { return (Join-Path $script:RuntimeDir "docker-host.json") }

function Get-CursorRamUserPath {
    if ($null -ne $script:UserPathStore) { return [string]$script:UserPathStore }
    return [string][Environment]::GetEnvironmentVariable("Path", "User")
}

function Set-CursorRamUserPath {
    param([string]$Value)
    if ($null -ne $script:UserPathStore) {
        $script:UserPathStore = $Value
        return
    }
    [Environment]::SetEnvironmentVariable("Path", $Value, "User")
}

function Add-CursorRamPathEntry {
    param(
        [string]$Path,
        [string]$Entry
    )
    if ([string]::IsNullOrWhiteSpace($Entry)) { return $Path }
    $norm = $Entry.TrimEnd("\")
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $parts = @($Path -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    foreach ($p in $parts) {
        if ([string]::Equals($p.TrimEnd("\"), $norm, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $Path
        }
    }
    if ($parts.Count -eq 0) { return $norm }
    return ($norm + ";" + ($parts -join ";"))
}

function Test-CursorRamDockerBusy {
    param(
        [string]$Name,
        [string]$CommandLine
    )
    $n = [string]$Name
    $c = [string]$CommandLine
    if ($c -match 'docker(\.exe)?["\s]+(build|push|buildx)\b') { return $true }
    if ($n -eq "docker.exe" -and $c -match '(^|[\s"])(build|push|buildx)\b') { return $true }
    return $false
}

function Get-CursorRamDockerEnsureFile {
    return (Join-Path $PSScriptRoot "cursor-ram.ps1")
}

function Write-CursorRamDockerHostJson {
    $payload = @{
        cli             = (Get-CursorRamDockerCliPath)
        shim            = (Get-CursorRamDockerShimPath)
        distro          = $script:UbuntuName
        ensureFile      = (Get-CursorRamDockerEnsureFile)
        "ensure-docker" = "ensure-docker"
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Get-CursorRamDockerHostJsonPath), $payload)
}

function Get-CursorRamDockerShimSource {
    return @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class CursorRamDockerShim
{
    private static int Main(string[] args)
    {
        string runtime = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar), ".."));
        string jsonPath = Path.Combine(runtime, "docker-host.json");
        string distro = ReadJsonString(jsonPath, "distro");
        if (string.IsNullOrEmpty(distro)) distro = "Ubuntu";
        string wslCwd = ToWslPath(Environment.CurrentDirectory);
        RunWsl(distro, "--", "sudo", "service", "docker", "start");
        return RunWsl(distro, "--cd", wslCwd, "--", "docker", QuoteArgs(args));
    }

    private static int RunWsl(string distro, params string[] parts)
    {
        var psi = new ProcessStartInfo();
        psi.FileName = "wsl.exe";
        psi.Arguments = "-d " + distro + " " + JoinParts(parts);
        psi.UseShellExecute = false;
        using (Process child = Process.Start(psi))
        {
            if (child == null) return 1;
            child.WaitForExit();
            return child.ExitCode;
        }
    }

    private static string JoinParts(string[] parts)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < parts.Length; i++)
        {
            if (i > 0) sb.Append(' ');
            sb.Append(parts[i]);
        }
        return sb.ToString();
    }

    private static string ToWslPath(string winPath)
    {
        string full = Path.GetFullPath(winPath);
        char drive = char.ToLowerInvariant(full[0]);
        string rest = full.Substring(2).Replace('\\', '/');
        return "/mnt/" + drive + rest;
    }

    private static string ReadJsonString(string path, string key)
    {
        if (!File.Exists(path)) return "";
        string json = File.ReadAllText(path);
        string pat = "\"" + key + "\"";
        int i = json.IndexOf(pat, StringComparison.Ordinal);
        if (i < 0) return "";
        i = json.IndexOf(':', i);
        if (i < 0) return "";
        i = json.IndexOf('"', i + 1);
        if (i < 0) return "";
        int j = json.IndexOf('"', i + 1);
        if (j < 0) return "";
        return json.Substring(i + 1, j - i - 1).Replace("\\\\", "\\");
    }

    private static string QuoteArgs(string[] args)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) sb.Append(' ');
            string a = args[i] ?? "";
            if (a.IndexOfAny(new[] { ' ', '"' }) >= 0)
            {
                sb.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
            }
            else
            {
                sb.Append(a);
            }
        }
        return sb.ToString();
    }
}
'@
}

function Install-CursorRamCompiledExe {
    param(
        [string]$Source,
        [string]$Output
    )
    $dir = Split-Path -Parent $Output
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Output) {
        Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
    }
    try {
        Add-Type -TypeDefinition $Source -OutputAssembly $Output -OutputType ConsoleApplication
    } catch {
        Write-CursorRamLog ("compile failed {0}: {1}" -f $Output, $_.Exception.Message)
        return $false
    }
    return (Test-Path -LiteralPath $Output)
}

function Install-CursorRamDockerHost {
    Initialize-CursorRamRuntimeDir
    $cli = Get-CursorRamDockerCliPath
    $shim = Get-CursorRamDockerShimPath
    $bin = Get-CursorRamDockerBinDir
    if (-not (Test-Path -LiteralPath $bin)) {
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
    }
    if ($null -ne $script:DockerCliInstaller) {
        $ok = [bool](& $script:DockerCliInstaller $cli $shim)
        if (-not $ok) {
            return [pscustomobject]@{ Ok = $false; Reason = "cli"; Cli = $cli; Shim = $shim }
        }
    } else {
        if (-not (Install-CursorRamCompiledExe -Source (Get-CursorRamDockerShimSource) -Output $shim)) {
            return [pscustomobject]@{ Ok = $false; Reason = "shim"; Cli = $cli; Shim = $shim }
        }
    }
    Write-CursorRamDockerHostJson
    $next = Add-CursorRamPathEntry -Path (Get-CursorRamUserPath) -Entry $bin
    Set-CursorRamUserPath $next
    $env:PATH = Add-CursorRamPathEntry -Path $env:PATH -Entry $bin
    Write-CursorRamLog "docker host installed"
    return [pscustomobject]@{
        Ok     = $true
        Reason = "ok"
        Cli    = $cli
        Shim   = $shim
    }
}

function Invoke-CursorRamEnsureDocker {
    if (-not (Lock-CursorRam -Command "ensure-docker" -TtlSec 120)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock" }
    }
    try {
        & wsl.exe -d $script:UbuntuName -- sudo service docker start | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ Ok = $false; Reason = "docker" }
        }
        Write-CursorRamLog "docker engine started"
        return [pscustomobject]@{ Ok = $true; Reason = "ok" }
    } finally {
        Unlock-CursorRam
    }
}
