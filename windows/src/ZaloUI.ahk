#Requires AutoHotkey v2.0
; ZaloUI.ahk — Adapter: every Zalo PC keystroke lives here. Calibrate delays in config.ini.

class ZaloUIAdapter {
    __New(config) {
        this.config := config
        this.publishGroup := ""
    }

    IsRunning() {
        return WinExist("ahk_exe " this.config.ExeName)
    }

    Activate() {
        if !this.IsRunning()
            throw Error("Zalo PC chưa mở. Hãy mở Zalo trước.")
        WinActivate "ahk_exe " this.config.ExeName
        if !WinWaitActive("ahk_exe " this.config.ExeName,, 3)
            throw Error("Không kích hoạt được cửa sổ Zalo.")
        Sleep 300
    }

    ; focus: "read" = message pane for copy; "send" = compose box for paste
    OpenGroup(groupName, focus := "read") {
        this.Activate()
        Send "{Esc}"
        Sleep 150
        Send "^f"
        Sleep this.config.SearchDelayMs
        SendText groupName
        Sleep this.config.SearchDelayMs + 300
        Send "{Enter}"
        Sleep this.config.OpenChatDelayMs
        Send "{Esc}"
        Sleep 150
        if focus = "send"
            this._FocusComposeBox()
        else
            this._ClickMessagePane()
        return true
    }

    ; Copy the conversation text of the currently open chat.
    ; manual    — the operator already highlighted the messages
    ; selectall — click the message pane, then Ctrl+A / Ctrl+C
    CaptureConversationText(method := "") {
        mode := method != "" ? method : this.config.CaptureMethod
        this.Activate()

        if mode = "selectall" {
            this._ClickMessagePane()
            Send "^a"
            Sleep this.config.PasteDelayMs
        }

        old := ClipboardAll()
        A_Clipboard := ""
        Send "^c"
        captured := ClipWait(this.config.ClipWaitSeconds) ? A_Clipboard : ""
        A_Clipboard := old
        return captured
    }

    ; Open Zalo's group + community lists (Alt+3), scroll the left pane, copy text.
    CaptureAllGroupListText() {
        combined := ""
        combined := this._MergeCapturedText(
            combined, this._CaptureListSection(false))
        if this.config.CaptureCommunities {
            combined := this._MergeCapturedText(
                combined, this._CaptureListSection(true))
        }
        return combined
    }

    _MergeCapturedText(existing, addition) {
        addition := Trim(NormalizeNewlines(addition))
        if addition = ""
            return existing
        if existing = ""
            return addition
        return existing "`n" addition
    }

    _CaptureListSection(communitiesTab := false) {
        this.Activate()
        Send "{Esc}"
        Sleep 150
        Send this.config.GroupListTabHotkey
        Sleep this.config.GroupListSettleMs

        WinGetPos &winX, &winY, &winW, &winH, "ahk_exe " this.config.ExeName
        if communitiesTab {
            tabX := winX + Round(winW * this.config.GroupCommunityTabClickXRatio)
            tabY := winY + Round(winH * this.config.GroupCommunityTabClickYRatio)
            Click(tabX, tabY)
            Sleep this.config.GroupListSettleMs
        }

        paneX := winX + Round(winW * this.config.GroupListPaneClickXRatio)
        paneY := winY + Round(winH * this.config.GroupListPaneClickYRatio)
        Click(paneX, paneY)
        Sleep this.config.PasteDelayMs
        Send "{Home}"
        Sleep this.config.GroupListSettleMs

        old := ClipboardAll()
        combined := ""
        previous := ""
        repeated := 0
        try {
            Loop this.config.GroupListScanPages {
                A_Clipboard := ""
                Send "^a"
                Sleep this.config.PasteDelayMs
                Send "^c"
                page := ClipWait(this.config.ClipWaitSeconds)
                    ? String(A_Clipboard) : ""
                page := Trim(NormalizeNewlines(page))
                if page != ""
                    combined := this._MergeCapturedText(combined, page)

                if page != "" && page = previous
                    repeated++
                else
                    repeated := 0
                if repeated >= 1
                    break
                previous := page

                Click(paneX, paneY)
                this._AdvanceGroupListScroll()
            }
        } finally {
            A_Clipboard := old
        }
        return combined
    }

    _AdvanceGroupListScroll() {
        if this.config.GroupListScrollMode = "wheel" {
            Loop this.config.GroupListWheelSteps
                Send "{WheelDown}"
        } else {
            Send "{PgDn}"
        }
        Sleep this.config.GroupListSettleMs
    }

    _ClickMessagePane() {
        WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
        ; Message pane sits right of the conversation list; click a neutral spot.
        Click(x + Round(w * 0.65), y + Round(h * 0.45))
        Sleep this.config.PasteDelayMs
    }

    ; Zalo PC: after search/open chat, focus must be in the compose box before Ctrl+V.
    _FocusComposeBox() {
        this.Activate()
        WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
        Click(x + Round(w * 0.65), y + h - 90)
        Sleep this.config.PasteDelayMs + 100
    }

    SendTextChunks(groupName, chunks) {
        if !chunks.Length
            return 0
        this.OpenGroup(groupName, "send")
        sent := 0
        for chunk in chunks {
            this._PasteAndSend(chunk)
            sent++
            Sleep this.config.BetweenMessagesMs
        }
        return sent
    }

    SendToGroup(groupName, message) {
        this.OpenGroup(groupName, "send")
        this._PasteAndSend(message)
        return true
    }

    PasteToActiveChat(message) {
        this.Activate()
        this._FocusComposeBox()
        Sleep this.config.PasteDelayMs
        this._PasteAndSend(message, false)
        return true
    }

