#Requires AutoHotkey v2.0
; Step-by-step startup diagnostic.

#Include Util.ahk
#Include Config.ahk
#Include TableLoader.ahk
#Include BlockList.ahk
#Include JSON.ahk
#Include StateStore.ahk
#Include QueueStore.ahk
#Include MediaStore.ahk
#Include Storage.ahk
#Include WebBridge.ahk
#Include ZaloUI.ahk

results := []
Add(msg) {
    global results
    results.Push(msg)
}

try {
    Add("ScriptDir: " A_ScriptDir)
    Add("Root: " DetectAppRoot())
} catch as err {
    Add("DetectAppRoot FAILED: " err.Message)
}

try {
    cfg := AppConfig.Instance()
    Add("AppConfig OK")
    Add("Browser: " cfg.BrowserExeName)
    Add("Bridge: " cfg.WebBridgeHost ":" cfg.WebBridgePort)
    Add("BlocklistCsv: " cfg.BlocklistCsv " exists=" FileExist(cfg.BlocklistCsv))
} catch as err {
    Add("AppConfig FAILED: " err.Message)
}

if IsSet(cfg) {
    try {
        bl := BlockList(cfg)
        Add("BlockList OK, rules=" bl.rules.Length)
    } catch as err {
        Add("BlockList FAILED: " err.Message)
    }
    try {
        qs := PublishQueueStore(cfg)
        Add("QueueStore OK, entries=" qs.order.Length)
    } catch as err {
        Add("QueueStore FAILED: " err.Message)
    }
    try {
        repo := ListingRepository(cfg)
        Add("ListingRepository OK, listings=" repo.listings.Length)
    } catch as err {
        Add("ListingRepository FAILED: " err.Message)
    }
    try {
        bridge := WebBridge(cfg)
        bridge.Start()
        ui := ZaloUIAdapter(cfg, bridge)
        Add("ZaloUIAdapter OK, Chrome running=" ui.IsRunning())
        bridge.Stop()
    } catch as err {
        Add("ZaloUIAdapter FAILED: " err.Message)
    }
}

report := StrJoin(results, "`n")
path := DetectAppRoot() "\data\diag-startup.txt"
EnsureDir(DetectAppRoot() "\data")
WriteTextFile(path, report)
MsgBox report "`n`nSaved: " path, "Startup diagnostic", "Iconi"
