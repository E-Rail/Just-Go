import PDFKit
import SwiftUI
import UIKit
import WebKit

enum OfficialTransitResourceButtonLayout {
    case row
    case chip
}

struct OfficialTransitResourceButton: View {
    let resource: ExternalTransitResource
    var stationName: String? = nil
    var compact = false
    var layout: OfficialTransitResourceButtonLayout = .row

    @State private var isPresentingViewer = false

    private var displayTitle: String {
        guard let stationName else { return resource.kind.localizedTitle }
        return "\(stationName) · \(resource.kind.localizedTitle)"
    }

    var body: some View {
        if resource.url != nil {
            Button {
                isPresentingViewer = true
            } label: {
                switch layout {
                case .row:
                    rowLabel
                case .chip:
                    chipLabel
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.text(
                english: "\(displayTitle), \(resource.format.badgeTitle), opens inside JustGo from \(resource.provider)",
                simplified: "\(displayTitle)，\(resource.format.badgeTitle)，在 JustGo 内打开 \(resource.provider)",
                traditional: "\(displayTitle)，\(resource.format.badgeTitle)，在 JustGo 內開啟 \(resource.provider)"
            ))
            .fullScreenCover(isPresented: $isPresentingViewer) {
                OfficialTransitResourceViewer(resource: resource)
            }
        }
    }

    private var rowLabel: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(compact ? .caption : .subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    formatBadge
                    Text(resource.provider)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 2)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var chipLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .accessibilityHidden(true)
            Text(displayTitle)
                .lineLimit(1)
            formatBadge
            Image(systemName: "chevron.right")
                .font(.caption2)
                .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var formatBadge: some View {
        Text(resource.format.badgeTitle)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var iconName: String {
        switch resource.kind.group {
        case .maps:
            return "map"
        case .travel:
            return "tram.fill"
        case .accessibility:
            return "accessibility"
        case .help:
            return "questionmark.circle"
        }
    }
}

struct OfficialTransitResourceViewer: View {
    let resource: ExternalTransitResource

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var webState = OfficialTransitResourceWebState()
    @StateObject private var binaryState = OfficialTransitBinaryResourceState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourceHeader
                Divider()
                ZStack {
                    resourceContent

                    if let errorMessage = activeErrorMessage {
                        failureView(errorMessage)
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.large)
                            .padding(20)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel(AppLocalization.text(
                                english: "Loading official resource",
                                simplified: "正在加载官方资源",
                                traditional: "正在載入官方資源"
                            ))
                    }
                }
                if resource.format == .webPage {
                    controlBar
                }
            }
            .background(Color.appBackground)
            .navigationTitle(resource.kind.localizedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.text(
                        english: "Done",
                        simplified: "完成",
                        traditional: "完成"
                    )) {
                        dismiss()
                    }
                }
            }
        }
        .task(id: resource.id) {
            if resource.format != .webPage {
                binaryState.load(resource)
            }
        }
        .onDisappear {
            binaryState.cancel()
        }
    }

    @ViewBuilder
    private var resourceContent: some View {
        switch resource.format {
        case .webPage:
            OfficialTransitResourceWebView(resource: resource, state: webState)
        case .pdf:
            if let document = binaryState.pdfDocument {
                OfficialTransitPDFView(document: document)
            }
        case .image:
            if let image = binaryState.image {
                OfficialTransitImageView(image: image, accessibilityTitle: resource.kind.localizedTitle)
            }
        }
    }

    private var isLoading: Bool {
        resource.format == .webPage ? webState.isLoading : binaryState.isLoading
    }

    private var activeErrorMessage: String? {
        resource.format == .webPage ? webState.errorMessage : binaryState.errorMessage
    }

    private var currentHost: String? {
        resource.format == .webPage ? webState.currentHost : binaryState.currentHost
    }

    private var sourceHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(resource.provider)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(currentHost ?? resource.url?.host ?? resource.targetURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(resource.format.badgeTitle)
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLocalization.text(
            english: "Official resource from \(resource.provider), temporary in-app session",
            simplified: "来自 \(resource.provider) 的官方资源，应用内临时会话",
            traditional: "來自 \(resource.provider) 的官方資源，App 內臨時工作階段"
        ))
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            viewerControl(
                icon: "chevron.left",
                label: AppLocalization.text(english: "Back", simplified: "后退", traditional: "返回"),
                enabled: webState.canGoBack,
                action: webState.goBack
            )
            viewerControl(
                icon: "chevron.right",
                label: AppLocalization.text(english: "Forward", simplified: "前进", traditional: "前進"),
                enabled: webState.canGoForward,
                action: webState.goForward
            )
            viewerControl(
                icon: "arrow.clockwise",
                label: AppLocalization.text(english: "Reload", simplified: "重新加载", traditional: "重新載入"),
                enabled: true,
                action: webState.reload
            )
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(.bar)
    }

    private func viewerControl(
        icon: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                AppLocalization.text(
                    english: "Resource Could Not Open",
                    simplified: "无法打开资源",
                    traditional: "無法開啟資源"
                ),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            Button {
                reloadResource()
            } label: {
                Label(
                    AppLocalization.text(
                        english: "Try Again",
                        simplified: "重试",
                        traditional: "重試"
                    ),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.borderedProminent)

            if resource.kind != .stationInformation, let url = resource.url {
                Button {
                    openURL(url)
                } label: {
                    Label(
                        AppLocalization.text(
                            english: "Open in Browser",
                            simplified: "在浏览器中打开",
                            traditional: "在瀏覽器中開啟"
                        ),
                        systemImage: "safari"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.appBackground)
    }

    private func reloadResource() {
        if resource.format == .webPage {
            webState.reload()
        } else {
            binaryState.load(resource)
        }
    }
}

@MainActor
private final class OfficialTransitBinaryResourceState: ObservableObject {
    static let maximumBinaryBytes = 50 * 1_024 * 1_024

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var pdfDocument: PDFDocument?
    @Published var image: UIImage?
    @Published var currentHost: String?

    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()

    func load(_ resource: ExternalTransitResource) {
        cancel()
        guard let url = resource.url, url.scheme?.lowercased() == "https" else {
            errorMessage = AppLocalization.text(
                english: "The reviewed resource address is invalid.",
                simplified: "已审核的资源地址无效。",
                traditional: "已審核的資源位址無效。"
            )
            return
        }

        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        errorMessage = nil
        pdfDocument = nil
        image = nil
        currentHost = nil

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.setValue(
            resource.format == .pdf ? "application/pdf" : "image/*",
            forHTTPHeaderField: "Accept"
        )

        loadTask = Task { [weak self] in
            guard let self else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            do {
                // `timeoutIntervalForRequest`/`timeoutIntervalForResource` only fire when no
                // bytes arrive for the interval — a connection that trickles data indefinitely
                // never trips them, so a buffered `session.data(for:)` can hang well past the
                // declared 30s and leave the viewer looking frozen. Race it against an explicit
                // deadline, mirroring the fix in OfficialStationInformationProvider.swift.
                let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                    group.addTask { try await session.data(for: request) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        throw OfficialTransitBinaryLoadError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw OfficialTransitBinaryLoadError.timedOut
                    }
                    return result
                }
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }
                guard let response = response as? HTTPURLResponse else {
                    throw OfficialTransitBinaryLoadError.invalidResponse
                }
                guard (200...299).contains(response.statusCode) else {
                    throw OfficialTransitBinaryLoadError.httpStatus(response.statusCode)
                }
                guard response.url?.scheme?.lowercased() == "https" else {
                    throw OfficialTransitBinaryLoadError.insecureRedirect
                }
                currentHost = response.url?.host
                guard data.count <= Self.maximumBinaryBytes else {
                    throw OfficialTransitBinaryLoadError.tooLarge
                }

                switch resource.format {
                case .pdf:
                    // Decoding a near-50MB PDF/image is real CPU work; keep it off the main
                    // actor so it can't stall the UI, matching the pattern already used for
                    // heavy decode work elsewhere in this codebase.
                    guard let document = await Task.detached(priority: .userInitiated, operation: {
                        PDFDocument(data: data)
                    }).value, document.pageCount > 0 else {
                        throw OfficialTransitBinaryLoadError.invalidPDF
                    }
                    guard loadGeneration == generation else { return }
                    pdfDocument = document
                case .image:
                    guard let loadedImage = await Task.detached(priority: .userInitiated, operation: {
                        UIImage(data: data)
                    }).value else {
                        throw OfficialTransitBinaryLoadError.invalidImage
                    }
                    guard loadGeneration == generation else { return }
                    image = loadedImage
                case .webPage:
                    throw OfficialTransitBinaryLoadError.invalidResponse
                }
                isLoading = false
                loadTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard loadGeneration == generation else { return }
                isLoading = false
                errorMessage = error.localizedDescription
                loadTask = nil
            }
        }
    }

    func cancel() {
        loadGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }
}

private enum OfficialTransitBinaryLoadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case insecureRedirect
    case tooLarge
    case invalidPDF
    case invalidImage
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return AppLocalization.text(
                english: "The operator did not respond in time.",
                simplified: "运营方响应超时。",
                traditional: "營運方回應逾時。"
            )
        case .invalidResponse:
            return AppLocalization.text(
                english: "The operator returned an invalid response.",
                simplified: "运营方返回了无效响应。",
                traditional: "營運方傳回了無效回應。"
            )
        case .httpStatus(let statusCode):
            return AppLocalization.text(
                english: "The operator returned HTTP \(statusCode).",
                simplified: "运营方返回 HTTP \(statusCode)。",
                traditional: "營運方傳回 HTTP \(statusCode)。"
            )
        case .insecureRedirect:
            return AppLocalization.text(
                english: "JustGo blocked a redirect to a non-secure address.",
                simplified: "JustGo 已阻止重定向至非安全地址。",
                traditional: "JustGo 已封鎖重新導向至非安全位址。"
            )
        case .tooLarge:
            return AppLocalization.text(
                english: "This operator file is larger than the 50 MB in-app limit.",
                simplified: "此运营方文件超过 50 MB 的应用内限制。",
                traditional: "此營運方檔案超過 50 MB 的 App 內限制。"
            )
        case .invalidPDF:
            return AppLocalization.text(
                english: "The operator response is not a readable PDF.",
                simplified: "运营方响应不是可读取的 PDF。",
                traditional: "營運方回應不是可讀取的 PDF。"
            )
        case .invalidImage:
            return AppLocalization.text(
                english: "The operator response is not a readable image.",
                simplified: "运营方响应不是可读取的图片。",
                traditional: "營運方回應不是可讀取的圖片。"
            )
        }
    }
}

