import AVFoundation
import SwiftUI
import UIKit

@Observable
final class IndoorStepGoViewModel {
    let steps: [IndoorStep]
    var currentIndex = 0

    init(steps: [IndoorStep]) {
        self.steps = steps
    }

    var currentStep: IndoorStep? {
        steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
    }

    var canAdvance: Bool { currentIndex < steps.count - 1 }
    var canGoBack: Bool { currentIndex > 0 }

    func advance() { if canAdvance { currentIndex += 1 } }
    func goBack() { if canGoBack { currentIndex -= 1 } }

    var progressText: String {
        AppLocalization.stepProgress(current: currentIndex + 1, total: steps.count)
    }

    var progressFraction: Double {
        guard steps.count > 1 else { return 1 }
        return Double(currentIndex) / Double(steps.count - 1)
    }
}

/// A reusable indoor walkthrough. With `onComplete`, it embeds directly in LiveGo and reports
/// only an explicitly completed final checkpoint. Without callbacks it keeps the legacy
/// full-screen `TransferStationSheet` presentation and dismisses itself on manual completion.
struct IndoorStepGoView: View {
    let stationTitle: String
    let mapImageURL: URL?
    let indoorMap: StationIndoorMap
    let routeNodeIDs: [String]
    let routeEdgeIDs: [String]
    let transferContext: TransferContext?
    let boardingZoneGuidance: IndoorBoardingZoneGuidance?
    let onComplete: (() -> Void)?
    let onBack: (() -> Void)?

    @State private var viewModel: IndoorStepGoViewModel
    @State private var showScanner = false
    @State private var didComplete = false
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var announcedStep: IndoorStep?
    @State private var announcementTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue

    private var themeColor: Color { Color.adaptive(hex: selectedThemeHex) }
    private var isEmbedded: Bool { onComplete != nil || onBack != nil }

    init(
        stationTitle: String,
        mapImageURL: URL?,
        indoorMap: StationIndoorMap,
        routeNodeIDs: [String],
        routeEdgeIDs: [String] = [],
        destinationLineName: String?,
        transferContext: TransferContext? = nil,
        boardingZoneGuidance: IndoorBoardingZoneGuidance? = nil,
        onComplete: (() -> Void)? = nil,
        onBack: (() -> Void)? = nil
    ) {
        self.stationTitle = stationTitle
        self.mapImageURL = mapImageURL
        self.indoorMap = indoorMap
        self.routeNodeIDs = routeNodeIDs
        self.routeEdgeIDs = routeEdgeIDs
        self.transferContext = transferContext
        self.boardingZoneGuidance = boardingZoneGuidance
        self.onComplete = onComplete
        self.onBack = onBack
        _viewModel = State(initialValue: IndoorStepGoViewModel(
            steps: IndoorStep.build(
                nodeIDs: routeNodeIDs,
                edgeIDs: routeEdgeIDs,
                map: indoorMap,
                destinationLineName: destinationLineName
            )
        ))
    }

    var body: some View {
        Group {
            if isEmbedded {
                walkthroughContent
            } else {
                NavigationStack {
                    walkthroughContent
                        .navigationTitle(stationTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(AppLocalization.localized("Done")) {
                                    dismiss()
                                }
                            }
                        }
                }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            IndoorCheckpointScannerView(
                stationName: stationTitle,
                routeContext: scannerRouteContext,
                candidates: recognitionCandidates,
                expectedNodeID: expectedCheckpointNodeID
            ) { nodeID in
                showScanner = false
                completeRecognizedCheckpoint(nodeID)
            }
        }
        .onAppear {
            announceCurrentStep()
        }
        .onDisappear {
            speechSynthesizer.stopSpeaking(at: .immediate)
            announcementTask?.cancel()
        }
        .onChange(of: viewModel.currentIndex) { _, _ in
            announceCurrentStep()
        }
    }

