import Foundation
@preconcurrency import AVFoundation
import Observation
import zlib

/// AVAudioNodeTapBlock is designed to run on AVFAudio's realtime queue but is
/// not annotated Sendable by the SDK. This wrapper documents and contains that
/// intentional cross-queue handoff.
private struct SendableAudioTap: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
}

enum ASRProvider: String, CaseIterable, Identifiable {
    case apple
    case volcano

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:
            return L.t("Apple On-Device Recognition")
        case .volcano:
            return L.t("Doubao Speech Recognition 2.0")
        }
    }

    var settingsTitle: String {
        switch self {
        case .apple:
            return L.t("Apple On-Device Recognition")
        case .volcano:
            return L.t("Doubao Speech Recognition 2.0")
        }
    }
}

@MainActor
@Observable
final class VolcanoASREngine {
    struct Config {
        var appID: String
        var accessToken: String
        var resourceID: String
        var language: String = "zh-CN"
        var sampleRate: Int = 16_000
        var chunkDurationMs: Int = 200
        var hotWords: [String] = []

        var isComplete: Bool {
            !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    
    static func builtinConfig(language: String) -> Config {
        Config(
            appID: KeychainStore.read("asr-volcano-app-key"),
            accessToken: KeychainStore.read("asr-volcano-access-key"),
            resourceID: UserDefaults.standard.string(forKey: "asr_volcano_resource_id")
                ?? "volc.seedasr.sauc.duration",
            language: language
        )
    }

    var isConnected = false
    var isListening = false
    var partialText = ""
    var statusText = ""
    var languageCode = "zh-CN"
    var audioSource: AudioSource = .microphone
    var audioLevel: Double = 0
    var isVoiceDetected = false
    var silenceDurationSeconds: Double = 8.0 {
        didSet { silenceLimitChunks = max(1, Int(silenceDurationSeconds / chunkSeconds)) }
    }
    var onRecognizedText: ((String) -> Void)?
    var onRecognizedUtterance: ((RecognizedUtterance) -> Void)?
    var answerTextProvider: (() -> String)?
    var canForceTrigger: Bool { isSpeaking || hasSentAudio }
    private(set) var lastErrorText = ""

    private var config: Config?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var connectionDelegate: VolcanoWebSocketConnectionDelegate?
    /// Created only while the microphone is actually in use and released on stop. Merely
    /// touching `AVAudioEngine.inputNode` opens the input device on macOS; with AirPods that
    /// switches the headset into its low-quality call profile (mono, one ear silent) even in
    /// system-audio mode, so no other code path may create or access an input node.
    @ObservationIgnored
    nonisolated(unsafe) private var microphoneEngine: AVAudioEngine?
    private let processingQueue = DispatchQueue(label: "InterviewAssistant.VolcanoASR.processing", qos: .userInitiated)
    /// Resamples captured audio to 16 kHz Int16 and re-chunks it into 200 ms packets.
    /// Only touched on `processingQueue`.
    private let pcmStream = VolcanoPCMStream(chunkSeconds: 0.2)
    private var sessionID = ""
    private var sequenceNumber = 0
    private var isSpeaking = false
    private var hasSentAudio = false
    private var silenceChunks = 0
    private var silenceLimitChunks = 10
    /// End time (ms, session timeline) of the last utterance already emitted. Utterances are
    /// de-duplicated by time rather than by array index: depending on the mode the server may
    /// return either every utterance since the start or only the recent ones, and an index
    /// silently skipped every sentence after the first in the latter case.
    private var lastEmittedUtteranceEndMs: Double = -1
    /// Fallback for responses without timestamps.
    private var recentlyEmittedTexts: [String] = []
    /// Periodic “[DoubaoASR]” log line, so a support log shows whether audio reaches the
    /// server and whether the server answers.
    private struct Diagnostics {
        var packets = 0
        var voicedPackets = 0
        var peakRMS: Float = 0
        var responses = 0
        var utterances = 0
        var lastLog = Date.distantPast
    }
    @ObservationIgnored private var diagnostics = Diagnostics()
    /// True between `start()` and `stop()`: an unexpected disconnect is then reconnected.
    @ObservationIgnored private var wantsListening = false
    @ObservationIgnored private var reconnectAttempts = 0
    /// System audio delivers nothing while the Mac is silent, and Doubao closes a stream that
    /// receives no audio for a while (the interviewer is quiet while the candidate answers).
    /// This task fills such gaps with silence packets so the stream stays open.
    @ObservationIgnored private var silenceKeepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var lastPacketAt = Date.distantPast
    private struct TimedPCMChunk {
        let start: Double
        let end: Double
        let data: Data
    }
    private var audioRing: [TimedPCMChunk] = []
    private var audioTimelineSeconds = 0.0
    private var currentVADSegment = Data()
    private var currentVADRMSValues: [Float] = []
    private var noiseFloorRMS: Float = 0
    private var audioConfigurationObserver: NSObjectProtocol?
    private let minimumVoiceThreshold: Float = 55
    private let chunkSeconds = 0.2
    private let protocolVersion: UInt8 = 0x01
    private let defaultHeaderSizeWords: UInt8 = 0x01
    private let fullClientRequest: UInt8 = 0x01
    private let audioOnlyRequest: UInt8 = 0x02
    private let noSequence: UInt8 = 0x00
    private let positiveSequence: UInt8 = 0x01
    private let lastWithoutSequence: UInt8 = 0x02
    private let negativeSequence: UInt8 = 0x03
    private let jsonSerialization: UInt8 = 0x01
    private let noSerialization: UInt8 = 0x00
    private let noCompression: UInt8 = 0x00
    private let gzipCompression: UInt8 = 0x01
    #if os(macOS)
    @ObservationIgnored
    nonisolated(unsafe) private var systemAudioCapture: SystemAudioCapture?
    #endif

    init(config: Config? = nil) {
        self.config = config
        self.languageCode = config?.language ?? "zh-CN"
        self.silenceLimitChunks = max(1, Int(silenceDurationSeconds / chunkSeconds))
    }

    func updateConfig(_ config: Config) {
        self.config = config
        self.languageCode = config.language
    }

    nonisolated static func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        let currentMicStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
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
    }

