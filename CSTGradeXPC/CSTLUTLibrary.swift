//
// CSTLUTLibrary.swift
//
// Dependency-free creative 3D .cube library support.
//
// Supported .cube dialect (deliberately narrow and explicit):
//   - UTF-8 text, comments, TITLE, LUT_3D_SIZE 2...64
//   - optional DOMAIN_MIN/DOMAIN_MAX only when they are the standard 0..1
//   - exactly dimension^3 RGB triplets in the standard R-fastest order
//   - no LUT_1D_SIZE, shaper, matrix, or vendor extension
//
// A creative Rec.709 display LUT is sampled after the shader's Rec.709 output
// transfer and before the final output clamp. It is never applied to the
// scene-linear part of the CST pipeline.
//
// The library stores metadata and security-scoped bookmarks, never moves or
// duplicates user LUT files, and uses a bounded in-process parsed-LUT cache.
// The visual browser uses a deterministic reference chart rather than a live
// FCP frame: FxPlug does not provide a safe, documented “current frame for a
// browser thumbnail” API.

import AppKit
import Foundation

#if CST_GRADE_XPC
import FxPlug
#endif

// The interpolation protocol belongs on the custom value object: the value
// on the left of a keyframe is `self`, and the host supplies the right value.
// A LUT selection is a discrete choice, so interpolation is a hold/step.
// UNVERIFIED: Xcode 14.2 may import the existential composition without the
// `any` spelling used by current Apple documentation; confirm in FxPlug.h.
@objc(CSTLUTSelection)
final class CSTLUTSelection: NSObject, NSSecureCoding, NSCopying {
    static var supportsSecureCoding: Bool { true }

    let identifier: UInt64
    let displayName: String
    let sourcePath: String
    let bookmarkData: Data?

    static func none() -> CSTLUTSelection {
        CSTLUTSelection(identifier: 0, displayName: "No LUT", sourcePath: "", bookmarkData: nil)
    }

    init(identifier: UInt64, displayName: String, sourcePath: String, bookmarkData: Data?) {
        self.identifier = identifier
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.bookmarkData = bookmarkData
        super.init()
    }

    required init?(coder: NSCoder) {
        identifier = UInt64(coder.decodeInt64(forKey: "identifier"))
        displayName = coder.decodeObject(of: NSString.self, forKey: "displayName") as String? ?? "Missing LUT"
        sourcePath = coder.decodeObject(of: NSString.self, forKey: "sourcePath") as String? ?? ""
        bookmarkData = coder.decodeObject(of: NSData.self, forKey: "bookmarkData") as Data?
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(Int64(bitPattern: identifier), forKey: "identifier")
        coder.encode(displayName as NSString, forKey: "displayName")
        coder.encode(sourcePath as NSString, forKey: "sourcePath")
        coder.encode(bookmarkData as NSData?, forKey: "bookmarkData")
    }

    func copy(with zone: NSZone? = nil) -> Any {
        CSTLUTSelection(
            identifier: identifier,
            displayName: displayName,
            sourcePath: sourcePath,
            bookmarkData: bookmarkData
        )
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CSTLUTSelection else { return false }
        return identifier == other.identifier && displayName == other.displayName
            && sourcePath == other.sourcePath
    }

    override var hash: Int { identifier.hashValue }

}

#if CST_GRADE_XPC
extension CSTLUTSelection: FxCustomParameterInterpolation_v2 {
    func interpolateBetween(
        _ rightValue: any NSCopying & NSSecureCoding & NSObjectProtocol,
        withWeight weight: Float
    ) -> any NSCopying & NSSecureCoding & NSObjectProtocol {
        guard let right = rightValue as? CSTLUTSelection else {
            return self.copy() as! any NSCopying & NSSecureCoding & NSObjectProtocol
        }
        return (weight >= 1.0 ? right.copy() : self.copy())
            as! any NSCopying & NSSecureCoding & NSObjectProtocol
    }

    func isEqual(_ value: any NSCopying & NSSecureCoding & NSObjectProtocol) -> Bool {
        guard let other = value as? CSTLUTSelection else { return false }
        return identifier == other.identifier && displayName == other.displayName
            && sourcePath == other.sourcePath
    }
}
#endif

/// The public custom-view API gives an FxPlug an embedded NSView, but does not
/// document a host-safe full-window LUT browser. The outer .fxplug application
/// therefore exposes this optional standard-AppKit organizer bridge. The
/// notification contains only a request token and an archived custom value;
/// the plug-in still performs the actual FxPlug parameter write through its
/// documented action/setting APIs.
enum CSTLUTOrganizerBridge {
    static let urlScheme = "cstgrade"
    static let notificationName = Notification.Name("com.example.cstgrade.lut-selection")

