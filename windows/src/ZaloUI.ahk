#Requires AutoHotkey v2.0
#Include Acc.ahk
#Include GroupRegistry.ahk
#Include GroupActivity.ahk
; ZaloUI.ahk — Adapter: every Zalo PC keystroke lives here. Calibrate delays in config.ini.

class ZaloUIAdapter {
    __New(config) {
        this.config := config
        this.publishGroup := ""
        EnablePerMonitorDpiAwareness()
        CoordMode("Mouse", "Screen")
    }

    ; options: "" | WhichButton ("Left","Right",...) | "D"/"U" (mouse down/up for drag)
    _ScreenClick(x, y, options := "") {
        CoordMode("Mouse", "Screen")
        if options = "D" || options = "U"
            Click(x, y, , , options)
        else if options != ""
            Click(x, y, options)
        else
            Click(x, y)
    }

    _ElementClick(element) {
        try {
            element.Click()
            return true
        } catch {
            try {
                loc := element.Location
                this._ScreenClick(
                    loc.x + Round(loc.w / 2),
                    loc.y + Round(loc.h / 2))
                return true
            } catch {
                return false
            }
        }
    }

    _WindowRect() {
        WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
        return Map("x", x, "y", y, "w", w, "h", h)
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
        opened := this.config.PreferAccessibleConversationClick
            && this._ClickAccessibleConversation(groupName)
        if !opened {
            Send "{Esc}"
            Sleep 150
            Send "^f"
            Sleep this.config.SearchDelayMs
            ; Clipboard paste preserves Vietnamese/emoji group names more
            ; reliably than simulated Unicode keyboard input in Zalo Electron.
            this._ReplaceFocusedText(groupName)
            Sleep this.config.SearchDelayMs + 300
            Send "{Enter}"
            Sleep this.config.OpenChatDelayMs
        }
        if this.config.VerifyActiveConversation
            && !this._ActiveConversationMatches(groupName)
            throw Error("Zalo opened a different conversation than: " groupName)
        Send "{Esc}"
        Sleep 150
        if focus = "send"
            this._FocusComposeBox()
        else
            this._ClickMessagePane()
        return true
    }

