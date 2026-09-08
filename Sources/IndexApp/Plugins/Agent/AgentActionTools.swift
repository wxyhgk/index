import Foundation

enum AgentActionTools {
    @MainActor
    static func make(service: AgentActionService) -> [AgentTool] {
        [
            AgentTool(
                name: "list_agent_actions",
                description: "列出 Agent 可计划和执行的批量动作。先查看可用状态，再创建计划。",
                parameters: [:],
                execute: { _ in
                    AgentActionCatalog.descriptors.map { descriptor in
                        let state = descriptor.isAvailable ? "available" : "unavailable"
                        return "\(descriptor.kind.rawValue) [\(state)]: \(descriptor.summary) 参数：\(descriptor.argumentHelp)"
                    }.joined(separator: "\n")
                }
            ),
            AgentTool(
                name: "plan_agent_action",
                description: "只生成批量动作预览，不修改数据。返回命中数量、样例、短期 plan_id 和 confirmation_token。filter 支持 all/favorites/untagged/annotated/recordings/category/tag/app/collection。category、tag、app、collection 需传 filter_value。",
                parameters: [
                    "action": "动作 id：set_favorite 或 add_tag",
                    "value": "动作参数：set_favorite 用 true/false；add_tag 用标签名",
                    "query": "可选关键词；空字符串表示不限制关键词",
                    "filter": "可选筛选，默认 all",
                    "filter_value": "category/tag/app/collection 的值，其他筛选传空字符串",
                    "bundle_id": "filter=app 时可选的 bundle identifier，否则传空字符串"
                ],
                requiredParameters: ["action", "value"],
                execute: { input in
                    do {
                        let draft = try parseDraft(input)
                        let plan = try await service.createPlan(draft)
                        return format(plan)
                    } catch {
                        return "无法创建计划：\(error.localizedDescription)"
                    }
                }
            ),
            AgentTool(
                name: "execute_agent_action",
                description: "执行已预览的批量动作。必须原样传入 plan_id、confirmation_token，并且 confirm=true；查询结果变化或计划过期时拒绝执行。",
                parameters: [
                    "plan_id": "plan_agent_action 返回的 plan_id",
                    "confirmation_token": "plan_agent_action 返回的 confirmation_token",
                    "confirm": "用户明确确认后只能传 true"
                ],
                execute: { input in
                    guard let planID = input["plan_id"], !planID.isEmpty,
                          let token = input["confirmation_token"], !token.isEmpty
                    else { return "无法执行：缺少 plan_id 或 confirmation_token" }
                    do {
                        let execution = try await service.execute(
                            planID: planID,
                            confirmationToken: token,
                            confirm: input["confirm"]?.lowercased() == "true"
                        )
                        return "执行完成：action=\(execution.action.rawValue) affected=\(execution.affectedCount) plan_id=\(execution.planID)"
                    } catch {
                        return "未执行：\(error.localizedDescription)"
                    }
                }
            )
        ]
    }

    static func parseDraft(_ input: [String: String]) throws -> AgentActionDraft {
        guard let rawAction = input["action"],
              let action = AgentActionKind(rawValue: rawAction)
        else {
            throw AgentActionPlanError.unsupportedAction(input["action"] ?? "")
        }
        guard AgentActionCatalog.descriptor(for: action)?.isAvailable == true else {
            throw AgentActionPlanError.unavailableAction(action)
        }
        guard let value = input["value"] else {
            throw AgentActionPlanError.invalidArgument("缺少 value 参数")
        }

        let payload: AgentActionPayload
        switch action {
        case .setFavorite:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": payload = .setFavorite(true)
            case "false": payload = .setFavorite(false)
            default: throw AgentActionPlanError.invalidArgument("set_favorite 的 value 只能是 true 或 false")
            }
        case .addTag:
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { throw AgentActionPlanError.invalidArgument("标签名不能为空") }
            payload = .addTag(tag)
        case .exportZIP:
            throw AgentActionPlanError.unavailableAction(.exportZIP)
        }

        return AgentActionDraft(
            query: input["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            filter: try parseFilter(input),
            payload: payload
        )
    }

    private static func parseFilter(_ input: [String: String]) throws -> AgentShotFilterSpec {
        let name = input["filter"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "all"
        let value = input["filter_value"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch name {
        case "", "all": return .all
        case "favorites": return .favorites
        case "untagged": return .untagged
        case "annotated": return .annotated
        case "recordings": return .recordings
        case "category":
            guard !value.isEmpty else { throw AgentActionPlanError.invalidArgument("category 筛选缺少 filter_value") }
            return .category(value)
        case "tag":
            guard !value.isEmpty else { throw AgentActionPlanError.invalidArgument("tag 筛选缺少 filter_value") }
            return .tag(value)
        case "app":
            guard !value.isEmpty else { throw AgentActionPlanError.invalidArgument("app 筛选缺少 filter_value") }
            return .app(name: value, bundleID: input["bundle_id"])
        case "collection":
            guard let id = Int64(value) else { throw AgentActionPlanError.invalidArgument("collection 的 filter_value 必须是数字 ID") }
            return .collection(id)
        default:
            throw AgentActionPlanError.invalidArgument("未知 filter：\(name)")
        }
    }

    private static func format(_ plan: AgentActionPlan) -> String {
        let sampleText = plan.samples.map { "id=\($0.id) title=\($0.title)" }.joined(separator: "\n")
        return """
        计划预览（尚未修改数据）
        action=\(plan.draft.payload.kind.rawValue)
        operation=\(plan.draft.payload.summary)
        query=\(plan.draft.query.isEmpty ? "(none)" : plan.draft.query)
        filter=\(plan.draft.filter.displayName)
        match_count=\(plan.matchCount)
        samples:
        \(sampleText)
        plan_id=\(plan.id)
        confirmation_token=\(plan.confirmationToken)
        expires_at=\(ISO8601DateFormatter().string(from: plan.expiresAt))
        必须得到用户明确确认后，才可调用 execute_agent_action 并传 confirm=true。
        """
    }
}

