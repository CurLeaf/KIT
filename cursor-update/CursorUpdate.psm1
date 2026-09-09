#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:RuntimeDir = Join-Path $env:LOCALAPPDATA "KIT\cursor-update"
$script:InstallRoot = "D:\Program Files\cursor"
$script:InstallRootPinned = $false
$script:DownloadApi = "https://cursor.com/api/download?platform=win32-x64&releaseTrack=stable"
$script:WatchTask = "KIT-CursorUpdate-Watch"
$script:ApplyTask = "KIT-CursorUpdate-Apply"
$script:ProcessLister = $null

function Set-CursorUpdateRuntimeDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:RuntimeDir = $Path
}

function Get-CursorUpdateRuntimeDir { return $script:RuntimeDir }

function Set-CursorUpdateInstallRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:InstallRoot = $Path
    $script:InstallRootPinned = $true
}

function Get-CursorUpdateUninstallRecords {
    $bases = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $out = @()
    foreach ($base in $bases) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $p) { return }
            $name = $null
            try { $name = [string]$p.DisplayName } catch { return }
            if ([string]::IsNullOrWhiteSpace($name)) { return }
            if ($name -notmatch '^Cursor') { return }
            $loc = ""
            try { if ($p.InstallLocation) { $loc = ([string]$p.InstallLocation).TrimEnd("\") } } catch { }
            $ver = ""
            try { if ($p.DisplayVersion) { $ver = [string]$p.DisplayVersion } } catch { }
            $out += [pscustomobject]@{
                DisplayName     = $name
                InstallLocation = $loc
                DisplayVersion  = $ver
                Key             = $_.PSChildName
            }
        }
    }
    return $out
}

function Resolve-CursorUpdateInstallRoot {
    $running = Get-Process -Name "Cursor" -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($null -ne $running) {
        return (Split-Path -Parent $running.Path)
    }
    foreach ($rec in (Get-CursorUpdateUninstallRecords)) {
        if ([string]::IsNullOrWhiteSpace($rec.InstallLocation)) { continue }
        $exe = Join-Path $rec.InstallLocation "Cursor.exe"
        if (Test-Path -LiteralPath $exe) { return $rec.InstallLocation }
    }
    return $script:InstallRoot
}

function Get-CursorUpdateInstallRoot {
    if (-not $script:InstallRootPinned) {
        $detected = Resolve-CursorUpdateInstallRoot
        if (-not [string]::IsNullOrWhiteSpace($detected)) {
            $script:InstallRoot = $detected
        }
    }
    return $script:InstallRoot
}

