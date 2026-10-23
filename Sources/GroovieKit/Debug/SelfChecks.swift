import AppKit
import Foundation

/// Headless checks for the pure interaction model. Run with `--self-test`.
/// (XCTest is not part of the Command Line Tools installation.)
public enum SelfChecks {
    public static func run() -> Int {
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func approx(_ a: Double, _ b: Double, _ epsilon: Double = 0.0001) -> Bool {
            abs(a - b) < epsilon
        }

        // MARK: Sensitivity

        let tuning = ScrubTuning.default
        let engineForCurve = ScrubEngine()
        var previous = -Double.infinity
        for speed in [0.0, 10, 100, 500, 1500, 4000, 7000] {
            let value = engineForCurve.sensitivity(forSpeed: speed)
            expect(value > previous, "sensitivity must be monotonically increasing at \(speed)")
            previous = value
        }
        expect(approx(engineForCurve.sensitivity(forSpeed: 7000), tuning.maxSensitivity),
               "sensitivity must reach the cap")
        expect(approx(engineForCurve.sensitivity(forSpeed: 99_999), tuning.maxSensitivity),
               "sensitivity must stay capped")

        // MARK: Direction

        func makeEngine(base: Double = 100, duration: Double = 200) -> ScrubEngine {
            var engine = ScrubEngine()
            engine.begin(x: 0, timestamp: 0, basePosition: base, duration: duration)
            return engine
        }

        var right = makeEngine()
        let rightResult = right.update(x: 20, timestamp: 0.1)
        expect(rightResult.delta < 0, "dragging right must rewind")
        expect(rightResult.angleDelta < 0, "dragging right must rotate counter-clockwise")
        expect(rightResult.position < 100, "rewind must move the position backwards")

        var left = makeEngine()
        let leftResult = left.update(x: -20, timestamp: 0.1)
        expect(leftResult.delta > 0, "dragging left must advance")
        expect(leftResult.angleDelta > 0, "dragging left must rotate clockwise")

        // MARK: Reversal

        var reversal = makeEngine()
        _ = reversal.update(x: 30, timestamp: 0.1)
        let before = reversal.accumulated
        let reversed = reversal.update(x: 20, timestamp: 0.2)
        expect(reversed.delta > before, "direction reversal must take effect immediately")

        // MARK: Velocity amplification

        var slow = makeEngine()
        let slowResult = slow.update(x: 10, timestamp: 0.5)
        var fast = makeEngine()
        let fastResult = fast.update(x: 10, timestamp: 0.004)
        expect(abs(fastResult.delta) > abs(slowResult.delta) * 2, "fast movement must seek much further")
        expect(abs(slowResult.delta) > 0.0, "slow movement must still seek")

        // MARK: Clamping

        var atStart = makeEngine(base: 0)
        let startResult = atStart.update(x: 100, timestamp: 0.1)
        expect(approx(startResult.delta, 0), "cannot rewind before zero")
        expect(approx(startResult.angleDelta, 0), "the disc must stop at the start of the track")
        expect(startResult.hitStart, "hitting the start must be reported")
        let startReversal = atStart.update(x: 90, timestamp: 0.2)
        expect(startReversal.angleDelta > 0, "the disc must rotate again after reversing")
        expect(startReversal.delta > 0, "reversing at zero must advance immediately")

        var atEnd = makeEngine(base: 199.5, duration: 200)
        let endResult = atEnd.update(x: -100, timestamp: 0.1)
        expect(approx(endResult.position, 199.85), "seeking must stop just before the end")
        expect(endResult.hitEnd, "hitting the end must be reported")

        // MARK: Wiggle cancel

        var wiggle = WiggleDetector()
        var wiggleTriggered = false
        var wiggleX: Double = 0
        for i in 1...6 {
            wiggleX = (i % 2 == 1) ? 10 : 0
            if wiggle.update(x: wiggleX, timestamp: Double(i) * 0.1) {
                wiggleTriggered = true
            }
        }
        expect(wiggleTriggered, "a left-right wiggle must be detected")

        var jitter = WiggleDetector()
        var jitterTriggered = false
        for i in 1...10 {
            let x: Double = (i % 2 == 1) ? 2 : 0
            if jitter.update(x: x, timestamp: Double(i) * 0.05) {
                jitterTriggered = true
            }
        }
        expect(!jitterTriggered, "tiny jitter must not cancel a seek")

        var slowWiggle = WiggleDetector()
        var slowTriggered = false
        for i in 1...8 {
            let x: Double = (i % 2 == 1) ? 20 : 0
            if slowWiggle.update(x: x, timestamp: Double(i) * 0.4) {
                slowTriggered = true
            }
        }
        expect(!slowTriggered, "slow alternating strokes outside the window must not cancel")

        let natural = ScrollDirection.physical(deltaX: 10, deltaY: -10, invertedFromDevice: true, precise: true)
        let traditional = ScrollDirection.physical(deltaX: -10, deltaY: 10, invertedFromDevice: false, precise: true)
        expect(natural.right > 0, "natural scrolling: rightward gesture scrubs right")
        expect(traditional.right > 0, "traditional scrolling maps the opposite horizontal sign")
        expect(natural.pull == traditional.pull, "both scrolling preferences must produce the same vertical pull")
        expect(natural.pull < 0, "the vertical direction is inverted relative to the first implementation")

        // MARK: Scroll axis lock

        var axisLock = ScrollAxisLock()
        expect(axisLock.update(right: 10, pull: 1) == .horizontal,
               "a clearly horizontal scroll must lock the horizontal axis")
        expect(approx(axisLock.horizontalTravel, 10), "horizontal travel must accumulate")
        expect(axisLock.update(right: 0, pull: 40) == .horizontal,
               "a locked axis must not flip mid-gesture")
        expect(approx(axisLock.horizontalTravel, 10),
               "vertical movement after the lock must not count as travel")

        axisLock.reset()
        expect(axisLock.update(right: 1, pull: 10) == .vertical,
               "a vertical scroll must lock the vertical axis")
        expect(axisLock.update(right: 40, pull: 0) == .vertical,
               "later horizontal drift must not revive a skip")

        var ambiguous = ScrollAxisLock()
        expect(ambiguous.update(right: 14, pull: 10) == .undecided,
               "a diagonal gesture must not decide the axis immediately")
        expect(ambiguous.update(right: 16, pull: 10) == .horizontal,
               "a subsequent clearly horizontal event must lock it")

        axisLock.reset()
        expect(axisLock.update(right: -10, pull: 0) == .horizontal,
               "leftward scrolling must also lock horizontally")
        expect(approx(axisLock.horizontalTravel, -10), "leftward travel must be signed")

        // MARK: Confirm meter

        var slowMeter = ConfirmAccumulator()
        slowMeter.begin(extra: 0, timestamp: 0, distance: 240)
        for step in 1...3 {
            _ = slowMeter.update(extra: CGFloat(step * 40), timestamp: Double(step) * 0.5)
        }
        expect(!slowMeter.isComplete, "a slow 120 pt pull must not fill a 240 pt meter")
        expect(slowMeter.progress > 0.45 && slowMeter.progress < 0.6,
               "slow pull progress should track raw distance")

        var fastMeter = ConfirmAccumulator()
        fastMeter.begin(extra: 0, timestamp: 0, distance: 240)
        for step in 1...3 {
            _ = fastMeter.update(extra: CGFloat(step * 40), timestamp: Double(step) * 0.02)
        }
        expect(fastMeter.isComplete, "a fast 120 pt pull must fill the meter via acceleration")
        expect(fastMeter.progress > slowMeter.progress, "faster pulls must fill the meter faster")

        var backingOff = ConfirmAccumulator()
        backingOff.begin(extra: 0, timestamp: 0, distance: 240)
        _ = backingOff.update(extra: 120, timestamp: 0.6)
        let high = backingOff.progress
        _ = backingOff.update(extra: 60, timestamp: 1.2)
        expect(backingOff.progress < high, "moving back up must reduce the confirm meter")

        let meter = ConfirmAccumulator()
        expect(meter.accelerationFactor(forSpeed: 200) < 1.2, "slow pulls stay near 1x")
        expect(meter.accelerationFactor(forSpeed: 1800) > 3.0, "fast pulls approach 3.2x")

        var prefilled = ConfirmAccumulator()
        prefilled.begin(extra: 120, timestamp: 0, distance: 240)
        expect(prefilled.progress == 0,
               "the confirm gauge must start empty at the snap, not from the opening pull")

        // MARK: Layout

        let layout = VinylLayout(emergenceInset: 32)
        expect(layout.exposure(forPullDistance: 0) == 0, "no pull, no exposure")
        expect(layout.exposure(forPullDistance: -20) == 0, "negative pull cannot expose the disc")
        var lastExposure: CGFloat = -1
        var monotonic = true
        for step in stride(from: 0.0, through: 200.0, by: 5.0) {
            let exposure = layout.exposure(forPullDistance: CGFloat(step))
            if exposure < lastExposure { monotonic = false }
            lastExposure = exposure
        }
        expect(monotonic, "exposure must increase with pull distance")
        expect(layout.exposure(forPullDistance: 1000) == layout.maxExposure, "exposure must be capped")
        expect(layout.fullExposure >= 80 && layout.fullExposure <= 110,
               "full exposure must be in the 80–110 range")
        expect(approx(layout.recordCenterY(exposure: layout.fullExposure), layout.emergenceInset),
               "the fully extracted record centre must sit on the notch edge")
        let detentExposure = layout.exposure(forPullDistance: layout.grabDetent)
        expect(detentExposure > 30 && detentExposure < layout.fullExposure * 0.6,
               "the magnetic detent must sit around halfway")
        expect(layout.recordCenterY(exposure: 0) < layout.recordCenterY(exposure: layout.fullExposure),
               "the record must move down as it is pulled out")
        expect(layout.confirmDistance == 240, "the pointer confirm distance should stay generous")
        expect(layout.scrollConfirmDistance == layout.confirmDistance * 2,
               "scroll confirm should require twice the pointer travel")
        expect(layout.confirmScrubDeadzone == 90,
               "the confirm phase should use a 3x wider horizontal dead-zone")
        expect(layout.scrollSkipDistance == 90,
               "a track skip must require a deliberate horizontal swipe")
        expect(layout.clickSlop == 4,
               "a click may drift 4 points before it counts as a drag")

        let flat = VinylLayout(emergenceInset: 0)
        expect(approx(flat.recordCenterY(exposure: flat.fullExposure), 0),
               "on a display without a notch the centre must sit on the screen's top edge")

        // The pinned record doubles as a play/pause button, but only on the
        // centre label; the rest of the vinyl keeps its click-to-close action.
        let stageSize = CGSize(width: layout.windowWidth, height: layout.windowHeight)
        let labelCenter = layout.recordCenter(in: stageSize, exposure: layout.fullExposure)
        expect(layout.isOnLabel(labelCenter, exposure: layout.fullExposure),
               "the record centre must be the play/pause target")
        expect(layout.isOnLabel(
            CGPoint(x: labelCenter.x + layout.labelHitRadius - 1, y: labelCenter.y),
            exposure: layout.fullExposure
        ), "the label hit target must include its slop")
        expect(!layout.isOnLabel(
            CGPoint(x: labelCenter.x + layout.labelHitRadius + 2, y: labelCenter.y),
            exposure: layout.fullExposure
        ), "a point beyond the label target must not toggle playback")
        expect(!layout.isOnLabel(
            CGPoint(x: labelCenter.x, y: labelCenter.y + layout.recordRadius * 0.8),
            exposure: layout.fullExposure
        ), "clicking the outer vinyl must still put the record away")
        expect(layout.labelHitRadius < layout.recordRadius,
               "the label target must stay inside the record")
        expect(layout.hoverRegion(at: labelCenter, exposure: layout.fullExposure) == .label,
               "the label must be the play/pause hover region")
        expect(layout.hoverRegion(
            at: CGPoint(x: labelCenter.x, y: labelCenter.y + layout.labelHitRadius + 8),
            exposure: layout.fullExposure
        ) == .vinyl, "the vinyl ring must be the put-away hover region")
        expect(layout.hoverRegion(
            at: CGPoint(x: labelCenter.x, y: labelCenter.y + layout.recordRadius + 4),
            exposure: layout.fullExposure
        ) == .none, "a point outside the record must not react")

        // MARK: Music read parsing

        let delimiter = "\u{1F}"
        let raw = ["playing", "95432", "ABC123", "Blue in Green", "Miles Davis", "Kind of Blue", "337000"]
            .joined(separator: delimiter)
        switch AppleMusicBridge.parse(raw) {
        case .success(.track(let state, let position, let id, let title, let artist, let album, let duration)):
            expect(state == "playing", "state parse")
            expect(position == 95432, "position parse")
            expect(id == "ABC123", "id parse")
            expect(title == "Blue in Green", "title parse")
            expect(artist == "Miles Davis", "artist parse")
            expect(album == "Kind of Blue", "album parse")
            expect(duration == 337000, "duration parse")
        default:
            expect(false, "track read must parse")
        }
        expect((try? AppleMusicBridge.parse("NOTRUNNING").get()) == .notRunning, "not-running parse")
        expect((try? AppleMusicBridge.parse("NOTRACK").get()) == .noTrack, "no-track parse")

        // MARK: Recent tracking

        var recent = RecentSet<Int>(limit: 3)
        recent.insert(1)
        recent.insert(2)
        recent.insert(3)
        expect(recent.contains(1) && recent.contains(3), "recent set keeps inserted values")
        recent.insert(4)
        expect(!recent.contains(1), "recent set evicts the oldest value")
        expect(recent.contains(2) && recent.contains(4), "recent set keeps the newest values")
        recent.insert(2)
        recent.insert(5)
        expect(recent.contains(2), "refreshing a value keeps it")
        expect(!recent.contains(3), "a refreshed value is not evicted")
        recent.removeAll()
        expect(recent.count == 0 && !recent.contains(2), "recent set can be cleared")

        // MARK: Formatter

        expect(TimeOffsetFormatter.string(for: -2.74) == "−2.7s", "negative offset formatting")
        expect(TimeOffsetFormatter.string(for: 3.41) == "+3.4s", "positive offset formatting")
        expect(TimeOffsetFormatter.string(for: 0.01) == "0.0s", "zero offset formatting")
        expect(TimeOffsetFormatter.string(for: 63.4) == "+1:03.4", "minute offset formatting")

        // MARK: Skins

        let skinIDs = VinylSkin.all.map(\.id)
        expect(Set(skinIDs).count == skinIDs.count, "skin ids must be unique")
        expect(skinIDs.contains(VinylSkin.defaultID), "the default skin must exist")
        expect(VinylSkin.skin(id: "does-not-exist").id == VinylSkin.defaultID,
               "unknown skin ids must fall back to the default")

        func luminance(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * rgb.redComponent
                + 0.7152 * rgb.greenComponent
                + 0.0722 * rgb.blueComponent
        }
        func spread(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            return max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                - min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }

        for skin in VinylSkin.all {
            let centre = luminance(skin.recordCenter)
            let edge = luminance(skin.recordEdge)
            expect(centre > edge, "\(skin.id): the record centre must be lighter than its edge")
            expect(centre > 0.045, "\(skin.id): the record must read against the black notch")
        }

        let trackSeed = "Miles Davis|Blue in Green"
        let classicAccent = VinylSkin.classic.labelAccent(for: trackSeed)
        let monoAccent = VinylSkin.mono.labelAccent(for: trackSeed)
        expect(spread(monoAccent) < spread(classicAccent) * 0.5,
               "the mono skin must desaturate the track accent")

        // MARK: Demo player

        MainActor.assumeIsolated {
            let demo = DemoMusicService()
            let firstTitle = demo.nowPlaying?.title
            expect(demo.nowPlaying?.isPlaying == true, "the demo must start playing")
            demo.skipToNext()
            expect(demo.nowPlaying?.title != firstTitle, "a demo skip must change the track")
            expect(demo.nowPlaying?.position == 0, "a skipped-to track must start at zero")
            demo.skipToPrevious()
            expect(demo.nowPlaying?.title == firstTitle, "a demo previous skip must return")
        }

        // MARK: Localization

        func placeholders(_ value: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: "%(?:[0-9]+\\$)?[@d]") else {
                return []
            }
            let range = NSRange(value.startIndex..., in: value)
            return regex.matches(in: value, range: range)
                .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
                .sorted()
        }

