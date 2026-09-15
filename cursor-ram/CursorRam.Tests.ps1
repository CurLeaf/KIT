#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here "CursorRam.psm1") -Force

function Assert-True {
    param($Cond, [string]$Msg)
    if (-not $Cond) { throw $Msg }
}

Describe "ConvertFrom-CursorRamWslList" {
    It "parses docker-desktop running and ubuntu stopped" {
        $text = "  NAME              STATE           VERSION`r`n* docker-desktop    Running         2`r`n  Ubuntu            Stopped         2`r`n"
        $rows = @(ConvertFrom-CursorRamWslList $text)
        Assert-True ($rows.Count -eq 2) "expected 2 distros, got $($rows.Count)"
        Assert-True ($rows[0].Name -eq "docker-desktop") "name0=$($rows[0].Name)"
        Assert-True ($rows[0].State -eq "Running") "state0=$($rows[0].State)"
        Assert-True ($rows[1].Name -eq "Ubuntu") "name1=$($rows[1].Name)"
        Assert-True ($rows[1].State -eq "Stopped") "state1=$($rows[1].State)"
    }
}

Describe "ConvertTo-CursorRamStatus" {
    $clean = [pscustomobject]@{
        FreeGB          = 12.3
        CompressionGB   = 0.2
        DesktopProcess  = $false
        DesktopDistro   = $false
        DesktopVhdx     = $false
        DesktopStartup  = $false
        WslRunning      = $false
        HoldActive      = $false
        Building        = $false
        NativePreview   = $false
        TscPreview      = 0
        PlaywrightMcp   = $false
        CursorWindows   = 1
        Vinext          = 0
        Uni             = 0
    }

    It "is ok when desktop gone and wsl down" {
        $s = ConvertTo-CursorRamStatus -Facts $clean
        Assert-True $s.Ok "expected Ok"
        Assert-True ($s.Reason -eq "ok") "reason=$($s.Reason)"
    }

    It "is not ok when desktop vhdx remains" {
        $f = $clean.PSObject.Copy()
        $f.DesktopVhdx = $true
        $s = ConvertTo-CursorRamStatus -Facts $f
        Assert-True (-not $s.Ok) "expected not Ok"
        Assert-True ($s.Reason -eq "desktop") "reason=$($s.Reason)"
    }

    It "is not ok when wsl running without hold or build" {
        $f = $clean.PSObject.Copy()
        $f.WslRunning = $true
        $s = ConvertTo-CursorRamStatus -Facts $f
        Assert-True (-not $s.Ok) "expected not Ok"
        Assert-True ($s.Reason -eq "wsl") "reason=$($s.Reason)"
    }

    It "is ok when wsl running and hold active" {
        $f = $clean.PSObject.Copy()
        $f.WslRunning = $true
        $f.HoldActive = $true
        $s = ConvertTo-CursorRamStatus -Facts $f
        Assert-True $s.Ok "expected Ok under hold"
    }

    It "is ok when wsl running and building" {
        $f = $clean.PSObject.Copy()
        $f.WslRunning = $true
        $f.Building = $true
        $s = ConvertTo-CursorRamStatus -Facts $f
        Assert-True $s.Ok "expected Ok while building"
    }

    It "is not ok when native-preview tsc is running" {
        $f = $clean.PSObject.Copy()
        $f.TscPreview = 2
        $s = ConvertTo-CursorRamStatus -Facts $f
        Assert-True (-not $s.Ok) "expected not Ok"
        Assert-True ($s.Reason -eq "preview") "reason=$($s.Reason)"
    }
}

Describe "Format-CursorRamStatusLine" {
    It "prints ok and free fields" {
        $s = ConvertTo-CursorRamStatus -Facts ([pscustomobject]@{
            FreeGB = 12.3; CompressionGB = 0.2
            DesktopProcess = $false; DesktopDistro = $false; DesktopVhdx = $false; DesktopStartup = $false
            WslRunning = $false; HoldActive = $false; Building = $false
            NativePreview = $false; TscPreview = 0; PlaywrightMcp = $false
            CursorWindows = 1; Vinext = 2; Uni = 0
        })
        $line = Format-CursorRamStatusLine $s
        Assert-True ($line -match "ok=1") "line=$line"
        Assert-True ($line -match "free=12.3") "line=$line"
        Assert-True ($line -match "vinext=2") "line=$line"
    }
}

