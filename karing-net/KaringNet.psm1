#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:RuntimeDir = Join-Path $env:APPDATA "karing\karing"
$script:ControlPort = 3057
$script:MixedPort = 3067
$script:PortTimeoutMs = 400
$script:ApiTimeoutSec = 2
$script:LockTtlWatchSec = 60
$script:LockTtlWriteSec = 120
$script:HoldMinutes = 30
$script:CloseHoldMinutes = 5
$script:UrltestTag = "urltest_out"
$script:CursorGroupPattern = "Cursor"
$script:CursorHostPattern = "cursor\.sh|cursor\.com|cursorapi\.com"
$script:KaringTask = "Karing"
$script:WatchTask = "Karing-ManualToAuto"

function Set-KaringNetRuntimeDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:RuntimeDir = $Path
}

function Get-KaringNetRuntimeDir { return $script:RuntimeDir }
function Get-KaringNetLockPath { return (Join-Path $script:RuntimeDir "karing-net.lock") }
function Get-KaringNetStatePath { return (Join-Path $script:RuntimeDir "karing-net.state.json") }
function Get-KaringNetLogPath { return (Join-Path $script:RuntimeDir "karing-net.log") }

function Initialize-KaringNetRuntimeDir {
    if (-not (Test-Path -LiteralPath $script:RuntimeDir)) {
        New-Item -ItemType Directory -Path $script:RuntimeDir -Force | Out-Null
    }
}

function Write-KaringNetLog {
    param([string]$Message)
    Initialize-KaringNetRuntimeDir
    $line = "{0} {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath (Get-KaringNetLogPath) -Value $line -Encoding UTF8
}