    @discardableResult
    func connect() async -> Bool {
        guard !isConnected else { return true }
        guard let config else {
            statusText = L.t("Enter the Doubao Voice App ID and Access Token in API settings first")
            lastErrorText = statusText
            return false
        }

        sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        sequenceNumber = 0

        let request: URLRequest
        do {
            request = try await Self.makeAuthenticatedRequest(config: config, sessionID: sessionID)
        } catch {
            statusText = String(format: L.t("Doubao Voice connection failed: %@"), error.localizedDescription)
            lastErrorText = statusText
            return false
        }

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 10
        sessionConfig.timeoutIntervalForResource = 20
        let openGate = VolcanoWebSocketOpenGate()
        let connectionDelegate = VolcanoWebSocketConnectionDelegate(gate: openGate)
        self.connectionDelegate = connectionDelegate
        let session = URLSession(configuration: sessionConfig, delegate: connectionDelegate, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        Task {
            try? await Task.sleep(for: .seconds(10))
            await openGate.resolve(.failed(L.t("Connection timed out")))
        }
        let openResult = await openGate.wait()
        guard case .opened = openResult else {
            let detail: String
            if case .failed(let message) = openResult {
                detail = message
            } else {
                detail = L.t("Unknown handshake error")
            }
            lastErrorText = Self.handshakeFailureMessage(detail: detail, resourceID: config.resourceID)
            disconnect(clearStatus: false)
            statusText = lastErrorText
            return false
        }

        let sendResult = await sendFullClientRequest(config: config)
        guard sendResult.success else {
            lastErrorText = String(format: L.t("Volcano ASR connection failed: %@"), sendResult.message)
            disconnect(clearStatus: false)
            statusText = lastErrorText
            return false
        }

        lastErrorText = ""
        isConnected = true
        statusText = L.t("🔗 Doubao Voice connected")
        receiveLoop()
        return true
    }

    func disconnect(clearStatus: Bool = true) {
        stopAudioEngine()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectionDelegate = nil
        isConnected = false
        isListening = false
        partialText = ""
        if clearStatus {
            statusText = ""
        }
        resetVAD()
    }

    @discardableResult
    func start() async -> Bool {
        guard !isListening else { return true }
        wantsListening = true
        guard await connect() else { return false }
        NSLog("[DoubaoASR] connected source=%@", audioSource == .system ? "system" : "microphone")

        switch audioSource {
        case .microphone:
            return await startMicrophoneCapture()
        case .system:
            return await startSystemAudioCapture()
        }
    }

    private func startMicrophoneCapture() async -> Bool {
        guard await Self.requestMicrophonePermission() else {
            statusText = L.t("Microphone permission required")
            return false
        }

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusText = "❌ \(error.localizedDescription)"
            return false
        }
        #endif

        // Do not carry this @MainActor instance into AVFAudio's worker queue.
        // With actor data-race checks enabled, a closure that captures `self`
        // here traps in `_dispatch_assert_queue_fail` as soon as the board opens.
        let tap = SendableAudioTap(block: Self.makeMicrophoneTap(engine: self))
        let unavailableInputMessage = L.t("The current microphone has no available audio input. Check the input device in Zoom/Teams and System Settings.")
        let engine = AVAudioEngine()
        microphoneEngine = engine
        let startResult = await Self.startAudioEngine(
            engine,
            tap: tap,
            unavailableInputMessage: unavailableInputMessage
        )

        switch startResult {
        case .success:
            isListening = true
            installAudioConfigurationObserver(for: engine)
            statusText = L.t("🎙 Listening with Doubao Voice...")
            return true
        case .failure(let error):
            if microphoneEngine === engine { stopMicrophoneEngineOnly() }
            statusText = "❌ \(error.localizedDescription)"
            return false
        }
    }

    /// AVAudioEngine invokes this block on its own realtime queue. Declaring the
    /// factory nonisolated prevents the closure from inheriting @MainActor.
    private nonisolated static func makeMicrophoneTap(engine: VolcanoASREngine) -> AVAudioNodeTapBlock {
        { [weak engine] buffer, _ in
            engine?.processCapturedBuffer(buffer)
        }
    }

