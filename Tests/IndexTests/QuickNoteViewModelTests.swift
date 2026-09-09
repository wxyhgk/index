import XCTest
@testable import IndexApp

// MARK: - QuickNoteViewModel 单元测试
//
// 用 FakeShotStore 驱动便签面板的全部业务逻辑（防抖保存 / undo-redo /
// todo 勾选 / 列表导航 / 持久化 / 按天分组），不依赖真实数据库。
//
// 防抖相关断言用 `Task.sleep`（async 测试方法），不用固定 `Thread.sleep`。

@MainActor
final class QuickNoteViewModelTests: XCTestCase {

    private var fakeStore: FakeShotStore!
    private var viewModel: QuickNoteViewModel!

    override func setUp() {
        super.setUp()
        fakeStore = FakeShotStore()
        viewModel = QuickNoteViewModel(store: fakeStore)
    }

    override func tearDown() {
        viewModel = nil
        fakeStore = nil
        super.tearDown()
    }

    // MARK: 辅助

    /// 构造一条 markdown 便签（contentKind = "markdown"，可指定时间）。
    private func makeMarkdownShot(title: String, at date: Date) -> Shot {
        var shot = Shot(
            id: nil,
            sha256: UUID().uuidString,
            capturedAt: date,
            pixelWidth: 0,
            pixelHeight: 0,
            scale: 1.0,
            appName: nil,
            appBundleID: nil,
            appVersion: nil,
            appBuild: nil,
            windowTitle: title,
            sourceURL: nil,
            displayID: nil,
            displayName: nil,
            regionX: 0,
            regionY: 0,
            regionW: 0,
            regionH: 0,
            ocrText: nil,
            originalExtension: "png"
        )
        shot.contentKind = "markdown"
        return shot
    }

    // MARK: 1. 防抖保存

    func testDebounceDoesNotPersistWithin800ms() async {
        viewModel.updateText("hello")
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(viewModel.selectedShotID, "800ms 防抖窗口内不应落盘")
        XCTAssertTrue(fakeStore.shots.isEmpty)
    }

    func testDebounceSavesAfter800ms() async {
        viewModel.updateText("hello")
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(viewModel.text, "hello")
        XCTAssertNotNil(viewModel.selectedShotID, "超过 800ms 后应自动保存")
        XCTAssertEqual(fakeStore.shots.count, 1)
        XCTAssertEqual(fakeStore.markdownSource(for: fakeStore.shots[0]), "hello")
    }

    func testFlushPendingSavePersistsImmediately() async {
        viewModel.updateText("hello")
        viewModel.flushPendingSave()
        // 不等 800ms：flush 已立即落盘
        XCTAssertNotNil(viewModel.selectedShotID)
        XCTAssertEqual(fakeStore.markdownSource(for: fakeStore.shots[0]), "hello")
    }

    func testConsecutiveUpdatesWithin800msSaveOnlyLast() async {
        viewModel.updateText("a")
        viewModel.updateText("ab")
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(fakeStore.shots.count, 1)
        XCTAssertEqual(fakeStore.markdownSource(for: fakeStore.shots[0]), "ab",
                       "第二次 updateText 取消第一次的防抖任务，只保存最后一次")
    }

    // MARK: 2. undo / redo

    func testUndoRedoRestoresText() async {
        viewModel.updateText("a")
        try? await Task.sleep(for: .seconds(0.6))
        viewModel.updateText("ab")
        try? await Task.sleep(for: .seconds(0.6))

        viewModel.undo()
        XCTAssertEqual(viewModel.text, "a")
        viewModel.redo()
        XCTAssertEqual(viewModel.text, "ab")
    }

    func testUndoRedoClearsRedoStackOnNewEdit() async {
        viewModel.updateText("a")
        try? await Task.sleep(for: .seconds(0.6))
        viewModel.updateText("ab")
        try? await Task.sleep(for: .seconds(0.6))

        viewModel.undo()
        XCTAssertEqual(viewModel.text, "a")
        viewModel.updateText("abc")
        try? await Task.sleep(for: .seconds(0.6))
        viewModel.redo()
        XCTAssertEqual(viewModel.text, "abc", "新编辑后 redoStack 被清空，redo 应无效")
    }

