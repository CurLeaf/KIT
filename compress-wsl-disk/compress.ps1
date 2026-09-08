# WSL/Docker VHDX Compact Script
# Run PowerShell as Administrator

# ============================================================
# Global paths (replace these if your Docker data is elsewhere)
# Default install:  Join-Path $env:LOCALAPPDATA "Docker\wsl"
# Current machine:  D:\docker\DockerDesktopWSL
# ============================================================
$script:DockerWslRoot = "D:\docker\DockerDesktopWSL"
$script:DockerDataVHDX = Join-Path $DockerWslRoot "disk\docker_data.vhdx"
$script:Ext4VHDX = Join-Path $DockerWslRoot "main\ext4.vhdx"
# ============================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "WSL/Docker VHDX Compact Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "VHDX paths:" -ForegroundColor White
Write-Host "  Root:            $DockerWslRoot" -ForegroundColor Gray
Write-Host "  docker_data.vhdx: $DockerDataVHDX" -ForegroundColor Gray
Write-Host "  ext4.vhdx:        $Ext4VHDX" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $DockerDataVHDX) -or -not (Test-Path $Ext4VHDX)) {
    Write-Host "ERROR: VHDX file(s) not found. Update `$DockerWslRoot at the top of this script." -ForegroundColor Red
    if (-not (Test-Path $DockerDataVHDX)) {
        Write-Host "  Missing: $DockerDataVHDX" -ForegroundColor Red
    }
    if (-not (Test-Path $Ext4VHDX)) {
        Write-Host "  Missing: $Ext4VHDX" -ForegroundColor Red
    }
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

function Test-DockerDaemonReady {
    param([int]$TimeoutSeconds = 20)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "docker"
    $psi.Arguments = "version --format {{.Server.Version}}"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        return $false
    }
    return ($process.ExitCode -eq 0)
}

function Get-DockerCliConflicts {
    Get-CimInstance Win32_Process -Filter "Name='docker.exe'" -ErrorAction SilentlyContinue
}

function Format-CleanupElapsed {
    param([int]$Seconds)
    return "{0:00}:{1:00}" -f [math]::Floor($Seconds / 60), ($Seconds % 60)
}

function Write-CleanupProgressPanel {
    param(
        [hashtable]$Stats,
        [int]$ElapsedSec,
        [string]$Phase,
        [string]$Latest,
        [int]$PanelTop,
        [char]$Spinner
    )

    $rate = if ($ElapsedSec -gt 0) {
        [math]::Round(($Stats.TotalItems / $ElapsedSec), 1)
    } else { 0 }

    $latestShort = if ([string]::IsNullOrWhiteSpace($Latest)) {
        "(waiting for docker output...)"
    } elseif ($Latest.Length -gt 72) {
        $Latest.Substring(0, 69) + "..."
    } else {
        $Latest
    }

    $barLen = 24
    $pulse = [math]::Min($barLen - 1, [int](($ElapsedSec * 2) % $barLen))
    $bar = ("=" * $pulse) + ">" + ("." * ($barLen - $pulse - 1))

    $lines = @(
        ("  {0} Cleaning unused Docker data" -f $Spinner),
        ("  Time {0}  |  Items {1}  |  Rate {2}/s  |  [{3}]" -f (Format-CleanupElapsed $ElapsedSec), $Stats.TotalItems, $rate, $bar),
        ("  Containers:{0,-4} Networks:{1,-4} Images:{2,-4} Layers:{3,-4} Volumes:{4,-4} Cache:{5,-4}" -f `
            $Stats.Containers, $Stats.Networks, $Stats.Images, $Stats.Layers, $Stats.Volumes, $Stats.Cache),
        ("  Phase:  {0}" -f $Phase),
        ("  Latest: {0}" -f $latestShort)
    )

    try {
        $width = [Math]::Max(80, [Console]::WindowWidth - 1)
        [Console]::SetCursorPosition(0, $PanelTop)
        foreach ($line in $lines) {
            $padded = if ($line.Length -ge $width) { $line.Substring(0, $width) } else { $line.PadRight($width) }
            [Console]::WriteLine($padded)
        }
    }
    catch {
        # Fallback when console cursor control is unavailable
        Write-Host ("`r  {0} {1} | items={2} rate={3}/s | {4} | {5}" -f `
            $Spinner, (Format-CleanupElapsed $ElapsedSec), $Stats.TotalItems, $rate, $Phase, $latestShort) -NoNewline
    }
}

