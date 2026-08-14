#Requires AutoHotkey v2.0
; ZaloUI.ahk — Zalo Web adapter: one Chrome tab, harvest then switch to sale in-place

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

    _WindowTitle() {
        title := this.config.WebWindowTitle
        return title != "" ? title : "[ZaloBot]"
    }

    _WindowMatch() {
        return this._WindowTitle()
            . " ahk_exe " this.config.BrowserExeName
            . " ahk_class Chrome_WidgetWin_1"
    }

    _WindowExists(match := "") {
        if match = ""
            match := this._WindowMatch()
        return WinExist(match)
    }

    IsRunning() {
        return this._WindowExists()
            || WinExist("ahk_exe " this.config.BrowserExeName)
    }

    Activate() {
        match := this._WindowMatch()
        if !this._WindowExists(match) {
            fallback := "ahk_exe " this.config.BrowserExeName
                . " ahk_class Chrome_WidgetWin_1"
            if !WinExist(fallback)
                throw Error("Chưa mở tab Zalo Web. Bookmark: " this.config.WebChatUrl)
            match := fallback
        }
        WinActivate match
        if !WinWaitActive("ahk_exe " this.config.BrowserExeName,, 4)
            throw Error("Không kích hoạt được cửa sổ Zalo Web.")
        Sleep 150
        return true
    }

    ActivateHarvest() {
        return this.Activate()
    }

    ActivatePublish() {
        return this.Activate()
    }

    EnsureNormalized() {
        hwnd := WinExist(this._WindowMatch())
        if !hwnd
            hwnd := WinExist("ahk_exe " this.config.BrowserExeName
                . " ahk_class Chrome_WidgetWin_1")
        if !hwnd
            return false
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
        return true
    }

    EnsureWindowState() {
        if this.config.StartupMaximizeBrowser {
            match := this._WindowMatch()
            if WinExist(match)
                WinMaximize match
            Sleep 300
            return true
        }
        return this.EnsureNormalized()
    }

    _NormalizeGroupName(name) {
        value := StrLower(Trim(String(name)))
        value := StrReplace(value, Chr(160), " ")
        value := StrReplace(value, Chr(0x201C), '"')
        value := StrReplace(value, Chr(0x201D), '"')
        return Trim(RegExReplace(value, "\s+", " "))
    }

    _GroupNamesMatch(actual, expected) {
        a := this._NormalizeGroupName(actual)
        e := this._NormalizeGroupName(expected)
        return a != "" && e != "" && a = e
    }

    _EnsureBridgeReady(timeoutSeconds := 8) {
        deadline := A_TickCount + (timeoutSeconds * 1000)
        while A_TickCount < deadline {
            this.Activate()
            Sleep 300
            if this.bridge.WaitForRoles(3)
                return true
            Sleep 400
        }
        throw Error("Tampermonkey chưa kết nối tab Zalo Web.")
    }

    _ReadConversationTitle(fallback := "") {
        try {
            this._EnsureBridgeReady(6)
            result := this.bridge.RunCommand("title", Map(), 8000, "bot")
            if result.Has("group") && Trim(result["group"]) != ""
                return result["group"]
        } catch {
        }
        return fallback
    }

    _VerifyGroupOpened(groupName) {
        title := ""
        try {
            this._EnsureBridgeReady(8)
            result := this.bridge.RunCommand("title", Map(), 8000, "bot")
            title := result.Has("group") ? result["group"] : ""
        } catch {
        }
        if this._GroupNamesMatch(title, groupName)
            return true
        try {
            scan := this.bridge.RunCommand("scan", Map(), 20000, "bot")
            scanGroup := scan.Has("group") ? scan["group"] : ""
            textLen := scan.Has("text") ? StrLen(Trim(scan["text"])) : 0
            msgCount := scan.Has("messages") ? scan["messages"].Length : 0
            ; #region agent log
            AgentDebugLog("ZaloUI.ahk:_VerifyGroupOpened", "verify_scan", Map(
                "group", groupName, "scanGroup", scanGroup,
                "textLen", textLen, "msgCount", msgCount, "title", title
            ), "H6", "post-fix")
            ; #endregion
            if this._GroupNamesMatch(scanGroup, groupName)
                return true
            return false
        } catch as err {
            ; #region agent log
            AgentDebugLog("ZaloUI.ahk:_VerifyGroupOpened", "verify_fail", Map(
                "group", groupName, "error", err.Message, "title", title
            ), "H6", "post-fix")
            ; #endregion
            return false
        }
    }

    _NavigateToGroup(groupName) {
        this.Activate()
        this._EnsureBridgeReady(12)
        Send "{Esc}"
        Sleep 150
        try {
            result := this.bridge.RunCommand("navigate", Map("group", groupName), 45000, "bot")
        } catch as err {
            throw Error("Không mở được nhóm: " groupName " (" err.Message ")")
        }
        opened := result.Has("group") ? result["group"] : groupName
        if this._GroupNamesMatch(opened, groupName)
            return opened
        if this._VerifyGroupOpened(groupName)
            return this._ReadConversationTitle(opened)
        throw Error("Không mở được nhóm: " groupName)
    }

    _FocusComposeBox() {
        this.Activate()
        try this.bridge.RunCommand("focus_compose", Map(), 5000, "bot")
        catch {
            WinGetClientPos(&x, &y, &w, &h, this._WindowMatch())
            Click x + Round(w * 0.42), y + Round(h * 0.88)
            Sleep this.config.PasteDelayMs
        }
    }

    _FocusMessagePane() {
        this.Activate()
        hwnd := WinExist(this._WindowMatch())
        if !hwnd
            hwnd := WinExist("ahk_exe " this.config.BrowserExeName)
        WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
        Click x + Round(w * 0.55), y + Round(h * 0.45)
        Sleep this.config.CaptureSettleMs
    }

    OpenGroup(groupName, focus := "read") {
        this.Activate()
        this.EnsureNormalized()
        openedGroup := this._NavigateToGroup(groupName)
        if Trim(openedGroup) = ""
            throw Error("Không mở được nhóm: " groupName)
        this.currentGroup := openedGroup
        this.lastOpenedGroup := openedGroup
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:OpenGroup", "open_group_ok", Map(
            "requested", groupName, "openedAs", openedGroup), "H2", "post-fix")
        ; #endregion
        if focus = "send"
            this._FocusComposeBox()
        else
            this._FocusMessagePane()
        return true
    }

    CaptureConversation(method := "") {
        this.Activate()
        this._EnsureBridgeReady(10)
        result := this.bridge.RunCommand("scan", Map(), 20000, "bot")
        captured := result.Has("text") ? result["text"] : ""
        this._GuardStickyConversation(captured)
        if !result.Has("messages") || !(result["messages"] is Array)
            result["messages"] := []
        if !result.Has("group")
            result["group"] := this.currentGroup
        return result
    }

    CaptureConversationText(method := "") {
        result := this.CaptureConversation(method)
        return result.Has("text") ? result["text"] : ""
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
        this.Activate()
        try {
            result := this.bridge.RunCommand("unread", Map(), 8000, "bot")
            if result.Has("groups") && result["groups"].Length
                return result["groups"]
        } catch {
        }
        return []
    }

    FindMessageInConversation(query) {
        if Trim(query) = ""
            throw Error("Anchor tìm tin rỗng.")
        this.Activate()
        this._FocusMessagePane()
        return true
    }

    FindImageBubblesNearMessage(anchor, limit := 1, allowHeuristic := true) {
        this.Activate()
        try {
            result := this.bridge.RunCommand("find_images", Map(
                "anchor", anchor,
                "limit", limit
            ), 30000, "bot")
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
        this.Activate()
        this.bridge.RunCommand("copy_image", Map("url", location["url"]), 15000, "bot")
        return this._ClipboardHasImage()
    }

    FetchImageAt(location) {
        if !IsObject(location) || !location.Has("url")
            throw Error("Vị trí ảnh không có URL.")
        this.Activate()
        result := this.bridge.RunCommand(
            "fetch_image", Map("url", location["url"]), 45000, "bot")
        if !result.Has("data_base64") || result["data_base64"] = ""
            throw Error("Tampermonkey không trả dữ liệu ảnh.")
        return result
    }

    SaveFetchedImage(image, path) {
        if !(image is Map) || !image.Has("data_base64")
            throw Error("Payload ảnh không hợp lệ.")
        return WriteBase64File(image["data_base64"], path)
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

    _ClipboardHasPublishMedia() {
        return this._ClipboardHasImage()
            || DllCall("IsClipboardFormatAvailable", "UInt", 15)
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
        if !RegExMatch(path, "i)\.clip$") {
            if !SetClipboardFile(path)
                throw Error("Không đưa được file ảnh vào clipboard: " path)
            if !ClipWait(this.config.ClipWaitSeconds, true)
                throw Error("Clipboard không nhận file ảnh: " path)
            return true
        }
        rawClip := FileRead(path, "RAW")
        A_Clipboard := ClipboardAll(rawClip)
        if !ClipWait(this.config.ClipWaitSeconds, true)
            throw Error("Không restore được archive ảnh: " path)
        if !this._ClipboardHasImage()
            throw Error("Archive không chứa định dạng ảnh: " path)
        return true
    }

    BeginPublishSession(groupName) {
        this.Activate()
        try this.bridge.RunCommand("pause_events", Map(), 3000, "bot")
        catch {
        }
        activeGroup := Trim(this._NavigateToGroup(groupName))
        if activeGroup = ""
            throw Error("Không mở được nhóm output trên tab Zalo Web.")
        if !this._GroupNamesMatch(activeGroup, groupName)
            throw Error("Không chuyển sang nhóm output: '" activeGroup
                . "'. Kỳ vọng '" groupName "'.")
        this.publishGroup := groupName
        this.currentGroup := activeGroup
        this._FocusComposeBox()
        return true
    }

    EndPublishSession() {
        this.publishGroup := ""
        try this.bridge.RunCommand("resume_events", Map(), 3000, "bot")
        catch {
        }
    }

    _PasteAndSend(message, sendAfter := true, beforeSend := 0) {
        this._FocusComposeBox()
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
        if !this._ClipboardHasPublishMedia()
            throw Error("Clipboard không có ảnh hoặc file ảnh.")
        this._FocusComposeBox()
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
        this.EndPublishSession()
        return sent
    }

    SendToGroup(groupName, message) {
        this.BeginPublishSession(groupName)
        this._PasteAndSend(message)
        this.EndPublishSession()
        return true
    }

    PasteToActiveChat(message) {
        this.Activate()
        this._FocusComposeBox()
        Sleep this.config.PasteDelayMs
        this._PasteAndSend(message, false)
        return true
    }

    RelayClipboardImage(groupName) {
        if !this._ClipboardHasImage()
            throw Error("Clipboard không có ảnh.")
        this.BeginPublishSession(groupName)
        this._FocusComposeBox()
        Send "^v"
        Sleep this.config.PasteDelayMs + 300
        Send "{Enter}"
        Sleep this.config.SendDelayMs
        this.EndPublishSession()
        return true
    }
}
