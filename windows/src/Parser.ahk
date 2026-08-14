#Requires AutoHotkey v2.0
; Parser.ahk — Strategy: turn raw Zalo text into structured listing objects

#Include Util.ahk

class ListingParser {
    ; Ordered: the first matching rule wins, so specific labels precede generic ones
    ; ("Giá điện" must be tested before "Giá").
    static RULES := [
        ["utility_price", "i)^\s*(?:⚡\s*)?(?:Điện\s*(?:và|&|/|,)\s*nước|Điện nước)\s*[:\-–]?\s*(.+)$"],
        ["electric_price", "i)^\s*(?:⚡|👉)?\s*(?:Giá điện|Tiền điện|Điện|Đ\.)\s*[:\-–]?\s*(.+)$"],
        ["water_price", "i)^\s*(?:💧|👉)?\s*(?:Giá nước|Tiền nước|Nước|Nc|N\.)\s*[:\-–]?\s*(.+)$"],
        ["service_price", "i)^\s*(?:🧾|👉)?\s*(?:Giá dịch vụ|Phí dịch vụ|Phí quản lý|Dịch vụ|Dv|PDV|Phí DV)\s*[:\-–]?\s*(.+)$"],
        ["address", "i)^\s*(?:📍\s*)?(?:Địa chỉ|Địa điểm|Đ/c|ĐC)\s*[:\-–]\s*(.+)$"],
        ["address", "i)^\s*📍\s*(\d[\d\/\.\-\w\s,]+(?:Q\.?\s*\d+|q\.?\s*\d+|quận\s*\d+|phường\s+\w+).*)$"],
        ["room_code", "i)^\s*(?:🔑\s*)?(?:Mã phòng|Số phòng|Phòng số|Mã)\s*[:\-–]\s*(.+)$"],
        ["price", "i)^\s*(?:💰|🚥|👉)?\s*(?:Giá thuê|Giá phòng|Giá)\s*[:\-–]?\s*(.+)$"],
        ["owner_phone", "i)^\s*(?:📞|☎️?|☎)\s*(.+)$"],
        ["owner_phone", "i)^\s*(?:Số điện thoại|Số chủ|SĐT|SDT|Hotline|Liên hệ|LH)\s*[:\-–]\s*(.+)$"],
        ["info", "i)^\s*(?:ℹ️\s*)?(?:Thông tin|Mô tả|Ghi chú|Nội thất|Tiện ích)\s*[:\-–]\s*(.+)$"]
    ]

    static FIELD_KEYS := [
        "address", "room_code", "price", "electric_price", "water_price",
        "utility_price", "service_price", "owner_phone", "info"
    ]

    static DEFAULT_START_PATTERN := "i)^\s*(?:📍\s*)?(?:Địa chỉ|Địa điểm|Đ/c|ĐC)\s*[:\-–]"
    ; Freeform posts often start with rental keywords instead of "Địa chỉ:"
    static RENTAL_START_PATTERN := "i)^\s*(?:🏠\s*|📍\s*|🚩\s*|👉\s*|👇\s*|💎\s*|🚥\s*)?(?:Cho thuê|Cần cho thuê|Sang CHDV|CHDV|Phòng trọ|Căn hộ|Nhà nguyên căn|Studio|Phòng|Giữa tháng|Giá|Hình ảnh.*trống|trống\s+mã)\b"
    static MAP_LINK_PATTERN := "i)(?:maps\.(?:app\.)?goo\.gl|google\.com/maps|goo\.gl/maps)"
    ; VN mobile: 0… or +84/84… with optional spaces/dots/dashes between digits.
    static PHONE_FRAGMENT_PATTERN := "(?:\+?84|0)(?:[\s.\-]*\d){9}"
    static DEFAULT_IMAGE_MARKER := "i)(?:\[(?:Hình ảnh|Ảnh|Image|Photo)\]|👇\s*Hình\s*ảnh|📷|🖼️|(?:^|\s)Hình ảnh(?:\s|$))"
    static DEFAULT_MIN_LISTING_SCORE := 3
    static NON_RENTAL_PATTERN := "i)\b(?:vay\s*(?:vốn|tiền|tín\s*chấp|thế\s*chấp)|tín\s*dụng|giải\s*ngân|đáo\s*hạn|mở\s*thẻ|lãi\s*suất\s*\d|bảo\s*hiểm|chứng\s*khoán)\b"
    ; "Minh Anh 18:05" — Zalo prints a sender/time header above each message
    static DEFAULT_NOISE_PATTERN := "i)^\S.{0,60}\s\d{1,2}:\d{2}(?:\s*(?:AM|PM|SA|CH))?$"

