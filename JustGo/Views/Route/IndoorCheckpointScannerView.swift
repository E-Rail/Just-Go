import AVFoundation
import SwiftUI
import UIKit

private enum IndoorCheckpointScannerPhase: Equatable {
    case idle
    case requestingPermission
    case scanning
    case result(StationSignRecognitionOutcome)
    case manual(IndoorCheckpointManualReason)
}

private enum IndoorCheckpointManualReason: Equatable {
    case voiceOver
    case noMatch
    case permissionDenied
    case cameraUnavailable
    case userRequested
}

@Observable
private final class IndoorCheckpointScannerViewModel: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var phase: IndoorCheckpointScannerPhase = .idle

    private let candidates: [StationSignCandidate]
    private let recognizer = StationSignRecognizer()
    private let sessionQueue = DispatchQueue(label: "com.justgo.sign-scanner.session")
    private let visionQueue = DispatchQueue(label: "com.justgo.sign-scanner.vision")
    private let stateLock = NSLock()
    private var acceptsFrames = false
    private var isConfigured = false
    private var lastProcessedAt = Date.distantPast
    private var stabilizer = StationSignRecognitionStabilizer()

    init(candidates: [StationSignCandidate]) {
        self.candidates = candidates
        super.init()
    }

    /// This is called only after the rider has tapped Scan Sign in the indoor guidance view.
    /// Merely opening LiveGo or reaching a transfer never touches camera authorization.
    func beginAfterScanSignTapped(voiceOverRunning: Bool) {
        guard phase == .idle else { return }
        guard !voiceOverRunning else {
            useManualSelection(.voiceOver)
            return
        }
        phase = .requestingPermission

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.phase == .requestingPermission else { return }
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.useManualSelection(.permissionDenied)
                    }
                }
            }
        case .denied, .restricted:
            useManualSelection(.permissionDenied)
        @unknown default:
            useManualSelection(.cameraUnavailable)
        }
    }

    func scanAgain() {
        phase = .scanning
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.stabilizer.reset()
            self.lastProcessedAt = .distantPast
            self.setAcceptsFrames(true)
            self.sessionQueue.async { [weak self] in
                guard let self, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }
    }

    func stop() {
        setAcceptsFrames(false)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func useManualSelection(_ reason: IndoorCheckpointManualReason) {
        stop()
        phase = .manual(reason)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard shouldAcceptFrame() else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProcessedAt) >= 0.35 else { return }
        lastProcessedAt = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let outcome = recognizer.recognize(
            pixelBuffer: pixelBuffer,
            orientation: Self.imageOrientation,
            candidates: candidates
        )
        guard let stableOutcome = stabilizer.ingest(outcome) else { return }

        setAcceptsFrames(false)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase == .scanning else { return }
            if stableOutcome == .none {
                self.useManualSelection(.noMatch)
            } else {
                self.phase = .result(stableOutcome)
                self.stop()
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let configured = self.isConfigured || self.configureSession()
            DispatchQueue.main.async {
                guard self.phase == .requestingPermission else { return }
                guard configured else {
                    self.useManualSelection(.cameraUnavailable)
                    return
                }
                self.scanAgain()
            }
        }
    }

    private func configureSession() -> Bool {
        guard !isConfigured,
              let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return false }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(output) else { return false }

        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: visionQueue)
        session.commitConfiguration()
        isConfigured = true
        return true
    }

    private func shouldAcceptFrame() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acceptsFrames
    }

    private func setAcceptsFrames(_ accepts: Bool) {
        stateLock.lock()
        acceptsFrames = accepts
        stateLock.unlock()
    }

    private static var imageOrientation: CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }
}

struct IndoorCheckpointScannerView: View {
    let stationName: String
    let routeContext: String?
    let candidates: [StationSignCandidate]
    let expectedNodeID: String?
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: IndoorCheckpointScannerViewModel
    @State private var selectedCandidateID: String?
    @State private var didConfirm = false
    @AccessibilityFocusState private var manualHeadingFocused: Bool