function Test-KaringNetPort {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 400
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if (-not $ok) { return $false }
        $client.EndConnect($iar) | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-KaringNetLockInfo {
    $path = Get-KaringNetLockPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-KaringNetLockStale {
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

function Lock-KaringNet {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$TtlSec = 60
    )
    Initialize-KaringNetRuntimeDir
    $path = Get-KaringNetLockPath
    if (Test-Path -LiteralPath $path) {
        $info = Get-KaringNetLockInfo
        if (-not (Test-KaringNetLockStale $info)) { return $false }
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

function Unlock-KaringNet {
    $info = Get-KaringNetLockInfo
    if ($null -eq $info) { return }
    if ([int]$info.pid -ne $PID) { return }
    $path = Get-KaringNetLockPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-KaringNetClashHeaders {
    $svcPath = Join-Path $script:RuntimeDir "service.json"
    $svc = Get-Content -LiteralPath $svcPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return @{ Authorization = "Bearer $($svc.secret)" }
}

function Get-KaringNetClashProxies {
    $headers = Get-KaringNetClashHeaders
    return Invoke-RestMethod -Uri "http://127.0.0.1:3057/proxies" -Headers $headers -TimeoutSec $script:ApiTimeoutSec
}

function Get-KaringNetClashProxyPutBytes {
    param([Parameter(Mandatory = $true)][string]$Name)
    $body = @{ name = $Name } | ConvertTo-Json -Compress
    return [System.Text.UTF8Encoding]::new($false).GetBytes($body)
}

function Set-KaringNetClashGroupNow {
    param(
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $headers = Get-KaringNetClashHeaders
    $bytes = Get-KaringNetClashProxyPutBytes -Name $Name
    $uri = "http://127.0.0.1:{0}/proxies/{1}" -f $script:ControlPort, [uri]::EscapeDataString($Group)
    Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec $script:ApiTimeoutSec | Out-Null
}

function Get-KaringNetGroupNow {
    param($Proxies)
    $map = @{}
    if ($null -eq $Proxies) { return $map }
    $root = $Proxies
    if ($null -ne $Proxies.proxies) { $root = $Proxies.proxies }
    foreach ($prop in $root.PSObject.Properties) {
        $name = [string]$prop.Name
        if ($name -ne $script:UrltestTag -and -not $name.StartsWith("$($script:UrltestTag)-")) { continue }
        $now = ""
        if ($null -ne $prop.Value -and $null -ne $prop.Value.now) {
            $now = [string]$prop.Value.now
        }
        $map[$name] = $now
    }
    return $map
}

function Get-KaringNetStatus {
    param(
        [switch]$Api,
        $Proxies
    )
    $karing = $null -ne (Get-Process -Name "karing" -ErrorAction SilentlyContinue)
    $service = $null -ne (Get-Process -Name "karingService" -ErrorAction SilentlyContinue)
    $p3057 = Test-KaringNetPort -Port $script:ControlPort
    $p3067 = Test-KaringNetPort -Port $script:MixedPort
    $groupNow = $null
    if ($Api) {
        if ($null -eq $Proxies) {
            try { $Proxies = Get-KaringNetClashProxies } catch { $Proxies = $null }
        }
        if ($null -ne $Proxies) { $groupNow = Get-KaringNetGroupNow $Proxies }
    }
    return [pscustomobject]@{
        Karing   = $karing
        Service  = $service
        Port3057 = $p3057
        Port3067 = $p3067
        Ok       = ($p3057 -and $p3067)
        GroupNow = $groupNow
    }
}

function ConvertTo-KaringNetGroupObject {
    param($Map)
    $obj = New-Object PSObject
    if ($null -eq $Map) { return $obj }
    foreach ($k in $Map.Keys) {
        $obj | Add-Member -NotePropertyName ([string]$k) -NotePropertyValue ([string]$Map[$k])
    }
    return $obj
}

function ConvertTo-KaringNetGroupMap {
    param($Obj)
    $map = @{}
    if ($null -eq $Obj) { return $map }
    if ($Obj -is [hashtable]) {
        foreach ($k in $Obj.Keys) { $map[[string]$k] = [string]$Obj[$k] }
        return $map
    }
    foreach ($p in $Obj.PSObject.Properties) {
        $map[[string]$p.Name] = [string]$p.Value
    }
    return $map
}

function Get-KaringNetState {
    $path = Get-KaringNetStatePath
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{} }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{}
    }
}

function Set-KaringNetState {
    param($State)
    Initialize-KaringNetRuntimeDir
    $json = $State | ConvertTo-Json -Depth 10
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Get-KaringNetStatePath), $json + "`r`n", $utf8)
}

function Get-KaringNetInfoNodePattern {
    return [regex]::Unescape('\u5269\u4F59\u6D41\u91CF|\u5957\u9910\u5230\u671F|\u8DDD\u79BB\u4E0B\u6B21\u91CD\u7F6E')
}

function Get-KaringNetFallbackNode {
    return [regex]::Unescape('\u65B0\u52A0\u5761SG-HY2')
}

function Get-KaringNetNote {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-KaringNetCursorGroupChange {
    param($Prev, $Now)
    $from = @(Get-KaringNetCursorSwitchedFrom $Prev $Now)
    return ($from.Count -gt 0)
}

function Get-KaringNetCursorSwitchedFrom {
    param($Prev, $Now)
    $out = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Now) { return @() }
    $prevMap = ConvertTo-KaringNetGroupMap $Prev
    foreach ($k in $Now.Keys) {
        if ($k -notmatch $script:CursorGroupPattern) { continue }
        $old = ""
        if ($prevMap.ContainsKey($k)) { $old = [string]$prevMap[$k] }
        $new = [string]$Now[$k]
        if ($old -and $new -and $old -ne $new) { [void]$out.Add($old) }
    }
    return @($out)
}

function Get-KaringNetCursorCurrentNode {
    param($Now)
    if ($null -eq $Now) { return "" }
    foreach ($k in $Now.Keys) {
        if ($k -notmatch $script:CursorGroupPattern) { continue }
        return [string]$Now[$k]
    }
    return ""
}

function Test-KaringNetCursorCloseHoldExpired {
    param($State, [datetime]$Now)
    $at = Get-KaringNetNote $State "cursorClosedAt"
    if (-not $at) { return $true }
    try {
        $dt = [datetime]$at
    } catch {
        return $true
    }
    return (($Now - $dt).TotalMinutes -ge $script:CloseHoldMinutes)
}

function Add-KaringNetUniqueName {
    param([string[]]$List, [string]$Name)
    $next = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($List)) {
        if ([string]$x) { [void]$next.Add([string]$x) }
    }
    if ($Name -and -not $next.Contains($Name)) { [void]$next.Add($Name) }
    return , @($next)
}

function Select-KaringNetCursorConnections {
    param($Connections)
    $items = @()
    if ($null -eq $Connections) { return @() }
    if ($Connections -is [System.Array]) {
        $items = @($Connections)
    } elseif ($null -ne (Get-KaringNetNote $Connections "connections")) {
        $items = @(Get-KaringNetNote $Connections "connections")
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $items) {
        $hostName = ""
        $md = Get-KaringNetNote $c "metadata"
        if ($null -ne $md) {
            $hostVal = Get-KaringNetNote $md "host"
            if ($hostVal) { $hostName = [string]$hostVal }
            else {
                $sniff = Get-KaringNetNote $md "sniffHost"
                if ($sniff) { $hostName = [string]$sniff }
            }
        }
        if ($hostName -match $script:CursorHostPattern) { [void]$out.Add($c) }
    }
    return $out.ToArray()
}

function Get-KaringNetConnectionChains {
    param($Conn)
    $list = New-Object System.Collections.Generic.List[string]
    $md = Get-KaringNetNote $Conn "metadata"
    foreach ($holder in @($Conn, $md)) {
        $raw = Get-KaringNetNote $holder "chains"
        if ($null -eq $raw) { continue }
        foreach ($x in @($raw)) {
            if ($null -eq $x) { continue }
            $s = [string]$x
            if ($s) { [void]$list.Add($s) }
        }
    }
    return @($list)
}

function Select-KaringNetStaleCursorConnections {
    param($Connections, [string[]]$OnNodes, [string]$CurrentNode)
    $selected = @(Select-KaringNetCursorConnections $Connections)
    if ($null -eq $OnNodes) { return $selected }
    $stale = @($OnNodes | Where-Object { $_ })
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $selected) {
        $chains = @(Get-KaringNetConnectionChains $c)
        $onStale = $false
        foreach ($n in $stale) {
            if ($chains -contains $n) { $onStale = $true; break }
        }
        $onCurrent = $false
        if ($CurrentNode -and ($chains -contains $CurrentNode)) { $onCurrent = $true }
        if ($onStale -and -not $onCurrent) { [void]$out.Add($c) }
    }
    return $out.ToArray()
}

