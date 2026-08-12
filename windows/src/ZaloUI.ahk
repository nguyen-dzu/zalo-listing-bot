#Requires AutoHotkey v2.0
#Include Acc.ahk
#Include GroupRegistry.ahk
#Include GroupActivity.ahk
; ZaloUI.ahk — Adapter: every Zalo PC keystroke lives here. Calibrate delays in config.ini.

class ZaloUIAdapter {
    __New(config) {
        this.config := config
        this.publishGroup := ""
        this.currentGroup := ""
        this.lastConversationFingerprint := ""
        this.lastConversationGroup := ""
        this.lastOpenedFingerprint := ""
        this.lastOpenedGroup := ""
        this.groupFingerprints := Map()
        this.mainHwnd := 0
        EnablePerMonitorDpiAwareness()
        CoordMode("Mouse", "Screen")
    }

    ; options: "" | WhichButton ("Left","Right",...) | "D"/"U" (mouse down/up for drag)
    _ScreenClick(x, y, options := "") {
        CoordMode("Mouse", "Screen")
        x := Round(x), y := Round(y)
        ; SetCursorPos consumes physical virtual-screen pixels. This avoids the
        ; second DPI conversion that MouseMove/Click(x,y) can apply on a scaled
        ; maximized Zalo window.
        virtualX := DllCall("GetSystemMetrics", "Int", 76, "Int")
        virtualY := DllCall("GetSystemMetrics", "Int", 77, "Int")
        virtualW := DllCall("GetSystemMetrics", "Int", 78, "Int")
        virtualH := DllCall("GetSystemMetrics", "Int", 79, "Int")
        x := Min(Max(x, virtualX), virtualX + Max(1, virtualW) - 1)
        y := Min(Max(y, virtualY), virtualY + Max(1, virtualH) - 1)
        if !DllCall("SetCursorPos", "Int", x, "Int", y)
            throw Error("Không di chuyển được chuột tới " x "," y ".")
        Sleep 50
        actual := Buffer(8, 0)
        if DllCall("GetCursorPos", "Ptr", actual) {
            actualX := NumGet(actual, 0, "Int")
            actualY := NumGet(actual, 4, "Int")
            if this.publishGroup != "" {
                ; #region agent log
                AgentDebugLog("ZaloUI.ahk:_ScreenClick", "publish click", Map(
                    "targetX", x, "targetY", y,
                    "actualX", actualX, "actualY", actualY,
                    "delta", Abs(actualX - x) + Abs(actualY - y),
                    "publishGroup", this.publishGroup
                ), "H5", "publish-debug")
                ; #endregion
            }
            if Abs(actualX - x) > 1 || Abs(actualY - y) > 1
                throw Error("Chuột bị DPI remap: yêu cầu " x "," y
                    . " nhưng nhận " actualX "," actualY ".")
        }
        if options != ""
            Click(options)
        else
            Click()
    }

    _ElementClick(element) {
        try {
            element.Click()
            return true
        } catch {
            try {
                loc := element.Location
                if loc.w <= 0 || loc.h <= 0
                    return false
                this._ScreenClick(
                    loc.x + Round(loc.w / 2),
                    loc.y + Round(loc.h / 2))
                return true
            } catch {
                return false
            }
        }
    }

    _IsUsableWindow(hwnd) {
        if !hwnd || !DllCall("IsWindow", "Ptr", hwnd)
            return false
        try {
            if WinGetProcessName("ahk_id " hwnd) != this.config.ExeName
                return false
            WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
            return w >= 600 && h >= 450
        } catch {
            return false
        }
    }

    ; Cache the main Zalo HWND before viewers/dialogs appear. Re-select only
    ; when that window is destroyed; transient Electron windows must never
    ; replace a valid main handle.
    _MainHwnd() {
        if this._IsUsableWindow(this.mainHwnd)
            return this.mainHwnd
        best := 0
        bestArea := 0
        try ids := WinGetList("ahk_exe " this.config.ExeName)
        catch
            ids := []
        for hwnd in ids {
            try {
                if !DllCall("IsWindowVisible", "Ptr", hwnd)
                    continue
                WinGetClientPos(&cx, &cy, &w, &h, "ahk_id " hwnd)
                if w < 200 || h < 200
                    continue
                area := w * h
                if area > bestArea {
                    bestArea := area
                    best := hwnd
                }
            } catch {
                continue
            }
        }
        if best {
            this.mainHwnd := best
            return best
        }
        this.mainHwnd := WinExist("ahk_exe " this.config.ExeName)
        return this.mainHwnd
    }