Describe "Lock-CursorRam" {
    $tmp = Join-Path $env:TEMP ("cursor-ram-lock-" + [guid]::NewGuid().ToString("n"))

    It "rejects a second live lock" {
        Set-CursorRamRuntimeDir $tmp
        Initialize-CursorRamRuntimeDir
        Assert-True (Lock-CursorRam -Command "status" -TtlSec 60) "first lock"
        Assert-True (-not (Lock-CursorRam -Command "watch" -TtlSec 60)) "second lock should fail"
        Unlock-CursorRam
    }

    AfterEach {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
}

Describe "Test-CursorRamHoldActive" {
    $tmp = Join-Path $env:TEMP ("cursor-ram-hold-" + [guid]::NewGuid().ToString("n"))

    BeforeEach {
        Set-CursorRamRuntimeDir $tmp
        Initialize-CursorRamRuntimeDir
    }

    AfterEach {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }

    It "is active after hold and inactive after clear" {
        Assert-True (-not (Test-CursorRamHoldActive)) "empty should be inactive"
        Set-CursorRamHold -Hours 2
        Assert-True (Test-CursorRamHoldActive) "hold should be active"
        Clear-CursorRamHold
        Assert-True (-not (Test-CursorRamHoldActive)) "cleared should be inactive"
    }

    It "treats expired hold as inactive" {
        Set-CursorRamHold -Hours 2
        $path = Get-CursorRamHoldPath
        $j = @{ until = (Get-Date).AddHours(-1).ToString("o") } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($path, $j)
        Assert-True (-not (Test-CursorRamHoldActive)) "expired hold"
    }
}

Describe "Invoke-CursorRamWatch" {
    $tmp = Join-Path $env:TEMP ("cursor-ram-watch-" + [guid]::NewGuid().ToString("n"))
    $script:Stopped = 0

    BeforeEach {
        $script:Stopped = 0
        Set-CursorRamRuntimeDir $tmp
        Initialize-CursorRamRuntimeDir
        Set-CursorRamWslStopper { $script:Stopped++ }
        Set-CursorRamFactsProvider {
            [pscustomobject]@{
                FreeGB = 10; CompressionGB = 0
                DesktopProcess = $false; DesktopDistro = $false; DesktopVhdx = $false; DesktopStartup = $false
                WslRunning = $true; HoldActive = (Test-CursorRamHoldActive); Building = $false
                NativePreview = $false; TscPreview = 0; PlaywrightMcp = $false
                CursorWindows = 1; Vinext = 0; Uni = 0
            }
        }
    }

    AfterEach {
        Set-CursorRamFactsProvider $null
        Set-CursorRamWslStopper $null
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }

    It "skips shutdown when hold is active" {
        Set-CursorRamHold -Hours 2
        $r = Invoke-CursorRamWatch
        Assert-True ($r.Reason -eq "hold") "reason=$($r.Reason)"
        Assert-True ($script:Stopped -eq 0) "must not shutdown under hold"
        Assert-True $r.Ok "ok"
    }

    It "skips shutdown when building" {
        Set-CursorRamFactsProvider {
            [pscustomobject]@{
                FreeGB = 10; CompressionGB = 0
                DesktopProcess = $false; DesktopDistro = $false; DesktopVhdx = $false; DesktopStartup = $false
                WslRunning = $true; HoldActive = $false; Building = $true
                NativePreview = $false; TscPreview = 0; PlaywrightMcp = $false
                CursorWindows = 1; Vinext = 0; Uni = 0
            }
        }
        $r = Invoke-CursorRamWatch
        Assert-True ($r.Reason -eq "build") "reason=$($r.Reason)"
        Assert-True ($script:Stopped -eq 0) "must not shutdown while building"
    }

    It "shuts down wsl when leaked" {
        $r = Invoke-CursorRamWatch
        Assert-True ($r.Reason -eq "shutdown") "reason=$($r.Reason)"
        Assert-True ($script:Stopped -eq 1) "expected one shutdown"
        Assert-True $r.Changed "changed"
    }
}

Describe "Move-CursorRamPlaywrightMcp" {
    It "moves playwright and keeps other servers" {
        $raw = '{"mcpServers":{"playwright":{"command":"npx"},"codegraph":{"command":"codegraph"}}}'
        $r = Move-CursorRamPlaywrightMcp $raw
        Assert-True $r.Moved "moved"
        $main = $r.Json | ConvertFrom-Json
        $side = $r.Sidecar | ConvertFrom-Json
        Assert-True ($null -eq $main.mcpServers.playwright) "playwright still in main"
        Assert-True ($null -ne $main.mcpServers.codegraph) "lost codegraph"
        Assert-True ($null -ne $side.mcpServers.playwright) "sidecar missing playwright"
        Assert-True ($null -eq $side.mcpServers.codegraph) "sidecar should only be playwright"
    }

    It "leaves json unchanged when playwright is absent" {
        $raw = '{"mcpServers":{"codegraph":{"command":"codegraph"}}}'
        $r = Move-CursorRamPlaywrightMcp $raw
        Assert-True (-not $r.Moved) "should not move"
        Assert-True ($r.Json -eq $raw) "json changed"
    }
}

Describe "Invoke-CursorRamApply" {
    $tmp = Join-Path $env:TEMP ("cursor-ram-apply-" + [guid]::NewGuid().ToString("n"))
    $script:Stopped = 0

    BeforeEach {
        $script:Stopped = 0
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Set-CursorRamRuntimeDir (Join-Path $tmp "run")
        Initialize-CursorRamRuntimeDir
        Set-CursorRamWslStopper { $script:Stopped++ }
        $mcp = Join-Path $tmp "mcp.json"
        $side = Join-Path $tmp "mcp.playwright.json"
        [System.IO.File]::WriteAllText($mcp, '{"mcpServers":{"playwright":{"command":"npx"},"codegraph":{"command":"codegraph"}}}')
        Set-CursorRamMcpPaths -McpPath $mcp -SidecarPath $side
        $ext = Join-Path $tmp "extensions"
        New-Item -ItemType Directory -Path (Join-Path $ext "typescriptteam.native-preview-0.1-win32-x64") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $ext "biomejs.biome-3.7.1-universal") -Force | Out-Null
        Set-CursorRamExtensionRoot $ext
        Set-CursorRamFactsProvider {
            [pscustomobject]@{
                FreeGB = 10; CompressionGB = 0
                DesktopProcess = $false; DesktopDistro = $false; DesktopVhdx = $false; DesktopStartup = $false
                WslRunning = $true; HoldActive = (Test-CursorRamHoldActive); Building = $false
                NativePreview = $true; TscPreview = 0; PlaywrightMcp = $true
                CursorWindows = 1; Vinext = 0; Uni = 0
            }
        }
    }

    AfterEach {
        Set-CursorRamFactsProvider $null
        Set-CursorRamWslStopper $null
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }

    It "does not stop wsl when hold is active but still moves mcp and preview dirs" {
        Set-CursorRamHold -Hours 2
        $r = Invoke-CursorRamApply
        Assert-True $r.Ok "apply ok"
        Assert-True ($script:Stopped -eq 0) "stopped under hold"
        Assert-True $r.McpMoved "mcp"
        Assert-True $r.PreviewRemoved "preview"
        $main = Get-Content -LiteralPath (Join-Path $tmp "mcp.json") -Raw | ConvertFrom-Json
        Assert-True ($null -eq $main.mcpServers.playwright) "playwright remains"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tmp "extensions\typescriptteam.native-preview-0.1-win32-x64"))) "preview dir remains"
        Assert-True (Test-Path -LiteralPath (Join-Path $tmp "extensions\biomejs.biome-3.7.1-universal")) "biome removed"
    }

    It "stops wsl when hold is absent" {
        $r = Invoke-CursorRamApply
        Assert-True $r.WslStopped "expected wsl stop"
        Assert-True ($script:Stopped -eq 1) "stop count=$($script:Stopped)"
        Assert-True $r.Ok "ok"
    }
}

