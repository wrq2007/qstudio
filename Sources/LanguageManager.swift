import SwiftUI
import Combine

/// 界面语言。中文原文作为 Localizable.strings 的 key，
/// 通过 @Environment(\.locale) 让所有 Text/Button/.help 在运行时查表切换。
enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var label: String {
        switch self {
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        }
    }

    private init() {
        // MDTESTLANG 自检用：强制语言，不改用户实际偏好
        let forced = ProcessInfo.processInfo.environment["MDTESTLANG"] ?? ""
        let saved = forced.isEmpty ? (UserDefaults.standard.string(forKey: "appLanguage") ?? "") : forced
        self.language = AppLanguage(rawValue: saved) ?? .chinese
    }

    /// 给非 SwiftUI 控件用（如 NSTextField 的 placeholder）：
    /// 这些字符串不经过 @Environment(\.locale)，得手动查 bundle。
    func local(_ key: String) -> String {
        let bundle: Bundle? = {
            let id = language.rawValue
            if let path = Bundle.main.path(forResource: id, ofType: "lproj"),
               let b = Bundle(path: path) { return b }
            return nil
        }()
        guard let bundle else { return key }
        let translated = NSLocalizedString(key, bundle: bundle, comment: "")
        return translated == key && language == .chinese ? key : translated
    }
}

/// 便捷函数：非 SwiftUI 控件取当前语言的文案
func L(_ key: String) -> String { LanguageManager.shared.local(key) }
