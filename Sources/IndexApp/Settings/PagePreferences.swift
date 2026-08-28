import Foundation

/// 页面级 UserDefaults 契约。
///
/// `key` 必须保持历史字符串不变，避免升级后丢失用户已有的窗口与布局偏好；
/// `defaultValue` 则让所有读写点共享同一份首次启动语义。
struct StoredPreference<Value> {
    let key: String
    let defaultValue: Value

    init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

extension StoredPreference where Value == String {
    /// 把集中保存的 raw value 解析成具体页面枚举，避免多个视图重复声明默认 case。
    func enumDefault<T: RawRepresentable>(as type: T.Type) -> T where T.RawValue == String {
        guard let value = T(rawValue: defaultValue) else {
            preconditionFailure("Invalid persisted default \(defaultValue) for \(T.self)")
        }
        return value
    }
}

enum PagePreferences {
    static let galleryInspectorShown = StoredPreference("galleryInspectorShown", default: true)
    static let galleryLayout = StoredPreference("galleryLayout", default: "grid")
    static let galleryZoom = StoredPreference("galleryZoom", default: 200.0)
    static let galleryDestination = StoredPreference("galleryDestination", default: "destination.library")
    static let appsOverviewSort = StoredPreference("appsOverviewSort", default: "captureCount")
    static let editorFilmstripCollapsed = StoredPreference("editorFilmstripCollapsed", default: false)

    static let clipboardPanelPositionSaved = StoredPreference("clipboardPanelPositionSaved", default: false)
    static let clipboardPanelRelativeX = StoredPreference("clipboardPanelRelX", default: 0.0)
    static let clipboardPanelRelativeY = StoredPreference("clipboardPanelRelY", default: 0.0)
}

extension UserDefaults {
    func bool(for preference: StoredPreference<Bool>) -> Bool {
        object(forKey: preference.key) == nil
            ? preference.defaultValue
            : bool(forKey: preference.key)
    }

    func double(for preference: StoredPreference<Double>) -> Double {
        object(forKey: preference.key) == nil
            ? preference.defaultValue
            : double(forKey: preference.key)
    }

    func set<Value>(_ value: Value, for preference: StoredPreference<Value>) {
        set(value, forKey: preference.key)
    }
}
