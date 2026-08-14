#Requires AutoHotkey v2.0
; GroupActivity.ahk — pure unread detection + bounded sequential harvest planning

#Include GroupRegistry.ahk

class GroupActivityDetector {
    ; Bare unread badge numbers Zalo Acc often exposes without "tin nhắn mới".
    static BADGE_NUMBER_PATTERN := "i)(?:^|\s)([1-9]\d{0,2})(?:\s|$)"

    ; Zalo may expose textual unread labels or bare numeric badges in the
    ; conversation list. When it does not, scheduler audit shards still cover.
    static DetectUnread(rawText, knownGroups, markerPattern) {
        lookup := GroupActivityDetector._KnownLookup(knownGroups)

        lines := []
        for rawLine in StrSplit(NormalizeNewlines(rawText), "`n") {
            line := Trim(RegExReplace(rawLine, "\s+", " "))
            if line != ""
                lines.Push(line)
        }

        result := []
        seen := Map()
        for index, line in lines {
            matchedKey := GroupActivityDetector._MatchKnownKey(line, lookup)
            if matchedKey = ""
                continue

            context := line
            finish := Min(lines.Length, index + 4)
            cursor := index + 1
            while cursor <= finish {
                nextKey := GroupActivityDetector._MatchKnownKey(lines[cursor], lookup)
                if nextKey != ""
                    break
                context .= "`n" lines[cursor]
                cursor++
            }
            if !GroupActivityDetector.LooksLikeUnread(context, markerPattern)
                continue

            name := lookup[matchedKey]
            nameKey := GroupRegistry._Key(name)
            if seen.Has(nameKey)
                continue
            seen[nameKey] := true
            result.Push(name)
        }
        return result
    }

    ; Structured Acc items: Map("name", groupOrLabel, "badge", "3"|"" , "text", …).
    static DetectUnreadFromItems(items, knownGroups, markerPattern) {
        lookup := GroupActivityDetector._KnownLookup(knownGroups)
        result := []
        seen := Map()
        for item in items {
            if !(item is Map)
                continue
            nameHint := item.Has("name") ? String(item["name"]) : ""
            badge := item.Has("badge") ? String(item["badge"]) : ""
            extra := item.Has("text") ? String(item["text"]) : ""
            context := Trim(nameHint
                . (badge != "" ? "`n" badge : "")
                . (extra != "" ? "`n" extra : ""))
            if context = ""
                continue

            matchedKey := GroupActivityDetector._MatchKnownKey(nameHint, lookup)
            if matchedKey = ""
                matchedKey := GroupActivityDetector._MatchKnownKey(context, lookup)
            if matchedKey = ""
                continue
            if !GroupActivityDetector.LooksLikeUnread(context, markerPattern)
                && !GroupActivityDetector.IsUnreadBadge(badge)
                continue

            name := lookup[matchedKey]
            nameKey := GroupRegistry._Key(name)
            if seen.Has(nameKey)
                continue
            seen[nameKey] := true
            result.Push(name)
        }
        return result
    }

    static LooksLikeUnread(context, markerPattern) {
        if Trim(context) = ""
            return false
        if markerPattern != "" && RegExMatch(context, markerPattern)
            return true
        ; Same-line: "Nhóm A 3" or "Nhóm A 3 tin nhắn mới"
        if RegExMatch(context, "i).+\s([1-9]\d{0,2})(?:\s|$)")
            return true
        ; Multi-line: group name then a bare badge number on its own line.
        for line in StrSplit(NormalizeNewlines(context), "`n") {
            if GroupActivityDetector.IsUnreadBadge(line)
                return true
        }
        return false
    }

    static IsUnreadBadge(value) {
        text := Trim(RegExReplace(String(value), "\s+", " "))
        if text = ""
            return false
        ; Pure 1–999 badge (Zalo unread count).
        if RegExMatch(text, "^[1-9]\d{0,2}$")
            return true
        return false
    }

    static ExtractBadge(text) {
        clean := Trim(RegExReplace(String(text), "\s+", " "))
        if GroupActivityDetector.IsUnreadBadge(clean)
            return clean
        if RegExMatch(clean,
            "i)(?:^|\s)([1-9]\d{0,2})\s*(?:tin nhắn mới|tin chưa đọc|chưa đọc|unread|new messages?)",
            &found)
            return found[1]
        if RegExMatch(clean, "i)\s([1-9]\d{0,2})$", &found)
            return found[1]
        return ""
    }

    ; Keep the source-file order while selecting only names marked unread.
    static SelectUnreadGroups(groups, unreadNames) {
        unreadKeys := Map()
        for name in unreadNames
            unreadKeys[GroupRegistry._Key(name)] := true
        result := []
        for group in groups {
            key := GroupRegistry._Key(group["group_name"])
            if unreadKeys.Has(key)
                result.Push(group)
        }
        return result
    }

    static _KnownLookup(knownGroups) {
        lookup := Map()
        for group in knownGroups
            lookup[GroupRegistry._Key(group["group_name"])] := group["group_name"]
        return lookup
    }