function Close-KaringNetCursorConnections {
    param($Connections, [string[]]$OnNodes, [string]$CurrentNode, [switch]$DryRun)
    if ($null -eq $OnNodes) {
        $selected = @(Select-KaringNetCursorConnections $Connections)
    } else {
        $selected = @(Select-KaringNetStaleCursorConnections -Connections $Connections -OnNodes $OnNodes -CurrentNode $CurrentNode)
    }
    $ids = @($selected | ForEach-Object { [string]$_.id })
    if (-not $DryRun) {
        $headers = Get-KaringNetClashHeaders
        foreach ($id in $ids) {
            if (-not $id) { continue }
            Invoke-RestMethod -Method Delete -Uri "http://127.0.0.1:3057/connections/$id" -Headers $headers -TimeoutSec 2 | Out-Null
        }
    }
    return @($ids)
}

function Get-KaringNetClashConnections {
    $headers = Get-KaringNetClashHeaders
    $uri = 'http://127.0.0.1:3057' + '/connections'
    return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec $script:ApiTimeoutSec
}

function Test-KaringNetInfoNode {
    param([string]$Name)
    if (-not $Name) { return $false }
    return [bool]($Name -match (Get-KaringNetInfoNodePattern))
}

function Get-KaringNetReplacementNode {
    param($Group, [string]$Current, [switch]$SkipGpt)
    $all = @()
    $allVal = Get-KaringNetNote $Group "all"
    if ($null -ne $allVal) { $all = @($allVal) }
    foreach ($n in $all) {
        $s = [string]$n
        if ($s -eq $Current) { continue }
        if (Test-KaringNetInfoNode $s) { continue }
        if ($SkipGpt -and (Test-KaringNetGptNode $s)) { continue }
        return $s
    }
    $fallback = Get-KaringNetFallbackNode
    if ($all -contains $fallback) { return $fallback }
    return $null
}

function Test-KaringNetIsUrltest {
    param($Item)
    if ($null -eq $Item) { return $false }
    return ((Get-KaringNetNote $Item "type") -eq "urltest")
}

function Promote-KaringNetUrltestRecent {
    param($Use)
    $recent = @(Get-KaringNetNote $Use "recent")
    $preferred = $null
    $other = $null
    $rest = New-Object System.Collections.Generic.List[object]
    foreach ($item in $recent) {
        $typ = Get-KaringNetNote $item "type"
        $tag = Get-KaringNetNote $item "tag"
        if ($typ -eq "urltest" -and $tag -eq $script:UrltestTag -and $null -eq $preferred) {
            $preferred = $item
        } elseif ($typ -eq "urltest" -and $null -eq $other) {
            $other = $item
        } else {
            [void]$rest.Add($item)
        }
    }
    $urltest = $preferred
    if ($null -eq $urltest) { $urltest = $other }
    if ($null -eq $urltest) {
        $urltest = [pscustomobject]@{
            groupid = "urltest"
            type    = "urltest"
            tag     = $script:UrltestTag
        }
    }
    $next = New-Object System.Collections.Generic.List[object]
    [void]$next.Add($urltest)
    foreach ($item in $rest) {
        if ($next.Count -ge 5) { break }
        [void]$next.Add($item)
    }
    $Use.recent = $next.ToArray()
    return $Use
}

function Get-KaringNetUsePath {
    return (Join-Path $script:RuntimeDir "karing_subscribe_use.json")
}

