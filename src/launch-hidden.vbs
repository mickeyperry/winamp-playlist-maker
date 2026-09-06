' launch-hidden.vbs
'
' Explorer verb entry point. wscript.exe is a GUI-subsystem executable with no
' console of its own, and WshShell.Run with window style 0 hides the child
' process from the moment it's created - unlike "powershell.exe -WindowStyle
' Hidden", which can still flash a console window briefly before hiding it.
' This is what actually eliminates the console-window flicker; the worker
' script's own progress dialog (a real GUI window) still shows normally.
Dim fso, shell, scriptDir, workerPath, sysRoot, psExe, cmd, i

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
workerPath = fso.BuildPath(scriptDir, "winamp-playlist.ps1")

sysRoot = shell.ExpandEnvironmentStrings("%SystemRoot%")
psExe = sysRoot & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(psExe) Then psExe = "powershell.exe"

cmd = Chr(34) & psExe & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & workerPath & Chr(34)
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " " & Chr(34) & Replace(WScript.Arguments(i), Chr(34), "") & Chr(34)
Next

shell.Run cmd, 0, False
