#Requires AutoHotkey v2.0
#SingleInstance Force

#Include Util.ahk
#Include JSON.ahk
#Include Config.ahk
#Include TableLoader.ahk
#Include GroupRegistry.ahk
#Include BlockList.ahk
#Include Parser.ahk
#Include Storage.ahk
#Include StateStore.ahk
#Include Composer.ahk
#Include ZaloUI.ahk
#Include Harvester.ahk

logPath := A_ScriptDir "\..\tests\diag-harvest.log"
try FileDelete logPath

Log(msg) {
    global logPath
    FileAppend FormatTime(, "HH:mm:ss") " " msg "`n", logPath, "UTF-8-RAW"
}

cfg := AppConfig.Instance()
reg := GroupRegistry(cfg)
ui := ZaloUIAdapter(cfg)
harvester := MessageHarvester(cfg, ui, reg, BlockList(cfg), HarvestStateStore(cfg), ListingRepository(cfg))

Log("root=" cfg.Root)
Log("Zalo running: " ui.IsRunning())
for g in reg.SourceGroups()
    Log("SOURCE: [" g["group_name"] "]")
for g in reg.MainGroups()
    Log("MAIN: [" g["group_name"] "]")

try {
    summary := harvester.HarvestAll()
    Log(Format("DONE groups={1} saved={2} blocked={3} dup={4} invalid={5}",
        summary["groups"], summary["saved"], summary["blocked"], summary["duplicate"], summary["invalid"]))
    for err in summary["errors"]
        Log("ERR: " err)
} catch as e {
    Log("FATAL: " e.Message)
}

ExitApp 0