Describe "ConvertTo-CursorRamWslPath" {
    It "maps D drive path to /mnt/d" {
        $p = ConvertTo-CursorRamWslPath "D:\GitHub\erp-admin-1\docker"
        Assert-True ($p -eq "/mnt/d/GitHub/erp-admin-1/docker") "got $p"
    }
}

Describe "Invoke-CursorRamPack" {
    $tmp = Join-Path $env:TEMP ("cursor-ram-pack-" + [guid]::NewGuid().ToString("n"))

    BeforeEach {
        Set-CursorRamRuntimeDir $tmp
        Initialize-CursorRamRuntimeDir
        Set-CursorRamWslStopper { }
        Set-CursorRamMcpPaths -McpPath (Join-Path $tmp "mcp.json") -SidecarPath (Join-Path $tmp "mcp.playwright.json")
        Set-CursorRamExtensionRoot (Join-Path $tmp "extensions")
        New-Item -ItemType Directory -Path (Join-Path $tmp "extensions") -Force | Out-Null
        Set-CursorRamFactsProvider {
            [pscustomobject]@{
                FreeGB = 10; CompressionGB = 0
                DesktopProcess = $false; DesktopDistro = $false; DesktopVhdx = $false; DesktopStartup = $false
                WslRunning = $false; HoldActive = (Test-CursorRamHoldActive); Building = $false
                NativePreview = $false; TscPreview = 0; PlaywrightMcp = $false
                CursorWindows = 1; Vinext = 0; Uni = 0
            }
        }
        Set-CursorRamPackRunner {
            param($WslCwd, $Command)
            [pscustomobject]@{ ExitCode = 0; WslCwd = $WslCwd; Command = $Command }
        }
    }

    AfterEach {
        Set-CursorRamFactsProvider $null
        Set-CursorRamPackRunner $null
        Set-CursorRamWslStopper $null
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }

    It "runs in wsl cwd and clears hold afterward" {
        $r = Invoke-CursorRamPack -Arguments @("sh", "docker/release-app.sh", "user-center") -WorkingDirectory "D:\GitHub\erp-admin-1"
        Assert-True $r.Ok "pack ok reason=$($r.Reason)"
        Assert-True ($r.WslCwd -eq "/mnt/d/GitHub/erp-admin-1") "cwd=$($r.WslCwd)"
        Assert-True ($r.Command -match "release-app.sh") "cmd=$($r.Command)"
        Assert-True (-not (Test-CursorRamHoldActive)) "hold should be cleared"
    }
}

