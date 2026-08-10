#Requires AutoHotkey v2.0
; MediaStore.ahk — paths and metadata for native ClipboardAll archives

class ListingMediaStore {
    __New(config) {
        this.config := config
        this.root := config.MediaDir
        EnsureDir(this.root)
    }

    ListingDir(listingId) {
        safe := RegExReplace(listingId, "[^A-Za-z0-9_.-]", "_")
        return EnsureDir(this.root "\" safe)
    }

    BundlePath(listingId) {
        return this.ListingDir(listingId) "\bundle.clip"
    }

    NumberedPath(listingId, index) {
        return this.ListingDir(listingId) "\" Format("{:03}", index) ".clip"
    }

    FilesFor(listingId) {
        dir := this.ListingDir(listingId)
        currentFile := dir "\current.txt"
        if FileExist(currentFile) {
            generation := Trim(ReadTextFile(currentFile))
            if RegExMatch(generation, "^[A-Za-z0-9_.-]+$") {
                generationDir := dir "\generations\" generation
                if DirExist(generationDir)
                    return this._ClipFilesIn(generationDir)
            }
        }
        return this._ClipFilesIn(dir)
    }

    _ClipFilesIn(dir) {
        bundle := dir "\bundle.clip"
        result := []
        if FileExist(bundle)
            result.Push(bundle)
        joined := ""
        Loop Files dir "\*.clip", "F" {
            if A_LoopFileName = "bundle.clip"
                continue
            joined .= (joined = "" ? "" : "`n") A_LoopFileFullPath
        }
        if joined = ""
            return result

        for path in StrSplit(Sort(joined), "`n") {
            if path != ""
                result.Push(path)
        }
        return result
    }

    PrepareArchive(listingId, append := false) {
        listingDir := this.ListingDir(listingId)
        generation := CompactStamp() "." A_Pid "." A_TickCount
        generationDir := EnsureDir(
            listingDir "\generations\" generation)

        if append {
            for sourcePath in this.FilesFor(listingId) {
                fileName := RegExReplace(sourcePath, "^.*\\", "")
                FileCopy sourcePath, generationDir "\" fileName, true
            }
        }

        targetPath := append
            ? this._NextNumberedInDir(generationDir)
            : generationDir "\bundle.clip"
        return Map(
            "listing_id", listingId,
            "listing_dir", listingDir,
            "generation", generation,
            "generation_dir", generationDir,
            "temp_path", generationDir "\incoming.tmp",
            "target_path", targetPath
        )
    }

    CommitGeneration(prepared) {
        tempPath := prepared["temp_path"]
        targetPath := prepared["target_path"]
        if !FileExist(tempPath) || FileGetSize(tempPath) <= 0
            throw Error("Archive tạm rỗng hoặc không tồn tại.")
        FileMove tempPath, targetPath, 1
        WriteTextFile(
            prepared["listing_dir"] "\current.txt",
            prepared["generation"])
        Loop Files prepared["listing_dir"] "\*.clip", "F"
            try FileDelete A_LoopFileFullPath
        this._CleanupOldGenerations(
            prepared["listing_dir"], prepared["generation"])
        return targetPath
    }

    AbortGeneration(prepared) {
        currentPath := prepared["listing_dir"] "\current.txt"
        current := FileExist(currentPath) ? Trim(ReadTextFile(currentPath)) : ""
        if current != prepared["generation"]
            && DirExist(prepared["generation_dir"])
            DirDelete prepared["generation_dir"], true
    }

    _NextNumberedInDir(dir) {
        index := 1
        Loop {
            path := dir "\" Format("{:03}", index) ".clip"
            if !FileExist(path)
                return path
            index++
        }
    }

    _CleanupOldGenerations(listingDir, currentGeneration) {
        generationsDir := listingDir "\generations"
        if !DirExist(generationsDir)
            return
        Loop Files generationsDir "\*", "D" {
            if A_LoopFileName != currentGeneration
                try DirDelete A_LoopFileFullPath, true
        }
    }

    HasMedia(listingId) {
        return this.FilesFor(listingId).Length > 0
    }

    RelativePaths(listingId) {
        result := []
        prefix := this.root "\"
        for path in this.FilesFor(listingId)
            result.Push(SubStr(path, 1, StrLen(prefix)) = prefix
                ? SubStr(path, StrLen(prefix) + 1) : path)
        return result
    }

    MetadataFor(listingId) {
        result := []
        paths := this.FilesFor(listingId)
        relative := this.RelativePaths(listingId)
        for index, path in paths
            result.Push(Map(
                "path", relative[index],
                "size", FileGetSize(path)
            ))
        return result
    }

    Resolve(relativeOrAbsolute) {
        if RegExMatch(relativeOrAbsolute, "^[A-Za-z]:\\")
            return relativeOrAbsolute
        return this.root "\" relativeOrAbsolute
    }

    DeleteFor(listingId) {
        dir := this.ListingDir(listingId)
        Loop Files dir "\*.clip", "F"
            FileDelete A_LoopFileFullPath
        if FileExist(dir "\current.txt")
            FileDelete dir "\current.txt"
        if DirExist(dir "\generations")
            DirDelete dir "\generations", true
    }
}