    static NewListing() {
        listing := Map()
        for key in ListingParser.FIELD_KEYS
            listing[key] := ""
        listing["extra_info"] := ""
        listing["raw_text"] := ""
        listing["image_count"] := 0
        listing["phone_carrier"] := ""
        return listing
    }

    ; Split a bulk conversation capture into one block per listing.
    ; Tries: labeled anchors → rental-keyword anchors → Zalo sender/time headers.
    static SplitBlocks(text, startPattern := "", imageMarker := "") {
        marker := imageMarker != "" ? imageMarker : ListingParser.DEFAULT_IMAGE_MARKER
        lines := StrSplit(NormalizeNewlines(text), "`n")
        patterns := []

        if startPattern != ""
            patterns.Push(startPattern)
        else {
            patterns.Push(ListingParser.DEFAULT_START_PATTERN)
            patterns.Push(ListingParser.RENTAL_START_PATTERN)
        }

        blocks := []
        for pattern in patterns {
            blocks := ListingParser._SplitByAnchors(lines, pattern, marker)
            if blocks.Length
                break
        }
        if !blocks.Length
            blocks := ListingParser._SplitBySenderHeaders(lines)

        return ListingParser._FilterListingBlocks(blocks)
    }

    static _SplitByAnchors(lines, pattern, marker) {
        anchors := []
        for index, line in lines {
            if RegExMatch(line, pattern)
                anchors.Push(index)
        }
        if !anchors.Length
            return []

        starts := []
        for index, anchor in anchors {
            floor := index > 1 ? anchors[index - 1] : 0
            cursor := anchor
            while cursor - 1 > floor {
                previous := Trim(lines[cursor - 1])
                if previous = "" || RegExMatch(previous, marker)
                    cursor--
                else
                    break
            }
            starts.Push(cursor)
        }

        blocks := []
        for index, start in starts {
            stop := index < starts.Length ? starts[index + 1] - 1 : lines.Length
            piece := []
            current := start
            while current <= stop {
                piece.Push(lines[current])
                current++
            }
            block := Trim(StrJoin(ListingParser.TrimNoiseLines(piece), "`n"))
            if block != ""
                blocks.Push(block)
        }
        return blocks
    }

    static _SplitBySenderHeaders(lines) {
        blocks := []
        current := []

        for line in lines {
            if ListingParser._IsNoise(line) {
                if current.Length {
                    block := Trim(StrJoin(ListingParser.TrimNoiseLines(current), "`n"))
                    if block != ""
                        blocks.Push(block)
                    current := []
                }
                continue
            }
            current.Push(line)
        }

        if current.Length {
            block := Trim(StrJoin(ListingParser.TrimNoiseLines(current), "`n"))
            if block != ""
                blocks.Push(block)
        }
        return blocks
    }

    static _FilterListingBlocks(blocks) {
        result := []
        for block in blocks {
            if ListingParser.LooksLikeListing(block)
                result.Push(block)
        }
        return result
    }

    ; Heuristic: tin có tín hiệu cho thuê (cho thuê, giá, phòng, địa chỉ, …).
    static LooksLikeListing(text, minScore := 0) {
        haystack := StrLower(NormalizeNewlines(text))
        trimmed := Trim(haystack)
        if StrLen(trimmed) < 12
            return false
        if RegExMatch(trimmed, ListingParser.NON_RENTAL_PATTERN)
            return false

        if minScore <= 0
            minScore := ListingParser.DEFAULT_MIN_LISTING_SCORE

        score := 0
        for signal in ListingParser._RENTAL_SIGNALS {
            if InStr(haystack, signal[1])
                score += signal[2]
        }
        for signal in ListingParser._INTENT_REGEX_SIGNALS {
            if RegExMatch(haystack, signal[1])
                score += signal[2]
        }
        if RegExMatch(haystack, "i)\d+tr\d|\d+\s*tr\s*\d")
            score += 2
        else if RegExMatch(haystack, "i)\d+[\.,]?\d*\s*(?:tr|triệu|k| củ)(?:\s*/\s*th(?:áng|ang)?)?")
            score += 2
        if RegExMatch(text, ListingParser.MAP_LINK_PATTERN)
            score += 3
        if RegExMatch(haystack, ListingParser.PHONE_FRAGMENT_PATTERN)
            score += 2
        if RegExMatch(haystack, "i)\d{2,4}/\d{1,4}/\d{1,4}")
            score += 2
        if RegExMatch(haystack, "i)(?:q\.?\s*\d+|quận\s*\d+|p\.?\s*\d+|phường\s+\w+)")
            score += 1
        if RegExMatch(haystack, "i)(?:đường|phố|ngõ|hẻm|hem)\s")
            score += 1

        return score >= minScore
    }

