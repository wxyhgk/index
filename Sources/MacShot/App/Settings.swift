import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let copyToClipboard = "copyToClipboard"
        static let runOCR = "runOCR"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Keys.copyToClipboard: true,
            Keys.runOCR: true
        ])
    }

    static var copyToClipboard: Bool {
        get { defaults.bool(forKey: Keys.copyToClipboard) }
        set { defaults.set(newValue, forKey: Keys.copyToClipboard) }
    }

    static var runOCR: Bool {
        get { defaults.bool(forKey: Keys.runOCR) }
        set { defaults.set(newValue, forKey: Keys.runOCR) }
    }
}
