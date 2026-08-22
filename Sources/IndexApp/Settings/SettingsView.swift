import SwiftUI

struct SettingsView: View {

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettings(settings: settings)
                .tabItem { Label("快捷键", systemImage: "command") }
            AnnotationSettings(settings: settings)
                .tabItem { Label("标注", systemImage: "pencil.tip") }
            SelectionAISettings(settings: settings)
                .tabItem { Label("AI", systemImage: "sparkles") }
            UploadSettings(settings: settings)
                .tabItem { Label("上传", systemImage: "square.and.arrow.up") }
            PluginSettingsView()
                .tabItem { Label("插件", systemImage: "puzzlepiece.extension") }
            StorageSettings()
                .tabItem { Label("存储", systemImage: "internaldrive") }
        }
        // 宽度由宿主决定 —— 它现在嵌在图库窗口里（`GalleryView.settingsMode`），
        // 而不是从前那个固定 500pt 的独立窗口。只留一个下限防止分栏被压扁。
        .frame(minWidth: 460)
    }
}
