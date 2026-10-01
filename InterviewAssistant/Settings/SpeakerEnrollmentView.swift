import SwiftUI
@preconcurrency import AVFoundation

struct SpeakerEnrollmentView: View {
    let onBack: () -> Void

    @State private var voices = SpeakerProfileStore.voices()
    @State private var selectedVoiceID = SpeakerProfileStore.selectedVoice()?.id
    @State private var showingAddVoice = false
    @State private var voiceToRename: StoredSpeakerVoice?
    @State private var renameDraft = ""
    @State private var showingRename = false
    @State private var voiceToDelete: StoredSpeakerVoice?
    @State private var showingDeleteConfirmation = false
    @State private var statusText = ""
    @AppStorage(AppPreferenceKey.speakerRecognitionSensitivity) private var sensitivity = 0.5
    @AppStorage(AppPreferenceKey.speakerRecognitionDebugLogging) private var debugLogging = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button(action: onBack) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.left")
                        Text(L.t("Settings"))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appText)
                    .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.t("Back to Settings"))

                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("Voices"))
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color.appText)
                    Text(L.t("Choose the voice that belongs to you during an interview."))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.appMuted)
                }

                VStack(spacing: 0) {
                    selectionRow(
                        title: L.t("None"),
                        subtitle: L.t("Turn off voice recognition"),
                        systemImage: "speaker.slash.fill",
                        isSelected: selectedVoiceID == nil
                    ) {
                        selectVoice(nil)
                    }

                    ForEach(voices) { voice in
                        Divider().overlay(Color.appBorder)
                        voiceRow(voice)
                    }

                    Divider().overlay(Color.appBorder)
                    Button {
                        showingAddVoice = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                            Text(L.t("Add Voice…"))
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Color.appPrimary)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(cardBackground(radius: 18))

                VStack(alignment: .leading, spacing: 12) {
                    Text(L.t("Recognition Sensitivity"))
                        .font(.system(size: 14, weight: .semibold))
                    Slider(value: $sensitivity, in: 0...1)
                        .tint(Color.appYellow)
                    Text(L.t("Higher sensitivity is stricter when deciding whether a speaker is you."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted)
                    #if DEBUG
                    Toggle(L.t("Speaker Debug Logging"), isOn: $debugLogging)
                        .toggleStyle(.switch)
                    #endif
                }
                .padding(18)
                .background(cardBackground(radius: 18))

                Text(L.t("Voiceprints are biometric data. They are encrypted in Keychain and never uploaded."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMuted)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appMuted)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 80)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBG.ignoresSafeArea())
        .sheet(isPresented: $showingAddVoice) {
            VoiceEnrollmentSheet { _ in refreshVoices() }
        }
        .alert(L.t("Rename Voice"), isPresented: $showingRename) {
            TextField(L.t("Voice Name"), text: $renameDraft)
            Button(L.t("Cancel"), role: .cancel) {}
            Button(L.t("Save")) { renameSelectedVoice() }
        } message: {
            Text(L.t("Enter a name that will help you recognize this voice."))
        }
        .alert(L.t("Delete Voice"), isPresented: $showingDeleteConfirmation) {
            Button(L.t("Cancel"), role: .cancel) {}
            Button(L.t("Delete"), role: .destructive) { deleteSelectedVoice() }
        } message: {
            Text(L.t("This removes the voiceprint from this device."))
        }
    }

    private func selectionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                iconTile(systemImage, tint: isSelected ? Color.appPrimary : Color.appMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func voiceRow(_ voice: StoredSpeakerVoice) -> some View {
        HStack(spacing: 0) {
            selectionRow(
                title: voice.name,
                subtitle: selectedVoiceID == voice.id ? L.t("Active") : L.t("Available"),
                systemImage: "waveform",
                isSelected: selectedVoiceID == voice.id
            ) { selectVoice(voice.id) }

            Menu {
                Button(L.t("Rename Voice"), systemImage: "pencil") {
                    voiceToRename = voice
                    renameDraft = voice.name
                    showingRename = true
                }
                Button(L.t("Delete Voice"), systemImage: "trash", role: .destructive) {
                    voiceToDelete = voice
                    showingDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.appMuted)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .padding(.trailing, 8)
        }
    }

    private func selectVoice(_ id: UUID?) {
        do {
            try SpeakerProfileStore.select(id)
            selectedVoiceID = id
            statusText = id == nil ? L.t("Voice recognition is off.") : L.t("Active voice updated.")
            Task { await SpeakerVerificationService.shared.reset() }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func renameSelectedVoice() {
        guard let voiceToRename else { return }
        do {
            try SpeakerProfileStore.rename(voiceToRename.id, to: renameDraft)
            refreshVoices()
        } catch {
            statusText = error.localizedDescription
        }
        self.voiceToRename = nil
    }

    private func deleteSelectedVoice() {
        guard let voiceToDelete else { return }
        do {
            try SpeakerProfileStore.delete(voiceToDelete.id)
            refreshVoices()
            Task { await SpeakerVerificationService.shared.reset() }
        } catch {
            statusText = error.localizedDescription
        }
        self.voiceToDelete = nil
    }

    private func refreshVoices() {
        voices = SpeakerProfileStore.voices()
        selectedVoiceID = SpeakerProfileStore.selectedVoice()?.id
    }
}

private struct VoiceEnrollmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = SpeakerEnrollmentRecorder()
    @State private var voiceName = ""
    @State private var isDownloading = false
    @State private var isProcessing = false
    @State private var isComplete = false
    @State private var statusText = ""

    let onSaved: (StoredSpeakerVoice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    recorder.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.appText)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.appSurfaceHover))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.t("Close"))
                Spacer()
            }
            .padding(18)

            ScrollView {
                VStack(spacing: 20) {
                    Text(isComplete ? L.t("Voice Added") : L.t("Add a Voice"))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.appText)

                    Text(isComplete
                         ? L.t("This voice is now selected for speaker recognition.")
                         : L.t("Speak naturally using the microphone and room you normally use for interviews."))
                        .font(.system(size: 15))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.appMuted)
                        .frame(maxWidth: 500)

                    voiceMark.padding(.vertical, 8)

                    if isComplete {
                        Button(L.t("Done")) { dismiss() }
                            .buttonStyle(AppButtonStyle(prominent: true))
                    } else {
                        setupContent
                    }

                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.system(size: 12, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.appMuted)
                            .frame(maxWidth: 520)
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 640, idealHeight: 720)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(Color.appBG.ignoresSafeArea())
        .onDisappear { recorder.stop() }
    }

    private var setupContent: some View {
        VStack(spacing: 16) {
            TextField(L.t("Voice Name"), text: $voiceName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

            VStack(alignment: .leading, spacing: 10) {
                Text(L.t("Read this passage for about 15 seconds using the same microphone and room you will use for interviews."))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appText)
                Text(enrollmentPassage)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appMuted)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
            .background(cardBackground(radius: 16))

            ProgressView(value: recorder.progress)
                .tint(Color.appPrimary)
                .frame(maxWidth: 420)

            if !recorder.errorText.isEmpty {
                Text(recorder.errorText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            if !SpeakerModelManager.isDownloaded {
                Button(isDownloading ? L.t("Downloading...") : L.t("Download Speaker Model (28.3 MB)")) {
                    downloadModel()
                }
                .buttonStyle(AppButtonStyle(prominent: true))
                .disabled(isDownloading)
            } else {
                Button(recordButtonTitle) { startEnrollment() }
                    .buttonStyle(AppButtonStyle(prominent: true))
                    .disabled(recorder.isRecording || recorder.isStarting || isProcessing)
            }
        }
    }

    private var voiceMark: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .stroke(
                        isComplete ? Color.appGreen.opacity(0.8 - Double(index) * 0.13) : Color.appPrimary.opacity(0.7 - Double(index) * 0.12),
                        lineWidth: 3
                    )
                    .frame(width: CGFloat(84 + index * 25), height: CGFloat(84 + index * 25))
            }
            Image(systemName: isComplete ? "checkmark" : "waveform")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(isComplete ? Color.appGreen : Color.appPrimary)
                .symbolEffect(.pulse, isActive: recorder.isRecording)
        }
        .frame(width: 180, height: 180)
    }

    private var recordButtonTitle: String {
        if isProcessing { return L.t("Processing…") }
        if recorder.isStarting { return L.t("Preparing Microphone…") }
        return recorder.isRecording ? L.t("Recording...") : L.t("Start Voice Setup")
    }

    private var enrollmentPassage: String {
        if AppLanguage.current == .chinese {
            return "我正在为面试助手注册自己的声音。清晰的表达来自充分准备，也来自对经历的真实总结。我会保持自然语速，使用平时面试时的音量，完整读完这段文字。"
        }
        return "I am registering my voice with InterviewAssistant. Clear answers come from careful preparation and an honest account of my experience. I will use my normal interview pace and volume while reading this passage to the end."
    }

    private func downloadModel() {
        isDownloading = true
        statusText = L.t("Downloading the on-device speaker model...")
        Task {
            do {
                _ = try await SpeakerModelManager.download()
                statusText = L.t("Speaker model downloaded and verified")
            } catch {
                statusText = error.localizedDescription
            }
            isDownloading = false
        }
    }

    private func startEnrollment() {
        statusText = L.t("Keep speaking naturally until recording finishes.")
        recorder.record(seconds: 15) { buffers in
            Task { await processEnrollment(buffers) }
        }
    }

    @MainActor
    private func processEnrollment(_ buffers: [SendablePCMBuffer]) async {
        isProcessing = true
        do {
            let samples = try await Task.detached { try SpeakerAudioConverter.samples16kMono(from: buffers) }.value
            let segmentLength = samples.count / 4
            guard segmentLength >= 16_000 else { throw SpeakerVerifierError.invalidEmbedding }
            let segments = (0..<4).map { index -> [Float] in
                let start = index * segmentLength
                let end = index == 3 ? samples.count : start + segmentLength
                return Array(samples[start..<end])
            }
            let rms = sqrt(samples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(max(samples.count, 1))) * Float(Int16.max)
            let verifier = try await Task.detached {
                let extractor = try SherpaSpeakerEmbeddingExtractor(modelURL: SpeakerModelManager.modelURL)
                return SpeakerVerifier(extractor: extractor, profile: nil)
            }.value
            let profile = try await verifier.enroll(
                samples: segments,
                meanRMS: rms,
                modelID: SpeakerModelManager.modelID,
                modelVersion: SpeakerModelManager.modelVersion
            )
            let voice = try SpeakerProfileStore.add(profile, named: voiceName)
            await SpeakerVerificationService.shared.reset()
            onSaved(voice)
            statusText = L.t("Voice setup is complete.")
            isComplete = true
        } catch {
            statusText = error.localizedDescription
        }
        isProcessing = false
    }
}