        let english = LocalizationLoader.load(explicit: "en")
        let korean = LocalizationLoader.load(explicit: "ko")
        expect(english.selectedCode == "en", "en must resolve to itself")
        expect(korean.selectedCode == "ko", "ko must resolve to itself")
        expect(english.languages["en"]?.complete == true, "en must be marked complete")
        expect(korean.languages["ko"]?.complete == true, "ko must be marked complete")

        let englishStrings = english.languages["en"]?.strings ?? [:]
        let koreanStrings = korean.languages["ko"]?.strings ?? [:]
        for key in LocalizationKey.allCases {
            expect(englishStrings[key.rawValue] != nil,
                   "en is missing \(key.rawValue)")
            expect(koreanStrings[key.rawValue] != nil,
                   "ko is missing \(key.rawValue)")
            expect(placeholders(englishStrings[key.rawValue] ?? "")
                   == placeholders(koreanStrings[key.rawValue] ?? ""),
                   "\(key.rawValue): placeholders must match between en and ko")
        }
        expect(Set(englishStrings.keys) == Set(koreanStrings.keys),
               "en and ko must define the same keys")
        expect(Set(englishStrings.keys) == Set(LocalizationKey.allCases.map(\.rawValue)),
               "en must define exactly the keys declared by LocalizationKey")