    init(
        stationName: String,
        routeContext: String?,
        candidates: [StationSignCandidate],
        expectedNodeID: String?,
        onConfirm: @escaping (String) -> Void
    ) {
        self.stationName = stationName
        self.routeContext = routeContext
        self.candidates = candidates
        self.expectedNodeID = expectedNodeID
        self.onConfirm = onConfirm
        _viewModel = State(initialValue: IndoorCheckpointScannerViewModel(candidates: candidates))
        _selectedCandidateID = State(initialValue: candidates.contains { $0.id == expectedNodeID }
            ? expectedNodeID
            : candidates.first?.id)
    }

    var body: some View {
        ZStack {
            scannerBackground

            VStack(spacing: 16) {
                scannerHeader
                Spacer(minLength: 16)
                phasePanel
            }
            .safeAreaPadding()
        }
        .background(Color.black)
        .task {
            viewModel.beginAfterScanSignTapped(voiceOverRunning: UIAccessibility.isVoiceOverRunning)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            guard UIAccessibility.isVoiceOverRunning else { return }
            presentManualSelection(.voiceOver)
        }
        .onChange(of: viewModel.phase) { _, phase in
            guard case .manual = phase else { return }
            prepareManualSelection()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    @ViewBuilder
    private var scannerBackground: some View {
        if viewModel.phase == .scanning {
            IndoorCameraPreview(session: viewModel.session)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            Rectangle()
                .fill(.clear)
                .border(.white.opacity(0.8), width: 2)
                .padding(.horizontal, 38)
                .padding(.vertical, 150)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            Color.appBackground
                .ignoresSafeArea()
        }
    }

    private var scannerHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scannerTitle)
                    .font(.headline)
                Text(stationName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel(AppLocalization.localized("Close Scanner"))
        }
        .padding(.leading, 12)
    }

    @ViewBuilder
    private var phasePanel: some View {
        switch viewModel.phase {
        case .idle, .requestingPermission:
            statusPanel(
                icon: "camera",
                title: AppLocalization.localized("Requesting Camera Access"),
                detail: AppLocalization.localized("Text is recognized on this device and is not saved."),
                showsProgress: true
            )
        case .scanning:
            statusPanel(
                icon: "viewfinder",
                title: AppLocalization.localized("Point the camera at a station sign"),
                detail: routeContext ?? AppLocalization.localized("Looking for a matching checkpoint..."),
                showsProgress: true
            )
        case .result(let outcome):
            resultPanel(outcome)
        case .manual(let reason):
            manualPanel(reason)
        }
    }

    private var scannerTitle: String {
        if case .manual = viewModel.phase {
            return AppLocalization.localized("Confirm Checkpoint")
        }
        return AppLocalization.localized("Scan Sign")
    }

