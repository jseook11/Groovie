import Foundation
import os

/// Lookup façade used by the UI. The catalog is built once on first use; adding
/// a language never requires changing this file.
enum L10n {
    private static let log = Logger(subsystem: "com.umak.app", category: "localization")
    private static let catalog = LocalizationLoader.load()

    static var currentLanguage: String {
        catalog.selectedCode
    }

    static var availableLanguages: [LocalizationLanguage] {
        catalog.languages.values.sorted { $0.code < $1.code }
    }

    static func t(_ key: LocalizationKey) -> String {
        guard let value = catalog.string(for: key.rawValue) else {
            log.error("Missing localization key: \(key.rawValue, privacy: .public)")
            return key.rawValue
        }
        return value
    }

    /// Positional placeholders (`%1$@`, `%2$@`) keep argument order explicit for
    /// languages whose word order differs from English.
    static func t(_ key: LocalizationKey, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }
}