    func testUndoStackCapsAt50Entries() async {
        // 51 次 updateText，每次间隔 0.55s（> 0.5s 压栈阈值）。
        // 每次 flushPendingSave 立即落盘并取消防抖任务，避免 51 个任务在
        // 800ms 窗口内堆积；压栈判定只依赖 lastPushTime，不受影响。
        // 压栈的是编辑前的 text：初始 "" + t0…t49 共 51 条，上限 50 挤出 ""。
        for i in 0...50 {
            viewModel.updateText("t\(i)")
            viewModel.flushPendingSave()
            try? await Task.sleep(for: .seconds(0.55))
        }
        // 栈 = [t0, t1, …, t49]（50 条），undo 50 次后 text = "t0"
        for _ in 0..<50 {
            viewModel.undo()
        }
        XCTAssertEqual(viewModel.text, "t0", "undoStack 最多保留 50 条")
        viewModel.undo()
        XCTAssertEqual(viewModel.text, "t0", "栈空后 undo 无效")
    }

    // MARK: 3. toggleTodo

    func testTodosParseAndToggle() {
        viewModel.text = "- [ ] task1\n- [x] task2\n- [ ] task3"
        let todos = viewModel.todos
        XCTAssertEqual(todos.count, 3)
        XCTAssertEqual(todos[1].done, true)
        XCTAssertEqual(todos[1].text, "task2")

        viewModel.toggleTodo(at: 0)
        XCTAssertTrue(viewModel.text.contains("- [x] task1"))
        viewModel.toggleTodo(at: 1)
        XCTAssertTrue(viewModel.text.contains("- [ ] task2"))
    }

    func testToggleTodoWithBlankLines() {
        viewModel.text = "- [ ] task1\n\n- [ ] task2"
        viewModel.toggleTodo(at: 1)
        XCTAssertTrue(viewModel.text.contains("- [x] task2"),
                      "lineIndex 基于原始行号，空行不应影响定位")
        XCTAssertTrue(viewModel.text.contains("- [ ] task1"))
    }