Describe "Select-CursorRamParkTargets" {
    $procs = @(
        [pscustomobject]@{ Name = "Cursor.exe"; CommandLine = "D:\Program Files\cursor\Cursor.exe" },
        [pscustomobject]@{ Name = "node.exe"; CommandLine = "node vinext dist/cli.js dev --port 3008" },
        [pscustomobject]@{ Name = "node.exe"; CommandLine = "node uni.js -p mp-weixin" },
        [pscustomobject]@{ Name = "chrome.exe"; CommandLine = "chrome --user-data-dir=mcp-chrome-abc" }
    )

    It "never includes Cursor.exe" {
        $t = @(Select-CursorRamParkTargets -Processes $procs -Dev)
        foreach ($x in $t) {
            Assert-True ($x.Name -ne "Cursor.exe") "cursor selected"
        }
    }

    It "includes vinext only when Dev" {
        $no = @(Select-CursorRamParkTargets -Processes $procs)
        $yes = @(Select-CursorRamParkTargets -Processes $procs -Dev)
        Assert-True ($no.Count -eq 0) "default should be empty, got $($no.Count)"
        Assert-True ($yes.Count -eq 3) "dev count=$($yes.Count)"
    }
}

Describe "Update-CursorRamWslConfig" {
    It "writes memory 3GB and processors 4" {
        $next = Update-CursorRamWslConfig ""
        Assert-True ($next -match "\[wsl2\]") "missing [wsl2] text=$next"
        Assert-True ($next -match "memory=3GB") "memory"
        Assert-True ($next -match "processors=4") "cpu"
    }

    It "keeps unrelated sections" {
        $next = Update-CursorRamWslConfig "[wsl2]`r`nswap=2GB`r`n"
        Assert-True ($next -match "swap=2GB") "lost swap"
        Assert-True ($next -match "memory=3GB") "memory"
    }
}

