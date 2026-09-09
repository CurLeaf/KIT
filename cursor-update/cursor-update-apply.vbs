Option Explicit
Dim sh, fso, root, cmd, rc
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
rc = sh.Run("schtasks.exe /Run /TN KIT-CursorUpdate-Apply", 0, True)
If rc = 0 Then
    WScript.Quit 0
End If
cmd = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & root & "\cursor-update.ps1"" apply"
rc = sh.Run(cmd, 0, False)
WScript.Quit rc
