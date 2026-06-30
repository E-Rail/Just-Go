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
    @Environment(DIContainer.self) private var container
    @AppStorage("arrivalAlertEnabled") private var arrivalAlertEnabled = true
    @AppStorage("arrivalAlertLeadMinutes") private var arrivalAlertLeadMinutes = 2
    @State private var showGetOffBanner = false
    @State private var alertTask: Task<Void, Never>?
    @State private var scheduledStationKey: String?

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
            .overlay(alignment: .top) {
                if showGetOffBanner {
                    getOffBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle(AppLocalization.text(english: "Go", simplified: "出发", traditional: "出發"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            refreshArrivalAlert()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            cancelArrivalAlert()
        }
        .onChange(of: viewModel.currentIndex) { _, _ in refreshArrivalAlert() }
        .onChange(of: arrivalAlertEnabled) { _, _ in refreshArrivalAlert() }
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
                    .foregroundStyle(Color.accentColor)
            }

            if step.kind == .ride, let exit = step.exitHint, !exit.isEmpty {
                Label(
                    AppLocalization.text(english: "Get off toward \(exit)", simplified: "下车走向\(exit)", traditional: "下車走向\(exit)"),
                    systemImage: "arrow.up.forward.circle.fill"
                )
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            }

            if step.kind == .ride {
                VStack(spacing: 6) {
                    Toggle(isOn: $arrivalAlertEnabled) {
                        Label(
                            AppLocalization.text(english: "Alert before getting off", simplified: "下车前提醒我", traditional: "下車前提醒我"),
                            systemImage: "bell.badge"
                        )
                        .font(.subheadline)
                    }
                    .tint(Color.accentColor)
                    Text(AppLocalization.text(
                        english: "Estimated from route time, not a live train position.",
                        simplified: "根据线路时间估算，非实时列车位置。",
                        traditional: "根據路線時間估算，非實時列車位置。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
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
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
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

    private var getOffBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.text(english: "Get ready to get off", simplified: "准备下车", traditional: "準備下車"))
                    .font(.headline)
                if let to = viewModel.currentStep?.toStationName {
                    Text(to)
                        .font(.subheadline)
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal)
    }

    /// (Re)arms the estimated "get off" alert for the current step. Cancels any prior alert first,
    /// then — only for a ride step with the toggle on — schedules a hands-free local notification
    /// and an in-app timer that buzzes + shows a banner if the app is still foreground at fire time.
    @MainActor
    private func refreshArrivalAlert() {
        cancelArrivalAlert()
        guard arrivalAlertEnabled,
              let step = viewModel.currentStep,
              step.kind == .ride else { return }

        let key = "\(step.id)"
        let leadSeconds = TimeInterval(arrivalAlertLeadMinutes * 60)
        let fireInterval = max(0, step.duration - leadSeconds)
        let fireDate = Date().addingTimeInterval(fireInterval)
        scheduledStationKey = key

        let stationName = step.toStationName ?? ""
        let exitHint = step.exitHint
        Task {
            if await container.tripReminderService.requestAuthorization() {
                await container.tripReminderService.scheduleArrivalReminder(
                    stationID: key,
                    stationName: stationName,
                    exitHint: exitHint,
                    fireDate: fireDate
                )
            }
        }

        alertTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(fireInterval))
            guard !Task.isCancelled, viewModel.currentStep?.kind == .ride else { return }
            Haptics.notify(.warning)
            withAnimation { showGetOffBanner = true }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled {
                withAnimation { showGetOffBanner = false }
            }
        }
    }

    @MainActor
    private func cancelArrivalAlert() {
        alertTask?.cancel()
        alertTask = nil
        showGetOffBanner = false
        if let key = scheduledStationKey {
            container.tripReminderService.cancelArrivalReminder(stationID: key)
            scheduledStationKey = nil
        }
    }
}

/// Thin haptic-feedback helper. The app had no haptics before; this is the single entry point.
enum Haptics {
    @MainActor
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
