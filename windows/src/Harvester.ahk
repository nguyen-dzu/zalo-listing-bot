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
                result := this.HarvestGroup(group["group_name"])
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
                AgentDebugLog("Harvester.ahk:HarvestGroups", "harvest_group_error", Map(
                    "group", group["group_name"], "error", err.Message), "H2")
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

    HarvestGroup(groupName) {
        result := Map(
            "saved", 0, "blocked", 0, "duplicate", 0, "invalid", 0,
            "media_captured", 0, "media_failed", 0, "saved_records", []
        )

        this.ui.OpenGroup(groupName, "read")
        settle := this.config.HasProp("CaptureSettleMs") ? this.config.CaptureSettleMs : 600
        Sleep settle
        capture := this.ui.CaptureConversation()
        text := capture.Has("text") ? capture["text"] : ""
        normalized := NormalizeNewlines(text)
        ; #region agent log
        AgentDebugLog("Harvester.ahk:HarvestGroup", "capture_result", Map(
            "group", groupName,
            "textLen", StrLen(normalized),
            "msgCount", capture.Has("messages") ? capture["messages"].Length : 0,
            "scanGroup", capture.Has("group") ? capture["group"] : ""), "H3")
        ; #endregion
        if Trim(normalized) = ""
            return result

        candidates := this._BuildCandidates(capture)
        blocks := []
        candidateByHash := Map()
        for candidate in candidates {
            block := candidate["text"]
            hash := FnvHash(block)
            blocks.Push(block)
            if candidateByHash.Has(hash)
                candidateByHash[hash]["images"] := this._MergeUrls(
                    candidateByHash[hash]["images"], candidate["images"])
            else
                candidateByHash[hash] := candidate
        }
        this._Log("harvest_scan group=" groupName
            " messages=" (capture.Has("messages") ? capture["messages"].Length : 0)
            " candidates=" blocks.Length)

        captureHash := this._CaptureHash(capture, normalized)
        previousHash := this.state.GetCaptureHash(groupName)
        ; Conversation unchanged → already-read messages; skip re-copy/re-parse.
        if previousHash != "" && previousHash = captureHash {
            ; #region agent log
            AgentDebugLog("Harvester.ahk:HarvestGroup", "hash_skip", Map(
                "group", groupName, "captureHash", captureHash), "H4")
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
            this.config.MaxMessagesPerGroup)
        if pick["stopped_on_seen"]
            result["duplicate"]++

        for item in pick["items"] {
            block := item["block"]
            hash := item["hash"]
            candidate := candidateByHash.Has(hash)
                ? candidateByHash[hash] : Map("images", [])

            keyword := this.blockList.Match(block)
            if keyword != "" {
                this.state.MarkSeen(groupName, hash)
                result["blocked"]++
                continue
            }

            listing := ListingParser.Parse(block, this.config.ImageMarkerPattern)
            listing["image_urls"] := candidate["images"]
            listing["image_count"] := candidate["images"].Length
            if ListingParser.Validate(listing, this.config.RequiredFields).Length {
                this.state.MarkSeen(groupName, hash)
                result["invalid"]++
                continue
            }

            record := this.repo.SaveListing(listing, groupName, hash)
            this.state.MarkSeen(groupName, hash)
            result["saved"]++
            result["saved_records"].Push(record)
            ; #region agent log
            AgentDebugLog("Harvester.ahk:HarvestGroup", "listing_saved", Map(
                "group", groupName,
                "id", record["id"],
                "room", record.Has("room_code") ? record["room_code"] : "",
                "imageCount", record.Has("image_count") ? record["image_count"] : 0,
                "rawLen", record.Has("raw_text") ? StrLen(record["raw_text"]) : 0), "H5")
            ; #endregion
            if (this.mediaCapturer
                && this.config.AutoCapture
                && ((record.Has("image_count") && record["image_count"] > 0)
                    || this.config.AutoCaptureProbeImages)) {
                mediaOk := this.mediaCapturer.CaptureForRecord(groupName, record)
                ; #region agent log
                AgentDebugLog("Harvester.ahk:HarvestGroup", "media_capture", Map(
                    "group", groupName,
                    "id", record["id"],
                    "ok", mediaOk,
                    "imageCount", record.Has("image_count") ? record["image_count"] : 0), "H5")
                ; #endregion
                if mediaOk
                    result["media_captured"]++
                else
                    result["media_failed"]++
            }
        }

        this.state.TouchHarvest(groupName)
        this._Log("harvest_result group=" groupName
            " saved=" result["saved"]
            " blocked=" result["blocked"]
            " invalid=" result["invalid"]
            " media_ok=" result["media_captured"]
            " media_fail=" result["media_failed"])
        return result
    }

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
            for part in parts
                result.Push(Map("text", part, "images", this._MergeUrls([], images)))
        }
        return result
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
