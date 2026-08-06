import ImageIO
import SwiftUI

// Swift forbids static stored properties on generic types, and this cache must be shared across
// every `StationAssetImage<Content, Failure>` specialization, so it lives at file scope instead.
private let stationAssetImageCache = NSCache<NSString, UIImage>()

/// Renders only bundled or privately persisted station media. Decodes off the main actor and,
/// when `targetDimension` is given, downsamples via ImageIO instead of decoding full resolution
/// — a grid of multi-MB personal photos would otherwise stall scrolling with per-cell,
/// main-thread, full-size decodes. Results are cached (bounded by `NSCache`'s own eviction).
struct StationAssetImage<Content: View, Failure: View>: View {
    let url: URL
    var targetDimension: CGFloat?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let failure: () -> Failure

    @State private var loadedImage: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let loadedImage {
                content(Image(uiImage: loadedImage))
            } else if didFail {
                failure()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private var cacheKey: NSString {
        "\(url.absoluteString)#\(targetDimension.map { String(Int($0)) } ?? "full")" as NSString
    }

    private func load() async {
        guard url.isFileURL else {
            didFail = true
            return
        }
        if let cached = stationAssetImageCache.object(forKey: cacheKey) {
            loadedImage = cached
            return
        }
        let dimension = targetDimension
        let decoded = await Task.detached(priority: .userInitiated) {
            StationAssetImageDecoder.decode(url: url, targetDimension: dimension)
        }.value
        guard !Task.isCancelled else { return }
        guard let decoded else {
            didFail = true
            return
        }
        stationAssetImageCache.setObject(decoded, forKey: cacheKey)
        loadedImage = decoded
    }

}

/// Non-generic on purpose: the decode runs in a detached task off the main actor, and referencing
/// it through the generic `StationAssetImage<Content, Failure>` would drag those views' possibly
/// main-actor-isolated `View` conformances across isolation (a Swift 6 error). A free helper carries
/// no such conformances.
private enum StationAssetImageDecoder {
    static func decode(url: URL, targetDimension: CGFloat?) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let targetDimension {
            let maxPixelSize = Int(targetDimension * UIScreen.main.scale)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct FullScreenStationImage: Identifiable {
    let url: URL
    let title: String

    var id: String {
        url.absoluteString
    }
}

struct FullScreenStationImageView: View {
    let image: FullScreenStationImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                StationAssetImage(url: image.url) { loadedImage in
                    ZoomableStationImage(image: loadedImage)
                } failure: {
                    ContentUnavailableView(
                        AppLocalization.text(
                            english: "Station media could not be loaded",
                            simplified: "车站媒体无法加载",
                            traditional: "車站媒體無法載入"
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.white)
                }
            }
            .navigationTitle(image.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel(AppLocalization.localized("Close station image"))
                }
            }
        }
    }
}

private struct ZoomableStationImage: View {
    let image: Image
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .padding()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(pinchGesture.simultaneously(with: dragGesture))
            .onTapGesture(count: 2) {
                resetZoom()
            }
            .accessibilityAddTraits(.isImage)
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = clamp(baseScale * value, minScale, maxScale)
                if scale == minScale {
                    offset = .zero
                    baseOffset = .zero
                }
            }
            .onEnded { _ in
                baseScale = scale
                if scale == minScale {
                    resetZoom()
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > minScale else { return }
                offset = CGSize(
                    width: baseOffset.width + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func resetZoom() {
        scale = minScale
        baseScale = minScale
        offset = .zero
        baseOffset = .zero
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
