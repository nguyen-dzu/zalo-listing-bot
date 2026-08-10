#Requires AutoHotkey v2.0
; GroupActivity.ahk — pure unread detection + bounded sequential harvest planning

#Include GroupRegistry.ahk

class GroupActivityDetector {
    ; Zalo may expose textual unread labels in copied group-list content.
    ; When it does not, scheduler audit shards guarantee eventual coverage.
    static DetectUnread(rawText, knownGroups, markerPattern) {
        lookup := Map()
        for group in knownGroups
            lookup[GroupRegistry._Key(group["group_name"])] := group["group_name"]

        lines := []
        for rawLine in StrSplit(NormalizeNewlines(rawText), "`n") {
            line := Trim(RegExReplace(rawLine, "\s+", " "))
            if line != ""
                lines.Push(line)
        }

        result := []
        seen := Map()
        for index, line in lines {
            key := GroupRegistry._Key(line)
            matchedKey := ""
            for candidateKey, candidateName in lookup {
                if key = candidateKey || InStr(key, candidateKey) {
                    if matchedKey = "" || StrLen(candidateKey) > StrLen(matchedKey)
                        matchedKey := candidateKey
                }
            }
            if matchedKey = ""
                continue

            context := line
            finish := Min(lines.Length, index + 4)
            cursor := index + 1
            while cursor <= finish {
                nextKey := GroupRegistry._Key(lines[cursor])
                startsNextGroup := false
                for candidateKey, candidateName in lookup {
                    if nextKey = candidateKey || InStr(nextKey, candidateKey) {
                        startsNextGroup := true
                        break
                    }
                }
                if startsNextGroup
                    break
                context .= (context = "" ? "" : "`n") lines[cursor]
                cursor++
            }
            if context = "" || !RegExMatch(context, markerPattern)
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
}

class HarvestScheduler {
    __New(config) {
        this.config := config
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
                if stamp < existingStamp {
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