    static _MatchKnownKey(text, lookup) {
        key := GroupRegistry._Key(text)
        if key = ""
            return ""
        matchedKey := ""
        for candidateKey, candidateName in lookup {
            if key = candidateKey || InStr(key, candidateKey) {
                if matchedKey = "" || StrLen(candidateKey) > StrLen(matchedKey)
                    matchedKey := candidateKey
            }
        }
        ; Also allow "Group Name 3" by stripping trailing badge before match.
        if matchedKey = "" {
            stripped := Trim(RegExReplace(
                String(text),
                "i)\s+[1-9]\d{0,2}(?:\s*(?:tin nhắn mới|tin chưa đọc|chưa đọc|unread|new messages?))?$",
                ""))
            if stripped != "" && stripped != text
                return GroupActivityDetector._MatchKnownKey(stripped, lookup)
        }
        return matchedKey
    }
}

; Newest-first message walk for harvest: stop when hitting an already-seen hash.
class MessageActivityScanner {
    ; isSeenFn(hash) -> true if already processed.
    ; blocks: oldest-first array (index 1 = oldest, Length = newest).
    static PickUnseenNewestFirst(blocks, isSeenFn, maxMessages) {
        items := []
        stoppedOnSeen := false
        index := blocks.Length
        while index >= 1 {
            block := blocks[index]
            hash := FnvHash(block)
            if isSeenFn.Call(hash) {
                stoppedOnSeen := true
                break
            }
            if items.Length >= maxMessages
                break
            items.Push(Map("index", index, "hash", hash, "block", block))
            index--
        }
        return Map("items", items, "stopped_on_seen", stoppedOnSeen)
    }
}

class HarvestScheduler {
    __New(config) {
        this.config := config
    }

    ; 24/7: every cycle walks every source group. Unread names are only
    ; reordered to the front; they never replace the rest of the list.
    BuildContinuousPlan(groups, unreadNames := 0) {
        if !groups.Length
            return Map("mode", "empty", "groups", [], "unread", 0, "audit", 0)

        selected := []
        selectedKeys := Map()
        unreadCount := 0
        if unreadNames {
            groupLookup := Map()
            for group in groups
                groupLookup[GroupRegistry._Key(group["group_name"])] := group
            for name in unreadNames {
                key := GroupRegistry._Key(name)
                if !groupLookup.Has(key) || selectedKeys.Has(key)
                    continue
                this._PushUnique(selected, selectedKeys, groupLookup[key])
                unreadCount++
            }
        }
        for group in groups
            this._PushUnique(selected, selectedKeys, group)

        return Map(
            "mode", "continuous",
            "groups", selected,
            "unread", unreadCount,
            "audit", 0
        )
    }

    BuildPlan(groups, state, unreadNames := 0) {
        if !groups.Length
            return Map("mode", "empty", "groups", [], "unread", 0, "audit", 0)

        hasAnyHarvest := false
        unharvested := []
        for group in groups {
            stamp := state.LastHarvestAt(group["group_name"])
            if stamp = ""
                unharvested.Push(group)
            else
                hasAnyHarvest := true
        }

        ; First-ever cycle establishes a complete baseline as requested.
        if !hasAnyHarvest && this.config.HarvestInitialFullScan
            return Map(
                "mode", "baseline",
                "groups", this._Copy(groups),
                "unread", 0,
                "audit", 0
            )

        selected := []
        selectedKeys := Map()
        for group in unharvested
            this._PushUnique(selected, selectedKeys, group)

        unreadCount := 0
        if unreadNames {
            groupLookup := Map()
            for group in groups
                groupLookup[GroupRegistry._Key(group["group_name"])] := group
            for name in unreadNames {
                key := GroupRegistry._Key(name)
                if !groupLookup.Has(key) || selectedKeys.Has(key)
                    continue
                this._PushUnique(selected, selectedKeys, groupLookup[key])
                unreadCount++
            }
        }

        auditCount := 0
        auditCandidates := this._Oldest(
            groups, state, this.config.HarvestAuditGroupsPerCycle,
            selectedKeys)
        for group in auditCandidates {
            key := GroupRegistry._Key(group["group_name"])
            this._PushUnique(selected, selectedKeys, group)
            auditCount++
        }

        while selected.Length > this.config.HarvestMaxGroupsPerCycle
            selected.Pop()

        return Map(
            "mode", unharvested.Length ? "new_groups" : "incremental",
            "groups", selected,
            "unread", unreadCount,
            "audit", auditCount
        )
    }

    ; Keep only K oldest entries: O(group_count × K), not O(group_count²).
    _Oldest(groups, state, limit, excludedKeys) {
        if limit <= 0
            return []
        oldest := []
        for group in groups {
            key := GroupRegistry._Key(group["group_name"])
            if excludedKeys.Has(key)
                continue
            stamp := state.LastHarvestAt(group["group_name"])
            inserted := false
            for index, existing in oldest {
                existingStamp := state.LastHarvestAt(existing["group_name"])
                ; AHK v2 relational operators are numeric. Harvest timestamps are
                ; fixed-width sortable strings (yyyy-MM-dd HH:mm:ss), so compare
                ; them explicitly as strings to avoid a type error.
                if StrCompare(String(stamp), String(existingStamp)) < 0 {
                    oldest.InsertAt(index, group)
                    inserted := true
                    break
                }
            }
            if !inserted
                oldest.Push(group)
            if oldest.Length > limit
                oldest.Pop()
        }
        return oldest
    }

    _PushUnique(result, lookup, group) {
        key := GroupRegistry._Key(group["group_name"])
        if lookup.Has(key)
            return false
        lookup[key] := true
        result.Push(group)
        return true
    }

    _Copy(items) {
        result := []
        for item in items
            result.Push(item)
        return result
    }
}