function Get-CursorUpdateInstallKind {
    $root = Get-CursorUpdateInstallRoot
    foreach ($rec in (Get-CursorUpdateUninstallRecords)) {
        if ([string]::IsNullOrWhiteSpace($rec.InstallLocation)) { continue }
        if (-not [string]::Equals($rec.InstallLocation, $root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $exe = Join-Path $rec.InstallLocation "Cursor.exe"
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        if ($rec.DisplayName -match 'User' -or $rec.Key -match 'DADADADA') { return "user" }
        return "system"
    }
    if ($root -match '\\Users\\.+\\AppData\\') { return "user" }
    return "system"
}
function Get-CursorUpdateExePath { return (Join-Path $script:InstallRoot "Cursor.exe") }
function Get-CursorUpdateProductJsonPath { return (Join-Path $script:InstallRoot "resources\app\product.json") }
function Get-CursorUpdateLockPath { return (Join-Path $script:RuntimeDir "cursor-update.lock") }
function Get-CursorUpdateLogPath { return (Join-Path $script:RuntimeDir "cursor-update.log") }
function Get-CursorUpdateLatestPath { return (Join-Path $script:RuntimeDir "latest.json") }
function Get-CursorUpdatePackageManifestPath { return (Join-Path $script:RuntimeDir "package.json") }
function Get-CursorUpdateToastStatePath { return (Join-Path $script:RuntimeDir "toasted.json") }

function Set-CursorUpdateProcessLister {
    param($Block)
    $script:ProcessLister = $Block
}

function Initialize-CursorUpdateRuntimeDir {
    if (-not (Test-Path -LiteralPath $script:RuntimeDir)) {
        New-Item -ItemType Directory -Path $script:RuntimeDir -Force | Out-Null
    }
}

function Write-CursorUpdateLog {
    param([string]$Message)
    Initialize-CursorUpdateRuntimeDir
    $line = "{0} {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath (Get-CursorUpdateLogPath) -Value $line -Encoding UTF8
}

function Get-CursorUpdateLockInfo {
    $path = Get-CursorUpdateLockPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-CursorUpdateLockStale {
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

function Lock-CursorUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$TtlSec = 60
    )
    Initialize-CursorUpdateRuntimeDir
    $path = Get-CursorUpdateLockPath
    if (Test-Path -LiteralPath $path) {
        $info = Get-CursorUpdateLockInfo
        if (-not (Test-CursorUpdateLockStale $info)) { return $false }
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

function Unlock-CursorUpdate {
    $info = Get-CursorUpdateLockInfo
    if ($null -eq $info) { return }
    if ([int]$info.pid -ne $PID) { return }
    $path = Get-CursorUpdateLockPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function ConvertTo-CursorUpdateVersion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -match '^\d+\.\d+$') { $t = "$t.0" }
    try { return [version]$t } catch { return $null }
}

function Compare-CursorUpdateVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    $a = ConvertTo-CursorUpdateVersion $Left
    $b = ConvertTo-CursorUpdateVersion $Right
    if ($null -eq $a -or $null -eq $b) { return 0 }
    if ($a -lt $b) { return -1 }
    if ($a -gt $b) { return 1 }
    return 0
}

function Get-CursorUpdateLocalVersion {
    $path = Get-CursorUpdateProductJsonPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $j.version) { return $null }
        return [string]$j.version
    } catch {
        return $null
    }
}

function Get-CursorUpdateBusy {
    if ($null -ne $script:ProcessLister) {
        $list = @(& $script:ProcessLister)
        return ($list.Count -gt 0)
    }
    return $null -ne (Get-Process -Name "Cursor" -ErrorAction SilentlyContinue)
}

function Set-CursorUpdateCachedLatest {
    param($Info)
    Initialize-CursorUpdateRuntimeDir
    $payload = @{
        version     = [string]$Info.version
        downloadUrl = [string]$Info.downloadUrl
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Get-CursorUpdateLatestPath), $payload)
}

function Get-CursorUpdateCachedLatest {
    $path = Get-CursorUpdateLatestPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-CursorUpdateSetupUrlKind {
    param(
        [string]$Url,
        [string]$Kind
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    if ($Kind -eq "user") { return ($Url -match '/user-setup/') }
    return ($Url -match '/system-setup/')
}

function Get-CursorUpdatePackage {
    $path = Get-CursorUpdatePackageManifestPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $man = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $man.path -or -not (Test-Path -LiteralPath ([string]$man.path))) { return $null }
        $kind = Get-CursorUpdateInstallKind
        $url = $null
        try { $url = [string]$man.url } catch { $url = $null }
        if (-not (Test-CursorUpdateSetupUrlKind $url $kind)) { return $null }
        return $man
    } catch {
        return $null
    }
}