function Invoke-KaringNetWatch {
    param(
        [switch]$DryRun,
        $Proxies,
        $Connections,
        $Use,
        [string]$UsePath
    )
    $closed = @()
    $kickedFrom = $null
    $kickedTo = $null
    $promoted = $false
    $status = Get-KaringNetStatus
    if (-not $status.Port3057) {
        Write-KaringNetLog "watch skip=ports"
        return [pscustomobject]@{
            Changed = $false; GroupNow = @{}; ClosedIds = @(); KickedFrom = $null; KickedTo = $null; Promoted = $false
        }
    }
    if ($null -eq $Proxies) {
        try { $Proxies = Get-KaringNetClashProxies } catch {
            Write-KaringNetLog "watch skip=api"
            return [pscustomobject]@{
                Changed = $false; GroupNow = @{}; ClosedIds = @(); KickedFrom = $null; KickedTo = $null; Promoted = $false
            }
        }
    }
    $now = Get-KaringNetGroupNow $Proxies
    $state = Get-KaringNetState
    $prev = Get-KaringNetNote $state "groupNow"
    $pending = @()
    $pendVal = Get-KaringNetNote $state "cursorCloseNodes"
    if ($null -ne $pendVal) { $pending = @($pendVal) }
    foreach ($from in @(Get-KaringNetCursorSwitchedFrom $prev $now)) {
        $pending = @(Add-KaringNetUniqueName -List $pending -Name $from)
    }
    $holdExpired = Test-KaringNetCursorCloseHoldExpired -State $state -Now (Get-Date)
    $currentNode = Get-KaringNetCursorCurrentNode $now
    if ($pending.Count -gt 0 -and $holdExpired) {
        if ($null -eq $Connections) {
            try { $Connections = Get-KaringNetClashConnections } catch { $Connections = $null }
        }
        $closed = @(Close-KaringNetCursorConnections -Connections $Connections -OnNodes $pending -CurrentNode $currentNode -DryRun:$DryRun)
        Write-KaringNetLog ("watch close ids={0}" -f ($closed -join ","))
        if ($closed.Count -gt 0) {
            $state | Add-Member -NotePropertyName cursorClosedAt -NotePropertyValue (Get-Date).ToString("o") -Force
        }
        $pending = @()
    } elseif ($pending.Count -gt 0) {
        Write-KaringNetLog "watch skip=close-hold"
    }
    $root = $Proxies
    if ($null -ne (Get-KaringNetNote $Proxies "proxies")) { $root = $Proxies.proxies }
    foreach ($k in @($now.Keys)) {
        $cur = [string]$now[$k]
        $browseEmpty = Test-KaringNetEmptyBrowseGroup -Group $k -Current $cur
        if (-not (Test-KaringNetInfoNode $cur) -and -not $browseEmpty) { continue }
        $group = Get-KaringNetNote $root $k
        $rep = Get-KaringNetReplacementNode -Group $group -Current $cur -SkipGpt:$browseEmpty
        if (-not $rep) { continue }
        $kickedFrom = $cur
        $kickedTo = $rep
        if (-not $DryRun) {
            try {
                Set-KaringNetClashGroupNow -Group $k -Name $rep
            } catch {
                Write-KaringNetLog ("watch kick fail group={0} err={1}" -f $k, $_.Exception.Message)
                $kickedFrom = $null
                $kickedTo = $null
                continue
            }
        }
        $now[$k] = $rep
        Write-KaringNetLog ("watch kick group={0} to={1}" -f $k, $rep)
        break
    }
    if (-not $UsePath) { $UsePath = Get-KaringNetUsePath }
    if ($null -eq $Use -and (Test-Path -LiteralPath $UsePath)) {
        $Use = Get-Content -LiteralPath $UsePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if ($null -ne $Use) {
        $item0 = $null
        $recent = Get-KaringNetNote $Use "recent"
        if ($recent -and @($recent).Count -gt 0) { $item0 = @($recent)[0] }
        if (-not (Test-KaringNetIsUrltest $item0)) {
            $since = $null
            $manualSince = Get-KaringNetNote $state "manualSince"
            if ($manualSince) { try { $since = [datetime]$manualSince } catch { $since = $null } }
            if ($null -eq $since) {
                $state | Add-Member -NotePropertyName manualSince -NotePropertyValue (Get-Date).ToString("o") -Force
            } elseif (((Get-Date) - $since).TotalMinutes -ge $script:HoldMinutes) {
                $Use = Promote-KaringNetUrltestRecent $Use
                $promoted = $true
                $state | Add-Member -NotePropertyName manualSince -NotePropertyValue $null -Force
                if (-not $DryRun) {
                    $utf8 = New-Object System.Text.UTF8Encoding $false
                    [System.IO.File]::WriteAllText($UsePath, (($Use | ConvertTo-Json -Depth 40) + "`r`n"), $utf8)
                }
                Write-KaringNetLog "watch promote urltest"
            }
        } else {
            $state | Add-Member -NotePropertyName manualSince -NotePropertyValue $null -Force
        }
    }
    $state | Add-Member -NotePropertyName groupNow -NotePropertyValue (ConvertTo-KaringNetGroupObject $now) -Force
    $state | Add-Member -NotePropertyName cursorCloseNodes -NotePropertyValue @($pending) -Force
    $state | Add-Member -NotePropertyName updatedAt -NotePropertyValue (Get-Date).ToString("o") -Force
    $changed = ($closed.Count -gt 0) -or $kickedTo -or $promoted
    if (-not $DryRun) {
        if (-not (Lock-KaringNet -Command "watch" -TtlSec $script:LockTtlWatchSec)) {
            Write-KaringNetLog "watch skip=lock"
            return [pscustomobject]@{
                Changed = $false; GroupNow = $now; ClosedIds = @(); KickedFrom = $null; KickedTo = $null; Promoted = $false; Locked = $false
            }
        }
        try { Set-KaringNetState $state } finally { Unlock-KaringNet }
    } else {
        Set-KaringNetState $state
    }
    return [pscustomobject]@{
        Changed    = $changed
        GroupNow   = $now
        ClosedIds  = $closed
        KickedFrom = $kickedFrom
        KickedTo   = $kickedTo
        Promoted   = $promoted
    }
}

function Get-KaringNetCursorUrltestRemark {
    return ("Cursor" + [regex]::Unescape('\u81ea\u52a8'))
}

function Get-KaringNetCursorUrltestRegexs {
    $us = [regex]::Unescape('\u7f8e\u56fd')
    $jp = [regex]::Unescape('\u65e5\u672c')
    return @(
        ($us + '|US|unitedstates|' + $us + 'LA'),
        ($jp + '|JP|japan|jp\.')
    )
}

function Get-KaringNetBrowseUrltestRemark {
    return [regex]::Unescape('\u81ea\u52a8\u4f18\u9009')
}

function Get-KaringNetBrowseUrltestRegexs {
    $hk = [regex]::Unescape('\u9999\u6E2F')
    $jp = [regex]::Unescape('\u65E5\u672C')
    $sg = [regex]::Unescape('\u65B0\u52A0\u5761')
    $tw = [regex]::Unescape('\u53F0\u6E7E')
    $opt = [regex]::Unescape('\u4F18\u5316')
    $bei = [regex]::Unescape('\u5907')
    $flower = [regex]::Unescape('\u2740')
    return @(
        ($hk + 'HK|' + $hk + 'HKT|' + $hk + ' ' + $flower + '|' + $hk + $flower + '|' + $hk + $bei),
        ($jp + '-' + $opt + '|' + $jp + 'JP|' + $jp + ' ' + $flower + '|' + $jp + $bei),
        ($sg + 'SG|' + $sg + '-' + $opt + '3|' + $sg + ' ' + $flower + '|' + $sg + $bei),
        ($tw + '-' + $opt + '3|^' + $tw + '-' + $opt + '$')
    )
}

function Get-KaringNetBrowseDiversionNames {
    $yt = [regex]::Unescape('\uD83D\uDCFA') + ' YouTube'
    $gg = [regex]::Unescape('\uD83C\uDF0F') + ' Google'
    return @($yt, $gg)
}

function Test-KaringNetEmptyBrowseGroup {
    param([string]$Group, [string]$Current)
    if ($Current) { return $false }
    if (-not $Group) { return $false }
    $remark = Get-KaringNetBrowseUrltestRemark
    return (($Group -eq $remark) -or ($Group -like ('*-' + $remark)))
}

function Test-KaringNetGptNode {
    param([string]$Name)
    if (-not $Name) { return $false }
    return [bool]($Name -match 'GPT')
}

function Test-KaringNetStringListEqual {
    param($Left, $Right)
    $a = @($Left)
    $b = @($Right)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ([string]$a[$i] -ne [string]$b[$i]) { return $false }
    }
    return $true
}