    func testParseTodosRecognizesUppercaseX() {
        let todos = QuickNoteViewModel.parseTodos("- [X] task1")
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].done, true)
    }

    // MARK: 4. navigate

    func testNavigateOnEmptyListDoesNotCrash() {
        viewModel.navigate(direction: 1)
        viewModel.navigate(direction: -1)
        XCTAssertNil(viewModel.selectedShotID)
    }

    func testNavigateWithSingleShotSelectsIt() async throws {
        let shot = try fakeStore.createMarkdownShot(title: "only", source: "s")
        viewModel.reload()
        XCTAssertEqual(viewModel.shots.count, 1)

        viewModel.navigate(direction: 1)
        XCTAssertEqual(viewModel.selectedShotID, shot.id)
        viewModel.navigate(direction: -1)
        XCTAssertEqual(viewModel.selectedShotID, shot.id)
    }

    func testNavigateWrapsAround() async throws {
        let s1 = try fakeStore.createMarkdownShot(title: "n1", source: "a")
        let s2 = try fakeStore.createMarkdownShot(title: "n2", source: "b")
        let s3 = try fakeStore.createMarkdownShot(title: "n3", source: "c")
        viewModel.reload()
        XCTAssertEqual(viewModel.shots.count, 3)
        // FakeShotStore insert(at: 0)：最新在前 → [s3, s2, s1]

        // 选第一条（s3，index 0），向前回绕到最后一条（s1，index 2）
        viewModel.select(shotID: s3.id!)
        viewModel.navigate(direction: -1)
        XCTAssertEqual(viewModel.selectedShotID, s1.id, "第 0 条向前应回绕到最后一条")
        // 向后回到第一条
        viewModel.navigate(direction: 1)
        XCTAssertEqual(viewModel.selectedShotID, s3.id, "回绕后向后应回到第一条")
        _ = s2
    }

    func testNavigateWhenCurrentNotInListSelectsFirst() async throws {
        let s1 = try fakeStore.createMarkdownShot(title: "n1", source: "a")
        let s2 = try fakeStore.createMarkdownShot(title: "n2", source: "b")
        viewModel.reload()
        XCTAssertEqual(viewModel.shots.count, 2)

        // 模拟删除后残留：selectedShotID 指向已不存在的 shot
        viewModel.selectedShotID = 9999
        viewModel.navigate(direction: 1)
        // reload 按 updatedAt 降序，s2 最新 → 第一条
        XCTAssertEqual(viewModel.selectedShotID, s2.id, "当前不在列表时应选中第一条")
        _ = s1
    }

    // MARK: 5. persist

    func testPersistCreatesNewShotWhenNoSelection() {
        viewModel.text = "hello world"
        viewModel.persistNow()
        XCTAssertNotNil(viewModel.selectedShotID, "新便签应创建 shot 并记录 selectedShotID")
        XCTAssertEqual(fakeStore.shots.count, 1)
        XCTAssertEqual(fakeStore.markdownSource(for: fakeStore.shots[0]), "hello world")
    }

    func testPersistUpdatesExistingShot() async throws {
        let shot = try fakeStore.createMarkdownShot(title: "old", source: "old")
        viewModel.reload()
        viewModel.select(shotID: shot.id!)
        XCTAssertEqual(viewModel.text, "old")

        viewModel.text = "updated"
        viewModel.persistNow()
        XCTAssertEqual(fakeStore.shots.count, 1, "已有便签应更新内容，不创建新 shot")
        XCTAssertEqual(viewModel.selectedShotID, shot.id)
        XCTAssertEqual(fakeStore.markdownSource(for: fakeStore.shots[0]), "updated")
    }

    func testPersistSkipsBlankText() {
        viewModel.text = "   "
        viewModel.persistNow()
        XCTAssertNil(viewModel.selectedShotID, "纯空白文本不应保存")
        XCTAssertTrue(fakeStore.shots.isEmpty)
    }

    func testPersistSkipsUnchangedText() {
        viewModel.text = "hello"
        viewModel.persistNow()
        let countAfterFirst = fakeStore.shots.count
        XCTAssertEqual(countAfterFirst, 1)

        // lastSavedText 守卫：相同文本再次 persist 不应重复落盘
        viewModel.text = "hello"
        viewModel.persistNow()
        XCTAssertEqual(fakeStore.shots.count, countAfterFirst, "相同文本不应重复保存")
    }

    // MARK: 6. groupByDay / dayLabel

    func testDayLabelTodayYesterdayAndEarlier() {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let earlier = Calendar.current.date(byAdding: .day, value: -10, to: today)!

        XCTAssertEqual(QuickNoteViewModel.dayLabel(for: today), "今天")
        XCTAssertEqual(QuickNoteViewModel.dayLabel(for: yesterday), "昨天")

        let expected = DateFormatter()
        expected.dateFormat = "M月d日"
        XCTAssertEqual(QuickNoteViewModel.dayLabel(for: earlier), expected.string(from: earlier))
    }

    func testGroupByDaySplitsAcrossDays() {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let shots = [
            makeMarkdownShot(title: "t1", at: today),
            makeMarkdownShot(title: "t2", at: today),
            makeMarkdownShot(title: "y1", at: yesterday)
        ]
        let groups = QuickNoteViewModel.groupByDay(shots)
        XCTAssertEqual(groups.count, 2, "今天 2 条 + 昨天 1 条应分成 2 组")
        XCTAssertEqual(groups[0].shots.count, 2, "按日期降序，今天组在前")
        XCTAssertEqual(groups[1].shots.count, 1)
    }

    // MARK: 7. resetEditor / loadLatest

    func testResetEditorClearsState() async throws {
        let shot = try fakeStore.createMarkdownShot(title: "n", source: "content")
        viewModel.select(shotID: shot.id!)
        viewModel.updateText("content edited")
        try? await Task.sleep(for: .seconds(0.6))

        viewModel.resetEditor()
        XCTAssertEqual(viewModel.text, "")
        XCTAssertNil(viewModel.selectedShotID)
        // undoStack 已清空：undo 无效
        viewModel.undo()
        XCTAssertEqual(viewModel.text, "")
    }

    func testLoadLatestLoadsMostRecentNote() async throws {
        _ = try fakeStore.createMarkdownShot(title: "old", source: "old content")
        let latest = try fakeStore.createMarkdownShot(title: "new", source: "new content")
        // 显式设置 updatedAt 保证排序确定（createMarkdownShot 不写 updatedAt）
        fakeStore.shots = fakeStore.shots.map { shot in
            var s = shot
            s.updatedAt = (shot.id == latest.id) ? Date() : Date().addingTimeInterval(-3600)
            return s
        }

        viewModel.loadLatest()
        XCTAssertEqual(viewModel.selectedShotID, latest.id)
        XCTAssertEqual(viewModel.text, "new content")
    }

    func testLoadLatestResetsEditorWhenNoNotes() {
        viewModel.text = "stale"
        viewModel.selectedShotID = 42
        viewModel.loadLatest()
        XCTAssertEqual(viewModel.text, "", "无便签时 loadLatest 应等同 resetEditor")
        XCTAssertNil(viewModel.selectedShotID)
    }
}
