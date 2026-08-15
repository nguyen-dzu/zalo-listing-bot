#Requires AutoHotkey v2.0
; Harvester.ahk — Service: read source groups, drop blocked/duplicate posts, persist new listings

class MessageHarvester {
    __New(config, ui, registry, blockList, stateStore, repository, mediaCapturer := 0) {
        this.config := config
        this.ui := ui
        this.registry := registry
        this.blockList := blockList
        this.state := stateStore
        this.repo := repository
        this.mediaCapturer := mediaCapturer
    }

    _EmptySummary() {
        return Map(
            "groups", 0, "saved", 0, "blocked", 0,
            "duplicate", 0, "invalid", 0, "published", 0,
            "revisit", 0, "media_captured", 0, "media_failed", 0, "errors", []
        )
    }

    ; Harvest every enabled source group. Returns a summary Map.
    HarvestAll() {
        return this.HarvestGroups(this.registry.SourceGroups())
    }

    ; Sequential bounded harvest. State may be flushed after every group so a
    ; restart resumes from the oldest untouched group instead of losing a cycle.
    HarvestGroups(groups, afterGroupFn := 0) {
        summary := this._EmptySummary()
        for index, group in groups {
            summary["groups"]++
            result := 0
            try {
                unreadLimit := group.Has("unread_count")
                    ? group["unread_count"] : 0
                result := this.HarvestGroup(group["group_name"], unreadLimit)
                summary["saved"] += result["saved"]
                summary["blocked"] += result["blocked"]
                summary["duplicate"] += result["duplicate"]
                summary["invalid"] += result["invalid"]
                summary["media_captured"] += result["media_captured"]
                summary["media_failed"] += result["media_failed"]
            } catch as err {
                ; OpenGroup miss / wrong chat → skip this group, try the next.
                summary["errors"].Push(
                    "skip " group["group_name"] ": " err.Message)
                ; #region agent log
                AgentDbg("H3", "Harvester.ahk:HarvestGroups", "group_error",
                    '{"group":"' StrReplace(group["group_name"], '"', '\"')
                    '","error":"' StrReplace(StrReplace(err.Message, "`n", " "), '"', '\"') '"}')
                ; #endregion
            }
            if this.config.HarvestSaveStateEachGroup
                this.state.Save()
            if afterGroupFn {
                shouldContinue := true
                try shouldContinue := afterGroupFn.Call(
                    index, group, result, summary)
                catch as err {
                    summary["errors"].Push(
                        "after-group " group["group_name"] ": " err.Message)
                }
                if shouldContinue = false
                    break
            }
            this._SequentialGroupDelay()
        }
        this.state.Save()
        return summary
    }

    _SequentialGroupDelay() {
        Sleep Random(
            this.config.HarvestGroupDelayMinMs,
            this.config.HarvestGroupDelayMaxMs)
    }

    _NamesToGroups(names, sources) {
        lookup := Map()
        for group in sources
            lookup[group["group_name"]] := group
        batch := []
        for name in names {
            if lookup.Has(name)
                batch.Push(lookup[name])
        }
        return batch
    }

    ; Lightweight re-read after publish: if conversation hash changed, queue for next pass.
    _RecheckForNewMessages(groupName) {
        this.ui.OpenGroup(groupName, "read")
        settle := this.config.HasProp("CaptureSettleMs") ? this.config.CaptureSettleMs : 600
        Sleep settle
        text := this.ui.CaptureConversationText()
        hash := FnvHash(NormalizeNewlines(text))
        if this.state.HasCaptureChanged(groupName, hash) {
            this.state.MarkNeedsRevisit(groupName, true)
            return true
        }
        return false
    }