    private func statusPanel(icon: String, title: String, detail: String, showsProgress: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsProgress {
                ProgressView()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resultPanel(_ outcome: StationSignRecognitionOutcome) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                switch outcome {
                case .unique(let candidate):
                    resultHeading(
                        icon: "checkmark.viewfinder",
                        title: AppLocalization.localized("Checkpoint Matched"),
                        detail: candidate.title
                    )
                    confirmButton(candidate.id)
                    chooseAnotherCheckpointButton
                case .ambiguous(let matches):
                    let selectedMatchID = selectedCandidateID.flatMap { selectedID in
                        matches.contains { $0.id == selectedID } ? selectedID : nil
                    }
                    resultHeading(
                        icon: "signpost.right.and.left",
                        title: AppLocalization.localized("Multiple Checkpoints Matched"),
                        detail: AppLocalization.localized("Select the checkpoint shown on the sign.")
                    )
                    ForEach(matches) { candidate in
                        candidateButton(candidate)
                    }
                    Button {
                        guard let selectedMatchID else { return }
                        confirm(selectedMatchID)
                    } label: {
                        Label(AppLocalization.localized("Confirm Checkpoint"), systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selectedMatchID == nil)
                    chooseAnotherCheckpointButton
                case .none:
                    resultHeading(
                        icon: "text.viewfinder",
                        title: AppLocalization.localized("No Matching Sign Found"),
                        detail: AppLocalization.localized("Try scanning again or confirm your checkpoint manually.")
                    )
                    manualCheckpointPicker
                }

                scanAgainButton
            }
            .padding(20)
        }
        .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 520 : 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func manualPanel(_ reason: IndoorCheckpointManualReason) -> some View {
        let presentation = manualPresentation(for: reason)
        return ScrollView {
            VStack(spacing: 14) {
                resultHeading(
                    icon: presentation.icon,
                    title: presentation.title,
                    detail: presentation.detail
                )
                .accessibilityFocused($manualHeadingFocused)

                manualCheckpointPicker

                if presentation.canScanAgain {
                    scanAgainButton
                }
            }
            .padding(20)
        }
        .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 620 : 500)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func manualPresentation(
        for reason: IndoorCheckpointManualReason
    ) -> (icon: String, title: String, detail: String, canScanAgain: Bool) {
        switch reason {
        case .voiceOver:
            return (
                "hand.tap",
                AppLocalization.localized("Manual Checkpoint Confirmation"),
                AppLocalization.localized("VoiceOver uses manual checkpoint confirmation before the camera starts."),
                false
            )
        case .noMatch:
            return (
                "text.viewfinder",
                AppLocalization.localized("No Matching Sign Found"),
                AppLocalization.localized("Try scanning again or choose your checkpoint manually."),
                true
            )
        case .permissionDenied:
            return (
                "camera.fill",
                AppLocalization.localized("Camera Access Needed"),
                AppLocalization.localized("Camera access is unavailable. Continue with the manual checkpoint controls."),
                false
            )
        case .cameraUnavailable:
            return (
                "camera.slash",
                AppLocalization.localized("Camera Unavailable"),
                AppLocalization.localized("Camera access is unavailable. Continue with the manual checkpoint controls."),
                false
            )
        case .userRequested:
            return (
                "signpost.right.and.left",
                AppLocalization.localized("Choose a Checkpoint"),
                AppLocalization.localized("Select the station sign or platform that matches where you are."),
                true
            )
        }
    }

    private func resultHeading(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private func candidateButton(_ candidate: StationSignCandidate) -> some View {
        let isSelected = selectedCandidateID == candidate.id
        return Button {
            selectedCandidateID = candidate.id
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .multilineTextAlignment(.leading)
                    if candidate.id == expectedNodeID {
                        Text(AppLocalization.localized("Suggested"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func confirmButton(_ candidateID: String) -> some View {
        Button {
            confirm(candidateID)
        } label: {
            Label(AppLocalization.localized("Confirm Checkpoint"), systemImage: "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var manualCheckpointPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.localized("Choose a Checkpoint"))
                .font(.subheadline)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(AppLocalization.localized("Select the station sign or platform that matches where you are."))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(candidates) { candidate in
                candidateButton(candidate)
            }

            Button {
                guard let selectedCandidateID else { return }
                confirm(selectedCandidateID)
            } label: {
                Label(AppLocalization.localized("Confirm Checkpoint"), systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedCandidateID == nil)
        }
    }

    private var chooseAnotherCheckpointButton: some View {
        Button {
            presentManualSelection(.userRequested)
        } label: {
            Label(AppLocalization.localized("Choose Another Checkpoint"), systemImage: "signpost.right.and.left")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var scanAgainButton: some View {
        Button {
            guard !UIAccessibility.isVoiceOverRunning else {
                presentManualSelection(.voiceOver)
                return
            }
            selectedCandidateID = recommendedCandidateID
            manualHeadingFocused = false
            viewModel.scanAgain()
        } label: {
            Label(AppLocalization.localized("Scan Again"), systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var recommendedCandidateID: String? {
        candidates.contains { $0.id == expectedNodeID } ? expectedNodeID : candidates.first?.id
    }

    private func presentManualSelection(_ reason: IndoorCheckpointManualReason) {
        selectedCandidateID = recommendedCandidateID
        viewModel.useManualSelection(reason)
    }

    private func prepareManualSelection() {
        if !candidates.contains(where: { $0.id == selectedCandidateID }) {
            selectedCandidateID = recommendedCandidateID
        }
        Task { @MainActor in
            await Task.yield()
            manualHeadingFocused = true
        }
    }

    private func confirm(_ nodeID: String) {
        guard !didConfirm else { return }
        didConfirm = true
        viewModel.stop()
        onConfirm(nodeID)
    }
}

private struct IndoorCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