function Get-CursorUpdateStatus {
    $local = Get-CursorUpdateLocalVersion
    $latestObj = Get-CursorUpdateCachedLatest
    $latest = $null
    if ($null -ne $latestObj -and $latestObj.version) { $latest = [string]$latestObj.version }
    $pkg = Get-CursorUpdatePackage
    $pkgVer = $null
    $pkgReady = $false
    if ($null -ne $pkg -and $pkg.version) {
        $pkgVer = [string]$pkg.version
        $pkgReady = $true
    }
    $busy = Get-CursorUpdateBusy
    $reason = "unknown-latest"
    $readyApply = $false
    if ([string]::IsNullOrWhiteSpace($local)) {
        $reason = "no-local"
    } elseif ([string]::IsNullOrWhiteSpace($latest)) {
        $reason = "unknown-latest"
    } elseif ((Compare-CursorUpdateVersion $local $latest) -ge 0) {
        $reason = "current"
    } elseif ($pkgReady -and (Compare-CursorUpdateVersion $pkgVer $latest) -eq 0) {
        $reason = "ready"
        $readyApply = $true
    } else {
        $reason = "need-fetch"
    }
    return [pscustomobject]@{
        LocalVersion   = $local
        LatestVersion  = $latest
        PackageVersion = $pkgVer
        PackageReady   = $pkgReady
        Busy           = $busy
        ReadyToApply   = $readyApply
        Reason         = $reason
        Ok             = -not [string]::IsNullOrWhiteSpace($local)
    }
}

function Format-CursorUpdateStatusLine {
    param($Status)
    $pkg = $Status.PackageVersion
    if ([string]::IsNullOrWhiteSpace($pkg)) { $pkg = "-" }
    $latest = $Status.LatestVersion
    if ([string]::IsNullOrWhiteSpace($latest)) { $latest = "-" }
    $local = $Status.LocalVersion
    if ([string]::IsNullOrWhiteSpace($local)) { $local = "-" }
    $ready = 0
    if ($Status.PackageReady) { $ready = 1 }
    $busy = 0
    if ($Status.Busy) { $busy = 1 }
    $apply = 0
    if ($Status.ReadyToApply) { $apply = 1 }
    return "local={0} latest={1} package={2} ready={3} busy={4} apply={5} reason={6}" -f $local, $latest, $pkg, $ready, $busy, $apply, $Status.Reason
}

$script:LatestProvider = $null
$script:Downloader = $null

function Set-CursorUpdateLatestProvider {
    param($Block)
    $script:LatestProvider = $Block
}

function Set-CursorUpdateDownloader {
    param($Block)
    $script:Downloader = $Block
}

function ConvertTo-CursorUpdateSystemSetupUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $u = $Url -replace '/user-setup/', '/system-setup/'
    $u = $u -replace 'CursorUserSetup-', 'CursorSetup-'
    return $u
}

function ConvertTo-CursorUpdateSetupUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Kind
    )
    if ([string]::IsNullOrWhiteSpace($Kind)) { $Kind = Get-CursorUpdateInstallKind }
    if ($Kind -eq "user") {
        $u = $Url -replace '/system-setup/', '/user-setup/'
        $u = $u -replace '(?<!User)CursorSetup-', 'CursorUserSetup-'
        return $u
    }
    return (ConvertTo-CursorUpdateSystemSetupUrl $Url)
}

function ConvertFrom-CursorUpdateDownloadJson {
    param([Parameter(Mandatory = $true)][string]$Json)
    $j = $Json | ConvertFrom-Json
    $url = ConvertTo-CursorUpdateSetupUrl -Url ([string]$j.downloadUrl) -Kind (Get-CursorUpdateInstallKind)
    return [pscustomobject]@{
        version     = [string]$j.version
        downloadUrl = $url
    }
}

function Get-CursorUpdateLatest {
    if ($null -ne $script:LatestProvider) {
        $info = & $script:LatestProvider
        Set-CursorUpdateCachedLatest $info
        return $info
    }
    $raw = Invoke-WebRequest -Uri $script:DownloadApi -UseBasicParsing -TimeoutSec 30
    $info = ConvertFrom-CursorUpdateDownloadJson $raw.Content
    Set-CursorUpdateCachedLatest $info
    return $info
}

