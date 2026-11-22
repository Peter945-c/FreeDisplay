import Foundation

public enum AppLanguage: String {
    case zh
    case en
}

public enum L10n {
    /// Optional runtime override (e.g. via `--lang en` or `--lang zh`); nil means follow macOS system default automatically.
    public static var overrideLanguage: AppLanguage? = nil

    public static var current: AppLanguage {
        if let override = overrideLanguage {
            return override
        }

        // Read global macOS preferred languages directly from system preferences first,
        // falling back to Locale.preferredLanguages so it always reflects System Settings -> Language & Region.
        let globalLangs = CFPreferencesCopyAppValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication
        ) as? [String]

        let candidates = (globalLangs?.isEmpty == false ? globalLangs! : Locale.preferredLanguages)
        for lang in candidates {
            let lower = lang.lowercased()
            if lower.hasPrefix("zh") {
                return .zh
            }
            if lower.hasPrefix("en") {
                return .en
            }
        }
        // If primary language is neither zh nor en, check if first language is Chinese, otherwise default to English
        if let first = candidates.first?.lowercased(), first.hasPrefix("zh") {
            return .zh
        }
        return .en
    }

    public static var isChinese: Bool {
        current == .zh
    }

    public static func tr(zh: String, en: String) -> String {
        isChinese ? zh : en
    }
}