    /// The dispatch block must be formed outside MainActor isolation because
    /// AVAudioEngine performs its setup on a worker queue.
    private nonisolated static func startAudioEngine(
        _ audioEngine: AVAudioEngine,
        tap: SendableAudioTap,
        unavailableInputMessage: String
    ) async -> Result<Void, Error> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let input = audioEngine.inputNode
                let inputFormat = input.inputFormat(forBus: 0)
                guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                    cont.resume(returning: .failure(NSError(
                        domain: "InterviewAssistant.Audio",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: unavailableInputMessage]
                    )))
                    return
                }
                input.removeTap(onBus: 0)
                input.installTap(
                    onBus: 0,
                    bufferSize: AVAudioFrameCount(max(1_024, inputFormat.sampleRate * 0.2)),
                    format: nil,
                    block: tap.block
                )
                audioEngine.prepare()
                do {
                    try audioEngine.start()
                    cont.resume(returning: .success(()))
                } catch {
                    input.removeTap(onBus: 0)
                    cont.resume(returning: .failure(error))
                }
            }
        }
    }

    private func startSystemAudioCapture() async -> Bool {
        #if os(macOS)
        let capture = SystemAudioCapture()
        capture.onBuffer = Self.makeSystemAudioBufferHandler(engine: self)
        capture.onStopped = Self.makeSystemAudioStoppedHandler(engine: self, capture: capture)
        systemAudioCapture = capture
        do {
            try await capture.start()
            isListening = true
            startSilenceKeepAlive()
            NSLog("[DoubaoASR] system audio capture started")
            statusText = L.t("🔊 Listening to system audio with Doubao Voice...")
            return true
        } catch {
            systemAudioCapture = nil
            statusText = String(format: L.t("❌ Unable to capture system audio: %@"), error.localizedDescription)
            NSLog("[DoubaoASR] system audio capture failed: %@", error.localizedDescription)
            return false
        }
        #else
        statusText = L.t("System audio is available only on macOS")
        return false
        #endif
    }

    #if os(macOS)
    /// ScreenCaptureKit invokes these handlers on its sample/delegate queues.
    /// Build them from a nonisolated context so they do not inherit @MainActor.
    private nonisolated static func makeSystemAudioBufferHandler(
        engine: VolcanoASREngine
    ) -> @Sendable (SendablePCMBuffer) -> Void {
        { [weak engine] buffer in
            engine?.processCapturedBuffer(buffer.buffer)
        }
    }

    private nonisolated static func makeSystemAudioStoppedHandler(
        engine: VolcanoASREngine,
        capture: SystemAudioCapture
    ) -> @Sendable (Error) -> Void {
        { [weak engine, weak capture] error in
            Task { @MainActor in
                guard let engine,
                      let capture,
                      engine.systemAudioCapture === capture,
                      engine.isListening,
                      engine.audioSource == .system else { return }
                engine.systemAudioCapture = nil
                engine.statusText = L.t("⚠️ The system-audio route changed. Reconnecting…")
                try? await Task.sleep(for: .milliseconds(350))
                if !(await engine.startSystemAudioCapture()) {
                    engine.lastErrorText = String(format: L.t("System-audio capture was interrupted: %@"), error.localizedDescription)
                }
            }
        }
    }
    #endif

    func stop() {
        wantsListening = false
        reconnectAttempts = 0
        guard isListening || isConnected else { return }
        if hasSentAudio {
            sendAudioChunk(Data(), isLast: true)
        }
        disconnect()
    }

    private func installAudioConfigurationObserver(for engine: AVAudioEngine) {
        removeAudioConfigurationObserver()
        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening, self.audioSource == .microphone else { return }
                self.statusText = L.t("⚠️ The microphone changed. Reconnecting…")
                self.removeAudioConfigurationObserver()
                self.stopMicrophoneEngineOnly()
                try? await Task.sleep(for: .milliseconds(300))
                _ = await self.startMicrophoneCapture()
            }
        }
    }

    private func removeAudioConfigurationObserver() {
        if let audioConfigurationObserver {
            NotificationCenter.default.removeObserver(audioConfigurationObserver)
            self.audioConfigurationObserver = nil
        }
    }

    private func stopMicrophoneEngineOnly() {
        guard let engine = microphoneEngine else { return }
        microphoneEngine = nil
        Self.stopAudioEngineInBackground(engine)
    }

    private nonisolated static func stopAudioEngineInBackground(_ audioEngine: AVAudioEngine) {
        DispatchQueue.global(qos: .userInitiated).async {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    func forceTrigger() {
        guard canForceTrigger else { return }
        // Feed enough regular PCM silence to trigger the server VAD without
        // sending a negative-sequence packet, which would close this continuous
        // interview recognition request.
        let silenceChunk = Data(repeating: 0, count: 6_400) // 200 ms, 16 kHz, Int16 mono
        for _ in 0..<5 {
            sendAudioChunk(silenceChunk)
        }
        isSpeaking = false
        silenceChunks = 0
        statusText = L.t("🔍 Transcribing...")
    }

    private func sendFullClientRequest(config: Config) async -> (success: Bool, message: String) {
        var requestDict: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            "show_utterances": true,
            "enable_accelerate_text": true,
            "enable_nonstream": true,
            // Let Doubao finalize each sentence while keeping the WebSocket open.
            // 900 ms is within the provider's recommended 800–1000 ms range.
            "end_window_size": 900,
            "force_to_speech_time": 1000
        ]
        let hotWords = config.hotWords.prefix(100)
        if !hotWords.isEmpty {
            requestDict["context"] = [
                "context_type": "dialog_ctx",
                "context_data": hotWords.map { ["text": $0] }
            ]
        }
        let payload: [String: Any] = [
            "user": [
                "uid": "user_\(sessionID)"
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": config.sampleRate,
                "bits": 16,
                "channel": 1,
                "language": config.language
            ],
            "request": requestDict
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return (false, L.t("Unable to encode the initialization request"))
        }
        let compressedPayload = Self.compressed(data)
        sequenceNumber += 1
        let frame = buildFrame(
            messageType: fullClientRequest,
            flags: positiveSequence,
            serialization: jsonSerialization,
            compression: gzipCompression,
            sequence: Int32(sequenceNumber),
            payload: compressedPayload
        )
        return await sendFrame(frame)
    }

    private func sendAudioChunk(_ pcmData: Data, isLast: Bool = false) {
        guard isConnected else { return }
        sequenceNumber += 1
        let seq = isLast ? -Int32(sequenceNumber) : Int32(sequenceNumber)
        let compressedPayload = Self.compressed(pcmData)
        let frame = buildFrame(
            messageType: audioOnlyRequest,
            flags: isLast ? negativeSequence : positiveSequence,
            serialization: noSerialization,
            compression: gzipCompression,
            sequence: seq,
            payload: compressedPayload
        )
        guard let task = webSocketTask else { return }
        // Hand the frame to the socket synchronously, like 1.2.1 did. One Task per packet (as
        // in 1.3.0) does not guarantee the order in which the sends reach the socket; Doubao
        // requires strictly increasing sequence numbers and closes the stream on a reordered
        // packet, which with ~100 system-audio packets per second happened within seconds.
        // A failed send is only logged: the receive loop detects a dead connection.
        Self.enqueue(frame, on: task)
    }

    /// Built outside @MainActor so URLSession's completion handler, called on its delegate
    /// queue, does not carry main-actor isolation (the `_dispatch_assert_queue_fail` crash).
    private nonisolated static func enqueue(_ frame: Data, on task: URLSessionWebSocketTask) {
        task.send(.data(frame)) { error in
            if let error {
                NSLog("[DoubaoASR] audio send failed: %@", error.localizedDescription)
            }
        }
    }

    private func sendFrame(_ data: Data) async -> (success: Bool, message: String) {
        guard let task = webSocketTask else { return (false, "WebSocket is unavailable") }
        do {
            try await task.send(.data(data))
            return (true, "OK")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func buildFrame(
        messageType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        sequence: Int32?,
        payload: Data
    ) -> Data {
        var frame = Data()
        frame.append((protocolVersion << 4) | defaultHeaderSizeWords)
        frame.append((messageType << 4) | flags)
        frame.append((serialization << 4) | compression)
        frame.append(0x00)
        if let sequence {
            var seq = sequence.bigEndian
            withUnsafeBytes(of: &seq) { frame.append(contentsOf: $0) }
        }
        var size = Int32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while self.isConnected, self.webSocketTask === task {
                    let message = try await task.receive()
                    switch message {
                    case .data(let data):
                        self.handleResponse(data)
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            self.handleResponse(data)
                        }
                    @unknown default:
                        break
                    }
                }
            } catch {
                guard self.webSocketTask === task, self.isConnected else { return }
                self.handleConnectionLost(error)
            }
        }
    }

    /// An unexpected disconnect while the board is listening: reconnect and keep listening
    /// instead of silently going deaf for the rest of the interview.
    private func handleConnectionLost(_ error: Error) {
        NSLog("[DoubaoASR] connection lost: %@ (attempt %ld)", error.localizedDescription, reconnectAttempts)
        let shouldReconnect = wantsListening && reconnectAttempts < 5
        disconnect(clearStatus: false)
        guard shouldReconnect else {
            lastErrorText = error.localizedDescription
            statusText = String(format: L.t("⚠️ Doubao Voice disconnected: %@"), error.localizedDescription)
            return
        }
        reconnectAttempts += 1
        let delay = Double(min(reconnectAttempts, 3))
        statusText = L.t("⚠️ Doubao Voice disconnected. Reconnecting…")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.wantsListening, !self.isListening else { return }
            if await self.start() {
                NSLog("[DoubaoASR] reconnected")
            } else if self.wantsListening {
                self.handleConnectionLost(NSError(
                    domain: "InterviewAssistant.Doubao",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: self.lastErrorText.isEmpty ? L.t("Reconnect failed") : self.lastErrorText]
                ))
            }
        }
    }

    private func startSilenceKeepAlive() {
        silenceKeepAliveTask?.cancel()
        let silence = Data(repeating: 0, count: 6_400) // 200 ms, 16 kHz, Int16 mono
        silenceKeepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                guard self.isListening, self.isConnected else { continue }
                if Date().timeIntervalSince(self.lastPacketAt) >= 0.4 {
                    self.handleVAD(pcmData: silence, rms: 0)
                }
            }
        }
    }

    private func logDiagnosticsIfDue(rms: Float) {
        diagnostics.packets += 1
        diagnostics.peakRMS = max(diagnostics.peakRMS, rms)
        if rms > max(minimumVoiceThreshold, noiseFloorRMS * 1.6) { diagnostics.voicedPackets += 1 }
        let now = Date()
        guard now.timeIntervalSince(diagnostics.lastLog) >= 5 else { return }
        NSLog(
            "[DoubaoASR] source=%@ packets=%ld voiced=%ld peakRMS=%.0f responses=%ld utterances=%ld connected=%@",
            audioSource == .system ? "system" : "microphone",
            diagnostics.packets, diagnostics.voicedPackets, Double(diagnostics.peakRMS),
            diagnostics.responses, diagnostics.utterances, isConnected ? "true" : "false"
        )
        diagnostics = Diagnostics(lastLog: now)
    }

    private func handleResponse(_ data: Data) {
        diagnostics.responses += 1
        reconnectAttempts = 0
        let messageType = data.count > 1 ? data[1] >> 4 : 0
        if messageType == 0x0F {
            handleErrorResponse(data)
            return
        }

        let flags = data.count > 1 ? data[1] & 0x0F : 0
        let isLastPackageFromHeader = (flags & lastWithoutSequence) != 0
        let payload: Data
        if data.count > 4 {
            let headerSize = Int(data[0] & 0x0F) * 4
            var payloadSizeOffset = headerSize

            // V3 response flags are a bit field, not an enum. A response can
            // contain a sequence and an event simultaneously (for example 0x05).
            // Treating only exactly 0x01/0x03 as sequenced shifts the payload
            // boundary and silently discards every recognition result.
            if (flags & positiveSequence) != 0 {
                payloadSizeOffset += 4
            }
            if (flags & 0x04) != 0 {
                payloadSizeOffset += 4
            }
            let payloadOffset = payloadSizeOffset + 4
            guard data.count >= payloadOffset else { return }
            let payloadSize = Int(Self.int32BigEndian(in: data, offset: payloadSizeOffset))
            if payloadSize > 0, data.count >= payloadOffset + payloadSize {
                payload = data.subdata(in: payloadOffset..<(payloadOffset + payloadSize))
            } else if data.count > payloadOffset {
                payload = data.subdata(in: payloadOffset..<data.count)
            } else {
                return
            }
        } else {
            payload = data
        }

        let responseCompression = data.count > 2 ? data[2] & 0x0F : noCompression
        let decodedPayload = responseCompression == gzipCompression ? Self.decompressed(payload) : payload

        guard let rootJSON = try? JSONSerialization.jsonObject(with: decodedPayload) as? [String: Any] else {
            statusText = L.t("The Volcano ASR response could not be parsed")
            return
        }

        if let code = Self.integerValue(rootJSON["code"]), code != 0 {
            let message = (rootJSON["message"] as? String)
                ?? (rootJSON["msg"] as? String)
                ?? L.t("The server returned an unknown error")
            lastErrorText = String(format: L.t("Doubao Voice %d: %@"), code, message)
            statusText = lastErrorText
            NSLog("[DoubaoASR] server error code=%ld message=%@", code, message)
            return
        }

        // Official examples wrap the actual ASR object in `payload_msg` after
        // protocol decoding. Supporting both shapes makes this parser work with
        // raw V3 frames as well as provider/test fixtures.
        let json = responseBody(from: rootJSON)
        let text = extractText(from: json)
        let isFinal = isLastPackageFromHeader
            || (rootJSON["is_last_package"] as? Bool == true)
            || (json["is_last_package"] as? Bool == true)
            || ((json["is_final"] as? Bool)
            ?? (json["isFinal"] as? Bool)
            ?? ((json["result"] as? [String: Any])?["is_final"] as? Bool)
            ?? false)

        // Server-side VAD: emit utterances the server has finalized (definite: true).
        let utterances = responseUtterances(from: json)
        var emittedAny = false
        for utterance in utterances where utterance["definite"] as? Bool == true {
            let utteranceText = (utterance["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard markEmitted(utterance, text: utteranceText) else { continue }
            emittedAny = true
            partialText = ""
            isSpeaking = false
            hasSentAudio = false
            silenceChunks = 0
            diagnostics.utterances += 1
            emitRecognizedUtterance(utteranceText, metadata: utterance)
            statusText = isListening ? L.t("🎙 Listening with Doubao Voice...") : ""
        }

        if isFinal {
            // Emit any text the definite utterances did not cover.
            var remaining: [String] = []
            for utterance in utterances {
                let utteranceText = (utterance["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if markEmitted(utterance, text: utteranceText) { remaining.append(utteranceText) }
            }
            if utterances.isEmpty, !emittedAny {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if markEmitted(nil, text: clean) { remaining.append(clean) }
            }
            partialText = ""
            hasSentAudio = false
            let remainingText = remaining.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingText.isEmpty {
                diagnostics.utterances += 1
                emitRecognizedUtterance(remainingText, metadata: utterances.last)
            }
            statusText = isListening ? L.t("🎙 Listening with Doubao Voice...") : ""
        } else if !text.isEmpty {
            partialText = text
            statusText = "💬 \(String(text.prefix(30)))..."
        }
    }

    /// Returns true (and records it) when `utterance` has not been emitted yet.
    private func markEmitted(_ utterance: [String: Any]?, text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if let end = Self.doubleValue(utterance?["end_time"]), end > 0 {
            guard end > lastEmittedUtteranceEndMs else { return false }
            lastEmittedUtteranceEndMs = end
            return true
        }
        guard !recentlyEmittedTexts.contains(text) else { return false }
        recentlyEmittedTexts.append(text)
        if recentlyEmittedTexts.count > 20 { recentlyEmittedTexts.removeFirst() }
        return true
    }

    private func handleErrorResponse(_ data: Data) {
        guard data.count >= 12 else { return }
        let code = UInt32(bitPattern: Self.int32BigEndian(in: data, offset: 4))
        let size = Int(Self.int32BigEndian(in: data, offset: 8))
        guard size > 0, data.count >= 12 + size else {
            lastErrorText = String(format: L.t("Volcano ASR error: %d"), code)
            statusText = lastErrorText
            return
        }
        let messageData = data.subdata(in: 12..<(12 + size))
        let message = String(data: messageData, encoding: .utf8) ?? "\(messageData.count) bytes"
        lastErrorText = String(format: L.t("Volcano ASR error %d: %@"), code, message)
        statusText = lastErrorText
    }

    private func extractText(from json: [String: Any]) -> String {
        if let result = json["result"] as? [[String: Any]] {
            return result.compactMap { $0["text"] as? String }.joined()
        }
        if let result = json["result"] as? [String: Any] {
            if let text = result["text"] as? String { return text }
            if let utterances = result["utterances"] as? [[String: Any]] {
                return utterances.compactMap { $0["text"] as? String }.joined()
            }
        }
        if let text = json["text"] as? String { return text }
        return ""
    }

    private func responseBody(from json: [String: Any]) -> [String: Any] {
        if let body = json["payload_msg"] as? [String: Any] {
            return body
        }
        if let bodyText = json["payload_msg"] as? String,
           let data = bodyText.data(using: .utf8),
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return body
        }
        return json
    }

    private func responseUtterances(from json: [String: Any]) -> [[String: Any]] {
        if let result = json["result"] as? [String: Any] {
            return result["utterances"] as? [[String: Any]] ?? []
        }
        if let results = json["result"] as? [[String: Any]] {
            return results.flatMap { $0["utterances"] as? [[String: Any]] ?? [] }
        }
        return []
    }

    private func handleVAD(pcmData: Data, rms: Float) {
        sendAudioChunk(pcmData)
        hasSentAudio = true
        lastPacketAt = Date()
        logDiagnosticsIfDue(rms: rms)
        if audioSource == .microphone {
            appendToAudioRing(pcmData)
        }

        let adaptiveThreshold = max(minimumVoiceThreshold, noiseFloorRMS * 1.6)
        isVoiceDetected = rms > adaptiveThreshold
        if isVoiceDetected {
            let normalized = min(1, max(0.12, Double(rms / max(adaptiveThreshold * 8, 1))))
            audioLevel = (audioLevel * 0.35) + (normalized * 0.65)
        } else {
            audioLevel = 0
        }

        if isVoiceDetected {
            if !isSpeaking {
                isSpeaking = true
                currentVADSegment = Data()
                currentVADRMSValues = []
                statusText = audioSource == .system ? L.t("🔴 Doubao Voice is transcribing system audio...") : L.t("🔴 Recording with Doubao Voice...")
            }
            currentVADSegment.append(pcmData)
            currentVADRMSValues.append(rms)
            silenceChunks = 0
        } else if isSpeaking {
            currentVADSegment.append(pcmData)
            learnNoiseFloor(from: rms)
            silenceChunks += 1
            if silenceChunks >= silenceLimitChunks {
                // Do not send a negative-sequence (last) packet here. That packet
                // ends the ASR request, so later system audio still animates the
                // waveform but can no longer produce text. Doubao's server-side
                // VAD (end_window_size) finalizes the sentence on this same stream.
                isSpeaking = false
                silenceChunks = 0
                statusText = L.t("🔍 Transcribing...")
            }
        } else if isListening {
            learnNoiseFloor(from: rms)
            statusText = audioSource == .system ? L.t("🔊 Listening to system audio with Doubao Voice...") : L.t("🎙 Listening with Doubao Voice...")
        }
    }

    private func learnNoiseFloor(from rms: Float) {
        guard rms.isFinite, rms > 0 else { return }
        if noiseFloorRMS == 0 {
            noiseFloorRMS = min(rms, minimumVoiceThreshold)
        } else {
            noiseFloorRMS = (noiseFloorRMS * 0.96) + (min(rms, noiseFloorRMS * 1.5) * 0.04)
        }
    }

    private func resetVAD() {
        isSpeaking = false
        hasSentAudio = false
        silenceChunks = 0
        lastEmittedUtteranceEndMs = -1
        recentlyEmittedTexts = []
        noiseFloorRMS = 0
        audioRing = []
        audioTimelineSeconds = 0
        currentVADSegment = Data()
        currentVADRMSValues = []
        audioLevel = 0
        isVoiceDetected = false
    }

    private func appendToAudioRing(_ data: Data) {
        let duration = Double(data.count / MemoryLayout<Int16>.size) / 16_000
        let chunk = TimedPCMChunk(start: audioTimelineSeconds, end: audioTimelineSeconds + duration, data: data)
        audioTimelineSeconds += duration
        audioRing.append(chunk)
        let cutoff = max(0, audioTimelineSeconds - 30)
        audioRing.removeAll { $0.end < cutoff }
    }

    private func emitRecognizedUtterance(_ text: String, metadata: [String: Any]?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard audioSource == .microphone else {
            onRecognizedUtterance?(RecognizedUtterance(text: clean))
            onRecognizedText?(clean)
            return
        }

        let rangedData = pcmData(for: metadata)
        let pcm = rangedData.isEmpty ? currentVADSegment : rangedData
        let samples = Self.floatSamples(fromPCM16: pcm)
        let meanRMS: Float
        if currentVADRMSValues.isEmpty {
            meanRMS = Self.rmsInt16(pcm)
        } else {
            meanRMS = currentVADRMSValues.reduce(0, +) / Float(currentVADRMSValues.count)
        }
        let duration = Double(samples.count) / 16_000
        let peakRMS = currentVADRMSValues.max() ?? meanRMS
        currentVADSegment = Data()
        currentVADRMSValues = []

        Task { @MainActor in
            var label: SpeakerLabel = .unknown
            var score: Float?
            if let result = await SpeakerVerificationService.shared.classify(
                samples16kMono: samples,
                meanRMS: meanRMS,
                answerOverlap: Float(SpeechProtectionPolicy.answerOverlap(clean, self.answerTextProvider?() ?? ""))
            ) {
                label = result.0
                score = result.1
            }
            if label == .candidate {
                self.statusText = L.t("🙋 You are answering")
                return
            }
            let utterance = RecognizedUtterance(
                text: clean,
                meanVoiceRMS: meanRMS,
                peakVoiceRMS: peakRMS,
                durationSeconds: duration,
                speaker: label,
                speakerScore: score
            )
            self.onRecognizedUtterance?(utterance)
            self.onRecognizedText?(clean)
        }
    }

    private func pcmData(for metadata: [String: Any]?) -> Data {
        guard let metadata,
              let startMS = Self.doubleValue(metadata["start_time"] ?? metadata["startTime"]),
              let endMS = Self.doubleValue(metadata["end_time"] ?? metadata["endTime"]),
              endMS > startMS else { return Data() }
        let start = startMS / 1_000
        let end = endMS / 1_000
        var result = Data()
        for chunk in audioRing where chunk.end > start && chunk.start < end {
            let chunkSamples = chunk.data.count / MemoryLayout<Int16>.size
            let from = max(0, Int((start - chunk.start) * 16_000))
            let to = min(chunkSamples, Int(ceil((end - chunk.start) * 16_000)))
            if from < to {
                result.append(chunk.data.subdata(in: (from * 2)..<(to * 2)))
            }
        }
        return result
    }

    private nonisolated static func floatSamples(fromPCM16 data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            return values.map { Float($0) / Float(Int16.max) }
        }
    }

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func stopAudioEngine() {
        silenceKeepAliveTask?.cancel()
        silenceKeepAliveTask = nil
        resetPCMStream()
        removeAudioConfigurationObserver()
        #if os(macOS)
        if let capture = systemAudioCapture {
            systemAudioCapture = nil
            Task { await capture.stop() }
        }
        #endif

        stopMicrophoneEngineOnly()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Microphone taps deliver ~200 ms buffers, but ScreenCaptureKit delivers ~10 ms ones.
    /// Both go through one long-lived converter (a fresh converter per buffer drops the
    /// resampler's look-ahead samples every time, which garbles short system-audio buffers
    /// beyond recognition) and are re-chunked to 200 ms, the packet size the VAD counters
    /// and the Doubao streaming API expect.
    private nonisolated func processCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        let stream = pcmStream
        processingQueue.async { [weak self] in
            for pcmData in stream.append(buffer) {
                let rms = Self.rmsInt16(pcmData)
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    self.handleVAD(pcmData: pcmData, rms: rms)
                }
            }
        }
    }

    private func resetPCMStream() {
        let stream = pcmStream
        processingQueue.async { stream.reset() }
    }

    static func makeAuthenticatedRequest(config: Config, sessionID: String) async throws -> URLRequest {
        guard config.isComplete else {
            throw NSError(
                domain: "InterviewAssistant",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: L.t("Enter the Doubao Voice App ID and Access Token.")]
            )
        }
        guard let url = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async") else {
            throw NSError(
                domain: "InterviewAssistant",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L.t("The Doubao Voice endpoint is invalid.")]
            )
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(sessionID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(sessionID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(config.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.setValue(config.appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        return request
    }

    static func testConnection(config: Config) async -> String {
        guard config.isComplete else {
            return L.t("Enter the Doubao Voice App ID and Access Token first.")
        }
        let engine = VolcanoASREngine(config: config)
        let didConnect = await engine.connect()
        if didConnect {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let error = engine.lastErrorText
        let isConnected = engine.isConnected
        engine.disconnect()
        if didConnect, isConnected, error.isEmpty {
            return L.t("✅ Doubao Voice connection successful.")
        }
        return error.isEmpty ? L.t("Doubao Voice connection failed. Check the App ID, Access Token, and model access.") : error
    }

    private static func handshakeFailureMessage(detail: String, resourceID: String) -> String {
        let plan = resourceID.hasSuffix(".concurrent") ? L.t("concurrent plan") : L.t("hourly plan")
        return String(format: L.t("Doubao Voice handshake failed (%@). The selected plan is %@. Confirm that the same plan is enabled for this App ID and that the Access Token belongs to the same app."), detail, plan)
    }

    private nonisolated static func rmsInt16(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        return data.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return 0 }
            var sum: Float = 0
            for index in 0..<sampleCount {
                let sample = Float(samples[index])
                sum += sample * sample
            }
            return sqrt(sum / Float(sampleCount))
        }
    }

    private nonisolated static func int32BigEndian(in data: Data, offset: Int) -> Int32 {
        guard data.count >= offset + 4 else { return 0 }
        let value = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        return Int32(bitPattern: value)
    }

    private nonisolated static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private nonisolated static func compressed(_ data: Data) -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16, // RFC 1952 gzip wrapper, required by Doubao ASR.
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { return data }
        defer { deflateEnd(&stream) }

        return data.withUnsafeBytes { sourceBuffer in
            let source = sourceBuffer.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = source.map { UnsafeMutablePointer(mutating: $0) }
            stream.avail_in = uInt(data.count)

            var result = Data()
            var output = [UInt8](repeating: 0, count: 32 * 1024)
            let outputCount = output.count
            var status: Int32 = Z_OK
            repeat {
                let produced = output.withUnsafeMutableBytes { outputBuffer -> Int in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputCount)
                    status = deflate(&stream, Z_FINISH)
                    return outputCount - Int(stream.avail_out)
                }
                if produced > 0 {
                    result.append(output, count: produced)
                }
            } while status == Z_OK

            return status == Z_STREAM_END ? result : data
        }
    }

    private nonisolated static func decompressed(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var stream = z_stream()
        // 15 + 32 accepts both gzip and zlib wrappers while still validating
        // the stream, which is useful for provider-side compatibility.
        let initialized = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { return data }
        defer { inflateEnd(&stream) }

        return data.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.bindMemory(to: Bytef.self).baseAddress else { return data }
            stream.next_in = UnsafeMutablePointer(mutating: source)
            stream.avail_in = uInt(data.count)

            var result = Data()
            var output = [UInt8](repeating: 0, count: 32 * 1024)
            let outputCount = output.count
            var status: Int32 = Z_OK
            repeat {
                let produced = output.withUnsafeMutableBytes { outputBuffer -> Int in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputCount)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return outputCount - Int(stream.avail_out)
                }
                if produced > 0 {
                    result.append(output, count: produced)
                }
            } while status == Z_OK

            return status == Z_STREAM_END ? result : data
        }
    }
}

