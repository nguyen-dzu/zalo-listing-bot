#Requires AutoHotkey v2.0
; ZaloUI.ahk — Adapter: every Zalo PC keystroke lives here. Calibrate delays in config.ini.

class ZaloUIAdapter {
    __New(config) {
        this.config := config
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
        this._PasteAndSend(message)
        return true
    }

    ; Relay whatever image is on the clipboard into the target group.
    RelayClipboardImage(groupName) {
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

    _PasteAndSend(message) {
        old := ClipboardAll()
        A_Clipboard := message
        if !ClipWait(this.config.ClipWaitSeconds) {
            A_Clipboard := old
            throw Error("Không đặt được nội dung vào clipboard.")
        }
        this._FocusComposeBox()
        Send "^v"
        Sleep this.config.PasteDelayMs + 150
        Send "{Enter}"
        Sleep this.config.SendDelayMs
        A_Clipboard := old
    }
}
