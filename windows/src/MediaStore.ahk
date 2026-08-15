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
                    return this._MediaFilesIn(generationDir)
            }
        }
        return this._MediaFilesIn(dir)
    }

    _MediaFilesIn(dir) {
        result := []
        bundle := ""
        joined := ""
        Loop Files dir "\*.*", "F" {
            if !RegExMatch(A_LoopFileName, "i)\.(?:clip|png|jpe?g|webp)$")
                continue
            if RegExMatch(A_LoopFileName, "i)^bundle\.") {
                bundle := A_LoopFileFullPath
                continue
            }
            joined .= (joined = "" ? "" : "`n") A_LoopFileFullPath
        }
        if bundle != ""
            result.Push(bundle)
        if joined = ""
            return result

        for path in StrSplit(Sort(joined), "`n") {
            if path != ""
                result.Push(path)
        }
        return result
    }

    PrepareArchive(listingId, append := false, extension := "clip") {
        listingDir := this.ListingDir(listingId)
        extension := StrLower(Trim(extension, " ."))
        if !RegExMatch(extension, "^(?:clip|png|jpg|jpeg|webp)$")
            extension := "png"
        baseGeneration := CompactStamp() "." ProcessExist() "." A_TickCount
        generation := baseGeneration
        generationDir := listingDir "\generations\" generation
        suffix := 0
        ; Replacement + append can execute within the same Windows timer tick.
        ; Never reuse an existing generation or FileCopy may target its source.
        while DirExist(generationDir) {
            suffix++
            generation := baseGeneration "." suffix
            generationDir := listingDir "\generations\" generation
        }
        EnsureDir(generationDir)

        if append {
            for sourcePath in this.FilesFor(listingId) {
                fileName := RegExReplace(sourcePath, "^.*\\", "")
                FileCopy sourcePath, generationDir "\" fileName, true
            }
        }

        targetPath := append
            ? this._NextNumberedInDir(generationDir, extension)
            : generationDir "\bundle." extension
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
        Loop Files prepared["listing_dir"] "\*.*", "F" {
            if RegExMatch(A_LoopFileName, "i)\.(?:clip|png|jpe?g|webp)$")
                try FileDelete A_LoopFileFullPath
        }
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

    _NextNumberedInDir(dir, extension := "clip") {
        index := 1
        Loop {
            path := dir "\" Format("{:03}", index) "." extension
            occupied := false
            Loop Files dir "\" Format("{:03}", index) ".*", "F" {
                occupied := true
                break
            }
            if !occupied
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

    ManifestPath(listingId) {
        return this.ListingDir(listingId) "\manifest.json"
    }

    WriteManifest(listingId, manifest) {
        WriteTextFile(this.ManifestPath(listingId), JSON.Stringify(manifest))
        return manifest
    }

    ReadManifest(listingId) {
        path := this.ManifestPath(listingId)
        if !FileExist(path)
            return 0
        try {
            parsed := JSON.Parse(ReadTextFile(path))
            return parsed is Map ? parsed : 0
        } catch {
            return 0
        }
    }

    IsTrusted(listingId) {
        manifest := this.ReadManifest(listingId)
        return this.HasMedia(listingId)
            && manifest
            && manifest.Has("capture_version")
            && manifest["capture_version"] >= 2
            && ((manifest.Has("validated_bitmap") && manifest["validated_bitmap"])
                || (manifest.Has("validated_file") && manifest["validated_file"]))
    }

    ; Legacy helper: one single group per archived file (publish ignores groups).
    ImageGroupsFor(listingId) {
        groups := []
        for path in this.RelativePaths(listingId)
            groups.Push(Map("mode", "single", "files", [path]))
        return groups
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
        Loop Files dir "\*.*", "F" {
            if RegExMatch(A_LoopFileName, "i)\.(?:clip|png|jpe?g|webp)$")
                FileDelete A_LoopFileFullPath
        }
        if FileExist(dir "\current.txt")
            FileDelete dir "\current.txt"
        if FileExist(dir "\manifest.json")
            FileDelete dir "\manifest.json"
        if DirExist(dir "\generations")
            DirDelete dir "\generations", true
    }
}
