#Requires AutoHotkey v2.0
; Simulate.ahk — chạy thử chu trình harvest → publish bằng file mẫu, KHÔNG đụng Zalo.
; Chạy: AutoHotkey64.exe windows\tests\Simulate.ahk
; Mỗi file windows\tests\samples\<Tên Nhóm>.txt được coi là hội thoại của nhóm nguồn đó.

#Include ../src/Util.ahk
#Include ../src/JSON.ahk
#Include ../src/TableLoader.ahk
#Include ../src/GroupRegistry.ahk
#Include ../src/BlockList.ahk
#Include ../src/Parser.ahk
#Include ../src/Composer.ahk

; AHK là app GUI-subsystem nên stdout có thể không hiện trên console — ghi kèm log file.
LogPath := A_ScriptDir "\Simulate.log"
try FileDelete LogPath

Out(text := "") {
    global LogPath
    try FileAppend text "`n", "*"
    FileAppend text "`n", LogPath, "UTF-8-RAW"
}

class SimConfig {
    Separator := "------------{group}------------"
    MaxMessageChars := 1800
    MaskPhone := true
    PhoneHint := 'Nhắn bot "SĐT {room_code}" để lấy số'
    BlocklistSheet := "Blocklist"
    GroupsSheet := "Groups"
    BlocklistXlsx := ""
    GroupsXlsx := ""
    BlocklistCsv := ""
    GroupsCsv := ""
    RequiredFields := ["address", "price", "owner_phone"]

    __New(root) {
        this.GroupsXlsx := SimConfig.Pick(root "\config\zalo-groups.xlsx", "")
        this.BlocklistXlsx := this.GroupsXlsx
        this.GroupsCsv := SimConfig.Pick(root "\config\groups.csv", root "\config\groups.example.csv")
        this.BlocklistCsv := SimConfig.Pick(root "\config\blocklist.csv", root "\config\blocklist.example.csv")
    }

    static Pick(primary, fallback) {
        return FileExist(primary) ? primary : fallback
    }
}

Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
SamplesDir := A_ScriptDir "\samples"
cfg := SimConfig(Root)
groupCatalog := GroupRegistry(cfg)
blockedWords := BlockList(cfg)
composerSvc := MessageComposer(cfg)

sourceNames := []
for group in groupCatalog.SourceGroups()
    sourceNames.Push(group["group_name"])
mainNames := []
for group in groupCatalog.MainGroups()
    mainNames.Push(group["group_name"])
keywords := []
for rule in blockedWords.rules
    keywords.Push(rule["keyword"])

Out("== Cấu hình ==")
Out("Nhóm nguồn : " (sourceNames.Length ? StrJoin(sourceNames, ", ") : "(trống)"))
Out("Nhóm chính : " (mainNames.Length ? StrJoin(mainNames, ", ") : "(trống)"))
Out("Từ khoá cấm: " (keywords.Length ? StrJoin(keywords, ", ") : "(trống)"))
Out()

records := []
seen := Map()
saved := 0, blocked := 0, duplicate := 0, invalid := 0, totalImages := 0

for name in sourceNames {
    dumpPath := SamplesDir "\" name ".txt"
    if !FileExist(dumpPath) {
        Out("-- " name ": không có file mẫu (" name ".txt), bỏ qua")
        continue
    }

    blocks := ListingParser.SplitBlocks(ReadTextFile(dumpPath))
    Out("-- " name ": " blocks.Length " tin thô")

    for block in blocks {
        hash := FnvHash(block)
        if seen.Has(hash) {
            duplicate++
            Out("   [TRÙNG] " hash)
            continue
        }
        seen[hash] := true

        keyword := blockedWords.Match(block)
        if keyword != "" {
            blocked++
            Out("   [CẤM  ] " hash " — từ khoá: " keyword)
            continue
        }

        listing := ListingParser.Parse(block)
        errors := ListingParser.Validate(listing, cfg.RequiredFields)
        if errors.Length {
            invalid++
            Out("   [THIẾU] " hash " — " StrJoin(errors, ", "))
            continue
        }

        listing["id"] := hash
        listing["source_group"] := name
        records.Push(listing)
        totalImages += listing["image_count"]
        saved++
        Out("   [LƯU  ] " hash " — "
            . (listing["room_code"] != "" ? listing["room_code"] : listing["address"])
            . " (" listing["image_count"] " ảnh)")
    }
}

Out()
Out("== Thống kê ==")
Out("Lưu mới: " saved " | Cấm: " blocked " | Trùng: " duplicate " | Thiếu field: " invalid)
Out()

chunks := composerSvc.Compose(records)
Out("== Sẽ gửi vào nhóm chính ==")
Out("Bước 1: chuyển " totalImages " ảnh (hotkey RelayImages)")
Out("Bước 2: " chunks.Length " message text")
for index, chunk in chunks {
    Out()
    Out("----- MESSAGE " index "/" chunks.Length " (" StrLen(chunk) " ký tự) -----")
    Out(chunk)
}

ExitApp 0