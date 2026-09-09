Option Explicit
Dim sh, fso, root, cmd, rc
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & root & "\karing-net.ps1"" watch"
rc = sh.Run(cmd, 0, True)
WScript.Quit rc
