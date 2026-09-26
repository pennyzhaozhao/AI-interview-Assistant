import Foundation
@preconcurrency import AVFoundation
import Accelerate
import Speech
import Observation

enum AudioSource: String, CaseIterable, Identifiable {
    case microphone
    case system

    var id: String { rawValue }
}

@MainActor
@Observable
final class SpeechEngine {
    var statusText = ""
    var isListening = false
    var languageCode = "en-US"
    var audioSource: AudioSource = .microphone
    var audioLevel: Double = 0
    var isVoiceDetected = false
    #if os(iOS)
    var silenceDurationSeconds: Double = 1.5
    #else
    var silenceDurationSeconds: Double = 1.2
    #endif
    var onRecognizedText: ((String) -> Void)?
    var canForceTrigger: Bool { !speechBuffer.isEmpty }

    nonisolated(unsafe) private let engine = AVAudioEngine()
    private let audioProcessor = SpeechAudioProcessor()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechBuffer = [AVAudioPCMBuffer]()
    private var isSpeaking = false
    private var silenceSeconds = 0.0
    private var speechSeconds = 0.0
    private var totalSeconds = 0.0
    private var consecutiveVoiceSeconds = 0.0
    private var noiseFloorRMS: Float = 0
    private var peakSpeechRMS: Float = 0
    private var processingGeneration = 0

    #if os(macOS)
    nonisolated(unsafe) private var systemAudioCapture: SystemAudioCapture?
    #endif

    #if os(iOS)
    private let rmsThreshold: Float = 900
    #else
    private let rmsThreshold: Float = 200
    #endif

    /// Minimum fraction of energy in the 300–3400 Hz human voice band.
    /// Values below this indicate noise (fans, AC, keyboard) rather than speech.
    private let minVoiceRatio: Float = 0.28

    private var effectiveRMSThreshold: Float {
        max(rmsThreshold, noiseFloorRMS + max(350, noiseFloorRMS * 1.2))
    }
    #if os(iOS)
    private let minSpeechSeconds = 0.8
    private let minSegmentSecondsBeforeRecognition = 1.5
    private var effectiveSilenceDurationSeconds: Double { max(silenceDurationSeconds, 1.5) }
    /// On iOS, echo/reverb can sustain voice-like readings for ~0.5 s.
    /// Require 0.8 s of consecutive voice to prove speech truly resumed
    /// so that trailing echo does NOT reset the silence counter.
    private let resumeSpeechSeconds = 0.8
    /// Absolute fallback: if total non-voice time while isSpeaking exceeds this,
    /// force recognition even when brief spikes keep resetting silenceSeconds.
    private let maxAbsoluteSilenceSeconds = 5.0
    /// Fraction of peak RMS below which trailing sound is treated as noise, not speech.
    /// Lower on iOS because the mic picks up more room echo after loud speech.
    private let trailingNoiseFactor: Float = 0.10
    #else
    private let minSpeechSeconds = 0.25
    private let minSegmentSecondsBeforeRecognition = 0.25
    private var effectiveSilenceDurationSeconds: Double {
        max(silenceDurationSeconds, 0.8)
    }
    private let resumeSpeechSeconds = 0.35
    private let maxAbsoluteSilenceSeconds = 10.0
    private let trailingNoiseFactor: Float = 0.18
    #endif
    private let maxSegmentSeconds = 30.0

    private var idleStatus: String {
        audioSource == .system ? L.t("🔊 Listening to system audio...") : L.t("🎙 Listening...")
    }

    init() {
        audioProcessor.onProcessedBuffer = { [weak self] copied, rms, voiceRatio, generation in
            DispatchQueue.main.async {
                guard let self, self.processingGeneration == generation, self.isListening else { return }
                self.handle(buffer: copied.buffer, rms: rms, voiceRatio: voiceRatio)
            }
        }
    }