    static _RENTAL_SIGNALS := [
        ["cho thuê", 3], ["cho thue", 3], ["cần cho thuê", 3], ["thuê phòng", 3],
        ["sang chdv", 3], ["phòng trọ", 2], ["phong tro", 2], ["căn hộ", 2], ["can ho", 2],
        ["nhà nguyên căn", 2], ["chdv", 2], ["studio", 2], ["duplex", 2], ["phòng", 1],
        [" trống", 2], ["trống mã", 3], ["phòng mới", 2], ["còn phòng", 2],
        ["phòng trống", 3], ["trống lại", 3], ["available", 3],
        ["nhận khách", 2], ["dọn vào", 2],
        ["giá thuê", 2], ["giá", 1], ["gia ", 1], ["triệu", 2], ["tr/th", 2], ["/tháng", 1],
        ["địa chỉ", 2], ["dia chi", 2], ["quận", 1], ["phường", 1], ["đường", 1],
        ["điện", 1], ["nước", 1], ["dịch vụ", 1], ["pdv", 1], ["sđt", 1], ["liên hệ", 2],
        ["full nội thất", 1], ["m²", 1], ["m2", 1], ["gác", 1], ["ban công", 1],
        ["google.com", 2], ["maps.app", 2], ["goo.gl", 2]
    ]

    ; Config-independent whitelist/intent signals. Multiple dimensions increase
    ; confidence; blacklist still runs before parse/save in Harvester.
    static _INTENT_REGEX_SIGNALS := [
        ["i)(?:trống|còn|sẵn)\s+(?:phòng|studio|1pn|2pn|phòng trọ)", 4],
        ["i)(?:địa chỉ|dự án|đường|quận|phường|gần trường|gần đh)\s*:?", 2],
        ["i)(?:sđt|lh|mọi chi tiết|zalo|call)\s*:?\s*0[35789]\d{8}", 3],
        ["i)(?:giá|điện|nước|dịch vụ)\s*:?\s*\d+(?:[\.,]\d+)?(?:k|tr|triệu)?", 2]
    ]

    ; Drop blank and sender/time header lines from both ends of a block.
    static TrimNoiseLines(lines) {
        first := 1
        last := lines.Length
        while first <= last && ListingParser._IsNoise(lines[first])
            first++
        while last >= first && ListingParser._IsNoise(lines[last])
            last--

        result := []
        index := first
        while index <= last {
            result.Push(lines[index])
            index++
        }
        return result
    }

    static _IsNoise(line) {
        stripped := Trim(line)
        return stripped = "" || RegExMatch(stripped, ListingParser.DEFAULT_NOISE_PATTERN)
    }

    static Parse(text, imageMarker := "") {
        listing := ListingParser.NewListing()
        listing["raw_text"] := Trim(NormalizeNewlines(text))
        extras := []

        marker := imageMarker != "" ? imageMarker : ListingParser.DEFAULT_IMAGE_MARKER

        for line in StrSplit(listing["raw_text"], "`n") {
            line := Trim(line)
            if line = ""
                continue
            ; image markers are counted separately, never echoed into the text
            if Trim(RegExReplace(line, marker)) = ""
                continue

            parseLine := ListingParser._StripLinePrefix(line)
            if parseLine = ""
                continue

            matched := false
            for rule in ListingParser.RULES {
                if RegExMatch(parseLine, rule[2], &found) {
                    key := rule[1]
                    if listing[key] = ""
                        listing[key] := Trim(found[1])
                    matched := true
                    break
                }
            }
            if !matched
                extras.Push(line)
        }

        listing["extra_info"] := StrJoin(extras, " | ")
        listing["owner_phone"] := ListingParser.NormalizePhone(listing["owner_phone"])

        if listing["owner_phone"] = ""
            listing["owner_phone"] := ListingParser.ExtractPhone(listing["raw_text"])

        listing["phone_carrier"] := listing["owner_phone"] != ""
            ? ListingParser.ClassifyCarrier(listing["owner_phone"]) : ""

        listing["image_count"] := ListingParser.CountMatches(listing["raw_text"], marker)
        ListingParser._InferFields(listing)
        if listing["owner_phone"] = ""
            listing["owner_phone"] := ListingParser.ExtractPhone(listing["raw_text"])
        if listing["owner_phone"] != "" && listing["phone_carrier"] = ""
            listing["phone_carrier"] := ListingParser.ClassifyCarrier(listing["owner_phone"])
        listing["room_code"] := ListingParser.NormalizeRoomCode(listing, "")
        ListingParser._DedupExtraInfo(listing)

        return listing
    }