    ; Harvest revisit groups, then mark groups whose conversation changed after publish.
    ProcessRevisitQueue() {
        summary := Map(
            "revisit", 0, "groups", 0, "saved", 0,
            "media_captured", 0, "media_failed", 0, "errors", []
        )
        revisitNames := this.state.ListRevisitGroups()
        sources := this.registry.SourceGroups()
        if revisitNames.Length {
            batch := this._NamesToGroups(revisitNames, sources)
            for group in batch {
                summary["groups"]++
                try {
                    result := this.HarvestGroup(group["group_name"])
                    summary["saved"] += result["saved"]
                    summary["media_captured"] += result["media_captured"]
                    summary["media_failed"] += result["media_failed"]
                    this.state.MarkNeedsRevisit(group["group_name"], false)
                } catch as err {
                    summary["errors"].Push(group["group_name"] ": " err.Message)
                }
                Sleep this.config.BetweenGroupsMs
            }
        }

        if this.config.RecheckAfterPublish {
            Sleep this.config.AfterPublishRecheckMs
            for group in sources {
                try {
                    if this._RecheckForNewMessages(group["group_name"])
                        summary["revisit"]++
                } catch as err {
                    summary["errors"].Push("recheck " group["group_name"] ": " err.Message)
                }
            }
        }

        this.state.Save()
        return summary
    }

    HarvestGroup(groupName, unreadLimit := 0) {
        result := Map(
            "saved", 0, "blocked", 0, "duplicate", 0, "invalid", 0,
            "media_captured", 0, "media_failed", 0, "saved_records", []
        )

        this.ui.OpenGroup(groupName, "read")
        settle := this.config.HasProp("CaptureSettleMs") ? this.config.CaptureSettleMs : 600
        Sleep settle
        ; Badge "1" and the old first-cycle unread_count=1 must not shrink the
        ; DOM scan to a single bubble — that drops listings and nearby photos.
        origUnread := unreadLimit
        if unreadLimit <= 1
            unreadLimit := 0
        effectiveLimit := unreadLimit > 0
            ? Min(this.config.MaxMessagesPerGroup, unreadLimit)
            : this.config.MaxMessagesPerGroup
        scanLimit := this.config.HasProp("MaxScanMessages")
            ? this.config.MaxScanMessages
            : effectiveLimit
        if unreadLimit > scanLimit
            scanLimit := Min(unreadLimit, this.config.MaxMessagesPerGroup)
        capture := this.ui.CaptureConversation("", scanLimit)
        text := capture.Has("text") ? capture["text"] : ""
        msgCount := capture.Has("messages") ? capture["messages"].Length : 0
        imageTotal := capture.Has("image_total") ? capture["image_total"] : 0
        normalized := NormalizeNewlines(text)

        candidates := this._BuildCandidates(capture)
        blocks := []
        candidateByHash := Map()
        for candidate in candidates {
            block := candidate["text"]
            hash := FnvHash(block)
            blocks.Push(block)
            if candidateByHash.Has(hash) {
                candidateByHash[hash]["images"] := this._MergeUrls(
                    candidateByHash[hash]["images"], candidate["images"])
            } else
                candidateByHash[hash] := candidate
        }
        this._Log("harvest_scan group=" groupName
            " messages=" msgCount
            " candidates=" blocks.Length)
        ; #region agent log
        AgentDbg("H6", "Harvester.ahk:HarvestGroup", "scan",
            '{"group":"' StrReplace(groupName, '"', '\"')
            '","messages":' msgCount
            ',"candidates":' blocks.Length
            ',"scanLimit":' scanLimit
            ',"origUnread":' origUnread
            ',"unreadLimit":' unreadLimit
            ',"imageTotal":' imageTotal
            ',"emptyText":' (Trim(normalized) = "" ? 1 : 0) "}")
        ; #endregion
        if Trim(normalized) = ""
            return result

        captureHash := this._CaptureHash(capture, normalized)
        previousHash := this.state.GetCaptureHash(groupName)
        ; Conversation unchanged → already-read messages; skip re-copy/re-parse.
        if previousHash != "" && previousHash = captureHash {
            ; #region agent log
            AgentDbg("H6", "Harvester.ahk:HarvestGroup", "hash_skip",
                '{"group":"' StrReplace(groupName, '"', '\"')
                '","messages":' msgCount "}")
            ; #endregion
            this.state.MarkNeedsRevisit(groupName, false)
            this.state.TouchHarvest(groupName)
            return result
        }

        this.state.SetCaptureHash(groupName, captureHash)
        this.state.MarkNeedsRevisit(groupName, false)

        pick := MessageActivityScanner.PickUnseenNewestFirst(
            blocks,
            ObjBindMethod(this.state, "IsSeen", groupName),
            effectiveLimit)
        if pick["stopped_on_seen"]
            result["duplicate"]++
        ; #region agent log
        this._DebugClassify(groupName, capture, blocks, pick)
        ; #endregion

        for item in pick["items"] {
            block := item["block"]
            hash := item["hash"]
            candidate := candidateByHash.Has(hash)
                ? candidateByHash[hash] : Map("images", [])

            listing := ListingParser.Parse(block, this.config.ImageMarkerPattern)
            listing["image_urls"] := candidate["images"]
            listing["image_count"] := candidate["images"].Length
            listing["image_groups"] := []
            if candidate.Has("message_hash")
                listing["message_hash"] := candidate["message_hash"]
            if candidate.Has("forward_eligible")
                listing["forward_eligible"] := candidate["forward_eligible"] ? 1 : 0

            keyword := this.blockList.Match(block)
            if keyword != "" && !this._SoftBlockOverride(keyword, listing) {
                this.state.MarkSeen(groupName, hash)
                result["blocked"]++
                continue
            }
            if ListingParser.Validate(listing, this.config.RequiredFields).Length {
                this.state.MarkSeen(groupName, hash)
                result["invalid"]++
                continue
            }

            record := this.repo.SaveListing(listing, groupName, hash)
            this.state.MarkSeen(groupName, hash)
            result["saved"]++
            result["saved_records"].Push(record)
            if (this.mediaCapturer
                && this.config.AutoCapture
                && ((record.Has("image_count") && record["image_count"] > 0)
                    || this.config.AutoCaptureProbeImages)) {
                mediaOk := this.mediaCapturer.CaptureForRecord(groupName, record)
                if mediaOk
                    result["media_captured"]++
                else
                    result["media_failed"]++
            }
        }

        this.state.TouchHarvest(groupName)
        ; #region agent log
        AgentDbg("H7", "Harvester.ahk:HarvestGroup", "result_filter",
            '{"group":"' StrReplace(groupName, '"', '\"')
            '","saved":' result["saved"]
            ',"blocked":' result["blocked"]
            ',"invalid":' result["invalid"]
            ',"duplicate":' result["duplicate"]
            ',"picked":' pick["items"].Length
            ',"stoppedOnSeen":' (pick["stopped_on_seen"] ? 1 : 0) "}")
        ; #endregion
        this._Log("harvest_result group=" groupName
            " saved=" result["saved"]
            " blocked=" result["blocked"]
            " invalid=" result["invalid"]
            " media_ok=" result["media_captured"]
            " media_fail=" result["media_failed"])
        ; #region agent log
        AgentDbg("H6", "Harvester.ahk:HarvestGroup", "result",
            '{"group":"' StrReplace(groupName, '"', '\"')
            '","saved":' result["saved"]
            ',"blocked":' result["blocked"]
            ',"invalid":' result["invalid"]
            ',"duplicate":' result["duplicate"]
            ',"mediaOk":' result["media_captured"]
            ',"mediaFail":' result["media_failed"] "}")
        ; #endregion
        return result
    }

