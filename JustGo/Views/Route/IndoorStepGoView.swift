import SwiftUI

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

/// A dedicated, full-screen turn-by-turn walkthrough of a traced indoor transfer path —
/// the same "one instruction card at a time" language as `LiveGoView`'s outdoor "Go", applied
/// to the station diagram instead of a real GPS map. There is no indoor position feed, so
/// unlike `LiveGoView` there is no auto-advance or off-route recovery here: the rider taps
/// Next as they walk, the same way they'd follow a printed direction card.
struct IndoorStepGoView: View {
    let stationTitle: String
    let mapImageURL: URL
    let indoorMap: StationIndoorMap
    let routeNodeIDs: [String]

    @State private var viewModel: IndoorStepGoViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue

    private var themeColor: Color { Color.adaptive(hex: selectedThemeHex) }

    init(stationTitle: String, mapImageURL: URL, indoorMap: StationIndoorMap, routeNodeIDs: [String], destinationLineName: String?) {
        self.stationTitle = stationTitle
        self.mapImageURL = mapImageURL
        self.indoorMap = indoorMap
        self.routeNodeIDs = routeNodeIDs
        _viewModel = State(initialValue: IndoorStepGoViewModel(
            steps: IndoorStep.build(nodeIDs: routeNodeIDs, map: indoorMap, destinationLineName: destinationLineName)
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                disclaimerBanner
                ScrollView {
                    diagramView
                        .padding()
                }
                .background(Color.appBackground)
                instructionPanel
            }
            .navigationTitle(stationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
    }

    /// Stays visible for every step, not a one-time dismissible notice — the whole path is
    /// traced by hand from a single official diagram image, not an official navigation feed.
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

    private var diagramView: some View {
        AsyncImage(url: mapImageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .overlay(pathOverlay)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            case .failure:
                Text(AppLocalization.localized("Station map could not be loaded"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }
    }

    /// Draws the full path dimmed, with the current step's segment highlighted thick/accent —
    /// mirrors the current/rest opacity-and-width split `LiveGoView.routeOverlays` uses for
    /// the outdoor route, just applied to fractional image coordinates instead of GPS.
    @ViewBuilder
    private var pathOverlay: some View {
        let nodesByID = Dictionary(uniqueKeysWithValues: indoorMap.nodes.map { ($0.id, $0) })
        let points = routeNodeIDs.compactMap { nodesByID[$0]?.coordinate }
        if points.count > 1 {
            Canvas { context, size in
                let resolved = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

                var fullPath = Path()
                fullPath.addLines(resolved)
                context.stroke(fullPath, with: .color(.gray.opacity(0.4)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                if let step = viewModel.currentStep {
                    let from = max(0, min(step.fromNodeIndex, resolved.count - 1))
                    let through = max(0, min(step.throughNodeIndex, resolved.count - 1))
                    if through > from {
                        var current = Path()
                        current.addLines(Array(resolved[from...through]))
                        context.stroke(current, with: .color(themeColor), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
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
        }
    }

    private var instructionPanel: some View {
        VStack(spacing: 12) {
            ProgressView(value: viewModel.progressFraction)
                .tint(themeColor)

            if let step = viewModel.currentStep {
                stepSummary(step)
                    .id(step.id)
                    .transition(.opacity)
            }

            controls
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
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
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let detail = step.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(viewModel.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([step.title, step.detail].compactMap { $0 }.joined(separator: ", "))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation { viewModel.goBack() }
            } label: {
                Label(AppLocalization.text(english: "Back", simplified: "上一步", traditional: "上一步"), systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoBack)
            .opacity(viewModel.canGoBack ? 1 : 0.4)

            Button {
                if viewModel.canAdvance {
                    withAnimation { viewModel.advance() }
                } else {
                    dismiss()
                }
            } label: {
                Label(
                    viewModel.canAdvance ? AppLocalization.text(english: "Next", simplified: "下一步", traditional: "下一步") : AppLocalization.localized("Done"),
                    systemImage: viewModel.canAdvance ? "chevron.right" : "checkmark"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(themeColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}
