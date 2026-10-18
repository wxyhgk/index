import Foundation
import AppKit

// MARK: - 剪贴板 AI 每日整理
//
// 每天固定时间（默认 22:00）读取最近 50 条文本剪贴板历史，
// 调 LLM 分析 → 生成标题 + 补充 tags → 写回数据库。
//
// 前提：Agent 已配置（有 LLM API key）且 clipboardAIEnabled = true。
// 定时机制：60s 轮询一次，到目标小时且当天未执行过则触发。

@MainActor
final class ClipboardAIOrganizer {
    static let shared = ClipboardAIOrganizer()

    private var timer: Timer?
    private var isRunning = false
    /// YYYYMMDD 格式（如 20261014），防止同一天重复执行。
    private var lastRunDay: Int?

    /// 每次整理分析的文本条目数量上限。
    private static let batchSize = 50

    private init() {}

    // MARK: - 生命周期

    func start(hour: Int) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRun(hour: hour)
            }
        }
        // 启动时检查：如果 App 在目标时间之前启动且当天还没跑过，补一次。
        checkAndRun(hour: hour)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 定时检查

    private func checkAndRun(hour: Int) {
        let now = Date()
        let cal = Calendar.current
        let currentHour = cal.component(.hour, from: now)
        let currentDay = Self.dayNumber(for: now)

        // 只在目标小时且今天没跑过时触发
        guard currentHour == hour, lastRunDay != currentDay else { return }
        guard !isRunning else { return }

        Task { [weak self] in
            await self?.runOnce()
        }
    }

    /// 手动触发一次（设置页"立即整理"按钮可用）。
    func runNow() {
        guard !isRunning else { return }
        lastRunDay = Self.dayNumber(for: .now)
        Task { [weak self] in
            await self?.runOnce()
        }
    }

    // MARK: - 核心整理逻辑

    private func runOnce() async {
        isRunning = true
        defer { isRunning = false }

        let settings = AppSettings.shared
        guard settings.plugin.agentBaseURL.isEmpty == false,
              settings.plugin.agentModel.isEmpty == false
        else {
            NSLog("[ClipboardAI] Agent 未配置（base URL 或 model 为空），跳过")
            return
        }

        let client = AgentLLMClient(
            baseURL: settings.plugin.agentBaseURL,
            model: settings.plugin.agentModel,
            apiKey: settings.plugin.agentAPIKey
        )

        // 读取最近 N 条，只分析文本
        let store = ClipboardHistoryStore.shared
        guard let items = try? store.recent(limit: Self.batchSize) else { return }
        let textItems = items.filter { $0.kind == .text && ($0.text?.isEmpty == false) }
        guard textItems.count >= 3 else {
            NSLog("[ClipboardAI] 文本条目不足 3 条（当前 \(textItems.count)），跳过")
            return
        }

        // 构建 LLM 请求
        let payload = Self.buildPayload(from: textItems)
        NSLog("[ClipboardAI] 开始分析 \(textItems.count) 条剪贴板…")

        guard let response = await client.simpleChat(system: Self.systemPrompt, user: payload) else {
            NSLog("[ClipboardAI] LLM 响应为空")
            return
        }

        // 解析 + 写回
        let results = Self.parseResponse(response, expectedIDs: Set(textItems.compactMap(\.id)))
        guard !results.isEmpty else {
            NSLog("[ClipboardAI] 解析结果为空: \(response.prefix(200))")
            return
        }

        let updates: [(id: Int64, title: String?, tags: String?, session: String?)] = results.map { result in
            let tagsJSON = result.tags.isEmpty
                ? nil
                : (try? JSONSerialization.data(withJSONObject: result.tags, options: .sortedKeys))
                    .flatMap { String(data: $0, encoding: .utf8) }
            return (id: result.id, title: result.title, tags: tagsJSON, session: result.session)
        }

        do {
            try store.applyAIUpdates(updates)
            NSLog("[ClipboardAI] 完成：分析 \(textItems.count) 条，更新 \(updates.count) 条")
        } catch {
            NSLog("[ClipboardAI] 写回失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Prompt

    private static let systemPrompt = """
        你是剪贴板内容整理助手。用户给你一批最近复制的文本（JSON 数组），请分析并返回 JSON 数组。

        对每条文本返回：
        - "id": 原样返回输入中的 id
        - "title": 简短中文标题（≤20字），概括内容主旨
        - "tags": 标签数组，从以下候选中选择（可多选，不确定不加）
        - "session": 简短项目/任务名（≤15字），表示这批内容属于什么工作上下文。同一批中表达同一工作内容的条目用相同 session 名。无法判断时填 null

        候选 tags:
        url, email, phone, code:swift, code:python, code:javascript, code:typescript, code:rust, code:go, code:java, code:c, code:cpp, code:sql, code:shell, code:html, code:css, code:json, code:yaml, code:xml, code:other, command, path, date, number, ip, uuid, api_key, secret, json, yaml, csv, markdown, log, code_snippet

        session 规则：
        - 用中文，简短直接（如 "hermes-gateway调试"、"分子优化参数"、"周报撰写"）
        - 同一工作上下文的条目用完全相同的 session 名
        - 不同工作内容用不同 session 名
        - 无法判断归属时填 null（如孤立的 URL、单字回复）
        - 不要把"都是命令"当作一个 session——要看具体内容在做什么

        规则：
        1. 只输出 JSON 数组，不要 markdown 代码块、不要解释文字
        2. title 用中文，简短直接
        3. code:xxx 标签只在文本有明确代码语法特征时使用
        4. 有 API key / token / 密码 / 密钥特征时加 "secret"
        5. 每条输入都必须有对应输出，顺序一致
        """

    static func buildPayload(from items: [ClipboardHistoryItem]) -> String {
        let objects: [[String: Any]] = items.compactMap { item in
            guard let id = item.id, let text = item.text else { return nil }
            return [
                "id": id,
                "text": String(text.prefix(500)),
                "source": item.sourceApp ?? ""
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects) else { return "[]" }
        return "以下是用户最近复制的文本（JSON 数组），请分析：\n\(String(data: data, encoding: .utf8) ?? "[]")"
    }

    // MARK: - 响应解析

    struct OrganizeResult {
        let id: Int64
        let title: String?
        let tags: [String]
        let session: String?
    }

    static func parseResponse(_ response: String, expectedIDs: Set<Int64>) -> [OrganizeResult] {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // LLM 可能包在 ```json ... ``` 里
        if json.hasPrefix("```") {
            if let firstNewline = json.firstIndex(of: "\n") {
                json = String(json[json.index(after: firstNewline)...])
            }
            if json.hasSuffix("```") {
                json = String(json.dropLast(3))
            }
            json = json.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { obj in
            guard let id = (obj["id"] as? Int64) ?? (obj["id"] as? NSNumber)?.int64Value,
                  expectedIDs.contains(id)
            else { return nil }
            let title = obj["title"] as? String
            let tags = (obj["tags"] as? [String])?.filter { !$0.isEmpty } ?? []
            let session = (obj["session"] as? String)?.isEmpty == false ? obj["session"] as? String : nil
            return OrganizeResult(id: id, title: title, tags: tags, session: session)
        }
    }

    // MARK: - 工具

    private static func dayNumber(for date: Date) -> Int {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}