    ; Drop Khác lines that only repeat address/info/price already shown.
    static _DedupExtraInfo(listing) {
        extra := listing.Has("extra_info") ? Trim(listing["extra_info"]) : ""
        if extra = ""
            return
        info := listing.Has("info") ? Trim(listing["info"]) : ""
        if info != "" && (extra = info || InStr(extra, info) = 1)
            listing["extra_info"] := ""
        else if info != "" && InStr(info, extra)
            listing["extra_info"] := ""

        kept := []
        for part in StrSplit(listing["extra_info"], " | ") {
            piece := Trim(part)
            if piece = ""
                continue
            skip := false
            for key in ["address", "price", "room_code", "info", "electric_price",
                "water_price", "utility_price", "service_price", "owner_phone"] {
                value := listing.Has(key) ? Trim(listing[key]) : ""
                if value != "" && (piece = value || InStr(piece, value) || InStr(value, piece)) {
                    skip := true
                    break
                }
            }
            if !skip
                kept.Push(piece)
        }
        listing["extra_info"] := StrJoin(kept, " | ")
    }

    ; Reject price strings; prefer labeled codes; prefix P for numeric rooms (P102).
    static LooksLikePrice(value) {
        v := Trim(value)
        if v = ""
            return false
        return RegExMatch(v, "i)^\d+tr\d|\d+\s*tr\b|\d+[\.,]?\d*\s*(?:tr|triệu|k| củ)\b")
    }

    static NormalizeRoomCode(listing, fallbackHash := "") {
        raw := listing.Has("room_code") ? Trim(listing["room_code"]) : ""
        text := listing.Has("raw_text") ? listing["raw_text"] : ""

        if raw != "" && ListingParser.LooksLikePrice(raw)
            raw := ""

        if raw = "" && text != "" {
            if RegExMatch(text, "i)(?:🔑\s*)?(?:Mã phòng|Số phòng|Phòng số|Mã)\s*[:\-–]\s*(\S+)", &found)
                raw := Trim(found[1])
            else if RegExMatch(text, "i)(?:mã|ma)\s+(\d{2,4})\b", &found)
                raw := found[1]
            else if RegExMatch(text, "i)\bP(\d{2,4})\b", &found)
                raw := "P" found[1]
            else if RegExMatch(text, "i)(?:phòng|room)\s+(\d{2,4})\b", &found)
                raw := found[1]
            else if RegExMatch(text, "i)trống\s+mã\s+(\d{2,4})\b", &found)
                raw := found[1]
        }

        if raw != "" && ListingParser.LooksLikePrice(raw)
            raw := ""

        if raw = "" {
            if fallbackHash != ""
                return "R" SubStr(fallbackHash, 1, 6)
            return ""
        }

        raw := RegExReplace(raw, "^\s*(?:🔑|#)\s*", "")
        raw := Trim(raw)

        if RegExMatch(raw, "^\d{2,4}$")
            return "P" raw
        if RegExMatch(raw, "i)^p(\d{2,4})$", &found)
            return "P" found[1]
        if RegExMatch(raw, "i)^([A-Za-z]\d[\w.\-]{0,11})$", &found)
            return StrUpper(found[1])

        return StrUpper(raw)
    }

    static _StripLinePrefix(line) {
        stripped := Trim(line)
        stripped := RegExReplace(stripped, "i)^\s*(?:👉|•|[-–—*]\s*)+")
        stripped := RegExReplace(stripped, "i)^\s*(?:🌈|🌹+|🚩|💎|🚥|👇)+")
        return Trim(stripped)
    }

