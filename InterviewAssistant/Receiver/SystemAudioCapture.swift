#if os(macOS)
import Foundation
import AVFoundation
import ScreenCaptureKit

/// Captures system audio via ScreenCaptureKit and vends AVAudioPCMBuffer callbacks.
/// Uses mono float32 at 44100 Hz to match the VAD/recognition pipeline.
final class SystemAudioCapture: NSObject, @unchecked Sendable {

    /// Called on an internal background queue for each captured audio chunk.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called when macOS stops the capture unexpectedly (for example after an
    /// output-device or conferencing-app audio route change).
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "InterviewAssistant.SystemAudio",
                                            qos: .userInitiated)

    // MARK: - Start / Stop

    func start() async throws {
        // Do not gate ScreenCaptureKit with CGPreflightScreenCaptureAccess.
        // On some macOS versions it can report false for a valid ScreenCaptureKit
        // grant, especially when the app was re-signed (Debug/TestFlight).
        // The real ScreenCaptureKit call is the authoritative permission check.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.screenRecordingPermissionDenied(underlying: error)
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio            = true
        config.excludesCurrentProcessAudio = true   // don't feed our own audio back
        config.sampleRate               = 44100
        config.channelCount             = 1         // mono – simplifies conversion
        // Minimise video overhead (video output is not used)
        config.width                    = 2
        config.height                   = 2
        config.minimumFrameInterval     = CMTime(value: 1, timescale: 1) // ≤1 fps

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await newStream.startCapture()
        self.stream = newStream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case noDisplay
        case screenRecordingPermissionDenied(underlying: Error)
        var errorDescription: String? {
            switch self {
            case .noDisplay: return L.t("No display was found, so system audio cannot be captured.")
            case .screenRecordingPermissionDenied(let underlying):
                return String(format: L.t("InterviewAssistant does not have Screen & System Audio Recording access, or macOS denied the request: %@. Enable the current version in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app."), underlying.localizedDescription)
            }
        }
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        if let pcm = Self.convertToPCM(sampleBuffer) {
            onBuffer?(pcm)
        }
    }

    // MARK: CMSampleBuffer → AVAudioPCMBuffer

    /// Converts a float32 PCM CMSampleBuffer from ScreenCaptureKit to AVAudioPCMBuffer (mono).
    /// Handles both mono (pass-through) and stereo (mix-down) source formats.
    private static func convertToPCM(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }

        let asbd       = asbdPtr.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        // Output: mono float32 at source sample rate
        guard let avFormat = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                           channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat,
                                         frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        guard let dst = pcm.floatChannelData?[0] else { return nil }

        // ── Retrieve AudioBufferList from the sample buffer ──────────────────
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return nil }

        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: needed,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablRaw.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        let abl        = UnsafeMutableAudioBufferListPointer(
                             ablRaw.assumingMemoryBound(to: AudioBufferList.self))
        let srcChannels = Int(asbd.mChannelsPerFrame)
        let bufCount    = abl.count

        if bufCount == 1 {
            guard let srcData = abl[0].mData else { return nil }
            let src = srcData.assumingMemoryBound(to: Float.self)

            if srcChannels == 1 {
                // Mono → direct copy
                dst.update(from: src, count: frameCount)
            } else {
                // Interleaved stereo/multi → average channels
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<srcChannels { sum += src[i * srcChannels + ch] }
                    dst[i] = sum / Float(srcChannels)
                }
            }
        } else {
            // Non-interleaved multi-channel → average buffers
            dst.initialize(repeating: 0, count: frameCount)
            for bufIdx in 0..<min(bufCount, srcChannels) {
                guard let srcData = abl[bufIdx].mData else { continue }
                let src = srcData.assumingMemoryBound(to: Float.self)
                for i in 0..<frameCount { dst[i] += src[i] }
            }
            let scale = 1.0 / Float(srcChannels)
            for i in 0..<frameCount { dst[i] *= scale }
        }

        return pcm
    }
}
#endif