    ; @All / tìm phòng / cần thuê often appear on real supply posts.
    _SoftBlockOverride(keyword, listing) {
        k := StrLower(Trim(keyword))
        if k != "@all" && k != "tìm phòng" && k != "cần thuê"
            return false
        return ListingParser.QualifiesAsRentalListing(listing)
    }

    ; #region agent log
    _DebugClassify(groupName, capture, blocks, pick) {
        messages := capture.Has("messages") && capture["messages"] is Array
            ? capture["messages"] : []
        picked := Map()
        for item in pick["items"]
            picked[item["hash"]] := true
        lookY := 0
        lookN := 0
        qualY := 0
        blkN := 0
        softY := 0
        rows := ""
        n := 0
        for message in messages {
            if !(message is Map)
                continue
            text := message.Has("text")
                ? Trim(NormalizeNewlines(message["text"])) : ""
            if text = ""
                continue
            looks := ListingParser.LooksLikeListing(text)
            listing := ListingParser.Parse(text, this.config.ImageMarkerPattern)
            core := ListingParser._CountRentalCoreSignals(listing)
            qualifies := ListingParser.QualifiesAsRentalListing(listing)
            keyword := this.blockList.Match(text)
            if looks
                lookY++
            else
                lookN++
            if qualifies
                qualY++
            if keyword != "" {
                blkN++
                if this._SoftBlockOverride(keyword, listing)
                    softY++
            }
            n++
            if n > 8
                continue
            first := Trim(StrSplit(text, "`n")[1])
            head := SubStr(RegExReplace(first, "\d", "#"), 1, 24)
            head := StrReplace(StrReplace(head, "\", "/"), '"', "'")
            kw := keyword != "" ? StrReplace(keyword, '"', "'") : "-"
            piece := "look=" (looks ? 1 : 0) " qual=" (qualifies ? 1 : 0) " core=" core " blk=" kw " head=" head
            if rows = ""
                rows := piece
            else
                rows := rows " / " piece
        }
        AgentDbg("H7", "Harvester.ahk:_DebugClassify", "text_filter",
            '{"group":"' StrReplace(groupName, '"', "'")
            '","lookY":' lookY
            ',"lookN":' lookN
            ',"qualY":' qualY
            ',"blkN":' blkN
            ',"softY":' softY
            ',"candN":' blocks.Length
            ',"pickN":' pick["items"].Length
            ',"stopped":' (pick["stopped_on_seen"] ? 1 : 0)
            ',"rows":"' StrReplace(rows, "`n", " ") '"}')
    }
    ; #endregion

    _BuildCandidates(capture) {
        result := []
        messages := capture.Has("messages") && capture["messages"] is Array
            ? capture["messages"] : []
        if !messages.Length {
            text := capture.Has("text") ? capture["text"] : ""
            for block in ListingParser.SplitBlocks(
                text, this.config.ListingStartPattern,
                this.config.ImageMarkerPattern)
                result.Push(Map("text", block, "images", []))
            return result
        }

        for message in messages {
            if !(message is Map)
                continue
            text := message.Has("text") ? Trim(NormalizeNewlines(message["text"])) : ""
            if text = ""
                continue
            images := message.Has("images") && message["images"] is Array
                ? message["images"] : []
            parts := ListingParser.SplitBlocks(
                text, this.config.ListingStartPattern,
                this.config.ImageMarkerPattern)
            ; The web bridge already gives us one Zalo message at a time.
            ; Real listings often begin with a project name or an emoji not
            ; covered by the split-anchor regex. Keep that message boundary as
            ; a safe fallback after the listing heuristic accepts the text.
            if !parts.Length && ListingParser.LooksLikeListing(text)
                parts.Push(text)
            imageMarker := this.config.ImageMarkerPattern != ""
                ? this.config.ImageMarkerPattern
                : ListingParser.DEFAULT_IMAGE_MARKER
            urlDistributions := this._DistributeImagesToParts(
                parts, images, imageMarker)
            for index, part in parts {
                partImages := index <= urlDistributions.Length
                    ? urlDistributions[index] : []
                shareForward := message.Has("forward_eligible")
                    ? message["forward_eligible"] : false
                result.Push(Map(
                    "text", part,
                    "images", this._MergeUrls([], partImages),
                    "message_hash", message.Has("hash") ? message["hash"] : "",
                    "forward_eligible", shareForward
                        && partImages.Length > 0
                ))
            }
        }
        return result
    }

    _NormalizeImageGroups(message) {
        if !(message is Map) || !message.Has("image_groups")
            return []
        raw := message["image_groups"]
        if !(raw is Array)
            return []
        groups := []
        for item in raw {
            if !(item is Map)
                continue
            urls := []
            if item.Has("urls") && item["urls"] is Array {
                for url in item["urls"]
                    if Trim(String(url)) != ""
                        urls.Push(Trim(String(url)))
            }
            if !urls.Length
                continue
            mode := item.Has("mode") ? StrLower(Trim(String(item["mode"]))) : ""
            if mode != "single" && mode != "batch"
                mode := urls.Length > 1 ? "batch" : "single"
            groups.Push(Map("mode", mode, "urls", urls))
        }
        return groups
    }

    _FlattenGroupUrls(groups) {
        urls := []
        for group in groups {
            if !(group is Map) || !group.Has("urls")
                continue
            for url in group["urls"]
                urls.Push(url)
        }
        return urls
    }

    _DistributeGroupsToParts(parts, groups, imageMarker) {
        if !parts.Length
            return []
        if parts.Length = 1
            return [groups]

        distributions := []
        markerCounts := []
        totalMarkers := 0
        for part in parts {
            count := ListingParser.CountMatches(part, imageMarker)
            markerCounts.Push(count)
            totalMarkers += count
        }

        if totalMarkers = 0 {
            index := 1
            while index <= parts.Length {
                distributions.Push([])
                index++
            }
            groupIndex := 1
            for group in groups {
                target := groupIndex <= parts.Length ? groupIndex : parts.Length
                distributions[target].Push(group)
                groupIndex++
            }
            return distributions
        }

        for count in markerCounts
            distributions.Push([])

        groupIndex := 1
        for group in groups {
            assigned := false
            for index, count in markerCounts {
                if count > 0 && distributions[index].Length < count {
                    distributions[index].Push(group)
                    assigned := true
                    break
                }
            }
            if !assigned {
                lastWithMarkers := 0
                for index, count in markerCounts {
                    if count > 0
                        lastWithMarkers := index
                }
                target := lastWithMarkers > 0 ? lastWithMarkers : 1
                distributions[target].Push(group)
            }
            groupIndex++
        }
        return distributions
    }

    _MergeGroups(left, right) {
        result := []
        seenUrl := Map()
        for list in [left, right] {
            for group in list {
                if !(group is Map) || !group.Has("urls")
                    continue
                urls := []
                for url in group["urls"] {
                    value := Trim(String(url))
                    if value = "" || seenUrl.Has(value)
                        continue
                    seenUrl[value] := true
                    urls.Push(value)
                }
                if !urls.Length
                    continue
                mode := group.Has("mode") ? group["mode"] : "batch"
                if mode != "single" && mode != "batch"
                    mode := urls.Length > 1 ? "batch" : "single"
                result.Push(Map("mode", mode, "urls", urls))
            }
        }
        return result
    }

    _DistributeImagesToParts(parts, images, imageMarker) {
        if !parts.Length
            return []
        if parts.Length = 1
            return [images]

        distributions := []
        markerCounts := []
        totalMarkers := 0
        for part in parts {
            count := ListingParser.CountMatches(part, imageMarker)
            markerCounts.Push(count)
            totalMarkers += count
        }

        if totalMarkers = 0 {
            distributions.Push(images)
            index := 2
            while index <= parts.Length {
                distributions.Push([])
                index++
            }
            return distributions
        }

        urlIndex := 1
        for count in markerCounts {
            partImages := []
            Loop count {
                if urlIndex <= images.Length {
                    partImages.Push(images[urlIndex])
                    urlIndex++
                }
            }
            distributions.Push(partImages)
        }

        if urlIndex <= images.Length {
            lastWithMarkers := 0
            for index, count in markerCounts {
                if count > 0
                    lastWithMarkers := index
            }
            target := lastWithMarkers > 0 ? lastWithMarkers : 1
            while urlIndex <= images.Length {
                distributions[target].Push(images[urlIndex])
                urlIndex++
            }
        }
        return distributions
    }

    _MergeUrls(left, right) {
        result := []
        seen := Map()
        for list in [left, right] {
            for url in list {
                value := Trim(String(url))
                if value = "" || seen.Has(value)
                    continue
                seen[value] := true
                result.Push(value)
            }
        }
        return result
    }

    _CaptureHash(capture, fallbackText) {
        signatures := []
        if capture.Has("messages") && capture["messages"] is Array {
            for message in capture["messages"] {
                if !(message is Map)
                    continue
                text := message.Has("text") ? message["text"] : ""
                images := message.Has("images") && message["images"] is Array
                    ? StrJoin(message["images"], "|") : ""
                signatures.Push(text "|" images)
            }
        }
        payload := signatures.Length
            ? StrJoin(signatures, "`n---message---`n") : fallbackText
        ; Version the snapshot because older runs could persist this hash while
        ; dropping valid structured messages before they were marked seen.
        ; The prefix forces one safe rescan after upgrading.
        return FnvHash("structured-candidate-v2`n" payload)
    }

    _Log(message) {
        try FileAppend "[" NowStamp() "] " message "`n",
            this.config.QueueLogFile, "UTF-8-RAW"
    }
}