    ; Search within the open conversation for a text anchor (room code, address, …).
    FindMessageInConversation(query) {
        if Trim(query) = ""
            throw Error("Anchor tìm tin rỗng.")
        this.Activate()
        this._ClickMessagePane()
        Send "{Esc}"
        Sleep 150
        Send this.config.FindInChatHotkey
        Sleep this.config.SearchDelayMs + 100
        SendText query
        Sleep this.config.SearchDelayMs + 200
        Send "{Enter}"
        Sleep this.config.CaptureSettleMs
        Send "{Esc}"
        Sleep 150
        this._ClickMessagePane()
        return true
    }

    ; Extend selection upward to include image_count bubbles above the anchor text.
    SelectImageBubblesAbove(imageCount) {
        if imageCount <= 0
            return true
        this.Activate()
        this._ClickMessagePane()
        mode := StrLower(this.config.ImageSelectMode)
        if mode = "shift_click" {
            WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
            clickX := x + Round(w * 0.65)
            baseY := y + Round(h * 0.45)
            step := this.config.ImageSelectStepPx
            Send "{Shift down}"
            Loop imageCount {
                clickY := Max(y + 80, baseY - (A_Index * step))
                if A_Index = 1
                    Click(clickX, clickY)
                else
                    Click(clickX, clickY, , , "D")
                Sleep this.config.PasteDelayMs
            }
            Send "{Shift up}"
        } else {
            Loop imageCount {
                Send "+{Up}"
                Sleep this.config.PasteDelayMs
            }
        }
        Sleep this.config.PasteDelayMs
        return true
    }

    CopySelectedImages() {
        if !this.CopyImageFromSelection()
            throw Error("Không copy được ảnh đã chọn.")
        return true
    }

    ; Copy image from the bubble the operator selected (Ctrl+C, then context-menu fallback).
    CopyImageFromSelection() {
        this.Activate()
        old := ClipboardAll()
        A_Clipboard := ""

        Send this.config.ImageCopyHotkey
        Sleep this.config.PasteDelayMs + 100
        if ClipWait(this.config.ClipWaitSeconds) && this._ClipboardHasImage()
            return true

        A_Clipboard := ""
        Send "{AppsKey}"
        Sleep 250
        Send "c"
        Sleep 200
        if ClipWait(this.config.ClipWaitSeconds) && this._ClipboardHasImage()
            return true

        A_Clipboard := old
        return false
    }

    _ClipboardHasImage() {
        if DllCall("IsClipboardFormatAvailable", "UInt", 2)   ; CF_BITMAP
            return true
        if DllCall("IsClipboardFormatAvailable", "UInt", 8)   ; CF_DIB
            return true
        if DllCall("IsClipboardFormatAvailable", "UInt", 17)  ; CF_DIBV5
            return true
        if DllCall("IsClipboardFormatAvailable", "UInt", 15)  ; CF_HDROP
            return true
        pngFormat := DllCall("RegisterClipboardFormat", "Str", "PNG", "UInt")
        if pngFormat && DllCall("IsClipboardFormatAvailable", "UInt", pngFormat)
            return true
        return false
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
        if this.publishGroup != groupName {
            this.OpenGroup(groupName, "send")
            this.publishGroup := groupName
        } else {
            this.Activate()
            this._FocusComposeBox()
        }
        return true
    }

    EndPublishSession() {
        this.publishGroup := ""
    }

    PasteClipboardInSession(beforeSend := 0) {
        if this.publishGroup = ""
            throw Error("Chưa mở publish session.")
        if !this._ClipboardHasImage()
            throw Error("Clipboard không có ảnh.")
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

    PasteArchiveInSession(path, beforeSend := 0) {
        this.RestoreClipboardArchive(path)
        return this.PasteClipboardInSession(beforeSend)
    }

    SendTextInSession(message, beforeSend := 0) {
        if this.publishGroup = ""
            throw Error("Chưa mở publish session.")
        this._PasteAndSend(message, true, beforeSend)
        Sleep this.config.BetweenMessagesMs
        return true
    }

    ; Relay whatever image is on the clipboard into the target group.
    RelayClipboardImage(groupName) {
        if !this._ClipboardHasImage()
            throw Error("Clipboard không có ảnh. Hãy chọn bubble ảnh trước.")
        this.OpenGroup(groupName, "send")
        this._FocusComposeBox()
        Send "^v"
        Sleep this.config.PasteDelayMs + 300
        Send "{Enter}"
        Sleep this.config.SendDelayMs
        return true
    }

    ; Forward the messages currently selected in Zalo to a target group.
    ; Uses Zalo's forward dialog: Ctrl+Q -> type group -> Enter -> confirm.
    ForwardSelection(groupName) {
        this.Activate()
        Send this.config.ForwardHotkey
        Sleep this.config.ForwardDialogMs
        SendText groupName
        Sleep this.config.SearchDelayMs + 200
        Send "{Enter}"
        Sleep this.config.PasteDelayMs
        Send "{Enter}"
        Sleep this.config.SendDelayMs
        return true
    }

    _PasteAndSend(message, refocus := true, beforeSend := 0) {
        old := ClipboardAll()
        A_Clipboard := message
        if !ClipWait(this.config.ClipWaitSeconds) {
            A_Clipboard := old
            throw Error("Không đặt được nội dung vào clipboard.")
        }
        try {
            if refocus
                this._FocusComposeBox()
            Send "^a{Backspace}"
            Sleep 100
            Send "^v"
            Sleep this.config.PasteDelayMs + 150
            if beforeSend
                beforeSend.Call()
            Send "{Enter}"
            Sleep this.config.SendDelayMs
        } finally {
            A_Clipboard := old
        }
    }
}