function Invoke-CursorUpdateFetch {
    if (-not (Lock-CursorUpdate -Command "fetch" -TtlSec 600)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock"; Version = $null; Path = $null }
    }
    try {
        $local = Get-CursorUpdateLocalVersion
        $info = Get-CursorUpdateLatest
        if ([string]::IsNullOrWhiteSpace($local)) {
            return [pscustomobject]@{ Ok = $false; Reason = "fail"; Version = $null; Path = $null }
        }
        if ((Compare-CursorUpdateVersion $local ([string]$info.version)) -ge 0) {
            return [pscustomobject]@{ Ok = $true; Reason = "current"; Version = [string]$info.version; Path = $null }
        }
        $pkg = Get-CursorUpdatePackage
        if ($null -ne $pkg -and (Compare-CursorUpdateVersion ([string]$pkg.version) ([string]$info.version)) -eq 0) {
            return [pscustomobject]@{ Ok = $true; Reason = "have"; Version = [string]$pkg.version; Path = [string]$pkg.path }
        }
        Initialize-CursorUpdateRuntimeDir
        $kind = Get-CursorUpdateInstallKind
        if ($kind -eq "user") {
            $name = "CursorUserSetup-x64-{0}.exe" -f $info.version
        } else {
            $name = "CursorSetup-x64-{0}.exe" -f $info.version
        }
        $dest = Join-Path $script:RuntimeDir $name
        $part = "$dest.part"
        if ($null -ne $script:Downloader) {
            & $script:Downloader $info.downloadUrl $part
        } else {
            Invoke-WebRequest -Uri $info.downloadUrl -OutFile $part -UseBasicParsing -TimeoutSec 600
        }
        if (-not (Test-Path -LiteralPath $part)) {
            return [pscustomobject]@{ Ok = $false; Reason = "fail"; Version = [string]$info.version; Path = $null }
        }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        Move-Item -LiteralPath $part -Destination $dest -Force
        $man = @{ version = [string]$info.version; path = $dest; url = [string]$info.downloadUrl } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText((Get-CursorUpdatePackageManifestPath), $man)
        Write-CursorUpdateLog ("fetch downloaded {0}" -f $info.version)
        return [pscustomobject]@{ Ok = $true; Reason = "downloaded"; Version = [string]$info.version; Path = $dest }
    } catch {
        Write-CursorUpdateLog ("fetch fail {0}" -f $_.Exception.Message)
        return [pscustomobject]@{ Ok = $false; Reason = "fail"; Version = $null; Path = $null }
    } finally {
        Unlock-CursorUpdate
    }
}

$script:ToastShower = $null

function Set-CursorUpdateToastShower {
    param($Block)
    $script:ToastShower = $Block
}

function Get-CursorUpdateToastState {
    $path = Get-CursorUpdateToastStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Set-CursorUpdateToastState {
    param([Parameter(Mandatory = $true)][string]$Version)
    Initialize-CursorUpdateRuntimeDir
    $payload = @{ version = $Version; at = (Get-Date).ToString("o") } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Get-CursorUpdateToastStatePath), $payload)
}

function Test-CursorUpdateToastNeeded {
    param($Status)
    if ($null -eq $Status) { return $false }
    if (-not $Status.ReadyToApply) { return $false }
    if (-not $Status.Busy) { return $false }
    $st = Get-CursorUpdateToastState
    if ($null -ne $st -and [string]$st.version -eq [string]$Status.PackageVersion) { return $false }
    return $true
}

function Get-CursorUpdateModulePath {
    return Join-Path $PSScriptRoot "CursorUpdate.psm1"
}

function Get-CursorUpdateProtocolCommand {
    $vbs = Join-Path $PSScriptRoot "cursor-update-apply.vbs"
    return ('wscript.exe "{0}"' -f $vbs)
}

function New-CursorUpdateToastXml {
    param([Parameter(Mandatory = $true)][string]$Version)
    return @"
<toast activationType="protocol" launch="cursor-update://apply">
  <visual>
    <binding template="ToastGeneric">
      <text>Cursor update ready</text>
      <text>Version $Version is downloaded. Click to close Cursor and install.</text>
    </binding>
  </visual>
  <actions>
    <action content="Restart and update" activationType="protocol" arguments="cursor-update://apply"/>
  </actions>
</toast>
"@
}

