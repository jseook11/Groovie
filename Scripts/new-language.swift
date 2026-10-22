#!/usr/bin/env swift
import Foundation

// Scaffolds a new language file from en.json. English copy is kept as a safe
// placeholder so the app remains usable while the translation is in progress.
//
// Usage: swift Scripts/new-language.swift <code> "<native name>"
// Example: swift Scripts/new-language.swift ja "日本語"

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: new-language.swift <code> \"<native name>\"\n".utf8)
    )
    exit(2)
}

let code = arguments[0]
let name = arguments[1]

guard code.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$", options: .regularExpression) != nil else {
    FileHandle.standardError.write(Data("invalid language code: \(code)\n".utf8))
    exit(2)
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let directory = root.appendingPathComponent("Sources/GroovieKit/Resources/Localization")
let source = directory.appendingPathComponent("en.json")
let destination = directory.appendingPathComponent("\(code).json")

guard !FileManager.default.fileExists(atPath: destination.path) else {
    FileHandle.standardError.write(Data("\(destination.path) already exists\n".utf8))
    exit(1)
}

guard
    let data = try? Data(contentsOf: source),
    let parsed = try? JSONSerialization.jsonObject(with: data),
    var object = parsed as? [String: Any]
else {
    FileHandle.standardError.write(Data("could not read \(source.path)\n".utf8))
    exit(1)
}

object["language"] = code
object["name"] = name
object["fallback"] = "en"
object["complete"] = false
object.removeValue(forKey: "$schema")
object["$schema"] = "../../../../docs/localization/schema.json"

guard
    JSONSerialization.isValidJSONObject(object),
    let output = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
else {
    FileHandle.standardError.write(Data("could not encode \(code).json\n".utf8))
    exit(1)
}

try output.write(to: destination)

print("Created \(destination.relativePath)")
print("")
print("Next:")
print("  1. Translate the values in \(code).json (keep keys and %1$@ placeholders).")
print("  2. Run: make l10n-check")
print("  3. Build and try it: make app && open build/Groovie.app --args --lang=\(code)")
print("  4. When every key is translated, set \"complete\": true.")
