import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct PersonalMediaPhotoFile: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("JustGoPhotoImport-\(UUID().uuidString)", isDirectory: false)
            do {
                try copyWithLimit(from: received.file, to: destination)
                return PersonalMediaPhotoFile(fileURL: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    private static func copyWithLimit(from source: URL, to destination: URL) throws {
        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > PersonalStationMediaStore.maximumSourceByteCount {
            throw PersonalStationMediaError.sourceTooLarge
        }
        guard let input = InputStream(url: source),
              let output = OutputStream(url: destination, append: false) else {
            throw PersonalStationMediaError.storageUnavailable
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }

        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let readCount = buffer.withUnsafeMutableBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return input.read(baseAddress, maxLength: pointer.count)
            }
            if readCount < 0 { throw input.streamError ?? PersonalStationMediaError.storageUnavailable }
            if readCount == 0 { break }
            guard total <= PersonalStationMediaStore.maximumSourceByteCount - readCount else {
                throw PersonalStationMediaError.sourceTooLarge
            }
            total += readCount
            var written = 0
            while written < readCount {
                let count = buffer.withUnsafeBufferPointer { pointer in
                    guard let baseAddress = pointer.baseAddress else { return -1 }
                    return output.write(baseAddress + written, maxLength: readCount - written)
                }
                if count <= 0 { throw output.streamError ?? PersonalStationMediaError.storageUnavailable }
                written += count
            }
        }
    }
}

@MainActor
struct PersonalStationMediaSection: View {
    let stationKey: PersonalStationMediaKey
    let stationName: String
    let mediaStore: any PersonalStationMediaProviding
    let onOpen: (FullScreenStationImage) -> Void

    @State private var items: [PersonalStationMediaItem] = []
    @State private var loadPhase: LoadPhase = .loading
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isFileImporterPresented = false
    @State private var isImporting = false
    @State private var deletingItemIDs = Set<UUID>()
    @State private var itemPendingDeletion: PersonalStationMediaItem?
    @State private var operationError: String?