Describe "Install-CursorRamHost" {
    $tmp = Join-Path $env:TEMP ("cursor-ram-install-" + [guid]::NewGuid().ToString("n"))

    BeforeEach {
        Set-CursorRamRuntimeDir $tmp
        Initialize-CursorRamRuntimeDir
        Set-CursorRamTaskRunner { param($ArgumentList) $true }
        Set-CursorRamWslStopper { }
        Set-CursorRamMcpPaths -McpPath (Join-Path $tmp "mcp.json") -SidecarPath (Join-Path $tmp "side.json")
        Set-CursorRamExtensionRoot (Join-Path $tmp "extensions")
        New-Item -ItemType Directory -Path (Join-Path $tmp "extensions") -Force | Out-Null
    }

    AfterEach {
        Set-CursorRamFactsProvider $null
        Set-CursorRamTaskRunner $null
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }

    It "fails when desktop vhdx is present" {
        Set-CursorRamFactsProvider {
            [pscustomobject]@{
                FreeGB = 10; CompressionGB = 0
                DesktopProcess = $false; DesktopDistro = $false; DesktopVhdx = $true; DesktopStartup = $false
                WslRunning = $false; HoldActive = $false; Building = $false
                NativePreview = $false; TscPreview = 0; PlaywrightMcp = $false
                CursorWindows = 1; Vinext = 0; Uni = 0
            }
        }
        $r = Install-CursorRamHost
        Assert-True (-not $r.Ok) "should fail"
        Assert-True ($r.Reason -eq "desktop") "reason=$($r.Reason)"
        Assert-True (-not $r.WatchTask) "must not register tasks"
    }

    It "registers watch when policy has no desktop leftover" {
        Set-CursorRamFactsProvider {
            [pscustomobject]@{
                FreeGB = 10; CompressionGB = 0
                DesktopProcess = $false; DesktopDistro = $false; DesktopVhdx = $false; DesktopStartup = $false
                WslRunning = $false; HoldActive = $false; Building = $false
                NativePreview = $false; TscPreview = 0; PlaywrightMcp = $false
                CursorWindows = 1; Vinext = 0; Uni = 0
            }
        }
        $r = Install-CursorRamHost
        Assert-True $r.Ok "install ok reason=$($r.Reason)"
        Assert-True $r.WatchTask "watch task"
    }
}

Describe "Invoke-CursorRamPurge" {
    $tmp = Join-Path $env:TEMP ("cursor-ram-purge-" + [guid]::NewGuid().ToString("n"))

    BeforeEach {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Set-CursorRamRuntimeDir (Join-Path $tmp "run")
        Initialize-CursorRamRuntimeDir
        $root = Join-Path $tmp "DockerDesktopWSL"
        New-Item -ItemType Directory -Path (Join-Path $root "disk") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root "disk\docker_data.vhdx"), "x")
        Set-CursorRamDesktopWslRoot $root
        Set-CursorRamWslConfigPath (Join-Path $tmp ".wslconfig")
        Set-CursorRamPurgeHook { $true }
        Set-CursorRamWslStopper { }
    }

    AfterEach {
        Set-CursorRamPurgeHook $null
        Set-CursorRamWslStopper $null
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }

    It "deletes the desktop vhdx root" {
        $r = Invoke-CursorRamPurge
        Assert-True $r.Ok "purge ok reason=$($r.Reason)"
        Assert-True $r.RemovedVhdx "RemovedVhdx"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tmp "DockerDesktopWSL"))) "root remains"
        $cfg = Get-Content -LiteralPath (Join-Path $tmp ".wslconfig") -Raw
        Assert-True ($cfg -match "memory=3GB") "wslconfig"
    }
}