function Invoke-DockerCleanup {
    param([int]$TimeoutMinutes = 30)

    $stdoutFile = Join-Path $env:TEMP "docker-prune-out.txt"
    $stderrFile = Join-Path $env:TEMP "docker-prune-err.txt"
    Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

    Write-Host "  Starting docker system prune (streaming progress)..." -ForegroundColor Gray
    Write-Host ""

    $process = Start-Process -FilePath "docker" `
        -ArgumentList "system", "prune", "-a", "--volumes", "-f" `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile

    $startTime = Get-Date
    $warnedMidConflict = $false
    $spinnerFrames = @('|', '/', '-', '\')
    $spinIndex = 0
    $phase = "starting"
    $latest = ""
    $reclaimed = ""
    $stats = @{
        Containers = 0
        Networks   = 0
        Images     = 0
        Layers     = 0
        Volumes    = 0
        Cache      = 0
        TotalItems = 0
    }

    # Reserve 5 lines for the live panel
    $panelTop = [Console]::CursorTop
    1..5 | ForEach-Object { Write-Host "" }

    $stream = $null
    $reader = $null
    for ($i = 0; $i -lt 20 -and -not $reader; $i++) {
        try {
            if (Test-Path $stdoutFile) {
                $stream = [System.IO.File]::Open($stdoutFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $reader = New-Object System.IO.StreamReader($stream)
            }
        }
        catch { }
        if (-not $reader) { Start-Sleep -Milliseconds 200 }
    }

    while ($true) {
        $process.Refresh()
        $stillAlive = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        $exited = $process.HasExited -or (-not $stillAlive)

        if ($reader) {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $trim = $line.Trim()
                if (-not $trim) { continue }

                switch -Regex ($trim) {
                    '^Deleted Containers:' {
                        $phase = "deleting containers"
                        Write-Host ""
                        Write-Host "  >> Phase: deleting containers" -ForegroundColor Cyan
                        $panelTop = [Console]::CursorTop
                        1..5 | ForEach-Object { Write-Host "" }
                    }
                    '^Deleted Networks:' {
                        $phase = "deleting networks"
                        Write-Host ""
                        Write-Host "  >> Phase: deleting networks" -ForegroundColor Cyan
                        $panelTop = [Console]::CursorTop
                        1..5 | ForEach-Object { Write-Host "" }
                    }
                    '^Deleted Images:' {
                        $phase = "deleting images"
                        Write-Host ""
                        Write-Host "  >> Phase: deleting images" -ForegroundColor Cyan
                        $panelTop = [Console]::CursorTop
                        1..5 | ForEach-Object { Write-Host "" }
                    }
                    '^Deleted Volumes:' {
                        $phase = "deleting volumes"
                        Write-Host ""
                        Write-Host "  >> Phase: deleting volumes" -ForegroundColor Cyan
                        $panelTop = [Console]::CursorTop
                        1..5 | ForEach-Object { Write-Host "" }
                    }
                    '^Deleted build cache' {
                        $phase = "deleting build cache"
                        Write-Host ""
                        Write-Host "  >> Phase: deleting build cache" -ForegroundColor Cyan
                        $panelTop = [Console]::CursorTop
                        1..5 | ForEach-Object { Write-Host "" }
                    }
                    '^Total reclaimed space:' {
                        $reclaimed = $trim
                        $phase = "finishing"
                        $latest = $trim
                    }
                    '^untagged:' {
                        $stats.Images++
                        $stats.TotalItems++
                        $latest = $trim.Substring(10).Trim()
                    }
                    '^deleted: sha256:' {
                        $stats.Layers++
                        $stats.TotalItems++
                        $latest = $trim
                    }
                    default {
                        if ($phase -eq "deleting containers") {
                            $stats.Containers++
                            $stats.TotalItems++
                            $latest = $trim
                        }
                        elseif ($phase -eq "deleting networks") {
                            $stats.Networks++
                            $stats.TotalItems++
                            $latest = $trim
                        }
                        elseif ($phase -eq "deleting volumes") {
                            $stats.Volumes++
                            $stats.TotalItems++
                            $latest = $trim
                        }
                        elseif ($phase -eq "deleting build cache") {
                            $stats.Cache++
                            $stats.TotalItems++
                            $latest = $trim
                        }
                        elseif ($phase -eq "deleting images" -and $trim -match '^[0-9a-f]{12,}$') {
                            $stats.Layers++
                            $stats.TotalItems++
                            $latest = $trim
                        }
                        elseif ($trim -match '^[0-9a-z]{20,}$') {
                            # dangling build-cache / content IDs without section header yet
                            if ($phase -eq "starting") { $phase = "deleting build cache" }
                            $stats.Cache++
                            $stats.TotalItems++
                            $latest = $trim
                        }
                    }
                }
            }
        }
        elseif (Test-Path $stdoutFile) {
            try {
                $stream = [System.IO.File]::Open($stdoutFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $reader = New-Object System.IO.StreamReader($stream)
            }
            catch { }
        }

        $elapsedSec = [math]::Floor(((Get-Date) - $startTime).TotalSeconds)
        $spinIndex = ($spinIndex + 1) % $spinnerFrames.Count
        Write-CleanupProgressPanel -Stats $stats -ElapsedSec $elapsedSec -Phase $phase -Latest $latest -PanelTop $panelTop -Spinner $spinnerFrames[$spinIndex]

        if ($exited) {
            # Drain and parse remaining output after process exit
            Start-Sleep -Milliseconds 400
            if ($reader) {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) { break }
                    $trim = $line.Trim()
                    if (-not $trim) { continue }
                    if ($trim -like 'Total reclaimed space:*') {
                        $reclaimed = $trim
                        $latest = $trim
                        $phase = "finishing"
                    }
                    elseif ($trim.StartsWith('untagged:')) {
                        $stats.Images++
                        $stats.TotalItems++
                        $latest = $trim.Substring(10).Trim()
                    }
                    elseif ($trim.StartsWith('deleted: sha256:')) {
                        $stats.Layers++
                        $stats.TotalItems++
                    }
                    elseif ($trim -match '^[0-9a-z]{20,}$') {
                        $stats.Cache++
                        $stats.TotalItems++
                    }
                }
            }
            if (-not $reclaimed -and (Test-Path $stdoutFile)) {
                $reclaimedLine = Get-Content $stdoutFile -ErrorAction SilentlyContinue |
                    Where-Object { $_ -like 'Total reclaimed space:*' } |
                    Select-Object -Last 1
                if ($reclaimedLine) { $reclaimed = $reclaimedLine }
            }
            $elapsedSec = [math]::Floor(((Get-Date) - $startTime).TotalSeconds)
            Write-CleanupProgressPanel -Stats $stats -ElapsedSec $elapsedSec -Phase "done" -Latest $latest -PanelTop $panelTop -Spinner '*'
            break
        }

        if ($elapsedSec -ge ($TimeoutMinutes * 60)) {
            Write-Host ""
            Write-Host "  Cleanup timed out after ${TimeoutMinutes} minutes. Docker may be stuck." -ForegroundColor Red
            $choice = Read-Host "  [K]ill cleanup process / [W]ait more"
            if ($choice -eq "k" -or $choice -eq "K") {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                if ($reader) { $reader.Dispose() }
                if ($stream) { $stream.Dispose() }
                return $false
            }
            $startTime = $startTime.AddMinutes(-5)
            $panelTop = [Console]::CursorTop
            1..5 | ForEach-Object { Write-Host "" }
        }

        $newConflicts = Get-DockerCliConflicts | Where-Object {
            $_.ProcessId -ne $process.Id -and
            $_.CommandLine -notmatch '\b(stats|version|ps|images|info|inspect|events)\b'
        }
        if ($newConflicts -and -not $warnedMidConflict) {
            Write-Host ""
            Write-Host "  Another docker CLI process started during cleanup:" -ForegroundColor Red
            foreach ($conflict in $newConflicts) {
                Write-Host ("    PID {0}: {1}" -f $conflict.ProcessId, $conflict.CommandLine) -ForegroundColor Red
            }
            Write-Host "  Waiting for current cleanup to finish is recommended." -ForegroundColor Yellow
            $warnedMidConflict = $true
            $panelTop = [Console]::CursorTop
            1..5 | ForEach-Object { Write-Host "" }
        }

        Start-Sleep -Milliseconds 400
    }

    if ($reader) { $reader.Dispose() }
    if ($stream) { $stream.Dispose() }

    Write-Host ""
    Write-Host ("  Summary: containers={0} networks={1} images={2} layers={3} volumes={4} cache={5}" -f `
        $stats.Containers, $stats.Networks, $stats.Images, $stats.Layers, $stats.Volumes, $stats.Cache) -ForegroundColor White
    if ($reclaimed) {
        Write-Host "  $reclaimed" -ForegroundColor Cyan
    }

    try { $exitCode = $process.ExitCode } catch { $exitCode = 0 }
    if ($null -eq $exitCode) { $exitCode = 0 }

    if ($exitCode -ne 0) {
        $stderr = Get-Content $stderrFile -ErrorAction SilentlyContinue
        if ($stderr) {
            Write-Host "  Cleanup finished with errors:" -ForegroundColor Yellow
            $stderr | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        }
        return $false
    }

    return $true
}

Write-Host "[1/6] Clean unused Docker data..." -ForegroundColor Yellow
Write-Host "  Scope: unused images, containers, networks, and volumes." -ForegroundColor Gray
Write-Host "  Note: running containers will be kept; this step is optional." -ForegroundColor Gray
$confirm = Read-Host "  Enter y to continue, any other key to skip"
if ($confirm -eq "y") {
    $skipCleanup = $false

    Write-Host "  [1/3] Checking for conflicting docker CLI processes..." -ForegroundColor Gray
    $conflicts = @(Get-DockerCliConflicts)
    if ($conflicts.Count -gt 0) {
        Write-Host "  Conflicting docker CLI process(es) detected:" -ForegroundColor Red
        foreach ($conflict in $conflicts) {
            Write-Host ("    PID {0}: {1}" -f $conflict.ProcessId, $conflict.CommandLine) -ForegroundColor Red
        }
        Write-Host "  Continuing may hang if another cleanup/query is already running." -ForegroundColor Yellow
        $conflictChoice = Read-Host "  [K]ill conflicting process(es) / [S]kip cleanup / [C]ontinue anyway"
        switch ($conflictChoice.ToLower()) {
            "k" {
                $conflicts | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Seconds 2
                Write-Host "  Conflicting process(es) terminated" -ForegroundColor Green
            }
            "s" {
                Write-Host "  Cleanup skipped due to process conflict" -ForegroundColor Gray
                $skipCleanup = $true
            }
            default {
                Write-Host "  Continuing cleanup despite process conflict" -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host "  No conflicting docker CLI process found" -ForegroundColor Green
    }

    if (-not $skipCleanup) {
        Write-Host "  [2/3] Checking Docker daemon responsiveness..." -ForegroundColor Gray
        if (-not (Test-DockerDaemonReady)) {
            Write-Host "  Docker daemon is not responding (waited 20s)." -ForegroundColor Red
            Write-Host "  Suggestion: restart Docker Desktop, then run this script again." -ForegroundColor Yellow
            $daemonChoice = Read-Host "  [S]kip cleanup / [R]etry daemon check"
            if ($daemonChoice -eq "r" -or $daemonChoice -eq "R") {
                if (-not (Test-DockerDaemonReady)) {
                    Write-Host "  Docker daemon still not responding, cleanup skipped" -ForegroundColor Gray
                    $skipCleanup = $true
                }
            }
            else {
                $skipCleanup = $true
            }
        }
        else {
            Write-Host "  Docker daemon is ready" -ForegroundColor Green
        }
    }

    if (-not $skipCleanup) {
        if (Invoke-DockerCleanup) {
            Write-Host "  Docker cleanup completed" -ForegroundColor Green
        }
        else {
            Write-Host "  Docker cleanup failed or was interrupted" -ForegroundColor Yellow
            Write-Host "  You can skip this step next time and continue with VHDX compaction." -ForegroundColor Gray
        }
    }
}
else {
    Write-Host "  Cleanup skipped" -ForegroundColor Gray
}

function Format-SizeMB {
    param([long]$Bytes)
    $mb = [math]::Round($Bytes / 1MB, 2)
    $gb = [math]::Round($Bytes / 1GB, 2)
    if ($gb -ge 1) {
        return ("{0} MB ({1} GB)" -f $mb, $gb)
    }
    return ("{0} MB" -f $mb)
}

function Get-DockerStackProcessNames {
    return @(
        "Docker Desktop",
        "com.docker.backend",
        "com.docker.build",
        "com.docker.proxy",
        "com.docker.dev-envs",
        "com.docker.extensions",
        "vpnkit",
        "docker",
        "docker-compose"
    )
}

function Get-DockerStackProcesses {
    Get-Process -Name (Get-DockerStackProcessNames) -ErrorAction SilentlyContinue
}

function Stop-ProcessImagesForce {
    param([string[]]$ImageNames)

    foreach ($image in $ImageNames) {
        Write-Host ("    taskkill /F /T /IM {0}" -f $image) -ForegroundColor DarkGray
        & taskkill.exe /F /T /IM $image 2>$null | Out-Null
    }
}

function Stop-DockerDesktopFully {
    param([int]$WaitSeconds = 20)

    Write-Host "  Force-stopping Docker Desktop stack..." -ForegroundColor Gray

    $svc = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Stopped") {
        Write-Host "  Stopping com.docker.service..." -ForegroundColor Gray
        try { Stop-Service -Name "com.docker.service" -Force -ErrorAction Stop } catch { }
    }

    $images = @(Get-DockerStackProcessNames | ForEach-Object { "$_.exe" })
    Stop-ProcessImagesForce -ImageNames $images

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)docker|vpnkit' } |
        ForEach-Object {
            Write-Host ("    taskkill /F /T /PID {0} ({1})" -f $_.ProcessId, $_.Name) -ForegroundColor DarkGray
            & taskkill.exe /F /T /PID $_.ProcessId 2>$null | Out-Null
        }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $left = @(Get-DockerStackProcesses)
        if ($left.Count -eq 0) {
            Write-Host "  Docker Desktop stack fully stopped" -ForegroundColor Green
            return $true
        }
        Stop-ProcessImagesForce -ImageNames $images
        $left | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    $left = @(Get-DockerStackProcesses)
    if ($left.Count -gt 0) {
        Write-Host "  WARNING: some Docker processes are still running:" -ForegroundColor Red
        foreach ($proc in $left) {
            Write-Host ("    {0} (PID {1})" -f $proc.ProcessName, $proc.Id) -ForegroundColor Red
        }
        return $false
    }

    Write-Host "  Docker Desktop stack fully stopped" -ForegroundColor Green
    return $true
}

function Get-DockerDesktopExe {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"),
        "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    return $null
}

function Start-DockerDesktopFully {
    param([int]$TimeoutSeconds = 180)

    if (Test-DockerDaemonReady -TimeoutSeconds 8) {
        Write-Host "  Docker daemon already ready" -ForegroundColor Green
        return $true
    }

    $running = @(Get-DockerStackProcesses)
    if ($running.Count -gt 0) {
        Write-Host "  Docker stack is up but daemon is not ready. Restarting stack..." -ForegroundColor Yellow
        $null = Stop-DockerDesktopFully
        Start-Sleep -Seconds 2
    }

    $svc = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Running") {
        Write-Host "  Starting com.docker.service..." -ForegroundColor Gray
        try { Start-Service -Name "com.docker.service" -ErrorAction Stop } catch { }
    }

    $exe = Get-DockerDesktopExe
    if (-not $exe) {
        Write-Host "  ERROR: Docker Desktop.exe not found" -ForegroundColor Red
        return $false
    }

    Write-Host ("  Starting {0}" -f $exe) -ForegroundColor Gray
    Start-Process -FilePath $exe

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $startedWsl = $false
    while ((Get-Date) -lt $deadline) {
        $wslText = (wsl -l -v 2>&1 | Out-String)
        if (-not $startedWsl -and $wslText -notmatch 'docker-desktop\s+Running') {
            Write-Host "  Starting WSL distro docker-desktop..." -ForegroundColor Gray
            & wsl.exe -d docker-desktop -e echo wsl-ok 2>$null | Out-Null
            $startedWsl = $true
        }
        if (Test-DockerDaemonReady -TimeoutSeconds 8) {
            Write-Host "  Docker daemon is ready" -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 3
    }

    Write-Host "  ERROR: Docker daemon did not become ready within ${TimeoutSeconds}s" -ForegroundColor Red
    return $false
}

function Stop-WslFully {
    param([int]$WaitSeconds = 30)

    Write-Host "  Sending wsl --shutdown..." -ForegroundColor Gray
    wsl --shutdown 2>$null

    $wslImages = @("vmmemWSL.exe", "vmmem.exe", "wsl.exe", "wslhost.exe", "wslrelay.exe")
    Stop-ProcessImagesForce -ImageNames $wslImages

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $vmmem = Get-Process -Name "vmmemWSL", "vmmem" -ErrorAction SilentlyContinue
        $wslCli = Get-Process -Name "wsl", "wslhost", "wslrelay" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -ne "wslservice" }
        if (-not $vmmem -and -not $wslCli) {
            Write-Host "  WSL fully stopped" -ForegroundColor Green
            return $true
        }
        Stop-ProcessImagesForce -ImageNames $wslImages
        Start-Sleep -Seconds 1
    }

    $vmmem = Get-Process -Name "vmmemWSL", "vmmem" -ErrorAction SilentlyContinue
    if ($vmmem) {
        Write-Host "  WARNING: vmmemWSL is still running, VHDX may be locked" -ForegroundColor Red
        return $false
    }

    Write-Host "  WSL stopped" -ForegroundColor Green
    return $true
}

function Invoke-VhdxCompact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path $VhdxPath)) {
        Write-Host ("  ERROR: file not found: {0}" -f $VhdxPath) -ForegroundColor Red
        return $false
    }

    $diskpartScript = @"
select vdisk file="$VhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
"@
    $output = $diskpartScript | diskpart 2>&1 | Out-String
    $ok = ($LASTEXITCODE -eq 0) -or ($output -match "successfully" -or $output -match "100 percent")

    # diskpart often returns 0 even with useful progress text; treat hard errors as failure
    if ($output -match "Virtual Disk Service error|not found|Access is denied|The system cannot find") {
        $ok = $false
    }

    if ($ok) {
        Write-Host ("  {0} compaction completed" -f $Label) -ForegroundColor Green
        return $true
    }

    Write-Host ("  {0} compaction may have failed. diskpart output:" -f $Label) -ForegroundColor Red
    $output -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object {
        Write-Host ("    {0}" -f $_) -ForegroundColor Gray
    }
    return $false
}

Write-Host "[2/6] Stop Docker Desktop (UI + backend)..." -ForegroundColor Yellow
if (-not (Stop-DockerDesktopFully)) {
    $choice = Read-Host "  Docker is not fully stopped. [A]bort / [C]ontinue anyway"
    if ($choice -ne "c" -and $choice -ne "C") {
        Write-Host "  Aborted." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Write-Host "[3/6] Shut down WSL..." -ForegroundColor Yellow
if (-not (Stop-WslFully)) {
    $choice = Read-Host "  WSL may still hold the VHDX. [A]bort / [C]ontinue anyway"
    if ($choice -ne "c" -and $choice -ne "C") {
        Write-Host "  Aborted." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# Final lock check before compact
$lockCheck = @(Get-DockerStackProcesses) + @(Get-Process -Name "vmmemWSL", "vmmem" -ErrorAction SilentlyContinue)
if ($lockCheck.Count -gt 0) {
    Write-Host "  Re-checking and clearing leftover processes before compact..." -ForegroundColor Yellow
    $null = Stop-DockerDesktopFully
    $null = Stop-WslFully
}

Write-Host ""
Write-Host "Size before compaction:" -ForegroundColor White
$beforeSize1 = (Get-Item $DockerDataVHDX).Length
$beforeSize2 = (Get-Item $Ext4VHDX).Length
Write-Host ("  docker_data.vhdx: {0}" -f (Format-SizeMB $beforeSize1)) -ForegroundColor White
Write-Host ("  ext4.vhdx:        {0}" -f (Format-SizeMB $beforeSize2)) -ForegroundColor White

Write-Host ""
Write-Host "[4/6] Compact docker_data.vhdx..." -ForegroundColor Yellow
$compact1Ok = Invoke-VhdxCompact -VhdxPath $DockerDataVHDX -Label "docker_data.vhdx"

Write-Host "[5/6] Compact ext4.vhdx..." -ForegroundColor Yellow
$compact2Ok = Invoke-VhdxCompact -VhdxPath $Ext4VHDX -Label "ext4.vhdx"

Write-Host "[6/6] Done" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Compaction result:" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$afterSize1 = (Get-Item $DockerDataVHDX).Length
$afterSize2 = (Get-Item $Ext4VHDX).Length

Write-Host "docker_data.vhdx:" -ForegroundColor White
Write-Host ("  Before: {0}" -f (Format-SizeMB $beforeSize1)) -ForegroundColor Gray
Write-Host ("  After:  {0}" -f (Format-SizeMB $afterSize1)) -ForegroundColor Green
Write-Host ("  Saved:  {0}" -f (Format-SizeMB ($beforeSize1 - $afterSize1))) -ForegroundColor Cyan

Write-Host "ext4.vhdx:" -ForegroundColor White
Write-Host ("  Before: {0}" -f (Format-SizeMB $beforeSize2)) -ForegroundColor Gray
Write-Host ("  After:  {0}" -f (Format-SizeMB $afterSize2)) -ForegroundColor Green
Write-Host ("  Saved:  {0}" -f (Format-SizeMB ($beforeSize2 - $afterSize2))) -ForegroundColor Cyan

$totalBefore = $beforeSize1 + $beforeSize2
$totalAfter = $afterSize1 + $afterSize2

Write-Host ""
Write-Host "Total:" -ForegroundColor White
Write-Host ("  Before: {0}" -f (Format-SizeMB $totalBefore)) -ForegroundColor Gray
Write-Host ("  After:  {0}" -f (Format-SizeMB $totalAfter)) -ForegroundColor Green
Write-Host ("  Saved:  {0}" -f (Format-SizeMB ($totalBefore - $totalAfter))) -ForegroundColor Cyan

if (-not $compact1Ok -or -not $compact2Ok) {
    Write-Host ""
    Write-Host "WARNING: one or more compact steps reported errors. Check sizes above." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Starting Docker Desktop..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
if (Start-DockerDesktopFully) {
    Write-Host "Docker Desktop is ready." -ForegroundColor Green
} else {
    Write-Host "WARNING: Docker Desktop did not become ready. Start it from the Start menu, then retry bun docker." -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Press Enter to exit"