import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

private struct HarnessStoredIndex: Codable {
    let schemaVersion: Int
    let records: [HarnessStoredRecord]
}

private struct HarnessStoredRecord: Codable {
    let id: UUID
    let stationKey: PersonalStationMediaKey
    let filename: String
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
}

@main
private enum PersonalStationMediaHarness {
    private static var fileManager: FileManager { FileManager() }

    static func main() async {
        do {
            try testCanonicalStationIdentity()
            print("PASS: canonical station identity")
            try await testSourceLimit()
            print("PASS: 25 MB source limit")
            try await testNormalizationAndMetadataStripping()
            print("PASS: 4096 px normalization and metadata stripping")
            try await testItemLimit()
            print("PASS: ten-item station limit")
            try await testStationIsolation()
            print("PASS: city and station isolation")
            try await testIndexRecovery()
            print("PASS: traversal and corrupt-index recovery")
            try await testAtomicPersistenceAndDeletion()
            print("PASS: atomic persistence and deletion")
            try await testRightsEpochShapedCleanup()
            print("PASS: rights-epoch media preservation")
            try await testSubjectAndShareStateMigration()
            print("PASS: subject/shareState round-trip and legacy migration")
            print("PersonalStationMediaStore: 8 tests passed")
        } catch {
            let message = "PersonalStationMediaStore test failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func testCanonicalStationIdentity() throws {
        let canonical = PersonalStationMediaKey(
            cityID: "8100",
            stationID: "network-8100-5100239bb9315f24"
        )
        try require(canonical?.canonicalStationID == "5100239bb9315f24", "network ID did not canonicalize")
        try require(
            PersonalStationMediaKey(cityID: "8100", stationID: "mapkit-name-22.1-114.1") == nil,
            "provider fallback ID was accepted"
        )
    }

    private static func testSourceLimit() async throws {
        let root = try temporaryRoot(named: "source-limit")
        defer { try? fileManager.removeItem(at: root) }

        let store = PersonalStationMediaStore(rootURL: root)
        let key = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "CEN")
        let oversized = Data(
            repeating: 0,
            count: PersonalStationMediaStore.maximumSourceByteCount + 1
        )

        try await requireMediaError(.sourceTooLarge) {
            try await store.importImageData(oversized, for: key, subject: .stationMap)
        }
        try require(!fileManager.fileExists(atPath: root.path), "oversized input created storage")
    }

    private static func testNormalizationAndMetadataStripping() async throws {
        let root = try temporaryRoot(named: "normalization")
        defer { try? fileManager.removeItem(at: root) }

        let sourceData = try makeJPEG(width: 5_000, height: 100, includePrivateMetadata: true)
        let sourceProperties = try imageProperties(sourceData)
        try require(sourceProperties[kCGImagePropertyGPSDictionary] != nil, "source lacks GPS fixture")
        try require(sourceProperties[kCGImagePropertyExifDictionary] != nil, "source lacks EXIF fixture")

        let store = PersonalStationMediaStore(rootURL: root)
        let key = PersonalStationMediaKey(cityID: "1100", canonicalStationID: "jianguomen")
        let item = try await store.importImageData(sourceData, for: key, subject: .stationMap)

        try require(max(item.pixelWidth, item.pixelHeight) == 4_096, "long edge was not normalized to 4096")
        try require(item.pixelWidth == 4_096, "unexpected normalized orientation")
        try require(item.pixelHeight > 0 && item.pixelHeight < 100, "aspect ratio was not preserved")

        let storedData = try Data(contentsOf: item.fileURL)
        let storedProperties = try imageProperties(storedData)
        try require(storedProperties[kCGImagePropertyGPSDictionary] == nil, "GPS metadata survived")
        try require(storedProperties[kCGImagePropertyExifDictionary] == nil, "EXIF metadata survived")
        try require(storedProperties[kCGImagePropertyIPTCDictionary] == nil, "IPTC metadata survived")
        try require(!containsMetadataJPEGSegment(storedData), "metadata-bearing JPEG segment survived")

        let storedDimensions = try imageDimensions(storedData)
        try require(storedDimensions.width == item.pixelWidth, "stored width differs from index")
        try require(storedDimensions.height == item.pixelHeight, "stored height differs from index")
    }

    private static func testItemLimit() async throws {
        let root = try temporaryRoot(named: "item-limit")
        defer { try? fileManager.removeItem(at: root) }

        let store = PersonalStationMediaStore(rootURL: root)
        let key = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "ADM")
        let sourceData = try makeJPEG(width: 48, height: 32)

        for _ in 0..<PersonalStationMediaStore.maximumItemsPerStation {
            try await store.importImageData(sourceData, for: key, subject: .stationMap)
        }
        try await requireMediaError(.itemLimitReached) {
            try await store.importImageData(sourceData, for: key, subject: .stationMap)
        }