    static func post(selection: CSTLUTSelection, requestToken: String) {
        guard let archived = try? NSKeyedArchiver.archivedData(
            withRootObject: selection,
            requiringSecureCoding: true
        ) else { return }
        DistributedNotificationCenter.default().post(
            name: notificationName,
            object: nil,
            userInfo: ["request": requestToken, "selection": archived],
            deliverImmediately: true
        )
    }

    static func selection(from notification: Notification, requestToken: String) -> CSTLUTSelection? {
        guard let userInfo = notification.userInfo,
              (userInfo["request"] as? String) == requestToken,
              let archived = userInfo["selection"] as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CSTLUTSelection.self,
            from: archived
        )
    }
}

struct CSTParsedLUT {
    let identifier: UInt64
    let dimension: Int
    /// Three floats per texel, with red changing fastest, then green, then blue.
    let rgbValues: [Float]

    var texelCount: Int { dimension * dimension * dimension }

    func sample(_ color: SIMD3<Float>) -> SIMD3<Float> {
        guard dimension > 1 else { return SIMD3(repeating: 0) }
        let x = min(max(color.x, 0), 1) * Float(dimension - 1)
        let y = min(max(color.y, 0), 1) * Float(dimension - 1)
        let z = min(max(color.z, 0), 1) * Float(dimension - 1)
        let x0 = Int(floor(x)); let y0 = Int(floor(y)); let z0 = Int(floor(z))
        let x1 = min(x0 + 1, dimension - 1)
        let y1 = min(y0 + 1, dimension - 1)
        let z1 = min(z0 + 1, dimension - 1)
        let fx = x - Float(x0); let fy = y - Float(y0); let fz = z - Float(z0)

        func texel(_ red: Int, _ green: Int, _ blue: Int) -> SIMD3<Float> {
            let index = ((blue * dimension + green) * dimension + red) * 3
            return SIMD3(rgbValues[index], rgbValues[index + 1], rgbValues[index + 2])
        }

        var result = SIMD3<Float>(repeating: 0)
        for bz in 0...1 {
            let wz = bz == 0 ? (1 - fz) : fz
            for gy in 0...1 {
                let wy = gy == 0 ? (1 - fy) : fy
                for rx in 0...1 {
                    let wx = rx == 0 ? (1 - fx) : fx
                    let weight = wx * wy * wz
                    result += texel(rx == 0 ? x0 : x1, gy == 0 ? y0 : y1, bz == 0 ? z0 : z1) * weight
                }
            }
        }
        return result
    }

    /// Metal texture data is RGBA32F because Metal texture writes are simpler
    /// and the alpha channel is a constant one. The source .cube file remains
    /// RGB-only.
    func rgbaFloatValues() -> [Float] {
        var result = [Float](repeating: 1, count: texelCount * 4)
        for texel in 0..<texelCount {
            result[texel * 4] = rgbValues[texel * 3]
            result[texel * 4 + 1] = rgbValues[texel * 3 + 1]
            result[texel * 4 + 2] = rgbValues[texel * 3 + 2]
        }
        return result
    }
}

enum CSTLUTParser {
    static func parse(data: Data, identifier: UInt64) throws -> CSTParsedLUT {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CSTGradeError("LUT is not valid UTF-8 text")
        }

        var dimension: Int?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var values: [Float] = []
        var saw1DLUT = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let lineWithoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let tokens = lineWithoutComment.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard let first = tokens.first else { continue }
            let keyword = String(first).uppercased()