function Set-KaringNetSubscribeUrltestByRemark {
    param($Subscribe, [string]$Remark, [string[]]$Regexs)
    if ($null -eq $Subscribe) { return $false }
    if (-not $Remark) { return $false }
    if ($null -eq $Regexs) { $Regexs = @() }
    $changed = $false
    $items = Get-KaringNetNote $Subscribe "items"
    foreach ($item in @($items)) {
        $uts = Get-KaringNetNote $item "urltests"
        foreach ($ut in @($uts)) {
            if ([string](Get-KaringNetNote $ut "remark") -ne $Remark) { continue }
            $cur = @(Get-KaringNetNote $ut "regexs")
            if (Test-KaringNetStringListEqual $cur $Regexs) { continue }
            $ut | Add-Member -NotePropertyName regexs -NotePropertyValue @($Regexs) -Force
            $changed = $true
        }
    }
    return $changed
}

function Set-KaringNetSubscribeCursorUrltest {
    param($Subscribe, [string[]]$Regexs)
    return (Set-KaringNetSubscribeUrltestByRemark -Subscribe $Subscribe -Remark (Get-KaringNetCursorUrltestRemark) -Regexs $Regexs)
}

function Set-KaringNetSubscribeBrowseUrltest {
    param($Subscribe, [string[]]$Regexs)
    return (Set-KaringNetSubscribeUrltestByRemark -Subscribe $Subscribe -Remark (Get-KaringNetBrowseUrltestRemark) -Regexs $Regexs)
}

function Update-KaringNetSubscribeUrltestTextByRemark {
    param([string]$Raw, [string]$Remark, [string[]]$Regexs)
    if (-not $Raw) { return $Raw }
    if (-not $Remark) { return $Raw }
    if ($null -eq $Regexs) { $Regexs = @() }
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Regexs) {
        $esc = [string]$r
        $esc = $esc.Replace('\', '\\').Replace('"', '\"')
        [void]$items.Add('"' + $esc + '"')
    }
    $joined = [string]::Join(", ", @($items))
    $newArray = "[" + $joined + "]"
    $pattern = '("remark"\s*:\s*"' + [regex]::Escape($Remark) + '"[\s\S]*?"regexs"\s*:\s*)\[[^\]]*\]'
    return [regex]::Replace($Raw, $pattern, ('${1}' + $newArray))
}

function Update-KaringNetSubscribeCursorUrltestText {
    param([string]$Raw, [string[]]$Regexs)
    return (Update-KaringNetSubscribeUrltestTextByRemark -Raw $Raw -Remark (Get-KaringNetCursorUrltestRemark) -Regexs $Regexs)
}

function Update-KaringNetSubscribeBrowseUrltestText {
    param([string]$Raw, [string[]]$Regexs)
    return (Update-KaringNetSubscribeUrltestTextByRemark -Raw $Raw -Remark (Get-KaringNetBrowseUrltestRemark) -Regexs $Regexs)
}

function Test-KaringNetBrowseDiversion {
    param($Use)
    if ($null -eq $Use) { return $false }
    $remark = Get-KaringNetBrowseUrltestRemark
    $items = @(Get-KaringNetNote $Use "diversion_group")
    foreach ($want in @(Get-KaringNetBrowseDiversionNames)) {
        $hit = $false
        foreach ($d in $items) {
            if ([string](Get-KaringNetNote $d "diversion_name") -ne $want) { continue }
            $hit = $true
            if ([string](Get-KaringNetNote $d "server_groupid") -ne "urltest") { return $false }
            if ([string](Get-KaringNetNote $d "server_name") -ne $remark) { return $false }
        }
        if (-not $hit) { return $false }
    }
    return $true
}