    ; Fill gaps when posts use freeform text instead of "Giá:" / "Địa chỉ:" labels.
    static _InferFields(listing) {
        text := listing["raw_text"]

        if listing["price"] = "" {
            if RegExMatch(text, "i)(?:giá\s*)?(\d+\s*tr\s*\d|\d+tr\d)", &found)
                listing["price"] := Trim(found[1])
            else if RegExMatch(text, "i)(\d+[\.,]?\d*)\s*(tr|triệu|k| củ)(?:\s*/\s*th(?:áng|ang)?)?", &found)
                listing["price"] := Trim(found[0])
            else if RegExMatch(text, "i)giá\s*[:\-–]?\s*([^\n\r]{2,40})", &found)
                listing["price"] := Trim(found[1])
        }

        if listing["room_code"] = "" {
            if RegExMatch(text, "i)(?:mã|ma)\s+(\d{2,4})", &found)
                listing["room_code"] := found[1]
            else if RegExMatch(text, "i)\bP(\d{2,4})\b", &found)
                listing["room_code"] := "P" found[1]
            else if RegExMatch(text, "i)phòng\s+(\d{2,4})", &found)
                listing["room_code"] := found[1]
            else if RegExMatch(text, "i)(?:phòng|room|pn|p)\s*[:\-#]?\s*([A-Za-z0-9.\-]{2,12})", &found)
                listing["room_code"] := Trim(found[1])
        }

        if listing["address"] = "" {
            if RegExMatch(text, "i)(?:tại|tai)\s+(\d[^\n]{5,100})", &found) {
                addr := Trim(found[1])
                addr := RegExReplace(addr, "i)\s*(?:giá|sđt|lh|điện|nước|full|,?\s*có\s).*$")
                addr := Trim(addr, " .,;|-")
                if StrLen(addr) >= 6
                    listing["address"] := addr
            }
            if listing["address"] = "" && RegExMatch(text, "i)\(\s*([^)]{8,120})\)", &found) {
                candidate := Trim(found[1])
                if RegExMatch(candidate, "i)(?:\d|quang|đường|phố|q\.?\s*\d+|quận|phường)", &_)
                    listing["address"] := candidate
            }
            if listing["address"] = "" {
                best := ""
                bestScore := 0
                for line in StrSplit(text, "`n") {
                    line := Trim(ListingParser._StripLinePrefix(line))
                    if line = ""
                        continue
                    candidate := ""
                    score := 0
                    if RegExMatch(line, "i)^(?:📍\s*)?(?:địa chỉ|đ/c|đc)\s*[:\-–]\s*(.+)$", &found) {
                        candidate := Trim(found[1])
                        score := 3
                    } else if RegExMatch(line, "i)^📍\s*(\d[\d\/\.\-\w\s,]+(?:Q\.?\s*\d+|q\.?\s*\d+|quận\s*\d+|phường\s+\w+).*)$", &found) {
                        candidate := Trim(found[1])
                        score := 5
                    } else if RegExMatch(line, "i)(?:\d+[\/\-\w]*\s+)?(?:đường|phố|ngõ|hẻm|hem)\s+.+\s*(?:q\.?\s*\d+|quận\s*\d+)", &found) {
                        candidate := line
                        score := 4
                    } else if RegExMatch(line, "i).+\s+(?:q\.?\s*\d+|quận\s*\d+|phường\s+\w+)", &found) && StrLen(line) >= 10 {
                        candidate := line
                        score := 2
                    }
                    if candidate != "" && RegExMatch(candidate, "\d/\d")
                        score += 2
                    if score > bestScore {
                        bestScore := score
                        best := candidate
                    }
                }
                if best != ""
                    listing["address"] := best
            }
        }

        if listing["owner_phone"] = ""
            listing["owner_phone"] := ListingParser.ExtractPhone(text)
        if listing["owner_phone"] != ""
            listing["phone_carrier"] := ListingParser.ClassifyCarrier(
                listing["owner_phone"])

        if listing["info"] = "" {
            for line in StrSplit(text, "`n") {
                line := Trim(line)
                if RegExMatch(line, "i)(?:duplex|studio|full nội thất|diện tích|m2|m²)", &found) {
                    listing["info"] := line
                    break
                }
            }
            if listing["info"] = "" && listing["extra_info"] != "" && !listing["address"]
                listing["info"] := listing["extra_info"]
        }
    }

