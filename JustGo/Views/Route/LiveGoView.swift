import SwiftUI

@Observable
final class LiveGoViewModel {
    let plan: LiveTripPlan
    var currentIndex = 0

    init(plan: LiveTripPlan) {
        self.plan = plan
    }

    var currentStep: TripStep? {
        plan.steps.indices.contains(currentIndex) ? plan.steps[currentIndex] : nil
    }

    var canAdvance: Bool { currentIndex < plan.steps.count - 1 }
    var canGoBack: Bool { currentIndex > 0 }

    func advance() { if canAdvance { currentIndex += 1 } }
    func goBack() { if canGoBack { currentIndex -= 1 } }

    var progressText: String {
        AppLocalization.stepProgress(current: currentIndex + 1, total: plan.steps.count)
    }

    var progressFraction: Double {
        guard plan.steps.count > 1 else { return 1 }
        return Double(currentIndex) / Double(plan.steps.count - 1)
    }
}

/// Full-screen, accessibility-first step-by-step in-station companion.
struct LiveGoView: View {
    @State private var viewModel: LiveGoViewModel
    @Environment(\.dismiss) private var dismiss

    init(plan: LiveTripPlan) {
        _viewModel = State(initialValue: LiveGoViewModel(plan: plan))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ProgressView(value: viewModel.progressFraction)
                    .tint(.blue)

                Text(viewModel.progressText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if let step = viewModel.currentStep {
                    stepCard(step)
                        .id(step.id)
                        .transition(.opacity)
                }

                Spacer()
                controls
            }
            .padding()
            .navigationTitle(AppLocalization.text(english: "Go", simplified: "出发", traditional: "出發"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func stepCard(_ step: TripStep) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon(for: step.kind))
                .font(.system(size: 60))
                .foregroundStyle(color(for: step))

            Text(step.title)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            if let detail = step.detail {
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let stopsLeft = step.rideStopsRemainingText {
                Text(stopsLeft)
                    .font(.headline)
                    .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step.accessibilityLabel)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation { viewModel.goBack() }
            } label: {
                Label(AppLocalization.text(english: "Back", simplified: "上一步", traditional: "上一步"), systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
                    .padding()
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
                .padding()
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private func icon(for kind: LiveStepKind) -> String {
        switch kind {
        case .walkToStation, .walkToDestination: return "figure.walk"
        case .ride: return "tram.fill"
        case .transfer: return "arrow.triangle.2.circlepath"
        case .arrive: return "flag.checkered"
        }
    }

    private func color(for step: TripStep) -> Color {
        switch step.kind {
        case .walkToStation, .walkToDestination: return .gray
        case .ride: return Color(hex: step.lineColorHex ?? "#007AFF")
        case .transfer: return .orange
        case .arrive: return .green
        }
    }
}
