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
        this.botWindowHwnd := 0
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
        hwnd := this._WindowExists(match)
        if hwnd {
            this.botWindowHwnd := hwnd
            match := "ahk_id " hwnd
        } else if this.botWindowHwnd && WinExist("ahk_id " this.botWindowHwnd) {
            match := "ahk_id " this.botWindowHwnd
        } else {
            fallback := "ahk_exe " this.config.BrowserExeName
                . " ahk_class Chrome_WidgetWin_1"
            hwnd := WinExist(fallback)
            if !hwnd
                throw Error("Chưa mở tab Zalo Web. Bookmark: " this.config.WebChatUrl)
            this.botWindowHwnd := hwnd
            match := "ahk_id " hwnd
        }
        WinActivate match
        if !WinWaitActive("ahk_exe " this.config.BrowserExeName,, 4)
            throw Error("Không kích hoạt được cửa sổ Zalo Web.")
        Sleep 150
        return true
    }

    ; A Zalo click can occasionally leave an external link in a new active
    ; Chrome tab. Close only that tab in the browser window already owned by
    ; the bot, then reveal the registered [ZaloBot] tab and continue scanning.
    _CloseUnexpectedActiveTab() {
        if !this.botWindowHwnd || !WinExist("ahk_id " this.botWindowHwnd)
            return false
        WinActivate "ahk_id " this.botWindowHwnd
        if !WinWaitActive("ahk_id " this.botWindowHwnd,, 2)
            return false
        title := WinGetTitle("ahk_id " this.botWindowHwnd)
        if InStr(title, this._WindowTitle())
            return false
        processName := ""
        try processName := WinGetProcessName("ahk_id " this.botWindowHwnd)
        if StrLower(processName) != StrLower(this.config.BrowserExeName)
            return false
        Send "^w"
        Sleep 500
        return InStr(WinGetTitle("ahk_id " this.botWindowHwnd), this._WindowTitle()) > 0
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
        Loop 3 {
            title := this._ReadConversationTitle("")
            if this._GroupNamesMatch(title, groupName)
                return true
            Sleep 200
        }
        return false
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
        ; Prefer DOM focus on the chat header. A client-area click at ~45%
        ; lands on listing photos and opens the image viewer, aborting harvest.
        try {
            this.bridge.RunCommand("focus_pane", Map(), 5000, "bot")
            ; #region agent log
            AgentDbg("H4", "ZaloUI.ahk:_FocusMessagePane", "bridge_ok", "{}")
            ; #endregion
            Sleep this.config.CaptureSettleMs
            return
        } catch as err {
            ; #region agent log
            AgentDbg("H4", "ZaloUI.ahk:_FocusMessagePane", "bridge_fail_click_header",
                '{"error":"' StrReplace(StrReplace(err.Message, "`n", " "), '"', '\"') '"}')
            ; #endregion
        }
        hwnd := WinExist(this._WindowMatch())
        if !hwnd
            hwnd := WinExist("ahk_exe " this.config.BrowserExeName)
        WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
        Click x + Round(w * 0.52), y + Round(h * 0.10)
        Sleep 80
        Send "{Esc}"
        Sleep this.config.CaptureSettleMs
    }

    OpenGroup(groupName, focus := "read") {
        this.Activate()
        this.EnsureNormalized()
        openedGroup := this._NavigateToGroup(groupName)
        this._CloseUnexpectedActiveTab()
        if Trim(openedGroup) = ""
            throw Error("Không mở được nhóm: " groupName)
        this.currentGroup := openedGroup
        this.lastOpenedGroup := openedGroup
        if focus = "send"
            this._FocusComposeBox()
        else
            this._FocusMessagePane()
        return true
    }

    CaptureConversation(method := "", maxMessages := 0) {
        result := Map("text", "", "messages", [], "group", this.currentGroup)
        limit := maxMessages > 0 ? maxMessages
            : (this.config.HasProp("MaxScanMessages")
                ? this.config.MaxScanMessages : 20)
        params := Map("max_messages", Max(1, limit))
        Loop 3 {
            this.Activate()
            this._EnsureBridgeReady(10)
            this._CloseUnexpectedActiveTab()
            result := this.bridge.RunCommand("scan", params, 45000, "bot")
            if !result.Has("messages") || !(result["messages"] is Array)
                result["messages"] := []
            if !result.Has("group")
                result["group"] := this.currentGroup
            captured := result.Has("text") ? result["text"] : ""
            if Trim(captured) != "" || result["messages"].Length {
                this._GuardStickyConversation(captured)
                return result
            }
            this._CloseUnexpectedActiveTab()
            this._FocusMessagePane()
            Sleep 500 * A_Index
        }
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
        knownNames := []
        for group in knownGroups
            knownNames.Push(group["group_name"])
        try {
            result := this.bridge.RunCommand(
                "unread", Map("known_groups", knownNames), 8000, "bot")
            if result.Has("items") && result["items"].Length
                return result["items"]
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

    FindImageBubblesNearMessage(anchor, limit := 1, allowHeuristic := true, messageHash := "") {
        this.Activate()
        try {
            params := Map(
                "anchor", anchor,
                "limit", limit
            )
            if Trim(messageHash) != ""
                params["message_hash"] := messageHash
            result := this.bridge.RunCommand("find_images", params, 30000, "bot")
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
    }

    ; Bitmap via Tampermonkey bridge — never CF_HDROP (Zalo uploads that to cloud drive).
    SetClipboardImageFromFile(path) {
        if !FileExist(path)
            return false
        mime := "image/png"
        if RegExMatch(path, "i)\.jpe?g$")
            mime := "image/jpeg"
        else if RegExMatch(path, "i)\.webp$")
            mime := "image/webp"
        encoded := FileToBase64(path)
        if encoded = ""
            return false
        try {
            this.bridge.RunCommand("set_clipboard_image",
                Map("data_base64", encoded, "mime", mime), 45000, "bot")
        } catch {
            return false
        }
        Sleep 150
        return this._ClipboardHasImage()
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
        if RegExMatch(path, "i)\.clip$") {
            rawClip := FileRead(path, "RAW")
            A_Clipboard := ClipboardAll(rawClip)
            if !ClipWait(this.config.ClipWaitSeconds, true)
                throw Error("Không restore được archive ảnh: " path)
            if !this._ClipboardHasImage()
                throw Error("Archive không chứa định dạng ảnh: " path)
            return true
        }
        if !this.SetClipboardImageFromFile(path)
            throw Error("Không đưa được ảnh vào clipboard dạng bitmap: " path)
        if !ClipWait(this.config.ClipWaitSeconds, true)
            throw Error("Clipboard không nhận ảnh bitmap: " path)
        if !this._ClipboardHasImage()
            throw Error("Clipboard không có định dạng ảnh inline: " path)
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

    ; Paste one archived image as its own message.
    PasteOneMediaInSession(path, beforeSend := 0) {
        if this.publishGroup = ""
            throw Error("Chưa mở publish session.")
        if !FileExist(path)
            throw Error("Không tìm thấy archive ảnh: " path)
        this._FocusComposeBox()
        Send "^a{Backspace}"
        Sleep 100
        this.RestoreClipboardArchive(path)
        Send "^v"
        Sleep this.config.PasteDelayMs + 200
        if beforeSend
            beforeSend.Call()
        Send "{Enter}"
        Sleep this.config.SendDelayMs
        return true
    }

    ; Paste every archived image into compose, then send once.
    PasteMediaBatchInSession(paths, beforeSend := 0) {
        if this.publishGroup = ""
            throw Error("Chưa mở publish session.")
        if !paths.Length
            return true
        this._FocusComposeBox()
        Send "^a{Backspace}"
        Sleep 100
        for path in paths {
            this.RestoreClipboardArchive(path)
            Send "^v"
            Sleep this.config.PasteDelayMs + 200
        }
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

    ForwardListingMessage(sourceGroup, targetGroup, messageHash, roomCode := "") {
        if this.publishGroup = ""
            throw Error("Chưa mở publish session.")
        params := Map(
            "source_group", sourceGroup,
            "target_group", targetGroup,
            "message_hash", messageHash
        )
        if Trim(roomCode) != ""
            params["room_code"] := roomCode
        result := this.bridge.RunCommand("forward_message", params, 90000, "bot")
        opened := result.Has("group") ? result["group"] : targetGroup
        if !this._GroupNamesMatch(opened, targetGroup)
            throw Error("Forward xong nhưng chưa ở nhóm output: '" opened "'")
        this.publishGroup := targetGroup
        this.currentGroup := opened
        this._FocusComposeBox()
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
