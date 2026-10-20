' Start the desktop pet with no visible console (Da Fei Yu).
Dim sh, dir, cmd
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "pet-wf.ps1"""
sh.Run cmd, 0, False
