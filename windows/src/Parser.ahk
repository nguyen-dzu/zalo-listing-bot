#Requires AutoHotkey v2.0
; Parser.ahk — Strategy: turn raw Zalo text into structured listing objects

class ListingParser {
    ; Ordered: the first matching rule wins, so specific labels precede generic ones
    ; ("Giá điện" must be tested before "Giá").
    static RULES := [
        ["utility_price", "i)^\s*(?:⚡\s*)?(?:Điện\s*(?:và|&|/|,)\s*nước|Điện nước)\s*[:\-–]\s*(.+)$"],
        ["electric_price", "i)^\s*(?:⚡\s*)?(?:Giá điện|Tiền điện|Điện)\s*[:\-–]\s*(.+)$"],
        ["water_price", "i)^\s*(?:💧\s*)?(?:Giá nước|Tiền nước|Nước)\s*[:\-–]\s*(.+)$"],
        ["service_price", "i)^\s*(?:🧾\s*)?(?:Giá dịch vụ|Phí dịch vụ|Phí quản lý|Dịch vụ)\s*[:\-–]\s*(.+)$"],
        ["address", "i)^\s*(?:📍\s*)?(?:Địa chỉ|Địa điểm|Đ/c|ĐC)\s*[:\-–]\s*(.+)$"],
        ["room_code", "i)^\s*(?:🔑\s*)?(?:Mã phòng|Số phòng|Phòng số|Mã)\s*[:\-–]\s*(.+)$"],
        ["price", "i)^\s*(?:💰\s*)?(?:Giá thuê|Giá phòng|Giá)\s*[:\-–]\s*(.+)$"],
        ["owner_phone", "i)^\s*(?:📞\s*)?(?:Số điện thoại|Số chủ|SĐT|SDT|Hotline|Liên hệ|LH)\s*[:\-–]\s*(.+)$"],
        ["info", "i)^\s*(?:ℹ️\s*)?(?:Thông tin|Mô tả|Ghi chú|Nội thất|Tiện ích)\s*[:\-–]\s*(.+)$"]
    ]

    static FIELD_KEYS := [
        "address", "room_code", "price", "electric_price", "water_price",
        "utility_price", "service_price", "owner_phone", "info"
    ]

    static DEFAULT_START_PATTERN := "i)^\s*(?:📍\s*)?(?:Địa chỉ|Địa điểm|Đ/c|ĐC)\s*[:\-–]"
    static DEFAULT_IMAGE_MARKER := "i)\[(?:Hình ảnh|Ảnh|Image|Photo)\]"
    ; "Minh Anh 18:05" — Zalo prints a sender/time header above each message
    static DEFAULT_NOISE_PATTERN := "i)^\S.{0,60}\s\d{1,2}:\d{2}(?:\s*(?:AM|PM|SA|CH))?$"

    static NewListing() {
        listing := Map()
        for key in ListingParser.FIELD_KEYS
            listing[key] := ""
        listing["extra_info"] := ""
        listing["raw_text"] := ""
        listing["image_count"] := 0
        return listing
    }

    ; Split a bulk conversation capture into one block per listing.
    ; Zalo shows image bubbles *before* the text of the same post, so a block
    ; starts at the image markers preceding its address line, not at that line.
    static SplitBlocks(text, startPattern := "", imageMarker := "") {
        pattern := startPattern != "" ? startPattern : ListingParser.DEFAULT_START_PATTERN
        marker := imageMarker != "" ? imageMarker : ListingParser.DEFAULT_IMAGE_MARKER
        lines := StrSplit(NormalizeNewlines(text), "`n")

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

            matched := false
            for rule in ListingParser.RULES {
                if RegExMatch(line, rule[2], &found) {
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

        listing["image_count"] := ListingParser.CountMatches(listing["raw_text"], marker)

        return listing
    }

    static NormalizePhone(value) {
        if value = ""
            return ""
        digits := RegExReplace(value, "[^\d]")
        return RegExMatch(digits, "^0\d{8,10}$") ? digits : ""
    }

    static ExtractPhone(text) {
        stripped := RegExReplace(text, "[.\-\s]")
        return RegExMatch(stripped, "(0\d{8,10})", &found) ? found[1] : ""
    }

    static CountMatches(text, pattern) {
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
        labels := Map(
            "address", "Địa chỉ",
            "room_code", "Số phòng",
            "price", "Giá",
            "owner_phone", "Số điện thoại"
        )
        keys := requiredKeys is Array ? requiredKeys : ["address", "price", "owner_phone"]
        errors := []
        for key in keys {
            if !listing.Has(key) || listing[key] = ""
                errors.Push("Thiếu " (labels.Has(key) ? labels[key] : key))
        }
        return errors
    }

    static ParsePhoneRequest(text) {
        text := Trim(text)
        if RegExMatch(text, "i)(?:SĐT|SDT|Số chủ|Số điện thoại)\s*(\S+)", &found)
            return found[1]
        if RegExMatch(text, "^\d{9,}$")   ; a bare phone number is not a room code
            return ""
        if RegExMatch(text, "^(?=.*\d)([A-Za-z0-9][A-Za-z0-9.\-]{1,11})$", &found)
            return found[1]
        return ""
    }

    ; Single-listing legacy output (Ctrl+Shift+B flow)
    static FormatMasked(listing, phoneHint := "") {
        return ListingParser.FormatBlock(listing, true, phoneHint)
    }

    static FormatBlock(listing, maskPhone := true, phoneHint := "") {
        lines := []
        ListingParser._AddLine(lines, "📍 Địa chỉ", listing, "address")
        ListingParser._AddLine(lines, "🔑 Số phòng", listing, "room_code")
        ListingParser._AddLine(lines, "💰 Giá", listing, "price")
        ListingParser._AddLine(lines, "⚡💧 Điện nước", listing, "utility_price")
        ListingParser._AddLine(lines, "⚡ Điện", listing, "electric_price")
        ListingParser._AddLine(lines, "💧 Nước", listing, "water_price")
        ListingParser._AddLine(lines, "🧾 Dịch vụ", listing, "service_price")
        ListingParser._AddLine(lines, "ℹ️ Thông tin", listing, "info")
        ListingParser._AddLine(lines, "📝 Khác", listing, "extra_info")

        if maskPhone {
            hint := phoneHint != "" ? phoneHint : 'Nhắn bot "SĐT {room_code}" để lấy số'
            hint := StrReplace(hint, "{room_code}", listing["room_code"] != "" ? listing["room_code"] : "mã phòng")
            lines.Push("📞 Số chủ: " hint)
        } else if listing["owner_phone"] != "" {
            lines.Push("📞 Số chủ: " listing["owner_phone"])
        }

        return StrJoin(lines, "`n")
    }

    static _AddLine(lines, label, listing, key) {
        if listing.Has(key) && listing[key] != ""
            lines.Push(label ": " listing[key])
    }
}
