#Requires AutoHotkey v2.0
; Shared test harness logging — stdout + log file.

InitTestLog(logFileName) {
    global TestLogPath := A_ScriptDir "\" logFileName
    try FileDelete TestLogPath
}

TestLog(text := "") {
    global TestLogPath
    try FileAppend text "`n", "*"
    FileAppend text "`n", TestLogPath, "UTF-8-RAW"
}
