import XCTest
@testable import IndexApp
import AppKit
import GRDB

final class ClipboardHistoryTests: XCTestCase {

    private var db: DatabaseQueue!
    private var store: ClipboardHistoryStore!

    override func setUp() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        self.db = queue
        self.store = try ClipboardHistoryStore(writer: queue)
    }

    override func tearDown() async throws {
        try? db.close()
        db = nil
        store = nil
    }

    func testRecordTextAndDedup() throws {
        let added = try store.record(
            kind: .text,
            contentHash: "abc123",
            text: "hello world",
            assetPath: nil,
            summary: "hello world",
            sourceApp: "Safari"
        )
        XCTAssertTrue(added, "首次记录应新增")

        // 相同 hash 再次记录 → 去重命中，只刷新时间
        let addedAgain = try store.record(
            kind: .text,
            contentHash: "abc123",
            text: "hello world",
            assetPath: nil,
            summary: "hello world",
            sourceApp: "Safari"
        )
        XCTAssertFalse(addedAgain, "相同 hash 应去重")

        let items = try store.recent(limit: 10)
        XCTAssertEqual(items.count, 1, "去重后只有一条")
        XCTAssertEqual(items.first?.text, "hello world")
    }

    func testClipboardPanelPasteStyleShortcuts() {
        func command(
            _ keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags = [],
            type: NSEvent.EventType = .keyDown,
            isRepeat: Bool = false
        ) -> ClipboardPanelShortcutCommand? {
            ClipboardPanelShortcutResolver.command(
                keyCode: keyCode,
                eventType: type,
                modifiers: modifiers,
                isRepeat: isRepeat
            )
        }

        XCTAssertEqual(command(KeyCode.returnKey), .paste)
        XCTAssertEqual(command(KeyCode.keypadEnter), .paste)
        XCTAssertEqual(command(KeyCode.returnKey, modifiers: [.shift]), .pasteAsPlainText)
        XCTAssertEqual(command(KeyCode.c, modifiers: [.command]), .copy)
        XCTAssertEqual(command(KeyCode.r, modifiers: [.command]), .rename)
        XCTAssertEqual(command(KeyCode.left), .movePrevious)
        XCTAssertEqual(command(KeyCode.right), .moveNext)
        XCTAssertEqual(command(KeyCode.delete), .delete)
        XCTAssertEqual(command(KeyCode.forwardDelete), .delete)
        XCTAssertEqual(command(KeyCode.escape), .close)
        XCTAssertEqual(command(KeyCode.space), .previewStart)
        XCTAssertEqual(command(KeyCode.space, type: .keyUp), .previewEnd)
        XCTAssertEqual(command(KeyCode.space, isRepeat: true), .consume)
        XCTAssertNil(command(KeyCode.returnKey, modifiers: [.command]))
        XCTAssertNil(command(KeyCode.c))
    }

    func testClipboardPanelShortcutsRemainAvailableWhileSearchFieldOwnsFocus() {
        for command in [
            ClipboardPanelShortcutCommand.paste,
            .pasteAsPlainText,
            .copy,
            .rename,
            .close,
        ] {
            XCTAssertFalse(ClipboardPanelTextInputShortcutPolicy.defersToTextInput(
                command,
                isRenaming: false
            ))
            XCTAssertTrue(ClipboardPanelTextInputShortcutPolicy.defersToTextInput(
                command,
                isRenaming: true
            ))
        }

        for command in [
            ClipboardPanelShortcutCommand.movePrevious,
            .moveNext,
            .delete,
            .previewStart,
            .previewEnd,
            .consume,
        ] {
            XCTAssertTrue(ClipboardPanelTextInputShortcutPolicy.defersToTextInput(
                command,
                isRenaming: false
            ))
        }
    }

    func testClipboardPasteWaitsForCapturedFocusButAlwaysHasBoundedFallback() {
        XCTAssertTrue(ClipboardPasteFocusRestorationPolicy.shouldPostCommandV(
            hasFocusSnapshot: false,
            isFocusRestored: false,
            attempt: 0
        ))
        XCTAssertTrue(ClipboardPasteFocusRestorationPolicy.shouldPostCommandV(
            hasFocusSnapshot: true,
            isFocusRestored: true,
            attempt: 0
        ))
        XCTAssertFalse(ClipboardPasteFocusRestorationPolicy.shouldPostCommandV(
            hasFocusSnapshot: true,
            isFocusRestored: false,
            attempt: 0
        ))
        XCTAssertTrue(ClipboardPasteFocusRestorationPolicy.shouldPostCommandV(
            hasFocusSnapshot: true,
            isFocusRestored: false,
            attempt: ClipboardPasteFocusRestorationPolicy.maximumAttemptCount - 1
        ))
    }

    @MainActor
    func testClipboardPanelEnterCrossesRealTextFirstResponderGate() throws {
        let viewModel = ClipboardHistoryViewModel(store: store)
        let panel = ClipboardHistoryPanel(store: store, viewModel: viewModel)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        let searchField = NSTextField(frame: NSRect(x: 10, y: 30, width: 200, height: 24))
        content.addSubview(searchField)
        panel.contentView = content
        panel.orderFrontRegardless()
        panel.makeKey()
        XCTAssertTrue(panel.makeFirstResponder(searchField))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        defer { panel.orderOut(nil) }

        XCTAssertTrue(panel.firstResponder is NSText)
        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: KeyCode.returnKey
        ))

        XCTAssertNil(panel.handleShortcutEvent(enter))
        XCTAssertEqual(viewModel.pasteFeedback, "请先选择要粘贴的卡片")
    }

    func testRecentOrdering() throws {
        try store.record(kind: .text, contentHash: "h1", text: "first", assetPath: nil, summary: "first", sourceApp: nil)
        Thread.sleep(forTimeInterval: 0.01)
        try store.record(kind: .text, contentHash: "h2", text: "second", assetPath: nil, summary: "second", sourceApp: nil)

        let items = try store.recent(limit: 10)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.text, "second", "最新的在前")
    }

    func testSearchFilter() throws {
        try store.record(kind: .text, contentHash: "h1", text: "apple pie", assetPath: nil, summary: "apple pie", sourceApp: nil)
        try store.record(kind: .text, contentHash: "h2", text: "banana split", assetPath: nil, summary: "banana split", sourceApp: nil)

        let filtered = try store.recent(limit: 10, query: "apple")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.text, "apple pie")
    }

    func testClipboardFTSMigrationAndSearchStaySynchronized() throws {
        let hasTable = try db.read { database in
            try database.tableExists("clipboardHistoryFts")
        }
        XCTAssertTrue(hasTable)

        try store.record(
            kind: .text,
            contentHash: "fts-sync",
            text: "opencode installation guide",
            assetPath: nil,
            summary: "developer note",
            sourceApp: nil
        )
        let inserted = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertEqual(try store.recent(limit: 10, query: "opencode").map(\.id), [inserted.id])

        store.rename("renamed searchable card", for: inserted)
        XCTAssertEqual(try store.recent(limit: 10, query: "searchable").map(\.id), [inserted.id])
    }

    func testStableCursorPaginationHasNoDuplicates() throws {
        for index in 0..<205 {
            try store.record(
                kind: .text,
                contentHash: "page-\(index)",
                text: "item \(index)",
                assetPath: nil,
                summary: "item \(index)",
                sourceApp: nil
            )
        }

        let first = try store.page(limit: 100)
        let firstTail = try XCTUnwrap(first.last)
        let second = try store.page(
            limit: 100,
            before: .init(capturedAt: firstTail.capturedAt, id: try XCTUnwrap(firstTail.id))
        )
        let secondTail = try XCTUnwrap(second.last)
        let third = try store.page(
            limit: 100,
            before: .init(capturedAt: secondTail.capturedAt, id: try XCTUnwrap(secondTail.id))
        )

        let ids = (first + second + third).compactMap(\.id)
        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(second.count, 100)
        XCTAssertEqual(third.count, 5)
        XCTAssertEqual(Set(ids).count, 205)
    }

    func testCapsulePersistsSelectionOrderAndProtectsMembersFromPrune() throws {
        try store.record(
            kind: .text,
            contentHash: "capsule-first",
            text: "first",
            assetPath: nil,
            summary: "first",
            sourceApp: "Notes"
        )
        try store.record(
            kind: .text,
            contentHash: "capsule-second",
            text: "second",
            assetPath: nil,
            summary: "second",
            sourceApp: "Notes"
        )
        let recent = try store.recent(limit: 10)
        let first = try XCTUnwrap(recent.first { $0.contentHash == "capsule-first" })
        let second = try XCTUnwrap(recent.first { $0.contentHash == "capsule-second" })

        let capsule = try store.createCapsule(name: "安装步骤", items: [first, second])
        let snapshot = try XCTUnwrap(store.capsuleSnapshots().first)

        XCTAssertEqual(snapshot.capsule.id, capsule.id)
        XCTAssertEqual(snapshot.capsule.name, "安装步骤")
        XCTAssertEqual(snapshot.items.map(\.contentHash), ["capsule-first", "capsule-second"])

        try db.write { database in
            try database.execute(
                sql: "UPDATE clipboardHistory SET capturedAt = ?",
                arguments: [Date(timeIntervalSince1970: 0)]
            )
        }
        store.prune(olderThanDays: 1)
        XCTAssertEqual(try store.recent(limit: 10).count, 2)
    }

    func testCapsuleRenamePinAndDeleteAreIndependentFromHistory() throws {
        try store.record(
            kind: .text,
            contentHash: "capsule-lifecycle",
            text: "payload",
            assetPath: nil,
            summary: "payload",
            sourceApp: nil
        )
        let item = try XCTUnwrap(store.recent(limit: 1).first)
        let capsule = try store.createCapsule(name: "旧名称", items: [item])
        let capsuleID = try XCTUnwrap(capsule.id)

        store.renameCapsule("新名称", capsuleID: capsuleID)
        store.setCapsulePinned(true, capsuleID: capsuleID)
        let updated = try XCTUnwrap(store.capsuleSnapshots().first)
        XCTAssertEqual(updated.capsule.name, "新名称")
        XCTAssertTrue(updated.capsule.isPinned)

        try store.record(
            kind: .text,
            contentHash: "capsule-replacement",
            text: "replacement",
            assetPath: nil,
            summary: "replacement",
            sourceApp: nil
        )
        let replacement = try XCTUnwrap(
            store.recent(limit: 10).first { $0.contentHash == "capsule-replacement" }
        )
        try store.replaceCapsuleItems(capsuleID: capsuleID, items: [replacement, item])
        XCTAssertEqual(
            try store.capsuleSnapshots().first?.items.map(\.contentHash),
            ["capsule-replacement", "capsule-lifecycle"]
        )

        store.deleteCapsule(capsuleID)
        XCTAssertTrue(try store.capsuleSnapshots().isEmpty)
        XCTAssertEqual(
            Set(try store.recent(limit: 10).map(\.contentHash)),
            Set(["capsule-lifecycle", "capsule-replacement"])
        )
    }

    func testThreadBuilderGroupsNearbyRelatedCopiesAndLeavesSinglesOut() {
        let base = Date(timeIntervalSince1970: 10_000)
        let items = [
            makeThreadItem(id: 1, text: "opencode 安装", source: "Safari", date: base),
            makeThreadItem(id: 2, text: "opencode npm command", source: "Terminal", date: base.addingTimeInterval(90)),
            makeThreadItem(id: 3, text: "unrelated", source: "Notes", date: base.addingTimeInterval(2_000)),
        ]

        let threads = ClipboardThreadBuilder.build(from: items)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].items.map(\.id), [2, 1])
        XCTAssertEqual(threads[0].title, "opencode")
    }

    func testThreadBuilderDoesNotMergeUnrelatedRapidCopiesByTimeAlone() {
        let base = Date(timeIntervalSince1970: 20_000)
        let items = [
            makeThreadItem(id: 1, text: "quarterly budget", source: "Numbers", date: base),
            makeThreadItem(id: 2, text: "holiday photo", source: "Photos", date: base.addingTimeInterval(20)),
        ]

        XCTAssertTrue(ClipboardThreadBuilder.build(from: items).isEmpty)
    }

    func testThreadBuilderKeepsSameSourceCopySequenceTogether() {
        let base = Date(timeIntervalSince1970: 30_000)
        let items = [
            makeThreadItem(id: 1, text: "first command", source: "Terminal", date: base),
            makeThreadItem(id: 2, text: "second result", source: "Terminal", date: base.addingTimeInterval(80)),
        ]

        let threads = ClipboardThreadBuilder.build(from: items)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].title, "Terminal")
    }

    private func makeThreadItem(
        id: Int64,
        text: String,
        source: String?,
        date: Date
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: id,
            kind: .text,
            contentHash: "thread-\(id)",
            text: text,
            assetPath: nil,
            summary: text,
            sourceApp: source,
            pinned: false,
            capturedAt: date,
            lastUsedAt: nil,
            title: nil,
            isFavorite: false
        )
    }

    func testDeleteRemovesAsset() throws {
        let data = Data("fake-png-bytes".utf8)
        let assetPath = try store.writeImageAsset(data, sha: "imgsha1")
        try store.record(
            kind: .image,
            contentHash: "imgsha1",
            text: nil,
            assetPath: assetPath,
            summary: "图片 100×100",
            sourceApp: nil
        )
        let items = try store.recent(limit: 10)
        XCTAssertEqual(items.count, 1)
        let fileURL = store.assetDirectory.appendingPathComponent(assetPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "图片文件应存在")

        store.delete(items[0])
        let after = try store.recent(limit: 10)
        XCTAssertEqual(after.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "删除后图片文件应清理")
    }

    func testCoordinatorHashAndSummary() {
        let hash = ClipboardHistoryCoordinator.hash(Data("test".utf8))
        XCTAssertEqual(hash.count, 64, "SHA256 hex 应为 64 字符")
        XCTAssertEqual(
            hash,
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        )

        let summary = ClipboardHistoryCoordinator.summary(for: "line one\nline two")
        XCTAssertEqual(summary, "line one", "摘要取第一行")

        let long = String(repeating: "a", count: 200)
        let longSummary = ClipboardHistoryCoordinator.summary(for: long)
        XCTAssertEqual(longSummary.count, 121, "120 字符 + 省略号")
        XCTAssertTrue(longSummary.hasSuffix("…"))
    }

    func testClipboardCardPresentationUsesUsefulFooterMetadata() {
        let text = ClipboardHistoryItem(
            id: 1,
            kind: .text,
            contentHash: "text",
            text: "hello world",
            assetPath: nil,
            summary: "hello world",
            sourceApp: "Safari",
            pinned: false,
            capturedAt: Date(),
            lastUsedAt: nil,
            title: nil,
            isFavorite: false
        )
        var image = text
        image.kind = .image
        image.summary = "图片 2050×1445"

        XCTAssertEqual(ClipboardCardPresentation.typeLabel(for: text.kind), "文本")
        XCTAssertEqual(ClipboardCardPresentation.metadata(for: text), "11 个字符")
        XCTAssertEqual(ClipboardCardPresentation.metadata(for: image), "2050×1445")
    }

    @MainActor
    func testAppIconAccentExtractorKeepsBrandHueAndDarkensForWhiteText() throws {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor(calibratedRed: 0.92, green: 0.08, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
        image.unlockFocus()

        let color = try XCTUnwrap(
            AppIconAccentExtractor.color(from: image)?.usingColorSpace(.sRGB)
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: nil
        )
        XCTAssertTrue(hue < 0.05 || hue > 0.95)
        XCTAssertGreaterThan(saturation, 0.4)
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
        XCTAssertLessThanOrEqual(luminance, 0.17)
    }

    func testClipboardCardPresentationUsesCustomTitleWithoutReplacingMetadata() {
        let item = ClipboardHistoryItem(
            id: 1,
            kind: .file,
            contentHash: "file",
            text: nil,
            assetPath: "file.json",
            summary: "report.pdf",
            sourceApp: "Finder",
            pinned: false,
            capturedAt: Date(),
            lastUsedAt: nil,
            title: "季度报告",
            isFavorite: false
        )

        XCTAssertEqual(ClipboardCardPresentation.displayTitle(for: item), "季度报告")
        XCTAssertEqual(ClipboardCardPresentation.metadata(for: item), "report.pdf")
        var untitled = item
        untitled.title = nil
        XCTAssertEqual(ClipboardCardPresentation.displayTitle(for: untitled), "文件")
    }

    func testRenameChangesTitleWithoutChangingClipboardKind() throws {
        try store.record(
            kind: .image,
            contentHash: "rename-image",
            text: nil,
            assetPath: "rename-image.png",
            summary: "图片 800×600",
            sourceApp: "Preview"
        )
        let original = try XCTUnwrap(store.recent(limit: 1).first)

        store.rename("设计参考", for: original)

        let renamed = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertEqual(renamed.title, "设计参考")
        XCTAssertEqual(renamed.kind, .image)

        store.rename("  ", for: renamed)
        let restored = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertNil(restored.title)
        XCTAssertEqual(ClipboardCardPresentation.displayTitle(for: restored), "图片")
    }

    func testRenameFromStaleCardSnapshotPreservesNewerFlags() throws {
        try store.record(
            kind: .text,
            contentHash: "rename-stale-snapshot",
            text: "需要改名的内容",
            assetPath: nil,
            summary: "需要改名的内容",
            sourceApp: "Notes"
        )
        let staleCard = try XCTUnwrap(store.recent(limit: 1).first)

        store.setPinned(true, for: staleCard)
        let pinned = try XCTUnwrap(store.recent(limit: 1).first)
        store.setFavorite(true, for: pinned)

        // 虚拟卡片仍可能持有改名前的旧快照；改名不得把较新的状态整行覆盖。
        store.rename("新的名称", for: staleCard)

        let renamed = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertEqual(renamed.title, "新的名称")
        XCTAssertTrue(renamed.pinned)
        XCTAssertTrue(renamed.isFavorite)
    }

    func testClipboardChangeGateSuppressesHistoryWriteBackOnlyOnce() {
        var gate = ClipboardChangeGate()

        gate.synchronize(to: 41)
        XCTAssertFalse(gate.consumeIfChanged(41), "内部写回的 changeCount 应被直接消费")
        XCTAssertTrue(gate.consumeIfChanged(42), "下一次真实的外部复制仍应进入历史")
        XCTAssertFalse(gate.consumeIfChanged(42), "同一个 changeCount 不应重复处理")
    }

    @MainActor
    func testPopupSelectionResolvesItemImmediatelyByStableID() throws {
        try store.record(
            kind: .text,
            contentHash: "selection-1",
            text: "first",
            assetPath: nil,
            summary: "first",
            sourceApp: nil
        )
        try store.record(
            kind: .text,
            contentHash: "selection-2",
            text: "second",
            assetPath: nil,
            summary: "second",
            sourceApp: nil
        )
        let items = try store.recent(limit: 10)
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.items = items

        viewModel.select(items[1])

        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(viewModel.selectedItemID, items[1].id)
    }

    @MainActor
    func testPopupPasteQueueUsesExplicitSelectionOrder() throws {
        for index in 1...3 {
            try store.record(
                kind: .text,
                contentHash: "queue-\(index)",
                text: "text-\(index)",
                assetPath: nil,
                summary: "text-\(index)",
                sourceApp: nil
            )
        }
        let items = try store.recent(limit: 10)
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.items = items

        viewModel.select(items[1])
        viewModel.select(items[0], extending: true)
        viewModel.select(items[2], extending: true)

        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[1].id, items[0].id, items[2].id].compactMap { $0 })
        XCTAssertEqual(viewModel.selectionOrdinal(for: items[1]), 1)
        XCTAssertEqual(viewModel.selectionOrdinal(for: items[0]), 2)
        XCTAssertEqual(viewModel.selectionOrdinal(for: items[2]), 3)

        // 取消再加入必须排到队尾，而不是回到列表里的原始位置。
        viewModel.select(items[0], extending: true)
        viewModel.select(items[0], extending: true)
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[1].id, items[2].id, items[0].id].compactMap { $0 })
    }

    func testQueuedTextUsesNewlineAndKeepsOrder() {
        XCTAssertEqual(
            ClipboardHistoryViewModel.joinedTexts(["first", "second", "third"]),
            "first\nsecond\nthird"
        )
    }

    @MainActor
    func testLoadingAndReorderingQueueMakesTheOrderVisible() throws {
        for index in 1...3 {
            try store.record(
                kind: .text,
                contentHash: "reorder-\(index)",
                text: "reorder-\(index)",
                assetPath: nil,
                summary: "reorder-\(index)",
                sourceApp: nil
            )
        }
        let items = try store.recent(limit: 10)
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.workspaceMode = .capsules

        viewModel.loadPasteQueue(items)
        XCTAssertEqual(viewModel.workspaceMode, .history)
        XCTAssertTrue(viewModel.isContinuousSelectionEnabled)

        viewModel.movePasteQueueItem(items[2], by: -1)
        XCTAssertEqual(
            viewModel.pasteQueueItems.map(\.id),
            [items[0].id, items[2].id, items[1].id]
        )
    }

    @MainActor
    func testPasteQueueSurvivesSearchAndAppendsResult() throws {
        try store.record(
            kind: .text,
            contentHash: "before-search",
            text: "chosen before search",
            assetPath: nil,
            summary: "chosen before search",
            sourceApp: nil
        )
        try store.record(
            kind: .text,
            contentHash: "search-result",
            text: "needle result",
            assetPath: nil,
            summary: "needle result",
            sourceApp: nil
        )
        let allItems = try store.recent(limit: 10)
        let first = try XCTUnwrap(allItems.first { $0.contentHash == "before-search" })
        let result = try XCTUnwrap(allItems.first { $0.contentHash == "search-result" })
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.items = allItems
        viewModel.select(first)

        // 搜索只替换候选列表，已选条目快照不能随之消失。
        viewModel.query = "needle"
        viewModel.items = [result]
        viewModel.selectedIndex = 0
        viewModel.setContinuousSelectionEnabled(true)
        viewModel.select(
            result,
            continuingQueue: viewModel.isContinuousSelectionEnabled
        )

        XCTAssertEqual(viewModel.orderedSelectedIDs, [first.id, result.id].compactMap { $0 })
        XCTAssertEqual(viewModel.pasteQueueItems.map(\.contentHash), ["before-search", "search-result"])
        XCTAssertEqual(viewModel.selectionOrdinal(for: result), 2)
    }

    @MainActor
    func testContinuousSelectionModeExplicitlyControlsAppend() throws {
        for index in 1...2 {
            try store.record(
                kind: .text,
                contentHash: "mode-\(index)",
                text: "mode-\(index)",
                assetPath: nil,
                summary: "mode-\(index)",
                sourceApp: nil
            )
        }
        let items = try store.recent(limit: 10)
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.items = items

        viewModel.select(items[0])
        viewModel.select(
            items[1],
            continuingQueue: viewModel.isContinuousSelectionEnabled
        )
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[1].id].compactMap { $0 })

        viewModel.select(items[0])
        viewModel.setContinuousSelectionEnabled(true)
        viewModel.select(
            items[1],
            continuingQueue: viewModel.isContinuousSelectionEnabled
        )
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[0].id, items[1].id].compactMap { $0 })

        // 连续模式再次点击同一张卡片就是取消，不需要去左侧点移除。
        viewModel.select(
            items[1],
            continuingQueue: viewModel.isContinuousSelectionEnabled
        )
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[0].id].compactMap { $0 })
        XCTAssertNil(viewModel.selectionOrdinal(for: items[1]))

        viewModel.setContinuousSelectionEnabled(false)
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[1].id].compactMap { $0 })
    }
}