    ; Normalize to 10-digit 0xxxxxxxxx (accepts +84 / 84 / separators).
    static NormalizePhone(value) {
        if value = ""
            return ""
        digits := RegExReplace(String(value), "\D", "")
        if digits = ""
            return ""
        if SubStr(digits, 1, 2) = "84"
            digits := "0" SubStr(digits, 3)
        if StrLen(digits) = 10 && SubStr(digits, 1, 1) = "0"
            return digits
        return ""
    }

    ; All VN mobiles in text → Array of Map("raw","phone","carrier").
    static ExtractPhoneNumbers(text) {
        phoneList := []
        seen := Map()
        pos := 1
        while RegExMatch(text, ListingParser.PHONE_FRAGMENT_PATTERN, &match, pos) {
            rawPhone := match[0]
            cleanPhone := ListingParser.NormalizePhone(rawPhone)
            if cleanPhone != "" && !seen.Has(cleanPhone) {
                seen[cleanPhone] := true
                phoneList.Push(Map(
                    "raw", rawPhone,
                    "phone", cleanPhone,
                    "carrier", ListingParser.ClassifyCarrier(cleanPhone)
                ))
            }
            pos := match.Pos(0) + Max(match.Len(0), 1)
        }
        return phoneList
    }

    ; Prefer phone on a Liên hệ/SĐT/☎ line; else last valid number in text.
    static ExtractPhone(text) {
        for line in StrSplit(text, "`n") {
            line := Trim(line)
            if RegExMatch(line,
                "i)(?:☎|📞|☎️?|liên hệ|lh\s*[:\-]|số chủ|số điện thoại|sđt|sdt|hotline|tel\b|phone\b)",
                &_) {
                phones := ListingParser.ExtractPhoneNumbers(line)
                if phones.Length
                    return phones[1]["phone"]
            }
        }

        phones := ListingParser.ExtractPhoneNumbers(text)
        if !phones.Length
            return ""
        return phones[phones.Length]["phone"]
    }

    static _PhoneFromFragment(fragment) {
        phones := ListingParser.ExtractPhoneNumbers(fragment)
        return phones.Length ? phones[1]["phone"] : ""
    }

    ; Prefix match for major VN mobile carriers (3-digit head).
    static ClassifyCarrier(phone) {
        clean := ListingParser.NormalizePhone(phone)
        if clean = ""
            return "Không xác định"
        prefix3 := SubStr(clean, 1, 3)
        switch prefix3 {
            case "086", "096", "097", "098",
                "032", "033", "034", "035", "036", "037", "038", "039":
                return "Viettel"
            case "088", "091", "094", "083", "084", "085", "081", "082":
                return "Vinaphone"
            case "089", "090", "093", "070", "079", "077", "076", "078":
                return "Mobifone"
            case "092", "056", "058":
                return "Vietnamobile"
            case "099", "059":
                return "Gmobile"
            case "055":
                return "Mạng ảo (Wintel/ITel)"
            default:
                return "Không xác định"
        }
    }

    static CountMatches(text, pattern) {
        if Trim(pattern) = ""
            return 0
        count := 0
        pos := 1
        while RegExMatch(text, pattern, &found, pos) {
            count++
            pos := found.Pos(0) + Max(found.Len(0), 1)
        }
        return count
    }

    ; Returns array of missing-field messages; empty array means valid.
    static Validate(listing, requiredKeys := "") {
        if !ListingParser.LooksLikeListing(listing["raw_text"])
            return ["Không giống tin cho thuê"]

        keys := requiredKeys is Array ? requiredKeys : ["address", "price", "owner_phone"]
        if !keys.Length
            return []

        labels := Map(
            "address", "Địa chỉ",
            "room_code", "Số phòng",
            "price", "Giá",
            "owner_phone", "Số điện thoại"
        )
        errors := []
        for key in keys {
            if !listing.Has(key) || listing[key] = ""
                errors.Push("Thiếu " (labels.Has(key) ? labels[key] : key))
        }
        return errors
    }

    static ParsePhoneRequest(text) {
        text := Trim(text)
        code := ""
        if RegExMatch(text, "i)(?:SĐT|SDT|Số chủ|Số điện thoại)\s*(\S+)", &found)
            code := found[1]
        else if RegExMatch(text, "^\d{9,}$")   ; bare phone number is not a room code
            return ""
        else if RegExMatch(text, "^(?=.*\d)([A-Za-z0-9][A-Za-z0-9.\-]{1,11})$", &found)
            code := found[1]
        else
            return ""
        return ListingParser.NormalizeRoomCode(Map("room_code", code), code)
    }