        // A partial language must fall back per key, and an unknown language
        // must fall back to English rather than showing raw keys.
        let partialEnglish = LocalizationLanguage(
            code: "en",
            name: "English",
            fallback: nil,
            complete: true,
            strings: ["a": "A", "b": "B %1$@", "c": "C"]
        )
        let partialJapanese = LocalizationLanguage(
            code: "ja",
            name: "日本語",
            fallback: "en",
            complete: false,
            strings: ["a": "あ"]
        )
        let partial = LocalizationCatalog(
            languages: ["en": partialEnglish, "ja": partialJapanese],
            preferred: ["ja-JP"]
        )
        expect(partial.selectedCode == "ja", "ja-JP must match the ja file")
        expect(partial.string(for: "a") == "あ", "a translated key must win")
        expect(partial.string(for: "b") == "B %1$@", "a missing key must fall back to English")

        let unknown = LocalizationCatalog(
            languages: ["en": partialEnglish, "ja": partialJapanese],
            preferred: ["de-DE", "fr"]
        )
        expect(unknown.selectedCode == "en", "an unavailable language must fall back to English")
        expect(unknown.string(for: "missing") == nil, "a key absent everywhere must be reported as missing")

        let format = englishStrings["a11y.headerTitleArtist"] ?? ""
        let formatted = String(
            format: format,
            locale: Locale(identifier: "en"),
            arguments: ["Song", "Artist"]
        )
        expect(formatted == "Groovie, Song, Artist",
               "positional placeholders must format with the supplied arguments")

