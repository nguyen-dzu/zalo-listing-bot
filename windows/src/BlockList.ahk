#Requires AutoHotkey v2.0
; BlockList.ahk — Specification: reject harvested messages containing banned keywords

class BlockList {
    __New(config) {
        this.config := config
        this.rules := []
        this.Reload()
    }

    Reload() {
        try {
            rows := TableLoader.Load(
                this.config.BlocklistXlsx,
                this.config.BlocklistSheet,
                this.config.BlocklistCsv
            )
        } catch as err {
            LogStartupError("BlockList: " err.Message)
            rows := []
        }

        this.rules := []
        for row in rows {
            keyword := row.Has("keyword") ? Trim(row["keyword"]) : ""
            if keyword = ""
                continue
            enabled := row.Has("enabled") ? StrLower(Trim(row["enabled"])) : ""
            if !(enabled = "" || enabled = "1" || enabled = "true" || enabled = "yes" || enabled = "x")
                continue
            matchType := row.Has("match_type") ? StrLower(Trim(row["match_type"])) : "contains"
            this.rules.Push(Map(
                "keyword", keyword,
                "match_type", matchType = "" ? "contains" : matchType
            ))
        }
        return this.rules.Length
    }

    ; Returns the matched keyword, or "" when the message is allowed.
    Match(text) {
        haystack := Trim(NormalizeNewlines(text))
        for rule in this.rules {
            keyword := rule["keyword"]
            switch rule["match_type"] {
                case "exact":
                    if StrLower(haystack) = StrLower(keyword)
                        return keyword
                case "regex":
                    if RegExMatch(haystack, keyword)
                        return keyword
                case "word":
                    if RegExMatch(haystack, "i)(?<![\p{L}\d])" RegExEscape(keyword) "(?![\p{L}\d])")
                        return keyword
                default:
                    if InStr(StrLower(haystack), StrLower(keyword))
                        return keyword
            }
        }
        return ""
    }

    IsBlocked(text) {
        return this.Match(text) != ""
    }
}

RegExEscape(text) {
    return RegExReplace(text, "([\\\.\*\?\+\[\]\(\)\{\}\|\^\$])", "\$1")
}