private struct OfficialTransitPDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = false
        pdfView.backgroundColor = .systemGroupedBackground
        pdfView.document = document
        pdfView.autoScales = true
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        guard pdfView.document !== document else { return }
        pdfView.document = document
        pdfView.autoScales = true
    }
}

private struct OfficialTransitImageView: UIViewRepresentable {
    let image: UIImage
    let accessibilityTitle: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .systemBackground
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = accessibilityTitle
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.imageView?.accessibilityLabel = accessibilityTitle
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        scrollView.delegate = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}

@MainActor
private final class OfficialTransitResourceWebState: ObservableObject {
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentHost: String?

    private weak var webView: WKWebView?
    private var initialRequest: URLRequest?

    func attach(_ webView: WKWebView, initialRequest: URLRequest) {
        self.webView = webView
        self.initialRequest = initialRequest
        updateNavigationState(webView)
    }

    func detach(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        self.webView = nil
    }

    func started(_ webView: WKWebView) {
        isLoading = true
        errorMessage = nil
        updateNavigationState(webView)
    }

    func finished(_ webView: WKWebView) {
        isLoading = false
        errorMessage = nil
        updateNavigationState(webView)
    }

    func failed(_ webView: WKWebView, message: String) {
        isLoading = false
        errorMessage = message
        updateNavigationState(webView)
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        guard let webView else { return }
        errorMessage = nil
        isLoading = true
        if webView.url == nil, let initialRequest {
            webView.load(initialRequest)
        } else {
            webView.reloadFromOrigin()
        }
    }

    private func updateNavigationState(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentHost = webView.url?.host
    }
}

private struct OfficialTransitResourceWebView: UIViewRepresentable {
    let resource: ExternalTransitResource
    @ObservedObject var state: OfficialTransitResourceWebState