private actor VolcanoWebSocketOpenGate {
    enum Outcome: Sendable {
        case opened
        case failed(String)
    }

    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ newOutcome: Outcome) {
        guard outcome == nil else { return }
        outcome = newOutcome
        continuation?.resume(returning: newOutcome)
        continuation = nil
    }
}

private final class VolcanoWebSocketConnectionDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let gate: VolcanoWebSocketOpenGate

    init(gate: VolcanoWebSocketOpenGate) {
        self.gate = gate
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { await gate.resolve(.opened) }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        NSLog("[DoubaoASR] server closed websocket code=%ld reason=%@", closeCode.rawValue, reasonText ?? "")
        let message = reasonText?.isEmpty == false
            ? String(format: L.t("The server closed the connection: %@"), reasonText!)
            : String(format: L.t("The server closed the connection (%d)"), closeCode.rawValue)
        Task { await gate.resolve(.failed(message)) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let message = statusCode.map { "HTTP \($0)：\(error.localizedDescription)" }
            ?? error.localizedDescription
        Task { await gate.resolve(.failed(message)) }
    }
}

/// Streaming resampler + re-chunker for Doubao: any PCM buffer in, 16 kHz mono Int16
/// packets of a fixed duration out. Downsampling averages the source samples each output
/// sample covers (a box low-pass, exact 3:1 for 48 kHz); upsampling interpolates linearly.
/// The fractional read position and unconsumed samples carry over between buffers, so
/// ~10 ms ScreenCaptureKit buffers convert as one continuous stream.
/// Not thread-safe; use from one serial queue.
private final class VolcanoPCMStream: @unchecked Sendable {
    private let targetRate = 16_000.0
    private let chunkBytes: Int
    private var sourceRate = 0.0
    private var position = 0.0
    private var history: [Float] = []
    private var pending = Data()
    private var buffersSinceLog = 0
    private var packetsSinceLog = 0
    private var lastLog = Date.distantPast

