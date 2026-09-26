import Foundation
@preconcurrency import AVFoundation
import Observation
import zlib

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
    var canForceTrigger: Bool { isSpeaking || hasSentAudio }
    private(set) var lastErrorText = ""

    private var config: Config?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var connectionDelegate: VolcanoWebSocketConnectionDelegate?
    nonisolated(unsafe) private let audioEngine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "InterviewAssistant.VolcanoASR.processing", qos: .userInitiated)
    private var sessionID = ""
    private var sequenceNumber = 0
    private var isSpeaking = false
    private var hasSentAudio = false
    private var silenceChunks = 0
    private var silenceLimitChunks = 10
    private var lastDefiniteIndex = 0
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
        guard await connect() else { return false }

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

        let startResult: Result<Void, Error> = await withCheckedContinuation { [audioEngine] cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let input = audioEngine.inputNode
                let inputFormat = input.outputFormat(forBus: 0)
                guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                    cont.resume(returning: .failure(NSError(
                        domain: "InterviewAssistant.Audio",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: L.t("The current microphone has no available audio input. Check the input device in Zoom/Teams and System Settings.")]
                    )))
                    return
                }
                input.removeTap(onBus: 0)
                input.installTap(
                    onBus: 0,
                    bufferSize: AVAudioFrameCount(inputFormat.sampleRate * 0.2),
                    format: inputFormat
                ) { [weak self] buffer, _ in
                    self?.processCapturedBuffer(buffer)
                }
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

        switch startResult {
        case .success:
            isListening = true
            installAudioConfigurationObserver()
            statusText = L.t("🎙 Listening with Doubao Voice...")
            return true
        case .failure(let error):
            statusText = "❌ \(error.localizedDescription)"
            return false
        }
    }

    private func startSystemAudioCapture() async -> Bool {
        #if os(macOS)
        let capture = SystemAudioCapture()
        capture.onBuffer = { [weak self] buffer in
            self?.processCapturedBuffer(buffer)
        }
        capture.onStopped = { [weak self, weak capture] error in
            Task { @MainActor in
                guard let self,
                      let capture,
                      self.systemAudioCapture === capture,
                      self.isListening,
                      self.audioSource == .system else { return }
                self.systemAudioCapture = nil
                self.statusText = L.t("⚠️ The system-audio route changed. Reconnecting…")
                try? await Task.sleep(for: .milliseconds(350))
                if !(await self.startSystemAudioCapture()) {
                    self.lastErrorText = String(format: L.t("System-audio capture was interrupted: %@"), error.localizedDescription)
                }
            }
        }
        systemAudioCapture = capture
        do {
            try await capture.start()
            isListening = true
            statusText = L.t("🔊 Listening to system audio with Doubao Voice...")
            return true
        } catch {
            systemAudioCapture = nil
            statusText = String(format: L.t("❌ Unable to capture system audio: %@"), error.localizedDescription)
            return false
        }
        #else
        statusText = L.t("System audio is available only on macOS")
        return false
        #endif
    }

    func stop() {
        guard isListening || isConnected else { return }
        if hasSentAudio {
            sendAudioChunk(Data(), isLast: true)
        }
        disconnect()
    }

    private func installAudioConfigurationObserver() {
        guard audioConfigurationObserver == nil else { return }
        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening, self.audioSource == .microphone else { return }
                self.statusText = L.t("⚠️ The microphone changed. Reconnecting…")
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
        let engineRef = audioEngine
        DispatchQueue.global(qos: .userInitiated).async {
            engineRef.inputNode.removeTap(onBus: 0)
            engineRef.stop()
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
        webSocketTask?.send(.data(frame)) { _ in }
    }

    private func sendFrame(_ data: Data) async -> (success: Bool, message: String) {
        await withCheckedContinuation { cont in
            webSocketTask?.send(.data(data)) { error in
                if let error {
                    cont.resume(returning: (false, error.localizedDescription))
                } else {
                    cont.resume(returning: (true, "OK"))
                }
            }
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
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
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
                    if self.isConnected {
                        self.receiveLoop()
                    }
                case .failure(let error):
                    self.lastErrorText = error.localizedDescription
                    self.isConnected = false
                    self.isListening = false
                    self.statusText = String(format: L.t("⚠️ Doubao Voice disconnected: %@"), error.localizedDescription)
                    self.stopAudioEngine()
                }
            }
        }
    }

    private func handleResponse(_ data: Data) {
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

        // Server-side VAD: emit utterances the server has finalized (definite: true)
        let utterances = responseUtterances(from: json)
        if !utterances.isEmpty {
            for i in lastDefiniteIndex..<utterances.count {
                let utterance = utterances[i]
                guard utterance["definite"] as? Bool == true else { break }
                let utteranceText = (utterance["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                lastDefiniteIndex = i + 1
                if !utteranceText.isEmpty {
                    partialText = ""
                    isSpeaking = false
                    hasSentAudio = false
                    silenceChunks = 0
                    onRecognizedText?(utteranceText)
                    statusText = isListening ? L.t("🎙 Listening with Doubao Voice...") : ""
                }
            }
        }

        if isFinal {
            // Emit any text not yet covered by definite utterances
            let remainingText: String
            if lastDefiniteIndex < utterances.count {
                remainingText = utterances
                    .dropFirst(lastDefiniteIndex)
                    .compactMap { $0["text"] as? String }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if lastDefiniteIndex == 0 {
                remainingText = text
            } else {
                remainingText = ""
            }
            lastDefiniteIndex = 0
            partialText = ""
            hasSentAudio = false
            if !remainingText.isEmpty {
                onRecognizedText?(remainingText)
            }
            statusText = isListening ? L.t("🎙 Listening with Doubao Voice...") : ""
        } else if !text.isEmpty {
            partialText = text
            statusText = "💬 \(String(text.prefix(30)))..."
        }
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
                statusText = audioSource == .system ? L.t("🔴 Doubao Voice is transcribing system audio...") : L.t("🔴 Recording with Doubao Voice...")
            }
            silenceChunks = 0
        } else if isSpeaking {
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
        lastDefiniteIndex = 0
        noiseFloorRMS = 0
        audioLevel = 0
        isVoiceDetected = false
    }

    private func stopAudioEngine() {
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

    private nonisolated func processCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        processingQueue.async { [weak self] in
            guard let pcmData = Self.convertToPCM16Mono(buffer, sampleRate: 16_000) else { return }
            let rms = Self.rmsInt16(pcmData)
            Task { @MainActor in
                guard let self, self.isListening else { return }
                self.handleVAD(pcmData: pcmData, rms: rms)
            }
        }
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

    private nonisolated static func convertToPCM16Mono(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> Data? {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            return nil
        }
        let inputFormat = buffer.format
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        let ratio = sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        let inputProvider = VolcanoConverterInputProvider(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.next(outStatus: outStatus)
        }
        guard status != .error, conversionError == nil, let data = outputBuffer.int16ChannelData else {
            return nil
        }

        let frameLength = Int(outputBuffer.frameLength)
        return Data(bytes: data[0], count: frameLength * MemoryLayout<Int16>.size)
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

private final class VolcanoConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didProvideInput {
            outStatus.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
    }
}
