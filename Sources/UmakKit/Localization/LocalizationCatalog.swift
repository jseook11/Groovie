import Foundation
import os

/// One language file. A language can be partial; missing keys fall through the
/// fallback chain (normally to English).
struct LocalizationLanguage {
    let code: String
    let name: String
    let fallback: String?
    let complete: Bool
    let strings: [String: String]
}

/// Immutable snapshot of all discovered languages plus the resolved choice for
/// this launch. Selection follows the system language list unless `--lang=` or
/// the stored `umak.language` preference overrides it.
struct LocalizationCatalog {
    let languages: [String: LocalizationLanguage]
    let selectedCode: String
    private let chain: [String]

    init(
        languages: [String: LocalizationLanguage],
        preferred: [String]
    ) {
        self.languages = languages

        let selected = Self.bestMatch(for: preferred, in: languages)
            ?? (languages["en"] != nil ? "en" : nil)
            ?? languages.keys.sorted().first
            ?? "en"
        self.selectedCode = selected

        var chain: [String] = []
        var cursor: String? = selected
        while let code = cursor, let language = languages[code], !chain.contains(code) {
            chain.append(code)
            cursor = language.fallback
        }
        if !chain.contains("en") {
            chain.append("en")
        }
        self.chain = chain
    }

    var selected: LocalizationLanguage? {
        languages[selectedCode]
    }

    func string(for key: String) -> String? {
        for code in chain {
            if let value = languages[code]?.strings[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// First language whose code or language subtag matches a preferred tag.
    /// `ko-KR` matches `ko`, and `zh-Hant-TW` prefers an exact file before `zh`.
    static func bestMatch(
        for preferred: [String],
        in languages: [String: LocalizationLanguage]
    ) -> String? {
        for raw in preferred {
            let tag = raw.replacingOccurrences(of: "_", with: "-")
            if languages[tag] != nil { return tag }

            let base = tag.split(separator: "-").first.map(String.init) ?? tag
            if languages[base] != nil { return base }

            if let match = languages.keys.sorted().first(where: {
                $0.split(separator: "-").first.map(String.init) == base
            }) {
                return match
            }
        }
        return nil
    }
}

/// Loads language files from the app bundle and the SwiftPM resource bundle.
///
/// Lookup order (later directories override earlier ones):
/// 1. `Umak_UmakKit.bundle/Localization` — strings shipped with the app
/// 2. `Bundle.main/Contents/Resources/Localization` — drop-in overrides
enum LocalizationLoader {
    static let directoryName = "Localization"
    static let defaultsKey = "umak.language"

    private static let log = Logger(subsystem: "com.umak.app", category: "localization")

    /// Embedded languages first, then files placed next to the app so a
    /// translator can test a language without rebuilding.
    static func directories() -> [URL] {
        var result: [URL] = []
        if let module = Bundle.module.resourceURL?
            .appendingPathComponent(directoryName),
           isDirectory(module) {
            result.append(module)
        }
        if let main = Bundle.main.resourceURL?
            .appendingPathComponent(directoryName),
           isDirectory(main), main != result.first {
            result.append(main)
        }
        return result
    }

    static func load(explicit: String? = nil) -> LocalizationCatalog {
        var languages: [String: LocalizationLanguage] = [:]
        for directory in directories() {
            for url in jsonFiles(in: directory) {
                guard let language = decode(url) else { continue }
                languages[language.code] = language
            }
        }

        if languages.isEmpty {
            log.error("No localization files found")
        }

        let requested = explicit ?? requestedLanguage()
        let preferred = requested.map { [$0] } ?? Locale.preferredLanguages
        return LocalizationCatalog(languages: languages, preferred: preferred)
    }

    /// `--lang=<code>` wins for screenshots and development, then a stored
    /// in-app choice. `system` means follow the preferred-language list.
    static func requestedLanguage() -> String? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--lang=") {
            let code = String(argument.dropFirst("--lang=".count))
            return code.isEmpty ? nil : code
        }
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), stored != "system" {
            return stored
        }
        return nil
    }

    private static func jsonFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private struct File: Decodable {
        let language: String
        let name: String?
        let fallback: String?
        let complete: Bool?
        let strings: [String: String]
    }

    private static func decode(_ url: URL) -> LocalizationLanguage? {
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(File.self, from: data)
            return LocalizationLanguage(
                code: file.language,
                name: file.name ?? file.language,
                fallback: file.fallback,
                complete: file.complete ?? false,
                strings: file.strings
            )
        } catch {
            log.error("Could not read \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
