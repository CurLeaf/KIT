#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:Trees = @(
    ".superpowers",
    "openspec",
    "tests",
    "design",
    ".cursor/plans"
)

$script:SkipDirNames = @(
    "node_modules",
    ".git",
    ".next",
    ".next-dev",
    ".turbo",
    ".vinext",
    ".output"
)

$script:FixtureDirNames = @("__test__", "_test_", "__tests__")

function ConvertTo-PurgePosix {
    param([string]$Path)
    return ($Path -replace "\\", "/")
}

function Join-PurgeRel {
    param([string]$Root, [string]$Rel)
    $path = $Root
    foreach ($part in @($Rel -split "[\\/]")) {
        if ($part) { $path = Join-Path $path $part }
    }
    return $path
}

function ConvertTo-PurgeRel {
    param([string]$Root, [string]$Full)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
    $fullPath = [IO.Path]::GetFullPath($Full)
    if ($fullPath.Length -le $rootFull.Length) { return "" }
    return (ConvertTo-PurgePosix $fullPath.Substring($rootFull.Length).TrimStart("\", "/"))
}

function Write-PurgeLine {
    param([string]$Message)
    [Console]::WriteLine($Message)
}

function Remove-PurgePath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-PurgeLine "skip (missing) $Path"
        return 0
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
    Write-PurgeLine "removed $Path"
    return 1
}

function Test-PurgeStrayTestName {
    param([string]$Name)
    if ($Name -match "\.Tests\.ps1$") { return $true }
    if ($Name -match "_test\.(py|js)$") { return $true }
    if ($Name -match "\.test\.(c|m)?[jt]sx?$") { return $true }
    return $false
}

function Get-PurgeTrackedSet {
    param([string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath (Join-Path $rootFull ".git"))) { return $null }
    $prev = Get-Location
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        Set-Location -LiteralPath $rootFull
        $top = git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $top) { return $null }
        $topFull = [IO.Path]::GetFullPath("$top".Trim())
        $a = $topFull.TrimEnd("\", "/")
        $b = $rootFull.TrimEnd("\", "/")
        if ([string]::Compare($a, $b, $true) -ne 0) { return $null }
        $set = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
        foreach ($line in @(git ls-files)) {
            $rel = (ConvertTo-PurgePosix "$line".Trim())
            if ($rel) { [void]$set.Add($rel) }
        }
        return $set
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevEap
        Set-Location $prev
    }
}

function Test-PurgeTracked {
    param($Set, [string]$RelPosix)
    if ($null -eq $Set) { return $false }
    $norm = (ConvertTo-PurgePosix $RelPosix).Trim()
    if (-not $norm) { return $false }
    if ($Set.Contains($norm)) { return $true }
    $prefix = $norm.TrimEnd("/") + "/"
    foreach ($item in $Set) {
        if ($item.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Walk-PurgeTree {
    param(
        [string]$Dir,
        [scriptblock]$OnFile,
        [scriptblock]$OnFixtureDir
    )
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $items = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        if (-not $item.PSIsContainer) {
            & $OnFile $item.FullName $item.Name
            continue
        }
        if ($script:SkipDirNames -contains $item.Name) { continue }
        if ($script:FixtureDirNames -contains $item.Name) {
            & $OnFixtureDir $item.FullName
            continue
        }
        Walk-PurgeTree -Dir $item.FullName -OnFile $OnFile -OnFixtureDir $OnFixtureDir
    }
}

function Invoke-PurgeRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )
    $rootFull = [IO.Path]::GetFullPath($Root)
    $script:PurgeRoot = $rootFull
    $script:PurgeTracked = Get-PurgeTrackedSet -Root $rootFull
    $script:PurgeRemoved = 0
    foreach ($rel in $script:Trees) {
        $path = Join-PurgeRel $rootFull $rel
        $relPosix = ConvertTo-PurgePosix $rel
        if (Test-PurgeTracked $script:PurgeTracked $relPosix) { continue }
        $script:PurgeRemoved += Remove-PurgePath $path
    }
    Walk-PurgeTree -Dir $rootFull -OnFile {
        param($full, $name)
        if (-not (Test-PurgeStrayTestName $name)) { return }
        $rel = ConvertTo-PurgeRel $script:PurgeRoot $full
        if (Test-PurgeTracked $script:PurgeTracked $rel) { return }
        $script:PurgeRemoved += Remove-PurgePath $full
    } -OnFixtureDir {
        param($full)
        $rel = ConvertTo-PurgeRel $script:PurgeRoot $full
        if (Test-PurgeTracked $script:PurgeTracked $rel) { return }
        $script:PurgeRemoved += Remove-PurgePath $full
    }
    Write-PurgeLine "purged $($script:PurgeRemoved) path(s)"
    return $script:PurgeRemoved
}

Export-ModuleMember -Function Invoke-PurgeRepo