    nonisolated func requestPermissions() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { auth in
                cont.resume(returning: auth == .authorized)
            }
        }
        #if os(iOS)
        let micOK = await AVAudioApplication.requestRecordPermission()
        #else
        let currentMicStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            switch currentMicStatus {
            case .authorized:
                cont.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            default:
                cont.resume(returning: false)
            }
        }
        #endif
        return speechOK && micOK
    }

    func start() async -> Bool {
        guard !isListening else { return true }
        guard await requestPermissions() else {
            statusText = L.t("Microphone and speech-recognition permission required")
            return false
        }

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        resetVAD()
        processingGeneration += 1
        let generation = processingGeneration
        let processor = self.audioProcessor

        // ── System audio path (macOS only) ──────────────────────────────────
        #if os(macOS)
        if audioSource == .system {
            let capture = SystemAudioCapture()
            capture.onBuffer = { [weak processor] buffer in
                processor?.process(buffer: buffer, generation: generation)
            }
            systemAudioCapture = capture
            do {
                try await capture.start()
                isListening = true
                statusText = L.t("🔊 Listening to system audio...")
                return true
            } catch {
                systemAudioCapture = nil
                statusText = String(format: L.t("❌ Unable to capture system audio: %@"), error.localizedDescription)
                return false
            }
        }
        #else
        if audioSource == .system {
            statusText = L.t("System audio is available only on macOS")
            return false
        }
        #endif

        // ── Microphone path ─────────────────────────────────────────────────
        // AVAudioEngine must not start on the main thread (internal mServiceQueue assertion).
        let startResult: Result<Void, Error> = await withCheckedContinuation { [engine] cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.removeTap(onBus: 0)
                let tap = SpeechEngine.makeTapBlock(processor: processor, generation: generation)
                input.installTap(onBus: 0,
                                 bufferSize: AVAudioFrameCount(format.sampleRate / 10),
                                 format: format,
                                 block: tap)
                engine.prepare()
                do {
                    try engine.start()
                    cont.resume(returning: .success(()))
                } catch {
                    input.removeTap(onBus: 0)
                    cont.resume(returning: .failure(error))
                }
            }
        }
        switch startResult {
        case .success:
            isListening = true
            statusText = L.t("🎙 Listening...")
            return true
        case .failure(let error):
            statusText = "❌ \(error.localizedDescription)"
            return false
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        processingGeneration += 1
        statusText = ""
        recognitionTask?.cancel()
        recognitionTask = nil
        resetVAD()

        #if os(macOS)
        if let capture = systemAudioCapture {
            systemAudioCapture = nil
            Task { await capture.stop() }
            return
        }
        #endif

        let engineRef = engine
        DispatchQueue.global(qos: .userInitiated).async {
            engineRef.inputNode.removeTap(onBus: 0)
            engineRef.stop()
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func forceTrigger() {
        guard !speechBuffer.isEmpty else { return }
        triggerRecognition()
    }

    /// Nonisolated + static so the closure carries no @MainActor isolation,
    /// avoiding _swift_task_checkIsolatedSwift crashes on AVFAudio's internal queue.
    nonisolated private static func makeTapBlock(
        processor: SpeechAudioProcessor,
        generation: Int
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in processor.process(buffer: buffer, generation: generation) }
    }

    // MARK: - VAD handler

    private func handle(buffer: AVAudioPCMBuffer, rms: Float, voiceRatio: Float) {
        // Both conditions must be true to count as speech:
        //   • Energy above noise floor (rmsThreshold)
        //   • Significant energy in the human voice frequency band (minVoiceRatio)
        let duration = buffer.durationSeconds
        let threshold = effectiveRMSThreshold
        let aboveVoiceBand = voiceRatio > minVoiceRatio
        let aboveNoiseFloor = rms > threshold
        let aboveTrailingNoise = !isSpeaking || peakSpeechRMS == 0 || rms >= max(threshold, peakSpeechRMS * trailingNoiseFactor)
        let isVoice = aboveNoiseFloor && aboveVoiceBand && aboveTrailingNoise
        isVoiceDetected = isVoice
        if isVoice {
            let normalized = min(1, max(0.12, Double(rms / max(threshold * 6, 1))))
            audioLevel = (audioLevel * 0.35) + (normalized * 0.65)
        } else {
            audioLevel = 0
        }

        if isVoice {
            consecutiveVoiceSeconds += duration
            if !isSpeaking {
                isSpeaking = true
                silenceSeconds = 0
                peakSpeechRMS = rms
                statusText = L.t("🔴 Recording...")
            } else if consecutiveVoiceSeconds >= resumeSpeechSeconds {
                // Only reset silence window after sustained voice.
                // This prevents a single echo / cough / keyboard click from resetting
                // the silence counter and keeping the app stuck in recording mode.
                silenceSeconds = 0
            } else {
                // Treat brief voice-like spikes as part of the silence window.
                // On iPhone, room noise / speaker bleed can look like speech for
                // one or two chunks; without this, Recording can get stuck.
                silenceSeconds += duration
            }
            peakSpeechRMS = max(peakSpeechRMS, rms)
            speechBuffer.append(buffer.copyPCM())
            speechSeconds += duration
            totalSeconds += duration
            if shouldEndCurrentUtterance() { triggerRecognition() }
            if totalSeconds >= maxSegmentSeconds { triggerRecognition() }
        } else {
            learnNoiseFloor(from: rms)
            consecutiveVoiceSeconds = 0
            if isSpeaking {
                speechBuffer.append(buffer.copyPCM())
                silenceSeconds += duration
                totalSeconds += duration
                let absoluteSilence = totalSeconds - speechSeconds
                if shouldEndCurrentUtterance() || absoluteSilence >= maxAbsoluteSilenceSeconds {
                    triggerRecognition()
                }
            } else {
                if isListening { statusText = idleStatus }
            }
        }
    }

    private func shouldEndCurrentUtterance() -> Bool {
        silenceSeconds >= effectiveSilenceDurationSeconds
            && speechSeconds >= minSpeechSeconds
            && totalSeconds >= minSegmentSecondsBeforeRecognition
    }

    private func learnNoiseFloor(from rms: Float) {
        guard rms.isFinite, rms > 0 else { return }
        if noiseFloorRMS == 0 {
            noiseFloorRMS = rms
        } else {
            noiseFloorRMS = (noiseFloorRMS * 0.95) + (rms * 0.05)
        }
    }

    private func triggerRecognition() {
        guard !speechBuffer.isEmpty else { resetVAD(); return }
        let buffers = speechBuffer
        let lang = languageCode
        resetVAD()
        statusText = L.t("🔍 Transcribing...")
        Task { @MainActor in
            let text = await Self.recognize(buffers: buffers, languageCode: lang)
            if let text, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 1 {
                self.statusText = "💬 \(String(text.prefix(30)))..."
                self.onRecognizedText?(text)
            } else {
                self.statusText = self.isListening ? self.idleStatus : ""
            }
        }
    }

    private func resetVAD() {
        speechBuffer = []
        isSpeaking = false
        silenceSeconds = 0
        speechSeconds = 0
        totalSeconds = 0
        consecutiveVoiceSeconds = 0
        peakSpeechRMS = 0
        audioLevel = 0
        isVoiceDetected = false
    }

    @MainActor
    private static func recognize(buffers: [AVAudioPCMBuffer], languageCode: String) async -> String? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode)),
              recognizer.isAvailable else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = [
            "自我介绍", "项目经历", "项目挑战", "系统设计", "算法", "复杂度", "数据库", "缓存",
            "用户研究", "信息架构", "设计系统", "产品经理", "薪资架构", "公司业务",
            "COSMO Japan", "Smilax Global", "CompletableFuture", "MySQL", "Redis",
            "Tell me about yourself", "project challenge", "system design", "user research"
        ]
        for buffer in buffers { request.append(buffer) }
        request.endAudio()
        return await withCheckedContinuation { cont in
            var finished = false
            var bestPartial: String?
            recognizer.recognitionTask(with: request) { result, error in
                DispatchQueue.main.async {
                    guard !finished else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            bestPartial = text
                        }
                    }
                    // Wait for isFinal on both platforms — endAudio() guarantees the
                    // recognizer will finalize. Fall back to bestPartial on error.
                    if let result, result.isFinal {
                        finished = true
                        cont.resume(returning: result.bestTranscription.formattedString)
                    } else if error != nil {
                        finished = true
                        cont.resume(returning: bestPartial)
                    }
                }
            }
        }
    }

}