        let items = try await store.items(for: key)
        try require(items.count == 10, "station contains \(items.count) items after limit rejection")
    }

    private static func testStationIsolation() async throws {
        let root = try temporaryRoot(named: "isolation")
        defer { try? fileManager.removeItem(at: root) }

        let store = PersonalStationMediaStore(rootURL: root)
        let sourceData = try makeJPEG(width: 40, height: 30)
        let central = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "CEN")
        let admiralty = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "ADM")
        let otherCity = PersonalStationMediaKey(cityID: "1100", canonicalStationID: "CEN")

        let centralItem = try await store.importImageData(sourceData, for: central, subject: .stationMap)
        let admiraltyItem = try await store.importImageData(sourceData, for: admiralty, subject: .stationMap)
        let otherCityItem = try await store.importImageData(sourceData, for: otherCity, subject: .stationMap)

        let centralIDs = try await store.items(for: central).map(\.id)
        let admiraltyIDs = try await store.items(for: admiralty).map(\.id)
        let otherCityIDs = try await store.items(for: otherCity).map(\.id)
        let crossStationURL = try await store.fileURL(for: centralItem.id, in: admiralty)
        try require(centralIDs == [centralItem.id], "central leaked another station")
        try require(admiraltyIDs == [admiraltyItem.id], "admiralty leaked another station")
        try require(otherCityIDs == [otherCityItem.id], "city boundary leaked media")
        try require(crossStationURL == nil, "cross-station file lookup succeeded")

        try await requireMediaError(.itemNotFound) {
            try await store.deleteItem(id: centralItem.id, for: otherCity)
        }
        let retainedURL = try await store.fileURL(for: centralItem.id, in: central)
        try require(retainedURL != nil, "wrong-key deletion removed media")
    }

    private static func testIndexRecovery() async throws {
        try await testTraversalRecordRecovery()
        try await testCorruptIndexRecovery()
    }

    private static func testTraversalRecordRecovery() async throws {
        let base = try temporaryRoot(named: "traversal")
        defer { try? fileManager.removeItem(at: base) }
        let root = base.appendingPathComponent("PersonalStationMedia", isDirectory: true)
        let key = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "CEN")
        let sourceData = try makeJPEG(width: 52, height: 36)

        let initialStore = PersonalStationMediaStore(rootURL: root)
        let validItem = try await initialStore.importImageData(sourceData, for: key, subject: .stationMap)

        let outsideURL = base.appendingPathComponent("outside.jpg", isDirectory: false)
        try sourceData.write(to: outsideURL, options: .atomic)
        let outsideBefore = try Data(contentsOf: outsideURL)
        let traversalID = UUID()
        let fixture = HarnessStoredIndex(
            schemaVersion: 1,
            records: [
                HarnessStoredRecord(
                    id: validItem.id,
                    stationKey: key,
                    filename: validItem.fileURL.lastPathComponent,
                    createdAt: validItem.createdAt,
                    pixelWidth: validItem.pixelWidth,
                    pixelHeight: validItem.pixelHeight,
                    byteCount: validItem.byteCount
                ),
                HarnessStoredRecord(
                    id: traversalID,
                    stationKey: key,
                    filename: "../outside.jpg",
                    createdAt: Date().addingTimeInterval(10),
                    pixelWidth: 52,
                    pixelHeight: 36,
                    byteCount: outsideBefore.count
                )
            ]
        )
        try encodeIndex(fixture).write(
            to: root.appendingPathComponent("index.json"),
            options: .atomic
        )

        let recoveredStore = PersonalStationMediaStore(rootURL: root)
        let recovered = try await recoveredStore.items(for: key)
        try require(recovered.map(\.id) == [validItem.id], "traversal record survived reconciliation")
        try require(try Data(contentsOf: outsideURL) == outsideBefore, "traversal target was modified")

        let repairedIndex = try String(
            contentsOf: root.appendingPathComponent("index.json"),
            encoding: .utf8
        )
        try require(!repairedIndex.contains("../outside.jpg"), "unsafe filename remained in index")
        try require(!repairedIndex.contains(traversalID.uuidString), "unsafe record remained in index")
    }

    private static func testCorruptIndexRecovery() async throws {
        let root = try temporaryRoot(named: "corrupt-index")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(
            to: root.appendingPathComponent("index.json"),
            options: .atomic
        )
        let orphanURL = root.appendingPathComponent("\(UUID().uuidString).jpg")
        try makeJPEG(width: 20, height: 20).write(to: orphanURL, options: .atomic)
        let tombstoneURL = root.appendingPathComponent(".deleting-\(UUID().uuidString.lowercased()).jpg")
        try makeJPEG(width: 20, height: 20).write(to: tombstoneURL, options: .atomic)

        let key = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "ADM")
        let store = PersonalStationMediaStore(rootURL: root)
        let corruptIndexItems = try await store.items(for: key)
        try require(corruptIndexItems.isEmpty, "corrupt index exposed records")
        try require(!fileManager.fileExists(atPath: orphanURL.path), "corrupt index left an unreachable JPEG")
        try require(!fileManager.fileExists(atPath: tombstoneURL.path), "recovery left a deletion tombstone")

        let names = try fileManager.contentsOfDirectory(atPath: root.path)
        try require(
            names.contains { $0.hasPrefix(".corrupt-index-") && $0.hasSuffix(".json") },
            "corrupt index was not quarantined"
        )

        let item = try await store.importImageData(
            makeJPEG(width: 36, height: 24),
            for: key,
            subject: .stationMap
        )
        try require(fileManager.fileExists(atPath: item.fileURL.path), "store did not recover after quarantine")
        try require(fileManager.fileExists(atPath: root.appendingPathComponent("index.json").path), "recovered index was not persisted")
    }

    private static func testAtomicPersistenceAndDeletion() async throws {
        try await testSuccessfulPersistenceAndDeletion()
        try await testFailedIndexCommitRollsBackImage()
    }

    private static func testSuccessfulPersistenceAndDeletion() async throws {
        let root = try temporaryRoot(named: "persistence")
        defer { try? fileManager.removeItem(at: root) }

        let key = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "TSY")
        let store = PersonalStationMediaStore(rootURL: root)
        let item = try await store.importImageData(
            makeJPEG(width: 44, height: 28),
            for: key,
            subject: .stationMap
        )
        let indexURL = root.appendingPathComponent("index.json")
        try require(fileManager.fileExists(atPath: indexURL.path), "import did not persist index")
        try require(fileManager.fileExists(atPath: item.fileURL.path), "import did not persist image")

        let reopened = PersonalStationMediaStore(rootURL: root)
        let reopenedIDs = try await reopened.items(for: key).map(\.id)
        try require(reopenedIDs == [item.id], "fresh store did not load committed import")

        try await reopened.deleteItem(id: item.id, for: key)
        try require(!fileManager.fileExists(atPath: item.fileURL.path), "delete left image on disk")
        let persistedIndex = try String(contentsOf: indexURL, encoding: .utf8)
        try require(!persistedIndex.contains(item.id.uuidString), "delete left item in committed index")

        let afterDelete = PersonalStationMediaStore(rootURL: root)
        let itemsAfterDelete = try await afterDelete.items(for: key)
        try require(itemsAfterDelete.isEmpty, "fresh store resurrected deleted item")
    }

    private static func testFailedIndexCommitRollsBackImage() async throws {
        let root = try temporaryRoot(named: "failed-commit")
        defer { try? fileManager.removeItem(at: root) }

        let key = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "HOK")
        let store = PersonalStationMediaStore(rootURL: root)
        _ = try await store.items(for: key)
        try fileManager.createDirectory(
            at: root.appendingPathComponent("index.json", isDirectory: true),
            withIntermediateDirectories: false
        )

        try await requireMediaError(.storageUnavailable) {
            try await store.importImageData(
                makeJPEG(width: 40, height: 24),
                for: key,
                subject: .stationMap
            )
        }

        let rootContents = try fileManager.contentsOfDirectory(atPath: root.path)
        try require(!rootContents.contains { $0.hasSuffix(".jpg") }, "failed index commit left a JPEG orphan")
    }

    /// A photo taken before subjects existed must survive the upgrade. `reconciledIndex` drops
    /// records it cannot decode, so a non-optional field in `StoredRecord` would delete the
    /// rider's whole library on first launch of this version rather than fail loudly.
    private static func testSubjectAndShareStateMigration() async throws {
        let root = try temporaryRoot(named: "subject-migration")
        defer { try? fileManager.removeItem(at: root) }

        let key = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "ADM")
        let store = PersonalStationMediaStore(rootURL: root)
        let saved = try await store.importImageData(
            makeJPEG(width: 40, height: 30),
            for: key,
            subject: .transferCorridor
        )
        try require(saved.subject == .transferCorridor, "import did not keep the subject")
        try require(saved.shareState == .local, "a captured photo must start local")
        try require(saved.remoteID == nil, "a captured photo must carry no remote ID")

        let reopened = PersonalStationMediaStore(rootURL: root)
        let roundTripped = try await reopened.items(for: key)
        try require(roundTripped.first?.subject == .transferCorridor, "subject did not survive a reload")
        try require(roundTripped.first?.shareState == .local, "shareState did not survive a reload")

        // Rewrite the index the way the previous version wrote it: no subject, no shareState.
        let indexURL = root.appendingPathComponent("index.json", isDirectory: false)
        var text = try String(contentsOf: indexURL, encoding: .utf8)
        for field in ["subject", "shareState"] {
            text = text.replacingOccurrences(
                of: "\"\(field)\":\"[A-Za-z]+\",?",
                with: "",
                options: .regularExpression
            )
        }
        text = text.replacingOccurrences(of: ",}", with: "}")
        try text.write(to: indexURL, atomically: true, encoding: .utf8)
        try require(!text.contains("shareState"), "test failed to produce a legacy index")

        let legacyStore = PersonalStationMediaStore(rootURL: root)
        let migrated = try await legacyStore.items(for: key)
        try require(migrated.count == 1, "legacy index lost the rider's photo")
        try require(migrated[0].id == saved.id, "legacy index resurrected the wrong record")
        try require(migrated[0].subject == .stationMap, "legacy record did not default its subject")
        try require(migrated[0].shareState == .local, "legacy record did not default its shareState")
    }

    private static func testRightsEpochShapedCleanup() async throws {
        let applicationSupport = try temporaryRoot(named: "rights-epoch")
        defer { try? fileManager.removeItem(at: applicationSupport) }
        let justGoRoot = applicationSupport.appendingPathComponent("JustGo", isDirectory: true)
        let personalRoot = justGoRoot.appendingPathComponent("PersonalStationMedia", isDirectory: true)
        let cityPacksRoot = justGoRoot.appendingPathComponent("CityPacks", isDirectory: true)
        try fileManager.createDirectory(at: cityPacksRoot, withIntermediateDirectories: true)
        try Data("legacy pack".utf8).write(to: cityPacksRoot.appendingPathComponent("8100.json"))

        let key = PersonalStationMediaKey(cityID: "8100", canonicalStationID: "CEN")
        let store = PersonalStationMediaStore(rootURL: personalRoot)
        let item = try await store.importImageData(
            makeJPEG(width: 32, height: 24),
            for: key,
            subject: .stationMap
        )

        // Mirrors the rights-epoch cleanup's storage boundary without importing the app entry point.
        try fileManager.removeItem(at: cityPacksRoot)

        try require(!fileManager.fileExists(atPath: cityPacksRoot.path), "legacy city packs survived cleanup")
        try require(fileManager.fileExists(atPath: personalRoot.path), "cleanup removed personal-media root")
        try require(fileManager.fileExists(atPath: item.fileURL.path), "cleanup removed personal image")
        let reopened = PersonalStationMediaStore(rootURL: personalRoot)
        let reopenedIDs = try await reopened.items(for: key).map(\.id)
        try require(reopenedIDs == [item.id], "cleanup broke personal-media index")
    }

    private static func temporaryRoot(named name: String) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("JustGoPersonalMediaTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let parent = root.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        return root
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: @autoclosure () -> String
    ) throws {
        guard try condition() else { throw HarnessFailure(description: message()) }
    }

    private static func requireMediaError(
        _ expected: PersonalStationMediaError,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch let actual as PersonalStationMediaError {
            try require(actual == expected, "expected \(expected), received \(actual)")
            return
        }
        throw HarnessFailure(description: "expected \(expected), operation succeeded")
    }

    private static func makeJPEG(
        width: Int,
        height: Int,
        includePrivateMetadata: Bool = false
    ) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw HarnessFailure(description: "could not create image context")
        }

        context.setFillColor(CGColor(red: 0.08, green: 0.44, blue: 0.61, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.92, green: 0.72, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: width / 4, y: 0, width: max(1, width / 5), height: height))
        guard let image = context.makeImage() else {
            throw HarnessFailure(description: "could not create fixture image")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw HarnessFailure(description: "could not create JPEG destination")
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        if includePrivateMetadata {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 22.2819,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 114.1580,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:15 12:34:56",
                kCGImagePropertyExifUserComment: "private test metadata"
            ]
            properties[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCCaptionAbstract: "private test caption"
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw HarnessFailure(description: "could not finalize JPEG fixture")
        }
        return output as Data
    }

    private static func imageProperties(_ data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw HarnessFailure(description: "could not read image properties")
        }
        return properties
    }

    private static func imageDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let properties = try imageProperties(data)
        guard let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw HarnessFailure(description: "image dimensions are missing")
        }
        return (width.intValue, height.intValue)
    }

    private static func containsMetadataJPEGSegment(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return true }
        var offset = 2

        while offset + 1 < bytes.count {
            guard bytes[offset] == 0xff else { return true }
            let marker = bytes[offset + 1]
            if marker == 0xda || marker == 0xd9 { return false }
            if marker == 0xe1 || marker == 0xed || marker == 0xfe { return true }
            guard offset + 3 < bytes.count else { return true }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { return true }
            offset += 2 + length
        }
        return true
    }

    private static func encodeIndex(_ index: HarnessStoredIndex) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(index)
    }
}
