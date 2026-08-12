#Requires AutoHotkey v2.0
; ZaloUI.ahk — Zalo Web adapter: Harvest window (read) + Publish window (send)

#Include WebBridge.ahk

class ZaloUIAdapter {
    __New(config, bridge := 0) {
        this.config := config
        this.bridge := bridge ? bridge : WebBridge(config)
        this.publishGroup := ""
        this.currentGroup := ""
        this.lastConversationFingerprint := ""
        this.lastConversationGroup := ""
        this.lastOpenedGroup := ""
        CoordMode("Mouse", "Screen")
    }

    _HarvestWindowTitle() {
        title := this.config.HarvestWindowTitle
        return title != "" ? title : "[Harvest]"
    }

    _PublishWindowTitle() {
        title := this.config.PublishWindowTitle
        return title != "" ? title : "[Publish]"
    }

    _HarvestWindowMatch() {
        return this._HarvestWindowTitle()
            . " ahk_exe " this.config.BrowserExeName
            . " ahk_class Chrome_WidgetWin_1"
    }

    _PublishWindowMatch() {
        return this._PublishWindowTitle()
            . " ahk_exe " this.config.BrowserExeName
            . " ahk_class Chrome_WidgetWin_1"
    }

    _WindowExists(match) {
        return WinExist(match)
    }

    IsRunning() {
        return this._WindowExists(this._HarvestWindowMatch())
            || this._WindowExists(this._PublishWindowMatch())
    }

    ActivateHarvest() {
        match := this._HarvestWindowMatch()
        if !this._WindowExists(match)
            throw Error("Cửa sổ Harvest chưa mở. Bookmark: " this.config.HarvestUrl)
        WinActivate match
        if !WinWaitActive("ahk_exe " this.config.BrowserExeName,, 4)
            throw Error("Không kích hoạt được cửa sổ Harvest.")
        Sleep 150
        return true
    }

    ActivatePublish() {
        match := this._PublishWindowMatch()
        if !this._WindowExists(match)
            throw Error("Cửa sổ Publish chưa mở. Bookmark: " this.config.PublishUrl)
        WinActivate match
        if !WinWaitActive("ahk_exe " this.config.BrowserExeName,, 4)
            throw Error("Không kích hoạt được cửa sổ Publish.")
        Sleep 150
        return true
    }

    Activate() {
        if this._WindowExists(this._HarvestWindowMatch())
            return this.ActivateHarvest()
        return this.ActivatePublish()
    }

    EnsureNormalized() {
        for match in [this._HarvestWindowMatch(), this._PublishWindowMatch()] {
            hwnd := WinExist(match)
            if !hwnd
                continue
            if WinGetMinMax("ahk_id " hwnd) != 0 {
                WinRestore "ahk_id " hwnd
                Sleep 300
            }
            targetW := Integer(this.config.NormalizedWindowWidth)
            targetH := Integer(this.config.NormalizedWindowHeight)
            if targetW >= 800 && targetH >= 600 {
                WinMove ,, targetW, targetH, "ahk_id " hwnd
                Sleep 200
            }
        }
        return true
    }

    EnsureWindowState() {
        if this.config.StartupMaximizeBrowser {
            for match in [this._HarvestWindowMatch(), this._PublishWindowMatch()] {
                if WinExist(match)
                    WinMaximize match
            }
            Sleep 300
            return true
        }
        return this.EnsureNormalized()
    }

    _FocusComposeBoxPublish() {
        this.ActivatePublish()
        try this.bridge.RunCommand("focus_compose", Map(), 5000, "publish")
        catch {
            WinGetClientPos(&x, &y, &w, &h, this._PublishWindowMatch())
            Click x + Round(w * 0.42), y + Round(h * 0.88)
            Sleep this.config.PasteDelayMs
        }
    }

    _FocusMessagePaneHarvest() {
        this.ActivateHarvest()
        WinGetClientPos(&x, &y, &w, &h, this._HarvestWindowMatch())
        Click x + Round(w * 0.55), y + Round(h * 0.45)
        Sleep this.config.CaptureSettleMs
    }

    OpenGroup(groupName, focus := "read") {
        this.ActivateHarvest()
        result := this.bridge.RunCommand("navigate", Map("group", groupName), 20000, "harvest")
        openedGroup := result.Has("group") ? result["group"] : groupName
        this.currentGroup := openedGroup
        this.lastOpenedGroup := openedGroup
        if focus = "send"
            this._FocusComposeBoxPublish()
        else
            this._FocusMessagePaneHarvest()
        return true
    }

    CaptureConversationText(method := "") {
        this.ActivateHarvest()
        result := this.bridge.RunCommand("scan", Map(), 20000, "harvest")
        captured := result.Has("text") ? result["text"] : ""
        this._GuardStickyConversation(captured)
        return captured
    }

    _GuardStickyConversation(captured) {
        text := Trim(NormalizeNewlines(captured))
        if StrLen(text) < 80 || this.currentGroup = ""
            return
        prefix := SubStr(RegExReplace(text, "\s+", " "), 1, 160)
        fp := FnvHash(prefix)
        if this.lastConversationFingerprint != ""
            && fp = this.lastConversationFingerprint
            && this.lastConversationGroup != ""
            && this.lastConversationGroup != this.currentGroup {
            throw Error("OpenGroup không chuyển chat: vẫn nội dung của '"
                . this.lastConversationGroup "' khi mở '" this.currentGroup "'.")
        }
        this.lastConversationFingerprint := fp
        this.lastConversationGroup := this.currentGroup
    }

    FindUnreadSidebarGroups(knownGroups) {
        this.ActivateHarvest()
        try {
            result := this.bridge.RunCommand("unread", Map(), 8000, "harvest")
            if result.Has("groups") && result["groups"].Length
                return result["groups"]
        } catch {
        }
        return []
    }