// MARK: - SpeechAudioProcessor

final class SpeechAudioProcessor: @unchecked Sendable {
    /// (buffer, rmsScaled, voiceFrequencyRatio, generation)
    var onProcessedBuffer: (@Sendable (SendablePCMBuffer, Float, Float, Int) -> Void)?

    private let queue = DispatchQueue(label: "InterviewAssistant.SpeechEngine.processing",
                                     qos: .userInitiated)

    func process(buffer: AVAudioPCMBuffer, generation: Int) {
        let copied = SendablePCMBuffer(buffer.copyPCM())
        queue.async { [onProcessedBuffer] in
            let rms = rmsInt16Equivalent(copied.buffer)
            let vr  = voiceFrequencyRatio(copied.buffer)
            onProcessedBuffer?(copied, rms, vr, generation)
        }
    }
}

// MARK: - DSP helpers

/// RMS scaled to approximate Int16 range (preserves compatibility with existing thresholds).
private func rmsInt16Equivalent(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let ch = buffer.floatChannelData?[0] else { return 0 }
    let n = Int(buffer.frameLength)
    guard n > 0 else { return 0 }
    var rms: Float = 0
    vDSP_rmsqv(ch, 1, &rms, vDSP_Length(n))
    return rms * Float(Int16.max)
}

