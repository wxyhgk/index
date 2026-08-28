import AppKit
import IndexSearchCore
import InputMethodKit

// InputMethodKit session 与键盘事件是输入法 target 的平台边界。

/// InputMethodKit shell for AOSP PinyinIME composition plus Index local search.
@objc(IndexSearchInputController)
final class IndexSearchInputController: IMKInputController {
    private static let coordinator = IndexInputSearchCoordinator()

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ maybeEvent: NSEvent!, client: Any!) -> Bool {
        guard let event = maybeEvent else { return false }
        let textClient = client as? IMKTextInput
        if event.type == .flagsChanged {
            Self.coordinator.consumeModifierFlags(event, client: textClient)
            return false
        }
        guard event.type == .keyDown else { return false }
        return Self.coordinator.consume(event, client: textClient)
    }

    override func deactivateServer(_ sender: Any!) {
        Self.coordinator.reset()
        super.deactivateServer(sender)
    }

    override func hidePalettes() {
        Self.coordinator.hide()
        super.hidePalettes()
    }

    override func inputControllerWillClose() {
        Self.coordinator.reset()
        super.inputControllerWillClose()
    }
}

private final class IndexInputSearchCoordinator {
    private static let languageModeDefaultsKey = "IndexInputMethod.languageMode"

    private struct SearchBatch: Sendable {
        let results: [IndexSearchResult]
        let navigationQuery: String
    }

    private var buffer = InputQueryBuffer()
    private let decoder = AOSPPinyinDecoder()
    private let pinyinPanel = PinyinCandidatePanelController()
    private let modeIndicator = InputLanguageModeIndicatorController()
    private var shiftSwitch = ShiftLanguageSwitchState()
    private var languageMode: InputLanguageMode
    private var composition = ""
    private var pinyinCandidates: [String] = []
    private var candidatePagination = CandidatePagination()
    private var activeClient: IMKTextInput?
    private var generation = 0
    private var activeSearchSignature: String?
    private var searchTask: Task<Void, Never>?
    private var repository: IndexSearchRepository?
    private var didLogRepositoryError = false
    private let panel = IndexSearchCandidatePanelController()

    init() {
        languageMode = UserDefaults.standard.string(forKey: Self.languageModeDefaultsKey)
            .flatMap(InputLanguageMode.init(rawValue:)) ?? .chinese
        pinyinPanel.onSelect = { [weak self] index in
            self?.commitCandidate(at: index)
        }
        pinyinPanel.onPreviousPage = { [weak self] in
            self?.moveCandidatePage(by: -1)
        }
        pinyinPanel.onNextPage = { [weak self] in
            self?.moveCandidatePage(by: 1)
        }
    }

    func consumeModifierFlags(_ event: NSEvent, client: IMKTextInput?) {
        let blockingModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        let shouldToggle = shiftSwitch.flagsChanged(
            shiftIsDown: event.modifierFlags.contains(.shift),
            hasBlockingModifiers: !event.modifierFlags.intersection(blockingModifiers).isEmpty
        )
        guard shouldToggle else { return }
        toggleLanguageMode(client: client)
    }

    func consume(_ event: NSEvent, client: IMKTextInput?) -> Bool {
        shiftSwitch.noteKeyDown()

        if languageMode == .english {
            consumeForSearch(event, client: client)
            return false
        }

        guard decoder.isAvailable else {
            consumeForSearch(event, client: client)
            return false
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }

        if !composition.isEmpty {
            switch event.keyCode {
            case 51, 117:
                composition.removeLast()
                if composition.isEmpty {
                    cancelComposition()
                } else {
                    updateComposition(client: client)
                }
                return true
            case 49: // Space commits the highlighted Chinese candidate.
                commitCandidate(at: candidatePagination.selectedIndex, client: client)
                return true
            case 18...29: // Number row; non-number keys in this key-code span fall through.
                if let number = event.charactersIgnoringModifiers?.first?.wholeNumberValue,
                   let candidateIndex = candidatePagination.absoluteIndex(forNumber: number) {
                    commitCandidate(at: candidateIndex, client: client)
                    return true
                }
            case 123:
                moveSelection(by: -1, client: client)
                return true
            case 124:
                moveSelection(by: 1, client: client)
                return true
            case 116, 126: // Page Up / Up Arrow moves to the previous candidate page.
                moveCandidatePage(by: -1, client: client)
                return true
            case 121, 125: // Page Down / Down Arrow moves to the next candidate page.
                moveCandidatePage(by: 1, client: client)
                return true
            case 36, 76: // Return commits raw pinyin, matching common IME behavior.
                commitRawPinyin(client: client)
                return true
            case 53:
                cancelComposition(client: client)
                return true
            default:
                break
            }
        }

        let disallowedTextModifiers: NSEvent.ModifierFlags = [.shift, .capsLock]
        if event.modifierFlags.intersection(disallowedTextModifiers).isEmpty,
           let text = event.charactersIgnoringModifiers?.lowercased(),
           text.count == 1,
           text.first.map({ $0.isLetter || $0 == "'" }) == true {
            composition.append(text)
            activeClient = client
            updateComposition(client: client)
            return true
        }

        if !composition.isEmpty {
            // Punctuation first commits the current Chinese candidate, then the client
            // receives the original punctuation event normally.
            commitCandidate(at: candidatePagination.selectedIndex, client: client)
        }
        consumeForSearch(event, client: client)
        return false
    }

