import XCTest
@testable import IndexApp

@MainActor
final class AgentActionCatalogTests: XCTestCase {
    func testCatalogListsSafeActionsAndKeepsZIPAsUnavailableContract() {
        XCTAssertEqual(AgentActionCatalog.descriptors.map(\.kind), [.setFavorite, .addTag, .exportZIP])
        XCTAssertTrue(AgentActionCatalog.descriptor(for: .setFavorite)?.isAvailable == true)
        XCTAssertTrue(AgentActionCatalog.descriptor(for: .addTag)?.isAvailable == true)
        XCTAssertTrue(AgentActionCatalog.descriptor(for: .exportZIP)?.isAvailable == false)
        XCTAssertFalse(AgentActionCatalog.descriptors.contains(where: \.isDestructive))
    }

    func testToolParserProducesTypedDraftAndRejectsUnavailableAction() throws {
        let draft = try AgentActionTools.parseDraft([
            "action": "add_tag",
            "value": "  论文  ",
            "query": "DeepSeek",
            "filter": "favorites"
        ])

        XCTAssertEqual(
            draft,
            AgentActionDraft(query: "DeepSeek", filter: .favorites, payload: .addTag("论文"))
        )
        XCTAssertThrowsError(try AgentActionTools.parseDraft([
            "action": "export_zip",
            "value": ""
        ])) { error in
            XCTAssertEqual(error as? AgentActionPlanError, .unavailableAction(.exportZIP))
        }
    }

    func testPlanIsImmutablePreviewAndConfirmedFavoriteExecutesOnce() async throws {
        let store = FakeShotStore(shots: [
            makeShot(id: 1, title: "DeepSeek 文档", time: 20),
            makeShot(id: 2, title: "无关内容", time: 10)
        ])
        let service = AgentActionService(store: store, lifetime: 60, sampleLimit: 3)
        let plan = try await service.createPlan(AgentActionDraft(
            query: "DeepSeek",
            filter: .all,
            payload: .setFavorite(true)
        ), now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(plan.shotIDs, [1])
        XCTAssertEqual(plan.samples.map(\.id), [1])
        XCTAssertTrue(store.favoriteIDs.isEmpty, "预览阶段不得修改数据")

        await XCTAssertThrowsAgentError(.confirmationRequired) {
            try await service.execute(
                planID: plan.id,
                confirmationToken: plan.confirmationToken,
                confirm: false,
                now: Date(timeIntervalSince1970: 101)
            )
        }
        let result = try await service.execute(
            planID: plan.id,
            confirmationToken: plan.confirmationToken,
            confirm: true,
            now: Date(timeIntervalSince1970: 101)
        )
        XCTAssertEqual(result.affectedCount, 1)
        XCTAssertEqual(store.favoriteIDs, [1])

        await XCTAssertThrowsAgentError(.planNotFound) {
            try await service.execute(
                planID: plan.id,
                confirmationToken: plan.confirmationToken,
                confirm: true,
                now: Date(timeIntervalSince1970: 102)
            )
        }
    }

    func testExecutionRejectsExpiredPlanAndWrongToken() async throws {
        let store = FakeShotStore(shots: [makeShot(id: 1, title: "A", time: 1)])
        let service = AgentActionService(store: store, lifetime: 10)
        let first = try await service.createPlan(AgentActionDraft(
            query: "",
            filter: .all,
            payload: .setFavorite(true)
        ), now: Date(timeIntervalSince1970: 100))

        await XCTAssertThrowsAgentError(.invalidToken) {
            try await service.execute(
                planID: first.id,
                confirmationToken: "wrong",
                confirm: true,
                now: Date(timeIntervalSince1970: 101)
            )
        }
        await XCTAssertThrowsAgentError(.expired) {
            try await service.execute(
                planID: first.id,
                confirmationToken: first.confirmationToken,
                confirm: true,
                now: Date(timeIntervalSince1970: 111)
            )
        }
        XCTAssertTrue(store.favoriteIDs.isEmpty)
    }

    func testQueryDriftInvalidatesPlanBeforeAnyWrite() async throws {
        let store = FakeShotStore(shots: [makeShot(id: 1, title: "DeepSeek A", time: 1)])
        let service = AgentActionService(store: store)
        let plan = try await service.createPlan(AgentActionDraft(
            query: "DeepSeek",
            filter: .all,
            payload: .setFavorite(true)
        ))

        _ = store.insert(makeShot(id: 2, title: "DeepSeek B", time: 2))
        await XCTAssertThrowsAgentError(.queryDrifted) {
            try await service.execute(
                planID: plan.id,
                confirmationToken: plan.confirmationToken,
                confirm: true
            )
        }
        XCTAssertTrue(store.favoriteIDs.isEmpty)
    }

    func testAddTagUsesFrozenMatchingIDs() async throws {
        let store = FakeShotStore(shots: [
            makeShot(id: 1, title: "论文 A", time: 2),
            makeShot(id: 2, title: "论文 B", time: 1),
            makeShot(id: 3, title: "聊天", time: 0)
        ])
        let service = AgentActionService(store: store)
        let plan = try await service.createPlan(AgentActionDraft(
            query: "论文",
            filter: .all,
            payload: .addTag("待整理")
        ))

        _ = try await service.execute(
            planID: plan.id,
            confirmationToken: plan.confirmationToken,
            confirm: true
        )
        XCTAssertEqual(store.tags(shotID: 1), ["待整理"])
        XCTAssertEqual(store.tags(shotID: 2), ["待整理"])
        XCTAssertTrue(store.tags(shotID: 3).isEmpty)
    }

    private func makeShot(id: Int64, title: String, time: TimeInterval) -> Shot {
        Shot(
            id: id,
            sha256: "hash-\(id)",
            capturedAt: Date(timeIntervalSince1970: time),
            pixelWidth: 1,
            pixelHeight: 1,
            scale: 1,
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
            regionW: 1,
            regionH: 1,
            ocrText: nil
        )
    }

    private func XCTAssertThrowsAgentError(
        _ expected: AgentActionPlanError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentActionPlanError, expected, file: file, line: line)
        }
    }
}

