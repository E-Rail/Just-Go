import SwiftUI

/// The two questions a finished trip may have earned, asked once and kept on the device.
///
/// Stage 1 of `docs/rider-reports-and-photos.md`: no backend, no upload, no account. The rider
/// answers for themselves, and the answers change nothing except their own future trips.
///
/// **A question is only asked when the app genuinely does not know.** Asking about something
/// already in an official feed teaches riders their answers do not matter, which is the fastest
/// way to make every later answer worthless. That rule is enforced in `questions(for:)` below, not
/// left to the caller — and it is why a trip with good data asks nothing at all and this sheet
/// never appears.
///
/// This never asks how long a change took. `TransferPacePrompt` already asks that during the
/// change itself, which is the one moment the rider knows the answer.
struct PostTripQuestionsSheet: View {
    let route: Route
    let cityID: String
    var onFinish: () -> Void

    @Environment(DIContainer.self) private var container
    @State private var index = 0

    /// At most two, because a third is a form and nobody fills in a form after a journey.
    static func questions(
        for route: Route,
        cityID: String,
        answered: (RiderAnswerKey) -> Bool
    ) -> [PendingQuestion] {
        guard !cityID.isEmpty else { return [] }
        var pending: [PendingQuestion] = []

        // Only when the trip could not confirm step-free access. `.confirmed` means an official
        // source said so and the rider has nothing to add; `.barrierDetected` means the app
        // already told them it was not step-free, and asking then is asking them to re-report
        // what it just said.
        if route.stepFreeAssessment == .likely || route.stepFreeAssessment == .unknown,
           let boarding = route.stationGuidance.first(where: { $0.role == .boarding }) {
            let key = RiderAnswerKey(cityID: cityID, stationID: boarding.stationID, question: .liftToPlatform)
            if !answered(key) {
                pending.append(PendingQuestion(key: key, stationName: boarding.stationName, detail: nil))
            }
        }

        // Only when the arrival exit was a guess. `RouteStationGuidance.confidence` records
        // whether the exit came from an operator or was picked by straight-line distance, and
        // until now nothing read it.
        if let arrival = route.stationGuidance.first(where: { $0.role == .arrival }),
           arrival.confidence != .official,
           let exit = arrival.exit {
            let key = RiderAnswerKey(cityID: cityID, stationID: arrival.stationID, question: .exitSide)
            if !answered(key) {
                pending.append(PendingQuestion(key: key, stationName: arrival.stationName, detail: exit.name))
            }
        }

        return Array(pending.prefix(2))
    }

    struct PendingQuestion: Identifiable, Equatable {
        let key: RiderAnswerKey
        let stationName: String
        let detail: String?

        var id: String { key.storageID }
    }

    /// Snapshotted once, not recomputed. Recording an answer makes `hasAnswered` true for it, so a
    /// computed list would shrink under the cursor and the second question would never be shown.
    @State private var pending: [PendingQuestion] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metrics.l) {
                if let question = pending.indices.contains(index) ? pending[index] : nil {
                    Text(prompt(for: question))
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: Metrics.s) {
                        ForEach(options(for: question.key.question), id: \.self) { answer in
                            Button {
                                record(answer, for: question)
                            } label: {
                                Text(title(for: answer))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .frame(minHeight: Metrics.minimumTapTarget)
                        }
                    }

                    Text(AppLocalization.text(
                        english: "Stays on this phone. It is not sent anywhere.",
                        simplified: "只保存在本机，不会发送到任何地方。",
                        traditional: "只儲存在本機，不會傳送到任何地方。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Metrics.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.text(
                english: "One quick thing",
                simplified: "问一个小问题",
                traditional: "問一個小問題"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Skipping is a first-class answer. A rider who does not want to be asked must
                    // be able to leave without giving one, or the next answer is noise.
                    Button(AppLocalization.text(english: "Skip", simplified: "跳过", traditional: "跳過")) {
                        onFinish()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            pending = Self.questions(for: route, cityID: cityID) {
                container.riderAnswerService.hasAnswered($0)
            }
            if pending.isEmpty { onFinish() }
        }
    }

    private func prompt(for question: PendingQuestion) -> String {
        switch question.key.question {
        case .liftToPlatform:
            return AppLocalization.text(
                english: "Was there a lift from the concourse to the platform at \(question.stationName)?",
                simplified: "在\(question.stationName)，站厅到站台有直梯吗？",
                traditional: "在\(question.stationName)，車站大堂到月台有電梯嗎？"
            )
        case .exitSide:
            let exit = question.detail ?? ""
            return AppLocalization.text(
                english: "Did \(exit) at \(question.stationName) come out on the right side?",
                simplified: "\(question.stationName)的\(exit)出来的方向对吗？",
                traditional: "\(question.stationName)的\(exit)出來的方向對嗎？"
            )
        }
    }

    private func options(for question: RiderQuestion) -> [RiderAnswer] {
        switch question {
        case .liftToPlatform: return [.yes, .no, .didNotLook]
        case .exitSide: return [.yes, .no]
        }
    }

    private func title(for answer: RiderAnswer) -> String {
        switch answer {
        case .yes:
            return AppLocalization.text(english: "Yes", simplified: "有", traditional: "有")
        case .no:
            return AppLocalization.text(english: "No", simplified: "没有", traditional: "沒有")
        case .didNotLook:
            return AppLocalization.text(english: "I didn't look", simplified: "没注意", traditional: "沒注意")
        }
    }

    private func record(_ answer: RiderAnswer, for question: PendingQuestion) {
        container.riderAnswerService.record(
            answer,
            for: question.key,
            stationName: question.stationName,
            detail: question.detail
        )
        if index + 1 < pending.count {
            index += 1
        } else {
            onFinish()
        }
    }
}
