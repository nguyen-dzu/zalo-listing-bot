#Requires AutoHotkey v2.0
; OutputRouter.ahk — chọn một nhóm output theo quận/giá

#Include Util.ahk

class ListingOutputRouter {
    static PRICE_UNDER59_VND := 5900000
    static PRICE_OVER6_VND := 6000000

    static ParsePriceVnd(priceText) {
        raw := Trim(priceText)
        if raw = ""
            return ""

        normalized := StrLower(RegExReplace(raw, "\s+", " "))
        normalized := RegExReplace(normalized, "đ|\$|vnđ|vnd", "")

        if RegExMatch(normalized, "i)^(\d{1,3}(?:[.,]\d{3})+|\d+)$", &found) {
            digits := RegExReplace(found[1], "[.,]", "")
            return Integer(digits)
        }

        if RegExMatch(normalized, "i)^(\d+)\s*tr\s*(\d)$", &found)
            return Integer(found[1]) * 1000000 + Integer(found[2]) * 100000

        if RegExMatch(normalized, "i)^(\d+)\s*tr\b", &found)
            return Integer(found[1]) * 1000000

        if RegExMatch(normalized, "i)^(\d+)[.,](\d+)\s*(?:tr|triệu|trieu)\b", &found) {
            whole := Integer(found[1])
            fracDigits := found[2]
            divisor := 1
            Loop StrLen(fracDigits)
                divisor *= 10
            return whole * 1000000 + Integer(fracDigits) * (1000000 // divisor)
        }

        if RegExMatch(normalized, "i)^(\d+)\s*(?:tr|triệu|trieu)\b", &found)
            return Integer(found[1]) * 1000000

        if RegExMatch(normalized, "i)^(\d+)\s*(?:k| củ|cu)\b", &found)
            return Integer(found[1]) * 1000

        return ""
    }

    static ExtractPriceVnd(record) {
        priceText := record.Has("price") ? Trim(record["price"]) : ""
        if priceText != "" {
            parsed := ListingOutputRouter.ParsePriceVnd(priceText)
            if parsed != ""
                return parsed
        }

        raw := record.Has("raw_text") ? record["raw_text"] : ""
        if raw = ""
            return ""

        if RegExMatch(raw, "i)(?:giá\s*(?:thuê|phòng)?\s*[:\-–]?\s*)?(\d+\s*tr\s*\d|\d+tr\d)", &found)
            return ListingOutputRouter.ParsePriceVnd(found[1])
        if RegExMatch(raw, "i)(?:giá\s*(?:thuê|phòng)?\s*[:\-–]?\s*)?(\d+[\.,]?\d*\s*(?:tr|triệu|trieu))", &found)
            return ListingOutputRouter.ParsePriceVnd(found[1])
        if RegExMatch(raw, "i)(?:giá\s*(?:thuê|phòng)?\s*[:\-–]?\s*)?(\d+\s*tr\b)", &found)
            return ListingOutputRouter.ParsePriceVnd(found[1])

        return ""
    }

    static ClassifyDistrict(haystack) {
        text := StrLower(NormalizeNewlines(haystack))
        if text = ""
            return "none"

        folded := ListingOutputRouter._FoldVietnamese(text)

        if RegExMatch(folded, "i)(?:\bbinh\s*thanh\b|\bphu\s*nhuan\b)")
            return "quan_so"

        if RegExMatch(text, "i)(?:quận|q\.?)\s*\d+")
            return "quan_so"
        if RegExMatch(text, "i)\bq\d+\b")
            return "quan_so"

        if RegExMatch(text, "i)(?:quận|q\.?)\s*[a-zà-ỹ]")
            return "ngoai_thanh"

        return "none"
    }

    static ResolveOutputGroup(record, config) {
        haystack := (record.Has("address") ? record["address"] : "")
            . "`n" (record.Has("raw_text") ? record["raw_text"] : "")

        district := ListingOutputRouter.ClassifyDistrict(haystack)
        if district = "quan_so"
            return Map(
                "group", config.OutputRouteGroupQuanSo,
                "reason", "quan_so")
        if district = "ngoai_thanh"
            return Map(
                "group", config.OutputRouteGroupNgoaiThanh,
                "reason", "ngoai_thanh")

        priceVnd := ListingOutputRouter.ExtractPriceVnd(record)
        if priceVnd != "" {
            if priceVnd <= ListingOutputRouter.PRICE_UNDER59_VND
                return Map(
                    "group", config.OutputRouteGroupUnder59,
                    "reason", "price_under59")
            if priceVnd >= ListingOutputRouter.PRICE_OVER6_VND
                return Map(
                    "group", config.OutputRouteGroupOver6,
                    "reason", "price_over6")
        }

        fallback := ListingOutputRouter.FallbackSingleOutput(config)
        if fallback != ""
            return Map("group", fallback, "reason", "fallback_single_output")
        return Map("group", "", "reason", "no_match")
    }

    static FallbackSingleOutput(config) {
        if !config.HasProp("OutputGroupNames") || !config.OutputGroupNames.Length
            return ""
        if config.OutputGroupNames.Length != 1
            return ""
        name := Trim(config.OutputGroupNames[1])
        return name
    }

    static _FoldVietnamese(text) {
        result := StrLower(text)
        replacements := [
            ["à","a"],["á","a"],["ả","a"],["ã","a"],["ạ","a"],
            ["ă","a"],["ằ","a"],["ắ","a"],["ẳ","a"],["ẵ","a"],["ặ","a"],
            ["â","a"],["ầ","a"],["ấ","a"],["ẩ","a"],["ẫ","a"],["ậ","a"],
            ["è","e"],["é","e"],["ẻ","e"],["ẽ","e"],["ẹ","e"],
            ["ê","e"],["ề","e"],["ế","e"],["ể","e"],["ễ","e"],["ệ","e"],
            ["ì","i"],["í","i"],["ỉ","i"],["ĩ","i"],["ị","i"],
            ["ò","o"],["ó","o"],["ỏ","o"],["õ","o"],["ọ","o"],
            ["ô","o"],["ồ","o"],["ố","o"],["ổ","o"],["ỗ","o"],["ộ","o"],
            ["ơ","o"],["ờ","o"],["ớ","o"],["ở","o"],["ỡ","o"],["ợ","o"],
            ["ù","u"],["ú","u"],["ủ","u"],["ũ","u"],["ụ","u"],
            ["ư","u"],["ừ","u"],["ứ","u"],["ử","u"],["ữ","u"],["ự","u"],
            ["ỳ","y"],["ý","y"],["ỷ","y"],["ỹ","y"],["ỵ","y"],
            ["đ","d"]
        ]
        for pair in replacements
            result := StrReplace(result, pair[1], pair[2])
        return result
    }
}