    FindMessageInConversation(query) {
        if Trim(query) = ""
            throw Error("Anchor tìm tin rỗng.")
        this.ActivateHarvest()
        this._FocusMessagePaneHarvest()
        return true
    }

    FindImageBubblesNearMessage(anchor, limit := 1, allowHeuristic := true) {
        this.ActivateHarvest()
        try {
            result := this.bridge.RunCommand("find_images", Map(
                "anchor", anchor,
                "limit", limit
            ), 30000, "harvest")
            urls := result.Has("urls") ? result["urls"] : []
            locations := []
            for index, url in urls
                locations.Push(Map("x", 0, "y", 0, "index", index, "url", url))
            return locations
        } catch {
            if !allowHeuristic
                throw
            return []
        }
    }

    CopyImageAt(location) {
        if !IsObject(location) || !location.Has("url")
            return false
        this.ActivateHarvest()
        this.bridge.RunCommand("copy_image", Map("url", location["url"]), 15000, "harvest")
        return this._ClipboardHasImage()
    }

    CopyImageFromSelection() {
        return this._ClipboardHasImage()
    }

    SelectImageBubblesAbove(imageCount) {
        return imageCount > 0
    }

    _ClipboardHasImage() {
        return DllCall("IsClipboardFormatAvailable", "UInt", 2)
            || DllCall("IsClipboardFormatAvailable", "UInt", 8)
    }

    SaveClipboardArchive(path) {
        if !this._ClipboardHasImage()
            throw Error("Clipboard không có ảnh để archive.")
        dir := RegExReplace(path, "\\[^\\]+$")
        if dir != path
            EnsureDir(dir)
        data := ClipboardAll()
        archiveHandle := FileOpen(path, "w")
        if !archiveHandle
            throw Error("Không mở được file archive: " path)
        archiveHandle.RawWrite(data)
        archiveHandle.Close()
        if !FileExist(path) || FileGetSize(path) <= 0
            throw Error("Archive ảnh rỗng: " path)
        return path
    }

    RestoreClipboardArchive(path) {
        if !FileExist(path)
            throw Error("Không tìm thấy archive ảnh: " path)
        rawClip := FileRead(path, "RAW")
        A_Clipboard := ClipboardAll(rawClip)
        if !ClipWait(this.config.ClipWaitSeconds, true)
            throw Error("Không restore được archive ảnh: " path)
        if !this._ClipboardHasImage()
            throw Error("Archive không chứa định dạng ảnh: " path)
        return true
    }

    BeginPublishSession(groupName) {
        this.ActivatePublish()
        result := this.bridge.RunCommand("title", Map(), 5000, "publish")
        activeGroup := result.Has("group") ? Trim(result["group"]) : ""
        if activeGroup = ""
            throw Error("Không đọc được tên nhóm đang mở ở cửa sổ Publish.")
        expected := StrLower(Trim(groupName))
        actual := StrLower(activeGroup)
        if !InStr(actual, expected) && !InStr(expected, actual)
            throw Error("Publish đang mở sai nhóm: '" activeGroup
                . "'. Hãy mở nhóm '" groupName "' rồi thử lại.")
        this.publishGroup := groupName
        this._FocusComposeBoxPublish()
        return true
    }

    EndPublishSession() {
        this.publishGroup := ""
    }

    _PasteAndSend(message, sendAfter := true, beforeSend := 0) {
        this._FocusComposeBoxPublish()
        oldClip := ClipboardAll()
        A_Clipboard := message
        Sleep this.config.PasteDelayMs
        Send "^a{Backspace}"
        Sleep 80
        Send "^v"
        Sleep this.config.PasteDelayMs + 150
        if beforeSend
            beforeSend.Call()
        if sendAfter {
            Send "{Enter}"
            Sleep this.config.SendDelayMs
        }
        A_Clipboard := oldClip
        return true
    }

    PasteClipboardInSession(beforeSend := 0) {
        if this.publishGroup = ""
            throw Error("Chưa mở publish session.")
        if !this._ClipboardHasImage()
            throw Error("Clipboard không có ảnh.")
        this._FocusComposeBoxPublish()
        Send "^a{Backspace}"
        Sleep 100
        Send "^v"
        Sleep this.config.PasteDelayMs + 300
        if beforeSend
            beforeSend.Call()
        Send "{Enter}"
        Sleep this.config.SendDelayMs
        return true
    }

    SendTextInSession(message, beforeSend := 0) {
        if this.publishGroup = ""
            throw Error("Chưa mở publish session.")
        this._PasteAndSend(message, true, beforeSend)
        Sleep this.config.BetweenMessagesMs
        return true
    }

    SendTextChunks(groupName, chunks) {
        if !chunks.Length
            return 0
        this.BeginPublishSession(groupName)
        sent := 0
        for chunk in chunks {
            this._PasteAndSend(chunk)
            sent++
            Sleep this.config.BetweenMessagesMs
        }
        return sent
    }

    SendToGroup(groupName, message) {
        this.BeginPublishSession(groupName)
        this._PasteAndSend(message)
        return true
    }

    PasteToActiveChat(message) {
        this.ActivatePublish()
        this._FocusComposeBoxPublish()
        Sleep this.config.PasteDelayMs
        this._PasteAndSend(message, false)
        return true
    }

    RelayClipboardImage(groupName) {
        if !this._ClipboardHasImage()
            throw Error("Clipboard không có ảnh.")
        this.BeginPublishSession(groupName)
        this._FocusComposeBoxPublish()
        Send "^v"
        Sleep this.config.PasteDelayMs + 300
        Send "{Enter}"
        Sleep this.config.SendDelayMs
        return true
    }
}