@MainActor
final class SpeakerEnrollmentRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var progress = 0.0
    @Published var errorText = ""

    private let engine = AVAudioEngine()
    private let audioQueue = DispatchQueue(
        label: "InterviewAssistant.SpeakerEnrollment.audio",
        qos: .userInitiated
    )
    private var buffers: [SendablePCMBuffer] = []
    private var progressTask: Task<Void, Never>?
    private var generation = 0

    func record(seconds: Double, completion: @escaping ([SendablePCMBuffer]) -> Void) {
        guard !isRecording, !isStarting else { return }
        generation += 1
        let currentGeneration = generation
        isStarting = true
        errorText = ""
        Task { [self] in
            guard await VolcanoASREngine.requestMicrophonePermission() else {
                guard generation == currentGeneration else { return }
                isStarting = false
                errorText = L.t("Microphone permission required")
                return
            }

            #if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                guard generation == currentGeneration else { return }
                isStarting = false
                errorText = error.localizedDescription
                return
            }
            #endif

            buffers = []
            progress = 0
            let startResult: Result<Void, Error> = await withCheckedContinuation { [audioQueue, engine, self] continuation in
                audioQueue.async {
                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.channelCount > 0, format.sampleRate > 0 else {
                        continuation.resume(returning: .failure(Self.noAudioInputError()))
                        return
                    }
                    input.removeTap(onBus: 0)
                    input.installTap(
                        onBus: 0,
                        bufferSize: AVAudioFrameCount(max(1, format.sampleRate / 10)),
                        format: format,
                        block: Self.makeTapBlock(recorder: self, generation: currentGeneration)
                    )
                    engine.prepare()
                    do {
                        try engine.start()
                        continuation.resume(returning: .success(()))
                    } catch {
                        input.removeTap(onBus: 0)
                        engine.stop()
                        continuation.resume(returning: .failure(error))
                    }
                }
            }

            guard generation == currentGeneration else {
                stopEngine()
                return
            }
            isStarting = false
            guard case .success = startResult else {
                if case .failure(let error) = startResult {
                    errorText = error.localizedDescription
                }
                return
            }
            isRecording = true
            progressTask = Task { @MainActor [weak self] in
                let steps = max(1, Int(seconds * 10))
                for step in 1...steps {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    self?.progress = Double(step) / Double(steps)
                }
                guard let self, self.generation == currentGeneration else { return }
                self.stopEngine()
                self.isRecording = false
                completion(self.buffers)
            }
        }
    }

    func stop() {
        generation += 1
        progressTask?.cancel()
        progressTask = nil
        stopEngine()
        isStarting = false
        isRecording = false
        progress = 0
        buffers = []
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func stopEngine() {
        let engineRef = engine
        audioQueue.async {
            engineRef.inputNode.removeTap(onBus: 0)
            engineRef.stop()
            engineRef.reset()
        }
    }

    nonisolated private static func makeTapBlock(
        recorder: SpeakerEnrollmentRecorder,
        generation: Int
    ) -> AVAudioNodeTapBlock {
        { [weak recorder] buffer, _ in
            let copy = SendablePCMBuffer(buffer.copyPCM())
            Task { @MainActor [weak recorder] in
                guard let recorder, recorder.generation == generation else { return }
                recorder.buffers.append(copy)
            }
        }
    }

    nonisolated private static func noAudioInputError() -> Error {
        NSError(
            domain: "InterviewAssistant.Audio",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: L.t("The current microphone has no available audio input. Check the input device in Zoom/Teams and System Settings.")
            ]
        )
    }
}
