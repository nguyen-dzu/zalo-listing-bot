#Requires AutoHotkey v2.0
; JSON.ahk — minimal JSON encode/decode for AHK v2 (Map <-> object, Array <-> array)

class JSON {
    static Stringify(value, indentStr := "  ") {
        return JSON._Encode(value, 0, indentStr)
    }

    static Parse(text) {
        if SubStr(text, 1, 1) = Chr(0xFEFF)
            text := SubStr(text, 2)
        pos := 1
        value := JSON._ParseValue(text, &pos)
        return value
    }

    ; ── encode ───────────────────────────────────────────
    static _Encode(value, level, ind) {
        if value is Map
            return JSON._EncodeMap(value, level, ind)
        if value is Array
            return JSON._EncodeArray(value, level, ind)
        if value is Integer || value is Float
            return String(value)
        if value is String
            return JSON._EncodeString(value)
        return "null"
    }

    static _EncodeMap(value, level, ind) {
        if !value.Count
            return "{}"
        pad := JSON._Indent(ind, level + 1)
        parts := []
        for key, item in value
            parts.Push(pad JSON._EncodeString(String(key)) ": " JSON._Encode(item, level + 1, ind))
        return "{`n" StrJoin(parts, ",`n") "`n" JSON._Indent(ind, level) "}"
    }

    static _EncodeArray(value, level, ind) {
        if !value.Length
            return "[]"
        pad := JSON._Indent(ind, level + 1)
        parts := []
        for item in value
            parts.Push(pad JSON._Encode(item, level + 1, ind))
        return "[`n" StrJoin(parts, ",`n") "`n" JSON._Indent(ind, level) "]"
    }

    static _Indent(ind, level) {
        out := ""
        Loop level
            out .= ind
        return out
    }

    static _EncodeString(text) {
        text := StrReplace(text, "\", "\\")
        text := StrReplace(text, '"', '\"')
        text := StrReplace(text, "`r", "\r")
        text := StrReplace(text, "`n", "\n")
        text := StrReplace(text, "`t", "\t")
        return '"' text '"'
    }

    ; ── decode ───────────────────────────────────────────
    static _SkipWs(text, &pos) {
        while pos <= StrLen(text) {
            c := SubStr(text, pos, 1)
            if c = " " || c = "`t" || c = "`n" || c = "`r"
                pos++
            else
                break
        }
    }

    static _ParseValue(text, &pos) {
        JSON._SkipWs(text, &pos)
        c := SubStr(text, pos, 1)
        if c = "{"
            return JSON._ParseObject(text, &pos)
        if c = "["
            return JSON._ParseArray(text, &pos)
        if c = '"'
            return JSON._ParseString(text, &pos)
        if SubStr(text, pos, 4) = "true" {
            pos += 4
            return 1
        }
        if SubStr(text, pos, 5) = "false" {
            pos += 5
            return 0
        }
        if SubStr(text, pos, 4) = "null" {
            pos += 4
            return ""
        }
        return JSON._ParseNumber(text, &pos)
    }

    static _ParseObject(text, &pos) {
        result := Map()
        pos++
        JSON._SkipWs(text, &pos)
        if SubStr(text, pos, 1) = "}" {
            pos++
            return result
        }
        loop {
            JSON._SkipWs(text, &pos)
            key := JSON._ParseString(text, &pos)
            JSON._SkipWs(text, &pos)
            pos++ ; consume ':'
            result[key] := JSON._ParseValue(text, &pos)
            JSON._SkipWs(text, &pos)
            c := SubStr(text, pos, 1)
            pos++
            if c = "}"
                break
            if c != ","
                break
        }
        return result
    }

    static _ParseArray(text, &pos) {
        result := []
        pos++
        JSON._SkipWs(text, &pos)
        if SubStr(text, pos, 1) = "]" {
            pos++
            return result
        }
        loop {
            result.Push(JSON._ParseValue(text, &pos))
            JSON._SkipWs(text, &pos)
            c := SubStr(text, pos, 1)
            pos++
            if c = "]"
                break
            if c != ","
                break
        }
        return result
    }

    static _ParseString(text, &pos) {
        pos++ ; opening quote
        out := ""
        while pos <= StrLen(text) {
            c := SubStr(text, pos, 1)
            if c = '"' {
                pos++
                return out
            }
            if c = "\" {
                esc := SubStr(text, pos + 1, 1)
                pos += 2
                switch esc {
                    case "n": out .= "`n"
                    case "r": out .= "`r"
                    case "t": out .= "`t"
                    case "b": out .= "`b"
                    case "f": out .= "`f"
                    case "u":
                        out .= Chr("0x" SubStr(text, pos, 4))
                        pos += 4
                    default: out .= esc
                }
                continue
            }
            out .= c
            pos++
        }
        return out
    }

    static _ParseNumber(text, &pos) {
        start := pos
        while pos <= StrLen(text) {
            c := SubStr(text, pos, 1)
            if InStr("+-0123456789.eE", c)
                pos++
            else
                break
        }
        raw := SubStr(text, start, pos - start)
        return InStr(raw, ".") || InStr(raw, "e") || InStr(raw, "E") ? Float(raw) : Integer(raw)
    }
}