            switch keyword {
            case "TITLE":
                continue
            case "LUT_1D_SIZE":
                saw1DLUT = true
            case "LUT_3D_SIZE":
                guard tokens.count == 2, let parsed = Int(tokens[1]), (2...64).contains(parsed) else {
                    throw CSTGradeError("LUT_3D_SIZE must be an integer from 2 through 64")
                }
                dimension = parsed
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard tokens.count == 4,
                      let x = Float(tokens[1]), let y = Float(tokens[2]), let z = Float(tokens[3]) else {
                    throw CSTGradeError("Malformed \(keyword) line in LUT")
                }
                let value = SIMD3(x, y, z)
                if keyword == "DOMAIN_MIN" { domainMin = value } else { domainMax = value }
            default:
                guard tokens.count == 3,
                      let red = Float(tokens[0]), let green = Float(tokens[1]), let blue = Float(tokens[2]) else {
                    throw CSTGradeError("Unsupported or malformed .cube line: \(rawLine)")
                }
                values.append(contentsOf: [red, green, blue])
            }
        }

        guard !saw1DLUT else {
            throw CSTGradeError("1D .cube LUTs are not supported; choose a 3D creative LUT")
        }
        guard let dimension else {
            throw CSTGradeError("LUT has no LUT_3D_SIZE header")
        }
        let expectedValues = dimension * dimension * dimension * 3
        guard values.count == expectedValues else {
            throw CSTGradeError("LUT contains \(values.count / 3) samples; expected \(expectedValues / 3)")
        }
        guard domainMin == SIMD3<Float>(repeating: 0), domainMax == SIMD3<Float>(repeating: 1) else {
            throw CSTGradeError("Only the standard .cube DOMAIN_MIN 0 and DOMAIN_MAX 1 are supported")
        }
        guard values.allSatisfy({ $0.isFinite }) else {
            throw CSTGradeError("LUT contains a non-finite sample")
        }
        return CSTParsedLUT(identifier: identifier, dimension: dimension, rgbValues: values)
    }

    static func identifier(for data: Data) -> UInt64 {
        // FNV-1a-64 is used only as a stable local cache/content key. It is not
        // a security hash and never authorizes file access.
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash == 0 ? 1 : hash
    }
}

struct CSTLUTRecord: Codable, Equatable {
    var identifier: UInt64
    var displayName: String
    var sourcePath: String
    var bookmarkData: Data?
    var addedAt: Date
    var lastUsedAt: Date?
    var favorite: Bool
    var collections: [String]

    func selection() -> CSTLUTSelection {
        CSTLUTSelection(
            identifier: identifier,
            displayName: displayName,
            sourcePath: sourcePath,
            bookmarkData: bookmarkData
        )
    }
}

final class CSTLUTParsedCache {
    static let shared = CSTLUTParsedCache()
    private var entries: [UInt64: CSTParsedLUT] = [:]
    private var order: [UInt64] = []
    private let lock = NSLock()
    private let maximumEntries = 4

    private init() {}

    func value(for identifier: UInt64) -> CSTParsedLUT? {
        lock.lock(); defer { lock.unlock() }
        guard let value = entries[identifier] else { return nil }
        order.removeAll { $0 == identifier }
        order.append(identifier)
        return value
    }

    func insert(_ value: CSTParsedLUT) {
        lock.lock(); defer { lock.unlock() }
        entries[value.identifier] = value
        order.removeAll { $0 == value.identifier }
        order.append(value.identifier)
        while order.count > maximumEntries {
            let old = order.removeFirst()
            entries.removeValue(forKey: old)
        }
    }
}

final class CSTLUTLibraryStore {
    static let shared = CSTLUTLibraryStore()

    private(set) var records: [CSTLUTRecord] = []
    private let lock = NSLock()
    private let fileManager = FileManager.default