    init(
        stationKey: PersonalStationMediaKey,
        stationName: String,
        mediaStore: any PersonalStationMediaProviding = PersonalStationMediaStore.shared,
        onOpen: @escaping (FullScreenStationImage) -> Void
    ) {
        self.stationKey = stationKey
        self.stationName = stationName
        self.mediaStore = mediaStore
        self.onOpen = onOpen
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                provenanceLabels
                stateContent

                if isImporting {
                    Label {
                        Text(AppLocalization.text(
                            english: "Adding image…",
                            simplified: "正在添加图片…",
                            traditional: "正在加入圖片…"
                        ))
                    } icon: {
                        ProgressView()
                            .controlSize(.small)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let operationError {
                    Label(operationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .task(id: stationKey) {
            await loadItems()
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                await importPhoto(newValue)
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image]
        ) { result in
            handleFileImporterResult(result)
        }
        .confirmationDialog(
            AppLocalization.text(
                english: "Delete personal image?",
                simplified: "删除个人图片？",
                traditional: "刪除個人圖片？"
            ),
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { itemPendingDeletion = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: itemPendingDeletion
        ) { item in
            Button(
                AppLocalization.text(
                    english: "Delete",
                    simplified: "删除",
                    traditional: "刪除"
                ),
                role: .destructive
            ) {
                itemPendingDeletion = nil
                delete(item)
            }
            Button(
                AppLocalization.text(
                    english: "Cancel",
                    simplified: "取消",
                    traditional: "取消"
                ),
                role: .cancel
            ) {
                itemPendingDeletion = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(AppLocalization.text(
                english: "Personal Images",
                simplified: "个人图片",
                traditional: "個人圖片"
            ))
            .font(.headline)

            Spacer(minLength: 8)

            if case .loaded = loadPhase {
                Text("\(items.count)/\(PersonalStationMediaStore.maximumItemsPerStation)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            addMenu
        }
    }

    private var provenanceLabels: some View {
        HStack(spacing: 14) {
            Label(
                AppLocalization.text(
                    english: "Personal",
                    simplified: "个人",
                    traditional: "個人"
                ),
                systemImage: "person.crop.rectangle"
            )
            Label(
                AppLocalization.text(
                    english: "Not verified",
                    simplified: "未经验证",
                    traditional: "未經驗證"
                ),
                systemImage: "exclamationmark.shield"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var addMenu: some View {
        Menu {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label(
                    AppLocalization.text(
                        english: "Photo Library",
                        simplified: "照片图库",
                        traditional: "照片圖庫"
                    ),
                    systemImage: "photo.on.rectangle"
                )
            }

            Button {
                isFileImporterPresented = true
            } label: {
                Label(
                    AppLocalization.text(
                        english: "Choose File",
                        simplified: "选择文件",
                        traditional: "選擇檔案"
                    ),
                    systemImage: "folder"
                )
            }
        } label: {
            Label(
                AppLocalization.text(
                    english: "Add",
                    simplified: "添加",
                    traditional: "加入"
                ),
                systemImage: "plus"
            )
        }
        .disabled(
            loadPhase != .loaded ||
                isImporting ||
                items.count >= PersonalStationMediaStore.maximumItemsPerStation
        )
        .accessibilityHint(AppLocalization.text(
            english: "Choose an image source",
            simplified: "选择图片来源",
            traditional: "選擇圖片來源"
        ))
    }

    @ViewBuilder
    private var stateContent: some View {
        switch loadPhase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text(AppLocalization.text(
                    english: "Loading personal images…",
                    simplified: "正在加载个人图片…",
                    traditional: "正在載入個人圖片…"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await loadItems() }
                } label: {
                    Label(
                        AppLocalization.text(
                            english: "Retry",
                            simplified: "重试",
                            traditional: "重試"
                        ),
                        systemImage: "arrow.clockwise"
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)

        case .loaded where items.isEmpty:
            Label(
                AppLocalization.text(
                    english: "No personal images",
                    simplified: "暂无个人图片",
                    traditional: "暫無個人圖片"
                ),
                systemImage: "photo"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)

        case .loaded:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 128, maximum: 190), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(items) { item in
                    mediaTile(item)
                }
            }
        }
    }

    private func mediaTile(_ item: PersonalStationMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onOpen(FullScreenStationImage(
                    url: item.fileURL,
                    title: AppLocalization.text(
                        english: "\(stationName) personal image",
                        simplified: "\(stationName)个人图片",
                        traditional: "\(stationName)個人圖片"
                    )
                ))
            } label: {
                StationAssetImage(url: item.fileURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } failure: {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.text(
                english: "Open personal station image",
                simplified: "打开个人车站图片",
                traditional: "開啟個人車站圖片"
            ))

            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppLocalization.text(
                        english: "Personal",
                        simplified: "个人",
                        traditional: "個人"
                    ))
                    .font(.caption)
                    .fontWeight(.medium)
                    Text(AppLocalization.text(
                        english: "Not verified",
                        simplified: "未经验证",
                        traditional: "未經驗證"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if deletingItemIDs.contains(item.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 32, height: 32)
                } else {
                    Button(role: .destructive) {
                        itemPendingDeletion = item
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(AppLocalization.text(
                        english: "Delete personal image",
                        simplified: "删除个人图片",
                        traditional: "刪除個人圖片"
                    ))
                }
            }
        }
    }

    private func loadItems() async {
        let requestedKey = stationKey
        loadPhase = .loading
        operationError = nil

        do {
            let loadedItems = try await mediaStore.items(for: requestedKey)
            guard !Task.isCancelled, requestedKey == stationKey else { return }
            items = loadedItems
            loadPhase = .loaded
        } catch {
            guard !Task.isCancelled, requestedKey == stationKey else { return }
            items = []
            loadPhase = .failed(message(for: error))
        }
    }

    private func importPhoto(_ photo: PhotosPickerItem) async {
        guard !isImporting else { return }
        isImporting = true
        operationError = nil
        defer {
            isImporting = false
            selectedPhoto = nil
        }

        do {
            guard let transferred = try await photo.loadTransferable(type: PersonalMediaPhotoFile.self) else {
                throw PersonalStationMediaError.unsupportedImage
            }
            defer { try? FileManager.default.removeItem(at: transferred.fileURL) }
            let data = try await Self.copySecurityScopedData(from: transferred.fileURL)
            try await importData(data)
        } catch {
            operationError = message(for: error)
        }
    }

    private func handleFileImporterResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                await importFile(at: url)
            }
        case .failure(let error):
            operationError = message(for: error)
        }
    }

    private func importFile(at url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        operationError = nil
        defer { isImporting = false }

        do {
            // The security-scoped URL never crosses into the store. Its bytes are copied while
            // access is active, then only the owned Data value is handed to the actor.
            let data = try await Self.copySecurityScopedData(from: url)
            try await importData(data)
        } catch {
            operationError = message(for: error)
        }
    }

    private func importData(_ data: Data) async throws {
        let imported = try await mediaStore.importImageData(data, for: stationKey)
        items.removeAll { $0.id == imported.id }
        items.insert(imported, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
        loadPhase = .loaded
    }

    private func delete(_ item: PersonalStationMediaItem) {
        guard deletingItemIDs.insert(item.id).inserted else { return }
        operationError = nil

        Task {
            defer { deletingItemIDs.remove(item.id) }
            do {
                try await mediaStore.deleteItem(id: item.id, for: stationKey)
                items.removeAll { $0.id == item.id }
                loadPhase = .loaded
            } catch {
                operationError = message(for: error)
            }
        }
    }

    private nonisolated static func copySecurityScopedData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > PersonalStationMediaStore.maximumSourceByteCount {
                throw PersonalStationMediaError.sourceTooLarge
            }

            guard let stream = InputStream(url: url) else {
                throw PersonalStationMediaError.storageUnavailable
            }
            stream.open()
            defer { stream.close() }

            var copiedData = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let readCount = buffer.withUnsafeMutableBufferPointer { pointer in
                    guard let baseAddress = pointer.baseAddress else { return 0 }
                    return stream.read(baseAddress, maxLength: pointer.count)
                }
                if readCount < 0 {
                    throw stream.streamError ?? PersonalStationMediaError.storageUnavailable
                }
                if readCount == 0 { break }
                guard copiedData.count <= PersonalStationMediaStore.maximumSourceByteCount - readCount else {
                    throw PersonalStationMediaError.sourceTooLarge
                }
                copiedData.append(contentsOf: buffer.prefix(readCount))
            }
            return copiedData
        }.value
    }

    private func message(for error: Error) -> String {
        switch error as? PersonalStationMediaError {
        case .sourceTooLarge:
            return AppLocalization.text(
                english: "Images must be 25 MB or smaller.",
                simplified: "图片大小不能超过 25 MB。",
                traditional: "圖片大小不能超過 25 MB。"
            )
        case .unsupportedImage:
            return AppLocalization.text(
                english: "This image could not be added.",
                simplified: "无法添加此图片。",
                traditional: "無法加入此圖片。"
            )
        case .itemLimitReached:
            return AppLocalization.text(
                english: "You can keep up to 10 personal images for this station.",
                simplified: "每个车站最多可保存 10 张个人图片。",
                traditional: "每個車站最多可儲存 10 張個人圖片。"
            )
        case .itemNotFound:
            return AppLocalization.text(
                english: "This personal image is no longer available.",
                simplified: "此个人图片已不可用。",
                traditional: "此個人圖片已無法使用。"
            )
        case .invalidStationKey, .storageUnavailable, .none:
            return AppLocalization.text(
                english: "Personal images are unavailable right now.",
                simplified: "个人图片目前不可用。",
                traditional: "個人圖片目前無法使用。"
            )
        }
    }
}

private enum LoadPhase: Equatable {
    case loading
    case loaded
    case failed(String)
}
