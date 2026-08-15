#Requires AutoHotkey v2.0
; Parser.ahk — Strategy: turn raw Zalo text into structured listing objects

#Include Util.ahk

class ListingParser {
    ; Ordered: the first matching rule wins, so specific labels precede generic ones
    ; ("Giá điện" must be tested before "Giá").
    static RULES := [
        ["utility_price", "i)^\s*(?:⚡\s*)?(?:Điện\s*(?:và|&|/|,)\s*nước|Điện nước)\s*[:\-–]?\s*(.+)$"],
        ["electric_price", "i)^\s*(?:⚡|👉|✅)?\s*(?:Giá điện|Tiền điện|Điện|Đ\.)\s*[:\-–]?\s*([^,\n|]+)"],
        ["water_price", "i)^\s*(?:💧|👉|✅)?\s*(?:Giá nước|Tiền nước|Nước|Nc|N\.)\s*[:\-–]?\s*([^,\n|]+)"],
        ["service_price", "i)^\s*(?:🧾|👉|✅)?\s*(?:Giá dịch vụ|Phí dịch vụ|Phí quản lý|Phí dv|Phí DV|Dịch vụ|Dv|PDV|Phí DV)\s*[:\-–]?\s*([^,\n|]+)"],
        ["address", "i)^\s*(?:📍|🏡\s*)?(?:Địa chỉ|Địa điểm|Đ/c|ĐC|Đc)\s*[:\-–]\s*(.+)$"],
        ["address", "i)^\s*📍\s*(\d[\d\/\.\-\w\s,A-Za-zÀ-ỹ]+(?:Q\.?\s*\d+|q\.?\s*\d+|quận\s*\d+|phường\s+\w+).*)$"],
        ["address", "i)^\s*(\d+\/\d+\s+[A-Za-zÀ-ỹ\s\/\.\-]+(?:quận|q\.?\s*\d+|phường\s+\w+).*)$"],
        ["room_code", "i)^\s*(?:🔑|➖|⚡)?\s*(?:Mã phòng|Mã Phòng|Số phòng|Phòng số|Mã)\s*[:\-–]\s*([A-Za-z]\d{0,3}|\d{2,4})"],
        ["room_code", "i)^\s*P(\d{2,4})\s*-\s*\d+\s*PN\s*:"],
        ["room_code", "i)^\s*-?\s*P(\d{2,4})\b(?:\s|$|[,\.:])"],
        ["price", "i)^\s*P\d{2,4}\s*-\s*\d+\s*PN\s*:\s*([\d\.]+)"],
        ["price", "i)^\s*(?:💰|🚥|👉|💸|➖)?\s*(?:Giá thuê|Giá phòng|Giá)\s*[:\-–]?\s*(.+)$"],
        ["price", "i)^\s*Giá\s+(\d+tr\d|\d+[\.,]?\d*\s*tr)\b"],
        ["info", "i)^\s*P(\d{2,4})\s+(.+)$"],
        ["owner_phone", "i)^\s*(?:📞|☎️?|☎)\s*(.+)$"],
        ["owner_phone", "i)^\s*(?:Số điện thoại|Số chủ|SĐT|SDT|Hotline|Liên hệ|LH)\s*[:\-–]\s*(.+)$"],
        ["info", "i)^\s*-?\s*(?:ℹ️\s*)?(?:Thông tin|Mô tả|Ghi chú|Nội thất|Tiện ích)\s*[:\-–]\s*(.+)$"]
    ]

    static FIELD_KEYS := [
        "address", "room_code", "price", "electric_price", "water_price",
        "utility_price", "service_price", "owner_phone", "info"
    ]

