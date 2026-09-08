import Foundation

/// Agent 批量动作的计划/确认门。
///
/// 服务只依赖 Storage 的读写契约，不依赖 Gallery 或任何 UI。计划单次有效；执行时重跑
/// 查询并与冻结 ID 完整比较，避免预览后新增、删除或改筛选导致作用范围漂移。
@MainActor
final class AgentActionService {
    private let store: any ShotReading & ShotWriting
    private let lifetime: TimeInterval
    private let sampleLimit: Int
    private var plans: [String: AgentActionPlan] = [:]

    init(
        store: any ShotReading & ShotWriting,
        lifetime: TimeInterval = 120,
        sampleLimit: Int = 5
    ) {
        self.store = store
        self.lifetime = lifetime
        self.sampleLimit = sampleLimit
    }

    func createPlan(_ draft: AgentActionDraft, now: Date = Date()) async throws -> AgentActionPlan {
        guard AgentActionCatalog.descriptor(for: draft.payload.kind)?.isAvailable == true else {
            throw AgentActionPlanError.unavailableAction(draft.payload.kind)
        }
        pruneExpired(now: now)

        let ids = await store.allMatchingIDs(query: draft.query, filter: draft.filter.shotFilter)
        guard !ids.isEmpty else { throw AgentActionPlanError.emptyResult }
        let sampleShots = await store.shotsInBackground(ids: Array(ids.prefix(sampleLimit)))
        let samples = sampleShots.compactMap { shot -> AgentActionSample? in
            guard let id = shot.id else { return nil }
            return AgentActionSample(id: id, title: shot.primaryDisplayName, capturedAt: shot.capturedAt)
        }
        let plan = AgentActionPlan(
            id: UUID().uuidString.lowercased(),
            confirmationToken: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime),
            draft: draft,
            shotIDs: ids,
            samples: samples
        )
        plans[plan.id] = plan
        return plan
    }

    func execute(
        planID: String,
        confirmationToken: String,
        confirm: Bool,
        now: Date = Date()
    ) async throws -> AgentActionExecution {
        guard confirm else { throw AgentActionPlanError.confirmationRequired }
        guard let plan = plans[planID] else { throw AgentActionPlanError.planNotFound }
        guard plan.confirmationToken == confirmationToken else { throw AgentActionPlanError.invalidToken }
        guard now < plan.expiresAt else {
            plans[planID] = nil
            throw AgentActionPlanError.expired
        }

        // 先消费，避免 actor 在下面 await 时重入并重复执行同一份计划。
        plans[planID] = nil
        let currentIDs = await store.allMatchingIDs(
            query: plan.draft.query,
            filter: plan.draft.filter.shotFilter
        )
        guard currentIDs == plan.shotIDs else { throw AgentActionPlanError.queryDrifted }

        switch plan.draft.payload {
        case .setFavorite(let value):
            store.setFavorite(shotIDs: plan.shotIDs, isFavorite: value)
        case .addTag(let tag):
            store.setTag(shotIDs: plan.shotIDs, name: tag, isPresent: true)
        }
        return AgentActionExecution(
            planID: plan.id,
            action: plan.draft.payload.kind,
            affectedCount: plan.matchCount
        )
    }

    private func pruneExpired(now: Date) {
        plans = plans.filter { now < $0.value.expiresAt }
    }
}