    init(chunkSeconds: Double) {
        chunkBytes = Int(16_000 * chunkSeconds) * MemoryLayout<Int16>.size
    }

    func reset() {
        sourceRate = 0
        position = 0
        history = []
        pending = Data()
    }

    /// Converts `buffer` and returns every complete packet now available.
    func append(_ buffer: AVAudioPCMBuffer) -> [Data] {
        let rate = buffer.format.sampleRate
        guard buffer.frameLength > 0, rate > 0 else { return [] }
        if rate != sourceRate {
            reset()
            sourceRate = rate
        }
        buffersSinceLog += 1
        history.append(contentsOf: Self.monoSamples(buffer))

        let step = sourceRate / targetRate
        var output: [Int16] = []
        output.reserveCapacity(Int(Double(history.count) / step) + 1)
        if step >= 1 {
            while position + step <= Double(history.count) {
                let start = Int(position)
                let end = min(history.count, max(start + 1, Int(position + step)))
                var sum: Float = 0
                for index in start..<end { sum += history[index] }
                output.append(Self.int16(sum / Float(end - start)))
                position += step
            }
        } else {
            while position + 1 < Double(history.count) {
                let index = Int(position)
                let fraction = Float(position - Double(index))
                output.append(Self.int16(history[index] * (1 - fraction) + history[index + 1] * fraction))
                position += step
            }
        }
        let consumed = min(Int(position), history.count)
        if consumed > 0 {
            history.removeFirst(consumed)
            position -= Double(consumed)
        }
        output.withUnsafeBufferPointer { pending.append(Data(buffer: $0)) }

        var packets: [Data] = []
        while pending.count >= chunkBytes {
            packets.append(Data(pending.prefix(chunkBytes)))
            pending = Data(pending.dropFirst(chunkBytes))
        }
        packetsSinceLog += packets.count
        logIfDue(buffer)
        return packets
    }

