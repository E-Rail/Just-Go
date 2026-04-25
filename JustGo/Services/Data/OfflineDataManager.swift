import Foundation

@Observable
final class OfflineDataManager {
    private(set) var installedPacks: Set<String> = []
    var downloadStates: [String: DownloadState] = [:]

    enum DownloadState {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded(sizeBytes: Int64)
        case updateAvailable(newSizeBytes: Int64)
        case error(String)

        var isDownloaded: Bool {
            if case .downloaded = self { return true }
            return false
        }

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        var progress: Double? {
            if case .downloading(let progress) = self { return progress }
            return nil
        }
    }

    private let fileManager = FileManager.default
    private var offlineDataDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineData", isDirectory: true)
    }

    init() {
        loadInstalledPacks()
    }

    func isAvailable(cityID: String) -> Bool {
        installedPacks.contains(cityID)
    }

    func getDownloadState(cityID: String) -> DownloadState {
        downloadStates[cityID] ?? (installedPacks.contains(cityID) ? .downloaded(sizeBytes: 0) : .notDownloaded)
    }

    func getPackSize(cityID: String) -> Int64 {
        let cityDir = offlineDataDirectory.appendingPathComponent(cityID)
        guard fileManager.fileExists(atPath: cityDir.path) else { return 0 }

        let enumerator = fileManager.enumerator(at: cityDir, includingPropertiesForKeys: [.fileSizeKey])
        var totalSize: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            totalSize += (attrs?[.size] as? Int64) ?? 0
        }
        return totalSize
    }

    func getTotalStorageUsed() -> Int64 {
        installedPacks.reduce(0) { $0 + getPackSize(cityID: $1) }
    }

    func downloadPack(cityID: String, progressHandler: @escaping (Double) -> Void) async throws {
        downloadStates[cityID] = .downloading(progress: 0)

        // Create directory
        let cityDir = offlineDataDirectory.appendingPathComponent(cityID)
        try fileManager.createDirectory(at: cityDir, withIntermediateDirectories: true)

        // Simulate download progress
        for i in 1...10 {
            try await Task.sleep(for: .milliseconds(200))
            let progress = Double(i) / 10.0
            downloadStates[cityID] = .downloading(progress: progress)
            progressHandler(progress)
        }

        // Mark as downloaded
        downloadStates[cityID] = .downloaded(sizeBytes: getPackSize(cityID: cityID))
        installedPacks.insert(cityID)
        saveInstalledPacks()
    }

    func deletePack(cityID: String) throws {
        let cityDir = offlineDataDirectory.appendingPathComponent(cityID)
        if fileManager.fileExists(atPath: cityDir.path) {
            try fileManager.removeItem(at: cityDir)
        }
        installedPacks.remove(cityID)
        downloadStates[cityID] = .notDownloaded
        saveInstalledPacks()
    }

    func checkForUpdates(cityID: String) async throws -> Bool {
        // Check if server has newer version
        return false
    }

    // MARK: - Persistence

    private func loadInstalledPacks() {
        guard let data = UserDefaults.standard.data(forKey: "installedPacks"),
              let packs = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return
        }
        installedPacks = packs

        // Verify directories exist
        for pack in packs {
            let cityDir = offlineDataDirectory.appendingPathComponent(pack)
            if !fileManager.fileExists(atPath: cityDir.path) {
                installedPacks.remove(pack)
            }
        }
    }

    private func saveInstalledPacks() {
        if let data = try? JSONEncoder().encode(installedPacks) {
            UserDefaults.standard.set(data, forKey: "installedPacks")
        }
    }
}
