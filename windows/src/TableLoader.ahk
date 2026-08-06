#Requires AutoHotkey v2.0
; TableLoader.ahk — Strategy: read a header/row table from .xlsx (Excel COM) or .csv fallback

class TableLoader {
    ; Returns array of Map(header -> value). Header keys are lower-cased and trimmed.
    static Load(xlsxPath, sheetName, csvPath) {
        if xlsxPath != "" && FileExist(xlsxPath) {
            try {
                return TableLoader._FromExcel(xlsxPath, sheetName)
            } catch as err {
                if csvPath = "" || !FileExist(csvPath)
                    throw Error("Đọc Excel thất bại và không có CSV dự phòng: " err.Message)
            }
        }
        if csvPath != "" && FileExist(csvPath)
            return TableLoader._FromCsv(csvPath)
        throw Error("Không tìm thấy bảng dữ liệu: " xlsxPath " hoặc " csvPath)
    }

    static _FromExcel(path, sheetName) {
        excel := ComObject("Excel.Application")
        excel.Visible := false
        excel.DisplayAlerts := false
        rows := []
        try {
            book := excel.Workbooks.Open(path, 0, true)
            sheet := sheetName != "" ? book.Worksheets(sheetName) : book.Worksheets(1)
            used := sheet.UsedRange
            rowCount := used.Rows.Count
            colCount := used.Columns.Count

            headers := []
            Loop colCount
                headers.Push(Trim(StrLower(String(sheet.Cells(1, A_Index).Text))))

            Loop rowCount - 1 {
                rowIndex := A_Index + 1
                record := Map()
                empty := true
                Loop colCount {
                    key := headers[A_Index]
                    if key = ""
                        continue
                    value := Trim(String(sheet.Cells(rowIndex, A_Index).Text))
                    record[key] := value
                    if value != ""
                        empty := false
                }
                if !empty
                    rows.Push(record)
            }
            book.Close(false)
        } finally {
            try excel.Quit()
        }
        return rows
    }

    static _FromCsv(path) {
        text := NormalizeNewlines(ReadTextFile(path))
        lines := StrSplit(text, "`n")
        rows := []
        headers := []

        for index, line in lines {
            if Trim(line) = ""
                continue
            fields := TableLoader._SplitCsvLine(line)
            if !headers.Length {
                for field in fields
                    headers.Push(Trim(StrLower(field)))
                continue
            }
            record := Map()
            empty := true
            for i, key in headers {
                if key = ""
                    continue
                value := i <= fields.Length ? Trim(fields[i]) : ""
                record[key] := value
                if value != ""
                    empty := false
            }
            if !empty
                rows.Push(record)
        }
        return rows
    }

    static _SplitCsvLine(line) {
        fields := []
        current := ""
        inQuote := false
        i := 1
        len := StrLen(line)

        while i <= len {
            c := SubStr(line, i, 1)
            if inQuote {
                if c = '"' {
                    if SubStr(line, i + 1, 1) = '"' {
                        current .= '"'
                        i += 2
                        continue
                    }
                    inQuote := false
                    i++
                    continue
                }
                current .= c
                i++
                continue
            }
            if c = '"' {
                inQuote := true
                i++
                continue
            }
            if c = "," {
                fields.Push(current)
                current := ""
                i++
                continue
            }
            current .= c
            i++
        }
        fields.Push(current)
        return fields
    }
}