    ; Single-listing legacy output (Ctrl+Shift+B flow)
    static FormatMasked(listing, phoneHint := "") {
        return ListingParser.FormatBlock(listing, true, phoneHint)
    }

    ; Standard listing card. Missing fields become "-".
    static FormatBlock(listing, maskPhone := true, phoneHint := "") {
        ListingParser._DedupExtraInfo(listing)
        dash := "-"

        groupName := listing.Has("source_group") && Trim(listing["source_group"]) != ""
            ? Trim(listing["source_group"]) : dash
        roomType := ListingParser._RoomTypeLabel(listing)
        roomCode := ListingParser.NormalizeRoomCode(
            listing, "")
        if roomCode != ""
            listing["room_code"] := roomCode
        else
            roomCode := dash

        info := ListingParser._RoomInfoLabel(listing)
        price := listing.Has("price") && Trim(listing["price"]) != ""
            ? Trim(listing["price"]) : dash
        service := listing.Has("service_price") && Trim(listing["service_price"]) != ""
            ? Trim(listing["service_price"]) : dash
        utility := ListingParser._UtilityLabel(listing)
        phone := ListingParser._PhoneLabel(listing, maskPhone, phoneHint, roomCode)

        return StrJoin([
            "🏷️ tên nhóm: " groupName,
            "🏠 phòng: " roomType,
            "🔑 mã phòng: " roomCode,
            "📍 thông tin phòng: " info,
            "💰 giá: " price,
            "🧾 giá dịch vụ: " service,
            "⚡ giá điện nước: " utility,
            "📞 số điện thoại của chủ trọ: " phone
        ], "`n")
    }

    static _PhoneLabel(listing, maskPhone, phoneHint, roomCode) {
        dash := "-"
        if maskPhone {
            if Trim(phoneHint) = ""
                return dash
            hint := StrReplace(phoneHint, "{room_code}",
                roomCode != dash ? roomCode : "mã phòng")
            return hint
        }
        phone := listing.Has("owner_phone") ? Trim(listing["owner_phone"]) : ""
        if phone = ""
            return dash
        ; Masked Zalo numbers like 0987***890 cannot be recovered.
        if InStr(phone, "*")
            return dash
        carrier := listing.Has("phone_carrier") ? listing["phone_carrier"] : ""
        if carrier = ""
            carrier := ListingParser.ClassifyCarrier(phone)
        if carrier != "" && carrier != "Không xác định"
            return phone " (" carrier ")"
        return phone
    }

    static _RoomTypeLabel(listing) {
        hay := ""
        for key in ["info", "extra_info", "address", "raw_text", "room_code"] {
            if listing.Has(key) && listing[key] != ""
                hay .= " " listing[key]
        }
        if RegExMatch(hay, "i)\b(studio|1\s*pn|2\s*pn|3\s*pn|duplex|mezzanine|ban\s*công|phòng\s*trọ|căn\s*hộ|chdv)\b", &m)
            return Trim(RegExReplace(m[0], "\s+", " "))
        return "-"
    }

    static _RoomInfoLabel(listing) {
        parts := []
        for key in ["address", "info", "extra_info"] {
            if !listing.Has(key)
                continue
            value := Trim(RegExReplace(NormalizeNewlines(listing[key]), "\s+", " "))
            if value != ""
                parts.Push(value)
        }
        if parts.Length
            return StrJoin(parts, " | ")
        if listing.Has("raw_text") && Trim(listing["raw_text"]) != ""
            return Trim(RegExReplace(NormalizeNewlines(listing["raw_text"]), "\s+", " "))
        return "-"
    }

    static _UtilityLabel(listing) {
        if listing.Has("utility_price") && Trim(listing["utility_price"]) != ""
            return Trim(listing["utility_price"])
        dien := listing.Has("electric_price") ? Trim(listing["electric_price"]) : ""
        nuoc := listing.Has("water_price") ? Trim(listing["water_price"]) : ""
        if dien = "" && nuoc = ""
            return "-"
        if dien = ""
            return "Nước: " nuoc
        if nuoc = ""
            return "Điện: " dien
        return "Điện: " dien " | Nước: " nuoc
    }

    static _AddLine(lines, label, listing, key) {
        if listing.Has(key) && listing[key] != ""
            lines.Push(label ": " listing[key])
    }
}
