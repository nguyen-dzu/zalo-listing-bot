#Requires AutoHotkey v2.0
; Pinpoint which #Include fails during Bot.ahk load (exit code 2).

Mark(step) {
    global LOAD_CHECK_LOG
    FileAppend FormatTime(, "HH:mm:ss") " " step "`n", LOAD_CHECK_LOG, "UTF-8"
}

root := RegExReplace(A_ScriptDir, "\\src$", "")
global LOAD_CHECK_LOG := root "\data\load-check.log"
if !DirExist(root "\data")
    DirCreate root "\data"
try FileDelete(LOAD_CHECK_LOG)
Mark("start")

#Include Util.ahk
Mark("Util.ahk")

#Include JSON.ahk
Mark("JSON.ahk")

#Include Config.ahk
Mark("Config.ahk")

#Include TableLoader.ahk
Mark("TableLoader.ahk")

#Include GroupRegistry.ahk
Mark("GroupRegistry.ahk")

#Include SourceGroupFile.ahk
Mark("SourceGroupFile.ahk")

#Include BotControlWindow.ahk
Mark("BotControlWindow.ahk")

#Include BlockList.ahk
Mark("BlockList.ahk")

#Include Parser.ahk
Mark("Parser.ahk")

#Include Storage.ahk
Mark("Storage.ahk")

#Include StateStore.ahk
Mark("StateStore.ahk")

#Include QueueStore.ahk
Mark("QueueStore.ahk")

#Include MediaStore.ahk
Mark("MediaStore.ahk")

#Include Composer.ahk
Mark("Composer.ahk")

#Include Acc.ahk
Mark("Acc.ahk")

#Include ZaloUI.ahk
Mark("ZaloUI.ahk")

#Include GroupActivity.ahk
Mark("GroupActivity.ahk")

#Include MediaCapturer.ahk
Mark("MediaCapturer.ahk")

#Include Harvester.ahk
Mark("Harvester.ahk")

#Include Publisher.ahk
Mark("Publisher.ahk")

Mark("all modules loaded")
MsgBox "Tat ca module load OK.`nLog: " LOAD_CHECK_LOG, "Load check", "Iconi"
