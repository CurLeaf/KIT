#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$psm1 = Join-Path $here "KaringNet.psm1"
$ps1 = Join-Path $here "karing-net.ps1"

function Test-NoCjkFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -ge 0x80) { return $true }
    }
    return $false
}

Describe "karing-net status and lock" {
    It "module and cli parse under Windows PowerShell 5.1" {
        foreach ($path in @($psm1, $ps1)) {
            $errors = $null
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $errors.Count | Should Be 0
        }
    }

    It "psm1 and ps1 have no CJK bytes" {
        (Test-NoCjkFile $psm1) | Should Be $false
        (Test-NoCjkFile $ps1) | Should Be $false
    }

    It "cli default command is status and does not mention api2.cursor.sh" {
        $raw = Get-Content -LiteralPath $ps1 -Raw
        $raw | Should Match "ValidateSet\(`"status`""
        $raw | Should Match '= "status"'
        $raw | Should Not Match "api2\.cursor\.sh"
        (Get-Content -LiteralPath $psm1 -Raw) | Should Not Match "api2\.cursor\.sh"
    }

    It "Test-KaringNetPort sees a local listener and a closed port" {
        Import-Module $psm1 -Force
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        (Test-KaringNetPort -Port $port) | Should Be $true
        $listener.Stop()
        (Test-KaringNetPort -Port $port) | Should Be $false
    }

    It "Lock-KaringNet is exclusive and stealable when stale" {
        Import-Module $psm1 -Force
        $tmp = Join-Path $env:TEMP ("karing-net-t1-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            Set-KaringNetRuntimeDir $tmp
            (Lock-KaringNet -Command "status" -TtlSec 60) | Should Be $true
            (Lock-KaringNet -Command "status" -TtlSec 60) | Should Be $false
            Unlock-KaringNet
            $dead = @{ pid = 999999; command = "watch"; expiresAt = (Get-Date).AddMinutes(5).ToString("o") } | ConvertTo-Json
            [System.IO.File]::WriteAllText((Get-KaringNetLockPath), $dead)
            (Lock-KaringNet -Command "status" -TtlSec 60) | Should Be $true
            Unlock-KaringNet
            $expired = @{ pid = $PID; command = "watch"; expiresAt = (Get-Date).AddMinutes(-5).ToString("o") } | ConvertTo-Json
            [System.IO.File]::WriteAllText((Get-KaringNetLockPath), $expired)
            (Lock-KaringNet -Command "status" -TtlSec 60) | Should Be $true
            Unlock-KaringNet
        } finally {
            Set-KaringNetRuntimeDir (Join-Path $env:APPDATA "karing\karing")
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "Get-KaringNetGroupNow keeps urltest groups only" {
        Import-Module $psm1 -Force
        $proxies = [pscustomobject]@{
            proxies = [pscustomobject]@{
                urltest_out            = [pscustomobject]@{ now = "hk-a" }
                "urltest_out-CursorAuto" = [pscustomobject]@{ now = "jp-b" }
                DIRECT                 = [pscustomobject]@{ now = "direct" }
            }
        }
        $map = Get-KaringNetGroupNow $proxies
        $map["urltest_out"] | Should Be "hk-a"
        $map["urltest_out-CursorAuto"] | Should Be "jp-b"
        $map.ContainsKey("DIRECT") | Should Be $false
    }

    It "cli accepts watch" {
        $raw = Get-Content -LiteralPath $ps1 -Raw
        $raw | Should Match 'ValidateSet\("status", "watch", "sync", "restart"\)'
    }

    It "vbs waits for powershell watch and returns exit code" {
        $vbs = Join-Path $here "karing-net.vbs"
        $raw = Get-Content -LiteralPath $vbs -Raw
        $raw | Should Match "sh\.Run\(cmd, 0, True\)"
        $raw | Should Match "WScript\.Quit rc"
        $raw | Should Match "karing-net.ps1"
        $raw | Should Match "watch"
    }

    It "Invoke-KaringNetWatch writes groupNow snapshot without closing connections" {
        Import-Module $psm1 -Force
        $tmp = Join-Path $env:TEMP ("karing-net-t3-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            Set-KaringNetRuntimeDir $tmp
            $proxies = [pscustomobject]@{
                proxies = [pscustomobject]@{
                    urltest_out = [pscustomobject]@{ now = "hk-a" }
                    "urltest_out-CursorAuto" = [pscustomobject]@{ now = "jp-b" }
                }
            }
            $result = Invoke-KaringNetWatch -DryRun -Proxies $proxies
            $result.GroupNow["urltest_out"] | Should Be "hk-a"
            $state = Get-KaringNetState
            $map = ConvertTo-KaringNetGroupMap $state.groupNow
            $map["urltest_out-CursorAuto"] | Should Be "jp-b"
            (Get-Content -LiteralPath $psm1 -Raw) | Should Not Match "DELETE /connections`""
            (Get-Content -LiteralPath $psm1 -Raw) | Should Not Match 'Uri "http://127.0.0.1:3057/connections"'
        } finally {
            Set-KaringNetRuntimeDir (Join-Path $env:APPDATA "karing\karing")
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "filters cursor connections and never bulk-deletes" {
        Import-Module $psm1 -Force
        $conns = [pscustomobject]@{
            connections = @(
                [pscustomobject]@{ id = "1"; metadata = [pscustomobject]@{ host = "api2.cursor.sh" } }
                [pscustomobject]@{ id = "2"; metadata = [pscustomobject]@{ host = "github.com" } }
                [pscustomobject]@{ id = "3"; metadata = [pscustomobject]@{ host = "cursor.com" } }
            )
        }
        $sel = @(Select-KaringNetCursorConnections $conns)
        $sel.Count | Should Be 2
        $ids = $sel | ForEach-Object { $_.id }
        $ids -contains "1" | Should Be $true
        $ids -contains "3" | Should Be $true
        $ids -contains "2" | Should Be $false
        $raw = Get-Content -LiteralPath $psm1 -Raw
        $raw | Should Match '3057/connections/\$id'
        $raw | Should Not Match 'Uri "http://127.0.0.1:3057/connections"'
    }

    It "detects info nodes and picks a real replacement" {
        Import-Module $psm1 -Force
        $expire = [regex]::Unescape('\u5957\u9910\u5230\u671F') + ":2027-08-25"
        $remain = [regex]::Unescape('\u5269\u4F59\u6D41\u91CF') + ":1GB"
        (Test-KaringNetInfoNode $expire) | Should Be $true
        (Test-KaringNetInfoNode $remain) | Should Be $true
        (Test-KaringNetInfoNode "hk-node") | Should Be $false
        $g = [pscustomobject]@{
            all = @($expire, "hk-node", "sg-node")
            now = $expire
        }
        (Get-KaringNetReplacementNode -Group $g -Current $expire) | Should Be "hk-node"
    }

    It "promotes urltest_out to recent0" {
        Import-Module $psm1 -Force
        $use = [pscustomobject]@{
            recent = @(
                [pscustomobject]@{ type = "vmess"; tag = "hk-manual" }
                [pscustomobject]@{ type = "urltest"; tag = "urltest_out" }
            )
        }
        $next = Promote-KaringNetUrltestRecent $use
        $next.recent[0].type | Should Be "urltest"
        $next.recent[0].tag | Should Be "urltest_out"
    }

    It "watch dry-run reports cursor switch close and info kick" {
        Import-Module $psm1 -Force
        $tmp = Join-Path $env:TEMP ("karing-net-t4-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            Set-KaringNetRuntimeDir $tmp
            $expire = [regex]::Unescape('\u5957\u9910\u5230\u671F') + ":x"
            $prev = [pscustomobject]@{ "urltest_out-CursorAuto" = "old-node"; urltest_out = "hk-a" }
            Set-KaringNetState ([pscustomobject]@{
                    groupNow     = $prev
                    manualSince  = (Get-Date).AddMinutes(-31).ToString("o")
                })
            $proxies = [pscustomobject]@{
                proxies = [pscustomobject]@{
                    urltest_out = [pscustomobject]@{ now = $expire; all = @($expire, "hk-a") }
                    "urltest_out-CursorAuto" = [pscustomobject]@{ now = "new-node"; all = @("old-node", "new-node") }
                }
            }
            $conns = [pscustomobject]@{
                connections = @(
                    [pscustomobject]@{ id = "c1"; metadata = [pscustomobject]@{ host = "www.cursor.sh" } }
                )
            }
            $use = [pscustomobject]@{
                recent = @([pscustomobject]@{ type = "vmess"; tag = "hk-manual" })
            }
            $r = Invoke-KaringNetWatch -DryRun -Proxies $proxies -Connections $conns -Use $use
            $r.ClosedIds -contains "c1" | Should Be $true
            $r.KickedTo | Should Be "hk-a"
            $r.Promoted | Should Be $true
        } finally {
            Set-KaringNetRuntimeDir (Join-Path $env:APPDATA "karing\karing")
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "cli accepts sync" {
        (Get-Content -LiteralPath $ps1 -Raw) | Should Match 'ValidateSet\("status", "watch", "sync", "restart"\)'
    }

    It "reports drift when system proxy or cursor bypass is wrong" {
        Import-Module $psm1 -Force
        $setting = [pscustomobject]@{
            proxy = [pscustomobject]@{
                auto_set_system_proxy      = $false
                system_proxy_bypass_domain = @("localhost", "*.cursor.sh")
            }
            dns = [pscustomobject]@{ proxy_resolve_mode = "fakeip" }
            tun = [pscustomobject]@{
                enable                 = $true
                route_exclude_address  = @("10.20.0.0/30")
                allow_bypass_httpproxy_domains = @("localhost")
            }
        }
        $drift = @(Get-KaringNetProfileDrift -Setting $setting -ProxyEnable 0 -ProxyServer "" -ProxyOverride "*.cursor.sh" -CursorProxySupport "off")
        ($drift -contains "auto_set_system_proxy") | Should Be $true
        ($drift -contains "proxy_resolve_mode") | Should Be $true
        ($drift -contains "win.proxy") | Should Be $true
        ($drift -contains "bypass.cursor") | Should Be $true
        ($drift -contains "cursor.proxySupport") | Should Be $true
    }

    It "Sync-KaringNetProfile dry-run does not write when drifted" {
        Import-Module $psm1 -Force
        $tmp = Join-Path $env:TEMP ("karing-net-t5-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            Set-KaringNetRuntimeDir $tmp
            $setting = [pscustomobject]@{
                proxy = [pscustomobject]@{
                    auto_set_system_proxy      = $false
                    system_proxy_bypass_domain = @("localhost")
                }
                dns = [pscustomobject]@{ proxy_resolve_mode = "proxy" }
                tun = [pscustomobject]@{
                    enable                = $true
                    route_exclude_address = @("10.20.0.0/30")
                    allow_bypass_httpproxy_domains = @("localhost")
                }
            }
            $r = Sync-KaringNetProfile -DryRun -Setting $setting -ProxyEnable 0 -ProxyServer "" -ProxyOverride "" -CursorProxySupport "off"
            $r.Wrote | Should Be $false
            $r.Drift.Count | Should BeGreaterThan 0
        } finally {
            Set-KaringNetRuntimeDir (Join-Path $env:APPDATA "karing\karing")
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "cli accepts restart and restart never curls remote" {
        $raw = Get-Content -LiteralPath $ps1 -Raw
        $raw | Should Match 'ValidateSet\("status", "watch", "sync", "restart"\)'
        $mod = Get-Content -LiteralPath $psm1 -Raw
        $mod | Should Match "function Restart-KaringNetCore"
        $fn = [regex]::Match($mod, "function Restart-KaringNetCore[\s\S]*?\nfunction |function Restart-KaringNetCore[\s\S]*$")
        $fn.Success | Should Be $true
        $fn.Value | Should Match "Test-KaringNetPort"
        $fn.Value | Should Not Match "api2"
        $fn.Value | Should Match "Start-ScheduledTask"
    }

    It "Restart-KaringNetCore dry-run does not stop processes" {
        Import-Module $psm1 -Force
        $tmp = Join-Path $env:TEMP ("karing-net-t7-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            Set-KaringNetRuntimeDir $tmp
            $r = Restart-KaringNetCore -DryRun
            $r.Ok | Should Be $true
            $r.Reason | Should Be "dry-run"
            $r.Steps -contains "stop" | Should Be $true
            $r.Steps -contains "wait-l0" | Should Be $true
        } finally {
            Set-KaringNetRuntimeDir (Join-Path $env:APPDATA "karing\karing")
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
}
