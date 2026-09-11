import SwiftUI
import GRDB

struct SyncSettings: View {
    @ObservedObject var settings: AppSettings

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var syncResult: String?
    @State private var syncErrors: [String] = []
    @State private var syncSucceeded = false
    @State private var syncProgress: SyncProgress?

    var body: some View {
        SettingsPage {
            SettingsCard("WebDAV 服务器", icon: "externaldrive") {
                Toggle("启用云同步", isOn: $settings.sync.enabled)

                DebouncedTextField(
                    title: "服务器地址",
                    placeholder: "http://ds720.local:5005/webdav",
                    initialValue: settings.sync.serverURL,
                    monospaced: true
                ) { settings.sync.serverURL = $0 }

                DebouncedTextField(
                    title: "用户名",
                    placeholder: "wxyhgk",
                    initialValue: settings.sync.username,
                    monospaced: true
                ) { settings.sync.username = $0 }

                SecureField("密码", text: Binding(
                    get: { settings.sync.password },
                    set: { settings.sync.password = $0 }
                ))
                .font(.system(size: DS.font13, design: .monospaced))

                DebouncedTextField(
                    title: "子目录",
                    placeholder: "index",
                    initialValue: settings.sync.subPath,
                    monospaced: true
                ) { settings.sync.subPath = $0 }
            }

            MiniCard("测试连接", icon: "network") {
                HStack(spacing: DS.s3) {
                    Button(isTesting ? "连接中…" : "测试连接") { runTest() }
                        .disabled(isTesting || !canConnect)
                    if isTesting { ProgressView().controlSize(.mini) }
                }
                if let testResult {
                    HStack(spacing: DS.s2) {
                        Image(systemName: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: DS.font12))
                            .foregroundStyle(testSucceeded ? .green : .red)
                        Text(testResult)
                            .font(.system(size: DS.font11))
                            .foregroundStyle(testSucceeded ? .green : .red)
                            .textSelection(.enabled)
                    }
                }
            }

            MiniCard("同步", icon: "arrow.triangle.2.circlepath") {
                HStack(spacing: DS.s3) {
                    Button(isBackingUp ? "备份中…" : "备份到云端") { runBackup() }
                        .disabled(isBackingUp || isRestoring || !canConnect)
                    Button(isRestoring ? "恢复中…" : "从云端恢复") { runRestore() }
                        .disabled(isBackingUp || isRestoring || !canConnect)
                    if isBackingUp || isRestoring { ProgressView().controlSize(.mini) }
                }
                if (isBackingUp || isRestoring), let progress = syncProgress {
                    VStack(alignment: .leading, spacing: DS.s2) {
                        if progress.total > 0 {
                            ProgressView(value: progress.fraction)
                        } else {
                            ProgressView()
                        }
                        Text("\(progress.phase) \(progress.current)/\(progress.total)")
                            .font(.system(size: DS.font11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let syncResult {
                    HStack(spacing: DS.s2) {
                        Image(systemName: syncSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: DS.font12))
                            .foregroundStyle(syncSucceeded ? .green : .red)
                        Text(syncResult)
                            .font(.system(size: DS.font11))
                            .foregroundStyle(syncSucceeded ? .green : .red)
                            .textSelection(.enabled)
                    }
                    if !syncErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(syncErrors.prefix(10), id: \.self) { err in
                                Text(err)
                                    .font(.system(size: DS.font10, design: .monospaced))
                                    .foregroundStyle(.red.opacity(0.8))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                            if syncErrors.count > 10 {
                                Text("… 还有 \(syncErrors.count - 10) 个错误")
                                    .font(.system(size: DS.font10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var canConnect: Bool {
        !settings.sync.serverURL.isEmpty && !settings.sync.username.isEmpty
    }

    private func makeEngine() -> SyncEngine? {
        let config = WebDAVConfig(
            baseURL: settings.sync.serverURL,
            username: settings.sync.username,
            password: settings.sync.password,
            subPath: settings.sync.subPath
        )
        guard config.fullBaseURL != nil else { return nil }
        let context = ShotStore.shared.syncContext
        return SyncEngine(
            config: config,
            database: context.database,
            rootDirectory: context.rootDirectory
        )
    }

    private func runTest() {
        guard let engine = makeEngine() else {
            testResult = "服务器地址无效"
            testSucceeded = false
            return
        }
        isTesting = true
        testResult = nil
        Task {
            do {
                let message = try await engine.testConnection()
                testResult = message
                testSucceeded = true
            } catch {
                testResult = error.localizedDescription
                testSucceeded = false
            }
            isTesting = false
        }
    }

    private func runBackup() {
        guard let engine = makeEngine() else { return }
        isBackingUp = true
        syncResult = nil
        syncErrors = []
        syncProgress = nil
        Task {
            do {
                let result = try await engine.backup { progress in
                    Task { @MainActor in
                        self.syncProgress = progress
                    }
                }
                syncResult = result.summary
                syncErrors = result.errors
                syncSucceeded = result.errors.isEmpty
            } catch {
                syncResult = error.localizedDescription
                syncErrors = [error.localizedDescription]
                syncSucceeded = false
            }
            isBackingUp = false
            syncProgress = nil
        }
    }

    private func runRestore() {
        guard let engine = makeEngine() else { return }
        isRestoring = true
        syncResult = nil
        syncErrors = []
        Task {
            do {
                let result = try await engine.restore()
                syncResult = result.summary
                syncErrors = result.errors
                syncSucceeded = result.errors.isEmpty
            } catch {
                syncResult = error.localizedDescription
                syncErrors = [error.localizedDescription]
                syncSucceeded = false
            }
            isRestoring = false
        }
    }
}