    private func logIfDue(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLog) >= 5 else { return }
        NSLog(
            "[DoubaoASR] capture buffers=%ld packets=%ld rate=%.0f channels=%ld interleaved=%@ common=%ld",
            buffersSinceLog, packetsSinceLog, sourceRate, Int(buffer.format.channelCount),
            buffer.format.isInterleaved ? "true" : "false", Int(buffer.format.commonFormat.rawValue)
        )
        buffersSinceLog = 0
        packetsSinceLog = 0
        lastLog = now
    }

    private static func int16(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-1, min(1, value)) * Float(Int16.max))
    }

    /// Mono float samples from float32, int16 or int32 buffers, interleaved or not.
    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        var mono = [Float](repeating: 0, count: frames)

        func mix(scale: Float, read: (_ channel: Int, _ frame: Int) -> Float) {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += read(channel, frame) }
                mono[frame] = sum / Float(channels) * scale
            }
        }

        if let data = buffer.floatChannelData {
            mix(scale: 1) { channel, frame in
                interleaved ? data[0][frame * channels + channel] : data[channel][frame]
            }
        } else if let data = buffer.int16ChannelData {
            mix(scale: 1 / 32_768) { channel, frame in
                Float(interleaved ? data[0][frame * channels + channel] : data[channel][frame])
            }
        } else if let data = buffer.int32ChannelData {
            mix(scale: 1 / 2_147_483_648) { channel, frame in
                Float(interleaved ? data[0][frame * channels + channel] : data[channel][frame])
            }
        } else {
            return []
        }
        return mono
    }
}
