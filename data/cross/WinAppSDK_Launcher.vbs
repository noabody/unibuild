Option Explicit

Dim shell, fso, scriptPath
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

' Resolve script path dynamically based on the folder containing the VBS file
scriptPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\WinAppSDK_Cleanup.ps1"


' === 1. Check file exists ===
If Not fso.FileExists(scriptPath) Then
    MsgBox "ERROR: Script not found:" & vbCrLf & scriptPath, 16, "WinAppSDK Launcher"
    WScript.Quit
End If

' === 2. Check extension ===
If LCase(fso.GetExtensionName(scriptPath)) <> "ps1" Then
    MsgBox "ERROR: File is not a .ps1 script:" & vbCrLf & scriptPath, 16, "WinAppSDK Launcher"
    WScript.Quit
End If

' === 3. Check MOTW (Zone.Identifier) ===
If fso.FileExists(scriptPath & ":Zone.Identifier") Then
    MsgBox "WARNING: Script is blocked by Mark-of-the-Web." & vbCrLf & _
           "Attempting to unblock now.", 48, "WinAppSDK Launcher"
    On Error Resume Next
    fso.DeleteFile scriptPath & ":Zone.Identifier", True
    On Error GoTo 0
End If

' === 4. Check readability ===
On Error Resume Next
Dim testRead
testRead = fso.OpenTextFile(scriptPath, 1).ReadLine
If Err.Number <> 0 Then
    MsgBox "ERROR: Script cannot be read. Check permissions." & vbCrLf & _
           "Path: " & scriptPath, 16, "WinAppSDK Launcher"
    WScript.Quit
End If
On Error GoTo 0

' === 5. Check PowerShell availability ===
result = shell.Run("powershell.exe -NoLogo -Command ""$PSVersionTable.PSVersion""", 0, True)
If result <> 0 Then
    MsgBox "ERROR: PowerShell is not available on this system.", 16, "WinAppSDK Launcher"
    WScript.Quit
End If

' === 6. Launch elevated PowerShell with full diagnostics ===
Dim cmd
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " & _
      "Start-Process powershell.exe -Verb RunAs -ArgumentList " & _
      "'-NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """'"

result = shell.Run(cmd, 1, False)

If result <> 0 Then
    MsgBox "ERROR: Failed to launch elevated PowerShell." & vbCrLf & _
           "Exit code: " & result, 16, "WinAppSDK Launcher"
Else
    MsgBox "WinAppSDK Cleanup script launched successfully.", 64, "WinAppSDK Launcher"
End If
