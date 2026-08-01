import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol PersonalStationMediaProviding: Sendable {
    func items(for stationKey: PersonalStationMediaKey) async throws -> [PersonalStationMediaItem]
    func fileURL(for itemID: UUID, in stationKey: PersonalStationMediaKey) async throws -> URL?

    @discardableResult
    func importImageData(
        _ data: Data,
        for stationKey: PersonalStationMediaKey,
        subject: PersonalStationMediaSubject
    ) async throws -> PersonalStationMediaItem

    func deleteItem(id: UUID, for stationKey: PersonalStationMediaKey) async throws
}

enum PersonalStationMediaError: Error, Equatable, Sendable {
    case invalidStationKey
    case sourceTooLarge
    case unsupportedImage
    case itemLimitReached
    case itemNotFound
    case storageUnavailable
}

actor PersonalStationMediaStore: PersonalStationMediaProviding {
    static let shared = PersonalStationMediaStore()
    static let maximumSourceByteCount = 25 * 1_024 * 1_024
    static let maximumPixelEdge = 4_096
    static let maximumItemsPerStation = 10

    private static let indexSchemaVersion = 1
    private static let jpegQuality = 0.88

    private let fileManager: FileManager
    private let rootURL: URL
    private let indexURL: URL
    private let hasUsableRoot: Bool

    private var storedIndex: StoredIndex?
    private var isPrepared = false

    /// The default store is rooted at Application Support/JustGo/PersonalStationMedia.
    /// Supplying a root keeps disk behavior testable without changing the production location.
    init(rootURL customRootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let resolvedRoot: URL
        let rootIsUsable: Bool
        if let customRootURL {
            resolvedRoot = customRootURL.standardizedFileURL
            rootIsUsable = customRootURL.isFileURL
        } else if let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolvedRoot = applicationSupportURL
                .appendingPathComponent("JustGo", isDirectory: true)
                .appendingPathComponent("PersonalStationMedia", isDirectory: true)
                .standardizedFileURL
            rootIsUsable = true
        } else {
            resolvedRoot = fileManager.temporaryDirectory
                .appendingPathComponent("UnavailablePersonalStationMedia", isDirectory: true)
            rootIsUsable = false
        }

        rootURL = resolvedRoot
        indexURL = resolvedRoot.appendingPathComponent("index.json", isDirectory: false)
        hasUsableRoot = rootIsUsable
    }

    func items(for stationKey: PersonalStationMediaKey) async throws -> [PersonalStationMediaItem] {
        guard stationKey.isValid else { throw PersonalStationMediaError.invalidStationKey }
        try prepareIfNeeded()
        repairIndexForCurrentFiles()

        return currentIndex.records
            .filter { $0.stationKey == stationKey }
            .compactMap(makeItem)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func fileURL(for itemID: UUID, in stationKey: PersonalStationMediaKey) async throws -> URL? {
        guard stationKey.isValid else { throw PersonalStationMediaError.invalidStationKey }
        try prepareIfNeeded()
        repairIndexForCurrentFiles()

        guard let record = currentIndex.records.first(where: {
            $0.id == itemID && $0.stationKey == stationKey
        }) else {
            return nil
        }
        return validatedFileURL(for: record)
    }

    @discardableResult
    func importImageData(
        _ data: Data,
        for stationKey: PersonalStationMediaKey,
        subject: PersonalStationMediaSubject
    ) async throws -> PersonalStationMediaItem {
        guard stationKey.isValid else { throw PersonalStationMediaError.invalidStationKey }
        guard !data.isEmpty else { throw PersonalStationMediaError.unsupportedImage }
        guard data.count <= Self.maximumSourceByteCount else {
            throw PersonalStationMediaError.sourceTooLarge
        }

        try prepareIfNeeded()
        repairIndexForCurrentFiles()
        guard currentIndex.records.lazy.filter({ $0.stationKey == stationKey }).count < Self.maximumItemsPerStation else {
            throw PersonalStationMediaError.itemLimitReached
        }

        let sanitized = try Self.sanitizedJPEG(from: data)
        let id = uniqueItemID()
        let filename = Self.filename(for: id)
        guard let destinationURL = safeFileURL(filename: filename, id: id) else {
            throw PersonalStationMediaError.storageUnavailable
        }

        do {
            try sanitized.data.write(to: destinationURL, options: .atomic)
        } catch {
            throw PersonalStationMediaError.storageUnavailable
        }

        let record = StoredRecord(
            id: id,
            stationKey: stationKey,
            filename: filename,
            createdAt: Date(),
            pixelWidth: sanitized.pixelWidth,
            pixelHeight: sanitized.pixelHeight,
            byteCount: sanitized.data.count,
            subject: subject,
            // Capture writes `.local` and nothing else. Until an upload path exists, any other
            // value here would be the app claiming a photo had been shared when it had not.
            shareState: .local,
            remoteID: nil
        )
        let candidate = StoredIndex(
            schemaVersion: Self.indexSchemaVersion,
            records: [record] + currentIndex.records
        )

        do {
            try persist(candidate)
            storedIndex = candidate
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        guard let item = makeItem(from: record) else {
            try? fileManager.removeItem(at: destinationURL)
            storedIndex = StoredIndex(
                schemaVersion: Self.indexSchemaVersion,
                records: currentIndex.records.filter { $0.id != id }
            )
            try? persist(currentIndex)
            throw PersonalStationMediaError.storageUnavailable
        }
        return item
    }

    func deleteItem(id: UUID, for stationKey: PersonalStationMediaKey) async throws {
        guard stationKey.isValid else { throw PersonalStationMediaError.invalidStationKey }
        try prepareIfNeeded()
        repairIndexForCurrentFiles()

        guard let record = currentIndex.records.first(where: {
            $0.id == id && $0.stationKey == stationKey
        }) else {
            throw PersonalStationMediaError.itemNotFound
        }
        guard let fileURL = safeFileURL(filename: record.filename, id: record.id) else {
            throw PersonalStationMediaError.storageUnavailable
        }

        let candidate = StoredIndex(
            schemaVersion: Self.indexSchemaVersion,
            records: currentIndex.records.filter { $0.id != id }
        )
        guard fileManager.fileExists(atPath: fileURL.path) else {
            try persist(candidate)
            storedIndex = candidate
            return
        }
        let tombstoneURL = rootURL.appendingPathComponent(
            ".deleting-\(id.uuidString.lowercased()).jpg",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: fileURL, to: tombstoneURL)
            do {
                try persist(candidate)
                storedIndex = candidate
            } catch {
                try? fileManager.moveItem(at: tombstoneURL, to: fileURL)
                throw error
            }
            try? fileManager.removeItem(at: tombstoneURL)
            removeUnreferencedMediaFiles(keeping: candidate)
        } catch {
            throw PersonalStationMediaError.storageUnavailable
        }
    }

    private var currentIndex: StoredIndex {
        storedIndex ?? StoredIndex(schemaVersion: Self.indexSchemaVersion, records: [])
    }

    private func prepareIfNeeded() throws {
        guard !isPrepared else { return }
        guard hasUsableRoot else { throw PersonalStationMediaError.storageUnavailable }

        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            var rootResourceValues = URLResourceValues()
            rootResourceValues.isExcludedFromBackup = true
            var mutableRootURL = rootURL
            try mutableRootURL.setResourceValues(rootResourceValues)
        } catch {
            throw PersonalStationMediaError.storageUnavailable
        }

        let loaded = loadIndexSafely()
        let repaired = reconciledIndex(from: loaded)
        removeUnreferencedMediaFiles(keeping: repaired)
        storedIndex = repaired
        isPrepared = true

        if repaired != loaded {
            try? persist(repaired)
        }
    }

    private func loadIndexSafely() -> StoredIndex {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return StoredIndex(schemaVersion: Self.indexSchemaVersion, records: [])
        }

        let resourceValues = try? indexURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard resourceValues?.isRegularFile == true,
              resourceValues?.isSymbolicLink != true,
              let data = try? Data(contentsOf: indexURL) else {
            try? fileManager.removeItem(at: indexURL)
            return StoredIndex(schemaVersion: Self.indexSchemaVersion, records: [])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(StoredIndex.self, from: data),
              decoded.schemaVersion == Self.indexSchemaVersion else {
            quarantineCorruptIndex()
            return StoredIndex(schemaVersion: Self.indexSchemaVersion, records: [])
        }
        return decoded
    }

    private func quarantineCorruptIndex() {
        let quarantineURL = rootURL.appendingPathComponent(
            ".corrupt-index-\(UUID().uuidString).json",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: indexURL, to: quarantineURL)
        } catch {
            try? fileManager.removeItem(at: indexURL)
        }
    }

    private func repairIndexForCurrentFiles() {
        let repaired = reconciledIndex(from: currentIndex)
        removeUnreferencedMediaFiles(keeping: repaired)
        if repaired != currentIndex {
            storedIndex = repaired
            try? persist(repaired)
        }
    }

    private func removeUnreferencedMediaFiles(keeping index: StoredIndex) {
        let referenced = Set(index.records.map(\.filename))
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            removeDeletionTombstones()
            return
        }
        for url in contents where url.pathExtension.lowercased() == "jpg" &&
            Self.isManagedMediaFilename(url.lastPathComponent) &&
            !referenced.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
        removeDeletionTombstones()
    }

    private func removeDeletionTombstones() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: rootURL.path) else { return }
        for name in names where name.hasPrefix(".deleting-") && name.hasSuffix(".jpg") {
            let tombstoneURL = rootURL.appendingPathComponent(name)
            // A tombstone can outlive a `deleteItem` call whose rollback (move back to the
            // original filename) itself failed. In that case the index still references the
            // original filename, and this tombstone is the only surviving copy of that photo —
            // restore it instead of deleting it, rather than silently losing data the app is
            // still telling the user exists.
            let uuidString = name
                .dropFirst(".deleting-".count)
                .dropLast(".jpg".count)
            if let id = UUID(uuidString: String(uuidString)),
               currentIndex.records.contains(where: { $0.id == id }),
               let restoredURL = safeFileURL(filename: Self.filename(for: id), id: id),
               !fileManager.fileExists(atPath: restoredURL.path) {
                if (try? fileManager.moveItem(at: tombstoneURL, to: restoredURL)) != nil {
                    continue
                }
            }
            try? fileManager.removeItem(at: tombstoneURL)
        }
    }

    private func reconciledIndex(from source: StoredIndex) -> StoredIndex {
        var seenIDs = Set<UUID>()
        var seenFilenames = Set<String>()
        var itemCountByStation: [PersonalStationMediaKey: Int] = [:]
        var validRecords: [StoredRecord] = []

        for record in source.records.sorted(by: Self.isNewer) {
            guard itemCountByStation[record.stationKey, default: 0] < Self.maximumItemsPerStation,
                  let validated = validatedRecord(record),
                  !seenIDs.contains(record.id),
                  !seenFilenames.contains(record.filename) else {
                continue
            }
            seenIDs.insert(record.id)
            seenFilenames.insert(record.filename)
            validRecords.append(validated)
            itemCountByStation[record.stationKey, default: 0] += 1
        }

        return StoredIndex(
            schemaVersion: Self.indexSchemaVersion,
            records: validRecords
        )
    }

    private func validatedRecord(_ record: StoredRecord) -> StoredRecord? {
        guard record.stationKey.isValid,
              let fileURL = safeFileURL(filename: record.filename, id: record.id),
              let validatedFile = validatedJPEG(at: fileURL) else {
            return nil
        }

        // Dimensions and byte count are re-read from the file on purpose — the record's copies are
        // only a cache of what is on disk. Everything the rider told us, though, is carried
        // through verbatim: rebuilding without these silently reset every photo's subject on the
        // next load, which the migration test catches.
        return StoredRecord(
            id: record.id,
            stationKey: record.stationKey,
            filename: record.filename,
            createdAt: record.createdAt,
            pixelWidth: validatedFile.pixelWidth,
            pixelHeight: validatedFile.pixelHeight,
            byteCount: validatedFile.byteCount,
            subject: record.subject,
            shareState: record.shareState,
            remoteID: record.remoteID
        )
    }

    private func validatedJPEG(at fileURL: URL) -> ValidatedFile? {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]),
            resourceValues.isRegularFile == true,
            resourceValues.isSymbolicLink != true,
            let byteCount = resourceValues.fileSize,
            byteCount > 0,
            let source = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetCount(source) > 0,
            let sourceType = CGImageSourceGetType(source),
            UTType(sourceType as String)?.conforms(to: .jpeg) == true,
            let dimensions = Self.pixelDimensions(in: source),
            dimensions.width > 0,
            dimensions.height > 0,
            max(dimensions.width, dimensions.height) <= Self.maximumPixelEdge else {
            return nil
        }

        return ValidatedFile(
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            byteCount: byteCount
        )
    }

    private func validatedFileURL(for record: StoredRecord) -> URL? {
        guard let fileURL = safeFileURL(filename: record.filename, id: record.id),
              validatedJPEG(at: fileURL) != nil else {
            return nil
        }
        return fileURL
    }

    private func safeFileURL(filename: String, id: UUID) -> URL? {
        guard filename == Self.filename(for: id) else { return nil }

        let candidate = rootURL
            .appendingPathComponent(filename, isDirectory: false)
            .standardizedFileURL
        let standardizedRoot = rootURL.standardizedFileURL
        guard candidate.deletingLastPathComponent() == standardizedRoot else { return nil }

        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.deletingLastPathComponent() == resolvedRoot else { return nil }
        return candidate
    }

    private func uniqueItemID() -> UUID {
        var candidate = UUID()
        while currentIndex.records.contains(where: { $0.id == candidate }) ||
            fileManager.fileExists(atPath: rootURL.appendingPathComponent(Self.filename(for: candidate)).path) {
            candidate = UUID()
        }
        return candidate
    }

    private func makeItem(from record: StoredRecord) -> PersonalStationMediaItem? {
        guard let fileURL = validatedFileURL(for: record) else { return nil }
        return PersonalStationMediaItem(
            id: record.id,
            stationKey: record.stationKey,
            fileURL: fileURL,
            createdAt: record.createdAt,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            byteCount: record.byteCount,
            // A photo stored before subjects existed is a station photo with no stated purpose;
            // `.stationMap` is the closest honest reading and is what the old grid showed.
            subject: record.subject ?? .stationMap,
            shareState: record.shareState ?? .local,
            remoteID: record.remoteID
        )
    }

    private func persist(_ index: StoredIndex) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        do {
            let data = try encoder.encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw PersonalStationMediaError.storageUnavailable
        }
    }

    private static func sanitizedJPEG(from sourceData: Data) throws -> SanitizedImage {
        guard let source = CGImageSourceCreateWithData(
            sourceData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw PersonalStationMediaError.unsupportedImage
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelEdge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ),
            thumbnail.width > 0,
            thumbnail.height > 0,
            max(thumbnail.width, thumbnail.height) <= maximumPixelEdge,
            let flattened = flattenedImage(thumbnail) else {
            throw PersonalStationMediaError.unsupportedImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PersonalStationMediaError.unsupportedImage
        }

        // Adding freshly redrawn pixels with empty metadata prevents any source dictionary from
        // being inherited. ImageIO still synthesizes a minimal APP1 block, removed below.
        CGImageDestinationAddImageAndMetadata(
            destination,
            flattened,
            CGImageMetadataCreateMutable(),
            [
                kCGImageDestinationLossyCompressionQuality: jpegQuality,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PersonalStationMediaError.unsupportedImage
        }

        guard let jpegData = removingMetadataSegments(from: output as Data) else {
            throw PersonalStationMediaError.unsupportedImage
        }
        guard !jpegData.isEmpty,
              let verificationSource = CGImageSourceCreateWithData(
                jpegData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let dimensions = pixelDimensions(in: verificationSource),
              max(dimensions.width, dimensions.height) <= maximumPixelEdge,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                verificationSource,
                0,
                nil
              ) as? [CFString: Any],
              properties[kCGImagePropertyGPSDictionary] == nil,
              properties[kCGImagePropertyExifDictionary] == nil else {
            throw PersonalStationMediaError.unsupportedImage
        }

        return SanitizedImage(
            data: jpegData,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height
        )
    }

    /// Removes metadata-bearing JPEG segments after ImageIO encoding. Parsing stops at SOS so
    /// marker-like bytes in compressed scan data are never interpreted as segment headers.
    private static func removingMetadataSegments(from jpegData: Data) -> Data? {
        let bytes = [UInt8](jpegData)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }

        var sanitized = Data(bytes[0...1])
        sanitized.reserveCapacity(bytes.count)
        var offset = 2

        while offset < bytes.count {
            guard offset + 1 < bytes.count, bytes[offset] == 0xff else { return nil }
            let marker = bytes[offset + 1]

            if marker == 0xda || marker == 0xd9 {
                sanitized.append(contentsOf: bytes[offset...])
                return sanitized
            }

            guard offset + 3 < bytes.count else { return nil }
            let segmentLength = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let segmentEnd = offset + 2 + segmentLength
            guard segmentLength >= 2, segmentEnd <= bytes.count else { return nil }

            // APP1 carries EXIF/GPS/XMP, APP13 carries IPTC, and COM carries comments.
            if marker != 0xe1, marker != 0xed, marker != 0xfe {
                sanitized.append(contentsOf: bytes[offset..<segmentEnd])
            }
            offset = segmentEnd
        }

        return nil
    }

    private static func flattenedImage(_ image: CGImage) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func pixelDimensions(in source: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (width.intValue, height.intValue)
    }

    private static func filename(for id: UUID) -> String {
        "\(id.uuidString).jpg"
    }

    private static func isManagedMediaFilename(_ value: String) -> Bool {
        guard value.lowercased().hasSuffix(".jpg") else { return false }
        return UUID(uuidString: String(value.dropLast(4))) != nil
    }

    private static func isNewer(_ lhs: StoredRecord, _ rhs: StoredRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct StoredIndex: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let records: [StoredRecord]
}

private struct StoredRecord: Codable, Equatable, Sendable {
    let id: UUID
    let stationKey: PersonalStationMediaKey
    let filename: String
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    // Optional in storage, not in the model: an index written before these existed must keep
    // decoding. `reconciledIndex` already drops records it cannot read, so a non-optional field
    // here would silently delete every photo taken before this version.
    var subject: PersonalStationMediaSubject?
    var shareState: PersonalStationMediaShareState?
    var remoteID: String?
}

private struct SanitizedImage: Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct ValidatedFile: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
}
