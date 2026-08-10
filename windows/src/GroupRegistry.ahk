#Requires AutoHotkey v2.0
; GroupRegistry.ahk — Repository: groups discovered from Zalo PC at runtime

class GroupRegistry {
    __New(config) {
        this.config := config
        this.discoveredNames := []
    }

    SetDiscovered(names) {
        this.discoveredNames := []
        seen := Map()
        for name in names {
            clean := Trim(name)
            key := GroupRegistry._Key(clean)
            if clean = "" || seen.Has(key)
                continue
            seen[key] := true
            this.discoveredNames.Push(clean)
        }
        return this.discoveredNames.Length
    }

    SourceGroups() {
        result := []
        outputs := this._OutputLookup()
        for name in this.discoveredNames {
            if outputs.Has(GroupRegistry._Key(name))
                continue
            result.Push(Map(
                "group_name", name,
                "type", "source",
                "note", "Discovered from Zalo PC"
            ))
        }
        return result
    }

    MainGroups() {
        result := []
        for name in this.config.OutputGroupNames {
            result.Push(Map(
                "group_name", name,
                "type", "main",
                "note", "Configured output group"
            ))
        }
        return result
    }

    _OutputLookup() {
        result := Map()
        for name in this.config.OutputGroupNames
            result[GroupRegistry._Key(name)] := true
        return result
    }

    ; Parse text copied from Zalo's Alt+3 "Danh sách nhóm" screen.
    static ParseCapturedNames(text, ignoredLabels := 0) {
        ignored := Map()
        defaults := [
            "danh sách nhóm", "danh sách cộng đồng", "nhóm", "cộng đồng",
            "tất cả", "tìm kiếm", "tìm kiếm nhóm", "tìm kiếm cộng đồng",
            "nhóm đang tham gia", "nhóm của tôi", "cộng đồng đang tham gia",
            "cộng đồng của tôi", "tạo nhóm", "tạo cộng đồng", "phân loại",
            "tin nhắn", "danh bạ", "community", "communities"
        ]
        for label in defaults
            ignored[GroupRegistry._Key(label)] := true
        if ignoredLabels {
            for label in ignoredLabels
                ignored[GroupRegistry._Key(label)] := true
        }

        names := []
        seen := Map()
        for rawLine in StrSplit(NormalizeNewlines(text), "`n") {
            line := Trim(RegExReplace(rawLine, "\s+", " "))
            line := Trim(RegExReplace(
                line, "i)\s+\d+\s*(?:thành viên|members?)$", ""))
            line := Trim(RegExReplace(
                line, "i)\s*·\s*\d+\s*(?:online|trực tuyến).*$", ""))
            if line = ""
                continue
            lower := GroupRegistry._Key(line)
            if ignored.Has(lower)
                continue
            if RegExMatch(line, "i)^\d+\s*(?:thành viên|members?)$")
                continue
            if RegExMatch(line, "i)^(?:\d+\s*)?nhóm(?:\s*\(\d+\))?$")
                continue
            if RegExMatch(line, "i)^(?:\d+\s*)?cộng đồng(?:\s*\(\d+\))?$")
                continue
            if RegExMatch(line,
                "i)^(?:nhóm đang tham gia|nhóm của tôi|cộng đồng đang tham gia|cộng đồng của tôi|tất cả)(?:\s*\(\d+\))?$")
                continue
            if RegExMatch(line,
                "i)^(?:\d+\s*)?(?:tin nhắn mới|tin chưa đọc|chưa đọc|unread|new messages?)$")
                continue
            if RegExMatch(line, "i)^(?:online|offline|\d+\s*(?:phút|giờ|ngày).*)$")
                continue
            if seen.Has(lower)
                continue
            seen[lower] := true
            names.Push(line)
        }
        return names
    }

    ; One group/community name per line — fallback when Zalo copy returns empty.
    static LoadManualNames(path) {
        if !FileExist(path)
            return []
        names := []
        seen := Map()
        for rawLine in StrSplit(ReadTextFile(path), "`n", "`r") {
            line := Trim(rawLine)
            if line = "" || SubStr(line, 1, 1) = "#" || SubStr(line, 1, 2) = ";"
                continue
            key := GroupRegistry._Key(line)
            if seen.Has(key)
                continue
            seen[key] := true
            names.Push(line)
        }
        return names
    }

    static _Key(name) {
        key := StrLower(Trim(name))
        key := StrReplace(key, Chr(0xFE0F), "")
        return RegExReplace(key, "\s+", " ")
    }
}