    private func consumeForSearch(_ event: NSEvent, client: IMKTextInput?) {
        let command = command(for: event)
        guard command != .ignore else { return }
        guard let query = buffer.consume(command) else {
            cancelAndHide()
            return
        }

        let caret = caretFrame(client: client)
        scheduleSearch(query: query, caretFrame: caret)
    }

    func reset() {
        cancelComposition(client: activeClient)
        buffer.clear()
        shiftSwitch.reset()
        modeIndicator.hide()
        cancelAndHide()
    }

    func hide() {
        pinyinPanel.hide()
        modeIndicator.hide()
        cancelAndHide()
    }

    private func toggleLanguageMode(client: IMKTextInput?) {
        let nextMode = languageMode.toggled

        if languageMode == .chinese, !composition.isEmpty {
            // 用户很可能刚在中文模式误输了英文：只保留当前原始拉丁字母。
            buffer.clear()
            commitRawPinyin(client: client)
        } else {
            buffer.clear()
            pinyinPanel.hide()
            cancelAndHide()
        }

        languageMode = nextMode
        UserDefaults.standard.set(nextMode.rawValue, forKey: Self.languageModeDefaultsKey)
        modeIndicator.show(mode: nextMode, caretFrame: caretFrame(client: client))
    }

    private func updateComposition(client: IMKTextInput?) {
        guard !composition.isEmpty else {
            cancelComposition(client: client)
            return
        }
        pinyinCandidates = decoder.candidates(for: composition)
        candidatePagination.reset(itemCount: pinyinCandidates.count)
        client?.setMarkedText(
            composition,
            selectionRange: NSRange(location: composition.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        if pinyinCandidates.isEmpty {
            pinyinPanel.hide()
        } else {
            pinyinPanel.show(
                candidates: pinyinCandidates,
                pagination: candidatePagination,
                caretFrame: caretFrame(client: client)
            )
        }
        scheduleCompositionSearch(client: client)
    }

    private func moveSelection(by delta: Int, client: IMKTextInput?) {
        guard !pinyinCandidates.isEmpty else { return }
        candidatePagination.moveSelection(by: delta)
        pinyinPanel.show(
            candidates: pinyinCandidates,
            pagination: candidatePagination,
            caretFrame: caretFrame(client: client)
        )
    }

    private func moveCandidatePage(by delta: Int, client: IMKTextInput? = nil) {
        guard !pinyinCandidates.isEmpty else { return }
        candidatePagination.movePage(by: delta)
        pinyinPanel.show(
            candidates: pinyinCandidates,
            pagination: candidatePagination,
            caretFrame: caretFrame(client: client ?? activeClient)
        )
    }

    private func commitCandidate(at index: Int, client: IMKTextInput? = nil) {
        let targetClient = client ?? activeClient
        guard pinyinCandidates.indices.contains(index) else {
            commitRawPinyin(client: targetClient)
            return
        }
        let text = pinyinCandidates[index]
        decoder.choose(index)
        targetClient?.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        finishComposition()
        if let query = buffer.consume(.text(text)) {
            scheduleSearch(query: query, caretFrame: caretFrame(client: targetClient))
        }
    }

    private func commitRawPinyin(client: IMKTextInput?) {
        guard !composition.isEmpty else { return }
        let raw = composition
        client?.insertText(
            raw,
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        finishComposition()
        if let query = buffer.consume(.text(raw)) {
            scheduleSearch(query: query, caretFrame: caretFrame(client: client))
        }
    }

    private func cancelComposition(client: IMKTextInput? = nil) {
        (client ?? activeClient)?.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        finishComposition()
        cancelAndHide()
    }

    private func finishComposition() {
        composition = ""
        pinyinCandidates = []
        candidatePagination.reset(itemCount: 0)
        activeClient = nil
        decoder.reset()
        pinyinPanel.hide()
    }

    private func scheduleCompositionSearch(client: IMKTextInput?) {
        let queries = InputSearchQueryPlanner.queries(
            composition: composition,
            pinyinCandidates: pinyinCandidates
        )
        guard !queries.isEmpty else {
            cancelAndHide()
            return
        }
        let caret = caretFrame(client: client)
        scheduleSearch(
            queries: queries,
            displayQuery: composition,
            caretFrame: pinyinPanel.searchAnchorFrame(fallback: caret)
        )
    }

    private func scheduleSearch(query: String, caretFrame: NSRect) {
        scheduleSearch(queries: [query], displayQuery: query, caretFrame: caretFrame)
    }

    private func scheduleSearch(
        queries rawQueries: [String],
        displayQuery: String,
        caretFrame: NSRect
    ) {
        var seen = Set<String>()
        let queries = rawQueries.compactMap { raw -> String? in
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, seen.insert(query).inserted else { return nil }
            return query
        }
        guard !queries.isEmpty else {
            cancelAndHide()
            return
        }
        generation += 1
        let activeGeneration = generation
        let signature = queries.joined(separator: "\u{1F}")
        activeSearchSignature = signature
        searchTask?.cancel()

        let repository: IndexSearchRepository
        do {
            if let existing = self.repository {
                repository = existing
            } else {
                let created = try IndexSearchRepository()
                self.repository = created
                repository = created
            }
        } catch {
            panel.hide()
            if !didLogRepositoryError {
                didLogRepositoryError = true
                NSLog("[IndexInputMethod] \(error.localizedDescription)")
            }
            return
        }

        searchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            let batch = await Task.detached(priority: .userInitiated) {
                var merged: [String: (
                    result: IndexSearchResult,
                    weightedScore: Int,
                    sourceQuery: String
                )] = [:]
                for (queryIndex, query) in queries.enumerated() {
                    let queryResults = (try? repository.search(query, limit: 6)) ?? []
                    for result in queryResults {
                        let weightedScore = result.score + (queryIndex == 0 ? 12 : 0)
                        if merged[result.id]?.weightedScore ?? Int.min < weightedScore {
                            merged[result.id] = (result, weightedScore, query)
                        }
                    }
                }
                let ranked = merged.values
                    .sorted {
                        if $0.weightedScore != $1.weightedScore {
                            return $0.weightedScore > $1.weightedScore
                        }
                        return $0.result.capturedAt > $1.result.capturedAt
                    }
                    .prefix(6)
                return SearchBatch(
                    results: ranked.map(\.result),
                    navigationQuery: ranked.first?.sourceQuery ?? displayQuery
                )
            }.value
            guard let self,
                  !Task.isCancelled,
                  activeGeneration == self.generation,
                  self.activeSearchSignature == signature
            else { return }

            if batch.results.isEmpty {
                self.panel.hide()
            } else {
                self.panel.show(
                    results: batch.results,
                    query: displayQuery,
                    navigationQuery: batch.navigationQuery,
                    caretFrame: caretFrame
                )
            }
        }
    }

    private func cancelAndHide() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        activeSearchSignature = nil
        panel.hide()
    }

    private func command(for event: NSEvent) -> InputQueryBuffer.Command {
        if event.modifierFlags.intersection([.command, .control]).isEmpty == false {
            return .ignore
        }
        switch event.keyCode {
        case 51, 117:
            return .deleteBackward
        case 36, 48, 53, 76, 123, 124, 125, 126:
            return .boundary
        default:
            guard let characters = event.characters, !characters.isEmpty else { return .ignore }
            return .text(characters)
        }
    }

    private func caretFrame(client: IMKTextInput?) -> NSRect {
        guard let client else {
            return NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20))
        }
        var frame = NSRect.zero
        let selectedLocation = client.selectedRange().location
        _ = client.attributes(forCharacterIndex: selectedLocation, lineHeightRectangle: &frame)
        if frame.isEmpty || !frame.origin.x.isFinite || !frame.origin.y.isFinite {
            return NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20))
        }
        return frame
    }
}
