import SwiftUI

enum SettingsKey {
    static let theme = "appTheme"
    static let language = "appLanguage"
    static let transferConcurrency = "transferConcurrency"
    static let transferRetries = "transferRetries"
    static let bandwidthLimitEnabled = "bandwidthLimitEnabled"
    static let bandwidthLimitKilobytes = "bandwidthLimitKilobytes"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            transferConcurrency: 3,
            transferRetries: 3,
            bandwidthLimitEnabled: false,
            bandwidthLimitKilobytes: 1024,
        ])
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Languages shipped in `Localizable.xcstrings`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Each language is named in itself so it can be found from any current language.
    var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static var initialSelection: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let locale = Locale(identifier: identifier)
            if let match = allCases.first(where: {
                locale.identifier == $0.rawValue || locale.identifier.hasPrefix($0.rawValue + "-")
            }) {
                return match
            }
            if locale.language.languageCode?.identifier == "zh", locale.language.script?.identifier != "Hant" {
                return .simplifiedChinese
            }
            if let code = locale.language.languageCode?.identifier,
               let match = allCases.first(where: { $0.rawValue == code }) {
                return match
            }
        }
        return .english
    }

    /// Makes strings created outside SwiftUI views (errors, menus built by AppKit) follow the
    /// selection from the next launch on.
    static func persistForBundleLookup(_ language: AppLanguage) {
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}