    private var walkthroughContent: some View {
        VStack(spacing: 0) {
            disclaimerBanner
            if let boardingZoneGuidance {
                boardingZoneBanner(boardingZoneGuidance)
            }
            ScrollView {
                diagramView
                    .padding()
            }
            .background(Color.appBackground)
            instructionPanel
        }
        .overlay(alignment: .top) {
            if let announcedStep {
                announcementBanner(announcedStep)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// This remains visible throughout the walkthrough because the path is traced from an
    /// official diagram rather than supplied by an indoor positioning or navigation feed.
    private var disclaimerBanner: some View {
        Label {
            Text(AppLocalization.text(
                english: "Traced from the station diagram — not an official feed. Confirm with signage as you walk.",
                simplified: "路径根据官方站内图人工标注，非官方导航数据，请以站内标识为准。",
                traditional: "路徑根據官方站內圖人工標注，非官方導航資料，請以站內標識為準。"
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private func boardingZoneBanner(_ guidance: IndoorBoardingZoneGuidance) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "train.side.front.car")
                .foregroundStyle(themeColor)
            Text(AppLocalization.text(
                english: "Boarding zone: \(guidance.zone.localizedLabel)",
                simplified: "建议候车位置：\(guidance.zone.localizedLabel)",
                traditional: "建議候車位置：\(guidance.zone.localizedLabel)"
            ))
            .font(.caption)
            .fontWeight(.medium)
            Spacer(minLength: 0)
            DataConfidenceChip(confidence: guidance.confidence, compact: true)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeColor.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var diagramView: some View {
        if let mapImageURL {
            StationAssetImage(url: mapImageURL) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .overlay(pathOverlay)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } placeholder: {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } failure: {
                mapFallback
            }
        } else {
            mapFallback
        }
    }

    private var mapFallback: some View {
        ContentUnavailableView {
            Label(AppLocalization.localized("Station Map Unavailable"), systemImage: "map")
        } description: {
            Text(AppLocalization.localized("Continue with the text directions below."))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    @ViewBuilder
    private var pathOverlay: some View {
        let nodesByID = Dictionary(uniqueKeysWithValues: indoorMap.nodes.map { ($0.id, $0) })
        let points = routeNodeIDs.compactMap { nodesByID[$0]?.coordinate }
        if points.count > 1 {
            Canvas { context, size in
                let resolved = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

                var fullPath = Path()
                fullPath.addLines(resolved)
                context.stroke(
                    fullPath,
                    with: .color(.gray.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )

                if let step = viewModel.currentStep {
                    let from = max(0, min(step.fromNodeIndex, resolved.count - 1))
                    let through = max(0, min(step.throughNodeIndex, resolved.count - 1))
                    if through > from {
                        var current = Path()
                        current.addLines(Array(resolved[from...through]))
                        context.stroke(
                            current,
                            with: .color(themeColor),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                        )
                    }
                    let marker = resolved[through]
                    let dot = CGRect(x: marker.x - 7, y: marker.y - 7, width: 14, height: 14)
                    context.fill(Path(ellipseIn: dot), with: .color(themeColor))
                    context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 2)
                }

                if let start = resolved.first {
                    let dot = CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: dot), with: .color(.secondary))
                    context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
                }
                if let end = resolved.last {
                    let marker = CGRect(x: end.x - 8, y: end.y - 8, width: 16, height: 16)
                    context.fill(Path(ellipseIn: marker), with: .color(.green))
                    context.stroke(Path(ellipseIn: marker), with: .color(.white), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var instructionPanel: some View {
        VStack(spacing: 12) {
            if !viewModel.steps.isEmpty {
                ProgressView(value: viewModel.progressFraction)
                    .tint(themeColor)
                    .accessibilityLabel(viewModel.progressText)
            }

            if let step = viewModel.currentStep {
                stepSummary(step)
                    .id(step.id)
                    .transition(.opacity)
            }

            if !recognitionCandidates.isEmpty, viewModel.currentStep != nil {
                Button {
                    showScanner = true
                } label: {
                    Label(AppLocalization.localized("Scan Sign"), systemImage: "text.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            controls
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .bottom], 10)
    }

    private func stepSummary(_ step: IndoorStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: step.kind.icon)
                .font(.title)
                .foregroundStyle(themeColor)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let detail = step.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize {
                Text(viewModel.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [step.title, step.detail, viewModel.progressText]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                nextButton
                backButton
            }
        } else {
            HStack(spacing: 14) {
                backButton
                nextButton
            }
        }
    }

    private var backButton: some View {
        let canGoBack = viewModel.canGoBack || onBack != nil
        return Button {
            if viewModel.canGoBack {
                withAnimation { viewModel.goBack() }
            } else {
                onBack?()
            }
        } label: {
            Label(
                AppLocalization.text(english: "Back", simplified: "上一步", traditional: "上一步"),
                systemImage: "chevron.left"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!canGoBack)
        .opacity(canGoBack ? 1 : 0.4)
    }

    private var nextButton: some View {
        Button {
            if viewModel.canAdvance {
                withAnimation { viewModel.advance() }
            } else {
                finishIndoorGuidance()
            }
        } label: {
            Label(
                viewModel.canAdvance
                    ? AppLocalization.text(english: "Next", simplified: "下一步", traditional: "下一步")
                    : AppLocalization.localized("Done"),
                systemImage: viewModel.canAdvance ? "chevron.right" : "checkmark"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(themeColor, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var recognitionCandidates: [StationSignCandidate] {
        let nodesByID = Dictionary(uniqueKeysWithValues: indoorMap.nodes.map { ($0.id, $0) })
        var seen = Set<String>()
        return routeNodeIDs.compactMap { nodeID in
            guard seen.insert(nodeID).inserted,
                  let node = nodesByID[nodeID],
                  !node.resolvedRecognitionAliases.isEmpty else { return nil }
            return StationSignCandidate(node: node)
        }
    }

    private var expectedCheckpointNodeID: String? {
        guard let step = viewModel.currentStep,
              routeNodeIDs.indices.contains(step.throughNodeIndex) else { return nil }
        return routeNodeIDs[step.throughNodeIndex]
    }

    private var scannerRouteContext: String? {
        guard let transferContext else { return nil }
        let line = transferContext.outgoing.lineName
        let direction = transferContext.outgoing.directionTerminalStationName
            ?? transferContext.outgoing.directionNextStationName
        guard let direction else { return line }
        return AppLocalization.text(
            english: "Follow signs for \(line) toward \(direction)",
            simplified: "跟随\(line)往\(direction)方向的标识",
            traditional: "跟隨\(line)往\(direction)方向的標識"
        )
    }

    private func completeRecognizedCheckpoint(_ nodeID: String) {
        guard !didComplete else { return }
        Haptics.notify(.success)

        guard let routeIndex = routeNodeIDs.firstIndex(of: nodeID),
              let completedStepIndex = viewModel.steps.firstIndex(where: {
                  $0.throughNodeIndex >= routeIndex
              }) else { return }

        if completedStepIndex >= viewModel.steps.count - 1 {
            finishIndoorGuidance()
        } else {
            withAnimation {
                viewModel.currentIndex = completedStepIndex + 1
            }
        }
    }

    private func finishIndoorGuidance() {
        guard !didComplete else { return }
        didComplete = true
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }

    private func announceCurrentStep() {
        guard let step = viewModel.currentStep else { return }
        let preference = appState.accessibilityPreference
        let announcement = [step.title, step.detail].compactMap { $0 }.joined(
            separator: AppLocalization.isChinese ? "。" : ". "
        )

        if preference.vibrationAlerts {
            Haptics.notify(.success)
        }
        if preference.audioNavigation {
            speechSynthesizer.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: announcement)
            utterance.voice = AVSpeechSynthesisVoice(
                language: AppLocalization.isTraditionalChinese ? "zh-TW" : (AppLocalization.isChinese ? "zh-CN" : "en-US")
            )
            speechSynthesizer.speak(utterance)
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
        if preference.visualAnnouncements {
            announcementTask?.cancel()
            withAnimation { announcedStep = step }
            announcementTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation { announcedStep = nil }
            }
        }
    }

    private func announcementBanner(_ step: IndoorStep) -> some View {
        HStack(spacing: 10) {
            Image(systemName: step.kind.icon)
            Text(step.title)
                .fontWeight(.semibold)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            Spacer(minLength: 0)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity)
        .background(themeColor, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
