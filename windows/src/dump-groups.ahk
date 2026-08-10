#Requires AutoHotkey v2.0
#Include Util.ahk
#Include Config.ahk
#Include GroupRegistry.ahk
#Include ZaloUI.ahk

out := A_ScriptDir "\..\tests\groups-loaded.txt"
EnsureDir(A_ScriptDir "\..\tests")
if FileExist(out)
    FileDelete out
cfg := AppConfig.Instance()
reg := GroupRegistry(cfg)
ui := ZaloUIAdapter(cfg)
raw := ui.CaptureAllGroupListText()
if Trim(raw) = "" {
    manual := GroupRegistry.LoadManualNames(cfg.GroupListManualFile)
    if manual.Length
        raw := StrJoin(manual, "`n")
}
WriteTextFile(cfg.GroupListCaptureFile, raw)
reg.SetDiscovered(GroupRegistry.ParseCapturedNames(
    raw, cfg.GroupListIgnoredLabels))
FileAppend "raw_chars=" StrLen(raw) "`n", out, "UTF-8-RAW"
FileAppend "sources=" reg.SourceGroups().Length "`n", out, "UTF-8-RAW"
for g in reg.SourceGroups()
    FileAppend "S:" g["group_name"] "`n", out, "UTF-8-RAW"
for g in reg.MainGroups()
    FileAppend "M:" g["group_name"] "`n", out, "UTF-8-RAW"
ExitApp 0