    private var metadataURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CSTGrade", isDirectory: true)
            .appendingPathComponent("lut-library.json")
    }

    private init() {
        load()
    }

    func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([CSTLUTRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func saveLocked() {
        let directory = metadataURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    func importURL(_ url: URL, recursive: Bool) -> (added: Int, skipped: [String], errors: [String]) {
        let rootAccessStarted = url.startAccessingSecurityScopedResource()
        defer { if rootAccessStarted { url.stopAccessingSecurityScopedResource() } }
        let urls: [URL]
        if recursive, let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            urls = enumerator.compactMap { $0 as? URL }.filter {
                $0.pathExtension.caseInsensitiveCompare("cube") == .orderedSame
            }
        } else {
            urls = [url].filter { $0.pathExtension.caseInsensitiveCompare("cube") == .orderedSame }
        }

        var added = 0
        var skipped: [String] = []
        var errors: [String] = []
        for candidate in urls {
            do {
                let data = try Data(contentsOf: candidate)
                let identifier = CSTLUTParser.identifier(for: data)
                _ = try CSTLUTParser.parse(data: data, identifier: identifier)
                // Do not add a record that can only be rendered through a
                // transient absolute path. The selected source must carry a
                // persistent security-scoped bookmark into the XPC service.
                let bookmark = try candidate.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                lock.lock()
                if records.contains(where: { $0.identifier == identifier }) {
                    skipped.append(candidate.lastPathComponent + " (duplicate content)")
                } else {
                    records.append(CSTLUTRecord(
                        identifier: identifier,
                        displayName: candidate.deletingPathExtension().lastPathComponent,
                        sourcePath: candidate.path,
                        bookmarkData: bookmark,
                        addedAt: Date(),
                        lastUsedAt: nil,
                        favorite: false,
                        collections: []
                    ))
                    added += 1
                }
                saveLocked()
                lock.unlock()
            } catch {
                errors.append(candidate.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        return (added, skipped, errors)
    }

    func createCollection(named name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var names = UserDefaults.standard.stringArray(forKey: "CSTGrade.collections") ?? []
        if !names.contains(normalized) { names.append(normalized) }
        UserDefaults.standard.set(names.sorted(), forKey: "CSTGrade.collections")
        UserDefaults.standard.set(normalized, forKey: "CSTGrade.lastCollection")
    }

    func collectionNames() -> [String] {
        lock.lock(); let recordNames = records.flatMap(\.collections); lock.unlock()
        let savedNames = UserDefaults.standard.stringArray(forKey: "CSTGrade.collections") ?? []
        return Array(Set(recordNames + savedNames)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func add(_ record: CSTLUTRecord, toCollection name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.identifier == record.identifier }) else { return }
        if !records[index].collections.contains(name) { records[index].collections.append(name) }
        saveLocked()
    }

    func toggleFavorite(_ record: CSTLUTRecord) {
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.identifier == record.identifier }) else { return }
        records[index].favorite.toggle()
        saveLocked()
    }

    func markUsed(_ selection: CSTLUTSelection) {
        guard selection.identifier != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.identifier == selection.identifier }) else { return }
        records[index].lastUsedAt = Date()
        saveLocked()
    }

    func parsedLUT(for selection: CSTLUTSelection) throws -> CSTParsedLUT? {
        guard selection.identifier != 0 else { return nil }

        let url: URL
        var stale = false
        guard let bookmarkData = selection.bookmarkData else {
            throw CSTGradeError("LUT has no persistent security-scoped bookmark")
        }
        url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let identifier = CSTLUTParser.identifier(for: data)
        guard identifier == selection.identifier else {
            throw CSTGradeError("LUT content changed since it was selected")
        }
        // Validate the current file bytes before consulting the parsed cache.
        // Otherwise an in-place edit could keep returning the old cached LUT
        // solely because the selection still carries its original identifier.
        // The file read/hash happens while pluginState or a preview is built;
        // the real-time render callback never touches the filesystem.
        if let cached = CSTLUTParsedCache.shared.value(for: identifier) { return cached }
        let parsed = try CSTLUTParser.parse(data: data, identifier: identifier)
        CSTLUTParsedCache.shared.insert(parsed)
        return parsed
    }

    func displayRecords() -> [CSTLUTRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    func neighbor(of selection: CSTLUTSelection, offset: Int) -> CSTLUTSelection {
        let sorted = displayRecords().sorted {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.identifier < $1.identifier
        }
        let choices = [CSTLUTSelection.none()] + sorted.map { $0.selection() }
        guard choices.count > 1 else { return .none() }
        let current = choices.firstIndex(where: { $0.identifier == selection.identifier }) ?? 0
        let wrapped = (current + offset) % choices.count
        let index = wrapped < 0 ? wrapped + choices.count : wrapped
        return choices[index]
    }
}

enum CSTLUTThumbnail {
    static func image(for lut: CSTParsedLUT?) -> NSImage {
        let size = NSSize(width: 220, height: 92)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        // A representative, fixed chart: grayscale ramp, skin-like patch,
        // foliage/sky/primary patches. It is intentionally not advertised as
        // a live-frame preview.
        let colors: [SIMD3<Float>] = [
            SIMD3(0.02, 0.02, 0.02), SIMD3(0.18, 0.18, 0.18), SIMD3(0.5, 0.5, 0.5), SIMD3(0.9, 0.9, 0.9),
            SIMD3(0.55, 0.28, 0.18), SIMD3(0.12, 0.35, 0.08), SIMD3(0.12, 0.28, 0.75), SIMD3(0.85, 0.08, 0.05),
            SIMD3(0.05, 0.75, 0.12), SIMD3(0.08, 0.2, 0.9), SIMD3(0.85, 0.75, 0.05), SIMD3(0.8, 0.1, 0.75)
        ]
        let columns = 6
        let rows = 2
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        for (index, color) in colors.enumerated() {
            let output = lut?.sample(color) ?? color
            let clipped = SIMD3(min(max(output.x, 0), 1), min(max(output.y, 0), 1), min(max(output.z, 0), 1))
            NSColor(calibratedRed: CGFloat(clipped.x), green: CGFloat(clipped.y), blue: CGFloat(clipped.z), alpha: 1).setFill()
            let x = CGFloat(index % columns) * cellWidth
            let y = CGFloat(rows - 1 - index / columns) * cellHeight
            NSBezierPath(rect: NSRect(x: x + 1, y: y + 1, width: cellWidth - 2, height: cellHeight - 2)).fill()
        }
        image.unlockFocus()
        return image
    }
}