function Get-CursorUpdateToastAumid {
    return "KIT.CursorUpdate"
}

function Get-CursorUpdateToastShortcutPath {
    return (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\KIT Cursor Update.lnk")
}

function Enable-CursorUpdateOsToast {
    $push = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"
    if (-not (Test-Path -LiteralPath $push)) {
        New-Item -Path $push -Force | Out-Null
    }
    $cur = $null
    try { $cur = (Get-ItemProperty -LiteralPath $push -Name "ToastEnabled" -ErrorAction Stop).ToastEnabled } catch { $cur = $null }
    if ($cur -ne 1) {
        New-ItemProperty -Path $push -Name "ToastEnabled" -Value 1 -PropertyType DWord -Force | Out-Null
        Write-CursorUpdateLog "toast enable-os"
    }
}

function Initialize-CursorUpdateLnkAumidType {
    if ("KIT.CursorUpdate.LnkAumid" -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace KIT.CursorUpdate {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class ShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    public interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxPath, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cchMaxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cchMaxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cchMaxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out uint cProps);
        [PreserveSig] int GetAt(uint iProp, out PropertyKey pkey);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant pv);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant pv);
        [PreserveSig] int Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid f, uint p) { fmtid = f; pid = p; }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr pointerValue;
        public int pad1;
        public int pad2;
    }

    public static class LnkAumid {
        public static void Create(string lnkPath, string target, string args, string workDir, string icon, string aumid) {
            var sl = (IShellLinkW)new ShellLink();
            sl.SetPath(target);
            sl.SetArguments(args ?? "");
            if (!string.IsNullOrEmpty(workDir)) { sl.SetWorkingDirectory(workDir); }
            if (!string.IsNullOrEmpty(icon)) { sl.SetIconLocation(icon, 0); }
            var store = (IPropertyStore)sl;
            var key = new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
            var pv = new PropVariant();
            pv.vt = 31;
            pv.pointerValue = Marshal.StringToCoTaskMemUni(aumid);
            try {
                int hr = store.SetValue(ref key, ref pv);
                if (hr != 0) { Marshal.ThrowExceptionForHR(hr); }
                hr = store.Commit();
                if (hr != 0) { Marshal.ThrowExceptionForHR(hr); }
            } finally {
                Marshal.FreeCoTaskMem(pv.pointerValue);
            }
            var pf = (IPersistFile)sl;
            pf.Save(lnkPath, true);
        }
    }

    public static class ProcessAumid {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
        public static void Set(string aumid) {
            int hr = SetCurrentProcessExplicitAppUserModelID(aumid);
            if (hr != 0) { Marshal.ThrowExceptionForHR(hr); }
        }
    }
}
"@
}

