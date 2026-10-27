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
    private let log = Logger(subsystem: "com.umak.app", category: "desktop-records")

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
        return support.appendingPathComponent("Umak", isDirectory: true)
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

    /// Change several fields of one record with a single write.
    ///
    /// User-visible transitions touch more than one field at once (the style
    /// cycle changes style, `recordOut`, and possibly the clamped position), and
    /// re-encoding the whole document once per field is wasted work.
    /// `screenID` is only applied together with `position`.
    func update(
        id: UUID,
        style: DesktopRecordStyle? = nil,
        recordOut: Bool? = nil,
        position: CGPoint? = nil,
        screenID: String? = nil
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var changed = false

        if let style, records[index].style != style {
            records[index].style = style
            changed = true
        }
        if let recordOut, records[index].recordOut != recordOut {
            records[index].recordOut = recordOut
            changed = true
        }
        if let position {
            if records[index].position != position {
                records[index].position = position
                changed = true
            }
            if records[index].screenID != screenID {
                records[index].screenID = screenID
                changed = true
            }
        }

        if changed { save() }
    }

    /// Apply many position changes with one write (display changes and restore).
    func updatePositions(_ updates: [(id: UUID, position: CGPoint, screenID: String?)]) {
        var changed = false
        for update in updates {
            guard let index = records.firstIndex(where: { $0.id == update.id }) else { continue }
            if records[index].position != update.position {
                records[index].position = update.position
                changed = true
            }
            if records[index].screenID != update.screenID {
                records[index].screenID = update.screenID
                changed = true
            }
        }
        if changed { save() }
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

    /// Minimal view of the document used to check the version before decoding
    /// anything else.
    private struct DocumentHeader: Decodable {
        let version: Int?
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let header = try JSONDecoder().decode(DocumentHeader.self, from: data)
            if let version = header.version,
               version > DesktopRecordDocument.currentVersion
            {
                // Refuse instead of decoding a newer file as this version: the
                // first save would silently drop fields this build cannot see.
                log.error("Desktop records were written by a newer version (\(version)); preserving them as a backup")
                backUpFile(tag: "newer-v\(version)")
                records = []
                return
            }

            let document = try JSONDecoder().decode(DesktopRecordDocument.self, from: data)
            // A v1 document has been migrated in memory by the decoder. Write
            // it back once so the shift and the new `recordOut` flag stick.
            var needsSave = document.version < DesktopRecordDocument.currentVersion

            if document.droppedRecordCount > 0 {
                log.error("Skipped \(document.droppedRecordCount) unreadable desktop record(s)")
                // Only rewrite the file if the original is safely backed up;
                // otherwise the skipped entries would be lost.
                needsSave = backUpFile(tag: "recovered")
            }

            var loaded = document.records
            if loaded.count > DesktopRecordGeometry.maxRecords {
                // A hand-edited file can exceed the cap. Keep the oldest
                // entries, remove the dropped artwork, and persist the
                // truncated list so the extra files do not leak.
                for dropped in loaded.dropFirst(DesktopRecordGeometry.maxRecords) {
                    deleteArtwork(for: dropped)
                }
                loaded = Array(loaded.prefix(DesktopRecordGeometry.maxRecords))
                needsSave = true
            }

            records = loaded
            if needsSave {
                save()
            }
        } catch {
            log.error("Could not read desktop records: \(error.localizedDescription, privacy: .public)")
            backUpFile(tag: "corrupt")
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

    @discardableResult
    private func backUpFile(tag: String) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        var backup = directory.appendingPathComponent("desktop-records.\(tag)-\(stamp).json")
        var suffix = 1
        // Two failures in the same second must not leave the bad file in place,
        // which would repeat the same failure on every launch.
        while fileManager.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("desktop-records.\(tag)-\(stamp)-\(suffix).json")
            suffix += 1
        }
        do {
            try fileManager.moveItem(at: fileURL, to: backup)
            return true
        } catch {
            log.error("Could not back up desktop records: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