        expect(L10n.availableLanguages.map(\.code).contains("en"),
               "the bundled catalog must expose en")
        expect(!L10n.t(.menuQuit).isEmpty,
               "L10n must resolve a bundled key")
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--lang=") {
            let requested = String(argument.dropFirst("--lang=".count))
            expect(L10n.currentLanguage == requested,
                   "--lang=\(requested) must select that language")
        }

        // MARK: Update checker

        expect(UpdateChecker.isNewer("0.1.2", than: "0.1.1"), "a patch release is newer")
        expect(UpdateChecker.isNewer("0.2.0", than: "0.1.9"), "a minor release is newer")
        expect(UpdateChecker.isNewer("v1.0.0", than: "0.9.9"), "a leading v is ignored")
        expect(!UpdateChecker.isNewer("0.1.1", than: "0.1.1"), "the same version is not newer")
        expect(!UpdateChecker.isNewer("0.1", than: "0.1.0"), "missing components count as zero")
        expect(!UpdateChecker.isNewer("1.0.0+build.7", than: "1.0.0"), "build metadata is ignored")
        expect(!UpdateChecker.isNewer("0.1.1-beta.1", than: "0.1.1"),
               "a prerelease is older than its release")
        expect(UpdateChecker.isNewer("0.1.1", than: "0.1.1-beta.1"),
               "a release is newer than its prerelease")
        expect(UpdateChecker.isNewer("0.1.1-beta.2", than: "0.1.1-beta.1"),
               "prerelease identifiers compare numerically")
        expect(!UpdateChecker.isNewer("not-a-version", than: "0.1.1"),
               "an unparseable tag never triggers an update")
        expect(!UpdateChecker.isNewer("0.1.2", than: "not-a-version"),
               "an unknown current version never triggers an update")
        expect(UpdateChecker.displayVersion("v0.2.0") == "0.2.0", "display versions drop the tag prefix")

        let releaseJSON = #"""
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/jseook11/Groovie/releases/tag/v0.2.0",
          "name": "Groovie 0.2.0",
          "body": "Notes"
        }
        """#
        let parsedRelease = UpdateChecker.release(
            from: Data(releaseJSON.utf8),
            currentVersion: "0.1.1"
        )
        expect(parsedRelease?.version == "0.2.0", "release parsing strips the tag prefix")
        expect(parsedRelease?.pageURL.absoluteString
               == "https://github.com/jseook11/Groovie/releases/tag/v0.2.0",
               "release parsing keeps the release page")
        expect(UpdateChecker.release(from: Data(releaseJSON.utf8), currentVersion: "0.2.0") == nil,
               "the running release is not reported as an update")
        expect(UpdateChecker.release(from: Data("{}".utf8), currentVersion: "0.1.1") == nil,
               "a malformed payload is ignored")

        // MARK: Desktop records

        let snapshot = TrackSnapshot(
            persistentID: "persist-1",
            title: "Blue in Green",
            artist: "Miles Davis",
            album: "Kind of Blue",
            duration: 337
        )
        let disc = DesktopRecord(
            track: snapshot,
            style: .disc,
            position: CGPoint(x: 400, y: 300),
            screenID: "1"
        )
        let sleeve = DesktopRecord(
            track: snapshot,
            style: .sleeve,
            position: CGPoint(x: 600, y: 260),
            screenID: "1"
        )
        let document = DesktopRecordDocument(records: [disc, sleeve])

        if let data = try? JSONEncoder().encode(document),
           let decoded = try? JSONDecoder().decode(DesktopRecordDocument.self, from: data)
        {
            expect(decoded.records.count == 2, "desktop records survive a JSON round trip")
            expect(decoded.records[0].style == .disc, "the disc style survives a round trip")
            expect(decoded.records[1].style == .sleeve, "the sleeve style survives a round trip")
            expect(decoded.records[1].track.album == "Kind of Blue",
                   "track metadata survives a round trip")
            expect(decoded.records[0].id != decoded.records[1].id,
                   "duplicate copies keep independent identities")
        } else {
            expect(false, "desktop records must encode and decode")
        }

        // `recordOut` is the whole open/closed state of a sleeve, so both
        // values must survive a round trip.
        for recordOut in [false, true] {
            let flagged = DesktopRecord(
                track: snapshot,
                style: .sleeve,
                position: CGPoint(x: 610, y: 270),
                screenID: "1",
                recordOut: recordOut
            )
            if let data = try? JSONEncoder().encode(flagged),
               let decoded = try? JSONDecoder().decode(DesktopRecord.self, from: data)
            {
                expect(decoded.recordOut == recordOut,
                       "recordOut \(recordOut) must survive a JSON round trip")
            } else {
                expect(false, "a record with recordOut must encode and decode")
            }
        }

        func jsonObject(_ record: DesktopRecord) -> [String: Any]? {
            guard let data = try? JSONEncoder().encode(record),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any]
            else { return nil }
            return dictionary
        }

        // A record written before recordOut existed decodes as open.
        if var legacyRecord = jsonObject(sleeve) {
            legacyRecord.removeValue(forKey: "recordOut")
            if let data = try? JSONSerialization.data(
                withJSONObject: legacyRecord,
                options: [.sortedKeys]
            ),
               let decoded = try? JSONDecoder().decode(DesktopRecord.self, from: data)
            {
                expect(decoded.recordOut,
                       "a record without recordOut must default to open")
            } else {
                expect(false, "a record without recordOut must still decode")
            }
        } else {
            expect(false, "a desktop record must serialise to a JSON object")
        }

        // A v1 document stored item-centre positions and had no recordOut
        // flag. Decoding shifts each sleeve's x by -35 pt (the old item centre
        // to the cover centre) and leaves discs alone; the document keeps
        // reporting v1 so the store knows to write the upgrade back.
        if var legacyDisc = jsonObject(disc),
           var legacySleeve = jsonObject(sleeve)
        {
            legacyDisc.removeValue(forKey: "recordOut")
            legacySleeve.removeValue(forKey: "recordOut")
            let legacy: [String: Any] = [
                "version": 1,
                "records": [legacyDisc, legacySleeve],
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: legacy,
                options: [.sortedKeys]
            ),
               let migrated = try? JSONDecoder().decode(DesktopRecordDocument.self, from: data)
            {
                expect(migrated.version == 1,
                       "a migrated v1 document reports its original version")
                expect(migrated.records.count == 2, "a v1 document keeps both records")

                let migratedDisc = migrated.records.first { $0.id == disc.id }
                let migratedSleeve = migrated.records.first { $0.id == sleeve.id }
                expect(migratedDisc?.position == disc.position,
                       "v1 disc positions already used the disc centre")
                expect(approx(
                    Double(migratedSleeve?.position.x ?? 0),
                    Double(sleeve.position.x - 35)
                ), "v1 sleeve positions shift left by 35 pt to the cover centre")
                expect(migratedSleeve?.position.y == sleeve.position.y,
                       "the v1 sleeve shift is horizontal only")
                expect(migratedDisc?.recordOut == true && migratedSleeve?.recordOut == true,
                       "v1 records migrate as open")

                if let reencoded = try? JSONEncoder().encode(migrated),
                   let rewritten = try? JSONDecoder().decode(
                    DesktopRecordDocument.self,
                    from: reencoded
                   )
                {
                    expect(rewritten.version == 2,
                           "re-encoding a migrated document writes version 2")
                    expect(rewritten.records.first { $0.id == sleeve.id }?.position
                           == migratedSleeve?.position,
                           "rewriting a migrated document keeps the shifted anchor")
                } else {
                    expect(false, "a migrated document must re-encode")
                }
            } else {
                expect(false, "a v1 document must decode")
            }
        } else {
            expect(false, "desktop records must serialise for the v1 migration check")
        }

        let visible = CGRect(x: 0, y: 0, width: 1440, height: 800)
        let discSize = DesktopRecordGeometry.itemSize(for: .disc)
        let inside = DesktopRecordGeometry.clamp(
            CGPoint(x: 10, y: 10),
            itemSize: discSize,
            to: visible
        )
        expect(inside.x >= discSize.width / 2 && inside.y >= discSize.height / 2,
               "desktop items clamp inside the visible frame")

        let outside = DesktopRecordGeometry.clamp(
            CGPoint(x: 5000, y: 5000),
            itemSize: discSize,
            to: visible
        )
        expect(outside.x <= visible.maxX - discSize.width / 2,
               "desktop items clamp at the right edge")
        expect(outside.y <= visible.maxY - discSize.height / 2,
               "desktop items clamp at the top edge")

        let noScreen = DesktopRecordGeometry.clamp(
            CGPoint(x: 321, y: 654),
            itemSize: discSize,
            to: .zero
        )
        expect(noScreen == CGPoint(x: 321, y: 654),
               "an unavailable screen must not collapse a desktop position")

        let notch = CGRect(x: 640, y: 770, width: 160, height: 30)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 800)
        let zone = DesktopRecordGeometry.deleteZone(notchRect: notch, screenFrame: screen)
        expect(zone.contains(CGPoint(x: 720, y: 790)),
               "the notch is inside the delete zone")
        expect(!zone.contains(CGPoint(x: 720, y: 400)),
               "the middle of the screen is outside the delete zone")
        expect(!zone.contains(CGPoint(x: 40, y: 790)),
               "the far top-left corner is outside the delete zone")

        let slot = DesktopRecordGeometry.defaultSlot(
            itemSize: discSize,
            screenFrame: screen,
            visibleFrame: visible,
            notchHeight: 30,
            index: 0
        )
        expect(!zone.contains(slot), "the default package slot starts below the delete zone")
        expect(visible.contains(slot), "the default package slot is on screen")

        let nextSlot = DesktopRecordGeometry.defaultSlot(
            itemSize: discSize,
            screenFrame: screen,
            visibleFrame: visible,
            notchHeight: 30,
            index: 1
        )
        expect(nextSlot != slot, "repeated package clicks cascade")

        // Option-click cycles open -> closed -> disc -> open. A disc ignores
        // the recordOut flag, so stepping from it always reopens the sleeve.
        var presentation = DesktopRecordStyle.next(after: .sleeve, recordOut: true)
        expect(presentation.style == .sleeve && presentation.recordOut == false,
               "the first Option-click closes the sleeve")
        presentation = DesktopRecordStyle.next(
            after: presentation.style,
            recordOut: presentation.recordOut
        )
        expect(presentation.style == .disc && presentation.recordOut,
               "the second Option-click turns the closed sleeve into a bare disc")
        presentation = DesktopRecordStyle.next(
            after: presentation.style,
            recordOut: presentation.recordOut
        )
        expect(presentation.style == .sleeve && presentation.recordOut,
               "the third Option-click reopens the sleeve")
        let discStep = DesktopRecordStyle.next(after: .disc, recordOut: false)
        expect(discStep.style == .sleeve && discStep.recordOut,
               "a disc ignores recordOut and always reopens the sleeve")

        // Sizes, rects, and anchors are shared by the window, the renderer, and
        // hit testing, so check the concrete numbers rather than just equality.
        let openSleeveSize = DesktopRecordGeometry.itemSize(for: .sleeve, recordOut: true)
        let closedSleeveSize = DesktopRecordGeometry.itemSize(for: .sleeve, recordOut: false)
        let bareDiscSize = DesktopRecordGeometry.itemSize(for: .disc, recordOut: false)
        expect(openSleeveSize == CGSize(width: 272, height: 200),
               "an open sleeve is cover + 72 pt of exposed vinyl")
        expect(closedSleeveSize == CGSize(width: 200, height: 200),
               "a closed sleeve is just the square cover")
        expect(bareDiscSize == CGSize(width: 180, height: 180), "a bare disc is 180x180")
        expect(DesktopRecordGeometry.sleeveExposed == 72,
               "40% of the 180 pt disc stays exposed")
        expect(DesktopRecordGeometry.sleeveOpenWidth == 272,
               "the open sleeve width is the cover plus the exposed strip")
        expect(DesktopRecordGeometry.sleeveClosedWidth == 200,
               "the closed sleeve width is the cover")

        let openDiscRect = DesktopRecordGeometry.discRect(for: .sleeve, recordOut: true)
        let closedDiscRect = DesktopRecordGeometry.discRect(for: .sleeve, recordOut: false)
        expect(approx(Double(openDiscRect.minX), 92),
               "the open sleeve disc starts 92 pt into the item")
        expect(approx(Double(closedDiscRect.minX), 20),
               "the closed sleeve disc is tucked behind the cover")
        expect(approx(Double(closedDiscRect.maxX), 200),
               "a closed sleeve keeps the record fully hidden")

        let openWindow = DesktopRecordGeometry.windowSize(for: .sleeve, recordOut: true)
        let closedWindow = DesktopRecordGeometry.windowSize(for: .sleeve, recordOut: false)
        let discWindow = DesktopRecordGeometry.windowSize(for: .disc, recordOut: true)
        expect(openWindow == CGSize(width: 340, height: 268),
               "the open sleeve window adds the 34 pt shadow margin")
        expect(closedWindow == CGSize(width: 268, height: 268),
               "the closed sleeve window adds the 34 pt shadow margin")
        expect(discWindow == CGSize(width: 248, height: 248),
               "the disc window adds the 34 pt shadow margin")
        for style in [DesktopRecordStyle.disc, .sleeve] {
            for recordOut in [false, true] {
                let item = DesktopRecordGeometry.itemSize(for: style, recordOut: recordOut)
                let window = DesktopRecordGeometry.windowSize(for: style, recordOut: recordOut)
                expect(approx(Double(window.width - item.width), 68)
                       && approx(Double(window.height - item.height), 68),
                       "\(style.rawValue): the window adds 68 pt on each axis")
            }
        }

        let anchorPoint = CGPoint(x: 600, y: 260)
        for style in [DesktopRecordStyle.disc, .sleeve] {
            for recordOut in [false, true] {
                let origin = DesktopRecordGeometry.windowOrigin(
                    anchor: anchorPoint,
                    style: style,
                    recordOut: recordOut
                )
                let roundTripped = DesktopRecordGeometry.anchor(
                    windowOrigin: origin,
                    style: style,
                    recordOut: recordOut
                )
                expect(roundTripped == anchorPoint,
                       "\(style.rawValue): a window origin round-trips to its anchor")
            }
        }
        let openSleeveCenter = DesktopRecordGeometry.itemCenter(
            anchor: anchorPoint,
            style: .sleeve,
            recordOut: true
        )
        expect(approx(Double(openSleeveCenter.x - anchorPoint.x), 36),
               "an open sleeve's item centre sits 36 pt right of the cover anchor")
        expect(approx(Double(openSleeveCenter.y), Double(anchorPoint.y)),
               "opening a sleeve never moves the cover vertically")

        let clampedAnchor = DesktopRecordGeometry.clamp(
            anchor: CGPoint(x: 5000, y: 5000),
            style: .sleeve,
            recordOut: true,
            to: visible
        )
        let sleeveOffset = DesktopRecordGeometry.anchorOffset(for: .sleeve, recordOut: true)
        let clampedItem = CGRect(
            x: clampedAnchor.x - sleeveOffset.x,
            y: clampedAnchor.y - sleeveOffset.y,
            width: openSleeveSize.width,
            height: openSleeveSize.height
        )
        expect(visible.contains(clampedItem),
               "clamping keeps the whole open sleeve inside the visible frame")

        let openSlot = DesktopRecordGeometry.defaultSlot(
            style: .sleeve,
            recordOut: true,
            screenFrame: screen,
            visibleFrame: visible,
            notchHeight: 30,
            index: 0
        )
        let slotItem = CGRect(
            x: openSlot.x - sleeveOffset.x,
            y: openSlot.y - sleeveOffset.y,
            width: openSleeveSize.width,
            height: openSleeveSize.height
        )
        expect(visible.contains(slotItem),
               "the default anchor keeps the whole open sleeve on screen")
        expect(!zone.contains(DesktopRecordGeometry.itemCenter(
            anchor: openSlot,
            style: .sleeve,
            recordOut: true
        )), "the default open-sleeve slot stays below the delete zone")

        // Renderer smoke test: the cached bitmap is exactly the window size, so
        // the window never has to scale it. No artwork, so both the cover and
        // the label are generated from the snapshot.
        let openImage = DesktopArtworkRenderer.image(
            for: .sleeve,
            recordOut: true,
            snapshot: snapshot,
            artwork: nil,
            skin: .classic
        )
        expect(openImage.size == openWindow,
               "the open sleeve render matches its window size")
        let closedImage = DesktopArtworkRenderer.image(
            for: .sleeve,
            recordOut: false,
            snapshot: snapshot,
            artwork: nil,
            skin: .classic
        )
        expect(closedImage.size == closedWindow,
               "the closed sleeve render matches its window size")
        let discImage = DesktopArtworkRenderer.image(
            for: .disc,
            recordOut: true,
            snapshot: snapshot,
            artwork: nil,
            skin: .classic
        )
        expect(discImage.size == discWindow,
               "the disc render matches its window size")

        // MARK: Desktop record storage

        MainActor.assumeIsolated {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GroovieSelfChecks-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = DesktopRecordStore(baseDirectory: directory)
            expect(store.records.isEmpty, "a new desktop store starts empty")
            expect(store.insert(disc), "a desktop record can be inserted")
            store.updatePosition(
                id: disc.id,
                position: CGPoint(x: 120, y: 140),
                screenID: "2"
            )

            let reloaded = DesktopRecordStore(baseDirectory: directory)
            expect(reloaded.records.count == 1, "desktop records reload from disk")
            expect(reloaded.records.first?.position == CGPoint(x: 120, y: 140),
                   "desktop positions persist across a reload")
            expect(reloaded.records.first?.screenID == "2",
                   "desktop screen identities persist across a reload")

            reloaded.updateStyle(id: disc.id, style: .sleeve)
            let restyled = DesktopRecordStore(baseDirectory: directory)
            expect(restyled.records.first?.style == .sleeve,
                   "desktop style changes persist across a reload")

            restyled.updateRecordOut(id: disc.id, recordOut: false)
            let tucked = DesktopRecordStore(baseDirectory: directory)
            expect(tucked.records.first?.recordOut == false,
                   "desktop recordOut changes persist across a reload")

            let unsafeArtwork = DesktopRecord(
                track: TrackSnapshot(
                    persistentID: "persist-1",
                    title: "Blue in Green",
                    artist: "Miles Davis",
                    album: "Kind of Blue",
                    duration: 337,
                    artworkFile: "../outside.png"
                ),
                style: .disc,
                position: .zero,
                screenID: nil
            )
            expect(reloaded.artwork(for: unsafeArtwork) == nil,
                   "artwork paths cannot escape the artwork directory")

            reloaded.remove(id: disc.id)
            let emptied = DesktopRecordStore(baseDirectory: directory)
            expect(emptied.records.isEmpty, "desktop removals persist across a reload")

            // A corrupt file must not block the next launch.
            let fileURL = directory.appendingPathComponent("desktop-records.json")
            try? Data("not-json".utf8).write(to: fileURL)
            let recovered = DesktopRecordStore(baseDirectory: directory)
            expect(recovered.records.isEmpty, "a corrupt desktop store starts empty")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            expect(files.contains(where: { $0.hasPrefix("desktop-records.corrupt-") }),
                   "a corrupt desktop store is backed up")

            // Loading a v1 file upgrades it on disk once: the sleeve anchor is
            // shifted and the rewritten document reports version 2.
            let legacyDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GroovieSelfChecks-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: legacyDirectory) }
            try? FileManager.default.createDirectory(
                at: legacyDirectory,
                withIntermediateDirectories: true
            )
            if var oldSleeve = jsonObject(sleeve) {
                oldSleeve.removeValue(forKey: "recordOut")
                let legacyDocument: [String: Any] = [
                    "version": 1,
                    "records": [oldSleeve],
                ]
                let legacyFile = legacyDirectory.appendingPathComponent("desktop-records.json")
                if let data = try? JSONSerialization.data(withJSONObject: legacyDocument) {
                    try? data.write(to: legacyFile)
                    let migratedStore = DesktopRecordStore(baseDirectory: legacyDirectory)
                    expect(migratedStore.records.first?.position.x
                           == sleeve.position.x - 35,
                           "the store shifts a v1 sleeve when it loads it")
                    if let written = try? Data(contentsOf: legacyFile),
                       let rewritten = try? JSONDecoder().decode(
                        DesktopRecordDocument.self,
                        from: written
                       )
                    {
                        expect(rewritten.version == 2,
                               "the store rewrites a migrated file as version 2")
                    } else {
                        expect(false, "a migrated file must be readable")
                    }
                } else {
                    expect(false, "a v1 fixture must encode")
                }
            } else {
                expect(false, "a v1 fixture must serialise")
            }

            // A file written by a newer build must be preserved rather than
            // decoded as v2 and rewritten (which would drop fields this build
            // cannot see).
            let futureDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GroovieSelfChecks-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: futureDirectory) }
            try? FileManager.default.createDirectory(
                at: futureDirectory,
                withIntermediateDirectories: true
            )
            if let futureRecord = jsonObject(disc) {
                let futureDocument: [String: Any] = [
                    "version": DesktopRecordDocument.currentVersion + 1,
                    "records": [futureRecord],
                ]
                let futureFile = futureDirectory.appendingPathComponent("desktop-records.json")
                if let data = try? JSONSerialization.data(withJSONObject: futureDocument) {
                    try? data.write(to: futureFile)
                    let futureStore = DesktopRecordStore(baseDirectory: futureDirectory)
                    expect(futureStore.records.isEmpty,
                           "a newer document version is not loaded")
                    let futureFiles = (try? FileManager.default.contentsOfDirectory(
                        atPath: futureDirectory.path
                    )) ?? []
                    expect(futureFiles.contains(where: {
                        $0.hasPrefix("desktop-records.newer-v")
                    }), "a newer document is preserved as a backup")
                } else {
                    expect(false, "a newer document fixture must encode")
                }
            } else {
                expect(false, "a record must serialise for the version fixture")
            }

            // One unreadable record (for example an unknown style from a newer
            // build) must not discard the other records in the file.
            let lossyDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GroovieSelfChecks-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: lossyDirectory) }
            try? FileManager.default.createDirectory(
                at: lossyDirectory,
                withIntermediateDirectories: true
            )
            if var badRecord = jsonObject(sleeve), let goodRecord = jsonObject(disc) {
                badRecord["style"] = "hologram"
                let lossyDocument: [String: Any] = [
                    "version": DesktopRecordDocument.currentVersion,
                    "records": [badRecord, goodRecord],
                ]
                let lossyFile = lossyDirectory.appendingPathComponent("desktop-records.json")
                if let data = try? JSONSerialization.data(withJSONObject: lossyDocument) {
                    try? data.write(to: lossyFile)
                    let lossyStore = DesktopRecordStore(baseDirectory: lossyDirectory)
                    expect(lossyStore.records.count == 1,
                           "an unreadable record does not discard the whole file")
                    expect(lossyStore.records.first?.id == disc.id,
                           "readable records survive a partially unreadable file")
                    let lossyFiles = (try? FileManager.default.contentsOfDirectory(
                        atPath: lossyDirectory.path
                    )) ?? []
                    expect(lossyFiles.contains(where: {
                        $0.hasPrefix("desktop-records.recovered-")
                    }), "a lossy recovery preserves the original file")
                    if let written = try? Data(contentsOf: lossyFile),
                       let rewritten = try? JSONDecoder().decode(
                        DesktopRecordDocument.self,
                        from: written
                       )
                    {
                        expect(rewritten.records.count == 1,
                               "the recovered file is rewritten without the bad record")
                    } else {
                        expect(false, "the recovered file must be readable")
                    }
                } else {
                    expect(false, "a lossy document fixture must encode")
                }
            } else {
                expect(false, "records must serialise for the lossy fixture")
            }

            // A style cycle changes style, recordOut, and position together;
            // one call must persist all of them.
            let batchDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GroovieSelfChecks-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: batchDirectory) }
            let batchStore = DesktopRecordStore(baseDirectory: batchDirectory)
            expect(batchStore.insert(disc), "a record can be inserted for a batched update")
            batchStore.update(
                id: disc.id,
                style: .sleeve,
                recordOut: false,
                position: CGPoint(x: 42, y: 84),
                screenID: "7"
            )
            let batched = DesktopRecordStore(baseDirectory: batchDirectory)
            expect(batched.records.first?.style == .sleeve
                   && batched.records.first?.recordOut == false
                   && batched.records.first?.position == CGPoint(x: 42, y: 84)
                   && batched.records.first?.screenID == "7",
                   "a batched update persists every field")
        }

        // MARK: Music poll cadence

        expect(AppleMusicService.pollInterval(engaged: true, availability: .playing, isRunning: true) == 3,
               "engaged playback must poll at 3 s")
        expect(AppleMusicService.pollInterval(engaged: false, availability: .playing, isRunning: true) == 5,
               "background playback must slow to 5 s")
        expect(AppleMusicService.pollInterval(engaged: true, availability: .paused, isRunning: true) == 5,
               "engaged pause must poll at 5 s")
        expect(AppleMusicService.pollInterval(engaged: false, availability: .paused, isRunning: true) == 10,
               "background pause must slow to 10 s")
        expect(AppleMusicService.pollInterval(engaged: false, availability: .noTrack, isRunning: true) == 15,
               "background no-track must slow to 15 s")
        expect(AppleMusicService.pollInterval(engaged: true, availability: .playing, isRunning: false) == 30,
               "an absent player must use the 30 s recovery cadence")
        for availability in [MusicAvailability.playing, .paused, .noTrack] {
            expect(
                AppleMusicService.pollInterval(engaged: false, availability: availability, isRunning: true)
                    >= AppleMusicService.pollInterval(engaged: true, availability: availability, isRunning: true),
                "background cadence must never be faster than engaged for \(availability)"
            )
        }

        // MARK: Report

        if failures.isEmpty {
            print("SelfChecks: all checks passed")
            return 0
        }
        for failure in failures {
            print("SelfChecks: FAIL — \(failure)")
        }
        print("SelfChecks: \(failures.count) failure(s)")
        return failures.count
    }
}
