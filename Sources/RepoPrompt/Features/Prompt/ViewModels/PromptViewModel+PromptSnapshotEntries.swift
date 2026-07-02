import Foundation

extension PromptViewModel {
    @MainActor
    private func effectiveCodeMapUsageForChatPromptEntries() -> CodeMapUsage {
        let chatPreset = currentChatPreset()
        let context = resolvedPromptContext(from: chatPreset) ?? resolvePromptContext()
        return context.codeMapUsage
    }

    @MainActor
    func hasPromptSnapshotEntriesForChat() -> Bool {
        let selectionCount = fileManager.selectedFiles.count
        let codeMapUsage = effectiveCodeMapUsageForChatPromptEntries()

        switch codeMapUsage {
        case .none, .selected:
            return selectionCount > 0
        case .auto:
            return selectionCount > 0 || !fileManager.autoCodemapFiles.isEmpty
        case .complete:
            return selectionCount > 0 || !tokenCountingViewModel.codemapPresentation.orderedEntries.isEmpty
        }
    }

    @MainActor
    func promptSnapshotEntriesForChatCached() -> [PromptFileEntry] {
        let codeMapUsage = effectiveCodeMapUsageForChatPromptEntries()
        let key = ChatPromptEntriesCacheKey(
            codeMapUsage: codeMapUsage,
            selectionVersion: chatSelectionVersion,
            slicesVersion: chatSlicesVersion,
            autoCodemapVersion: chatAutoCodemapVersion,
            codemapAuthorityVersion: chatCodemapAuthorityVersion
        )

        if let cache = chatPromptEntriesCache, cache.key == key {
            return cache.entries
        }

        let entries = buildPromptSnapshotEntriesForCurrentChatProjection(codeMapUsage: codeMapUsage)
        chatPromptEntriesCache = (key: key, entries: entries)
        return entries
    }

    @MainActor
    private func buildPromptSnapshotEntriesForCurrentChatProjection(codeMapUsage: CodeMapUsage) -> [PromptFileEntry] {
        let selectedFiles = fileManager.selectedFiles
        let selectedIDs = Set(selectedFiles.map(\.id))
        let codemapEntries = tokenCountingViewModel.codemapPresentation.entriesByFileID
        var entries: [PromptFileEntry] = selectedFiles.map { file in
            PromptFileEntry(
                file: file,
                ranges: fileManager.selectionSlicesByFileID[file.id]
            )
        }

        for file in fileManager.autoCodemapFiles where !selectedIDs.contains(file.id) {
            entries.append(PromptFileEntry(file: file, codemap: codemapEntries[file.id]))
        }

        switch codeMapUsage {
        case .none:
            entries.removeAll { $0.isCodemap }
        case .auto:
            break
        case .selected:
            entries = entries.compactMap { entry in
                guard selectedIDs.contains(entry.file.id) else { return nil }
                let codemap = codemapEntries[entry.file.id]
                return PromptFileEntry(
                    file: entry.file,
                    codemap: codemap,
                    ranges: codemap == nil ? entry.ranges : nil
                )
            }
        case .complete:
            var existingIDs = Set(entries.map(\.file.id))
            for codemap in tokenCountingViewModel.codemapPresentation.orderedEntries {
                guard !existingIDs.contains(codemap.fileID),
                      let file = fileManager.allFilesSnapshot(sorted: false).first(where: { $0.id == codemap.fileID })
                else { continue }
                entries.append(PromptFileEntry(file: file, codemap: codemap, ranges: nil))
                existingIDs.insert(codemap.fileID)
            }
        }

        return entries
    }

    @MainActor
    func promptSnapshotEntriesForChat() -> [PromptFileEntry] {
        promptSnapshotEntriesForChatCached()
    }
}