    _ClickAccessibleConversation(groupName) {
        Send "{Esc}"
        Sleep 100
        Send "!1"
        Sleep this.config.GroupListSettleMs
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

    _ActiveConversationMatches(groupName) {
        root := this._AccessibleRoot()
        if !root
            return true
        WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
        minX := x + Round(w * 0.32)
        maxY := y + Round(h * 0.20)
        targetKey := GroupRegistry._Key(groupName)
        inspected := 0
        try elements := root.FindElements([
            {Role: Acc.Role.StaticText},
            {Role: Acc.Role.Text}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return true
        for element in elements {
            try location := element.Location
            catch
                continue
            if location.x < minX || location.y < y || location.y > maxY
                continue
            name := ""
            try name := element.Name
            if name = ""
                continue
            inspected++
            nameKey := GroupRegistry._Key(name)
            if nameKey = targetKey || InStr(nameKey, targetKey)
                return true
        }
        ; If Zalo exposes no header text, keep compatibility. If it does expose
        ; a header but the target is absent, stop before reading/sending wrong chat.
        return inspected = 0
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
            ; Use a deterministic point inside the conversation bubbles. MSAA
            ; Pane/Document may resolve to the compose box or left search pane.
            this._ClickConversationTextArea()
            Send "^a"
            Sleep this.config.PasteDelayMs
        }

        old := ClipboardAll()
        A_Clipboard := ""
        Send "^c"
        captured := ClipWait(this.config.ClipWaitSeconds) ? A_Clipboard : ""
        Send "{Esc}"
        A_Clipboard := old
        return captured
    }

    _ClickConversationTextArea() {
        win := this._WindowRect()
        this._ScreenClick(
            win["x"] + Round(win["w"] * 0.68),
            win["y"] + Round(win["h"] * 0.48))
        Sleep this.config.PasteDelayMs
    }

    _CaptureAccessibleConversationText() {
        root := this._AccessibleRoot()
        if !root
            return ""
        WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
        minX := x + Round(w * 0.36)
        maxX := x + Round(w * 0.96)
        minY := y + Round(h * 0.12)
        maxY := y + Round(h * 0.87)
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
        paneX := win["x"] + Round(win["w"] * this.config.GroupListPaneClickXRatio)
        paneY := win["y"] + Round(win["h"] * this.config.GroupListPaneClickYRatio)
        this._ScreenClick(paneX, paneY)
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
        WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
        maxX := x + Round(w * this.config.GroupAccessibilityLeftRatio)
        result := []
        seen := Map()
        try elements := root.FindElements([
            {Role: Acc.Role.ListItem},
            {Role: Acc.Role.OutlineItem}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return ""
        this._AppendAccessiblePaneElements(
            elements, result, seen, includeState, x, y, w, h, maxX)
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
            elements, result, seen, includeState, x, y, w, h, maxX)
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
        WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
        maxX := x + Round(w * this.config.GroupAccessibilityLeftRatio)
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
                || location.x < x || location.x >= maxX
                || location.y < y || location.y >= y + h
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
        hwnd := WinExist("ahk_exe " this.config.ExeName)
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

    ; Find actual message-pane graphics nearest the listing anchor. Group
    ; avatars are excluded by pane and size/distance constraints.
    FindImageBubblesNearMessage(anchor, maxImages := 6) {
        if Trim(anchor) = ""
            return []
        this.FindMessageInConversation(anchor)
        Sleep this.config.ImageViewerSettleMs
        root := this._AccessibleRoot()
        if !root
            return []

        WinGetPos &x, &y, &w, &h, "ahk_exe " this.config.ExeName
        paneMinX := x + Round(w * 0.36)
        paneMaxX := x + Round(w * 0.94)
        contentMinY := y + Round(h * 0.12)
        contentMaxY := y + Round(h * 0.86)
        anchorY := y + Round(h * 0.55)

        try textElements := root.FindElements([
            {Role: Acc.Role.StaticText},
            {Role: Acc.Role.Text}
        ], Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            textElements := []
        for element in textElements {
            matched := false
            for value in this._AccessibleElementStrings(element) {
                if InStr(value, anchor) {
                    matched := true
                    break
                }
            }
            if !matched
                continue
            try location := element.Location
            catch
                continue
            if location.x >= paneMinX && location.x <= paneMaxX {
                anchorY := location.y
                break
            }
        }

        candidates := []
        try graphics := root.FindElements(
            {Role: Acc.Role.Graphic},
            Acc.TreeScope.Descendants, 0, this.config.GroupAccessibilityDepth)
        catch
            return []
        for graphic in graphics {
            try location := graphic.Location
            catch
                continue
            centerY := location.y + Round(location.h / 2)
            distance := Abs(centerY - anchorY)
            if this.config.ImageCandidateDirection = "above"
                && centerY > anchorY
                continue
            if this.config.ImageCandidateDirection = "below"
                && centerY < anchorY
                continue
            if location.x < paneMinX || location.x > paneMaxX
                || location.y < contentMinY || location.y > contentMaxY
                || location.w < this.config.ImageCandidateMinWidthPx
                || location.h < this.config.ImageCandidateMinHeightPx
                || distance > this.config.ImageCandidateMaxDistancePx
                continue
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

        this._SortLocationsByDistance(candidates)
        while candidates.Length > maxImages
            candidates.Pop()
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

    ; Zalo Electron often ignores Ctrl+C for chat images. Prefer context-menu
    ; "Copy hình ảnh", then viewer hotkey, then screen BitBlt of the Acc bounds.
    CopyImageAt(location) {
        this.Activate()
        if this._CopyImageViaContextMenu(location["x"], location["y"])
            return true

        A_Clipboard := ""
        this._ScreenClick(location["x"], location["y"])
        Sleep this.config.ImageViewerSettleMs
        Send this.config.ImageCopyHotkey
        Sleep this.config.PasteDelayMs + 200
        if this._WaitForClipboardImage() {
            Send "{Esc}"
            return true
        }
        Send "{Esc}"
        Sleep 150

        if location.Has("left") && location.Has("top")
            && location.Has("w") && location.Has("h")
            && location["w"] > 0 && location["h"] > 0 {
            if this._CopyScreenRegionToClipboard(
                location["left"], location["top"], location["w"], location["h"])
                return true
        }
        return false
    }

    _CopyImageViaContextMenu(x, y) {
        for key in this._ImageContextCopyKeys() {
            A_Clipboard := ""
            this._ScreenClick(x, y, "Right")
            Sleep this.config.PasteDelayMs + 250
            Send key
            Sleep this.config.PasteDelayMs + 250
            if this._WaitForClipboardImage()
                return true
            Send "{Esc}"
            Sleep 120
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
    ; puts CF_DIB/PNG and would always time out.
    _WaitForClipboardImage() {
        ClipWait(this.config.ClipWaitSeconds, 1)
        return this._ClipboardHasBitmapImage()
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
        if this._FocusAccRegion(["Document", "Pane"], 0.36, 0.96, 0.12, 0.87)
            return
        if !this.config.UiUseRatioClicks
            return
        win := this._WindowRect()
        this._ScreenClick(
            win["x"] + Round(win["w"] * 0.65),
            win["y"] + Round(win["h"] * 0.45))
        Sleep this.config.PasteDelayMs
    }

    ; Zalo PC: after search/open chat, focus must be in the compose box before Ctrl+V.
    _FocusComposeBox() {
        this.Activate()
        if this._FocusAccRegion(["Text", "ComboBox", "Document"], 0.36, 0.96, 0.78, 0.98)
            return
        if !this.config.UiUseRatioClicks {
            Send "{Tab}"
            Sleep this.config.PasteDelayMs
            return
        }
        win := this._WindowRect()
        this._ScreenClick(
            win["x"] + Round(win["w"] * 0.65),
            win["y"] + win["h"] - 90)
        Sleep this.config.PasteDelayMs + 100
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
    ; Zalo: context-menu "Copy hình ảnh" first; Ctrl+C is usually text-only.
    CopyImageFromSelection() {
        this.Activate()
        old := ClipboardAll()

        for key in this._ImageContextCopyKeys() {
            A_Clipboard := ""
            Send "{AppsKey}"
            Sleep 280
            Send key
            Sleep this.config.PasteDelayMs + 200
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
        return this._ClipboardHasBitmapImage()
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
        this._ReplaceFocusedText(groupName)
        Sleep this.config.SearchDelayMs + 200
        Send "{Enter}"
        Sleep this.config.PasteDelayMs
        Send "{Enter}"
        Sleep this.config.SendDelayMs
        return true
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
