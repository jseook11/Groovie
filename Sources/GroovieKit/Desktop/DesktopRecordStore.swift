import AppKit
import Foundation
import os

/// JSON and artwork cache for desktop records.
///
/// Writing happens on the main actor because the files are tiny and changes are
/// user-paced (create, drop, delete). Artwork is PNG so a record still renders
/// when Music is closed or the track is no longer available.
@MainActor
final class DesktopRecordStore {
    private(set) var records: [DesktopRecord] = []

    private let fileManager: FileManager
    private let directory: URL
    private let fileURL: URL
    private let artworkDirectory: URL
    private let log = Logger(subsystem: "com.groovie.app", category: "desktop-records")

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = baseDirectory ?? Self.defaultDirectory(fileManager: fileManager)
        directory = base
        fileURL = base.appendingPathComponent("desktop-records.json")
        artworkDirectory = base.appendingPathComponent("artwork", isDirectory: true)

        do {
            try fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        } catch {
            log.error("Could not create artwork directory: \(error.localizedDescription, privacy: .public)")
        }
        load()
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Groovie", isDirectory: true)
    }

    // MARK: - Mutations

    @discardableResult
    func insert(_ record: DesktopRecord) -> Bool {
        guard records.count < DesktopRecordGeometry.maxRecords else { return false }
        guard !records.contains(where: { $0.id == record.id }) else { return false }
        records.append(record)
        save()
        return true
    }

    func updatePosition(id: UUID, position: CGPoint, screenID: String?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].position != position || records[index].screenID != screenID else { return }
        records[index].position = position
        records[index].screenID = screenID
        save()
    }

    func updateStyle(id: UUID, style: DesktopRecordStyle) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].style != style else { return }
        records[index].style = style
        save()
    }

    /// Slide a sleeve's record out or tuck it back in. Ignored by `.disc` at
    /// draw time, but still persisted so a later style switch remembers it.
    func updateRecordOut(id: UUID, recordOut: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].recordOut != recordOut else { return }
        records[index].recordOut = recordOut
        save()
    }

    func remove(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let removed = records.remove(at: index)
        deleteArtwork(for: removed)
        save()
    }

    func removeAll() {
        let removed = records
        records.removeAll()
        for record in removed {
            deleteArtwork(for: record)
        }
        save()
    }

    // MARK: - Artwork

    /// Persist the current track's artwork and return the file name to store in
    /// the snapshot. Failure is not fatal: the record falls back to its printed
    /// label and still appears on the desktop.
    func writeArtwork(_ image: NSImage, id: UUID) -> String? {
        guard let data = Self.pngData(from: image) else { return nil }
        let name = "\(id.uuidString.lowercased()).png"
        let url = artworkDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            log.error("Could not write artwork: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func artwork(for record: DesktopRecord) -> NSImage? {
        guard let url = artworkURL(for: record.track.artworkFile) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func deleteArtwork(for record: DesktopRecord) {
        guard let url = artworkURL(for: record.track.artworkFile) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Artwork names are written by this store as `<uuid>.png`, but the JSON is
    /// user-writable. Accept only a single path component so a crafted record
    /// cannot read or delete files outside the artwork directory.
    private func artworkURL(for name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let safe = (name as NSString).lastPathComponent
        guard safe == name, safe != ".", safe != ".." else { return nil }
        return artworkDirectory.appendingPathComponent(safe)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Disk

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(DesktopRecordDocument.self, from: data)
            // A v1 document has been migrated in memory by the decoder. Write
            // it back once so the shift and the new `recordOut` flag stick.
            let needsMigration = document.version < DesktopRecordDocument.currentVersion

            if document.records.count > DesktopRecordGeometry.maxRecords {
                // A hand-edited or future file can exceed the cap. Keep the
                // oldest entries, remove the dropped artwork, and persist the
                // truncated list so the extra files do not leak.
                let kept = Array(document.records.prefix(DesktopRecordGeometry.maxRecords))
                for dropped in document.records.dropFirst(DesktopRecordGeometry.maxRecords) {
                    deleteArtwork(for: dropped)
                }
                records = kept
                save()
            } else {
                records = document.records
                if needsMigration {
                    save()
                }
            }
        } catch {
            log.error("Could not read desktop records: \(error.localizedDescription, privacy: .public)")
            backUpCorruptFile()
            records = []
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let document = DesktopRecordDocument(records: records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Could not save desktop records: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func backUpCorruptFile() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = directory.appendingPathComponent("desktop-records.corrupt-\(stamp).json")
        do {
            try fileManager.moveItem(at: fileURL, to: backup)
        } catch {
            log.error("Could not back up corrupt records: \(error.localizedDescription, privacy: .public)")
        }
    }
}