    ; Client-area in physical screen pixels (GetClientRect + ClientToScreen).
    ; More reliable than WinGetClientPos when Zalo is maximized / multi-DPI.
    _WindowRect() {
        hwnd := this._MainHwnd()
        if !hwnd {
            try {
                WinGetClientPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
                return Map("x", x, "y", y, "w", w, "h", h)
            } catch {
                WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
                return Map("x", x, "y", y, "w", w, "h", h)
            }
        }
        rect := Buffer(16, 0)
        if !DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect) {
            WinGetClientPos &x, &y, &w, &h, hwnd
            return Map("x", x, "y", y, "w", w, "h", h, "hwnd", hwnd)
        }
        pt := Buffer(8, 0)
        NumPut("Int", 0, pt, 0)
        NumPut("Int", 0, pt, 4)
        if !DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt) {
            WinGetClientPos &x, &y, &w, &h, hwnd
            return Map("x", x, "y", y, "w", w, "h", h, "hwnd", hwnd)
        }
        return Map(
            "x", NumGet(pt, 0, "Int"),
            "y", NumGet(pt, 4, "Int"),
            "w", NumGet(rect, 8, "Int"),
            "h", NumGet(rect, 12, "Int"),
            "hwnd", hwnd
        )
    }

    _RatioPoint(win, xRatio, yRatio) {
        return [
            win["x"] + Round(win["w"] * xRatio),
            win["y"] + Round(win["h"] * yRatio)
        ]
    }

    _SidebarWidth(win) {
        fixed := this.config.HasProp("LayoutSidebarWidthPx")
            ? Integer(this.config.LayoutSidebarWidthPx) : 0
        ratio := this.config.HasProp("LayoutSidebarWidthRatio")
            ? this.config.LayoutSidebarWidthRatio : 0.345
        if fixed > 0 && win["w"] >= 1500
            sidebar := fixed
        else if ratio > 0
            sidebar := Round(win["w"] * ratio)
        else if fixed > 0
            sidebar := fixed
        else
            sidebar := Round(win["w"] * 0.345)
        return Min(Max(sidebar, 200), Round(win["w"] * 0.48))
    }

    ; One geometry snapshot for every mouse fallback. Ratios are relative to
    ; the main Zalo client rect, never to a viewer/dialog or the whole screen.
    _LayoutSnapshot(win := 0) {
        if !win
            win := this._WindowRect()
        sidebar := this._SidebarWidth(win)
        minX := win["x"] + sidebar
        maxX := win["x"] + Round(win["w"] * 0.98)
        minY := win["y"] + Round(win["h"] * 0.10)
        maxY := win["y"] + Round(win["h"] * 0.82)
        paneW := Max(1, maxX - minX)
        messageYRatio := this.config.HasProp("LayoutMessageClickYRatio")
            ? this.config.LayoutMessageClickYRatio : 0.24
        messageXRatio := this.config.HasProp("LayoutMessageClickXRatio")
            ? this.config.LayoutMessageClickXRatio : 0.28
        composeYRatio := this.config.HasProp("LayoutComposeClickYRatio")
            ? this.config.LayoutComposeClickYRatio : 0.92
        composeXRatio := this.config.HasProp("LayoutComposeClickXRatio")
            ? this.config.LayoutComposeClickXRatio : 0.42
        resultYRatio := this.config.HasProp("GroupSearchResultClickYRatio")
            ? this.config.GroupSearchResultClickYRatio : 0.135
        searchXRatio := this.config.HasProp("GroupSearchBoxClickXRatio")
            ? this.config.GroupSearchBoxClickXRatio : 0.55
        composeOffsetY := this.config.HasProp("ComposeClickOffsetYPx")
            ? Integer(this.config.ComposeClickOffsetYPx) : 0
        resultOffsetY := this.config.HasProp("SearchResultClickOffsetYPx")
            ? Integer(this.config.SearchResultClickOffsetYPx) : 0
        if searchXRatio < 0.25
            searchXRatio := 0.55
        layout := Map(
            "win", win,
            "sidebarWidth", sidebar,
            "searchX", win["x"] + Round(sidebar * searchXRatio),
            "searchY", win["y"] + Round(win["h"]
                * this.config.GroupSearchBoxClickYRatio),
            "firstResultX", win["x"] + Round(sidebar * searchXRatio),
            "firstResultY", win["y"] + Round(win["h"] * resultYRatio)
                + resultOffsetY,
            "minX", minX, "maxX", maxX, "minY", minY, "maxY", maxY,
            "textFocusX", minX + Round(paneW * messageXRatio),
            "textFocusY", win["y"] + Round(win["h"] * messageYRatio),
            "cx", minX + Round(paneW * 0.55),
            "cy", win["y"] + Round(win["h"] * 0.48),
            "composeX", minX + Round(paneW * composeXRatio),
            "composeY", win["y"] + Round(win["h"] * composeYRatio)
                + composeOffsetY
        )
        ; #region agent log
        static lastLogTick := 0
        if (A_TickCount - lastLogTick) > 1500 {
            lastLogTick := A_TickCount
            zoomed := 0
            try {
                if win.Has("hwnd")
                    zoomed := WinGetMinMax("ahk_id " win["hwnd"])
            }
            AgentDebugLog("ZaloUI.ahk:_MessagePaneBounds", "layout bounds", Map(
                "winX", win["x"], "winY", win["y"], "winW", win["w"], "winH", win["h"],
                "sidebarCfg", sidebar, "minX", minX, "maxX", maxX,
                "cx", layout["cx"], "cy", layout["cy"],
                "composeX", layout["composeX"], "composeY", layout["composeY"],
                "zoomed", zoomed,
                "sidebarPct", Round(100 * (minX - win["x"]) / Max(1, win["w"]), 1)
            ), "A")
        }
        ; #endregion
        return layout
    }

    _MessagePaneBounds(win := 0) {
        return this._LayoutSnapshot(win)
    }

    _WorkAreaRect() {
        rect := Buffer(16, 0)
        if !DllCall("SystemParametersInfo", "UInt", 0x30, "UInt", 0, "Ptr", rect, "UInt", 0) {
            return Map("x", 0, "y", 0, "w", A_ScreenWidth, "h", A_ScreenHeight)
        }
        left := NumGet(rect, 0, "Int")
        top := NumGet(rect, 4, "Int")
        right := NumGet(rect, 8, "Int")
        bottom := NumGet(rect, 12, "Int")
        return Map(
            "x", left, "y", top,
            "w", Max(800, right - left),
            "h", Max(600, bottom - top)
        )
    }

    EnsureMaximized() {
        if !this.config.StartupMaximizeZalo
            return false
        hwnd := this._MainHwnd()
        if !hwnd
            return false
        if WinGetMinMax(hwnd) = 1
            return true
        WinMaximize "ahk_id " hwnd
        Sleep 450
        return WinGetMinMax(hwnd) = 1
    }

    ; Restore Zalo to a stable non-maximized size so mouse ratios stay predictable.
    EnsureNormalized() {
        if this.config.StartupMaximizeZalo
            return false
        hwnd := this._MainHwnd()
        if !hwnd
            return false
        state := WinGetMinMax(hwnd)
        if state != 0 {
            WinRestore "ahk_id " hwnd
            Sleep 350
        }
        targetW := this.config.HasProp("NormalizedWindowWidth")
            ? Integer(this.config.NormalizedWindowWidth) : 0
        targetH := this.config.HasProp("NormalizedWindowHeight")
            ? Integer(this.config.NormalizedWindowHeight) : 0
        if targetW >= 800 && targetH >= 600 {
            work := this._WorkAreaRect()
            outerW := targetW
            outerH := targetH
            try {
                WinGetPos &curX, &curY, &curW, &curH, "ahk_id " hwnd
                WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
                borderW := Max(0, curW - cw)
                borderH := Max(0, curH - ch)
                outerW := targetW + borderW
                outerH := targetH + borderH
                posX := work["x"] + Round((work["w"] - outerW) / 2)
                posY := work["y"] + Round((work["h"] - outerH) / 2)
                if Abs(curW - outerW) > 8 || Abs(curH - outerH) > 8
                    || Abs(curX - posX) > 8 || Abs(curY - posY) > 8
                    WinMove posX, posY, outerW, outerH, "ahk_id " hwnd
            } catch {
                posX := work["x"] + Round((work["w"] - outerW) / 2)
                posY := work["y"] + Round((work["h"] - outerH) / 2)
                WinMove posX, posY, outerW, outerH, "ahk_id " hwnd
            }
            Sleep 400
        }
        win := this._WindowRect()
        zoomed := WinGetMinMax(hwnd)
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:EnsureNormalized", "window normalized", Map(
            "zoomed", zoomed,
            "winX", win["x"], "winY", win["y"],
            "winW", win["w"], "winH", win["h"],
            "targetW", targetW, "targetH", targetH
        ), "W", "post-fix")
        ; #endregion
        return zoomed = 0
    }

    EnsureWindowState() {
        if this.config.StartupMaximizeZalo
            return this.EnsureMaximized()
        return this.EnsureNormalized()
    }

    IsRunning() {
        return !!this._MainHwnd() || WinExist("ahk_exe " this.config.ExeName)
    }

    Activate() {
        if !this.IsRunning()
            throw Error("Zalo PC chưa mở. Hãy mở Zalo trước.")
        ; Keep Acc + mouse in the same physical pixel space (fullscreen / DPI).
        try DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
        hwnd := this._MainHwnd()
        if hwnd
            WinActivate "ahk_id " hwnd
        else
            WinActivate "ahk_exe " this.config.ExeName
        if hwnd {
            if !WinWaitActive("ahk_id " hwnd,, 3)
                throw Error("Không kích hoạt được cửa sổ Zalo.")
        } else if !WinWaitActive("ahk_exe " this.config.ExeName,, 3) {
            throw Error("Không kích hoạt được cửa sổ Zalo.")
        }
        this.EnsureWindowState()
        Sleep 250
    }

    _RequireMainActive(operation) {
        hwnd := this._MainHwnd()
        if !hwnd || !WinActive("ahk_id " hwnd)
            throw Error("Zalo main window mất focus trước khi " operation ".")
        return hwnd
    }

    _PublishDebugSnapshot(stage, hypothesisId := "P", groupName := "") {
        activeHwnd := 0
        activeTitle := ""
        try activeHwnd := WinExist("A")
        try activeTitle := WinGetTitle("A")
        cursorX := cursorY := -1
        pt := Buffer(8, 0)
        if DllCall("GetCursorPos", "Ptr", pt) {
            cursorX := NumGet(pt, 0, "Int")
            cursorY := NumGet(pt, 4, "Int")
        }
        focused := ""
        try focused := ControlGetFocus("A")
        clipTextLen := StrLen(String(A_Clipboard))
        clipPreview := SubStr(
            RegExReplace(Trim(String(A_Clipboard)), "\s+", " "), 1, 80)
        win := this._WindowRect()
        pane := this._MessagePaneBounds(win)
        mainHwnd := this._MainHwnd()
        group := groupName != "" ? groupName
            : (this.publishGroup != "" ? this.publishGroup : this.currentGroup)
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:_PublishDebugSnapshot", stage, Map(
            "group", group,
            "activeHwnd", activeHwnd,
            "activeTitle", SubStr(activeTitle, 1, 80),
            "mainHwnd", mainHwnd,
            "mainActive", (activeHwnd = mainHwnd) ? 1 : 0,
            "cursorX", cursorX, "cursorY", cursorY,
            "focused", focused,
            "clipTextLen", clipTextLen,
            "clipPreview", clipPreview,
            "clipBitmap", this._ClipboardHasBitmapImage() ? 1 : 0,
            "clipHdrop", DllCall("IsClipboardFormatAvailable", "UInt", 15) ? 1 : 0,
            "composeX", pane["composeX"], "composeY", pane["composeY"],
            "msgPaneX", pane["textFocusX"], "msgPaneY", pane["textFocusY"],
            "winW", win["w"], "winH", win["h"]
        ), hypothesisId, "publish-debug")
        ; #endregion
    }

    ; focus: "read" = message pane for copy; "send" = compose box for paste.
    ; Sidebar search uses Acc / Ctrl+F on chat list — not Ctrl+F while message pane focused.
    OpenGroup(groupName, focus := "read") {
        attempts := this.config.HasProp("OpenGroupMaxAttempts")
            ? this.config.OpenGroupMaxAttempts : 2
        lastReason := "không mở được kết quả tìm kiếm"
        Loop attempts {
            this.Activate()
            this._DismissOverlayUi(1)

            opened := false
            if this.config.PreferAccessibleConversationClick
                opened := this._ClickAccessibleConversation(groupName)
            if !opened
                opened := this._OpenGroupViaSidebarSearch(groupName)

            headerStatus := !this.config.VerifyActiveConversation
                ? 1 : this._ActiveConversationStatus(groupName)
            fingerprint := ""
            fingerprintOk := true
            if opened && headerStatus >= 0
                && focus != "send"
                && this.config.HasProp("VerifyConversationFingerprint")
                && this.config.VerifyConversationFingerprint {
                fingerprint := this._ProbeConversationFingerprint()
                fingerprintOk := this._FingerprintMatchesOpen(
                    groupName, fingerprint)
            }
            matched := opened && headerStatus >= 0 && fingerprintOk
            ; #region agent log
            AgentDebugLog("ZaloUI.ahk:OpenGroup", "open group result", Map(
                "group", groupName, "focus", focus, "attempt", A_Index,
                "opened", opened ? 1 : 0, "headerStatus", headerStatus,
                "fingerprint", fingerprint, "matched", matched ? 1 : 0
            ), "C", "post-fix")
            ; #endregion
            if matched {
                if fingerprint != "" {
                    this.groupFingerprints[groupName] := fingerprint
                    this.lastOpenedFingerprint := fingerprint
                    this.lastOpenedGroup := groupName
                }
                break
            }
            lastReason := !opened ? "không mở được kết quả"
                : headerStatus < 0 ? "header không khớp"
                : "nội dung vẫn là chat trước"
            this._DismissOverlayUi(2)
            Sleep this.config.SearchDelayMs
        }
        if !matched
            throw Error("Không mở đúng nhóm '" groupName "': " lastReason)

        this._DismissOverlayUi(1)
        this.currentGroup := groupName
        if focus = "send"
            this._FocusComposeBox()
        ; focus=read: harvest/capture clicks message pane when copying — skip here
        ; to avoid an extra mouse jump to the middle of the chat after open.
        return true
    }

    _FingerprintMatchesOpen(groupName, fingerprint) {
        if fingerprint = ""
            return true
        if this.groupFingerprints.Has(groupName)
            return this.groupFingerprints[groupName] = fingerprint
        return !(this.lastOpenedFingerprint != ""
            && fingerprint = this.lastOpenedFingerprint
            && this.lastOpenedGroup != ""
            && this.lastOpenedGroup != groupName)
    }

    _ProbeConversationFingerprint() {
        this._ClickMessagePane()
        this._PublishDebugSnapshot("fingerprint_before_ctrla", "H2")
        old := ClipboardAll()
        try {
            A_Clipboard := ""
            Send "^a"
            Sleep this.config.PasteDelayMs
            this._PublishDebugSnapshot("fingerprint_after_ctrla", "H2")
            Send "^c"
            text := ClipWait(this.config.ClipWaitSeconds)
                ? String(A_Clipboard) : ""
            this._PublishDebugSnapshot("fingerprint_after_copy", "H2")
            Send "{Esc}"
            normalized := RegExReplace(
                Trim(NormalizeNewlines(text)), "\s+", " ")
            return StrLen(normalized) >= 30 ? FnvHash(normalized) : ""
        } finally {
            A_Clipboard := old
        }
    }

    _DismissOverlayUi(times := 1) {
        Loop Max(1, times) {
            Send "{Esc}"
            Sleep 120
        }
    }

    _OpenGroupViaSidebarSearch(groupName) {
        this.Activate()
        Send "!1"
        Sleep this.config.GroupListSettleMs

        if !this._FocusConversationSearchBox()
            return false

        this._ReplaceFocusedText(groupName)
        Sleep this.config.SearchDelayMs + 300

        ; Filtered sidebar: Acc click only when enabled (Acc tree walk can hang).
        if this.config.PreferAccessibleConversationClick
            && this._ClickAccessibleConversation(groupName, false)
            return true

        ; Enter opens the first filtered row. Down from the search box lands on
        ; filter tabs (Tất cả / Liên hệ) — never use a bare Down+Enter here.
        method := "enter"
        Send "{Enter}"
        Sleep this.config.OpenChatDelayMs
        headerOk := !this.config.VerifyActiveConversation
            || this._ActiveConversationStatus(groupName) >= 0
        if !headerOk {
            method := "down3_enter"
            Send "{Down 3}"
            Sleep 120
            Send "{Enter}"
            Sleep this.config.OpenChatDelayMs
            headerOk := !this.config.VerifyActiveConversation
                || this._ActiveConversationStatus(groupName) >= 0
        }
        if !headerOk {
            method := "click_first_result"
            this._ClickFirstFilteredConversation()
            Sleep this.config.OpenChatDelayMs
        }
        Send "{Esc}"
        Sleep 120
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:_OpenGroupViaSidebarSearch",
            "sidebar search open", Map(
                "group", groupName, "method", method
            ), "C", "post-fix")
        ; #endregion
        return true
    }

    ; Click first row in the filtered left chat list (below search).
    _ClickFirstFilteredConversation() {
        win := this._WindowRect()
        layout := this._LayoutSnapshot(win)
        x := layout["firstResultX"]
        y := layout["firstResultY"]
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:_ClickFirstFilteredConversation",
            "click first result", Map(
                "x", x, "y", y, "sidebar", layout["sidebarWidth"],
                "winW", win["w"], "zoomed", win.Has("hwnd")
                    ? WinGetMinMax("ahk_id " win["hwnd"]) : -1
            ), "C", "post-fix")
        ; #endregion
        this._ScreenClick(x, y)
        Sleep this.config.OpenChatDelayMs
        return true
    }

    ; Top of left chat list. Prefer Acc label / Ctrl+F after sidebar focus.
    _FocusConversationSearchBox() {
        if this._FocusAccConversationSearch()
            return true

        win := this._WindowRect()
        layout := this._LayoutSnapshot(win)
        ; Focus the sidebar search row, not a conversation below it.
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:_FocusConversationSearchBox",
            "click search box", Map(
                "x", layout["searchX"], "y", layout["searchY"],
                "sidebar", layout["sidebarWidth"], "winW", win["w"]
            ), "C", "post-fix")
        ; #endregion
        this._ScreenClick(layout["searchX"], layout["searchY"])
        Sleep this.config.PasteDelayMs + 80

        ; Zalo PC: Ctrl+F = sidebar search when chat list has focus (not in-chat).
        Send this.config.GroupSearchHotkey
        Sleep this.config.SearchDelayMs + 150
        if this._FocusedControlLooksLikeSearch()
            return true

        ; Last resort: direct ratio click into the search row (skip icon rail).
        this._ScreenClick(layout["searchX"], layout["searchY"])
        Sleep this.config.PasteDelayMs + 100
        return true
    }

    _FocusAccConversationSearch() {
        root := this._AccessibleRoot()
        if !root
            return false
        win := this._WindowRect()
        minX := win["x"] + Round(win["w"] * this.config.GroupSidebarMinXRatio)
        maxX := win["x"] + Round(win["w"] * this.config.GroupAccessibilityLeftRatio)
        minY := win["y"] + Round(win["h"] * 0.02)
        maxY := win["y"] + Round(win["h"] * 0.16)

        labelNeedle := "i)(?:tìm kiếm|tim kiem|search|tìm tin|tim tin|tìm tên|tim ten)"
        try labeled := root.FindElements({
            or: [
                {Name: "Tìm kiếm", matchmode: "SubString", casesensitive: false},
                {Name: "Search", matchmode: "SubString", casesensitive: false},
                {Value: "Tìm kiếm", matchmode: "SubString", casesensitive: false},
                {Description: "Tìm kiếm", matchmode: "SubString", casesensitive: false}
            ]
        }, Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            labeled := []

        for element in labeled {
            if !this._AccPointInRect(element, minX, maxX, minY, maxY)
                continue
            if this._ElementClick(element)
                return true
        }

        try elements := root.FindElements([
            {Role: Acc.Role.Text},
            {Role: Acc.Role.ComboBox}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return false

        best := 0
        bestScore := -1
        for element in elements {
            if !this._AccPointInRect(element, minX, maxX, minY, maxY)
                continue
            try location := element.Location
            catch
                continue
            if location.h > 72 || location.w < 80
                continue
            score := 1000 - (location.w * location.h)
            for value in this._AccessibleElementStrings(element) {
                if RegExMatch(value, labelNeedle)
                    score += 5000
            }
            if score > bestScore {
                bestScore := score
                best := element
            }
        }
        if !best
            return false
        return this._ElementClick(best)
    }

    _AccPointInRect(element, minX, maxX, minY, maxY) {
        try location := element.Location
        catch
            return false
        if location.w <= 0 || location.h <= 0
            return false
        cx := location.x + Round(location.w / 2)
        cy := location.y + Round(location.h / 2)
        return cx >= minX && cx <= maxX && cy >= minY && cy <= maxY
    }

    _FocusedControlLooksLikeSearch() {
        hwnd := this._MainHwnd()
        if !hwnd
            return false
        try focused := ControlGetFocus("ahk_id " hwnd)
        catch
            return false
        if focused = ""
            return false
        cls := "", caption := ""
        try cls := WinGetClass(focused)
        try caption := ControlGetText(focused)
        combined := cls " " caption
        return RegExMatch(combined, "i)(?:edit|search|tìm|tim)")
    }

    _ClickAccessibleConversation(groupName, prepareList := true) {
        if prepareList {
            Send "{Esc}"
            Sleep 100
            Send "!1"
            Sleep this.config.GroupListSettleMs
        }
        root := this._AccessibleRoot()
        if !root
            return false
        win := this._WindowRect()
        maxX := win["x"] + Round(win["w"] * this.config.GroupAccessibilityLeftRatio)
        targetKey := GroupRegistry._Key(groupName)
        ; ListItem/OutlineItem only — StaticText matches random labels and
        ; causes repeated clicks at wrong coordinates.
        try elements := root.FindElements([
            {Role: Acc.Role.ListItem},
            {Role: Acc.Role.OutlineItem}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return false
        best := 0
        bestScore := -1
        for element in elements {
            name := ""
            try name := element.Name
            if name = ""
                continue
            nameKey := GroupRegistry._Key(name)
            if nameKey != targetKey && !InStr(nameKey, targetKey)
                continue
            try location := element.Location
            catch
                continue
            if location.w <= 0 || location.h <= 0
                || location.x < win["x"] || location.x >= maxX
                || location.y < win["y"] || location.y >= win["y"] + win["h"]
                continue
            score := StrLen(nameKey)
            if nameKey = targetKey
                score += 1000
            if score > bestScore {
                bestScore := score
                best := element
            }
        }
        if !best
            return false
        if !this._ElementClick(best)
            return false
        Sleep this.config.OpenChatDelayMs
        return true
    }

    ; 1 = matching header, 0 = Zalo exposes no usable header, -1 = mismatch.
    _ActiveConversationStatus(groupName) {
        ; Always honor VerifyActiveConversation — PreferAccessibleConversationClick
        ; only gates Acc *click* for opening, not header verification.
        root := this._AccessibleRoot()
        if !root
            return 0
        win := this._WindowRect()
        sidebar := 0
        if this.config.HasProp("LayoutSidebarWidthPx")
            sidebar := Integer(this.config.LayoutSidebarWidthPx)
        minX := sidebar > 0
            ? win["x"] + Min(sidebar, Round(win["w"] * 0.48))
            : win["x"] + Round(win["w"] * 0.32)
        maxY := win["y"] + Round(win["h"] * 0.20)
        targetKey := GroupRegistry._Key(groupName)
        inspected := 0
        ; Shallower walk than full harvest Acc — header labels are near the root.
        depth := Min(this.config.GroupAccessibilityDepth, 12)
        try elements := root.FindElements([
            {Role: Acc.Role.StaticText},
            {Role: Acc.Role.Text}
        ], Acc.TreeScope.Descendants, 0, depth)
        catch
            return 0
        for element in elements {
            try location := element.Location
            catch
                continue
            if location.x < minX || location.y < win["y"] || location.y > maxY
                continue
            name := ""
            try name := element.Name
            if name = ""
                continue
            inspected++
            nameKey := GroupRegistry._Key(name)
            if nameKey = targetKey || InStr(nameKey, targetKey)
                || InStr(targetKey, nameKey)
                return 1
        }
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:_ActiveConversationMatches",
            "header verify", Map(
                "group", groupName, "inspected", inspected,
                "matched", 0, "minX", minX, "maxY", maxY
            ), "C")
        ; #endregion
        return inspected = 0 ? 0 : -1
    }

    ; Copy the conversation text of the currently open chat.
    ; manual    — the operator already highlighted the messages
    ; selectall — click the message pane, then Ctrl+A / Ctrl+C
    CaptureConversationText(method := "") {
        mode := method != "" ? method : this.config.CaptureMethod
        this.Activate()

        if mode = "accessibility" {
            captured := this._CaptureAccessibleConversationText()
            if Trim(captured) != ""
                return captured
            mode := this.config.CaptureAccessibilityFallback
        }

        if mode = "selectall" {
            ; Focus the message pane (Acc Document/Pane) before select-all copy.
            this._ClickMessagePane()
            Send "^a"
            Sleep this.config.PasteDelayMs
        }

        old := ClipboardAll()
        A_Clipboard := ""
        Send "^c"
        captured := ClipWait(this.config.ClipWaitSeconds) ? A_Clipboard : ""
        Send "{Esc}"
        A_Clipboard := old
        ; #region agent log
        preview := SubStr(RegExReplace(Trim(captured), "\s+", " "), 1, 80)
        AgentDebugLog("ZaloUI.ahk:CaptureConversationText", "capture result", Map(
            "mode", mode, "textLen", StrLen(captured), "preview", preview,
            "group", this.currentGroup
        ), "D", "post-fix")
        ; #endregion
        this._GuardStickyConversation(captured)
        return captured
    }

    ; Detect OpenGroup "success" that left the previous chat still focused.
    ; Use a short normalized prefix — full-hash misses near-identical sticky
    ; captures that only differ by select-all length (545 vs 611).
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
            ; #region agent log
            AgentDebugLog("ZaloUI.ahk:_GuardStickyConversation",
                "sticky conversation", Map(
                    "current", this.currentGroup,
                    "previous", this.lastConversationGroup,
                    "textLen", StrLen(text),
                    "prefix", SubStr(prefix, 1, 60)
                ), "C", "post-fix")
            ; #endregion
            prev := this.lastConversationGroup
            cur := this.currentGroup
            throw Error("OpenGroup không chuyển chat: vẫn nội dung của '"
                . prev "' khi mở '" cur "'.")
        }
        this.lastConversationFingerprint := fp
        this.lastConversationGroup := this.currentGroup
    }

    _ClickConversationTextArea() {
        pane := this._MessagePaneBounds()
        this._ScreenClick(pane["textFocusX"], pane["textFocusY"])
        Sleep this.config.PasteDelayMs
    }

    _CaptureAccessibleConversationText() {
        root := this._AccessibleRoot()
        if !root
            return ""
        win := this._WindowRect()
        pane := this._MessagePaneBounds(win)
        minX := pane["minX"]
        maxX := pane["maxX"]
        minY := pane["minY"]
        maxY := pane["maxY"]
        rows := []
        try elements := root.FindElements([
            {Role: Acc.Role.StaticText},
            {Role: Acc.Role.Text}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return ""
        for element in elements {
            try location := element.Location
            catch
                continue
            if location.w <= 0 || location.h <= 0
                || location.x < minX || location.x > maxX
                || location.y < minY || location.y > maxY
                continue
            value := ""
            try value := element.Name
            if value = ""
                try value := element.Value
            value := Trim(NormalizeNewlines(value))
            if value = ""
                continue
            rows.Push(Map(
                "x", location.x,
                "y", location.y,
                "value", value
            ))
        }
        this._SortAccessibleRows(rows)
        result := []
        previous := ""
        for row in rows {
            value := row["value"]
            if value = previous
                continue
            result.Push(value)
            previous := value
        }
        return StrJoin(result, "`n")
    }

    _SortAccessibleRows(rows) {
        index := 2
        while index <= rows.Length {
            current := rows[index]
            cursor := index - 1
            while cursor >= 1
                && (rows[cursor]["y"] > current["y"]
                    || (rows[cursor]["y"] = current["y"]
                        && rows[cursor]["x"] > current["x"])) {
                rows[cursor + 1] := rows[cursor]
                cursor--
            }
            rows[cursor + 1] := current
            index++
        }
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

        win := this._WindowRect()
        if communitiesTab
            this._ActivateCommunityTab(win)

        if this.config.GroupListUsePaneClick
            this._FocusGroupListPaneByRatio(win)
        else
            Send "{Home}"

        old := ClipboardAll()
        combined := ""
        previous := ""
        repeated := 0
        try {
            Loop this.config.GroupListScanPages {
                page := ""
                if this.config.GroupDiscoveryMode != "clipboard"
                    page := this._CaptureAccessiblePaneText(false)
                if page = "" && this.config.GroupDiscoveryMode != "accessibility" {
                    A_Clipboard := ""
                    Send "^a"
                    Sleep this.config.PasteDelayMs
                    Send "^c"
                    page := ClipWait(this.config.ClipWaitSeconds)
                        ? String(A_Clipboard) : ""
                }
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

                this._AdvanceGroupListScroll()
            }
        } finally {
            A_Clipboard := old
        }
        return combined
    }

    _FocusGroupListPaneByRatio(win) {
        pt := this._RatioPoint(win,
            this.config.GroupListPaneClickXRatio,
            this.config.GroupListPaneClickYRatio)
        this._ScreenClick(pt[1], pt[2])
        Sleep this.config.PasteDelayMs
        Send "{Home}"
        Sleep this.config.GroupListSettleMs
    }

    _ActivateCommunityTab(win) {
        root := this._AccessibleRoot()
        if root {
            try tabs := root.FindElements([
                {Role: Acc.Role.PageTab},
                {Role: Acc.Role.Button}
            ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
            catch
                tabs := []
            maxX := win["x"] + Round(win["w"] * 0.45)
            for tab in tabs {
                label := ""
                try label := tab.Name
                if label = "" || !RegExMatch(label, "i)(?:cong dong|community|cộng đồng)")
                    continue
                try location := tab.Location
                catch
                    continue
                if location.x > maxX
                    continue
                if this._ElementClick(tab) {
                    Sleep this.config.GroupListSettleMs
                    return
                }
            }
        }
        if this.config.UiUseRatioClicks {
            tabX := win["x"] + Round(win["w"] * this.config.GroupCommunityTabClickXRatio)
            tabY := win["y"] + Round(win["h"] * this.config.GroupCommunityTabClickYRatio)
            this._ScreenClick(tabX, tabY)
            Sleep this.config.GroupListSettleMs
        }
    }

    ; Read Chromium/Electron accessibility names instead of selecting/copying
    ; the Zalo UI. This avoids caching the group avatar as clipboard media.
    _CaptureAccessiblePaneText(includeState := false) {
        root := this._AccessibleRoot()
        if !root
            return ""
        win := this._WindowRect()
        maxX := win["x"] + Round(win["w"] * this.config.GroupAccessibilityLeftRatio)
        result := []
        seen := Map()
        try elements := root.FindElements([
            {Role: Acc.Role.ListItem},
            {Role: Acc.Role.OutlineItem}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return ""
        this._AppendAccessiblePaneElements(
            elements, result, seen, includeState,
            win["x"], win["y"], win["w"], win["h"], maxX)
        if result.Length
            return StrJoin(result, "`n")
        try elements := root.FindElements([
            {Role: Acc.Role.StaticText},
            {Role: Acc.Role.Text}
        ], Acc.TreeScope.Descendants, 0,
            this.config.GroupAccessibilityDepth)
        catch
            return ""
        this._AppendAccessiblePaneElements(
            elements, result, seen, includeState,
            win["x"], win["y"], win["w"], win["h"], maxX)
        return StrJoin(result, "`n")
    }

    _AppendAccessiblePaneElements(
        elements, result, seen, includeState, x, y, w, h, maxX
    ) {
        for element in elements {
            try location := element.Location
            catch
                continue
            if location.w <= 0 || location.h <= 0
                || location.x < x || location.x >= maxX
                || location.y < y || location.y >= y + h
                continue
            for value in this._AccessibleElementStrings(element, includeState) {
                clean := Trim(RegExReplace(value, "\s+", " "))
                if clean = "" || seen.Has(clean)
                    continue
                seen[clean] := true
                result.Push(clean)
            }
        }
    }

    CaptureUnreadConversationText() {
        this.Activate()
        Send "{Esc}"
        Sleep 100
        Send "!1"
        Sleep this.config.GroupListSettleMs
        return this._CaptureAccessiblePaneText(true)
    }

    ; Acc sidebar: ListItems with unread badge (number or marker text).
    ; Returns unique known group names; empty when Zalo exposes no unread state.
    FindUnreadSidebarGroups(knownGroups) {
        this.Activate()
        Send "{Esc}"
        Sleep 100
        Send "!1"
        Sleep this.config.GroupListSettleMs

        items := this._CollectSidebarConversationItems()
        names := GroupActivityDetector.DetectUnreadFromItems(
            items, knownGroups, this.config.GroupUnreadMarkerPattern)
        if names.Length
            return names

        ; Flat text fallback (Name/Value dump without ListItem structure).
        raw := this._CaptureAccessiblePaneText(true)
        return GroupActivityDetector.DetectUnread(
            raw, knownGroups, this.config.GroupUnreadMarkerPattern)
    }

    _CollectSidebarConversationItems() {
        root := this._AccessibleRoot()
        if !root
            return []
        win := this._WindowRect()
        maxX := win["x"] + Round(win["w"] * this.config.GroupAccessibilityLeftRatio)
        items := []
        try elements := root.FindElements([
            {Role: Acc.Role.ListItem},
            {Role: Acc.Role.OutlineItem}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return []

        for element in elements {
            try location := element.Location
            catch
                continue
            if location.w <= 0 || location.h <= 0
                || location.x < win["x"] || location.x >= maxX
                || location.y < win["y"] || location.y >= win["y"] + win["h"]
                continue

            parts := []
            seen := Map()
            for value in this._AccessibleElementStrings(element, true) {
                clean := Trim(RegExReplace(value, "\s+", " "))
                if clean = "" || seen.Has(clean)
                    continue
                seen[clean] := true
                parts.Push(clean)
            }
            try children := element.Children
            catch
                children := []
            for child in children {
                for value in this._AccessibleElementStrings(child, true) {
                    clean := Trim(RegExReplace(value, "\s+", " "))
                    if clean = "" || seen.Has(clean)
                        continue
                    seen[clean] := true
                    parts.Push(clean)
                }
            }
            if !parts.Length
                continue

            name := parts[1]
            badge := ""
            extraParts := []
            for part in parts {
                if badge = "" {
                    extracted := GroupActivityDetector.ExtractBadge(part)
                    if extracted != "" {
                        badge := extracted
                        continue
                    }
                }
                if part != name
                    extraParts.Push(part)
            }
            items.Push(Map(
                "name", name,
                "badge", badge,
                "text", StrJoin(extraParts, "`n")
            ))
        }
        return items
    }

    _AccessibleRoot() {
        hwnd := this._MainHwnd()
        if !hwnd
            return 0
        try return Acc.ElementFromHandle(hwnd)
        catch
            return 0
    }

    _AccessibleElementStrings(element, includeState := true) {
        values := []
        properties := includeState
            ? ["Name", "Value", "Description", "StateText"]
            : ["Name", "Value"]
        for property in properties {
            try {
                value := element.%property%
                if value != ""
                    values.Push(String(value))
            }
        }
        return values
    }

    ; Find image bubbles near listing text. Zalo Electron often does NOT expose
    ; chat photos as Acc.Role.Graphic — fall back to large panes + heuristic
    ; positions above the message text.
    FindImageBubblesNearMessage(anchor, maxImages := 6, allowHeuristic := false) {
        if Trim(anchor) = ""
            return []

        win := this._WindowRect()
        pane := this._MessagePaneBounds(win)
        paneMinX := pane["minX"]
        paneMaxX := pane["maxX"]
        contentMinY := pane["minY"]
        contentMaxY := pane["maxY"]
        anchorY := pane["cy"]
        anchorX := pane["cx"]
        foundText := false
        searchedInChat := false

        ; Prefer Acc text match in the already-open chat before Ctrl+F.
        textLoc := this._FindMessageTextLocation(
            anchor, paneMinX, paneMaxX, contentMinY, contentMaxY)
        if textLoc {
            anchorY := textLoc["y"]
            anchorX := textLoc["x"]
            foundText := true
        } else {
            this.FindMessageInConversation(anchor)
            searchedInChat := true
            Sleep this.config.ImageViewerSettleMs
            textLoc := this._FindMessageTextLocation(
                anchor, paneMinX, paneMaxX, contentMinY, contentMaxY)
            if textLoc {
                anchorY := textLoc["y"]
                anchorX := textLoc["x"]
                foundText := true
            }
        }

        candidates := this._CollectImageCandidateLocations(
            paneMinX, paneMaxX, contentMinY, contentMaxY, anchorY)
        this._SortLocationsByDistance(candidates)

        ; Acc often hides bubble text/graphics — probe click slots above anchor.
        if !candidates.Length && allowHeuristic {
            if !foundText {
                this._ClickMessagePane()
                anchorX := pane["cx"]
                anchorY := searchedInChat
                    ? pane["minY"] + Round((pane["maxY"] - pane["minY"]) * 0.45)
                    : pane["cy"]
            }
            step := this.config.ImageSelectStepPx
            Loop maxImages {
                clickY := Max(contentMinY + 20, anchorY - (A_Index * step))
                clickX := anchorX
                candidates.Push(Map(
                    "x", clickX,
                    "y", clickY,
                    "left", clickX - 120,
                    "top", clickY - 90,
                    "w", 240,
                    "h", 180,
                    "distance", A_Index * step
                ))
            }
            this._LogImage("heuristic_slots anchor=" anchor
                " searched=" (searchedInChat ? 1 : 0)
                " count=" candidates.Length)
        }

        while candidates.Length > maxImages
            candidates.Pop()
        this._LogImage("image_candidates anchor=" anchor
            " found_text=" (foundText ? 1 : 0)
            " heuristic=" (allowHeuristic ? 1 : 0)
            " count=" candidates.Length)
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:FindImageBubblesNearMessage", "image detect", Map(
            "anchor", SubStr(anchor, 1, 40),
            "foundText", foundText ? 1 : 0,
            "searchedInChat", searchedInChat ? 1 : 0,
            "count", candidates.Length,
            "paneMinX", paneMinX, "paneMaxX", paneMaxX,
            "anchorX", anchorX, "anchorY", anchorY
        ), "B")
        ; #endregion
        return candidates
    }

    _FindMessageTextLocation(anchor, paneMinX, paneMaxX, contentMinY, contentMaxY) {
        root := this._AccessibleRoot()
        if !root
            return 0
        try textElements := root.FindElements([
            {Role: Acc.Role.StaticText},
            {Role: Acc.Role.Text}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return 0
        for element in textElements {
            matched := false
            for value in this._AccessibleElementStrings(element) {
                if InStr(value, anchor, false)
                    || (StrLen(anchor) > 8
                        && InStr(value, SubStr(anchor, 1, 8), false)) {
                    matched := true
                    break
                }
            }
            if !matched
                continue
            try location := element.Location
            catch
                continue
            if location.x >= paneMinX && location.x <= paneMaxX
                && location.y >= contentMinY && location.y <= contentMaxY {
                return Map(
                    "x", location.x + Round(location.w / 2),
                    "y", location.y,
                    "w", location.w,
                    "h", location.h
                )
            }
        }
        return 0
    }

    _CollectImageCandidateLocations(
        paneMinX, paneMaxX, contentMinY, contentMaxY, anchorY
    ) {
        root := this._AccessibleRoot()
        if !root
            return []
        roles := [
            {Role: Acc.Role.Graphic},
            {Role: Acc.Role.Document},
            {Role: Acc.Role.Pane},
            {Role: Acc.Role.Animation}
        ]
        candidates := []
        seen := Map()
        try elements := root.FindElements(
            roles, Acc.TreeScope.Descendants, 0,
            this.config.GroupAccessibilityDepth)
        catch
            return []
        for element in elements {
            try location := element.Location
            catch
                continue
            centerY := location.y + Round(location.h / 2)
            distance := Abs(centerY - anchorY)
            if this.config.ImageCandidateDirection = "above"
                && centerY > anchorY + 40
                continue
            if this.config.ImageCandidateDirection = "below"
                && centerY < anchorY - 40
                continue
            if location.x < paneMinX || location.x > paneMaxX
                || location.y < contentMinY || location.y > contentMaxY
                || location.w < this.config.ImageCandidateMinWidthPx
                || location.h < this.config.ImageCandidateMinHeightPx
                || distance > this.config.ImageCandidateMaxDistancePx
                continue
            ; Skip ultra-wide chrome strips (header/footer).
            if location.w > (paneMaxX - paneMinX) * 0.95 && location.h < 80
                continue
            key := location.x ":" location.y ":" location.w ":" location.h
            if seen.Has(key)
                continue
            seen[key] := true
            candidates.Push(Map(
                "x", location.x + Round(location.w / 2),
                "y", centerY,
                "left", location.x,
                "top", location.y,
                "w", location.w,
                "h", location.h,
                "distance", distance
            ))
        }
        return candidates
    }

    _SortLocationsByDistance(items) {
        index := 2
        while index <= items.Length {
            current := items[index]
            cursor := index - 1
            while cursor >= 1 && items[cursor]["distance"] > current["distance"] {
                items[cursor + 1] := items[cursor]
                cursor--
            }
            items[cursor + 1] := current
            index++
        }
    }

    ; Prefer on-screen BitBlt (Electron-safe), then context-menu / viewer copy.
    ; Zalo often puts CF_HDROP or nothing on Ctrl+C.
    CopyImageAt(location) {
        this.Activate()
        if location.Has("left") && location.Has("top")
            && location.Has("w") && location.Has("h")
            && location["w"] >= 8 && location["h"] >= 8 {
            ; Bring bubble into focus without relying on clipboard.
            this._ScreenClick(location["x"], location["y"])
            Sleep this.config.PasteDelayMs + 100
            if this._CopyScreenRegionToClipboard(
                location["left"], location["top"], location["w"], location["h"]) {
                this._LogImage("copy_bitblt ok "
                    . location["w"] "x" location["h"])
                return true
            }
        }

        if this._CopyImageViaContextMenu(location["x"], location["y"]) {
            this._LogImage("copy_context_menu ok")
            return true
        }

        A_Clipboard := ""
        this._ScreenClick(location["x"], location["y"])
        Sleep this.config.ImageViewerSettleMs
        ; Some Zalo builds need double-click to open the image viewer.
        this._ScreenClick(location["x"], location["y"])
        Sleep this.config.ImageViewerSettleMs
        Send this.config.ImageCopyHotkey
        Sleep this.config.PasteDelayMs + 200
        if this._WaitForClipboardImage() {
            Send "{Esc}"
            this._LogImage("copy_viewer_hotkey ok")
            return true
        }
        Send "{Esc}"
        Sleep 150
        this._LogImage("copy_failed at "
            . location["x"] "," location["y"])
        return false
    }

    _CopyImageViaContextMenu(x, y) {
        ; Try accelerator keys, then arrow-navigate common Zalo menu rows.
        sequences := []
        for key in this._ImageContextCopyKeys()
            sequences.Push(key)
        sequences.Push("{Down}{Enter}")
        sequences.Push("{Down}{Down}{Enter}")
        sequences.Push("{Down}{Down}{Down}{Enter}")

        for seq in sequences {
            A_Clipboard := ""
            this._ScreenClick(x, y, "Right")
            Sleep this.config.PasteDelayMs + 350
            Send seq
            Sleep this.config.PasteDelayMs + 350
            if this._WaitForClipboardImage()
                return true
            ; "Lưu hình ảnh" / Save As may open a dialog — cancel it.
            Send "{Esc}"
            Sleep 120
            Send "{Esc}"
            Sleep 80
        }
        return false
    }

    _ImageContextCopyKeys() {
        keys := []
        seen := Map()
        raw := ""
        if this.config.HasProp("ImageContextCopyKeys")
            raw := Trim(this.config.ImageContextCopyKeys)
        if raw = "" && this.config.HasProp("ImageContextCopyKey")
            raw := Trim(this.config.ImageContextCopyKey)
        if raw = ""
            raw := "c,i"
        for part in StrSplit(raw, ",") {
            key := Trim(part)
            if key = ""
                continue
            norm := StrLower(key)
            if seen.Has(norm)
                continue
            seen[norm] := true
            keys.Push(key)
        }
        if !keys.Length {
            keys.Push("c")
            keys.Push("i")
        }
        return keys
    }

    ; ClipWait without WaitForAnyData only waits for text — Zalo image copy
    ; puts CF_DIB/PNG/HDROP and would always time out.
    _WaitForClipboardImage() {
        ClipWait(this.config.ClipWaitSeconds, 1)
        return this._ClipboardHasImage()
    }

    ; Last-resort capture of the on-screen Acc Graphic rectangle (Electron-safe).
    _CopyScreenRegionToClipboard(x, y, w, h) {
        if w < 8 || h < 8
            return false
        hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
        if !hdcScreen
            return false
        hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
        hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdcScreen, "Int", w, "Int", h, "Ptr")
        if !hdcMem || !hbm {
            if hbm
                DllCall("DeleteObject", "Ptr", hbm)
            if hdcMem
                DllCall("DeleteDC", "Ptr", hdcMem)
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
            return false
        }
        obm := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hbm, "Ptr")
        ok := DllCall("BitBlt",
            "Ptr", hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", h,
            "Ptr", hdcScreen, "Int", x, "Int", y,
            "UInt", 0x00CC0020)
        DllCall("SelectObject", "Ptr", hdcMem, "Ptr", obm, "Ptr")
        DllCall("DeleteDC", "Ptr", hdcMem)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
        if !ok {
            DllCall("DeleteObject", "Ptr", hbm)
            return false
        }
        if !DllCall("OpenClipboard", "Ptr", A_ScriptHwnd) {
            DllCall("DeleteObject", "Ptr", hbm)
            return false
        }
        DllCall("EmptyClipboard")
        ; Clipboard owns hbm after a successful SetClipboardData(CF_BITMAP).
        if !DllCall("SetClipboardData", "UInt", 2, "Ptr", hbm) {
            DllCall("CloseClipboard")
            DllCall("DeleteObject", "Ptr", hbm)
            return false
        }
        DllCall("CloseClipboard")
        return this._WaitForClipboardImage()
    }

    _LogImage(message) {
        try {
            logPath := this.config.HasProp("QueueLogFile")
                ? this.config.QueueLogFile : ""
            if logPath != ""
                FileAppend "[" NowStamp() "] image " message "`n",
                    logPath, "UTF-8-RAW"
        } catch {
        }
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
        this.Activate()
        this._DismissOverlayUi(1)
        win := this._WindowRect()
        pane := this._MessagePaneBounds(win)
        minXR := (pane["minX"] - win["x"]) / Max(1, win["w"])
        maxXR := (pane["maxX"] - win["x"]) / Max(1, win["w"])
        minYR := (pane["minY"] - win["y"]) / Max(1, win["h"])
        maxYR := (pane["maxY"] - win["y"]) / Max(1, win["h"])
        usedAcc := this._FocusAccRegion(["Document", "Pane"], minXR, maxXR, minYR, maxYR)
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:_ClickMessagePane", "focus message pane", Map(
            "usedAcc", usedAcc ? 1 : 0,
            "clickX", pane["textFocusX"], "clickY", pane["textFocusY"],
            "centerX", pane["cx"], "centerY", pane["cy"],
            "minX", pane["minX"], "maxX", pane["maxX"],
            "purpose", "copy_safe"
        ), "D")
        ; #endregion
        ; Upper-left text band — avoids center image bubbles when copy/select-all.
        this._ScreenClick(pane["textFocusX"], pane["textFocusY"])
        Sleep this.config.PasteDelayMs
    }

    ; Zalo PC: after search/open chat, focus must be in the compose box before Ctrl+V.
    _FocusComposeBox() {
        this.Activate()
        win := this._WindowRect()
        pane := this._MessagePaneBounds(win)
        minXR := (pane["minX"] - win["x"]) / Max(1, win["w"])
        maxXR := (pane["maxX"] - win["x"]) / Max(1, win["w"])
        usedAcc := this._FocusAccRegion(
            ["Text", "ComboBox"], minXR, maxXR, 0.84, 0.98)
        ; #region agent log
        AgentDebugLog("ZaloUI.ahk:_FocusComposeBox", "focus compose", Map(
            "usedAcc", usedAcc ? 1 : 0,
            "composeX", pane["composeX"], "composeY", pane["composeY"],
            "minX", pane["minX"], "maxX", pane["maxX"]
        ), "E")
        ; #endregion
        ; Always confirm the compose row. Electron often reports the whole chat
        ; document as an editable element even though it is not the input box.
        this._ScreenClick(pane["composeX"], pane["composeY"])
        Sleep this.config.PasteDelayMs + 100
        this._PublishDebugSnapshot("compose_focus_after", "H1")
    }

    _ResolveAccRole(roleName) {
        if roleName = "Edit" || roleName = "TextEdit" || roleName = "Editable"
            return Acc.Role.Text
        try {
            return Acc.Role.%roleName%
        } catch {
            return 0
        }
    }

    _FocusAccRegion(roleNames, minXRatio, maxXRatio, minYRatio, maxYRatio) {
        root := this._AccessibleRoot()
        if !root
            return false
        win := this._WindowRect()
        minX := win["x"] + Round(win["w"] * minXRatio)
        maxX := win["x"] + Round(win["w"] * maxXRatio)
        minY := win["y"] + Round(win["h"] * minYRatio)
        maxY := win["y"] + Round(win["h"] * maxYRatio)
        criteria := []
        for roleName in roleNames {
            role := this._ResolveAccRole(roleName)
            if role
                criteria.Push({Role: role})
        }
        if !criteria.Length
            return false
        try elements := root.FindElements(
            criteria, Acc.TreeScope.Descendants, 0,
            this.config.GroupAccessibilityDepth)
        catch
            return false
        best := 0
        bestArea := -1
        for element in elements {
            try location := element.Location
            catch
                continue
            if location.w <= 0 || location.h <= 0
                || location.x < minX || location.x > maxX
                || location.y < minY || location.y > maxY
                continue
            area := location.w * location.h
            if area > bestArea {
                bestArea := area
                best := element
            }
        }
        if !best
            return false
        return this._ElementClick(best)
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

    ; Search within the already-open conversation only (images/anchors).
    ; Do not call this to open a group — use OpenGroup instead.
    FindMessageInConversation(query) {
        if Trim(query) = ""
            throw Error("Anchor tìm tin rỗng.")
        this.Activate()
        this._ClickMessagePane()
        this._DismissOverlayUi()
        Send this.config.FindInChatHotkey
        Sleep this.config.SearchDelayMs + 100
        this._ReplaceFocusedText(query)
        Sleep this.config.SearchDelayMs + 200
        Send "{Enter}"
        Sleep this.config.CaptureSettleMs
        this._DismissOverlayUi()
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
            win := this._WindowRect()
            clickX := win["x"] + Round(win["w"] * 0.65)
            baseY := win["y"] + Round(win["h"] * 0.45)
            step := this.config.ImageSelectStepPx
            Send "{Shift down}"
            Loop imageCount {
                clickY := Max(win["y"] + 80, baseY - (A_Index * step))
                if A_Index = 1
                    this._ScreenClick(clickX, clickY)
                else
                    this._ScreenClick(clickX, clickY, "D")
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

    ; Copy image from the bubble the operator selected.
    ; Prefer BitBlt of a small region around the cursor, then context menu / Ctrl+C.
    CopyImageFromSelection() {
        this.Activate()
        old := ClipboardAll()

        ; Screen-capture around current mouse (Zalo bubble under cursor).
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        if this._CopyScreenRegionToClipboard(mx - 120, my - 90, 240, 180)
            return true

        for key in this._ImageContextCopyKeys() {
            A_Clipboard := ""
            Send "{AppsKey}"
            Sleep 350
            Send key
            Sleep this.config.PasteDelayMs + 250
            if this._WaitForClipboardImage()
                return true
            Send "{Esc}"
            Sleep 100
        }

        A_Clipboard := ""
        Send this.config.ImageCopyHotkey
        Sleep this.config.PasteDelayMs + 100
        if this._WaitForClipboardImage()
            return true

        A_Clipboard := old
        return false
    }

    _ClipboardHasImage() {
        if this._ClipboardHasBitmapImage()
            return true
        ; Zalo "Copy hình ảnh" / Save sometimes puts a file path (CF_HDROP).
        if DllCall("IsClipboardFormatAvailable", "UInt", 15)  ; CF_HDROP
            return true
        return false
    }

    _ClipboardHasBitmapImage() {
        if DllCall("IsClipboardFormatAvailable", "UInt", 2)   ; CF_BITMAP
            return true
        if DllCall("IsClipboardFormatAvailable", "UInt", 8)   ; CF_DIB
            return true
        if DllCall("IsClipboardFormatAvailable", "UInt", 17)  ; CF_DIBV5
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
        this._PublishDebugSnapshot("publish_session_ready", "H4", groupName)
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
        this._PublishDebugSnapshot("image_paste_before_ctrla", "H3")
        Send "^a{Backspace}"
        Sleep 100
        Send "^v"
        Sleep this.config.PasteDelayMs + 300
        this._PublishDebugSnapshot("image_paste_after_ctrlv", "H3")
        this._RequireMainActive("gửi ảnh")
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
        this._TriggerForwardDialog()
        this._ConfirmForwardToGroup(groupName)
        return true
    }

    ; Gemini album flow: open first image near listing → Viewer →
    ; Forward → Right → … → Esc. Avoids per-thumbnail BitBlt miss-clicks.
    ForwardAlbumToGroup(anchor, targetGroup, maxImages := 0) {
        if Trim(anchor) = ""
            throw Error("Anchor tìm album ảnh rỗng.")
        if Trim(targetGroup) = ""
            throw Error("Tên nhóm đích forward rỗng.")
        limit := maxImages > 0
            ? maxImages : this.config.AlbumMaxImages
        limit := Max(1, Min(limit, this.config.AlbumMaxImages))

        locations := this.FindImageBubblesNearMessage(anchor, 1, true)
        if !locations.Length
            throw Error("Không tìm thấy ảnh đầu album gần: " anchor)

        loc := locations[1]
        this.Activate()
        this._ScreenClick(loc["x"], loc["y"])
        Sleep this.config.ImageViewerSettleMs
        ; Double-click opens Image Viewer on some Zalo builds.
        this._ScreenClick(loc["x"], loc["y"])
        Sleep this.config.ImageViewerSettleMs + 200

        forwarded := 0
        Loop limit {
            this._TriggerForwardDialog()
            this._ConfirmForwardToGroup(targetGroup)
            forwarded++
            this._LogImage("forward_viewer #" forwarded
                " → " targetGroup)
            if A_Index >= limit
                break
            Send "{Right}"
            Sleep this.config.ImageViewerSettleMs
        }
        Send "{Esc}"
        Sleep 200
        Send "{Esc}"
        Sleep 120
        this._LogImage("forward_album done target=" targetGroup
            " count=" forwarded " anchor=" anchor)
        return forwarded
    }

    _TriggerForwardDialog() {
        mode := StrLower(this.config.HasProp("ViewerForwardMode")
            ? this.config.ViewerForwardMode : "hotkey")
        if mode = "click" {
            win := this._WindowRect()
            x := win["x"] + Round(win["w"] * this.config.ViewerForwardClickX)
            y := win["y"] + Round(win["h"] * this.config.ViewerForwardClickY)
            this._ScreenClick(x, y)
        } else {
            Send this.config.ForwardHotkey
        }
        Sleep this.config.ForwardDialogMs
    }

    _ConfirmForwardToGroup(groupName) {
        this._ReplaceFocusedText(groupName)
        Sleep this.config.SearchDelayMs + 200
        Send "{Enter}"
        Sleep this.config.PasteDelayMs
        Send "{Enter}"
        Sleep this.config.SendDelayMs + 200
    }

    _ReplaceFocusedText(text) {
        if Trim(text) = ""
            throw Error("Không thể paste chuỗi tìm kiếm rỗng.")
        old := ClipboardAll()
        A_Clipboard := ""
        A_Clipboard := text
        if !ClipWait(this.config.ClipWaitSeconds) {
            A_Clipboard := old
            throw Error("Không đặt được tên nhóm Unicode vào clipboard.")
        }
        try {
            Send "^a"
            Sleep 80
            Send "{Backspace}"
            Sleep 80
            Send "^v"
            Sleep this.config.PasteDelayMs
        } finally {
            A_Clipboard := old
        }
    }

    _PasteAndSend(message, refocus := true, beforeSend := 0) {
        old := ClipboardAll()
        A_Clipboard := message
        if !ClipWait(this.config.ClipWaitSeconds) {
            A_Clipboard := old
            ; #region agent log
            AgentDebugLog("ZaloUI.ahk:_PasteAndSend", "clip set failed", Map(
                "msgLen", StrLen(message), "publishGroup", this.publishGroup
            ), "E")
            ; #endregion
            throw Error("Không đặt được nội dung vào clipboard.")
        }
        try {
            if refocus
                this._FocusComposeBox()
            this._PublishDebugSnapshot("paste_before_ctrla", "H1")
            Send "^a{Backspace}"
            Sleep 100
            this._PublishDebugSnapshot("paste_after_ctrla", "H1")
            Send "^v"
            Sleep this.config.PasteDelayMs + 150
            this._PublishDebugSnapshot("paste_after_ctrlv", "H3")
            this._RequireMainActive("gửi text")
            ; #region agent log
            AgentDebugLog("ZaloUI.ahk:_PasteAndSend", "paste sent", Map(
                "msgLen", StrLen(message),
                "refocus", refocus ? 1 : 0,
                "publishGroup", this.publishGroup,
                "preview", SubStr(RegExReplace(Trim(message), "\s+", " "), 1, 60)
            ), "E")
            ; #endregion
            if beforeSend
                beforeSend.Call()
            Send "{Enter}"
            Sleep this.config.SendDelayMs
        } finally {
            A_Clipboard := old
        }
    }
}