    func makeCoordinator() -> Coordinator {
        Coordinator(resource: resource, state: state)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if resource.kind == .stationInformation {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Self.stationInformationReaderScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        context.coordinator.loadInitialResource(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(resource: resource)
        context.coordinator.loadInitialResourceIfNeeded(in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.detach(from: webView)
    }

    private static let stationInformationReaderScript = """
    (() => {
      const viewport = document.querySelector('meta[name="viewport"]') || document.createElement('meta');
      viewport.name = 'viewport';
      viewport.content = 'width=device-width, initial-scale=1, maximum-scale=5';
      if (!viewport.parentNode) document.head.appendChild(viewport);

      const style = document.createElement('style');
      style.id = 'justgo-station-reader';
      style.textContent = `
        :root { color-scheme: light; }
        html, body {
          width: 100% !important;
          min-width: 0 !important;
          margin: 0 !important;
          padding: 0 !important;
          overflow-x: hidden !important;
          background: #f2f2f7 !important;
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif !important;
          -webkit-text-size-adjust: 100% !important;
        }
        .wrap, .content, .siteinfo, .firstcartime, .firstcartime_time {
          box-sizing: border-box !important;
          width: 100% !important;
          min-width: 0 !important;
          max-width: none !important;
          height: auto !important;
          margin: 0 !important;
          padding: 0 !important;
          float: none !important;
        }
        #header, .header, .here, #sider, .side, #footer, .bottom,
        .locbox, body > script, .content + * {
          display: none !important;
        }
        .content { display: block !important; }
        .firstcartime_sitename {
          box-sizing: border-box !important;
          width: 100% !important;
          height: auto !important;
          padding: 18px 16px 10px !important;
          color: #111111 !important;
          font-size: 26px !important;
          font-weight: 700 !important;
          line-height: 1.2 !important;
          background: transparent !important;
        }
        #tabs, .tabs {
          box-sizing: border-box !important;
          display: grid !important;
          grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
          gap: 1px !important;
          width: calc(100% - 24px) !important;
          height: auto !important;
          margin: 0 12px !important;
          padding: 0 !important;
          overflow: hidden !important;
          border: 1px solid #d1d1d6 !important;
          border-radius: 8px !important;
          background: #d1d1d6 !important;
        }
        #tabs li, .tabs li {
          box-sizing: border-box !important;
          width: auto !important;
          height: auto !important;
          margin: 0 !important;
          padding: 0 !important;
          float: none !important;
          list-style: none !important;
          background: #ffffff !important;
        }
        #tabs li a, .tabs li a {
          box-sizing: border-box !important;
          display: flex !important;
          align-items: center !important;
          justify-content: center !important;
          min-height: 44px !important;
          padding: 8px !important;
          color: #1c1c1e !important;
          font-size: 14px !important;
          line-height: 1.2 !important;
          text-align: center !important;
          text-decoration: none !important;
          background: transparent !important;
        }
        #tabs li.thistab, .tabs li.thistab {
          background: #e8f1f7 !important;
        }
        .tab-content {
          box-sizing: border-box !important;
          width: 100% !important;
          min-width: 0 !important;
          padding: 12px !important;
          color: #3a3a3c !important;
          background: transparent !important;
        }
        .tab-panel, .card, .card-content, .direction-section {
          box-sizing: border-box !important;
          min-width: 0 !important;
          max-width: 100% !important;
        }
        .card {
          overflow: hidden !important;
          border-radius: 8px !important;
          background: #ffffff !important;
        }
        .card-content { display: block !important; }
        .card-content .direction-section {
          width: 100% !important;
          border-right: 0 !important;
          border-bottom: 1px solid #e5e5ea !important;
        }
        .card-content .direction-section:last-child { border-bottom: 0 !important; }
        .direction-title, .time-value { overflow-wrap: anywhere !important; }
        .exit-container, .facility-list {
          box-sizing: border-box !important;
          display: grid !important;
          grid-template-columns: minmax(0, 1fr) !important;
          gap: 12px !important;
          width: 100% !important;
        }
        .exit-item, .facility-item {
          box-sizing: border-box !important;
          min-width: 0 !important;
          padding: 10px !important;
          border-radius: 8px !important;
          background: #ffffff !important;
        }
        .exit-item-info, .facility-item-right {
          min-width: 0 !important;
          overflow-wrap: anywhere !important;
        }
        #map {
          box-sizing: border-box !important;
          width: 100% !important;
          max-width: 100% !important;
          height: 320px !important;
          border-radius: 8px !important;
          overflow: hidden !important;
        }
        img, .schedule-pic {
          max-width: 100% !important;
          height: auto !important;
        }
        table {
          display: block !important;
          width: 100% !important;
          max-width: 100% !important;
          overflow-x: auto !important;
          -webkit-overflow-scrolling: touch !important;
        }
        a, button, [role="button"] { min-height: 44px; }
        @media (min-width: 620px) {
          #tabs, .tabs { grid-template-columns: repeat(4, minmax(0, 1fr)) !important; }
          .card-content { display: flex !important; }
          .card-content .direction-section {
            width: auto !important;
            border-right: 1px solid #e5e5ea !important;
            border-bottom: 0 !important;
          }
          .card-content .direction-section:last-child { border-right: 0 !important; }
          .exit-container, .facility-list {
            grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
          }
        }
      `;
      document.head.appendChild(style);
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var resource: ExternalTransitResource
        private let state: OfficialTransitResourceWebState
        private var loadedResourceID: String?

        init(resource: ExternalTransitResource, state: OfficialTransitResourceWebState) {
            self.resource = resource
            self.state = state
        }

        func update(resource: ExternalTransitResource) {
            self.resource = resource
        }

        func loadInitialResourceIfNeeded(in webView: WKWebView) {
            guard loadedResourceID != resource.id else { return }
            loadInitialResource(in: webView)
        }

        func loadInitialResource(in webView: WKWebView) {
            guard let url = resource.url else {
                state.failed(
                    webView,
                    message: AppLocalization.text(
                        english: "The reviewed resource address is invalid.",
                        simplified: "已审核的资源地址无效。",
                        traditional: "已審核的資源位址無效。"
                    )
                )
                return
            }
            loadedResourceID = resource.id
            let request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 30
            )
            state.attach(webView, initialRequest: request)
            webView.load(request)
        }

        func detach(from webView: WKWebView) {
            state.detach(webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            state.started(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            state.finished(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            report(error, in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            report(error, in: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.failed(
                webView,
                message: AppLocalization.text(
                    english: "The official page stopped responding. Try loading it again.",
                    simplified: "官方页面已停止响应，请重新加载。",
                    traditional: "官方頁面已停止回應，請重新載入。"
                )
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }

            let isMainFrame = navigationAction.targetFrame?.isMainFrame != false
            guard url.scheme?.lowercased() == "https" else {
                if isMainFrame {
                    state.failed(
                        webView,
                        message: AppLocalization.text(
                            english: "JustGo blocked a non-secure link from this page.",
                            simplified: "JustGo 已阻止此页面中的非安全链接。",
                            traditional: "JustGo 已封鎖此頁面中的非安全連結。"
                        )
                    )
                }
                decisionHandler(.cancel)
                return
            }

            if isMainFrame, !isReviewedHost(url.host) {
                state.failed(
                    webView,
                    message: AppLocalization.text(
                        english: "This page redirected outside its reviewed official domain.",
                        simplified: "此页面已重定向至已审核官方域名之外。",
                        traditional: "此頁面已重新導向至已審核官方網域之外。"
                    )
                )
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard navigationResponse.canShowMIMEType else {
                state.failed(
                    webView,
                    message: AppLocalization.text(
                        english: "This operator file cannot be displayed inside JustGo.",
                        simplified: "此运营方文件无法在 JustGo 内显示。",
                        traditional: "此營運方檔案無法在 JustGo 內顯示。"
                    )
                )
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func isReviewedHost(_ candidate: String?) -> Bool {
            guard let candidate = normalizedHost(candidate) else { return false }
            return reviewedHosts.contains { reviewed in
                candidate == reviewed || candidate.hasSuffix(".\(reviewed)")
            }
        }

        private var reviewedHosts: Set<String> {
            [resource.url?.host, resource.sourceURL?.host]
                .compactMap(normalizedHost)
                .reduce(into: Set<String>()) { $0.insert($1) }
        }

        private func normalizedHost(_ host: String?) -> String? {
            guard let host = host?.lowercased(), !host.isEmpty else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        private func report(_ error: Error, in webView: WKWebView) {
            let networkError = error as NSError
            guard networkError.code != NSURLErrorCancelled else { return }
            state.failed(webView, message: networkError.localizedDescription)
        }
    }
}
