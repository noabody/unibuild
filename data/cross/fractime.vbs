Option Explicit

Dim shell, fso, scriptPath
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

' Resolve fractime.ps1 dynamically based on the folder containing this VBS file
scriptPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\fractime.ps1"

' Launch PowerShell silently
shell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """", 0, False