function Set-KaringNetSubscribeUseBrowseDiversion {
    param($Use)
    if ($null -eq $Use) { return $false }
    $remark = Get-KaringNetBrowseUrltestRemark
    $names = @(Get-KaringNetBrowseDiversionNames)
    $changed = $false
    foreach ($d in @(Get-KaringNetNote $Use "diversion_group")) {
        $n = [string](Get-KaringNetNote $d "diversion_name")
        if ($names -notcontains $n) { continue }
        if ([string](Get-KaringNetNote $d "server_groupid") -ne "urltest") {
            $d | Add-Member -NotePropertyName server_groupid -NotePropertyValue "urltest" -Force
            $changed = $true
        }
        if ([string](Get-KaringNetNote $d "server_name") -ne $remark) {
            $d | Add-Member -NotePropertyName server_name -NotePropertyValue $remark -Force
            $changed = $true
        }
    }
    return $changed
}

function Get-KaringNetDesiredProfile {
    return [pscustomobject]@{
        AutoSetSystemProxy          = $true
        ProxyResolveMode            = "proxy"
        TunEnable                   = $true
        ProxyServer                 = "127.0.0.1:3067"
        CursorProxySupport          = "on"
        AutoSelectInterval          = 300
        AutoSelectTolerance         = 150
        SelectedHealthCheckInterval = 300
        BypassMust                  = @(
            "<-loopback>", "<local>", "localhost", "*.local",
            "127.*", "10.*", "172.16.*", "172.17.*", "172.18.*", "172.19.*",
            "172.2*", "172.30.*", "172.31.*", "192.168.*", "10.126.*",
            "*.docker.io", "docker.io", "registry-1.docker.io",
            "*.docker.com", "docker.com",
            "docker.cnb.cool", "*.docker.cnb.cool",
            "*.qxai666.com", "qxai666.com"
        )
        BypassMustNot               = @(
            "*.cursor.sh", "cursor.sh",
            "*.cursor.com", "cursor.com",
            "*.cursorapi.com", "cursorapi.com",
            "*.cursor-cdn.com", "cursor-cdn.com"
        )
        RouteExclude                = @(
            "10.20.0.0/30", "10.126.126.0/24", "10.126.0.0/16",
            "192.168.0.0/16", "172.16.0.0/12", "10.255.255.0/24"
        )
        CursorNoProxy               = @(
            "<loopback>", "localhost", "127.0.0.1", "*.local",
            "10.*", "172.16.*", "172.17.*", "172.18.*", "172.19.*",
            "172.2*", "172.30.*", "172.31.*", "192.168.*"
        )
    }
}

function Get-KaringNetProfileDrift {
    param(
        $Setting,
        [int]$ProxyEnable,
        [string]$ProxyServer,
        [string]$ProxyOverride,
        [string]$CursorProxySupport,
        $Subscribe,
        $Use
    )
    $d = Get-KaringNetDesiredProfile
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($Setting.proxy.auto_set_system_proxy -ne $d.AutoSetSystemProxy) { [void]$reasons.Add("auto_set_system_proxy") }
    if ([string]$Setting.dns.proxy_resolve_mode -ne $d.ProxyResolveMode) { [void]$reasons.Add("proxy_resolve_mode") }
    if ($Setting.tun.enable -ne $d.TunEnable) { [void]$reasons.Add("tun.enable") }
    if ($ProxyEnable -ne 1 -or $ProxyServer -ne $d.ProxyServer) { [void]$reasons.Add("win.proxy") }
    $bypass = @($Setting.proxy.system_proxy_bypass_domain)
    foreach ($need in $d.BypassMust) {
        if ($bypass -notcontains $need) { [void]$reasons.Add("bypass.missing"); break }
    }
    foreach ($ban in $d.BypassMustNot) {
        if ($bypass -contains $ban -or ($ProxyOverride -and $ProxyOverride -match "cursor")) {
            [void]$reasons.Add("bypass.cursor"); break
        }
    }
    $exc = @($Setting.tun.route_exclude_address)
    foreach ($need in $d.RouteExclude) {
        if ($exc -notcontains $need) { [void]$reasons.Add("tun.route_exclude"); break }
    }
    if ($CursorProxySupport -ne $d.CursorProxySupport) { [void]$reasons.Add("cursor.proxySupport") }
    $as = Get-KaringNetNote $Setting "auto_select"
    $asInterval = Get-KaringNetNote $as "interval"
    $asTolerance = Get-KaringNetNote $as "tolerance"
    $asHealth = Get-KaringNetNote $as "selected_health_check_interval"
    if ([int](0 + $asInterval) -ne [int]$d.AutoSelectInterval) { [void]$reasons.Add("auto_select.interval") }
    if ([int](0 + $asTolerance) -ne [int]$d.AutoSelectTolerance) { [void]$reasons.Add("auto_select.tolerance") }
    if ([int](0 + $asHealth) -ne [int]$d.SelectedHealthCheckInterval) { [void]$reasons.Add("auto_select.health_check") }
    if ($null -ne $Subscribe) {
        $remark = Get-KaringNetCursorUrltestRemark
        $wanted = @(Get-KaringNetCursorUrltestRegexs)
        $mismatch = $false
        $items = Get-KaringNetNote $Subscribe "items"
        foreach ($item in @($items)) {
            $uts = Get-KaringNetNote $item "urltests"
            foreach ($ut in @($uts)) {
                if ([string](Get-KaringNetNote $ut "remark") -ne $remark) { continue }
                if (-not (Test-KaringNetStringListEqual (Get-KaringNetNote $ut "regexs") $wanted)) {
                    $mismatch = $true
                    break
                }
            }
            if ($mismatch) { break }
        }
        if ($mismatch) { [void]$reasons.Add("cursor.urltest.regex") }
        $browseRemark = Get-KaringNetBrowseUrltestRemark
        $browseWanted = @(Get-KaringNetBrowseUrltestRegexs)
        $browseMismatch = $false
        $browseFound = $false
        foreach ($item in @($items)) {
            $uts = Get-KaringNetNote $item "urltests"
            foreach ($ut in @($uts)) {
                if ([string](Get-KaringNetNote $ut "remark") -ne $browseRemark) { continue }
                $browseFound = $true
                if (-not (Test-KaringNetStringListEqual (Get-KaringNetNote $ut "regexs") $browseWanted)) {
                    $browseMismatch = $true
                    break
                }
            }
            if ($browseMismatch) { break }
        }
        if ($browseMismatch -or -not $browseFound) { [void]$reasons.Add("browse.urltest.regex") }
    }
    if ($null -ne $Use -and -not (Test-KaringNetBrowseDiversion $Use)) {
        [void]$reasons.Add("browse.diversion")
    }
    return @($reasons)
}

