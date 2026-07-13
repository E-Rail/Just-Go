import SwiftUI

/// Renders persisted `file://` city-pack assets and remote fallbacks through the same API.
/// SwiftUI's `AsyncImage` is retained for HTTP caching while local images are decoded from
/// the app's private Application Support directory.
struct StationAssetImage<Content: View, Placeholder: View, Failure: View>: View {
    let url: URL
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    var body: some View {
        if url.isFileURL {
            if let image = UIImage(contentsOfFile: url.path) {
                content(Image(uiImage: image))
            } else {
                failure()
            }
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): content(image)
                case .failure: failure()
                case .empty: placeholder()
                @unknown default: failure()
                }
            }
        }
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
                } placeholder: {
                    ProgressView()
                        .tint(.white)
                } failure: {
                    ContentUnavailableView(
                        AppLocalization.localized("Station map could not be loaded"),
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