    static DEFAULT_START_PATTERN := "i)^\s*(?:📍\s*)?(?:Địa chỉ|Địa điểm|Đ/c|ĐC)\s*[:\-–]"
    ; Freeform posts often start with rental keywords instead of "Địa chỉ:"
    static RENTAL_START_PATTERN := "i)^\s*(?:🏠\s*|📍\s*|🚩\s*|👉\s*|👇\s*|💎\s*|🚥\s*|💥\s*|🔥\s*)?(?:Cho thuê|Cần cho thuê|Sang CHDV|CHDV|Phòng trọ|Căn hộ|CĂN HỘ|Nhà nguyên căn|Studio|Duplex|Phòng|Giữa tháng|Giá|Hình ảnh.*trống|trống\s+mã|trống\s+sẵn|trống\s+phòng|P\d{2,4}\s*-\s*\d+\s*PN)\b"
    static MAP_LINK_PATTERN := "i)(?:maps\.(?:app\.)?goo\.gl|google\.com/maps|goo\.gl/maps)"
    ; VN mobile: 0… or +84/84… with optional spaces/dots/dashes between digits.
    static PHONE_FRAGMENT_PATTERN := "(?:\+?84|0)(?:[\s.\-]*\d){9}"
    static DEFAULT_IMAGE_MARKER := "i)(?:\[(?:Hình ảnh|Ảnh|Image|Photo)\]|👇\s*Hình\s*ảnh|📷|🖼️|(?:^|\s)Hình ảnh(?:\s|$))"
    static DEFAULT_MIN_LISTING_SCORE := 3
    static NON_RENTAL_PATTERN := "i)\b(?:vay\s*(?:vốn|tiền|tín\s*chấp|thế\s*chấp|tài\s*chính)|tín\s*dụng|giải\s*ngân|đáo\s*hạn|mở\s*thẻ|lãi\s*suất\s*\d|bảo\s*hiểm|chứng\s*khoán)\b"
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
        else if RegExMatch(haystack, "i)\d{1,2}\.\d{3}\.\d{3}")
            score += 3
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
        ["phòng trống", 3], ["trống lại", 3], ["trống sẵn", 3], ["available", 3],
        ["căn hộ studio", 2], ["duplex", 2], ["full nt", 1], ["full nội thất", 1],
        ["nhận khách", 2], ["dọn vào", 2],
        ["giá thuê", 2], ["giá", 1], ["gia ", 1], ["triệu", 2], ["tr/th", 2], ["/tháng", 1],
        ["phí dv", 1], ["pdv", 1],
        ["địa chỉ", 2], ["dia chi", 2], ["quận", 1], ["phường", 1], ["đường", 1],
        ["điện", 1], ["nước", 1], ["dịch vụ", 1], ["sđt", 1], ["liên hệ", 2],
        ["full nội thất", 1], ["m²", 1], ["m2", 1], ["gác", 1], ["ban công", 1],
        ["google.com", 2], ["maps.app", 2], ["goo.gl", 2]
    ]

    ; Config-independent whitelist/intent signals. Multiple dimensions increase
    ; confidence; blacklist still runs before parse/save in Harvester.
    static _INTENT_REGEX_SIGNALS := [
        ["i)^\s*P\d{2,4}\s*-\s*\d+\s*PN\s*:", 5],
        ["i)\d{1,2}\.\d{3}\.\d{3}", 3],
        ["i)(?:trống|còn|sẵn)\s+(?:phòng|studio|1pn|2pn|phòng trọ)", 4],
        ["i)^\d{1,2}/\d{1,2}\s+trống", 3],
        ["i)(?:địa chỉ|dự án|đường|quận|phường|gần trường|gần đh)\s*:?", 2],
        ["i)(?:sđt|lh|mọi chi tiết|zalo|call)\s*:?\s*0[35789]\d{8}", 3],
        ["i)(?:giá|điện|nước|dịch vụ|phí dv)\s*:?\s*\d+(?:[\.,]\d+)?(?:k|tr|triệu)?", 2]
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
        ListingParser._CleanListingContent(listing)
        ListingParser._InferCompactListing(listing)
        ListingParser._DedupExtraInfo(listing)

        return listing
    }

    static PROMO_PATTERNS := [
        "i)còn\s+\d+\s*mã\s+phòng[^\n|📍]*",
        "i)nhờ\s+mọi\s+người[^\n|📍!]*",
        "i)thanks?\s+all\b",
        "i)bấm\s+vào\s+đây[^\n|]*",
        "i)tham\s+gia\s+cộng\s+đồng[^\n|]*",
        "i)mời\s+tham\s+gia[^\n|]*",
        "i)join\s+group[^\n|]*",
        "i)chốt\s+đúng\s+giá\s+thưởng[^\n|]*",
        "i)thưởng\s*nóng(?:\s+\d+[\s\d]*(?:triệu|tr|k))?(?:\s*trên\s*mỗi\s*phòng)?[^\n|📍🔥]*",
        "i)thuong\s*nong(?:\s+\d+[\s\d]*(?:triệu|tr|k))?(?:\s*tren\s*moiphong)?[^\n|📍🔥]*",
        "i)🌹[^\n|]*",
        "i)(?:hh|hoa hồng)\s*[\d/]+%[^\n|]*",
        "i)\bhđ\s*\d+[^\n|]*",
        "i)\(\s*HĐ\s*\d+[^\n|]*\)",
        "i)(?:🎉\s*)?link\s+nhóm\s*:?\s*[^\n|]*",
        "i)https?://[^\s|]+",
        "i)zalo\.me[^\s|]*"
    ]

    static _StripPromotionalText(text) {
        if text = ""
            return ""
        result := NormalizeNewlines(text)
        for pattern in ListingParser.PROMO_PATTERNS
            result := RegExReplace(result, pattern, "")
        result := RegExReplace(result, "i)thưởng\s*nóng[^|📍\n🔥]*", "")
        result := RegExReplace(result, "i)thuong\s*nong[^|📍\n🔥]*", "")
        result := RegExReplace(result, "i)\s*🔥+", " ")
        result := RegExReplace(result, "i)\s*\|\s*\|+", " | ")
        result := RegExReplace(result, "\s{2,}", " ")
        return Trim(result, " |,;.")
    }

    static _IsPromoPart(text) {
        piece := Trim(text)
        if piece = ""
            return true
        for pattern in ListingParser.PROMO_PATTERNS {
            if RegExMatch(piece, pattern)
                return true
        }
        if RegExMatch(piece,
            "i)(?:liên hệ|link nhóm|zalo\.me|chốt\s+đúng\s+giá|thưởng\s*nóng|thuong\s*nong|vay\s+tài\s+chính)")
            return true
        return RegExMatch(piece,
            "i)(?:thưởng\s*nóng|thuong\s*nong|^\s*chốt|link\s+nhóm|tham\s+gia|join\s+group|"
            . "^\s*🌹|\b(?:hh|hđ|hoa hồng)\b)")
    }

    ; True when stripped text has no meaningful rental core (group invite / CTA spam).
    static IsPromoOnlyMessage(text, listing := "") {
        if text = ""
            return true
        cleaned := ListingParser._StripPromotionalText(text)
        cleaned := RegExReplace(cleaned, "🔥|🎉|♨️|👇|👉", "")
        cleaned := Trim(RegExReplace(cleaned, "\s{2,}", " "))
        if StrLen(cleaned) < 10
            return true
        hay := StrLower(cleaned)
        if RegExMatch(hay,
            "i)(?:link\s+nhóm|tham\s+gia|zalo\.me|join\s+group|mời\s+tham\s+gia)")
            && !RegExMatch(hay,
                "i)(?:giá|cho thuê|phòng|địa chỉ|mã phòng|\d+\s*tr\b|\d+tr\d)")
            return true
        if listing is Map
            return ListingParser._CountRentalCoreSignals(listing) < 2
        signals := 0
        if RegExMatch(hay,
            "i)(?:giá|gia)\s*[:\-]|"
            . "\d+[\.,]?\d*\s*(?:tr|triệu|k| củ)(?:\s*/\s*th(?:áng|ang)?)?")
            signals++
        if RegExMatch(hay,
            "i)(?:địa chỉ|đ/c)\s*[:\-]|"
            . "(?:q\.?\s*\d+|quận\s*\d+|phường\s+\w+)")
            signals++
        if RegExMatch(hay,
            "i)(?:mã phòng|số phòng|phòng số)\s*[:\-]|\bp\d{2,4}\b")
            signals++
        if RegExMatch(hay, ListingParser.PHONE_FRAGMENT_PATTERN)
            signals++
        if RegExMatch(hay, "i)(?:dịch vụ|điện|nước)\s*[:\-]\s*\S")
            signals++
        return signals < 2
    }

    static ROOM_INFO_LABELED_PATTERN := "i)^(?:dịch vụ|pdv|dv|điện|nước|giá|địa chỉ|mã phòng|số phòng|sđt|liên hệ|xe)\s*[:\-]?"
    static ROOM_INFO_AMENITY_PATTERN := "i)(?:full nội thất|full nt|nội thất|máy giặt|máy lạnh|máy nước nóng|"
        . "vân tay|giờ giấc|duplex|studio|mezzanine|gác|gác cao|ban công|bancong|"
        . "wc riêng|hẻm xe hơi|hem xe hoi|xe hơi|ô tô|thang máy|"
        . "an ninh|camera|"
        . "m²|m2|diện tích|"
        . "người.*xe|\d+\s*người|free\s*\d*\s*xe|giữ xe|"
        . "trống phòng|trống sẵn|\d{1,2}/\d{1,2}\s+trống|tách bếp|ngủ tách|tiện ích|"
        . "tủ lạnh|kệ bếp|tủ quần|phòng mới|"
        . "\d+\s*pn|lầu\s*\d+)"

    static _IsLabeledFieldPart(text) {
        piece := Trim(text)
        return RegExMatch(piece, ListingParser.ROOM_INFO_LABELED_PATTERN)
    }

    static _IsRoomInfoPart(text) {
        piece := Trim(text)
        if piece = "" || ListingParser._IsPromoPart(piece)
            return false
        if ListingParser._IsLabeledFieldPart(piece)
            return false
        return RegExMatch(piece, ListingParser.ROOM_INFO_AMENITY_PATTERN)
    }

    static _CountRentalCoreSignals(listing) {
        count := 0
        if listing.Has("price") && Trim(listing["price"]) != ""
            count++
        if listing.Has("address") && Trim(listing["address"]) != ""
            count++
        code := listing.Has("room_code") ? Trim(listing["room_code"]) : ""
        if code != "" && !RegExMatch(code, "^R[a-f0-9]{6}$")
            count++
        if listing.Has("service_price") && Trim(listing["service_price"]) != ""
            count++
        if listing.Has("electric_price") && Trim(listing["electric_price"]) != ""
            count++
        if listing.Has("water_price") && Trim(listing["water_price"]) != ""
            count++
        if listing.Has("owner_phone") && Trim(listing["owner_phone"]) != ""
            count++
        if listing.Has("info") && Trim(listing["info"]) != ""
            count++
        return count
    }

    ; Harvest gate: rental intent + at least two core fields after cleanup.
    static QualifiesAsRentalListing(listing) {
        raw := listing.Has("raw_text") ? listing["raw_text"] : ""
        if !ListingParser.LooksLikeListing(raw)
            return false
        if ListingParser.IsPromoOnlyMessage(raw, listing)
            return false
        return ListingParser._CountRentalCoreSignals(listing) >= 2
    }

    static _ExtractPinAddress(text) {
        if text = ""
            return ""
        if RegExMatch(text,
            "📍\s*(\d{2,5}\s+[A-Za-z0-9À-ỹ\s\/\.\-]+?"
            . "(?:phường|quận|p\.?\s*\d+|q\.?\s*\d+)"
            . "[A-Za-zÀ-ỹ\s]*?)(?=Bấm|bấm|https?|zalo|\||📍|🎉|📱|$)",
            &found)
            return Trim(found[1])
        if RegExMatch(text,
            "📍\s*(\d{2,5}\s+[A-Za-z0-9À-ỹ\s\/\.\-]{4,80})",
            &found)
            return Trim(RegExReplace(found[1], "(Bấm|bấm|zalo).*$"))
        return ""
    }

    static _InferInlineUtilityPrices(listing) {
        haystack := listing["raw_text"]
        for key in ["address", "info", "extra_info"] {
            if listing.Has(key) && Trim(listing[key]) != ""
                haystack .= "`n" listing[key]
        }

        if listing["service_price"] = "" {
            if RegExMatch(haystack,
                "i)(?:dịch vụ|dv|pdv)\s*:\s*([^,\n|🎉📱]+)", &found)
                listing["service_price"] := Trim(found[1])
            else if RegExMatch(haystack,
                "i)(?:dv|pdv)\s+(\d+k(?:/\w+)?)", &found)
                listing["service_price"] := Trim(found[1])
        }
        if listing["electric_price"] = "" {
            if RegExMatch(haystack, "i)điện\s*:\s*([^,\n|🎉📱]+)", &found)
                listing["electric_price"] := Trim(found[1])
            else if RegExMatch(haystack, "i)\bđiện\s+(\d+k(?:/\w+)?)", &found)
                listing["electric_price"] := Trim(found[1])
        }
        if listing["water_price"] = "" {
            if RegExMatch(haystack, "i)nước\s*:\s*([^,\n|🎉📱]+)", &found)
                listing["water_price"] := Trim(found[1])
            else if RegExMatch(haystack,
                "i)\bnước\s+(\d+k(?:/\w+)?(?:/\w+)?)", &found)
                listing["water_price"] := Trim(found[1])
        }
    }

    static _SplitInfoParts(text) {
        parts := []
        for line in StrSplit(NormalizeNewlines(text), "`n") {
            line := Trim(line)
            if line = ""
                continue
            for piece in StrSplit(line, " | ") {
                piece := Trim(piece)
                if piece != ""
                    parts.Push(piece)
            }
        }
        return parts
    }

    static _ExtractAmenityInfo(listing) {
        amenities := []
        sources := []
        if listing.Has("extra_info") && Trim(listing["extra_info"]) != ""
            sources.Push(listing["extra_info"])
        if listing.Has("raw_text") && Trim(listing["raw_text"]) != ""
            sources.Push(listing["raw_text"])

        for source in sources {
            for piece in ListingParser._SplitInfoParts(source) {
                if !ListingParser._IsRoomInfoPart(piece)
                    continue
                clean := ListingParser._StripPromotionalText(piece)
                if clean != "" && !ListingParser._ArrayHas(amenities, clean)
                    amenities.Push(clean)
            }
        }
        if amenities.Length
            listing["info"] := StrJoin(amenities, " | ")
    }

    static _ArrayHas(arr, value) {
        for item in arr {
            if item = value
                return true
        }
        return false
    }

    static _AddressLooksPolluted(address) {
        addr := Trim(address)
        if addr = ""
            return false
        return RegExMatch(addr,
            "i)còn\s+\d+\s*mã|nhờ\s+mọi|zalo\.me|tham\s+gia|thanks?\s+all|link\s+nhóm|thưởng\s*nóng|thuong\s*nong")
    }

    static _CleanListingContent(listing) {
        ListingParser._InferInlineUtilityPrices(listing)

        pin := ListingParser._ExtractPinAddress(listing["raw_text"])
        if pin = "" {
            for key in ["address", "info", "extra_info"] {
                if !listing.Has(key)
                    continue
                pin := ListingParser._ExtractPinAddress(listing[key])
                if pin != ""
                    break
            }
        }

        addr := listing.Has("address") ? Trim(listing["address"]) : ""
        if pin != ""
            && (addr = "" || ListingParser._AddressLooksPolluted(addr))
            listing["address"] := ListingParser._StripPromotionalText(pin)
        else if addr != ""
            listing["address"] := ListingParser._StripPromotionalText(addr)

        if listing.Has("info") && Trim(listing["info"]) != ""
            listing["info"] := ListingParser._StripPromotionalText(listing["info"])

        ListingParser._ExtractAmenityInfo(listing)
        if listing.Has("info") && Trim(listing["info"]) != ""
            && ListingParser._AddressLooksPolluted(listing["info"])
            listing["info"] := ""

        if listing.Has("extra_info") && Trim(listing["extra_info"]) != "" {
            kept := []
            for part in StrSplit(listing["extra_info"], " | ") {
                piece := Trim(part)
                if !ListingParser._IsRoomInfoPart(piece)
                    continue
                if listing.Has("address") && Trim(listing["address"]) != ""
                    && InStr(piece, listing["address"])
                    continue
                kept.Push(piece)
            }
            listing["extra_info"] := StrJoin(kept, " | ")
        }

        ListingParser._RejectPromoDerivedFields(listing)
    }

    ; Drop giá/địa chỉ bị suy ra từ dòng thưởng nóng (vd. "2 triệu trên mỗi phòng").
    static _RejectPromoDerivedFields(listing) {
        hay := listing.Has("raw_text") ? StrLower(listing["raw_text"]) : ""
        if hay = "" || !RegExMatch(hay, "i)thưởng\s*nóng|thuong\s*nong")
            return

        price := listing.Has("price") ? Trim(listing["price"]) : ""
        if price != "" {
            priceHay := StrLower(price)
            if RegExMatch(hay, "i)thưởng\s*nóng[^\n]{0,100}?" . RegExReplace(priceHay, "\s+", "\s*"))
                listing["price"] := ""
            else if RegExMatch(hay, "i)thưởng\s*nóng[^\n]*\d+[\s\d]*(?:triệu|tr|k)")
                && RegExMatch(priceHay, "i)^\d+\s*(?:tr|triệu|k)$")
                && !RegExMatch(hay, "i)(?:💰|giá\s*[:\-]|cho thuê[^\n]{0,40}\d+\s*(?:tr|triệu))")
                listing["price"] := ""
        }

        for key in ["address", "info", "extra_info"] {
            if !listing.Has(key)
                continue
            value := ListingParser._StripPromotionalText(listing[key])
            value := Trim(RegExReplace(value, "i)\s*🔥+", " "))
            if value = "" || ListingParser._AddressLooksPolluted(value)
                listing[key] := ""
            else
                listing[key] := value
        }
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
        stripped := RegExReplace(stripped, "i)^\s*(?:👉|•|➖|[-–—*]\s*)+")
        stripped := RegExReplace(stripped,
            "i)^\s*(?:🌈|🌹+|🚩|💎|🚥|👇|💸|✅|💥|⚡|🏡|📞|☎️?|☎|🔥+)+")
        return Trim(stripped)
    }

    ; Fill gaps when posts use freeform text instead of "Giá:" / "Địa chỉ:" labels.
    static _InferFields(listing) {
        text := listing["raw_text"]

        if listing["price"] != "" && RegExMatch(listing["price"], "^\d{1,2}\.\d{3}\.\d{3}$")
            listing["price"] := ListingParser._NormalizeDotPrice(listing["price"])

        if listing["price"] = "" {
            if RegExMatch(text, "i)(?:giá\s*)?(\d+\s*tr\s*\d|\d+tr\d)", &found)
                listing["price"] := Trim(found[1])
            else if RegExMatch(text, "i)(?:👉\s*)?(\d+tr\d|\d+\s*tr\s*\d)", &found)
                listing["price"] := Trim(found[1])
            else if RegExMatch(text, "i)(\d{1,2}\.\d{3}\.\d{3})", &found)
                listing["price"] := ListingParser._NormalizeDotPrice(found[1])
            else if RegExMatch(text, "i)(\d+[\.,]?\d*)\s*(tr|triệu|k| củ)(?:\s*/\s*th(?:áng|ang)?)?", &found)
                listing["price"] := Trim(found[0])
            else if RegExMatch(text, "i)giá\s*[:\-–]?\s*([^\n\r]{2,40})", &found)
                listing["price"] := Trim(found[1])
        }

        if listing["room_code"] = "" {
            if RegExMatch(text, "i)(?:mã|ma)\s+([A-Za-z]\d{0,3}|\d{2,4})", &found)
                listing["room_code"] := found[1]
            else if RegExMatch(text, "i)(?:mã|ma)\s+(\d{2,4})", &found)
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
                if !RegExMatch(candidate, "i)^\d{1,2}/\d{1,2}\s+trống\s*$")
                    && RegExMatch(candidate,
                        "i)(?:\d|quang|đường|phố|q\.?\s*\d+|quận|phường)", &_)
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
                    } else if RegExMatch(line,
                        "i)^\d+\/\d+\s+[A-Za-zÀ-ỹ\s\/\.\-]+(?:quận|q\.?\s*\d+|phường\s+\w+)",
                        &_) {
                        candidate := line
                        score := 5
                    } else if RegExMatch(line,
                        "i)^\d[\d\/\.\-\w\s,A-Za-zÀ-ỹ]+(?:gò vấp|go vap|bình thạnh|tân phú|tân bình|thủ đức|"
                        . "quận|q\.?\s*\d+|phường|p\.?\s*\d+)", &_) {
                        candidate := line
                        score := 4
                    } else if RegExMatch(line,
                        "i)(?:\d+[\/\-\w]*\s+)?(?:đường|phố|ngõ|hẻm|hem)\s+.+\s*(?:q\.?\s*\d+|quận\s*\d+)",
                        &_) {
                        candidate := line
                        score := 4
                    } else if RegExMatch(line, "i).+\s+(?:q\.?\s*\d+|quận\s*\d+|phường\s+\w+)", &found) && StrLen(line) >= 10 {
                        candidate := line
                        score := 2
                    }
                    if candidate != "" && RegExMatch(candidate, "\d/\d")
                        && !RegExMatch(candidate, "i)^\d{1,2}/\d{1,2}\s+trống\s*$")
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
                line := Trim(ListingParser._StripLinePrefix(line))
                if RegExMatch(line,
                    "i)(?:duplex|studio|full nội thất|full nt|bancong|ban công|diện tích|m2|m²|"
                    . "wc riêng|thang máy|trống sẵn|\d+\s*pn)", &found) {
                    listing["info"] := line
                    break
                }
            }
            if listing["info"] = "" && listing["extra_info"] != "" && !listing["address"]
                listing["info"] := listing["extra_info"]
        }
    }

    ; P201 - 2PN : 8.200.000 ( 20/8 trống )
    static _InferCompactListing(listing) {
        text := Trim(NormalizeNewlines(listing["raw_text"]))
        if !RegExMatch(text,
            "im)^\s*P(\d{2,4})\s*-\s*(\d+\s*PN)\s*:\s*([\d\.]+)(?:\s*\(([^)]+)\))?",
            &found)
            return

        listing["room_code"] := "P" found[1]
        listing["info"] := Trim(found[2])
        if listing["price"] = "" || RegExMatch(listing["price"], "^\d{1,2}\.\d{3}\.\d{3}$")
            listing["price"] := ListingParser._NormalizeDotPrice(found[3])
        avail := Trim(found[4])
        if avail != ""
            listing["extra_info"] := avail
    }

    ; 8.200.000 → 8tr2 (VN dot-separated VND)
    static _NormalizeDotPrice(value) {
        v := Trim(value)
        if RegExMatch(v, "^(\d{1,2})\.(\d{3})\.(\d{3})$", &m) {
            whole := Integer(m[1])
            sub := (Integer(m[2]) * 1000 + Integer(m[3])) // 100000
            if sub = 0
                return whole "tr"
            return whole "tr" sub
        }
        return v
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
        if !ListingParser.QualifiesAsRentalListing(listing)
            return ListingParser.LooksLikeListing(listing["raw_text"])
                ? ["Không đủ thông tin cho thuê"]
                : ["Không giống tin cho thuê"]

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
            ? RegExReplace(Trim(listing["service_price"]),
                "i)^(?:dịch vụ|dv|pdv)\s*:?\s*", "") : dash
        utility := ListingParser._UtilityLabel(listing)

        return StrJoin([
            "🏷️ tên nhóm: " groupName,
            "🏠 phòng: " roomType,
            "🔑 mã phòng: " roomCode,
            "📍 thông tin phòng: " info,
            "💰 giá: " price,
            "🧾 giá dịch vụ: " service,
            "⚡ giá điện nước: " utility
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
        if listing.Has("address") && Trim(listing["address"]) != "" {
            addr := ListingParser._StripPromotionalText(listing["address"])
            addr := Trim(RegExReplace(NormalizeNewlines(addr), "\s+", " "))
            if addr != "" && !ListingParser._IsPromoPart(addr)
                parts.Push(addr)
        }
        if listing.Has("info") && Trim(listing["info"]) != "" {
            info := ListingParser._StripPromotionalText(listing["info"])
            info := Trim(RegExReplace(NormalizeNewlines(info), "\s+", " "))
            if info != "" && !ListingParser._IsPromoPart(info)
                parts.Push(info)
        }
        if listing.Has("extra_info") && Trim(listing["extra_info"]) != "" {
            for part in StrSplit(listing["extra_info"], " | ") {
                piece := Trim(ListingParser._StripPromotionalText(part))
                piece := Trim(RegExReplace(NormalizeNewlines(piece), "\s+", " "))
                if piece != "" && ListingParser._IsRoomInfoPart(piece)
                    parts.Push(piece)
            }
        }
        if parts.Length
            return StrJoin(parts, " | ")
        return "-"
    }

    static _UtilityLabel(listing) {
        if listing.Has("utility_price") && Trim(listing["utility_price"]) != ""
            return Trim(listing["utility_price"])
        dien := listing.Has("electric_price") ? Trim(listing["electric_price"]) : ""
        nuoc := listing.Has("water_price") ? Trim(listing["water_price"]) : ""
        if dien = "" && nuoc = ""
            return "-"
        dien := RegExReplace(dien, "i)^(?:điện|tiền điện)\s*:?\s*", "")
        nuoc := RegExReplace(nuoc, "i)^(?:nước|tiền nước)\s*:?\s*", "")
        nuocLabel := Trim(nuoc)
        if RegExMatch(nuocLabel, "i)^(.+?)\s*/\s*người\s*$", &found)
            nuocLabel := Trim(found[1]) " nước/người"
        else if nuocLabel != ""
            nuocLabel .= " nước"
        dienLabel := Trim(dien)
        if dienLabel != ""
            dienLabel .= " điện"
        if dienLabel != "" && nuocLabel != ""
            return dienLabel ", " nuocLabel
        if dienLabel != ""
            return dienLabel
        return nuocLabel != "" ? nuocLabel : "-"
    }

    static _AddLine(lines, label, listing, key) {
        if listing.Has(key) && listing[key] != ""
            lines.Push(label ": " listing[key])
    }
}