/// Fraction of spectral energy in the 300–3400 Hz human voice band relative to 0–8 kHz.
/// Computed via real FFT (vDSP). Returns 1.0 on failure (give benefit of the doubt).
private func voiceFrequencyRatio(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let ch = buffer.floatChannelData?[0] else { return 1 }
    let count = Int(buffer.frameLength)
    guard count >= 64 else { return 1 }

    let sampleRate = buffer.format.sampleRate

    // Largest power-of-2 ≤ count
    let log2n = vDSP_Length(floor(log2(Float(count))))
    let fftLen = Int(1 << log2n)
    guard fftLen >= 64 else { return 1 }
    let halfLen = fftLen / 2

    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 1 }
    defer { vDSP_destroy_fftsetup(setup) }

    // Apply Hann window to reduce spectral leakage
    var windowed = [Float](repeating: 0, count: fftLen)
    var hannWin  = [Float](repeating: 0, count: fftLen)
    vDSP_hann_window(&hannWin, vDSP_Length(fftLen), Int32(vDSP_HANN_NORM))
    vDSP_vmul(ch, 1, hannWin, 1, &windowed, 1, vDSP_Length(fftLen))

    // Real FFT via split-complex: vDSP_ctoz interleaves real pairs as (re, im)
    let realBuf = UnsafeMutablePointer<Float>.allocate(capacity: halfLen)
    let imagBuf = UnsafeMutablePointer<Float>.allocate(capacity: halfLen)
    let magsBuf = UnsafeMutablePointer<Float>.allocate(capacity: halfLen)
    defer { realBuf.deallocate(); imagBuf.deallocate(); magsBuf.deallocate() }

    realBuf.initialize(repeating: 0, count: halfLen)
    imagBuf.initialize(repeating: 0, count: halfLen)

    var split = DSPSplitComplex(realp: realBuf, imagp: imagBuf)
    windowed.withUnsafeMutableBufferPointer { wBuf in
        wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfLen) { cPtr in
            vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfLen))
        }
    }
    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    vDSP_zvmags(&split, 1, magsBuf, 1, vDSP_Length(halfLen))

    // Frequency bin boundaries
    let hzPerBin = sampleRate / Double(fftLen)
    let voiceLow = max(1, Int(300.0 / hzPerBin))
    let voiceHigh = min(halfLen - 1, Int(3400.0 / hzPerBin))
    let totalTop  = min(halfLen, Int(8000.0 / hzPerBin))
    guard voiceLow < voiceHigh, totalTop > 1 else { return 1 }

    var voiceE: Float = 0
    var totalE: Float = 0
    vDSP_sve(magsBuf + voiceLow, 1, &voiceE, vDSP_Length(voiceHigh - voiceLow))
    vDSP_sve(magsBuf + 1,        1, &totalE, vDSP_Length(totalTop  - 1))

    return totalE > 0 ? voiceE / totalE : 1
}

// MARK: - Supporting types

struct SendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

extension AVAudioPCMBuffer {
    var durationSeconds: Double {
        guard format.sampleRate > 0 else { return 0.1 }
        return Double(frameLength) / format.sampleRate
    }

    func copyPCM() -> AVAudioPCMBuffer {
        let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
        copy.frameLength = frameLength
        for ch in 0..<Int(format.channelCount) {
            if let src = floatChannelData?[ch], let dst = copy.floatChannelData?[ch] {
                dst.update(from: src, count: Int(frameLength))
            }
        }
        return copy
    }
}
