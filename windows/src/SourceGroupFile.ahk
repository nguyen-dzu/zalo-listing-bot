#Requires AutoHotkey v2.0
; SourceGroupFile.ahk — startup picker + CSV/XLSX source-group loader.

#Include Util.ahk
#Include TableLoader.ahk
#Include GroupRegistry.ahk

class SourceGroupFile {
    static LoadNames(path, sheetName := "", preferredColumn := "group_name") {
        if !FileExist(path)
            throw Error("Khong tim thay file nhom input: " path)

        extension := StrLower(RegExReplace(path, "^.*\."))
        if extension != "csv" && extension != "xlsx" && extension != "xls"
            throw Error("Chi ho tro file .csv, .xlsx hoac .xls.")

        rows := TableLoader.LoadFile(path, sheetName)
        aliases := SourceGroupFile._ColumnAliases(preferredColumn)
        names := []
        seen := Map()
        for row in rows {
            if !SourceGroupFile._IsEnabledSourceRow(row)
                continue
            name := SourceGroupFile._NameFromRow(row, aliases)
            SourceGroupFile._PushUnique(names, seen, name)
        }

        ; CSV convenience: allow a one-column file without a header.
        if !names.Length && extension = "csv"
            names := SourceGroupFile._LoadHeaderlessCsv(path, aliases)

        if !names.Length
            throw Error(
                "File khong co ten nhom.`n"
                . "Can cot group_name (hoac group/name/ten_nhom) va moi dong mot nhom.")
        return names
    }

    static _ColumnAliases(preferredColumn) {
        aliases := []
        seen := Map()
        for name in [
            preferredColumn, "group_name", "group", "name",
            "ten_nhom", "tên nhóm", "nhom", "nhóm"
        ] {
            key := SourceGroupFile._HeaderKey(name)
            if key = "" || seen.Has(key)
                continue
            seen[key] := true
            aliases.Push(key)
        }
        return aliases
    }

    static _IsEnabledSourceRow(row) {
        if !(row is Map)
            return false
        enabled := ""
        type := ""
        for rawKey, value in row {
            key := SourceGroupFile._HeaderKey(rawKey)
            if key = "enabled"
                enabled := StrLower(Trim(String(value)))
            else if key = "type"
                type := StrLower(Trim(String(value)))
        }
        if enabled != ""
            && enabled != "1" && enabled != "true"
            && enabled != "yes" && enabled != "x"
            return false
        return type = "" || type = "source" || type = "input"
    }

    static _NameFromRow(row, aliases) {
        if !(row is Map)
            return ""
        for rawKey, value in row {
            key := SourceGroupFile._HeaderKey(rawKey)
            for alias in aliases {
                if key = alias
                    return Trim(String(value))
            }
        }
        return ""
    }

    static _LoadHeaderlessCsv(path, aliases) {
        names := []
        seen := Map()
        lines := StrSplit(NormalizeNewlines(ReadTextFile(path)), "`n")
        for index, line in lines {
            if Trim(line) = ""
                continue
            fields := TableLoader._SplitCsvLine(line)
            if !fields.Length
                continue
            value := Trim(fields[1])
            if index = 1 {
                headerKey := SourceGroupFile._HeaderKey(value)
                isHeader := false
                for alias in aliases {
                    if headerKey = alias {
                        isHeader := true
                        break
                    }
                }
                if isHeader
                    continue
            }
            SourceGroupFile._PushUnique(names, seen, value)
        }
        return names
    }

    static _PushUnique(names, seen, value) {
        clean := Trim(value)
        if clean = ""
            return false
        key := GroupRegistry._Key(clean)
        if seen.Has(key)
            return false
        seen[key] := true
        names.Push(clean)
        return true
    }

    static _HeaderKey(value) {
        key := StrLower(Trim(String(value)))
        key := StrReplace(key, " ", "_")
        return RegExReplace(key, "[^\p{L}\d_]+", "")
    }
}

class SourceGroupFilePicker {
    static Select(config) {
        picker := SourceGroupFilePicker(config)
        return picker.Show()
    }

    __New(config) {
        this.config := config
        this.selectedPath := ""
        this.lastPathFile := config.DataDir "\source-groups.last.txt"
        this.candidatePath := this._DefaultPath()
    }

    Show() {
        this.window := Gui("+AlwaysOnTop", "Chon file nhom input")
        this.window.SetFont("s10", "Segoe UI")
        this.window.AddText("w560",
            "Keo tha file CSV/Excel vao khung ben duoi, hoac bam Chon file.")
        this.dropArea := this.window.AddText(
            "xm w560 h100 Border Center 0x200",
            "THA FILE .CSV / .XLSX / .XLS VAO DAY")
        this.pathEdit := this.window.AddEdit("xm w450 ReadOnly", this.candidatePath)
        browse := this.window.AddButton("x+8 w100", "Chon file...")
        this.status := this.window.AddText("xm w560 cGray",
            "Cot mac dinh: " this.config.SourceGroupColumn)
        accept := this.window.AddButton("xm+345 w100 Default", "Bat dau")
        cancel := this.window.AddButton("x+10 w100", "Huy")

        browse.OnEvent("Click", ObjBindMethod(this, "_Browse"))
        accept.OnEvent("Click", ObjBindMethod(this, "_Accept"))
        cancel.OnEvent("Click", ObjBindMethod(this, "_Cancel"))
        this.window.OnEvent("DropFiles", ObjBindMethod(this, "_DropFiles"))
        this.window.OnEvent("Close", ObjBindMethod(this, "_Cancel"))
        this.window.OnEvent("Escape", ObjBindMethod(this, "_Cancel"))

        this.window.Show("AutoSize Center")
        WinWaitClose("ahk_id " this.window.Hwnd)
        return this.selectedPath
    }

    _Browse(*) {
        initial := this.candidatePath != ""
            ? this.candidatePath : this.config.Root
        selected := FileSelect(
            1, initial, "Chon danh sach nhom input",
            "Group files (*.csv; *.xlsx; *.xls)")
        if selected != ""
            this._SetCandidate(selected)
    }

    _DropFiles(guiObj, guiCtrl, files, x, y) {
        if files.Length
            this._SetCandidate(files[1])
    }

    _SetCandidate(path) {
        this.candidatePath := path
        this.pathEdit.Value := path
        try {
            names := SourceGroupFile.LoadNames(
                path, this.config.SourceGroupSheet,
                this.config.SourceGroupColumn)
            this.status.SetFont("c008000")
            this.status.Value := "Hop le: " names.Length " nhom input"
        } catch as err {
            this.status.SetFont("cRed")
            this.status.Value := err.Message
        }
    }

    _Accept(*) {
        try {
            names := SourceGroupFile.LoadNames(
                this.candidatePath, this.config.SourceGroupSheet,
                this.config.SourceGroupColumn)
        } catch as err {
            MsgBox err.Message, "File nhom input khong hop le", "Iconx"
            return
        }
        this.selectedPath := this.candidatePath
        WriteTextFile(this.lastPathFile, this.selectedPath)
        this.window.Destroy()
    }

    _Cancel(*) {
        this.selectedPath := ""
        this.window.Destroy()
    }

    _DefaultPath() {
        configured := Trim(this.config.SourceGroupFilePath)
        if configured != "" && FileExist(configured)
            return configured
        previous := Trim(ReadTextFile(this.lastPathFile))
        return previous != "" && FileExist(previous) ? previous : ""
    }
}