function Update-KaringNetStringList {
    param([System.Collections.IList]$List, [string[]]$Remove, [string[]]$Ensure)
    $next = New-Object System.Collections.Generic.List[string]
    foreach ($item in $List) {
        if ($Remove -contains $item) { continue }
        if (-not $next.Contains($item)) { [void]$next.Add([string]$item) }
    }
    foreach ($item in $Ensure) {
        if (-not $next.Contains($item)) { [void]$next.Add($item) }
    }
    return , @($next)
}

function Sync-KaringNetProfile {
    param(
        [switch]$DryRun,
        $Setting,
        [int]$ProxyEnable,
        [string]$ProxyServer,
        [string]$ProxyOverride,
        [string]$CursorProxySupport,
        [string]$SettingPath,
        [string]$CursorSettingPath,
        [string]$DockerSettingPath,
        [string]$SubscribePath,
        $Subscribe,
        [string]$UsePath,
        $Use
    )
    if (-not (Lock-KaringNet -Command "sync" -TtlSec $script:LockTtlWriteSec)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock"; Wrote = $false; Drift = @() }
    }
    try {
        $d = Get-KaringNetDesiredProfile
        if (-not $SettingPath) { $SettingPath = Join-Path $script:RuntimeDir "karing_setting.json" }
        if (-not $CursorSettingPath) { $CursorSettingPath = Join-Path $env:APPDATA "Cursor\User\settings.json" }
        if (-not $DockerSettingPath) { $DockerSettingPath = Join-Path $env:APPDATA "Docker\settings-store.json" }
        if (-not $SubscribePath) { $SubscribePath = Join-Path $script:RuntimeDir "karing_subscribe.json" }
        if (-not $UsePath) { $UsePath = Get-KaringNetUsePath }
        if ($null -eq $Setting -and (Test-Path -LiteralPath $SettingPath)) {
            $Setting = Get-Content -LiteralPath $SettingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if ($null -eq $Subscribe -and (Test-Path -LiteralPath $SubscribePath)) {
            $Subscribe = Get-Content -LiteralPath $SubscribePath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if ($null -eq $Use -and (Test-Path -LiteralPath $UsePath)) {
            $Use = Get-Content -LiteralPath $UsePath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if ($PSBoundParameters.ContainsKey("ProxyEnable") -eq $false) {
            $reg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
            $ProxyEnable = [int]$reg.ProxyEnable
            $ProxyServer = [string]$reg.ProxyServer
            $ProxyOverride = [string]$reg.ProxyOverride
        }
        if (-not $CursorProxySupport -and (Test-Path -LiteralPath $CursorSettingPath)) {
            $cur = Get-Content -LiteralPath $CursorSettingPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $CursorProxySupport = [string]$cur."http.proxySupport"
        }
        $drift = @(Get-KaringNetProfileDrift -Setting $Setting -ProxyEnable $ProxyEnable -ProxyServer $ProxyServer -ProxyOverride $ProxyOverride -CursorProxySupport $CursorProxySupport -Subscribe $Subscribe -Use $Use)
        if ($drift.Count -eq 0) {
            return [pscustomobject]@{ Ok = $true; Reason = "clean"; Wrote = $false; Drift = @() }
        }
        if ($DryRun) {
            return [pscustomobject]@{ Ok = $true; Reason = "dry-run"; Wrote = $false; Drift = $drift }
        }
        $Setting.proxy.auto_set_system_proxy = $d.AutoSetSystemProxy
        $Setting.dns.proxy_resolve_mode = $d.ProxyResolveMode
        $Setting.tun.enable = $d.TunEnable
        $Setting.proxy.system_proxy_bypass_domain = Update-KaringNetStringList -List $Setting.proxy.system_proxy_bypass_domain -Remove $d.BypassMustNot -Ensure $d.BypassMust
        $Setting.tun.allow_bypass_httpproxy_domains = Update-KaringNetStringList -List $Setting.tun.allow_bypass_httpproxy_domains -Remove $d.BypassMustNot -Ensure $d.BypassMust
        $Setting.tun.route_exclude_address = Update-KaringNetStringList -List $Setting.tun.route_exclude_address -Remove @() -Ensure $d.RouteExclude
        $as = Get-KaringNetNote $Setting "auto_select"
        if ($null -eq $as) {
            $as = [pscustomobject]@{}
            $Setting | Add-Member -NotePropertyName auto_select -NotePropertyValue $as -Force
        }
        $as | Add-Member -NotePropertyName interval -NotePropertyValue $d.AutoSelectInterval -Force
        $as | Add-Member -NotePropertyName tolerance -NotePropertyValue $d.AutoSelectTolerance -Force
        $as | Add-Member -NotePropertyName selected_health_check_interval -NotePropertyValue $d.SelectedHealthCheckInterval -Force
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($SettingPath, (($Setting | ConvertTo-Json -Depth 30) + "`r`n"), $utf8)
        if ($null -ne $Subscribe) {
            $cursorSub = Set-KaringNetSubscribeCursorUrltest -Subscribe $Subscribe -Regexs @(Get-KaringNetCursorUrltestRegexs)
            $browseSub = Set-KaringNetSubscribeBrowseUrltest -Subscribe $Subscribe -Regexs @(Get-KaringNetBrowseUrltestRegexs)
            if (($cursorSub -or $browseSub) -and (Test-Path -LiteralPath $SubscribePath)) {
                $raw = [System.IO.File]::ReadAllText($SubscribePath)
                $next = $raw
                if ($cursorSub) {
                    $next = Update-KaringNetSubscribeCursorUrltestText -Raw $next -Regexs @(Get-KaringNetCursorUrltestRegexs)
                }
                if ($browseSub) {
                    $next = Update-KaringNetSubscribeBrowseUrltestText -Raw $next -Regexs @(Get-KaringNetBrowseUrltestRegexs)
                }
                if ($next -ne $raw) {
                    [System.IO.File]::WriteAllText($SubscribePath, $next, $utf8)
                } else {
                    Write-KaringNetLog "sync skip=subscribe-text"
                }
            }
        }
        if ($null -ne $Use) {
            $useChanged = Set-KaringNetSubscribeUseBrowseDiversion -Use $Use
            if ($useChanged) {
                [System.IO.File]::WriteAllText($UsePath, (($Use | ConvertTo-Json -Depth 40) + "`r`n"), $utf8)
            }
        }
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 1
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyServer -Value $d.ProxyServer
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyOverride -Value ($d.BypassMust -join ";")
        if (Test-Path -LiteralPath $CursorSettingPath) {
            $cur = Get-Content -LiteralPath $CursorSettingPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cur | Add-Member -NotePropertyName "http.proxySupport" -NotePropertyValue $d.CursorProxySupport -Force
            $cur | Add-Member -NotePropertyName "http.noProxy" -NotePropertyValue $d.CursorNoProxy -Force
            [System.IO.File]::WriteAllText($CursorSettingPath, (($cur | ConvertTo-Json -Depth 20) + "`r`n"), $utf8)
        }
        if (Test-Path -LiteralPath $DockerSettingPath) {
            $dock = Get-Content -LiteralPath $DockerSettingPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $dock.ProxyHTTPMode = "system"
            $dock.OverrideProxyHTTP = ""
            $dock.OverrideProxyHTTPS = ""
            $dock.OverrideProxyExclude = "localhost,127.0.0.1,*.local,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,*.qxai666.com,qxai666.com,docker.cnb.cool,*.docker.cnb.cool,*.docker.io,docker.io,registry-1.docker.io,*.docker.com,docker.com"
            [System.IO.File]::WriteAllText($DockerSettingPath, (($dock | ConvertTo-Json -Depth 20) + "`r`n"), $utf8)
        }
        Write-KaringNetLog ("sync applied drift={0}" -f ($drift -join ","))
        return [pscustomobject]@{ Ok = $true; Reason = "applied"; Wrote = $true; Drift = $drift }
    } finally {
        Unlock-KaringNet
    }
}

function Restart-KaringNetCore {
    param(
        [switch]$DryRun,
        [int]$TimeoutSec = 90
    )
    if (-not (Lock-KaringNet -Command "restart" -TtlSec $script:LockTtlWriteSec)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock"; Steps = @() }
    }
    try {
        $steps = @("stop", "start-task", "wait-l0")
        if ($DryRun) {
            return [pscustomobject]@{ Ok = $true; Reason = "dry-run"; Steps = $steps }
        }
        Get-Process -Name "karing", "karingService" -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-ScheduledTask -TaskName $script:KaringTask
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ((Test-KaringNetPort -Port $script:ControlPort) -and (Test-KaringNetPort -Port $script:MixedPort)) {
                try {
                    $conns = Get-KaringNetClashConnections
                    [void](Close-KaringNetCursorConnections -Connections $conns)
                } catch { }
                Write-KaringNetLog "restart ready"
                return [pscustomobject]@{ Ok = $true; Reason = "ready"; Steps = $steps }
            }
            Start-Sleep -Seconds 1
        }
        Write-KaringNetLog "restart timeout"
        return [pscustomobject]@{ Ok = $false; Reason = "timeout"; Steps = $steps }
    } finally {
        Unlock-KaringNet
    }
}

Export-ModuleMember -Function *