function Register-CursorUpdateToastApp {
    Enable-CursorUpdateOsToast
    $aumid = Get-CursorUpdateToastAumid
    $idKey = "HKCU:\SOFTWARE\Classes\AppUserModelId\$aumid"
    if (-not (Test-Path -LiteralPath $idKey)) {
        New-Item -Path $idKey -Force | Out-Null
    }
    New-ItemProperty -Path $idKey -Name "DisplayName" -Value "KIT Cursor Update" -PropertyType String -Force | Out-Null
    $setKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\$aumid"
    if (-not (Test-Path -LiteralPath $setKey)) {
        New-Item -Path $setKey -Force | Out-Null
    }
    New-ItemProperty -Path $setKey -Name "Enabled" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $setKey -Name "ShowInActionCenter" -Value 1 -PropertyType DWord -Force | Out-Null
    $lnk = Get-CursorUpdateToastShortcutPath
    $dir = Split-Path -Parent $lnk
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cli = Join-Path $PSScriptRoot "cursor-update.ps1"
    $lnkArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$cli`" status"
    $icon = Get-CursorUpdateExePath
    if (-not (Test-Path -LiteralPath $icon)) { $icon = "" }
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
    Initialize-CursorUpdateLnkAumidType
    [KIT.CursorUpdate.LnkAumid]::Create($lnk, $ps, $lnkArgs, $PSScriptRoot, $icon, $aumid)
    Write-CursorUpdateLog "toast register-app"
    return $true
}

function Show-CursorUpdateToast {
    param([Parameter(Mandatory = $true)][string]$Version)
    $xml = New-CursorUpdateToastXml $Version
    try {
        if ($null -ne $script:ToastShower) {
            & $script:ToastShower $xml
        } else {
            Register-CursorUpdateToastApp | Out-Null
            Initialize-CursorUpdateLnkAumidType
            [KIT.CursorUpdate.ProcessAumid]::Set((Get-CursorUpdateToastAumid))
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
            $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
            $doc.LoadXml($xml)
            $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier((Get-CursorUpdateToastAumid)).Show($toast)
        }
        Set-CursorUpdateToastState $Version
        Write-CursorUpdateLog ("toast {0}" -f $Version)
        return $true
    } catch {
        Write-CursorUpdateLog ("toast fail {0}" -f $_.Exception.Message)
        return $false
    }
}

function Register-CursorUpdateProtocol {
    $cmd = Get-CursorUpdateProtocolCommand
    $base = "HKCU:\Software\Classes\cursor-update"
    New-Item -Path $base -Force | Out-Null
    Set-ItemProperty -Path $base -Name "(default)" -Value "URL:cursor-update"
    New-ItemProperty -Path $base -Name "URL Protocol" -Value "" -PropertyType String -Force | Out-Null
    $open = Join-Path $base "shell\open\command"
    New-Item -Path $open -Force | Out-Null
    Set-ItemProperty -Path $open -Name "(default)" -Value $cmd
    return $true
}

$script:Elevated = $null
$script:ProcessStopper = $null
$script:Installer = $null
$script:Relauncher = $null
$script:Detacher = $null

function Set-CursorUpdateElevated { param($Value) $script:Elevated = $Value }
function Set-CursorUpdateProcessStopper { param($Block) $script:ProcessStopper = $Block }
function Set-CursorUpdateInstaller { param($Block) $script:Installer = $Block }
function Set-CursorUpdateRelauncher { param($Block) $script:Relauncher = $Block }
function Set-CursorUpdateDetacher { param($Block) $script:Detacher = $Block }

function Test-CursorUpdateAdmin {
    if ($null -ne $script:Elevated) { return [bool]$script:Elevated }
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-CursorUpdateProcesses {
    if ($null -ne $script:ProcessStopper) { & $script:ProcessStopper; return }
    Get-Process -Name "Cursor", "cursor-inno-updater" -ErrorAction SilentlyContinue | Stop-Process -Force
    $root = Get-CursorUpdateInstallRoot
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        if ($_.Name -match '^CursorSetup') { return $true }
        if ($_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        return $false
    } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}

function Test-CursorUpdateInstallUnlocked {
    if ($null -ne $script:ProcessLister) {
        return ((@(& $script:ProcessLister)).Count -eq 0)
    }
    if (Get-Process -Name "Cursor", "cursor-inno-updater" -ErrorAction SilentlyContinue) { return $false }
    $root = Get-CursorUpdateInstallRoot
    $hit = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return @($hit).Count -eq 0
}

function Get-CursorUpdateInstallerArgs {
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [string]$Kind
    )
    if ([string]::IsNullOrWhiteSpace($Kind)) { $Kind = Get-CursorUpdateInstallKind }
    $args = @(
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
        ('/DIR="{0}"' -f $Dir)
    )
    if ($Kind -eq "user") {
        $args += "/CURRENTUSER"
    } else {
        $args += "/ALLUSERS"
    }
    return $args
}

function Wait-CursorUpdateUnlocked {
    param([int]$TimeoutSec = 60)
    $until = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if (Test-CursorUpdateInstallUnlocked) { return $true }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $until)
    return (Test-CursorUpdateInstallUnlocked)
}

function Invoke-CursorUpdateApply {
    param([switch]$FromTask)
    if (-not $FromTask) {
        if ($null -ne $script:Detacher) {
            & $script:Detacher
        } else {
            $cli = Join-Path $PSScriptRoot "cursor-update.ps1"
            Start-Process -FilePath "powershell.exe" -ArgumentList @(
                "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
                "-ExecutionPolicy", "Bypass", "-File", $cli, "apply", "-FromTask"
            ) -WindowStyle Hidden | Out-Null
        }
        return [pscustomobject]@{ Ok = $true; Reason = "detached" }
    }
    if (-not (Lock-CursorUpdate -Command "apply" -TtlSec 900)) {
        return [pscustomobject]@{ Ok = $false; Reason = "lock" }
    }
    try {
        $status = Get-CursorUpdateStatus
        if ($status.Reason -eq "current") {
            return [pscustomobject]@{ Ok = $true; Reason = "current" }
        }
        $pkg = Get-CursorUpdatePackage
        if ($null -eq $pkg) {
            return [pscustomobject]@{ Ok = $false; Reason = "no-package" }
        }
        $root = Get-CursorUpdateInstallRoot
        if ($root -match "Program Files" -and -not (Test-CursorUpdateAdmin)) {
            return [pscustomobject]@{ Ok = $false; Reason = "admin" }
        }
        Stop-CursorUpdateProcesses
        if (-not (Wait-CursorUpdateUnlocked -TimeoutSec 60)) {
            return [pscustomobject]@{ Ok = $false; Reason = "wait" }
        }
        $flag = Join-Path $script:RuntimeDir "cursor-update.flag"
        [System.IO.File]::WriteAllText($flag, "")
        $kind = Get-CursorUpdateInstallKind
        $instArgs = Get-CursorUpdateInstallerArgs -Dir $root -Kind $kind
        if ($null -ne $script:Installer) {
            & $script:Installer ([string]$pkg.path) $flag
        } else {
            Write-CursorUpdateLog ("apply install kind={0} dir={1}" -f $kind, $root)
            $p = Start-Process -FilePath ([string]$pkg.path) -ArgumentList $instArgs -Wait -PassThru
            if ($p.ExitCode -ne 0) {
                Write-CursorUpdateLog ("apply install exit={0}" -f $p.ExitCode)
                return [pscustomobject]@{ Ok = $false; Reason = "install" }
            }
        }
        $ver = Get-CursorUpdateLocalVersion
        if ((Compare-CursorUpdateVersion $ver ([string]$pkg.version)) -ne 0) {
            return [pscustomobject]@{ Ok = $false; Reason = "install" }
        }
        if (Test-Path -LiteralPath ([string]$pkg.path)) {
            Remove-Item -LiteralPath ([string]$pkg.path) -Force
        }
        $man = Get-CursorUpdatePackageManifestPath
        if (Test-Path -LiteralPath $man) { Remove-Item -LiteralPath $man -Force }
        if (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag -Force }
        if ($null -ne $script:Relauncher) {
            & $script:Relauncher
        } else {
            Start-Process -FilePath (Get-CursorUpdateExePath) | Out-Null
        }
        Write-CursorUpdateLog ("apply updated {0}" -f $ver)
        return [pscustomobject]@{ Ok = $true; Reason = "updated" }
    } catch {
        Write-CursorUpdateLog ("apply fail {0}" -f $_.Exception.Message)
        return [pscustomobject]@{ Ok = $false; Reason = "install" }
    } finally {
        Unlock-CursorUpdate
    }
}

$script:TaskRunner = $null
$script:WatchLogonTask = "KIT-CursorUpdate-WatchLogon"
function Set-CursorUpdateTaskRunner { param($Block) $script:TaskRunner = $Block }

function Get-CursorUpdateSchtasksDate {
    param([datetime]$Date)
    return $Date.ToString([cultureinfo]::CurrentCulture.DateTimeFormat.ShortDatePattern)
}

function Invoke-CursorUpdateSchtasks {
    param([string[]]$ArgumentList)
    if ($null -ne $script:TaskRunner) {
        return [bool](& $script:TaskRunner $ArgumentList)
    }
    & schtasks.exe @ArgumentList | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-CursorUpdateWatch {
    $fetched = $false
    $status = Get-CursorUpdateStatus
    if ($status.Reason -eq "unknown-latest" -or $status.Reason -eq "need-fetch") {
        $f = Invoke-CursorUpdateFetch
        $fetched = ($f.Reason -eq "downloaded" -or $f.Reason -eq "have")
        if ($f.Reason -eq "lock") {
            return [pscustomobject]@{ Ok = $false; Fetched = $false; Toast = $false; Reason = "lock" }
        }
        $status = Get-CursorUpdateStatus
    }
    $toast = $false
    if (Test-CursorUpdateToastNeeded $status) {
        $toast = Show-CursorUpdateToast ([string]$status.PackageVersion)
    }
    return [pscustomobject]@{
        Ok      = $true
        Fetched = $fetched
        Toast   = $toast
        Reason  = $status.Reason
    }
}

function Update-CursorUpdateSettingsJson {
    param([Parameter(Mandatory = $true)][string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { $Raw = "{}" }
    $j = $Raw | ConvertFrom-Json
    $j | Add-Member -NotePropertyName "update.mode" -NotePropertyValue "none" -Force
    return ($j | ConvertTo-Json -Depth 8)
}

function Install-CursorUpdateHost {
    param([string]$SettingsPath)
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        $SettingsPath = Join-Path $env:APPDATA "Cursor\User\settings.json"
    }
    $protocol = $false
    try { $protocol = Register-CursorUpdateProtocol } catch { $protocol = $false }
    try { Register-CursorUpdateToastApp | Out-Null } catch { }
    $settingsOk = $false
    try {
        $raw = "{}"
        if (Test-Path -LiteralPath $SettingsPath) {
            $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
        } else {
            $dir = Split-Path -Parent $SettingsPath
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
        $next = Update-CursorUpdateSettingsJson $raw
        [System.IO.File]::WriteAllText($SettingsPath, $next)
        $settingsOk = $true
    } catch {
        $settingsOk = $false
    }
    $cli = Join-Path $PSScriptRoot "cursor-update.ps1"
    $watchVbs = Join-Path $PSScriptRoot "cursor-update.vbs"
    $ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $watchTr = ('wscript.exe "{0}"' -f $watchVbs)
    $applyTr = ('"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" apply -FromTask' -f $ps, $cli)
    $watchCmd = @(
        "/Create", "/TN", $script:WatchTask, "/TR", $watchTr,
        "/SC", "HOURLY", "/RL", "HIGHEST", "/F"
    )
    $logonCmd = @(
        "/Create", "/TN", $script:WatchLogonTask, "/TR", $watchTr,
        "/SC", "ONLOGON", "/RL", "HIGHEST", "/F"
    )
    $sd = Get-CursorUpdateSchtasksDate (Get-Date -Year 2099 -Month 12 -Day 31)
    $applyCmd = @(
        "/Create", "/TN", $script:ApplyTask, "/TR", $applyTr,
        "/SC", "ONCE", "/ST", "00:00", "/SD", $sd, "/RL", "HIGHEST", "/F"
    )
    $watchTask = (Invoke-CursorUpdateSchtasks $watchCmd) -and (Invoke-CursorUpdateSchtasks $logonCmd)
    $applyTask = Invoke-CursorUpdateSchtasks $applyCmd
    return [pscustomobject]@{
        Ok        = ($protocol -and $settingsOk)
        Protocol  = $protocol
        WatchTask = $watchTask
        ApplyTask = $applyTask
        Settings  = $settingsOk
    }
}
