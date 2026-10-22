#!/usr/bin/env swift
import Foundation

// Validates every language file against en.json.
//
// Usage: swift Scripts/check-localizations.swift <localization-dir> [--strict]
//
// Errors are always fatal. Warnings become fatal with --strict, which is what
// CI should use once translations for a language are complete.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let directoryArgument = arguments.first else {
    FileHandle.standardError.write(
        Data("usage: check-localizations.swift <localization-dir> [--strict]\n".utf8)
    )
    exit(2)
}
let strict = arguments.contains("--strict")
let directory = URL(fileURLWithPath: directoryArgument, isDirectory: true)
let fileManager = FileManager.default

struct LanguageFile {
    let url: URL
    let code: String
    let name: String
    let fallback: String?
    let complete: Bool
    let strings: [String: String]
}

var errors: [String] = []
var warnings: [String] = []

func error(_ message: String) { errors.append(message) }
func warning(_ message: String) { warnings.append(message) }

func placeholders(_ value: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: "%(?:[0-9]+\\$)?[@d]") else {
        return []
    }
    let range = NSRange(value.startIndex..., in: value)
    return regex.matches(in: value, range: range)
        .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
        .sorted()
}

let files = (try? fileManager.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
))?
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

guard !files.isEmpty else {
    error("no language files found in \(directory.path)")
    exit(1)
}

var languages: [String: LanguageFile] = [:]
for file in files {
    guard
        let data = try? Data(contentsOf: file),
        let parsed = try? JSONSerialization.jsonObject(with: data),
        let object = parsed as? [String: Any]
    else {
        error("\(file.lastPathComponent): invalid JSON object")
        continue
    }

    guard let code = object["language"] as? String, !code.isEmpty else {
        error("\(file.lastPathComponent): missing \"language\"")
        continue
    }
    guard code.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$", options: .regularExpression) != nil else {
        error("\(file.lastPathComponent): invalid language code \"\(code)\"")
        continue
    }
    guard let name = object["name"] as? String, !name.isEmpty else {
        error("\(file.lastPathComponent): missing \"name\"")
        continue
    }
    guard let rawStrings = object["strings"] as? [String: Any] else {
        error("\(file.lastPathComponent): missing \"strings\" object")
        continue
    }

    let expectedName = file.deletingPathExtension().lastPathComponent
    if expectedName != code {
        error("\(file.lastPathComponent): \"language\" is \(code), expected \(expectedName)")
    }

    let fallback = object["fallback"] as? String
    let complete = object["complete"] as? Bool ?? false

    var strings: [String: String] = [:]
    for (key, value) in rawStrings {
        guard let text = value as? String else {
            error("\(file.lastPathComponent): \(key) is not a string")
            continue
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("\(file.lastPathComponent): \(key) is empty")
        }
        strings[key] = text
    }

    languages[code] = LanguageFile(
        url: file,
        code: code,
        name: name,
        fallback: fallback,
        complete: complete,
        strings: strings
    )
}

guard let english = languages["en"] else {
    error("en.json is required and must be the reference language")
    exit(1)
}

for language in languages.values {
    if let fallback = language.fallback, languages[fallback] == nil {
        error("\(language.code): fallback \"\(fallback)\" has no language file")
    }
    guard language.code != "en" else { continue }

    let missing = Set(english.strings.keys).subtracting(language.strings.keys).sorted()
    let extra = Set(language.strings.keys).subtracting(english.strings.keys).sorted()

    if language.complete {
        for key in missing {
            error("\(language.code): complete language is missing \(key)")
        }
        for key in extra {
            error("\(language.code): \(key) does not exist in en")
        }
    } else {
        for key in missing {
            warning("\(language.code): falls back to en for \(key)")
        }
        for key in extra {
            warning("\(language.code): \(key) does not exist in en")
        }
    }

    for (key, value) in language.strings where english.strings[key] != nil {
        let expected = placeholders(english.strings[key] ?? "")
        let actual = placeholders(value)
        if expected != actual {
            error("\(language.code): \(key) placeholders \(actual) do not match en \(expected)")
        }
    }
}

for warning in warnings {
    print("warning: \(warning)")
}
for error in errors {
    print("error: \(error)")
}

if !errors.isEmpty {
    print("Localization check failed: \(errors.count) error(s), \(warnings.count) warning(s)")
    exit(1)
}
if strict && !warnings.isEmpty {
    print("Localization check failed (--strict): \(warnings.count) warning(s)")
    exit(1)
}

print("Localization check passed: \(languages.count) language(s), \(english.strings.count) key(s)")
