#if os(macOS)
import AppKit
import CoreGraphics
import CoreML
import ScreenCaptureKit
import Vision

@MainActor
final class ScreenshotCapture: ObservableObject {
    @Published var isCapturing = false
    @Published var recognizedText = ""
    @Published var captureError: String?
    @Published var captureMode: CaptureMode = .idle
    @Published var capturedSegments: [String] = []
    @Published var capturedImages: [NSImage] = []
    @Published var segmentCount = 0
    @Published var presetRegion: CGRect?
    @Published var hasPresetRegion = false
    @Published var hasScreenCapturePermission = false

    enum CaptureMode: Equatable {
        case idle
        case capturing
        case segmentDone
        case analyzing
    }

    private var selectionWindow: ScreenshotSelectionPanel?

    init() {
        loadPresetRegion()
        refreshScreenCapturePermission()
    }

    func captureAndRecognize() async -> String? {
        isCapturing = true
        captureError = nil
        defer { isCapturing = false }

        guard let image = await captureSelectedImage() else { return nil }
        let text = await recognizeText(from: image).trimmingCharacters(in: .whitespacesAndNewlines)
        recognizedText = text
        return text.isEmpty ? nil : text
    }

    func captureSelectedImage() async -> NSImage? {
        isCapturing = true
        captureError = nil
        defer { isCapturing = false }

        guard let rect = await selectRegion() else { return nil }
        return await captureRegion(rect)
    }

    func startMultiCapture() {
        capturedSegments = []
        capturedImages = []
        segmentCount = 0
        recognizedText = ""
        captureError = nil
        beginSegmentSelection()
    }

    func continueCapture() {
        captureError = nil
        beginSegmentSelection()
    }

    func finishAndMerge() -> String {
        captureMode = .analyzing
        return capturedSegments.joined(separator: "\n\n")
    }

    /// Deletes the newest screenshot and its OCR text together. Repeated calls
    /// walk backward through the current capture batch.
    @discardableResult
    func removeLastCapture() -> NSImage? {
        guard !capturedSegments.isEmpty, !capturedImages.isEmpty else { return nil }
        capturedSegments.removeLast()
        capturedImages.removeLast()
        segmentCount = capturedSegments.count
        recognizedText = capturedSegments.last ?? ""
        captureError = nil
        captureMode = capturedSegments.isEmpty ? .idle : .segmentDone
        return capturedImages.last
    }

    func resetMultiCapture() {
        capturedSegments = []
        capturedImages = []
        segmentCount = 0
        recognizedText = ""
        captureError = nil
        isCapturing = false
        captureMode = .idle
    }

    func cancelCapture() {
        selectionWindow?.close()
        selectionWindow = nil
        resetMultiCapture()
    }

    func setupPresetRegion(onComplete: @escaping (CGRect) -> Void) {
        Task { [weak self] in
            guard let self,
                  await requestScreenCapturePermissionIfNeeded() else { return }
            startRegionSelection(
                onComplete: { [weak self] rect in
                    self?.presetRegion = rect
                    self?.hasPresetRegion = true
                    self?.savePresetRegion(rect)
                    onComplete(rect)
                },
                onCancel: {}
            )
        }
    }

    func clearPresetRegion() {
        presetRegion = nil
        hasPresetRegion = false
        UserDefaults.standard.removeObject(forKey: AppPreferenceKey.screenshotPresetRegion)
    }

    func refreshPresetRegion() {
        loadPresetRegion()
    }

    func refreshScreenCapturePermission() {
        hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func silentCapturePresetRegion() async -> String? {
        loadPresetRegion()
        guard let region = presetRegion else {
            captureError = "Please set a screenshot region in Settings first."
            return nil
        }
        guard let image = await captureRegion(region) else { return nil }
        let text = await recognizeText(from: image).trimmingCharacters(in: .whitespacesAndNewlines)
        recognizedText = text
        guard !text.isEmpty else {
            captureError = "No readable text was found in this screenshot."
            return nil
        }
        capturedImages.append(image)
        return text
    }

    func silentCaptureSegment(reset: Bool = false) async {
        if reset {
            capturedSegments = []
            capturedImages = []
            segmentCount = 0
            recognizedText = ""
            captureError = nil
        }

        isCapturing = true
        captureMode = .capturing
        defer { isCapturing = false }

        guard let text = await silentCapturePresetRegion() else {
            captureMode = capturedSegments.isEmpty ? .idle : .segmentDone
            return
        }
        capturedSegments.append(text)
        segmentCount = capturedSegments.count
        captureMode = .segmentDone
    }

    private func savePresetRegion(_ rect: CGRect) {
        let dict: [String: Double] = [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.width),
            "height": Double(rect.height)
        ]
        UserDefaults.standard.set(dict, forKey: AppPreferenceKey.screenshotPresetRegion)
    }

    private func loadPresetRegion() {
        guard let dict = UserDefaults.standard.dictionary(forKey: AppPreferenceKey.screenshotPresetRegion),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let width = dict["width"] as? Double,
              let height = dict["height"] as? Double else {
            presetRegion = nil
            hasPresetRegion = false
            return
        }
        presetRegion = CGRect(x: x, y: y, width: width, height: height)
        hasPresetRegion = true
    }

    private func beginSegmentSelection() {
        isCapturing = true
        captureMode = .capturing
        startRegionSelection(
            onComplete: { rect in
                Task { await self.processSegment(rect: rect) }
            },
            onCancel: {
                self.isCapturing = false
                self.captureMode = self.capturedSegments.isEmpty ? .idle : .segmentDone
            }
        )
    }

    private func processSegment(rect: CGRect) async {
        defer {
            isCapturing = false
            captureMode = capturedSegments.isEmpty ? .idle : .segmentDone
        }

        guard let image = await captureRegion(rect) else { return }
        let text = await recognizeText(from: image).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            captureError = "No readable text was found in this screenshot."
            return
        }

        capturedImages.append(image)
        capturedSegments.append(text)
        segmentCount = capturedSegments.count
        recognizedText = text
    }

    private func selectRegion() async -> CGRect? {
        await withCheckedContinuation { continuation in
            let completion = SelectionCompletion { rect in
                continuation.resume(returning: rect)
            }
            startRegionSelection(
                onComplete: { rect in completion.finish(rect) },
                onCancel: { completion.finish(nil) }
            )
        }
    }

    private func startRegionSelection(onComplete: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        // The prompter is temporarily hidden before manual selection. In that
        // state NSScreen.main may be nil even though a display is available.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            onCancel()
            return
        }

        let overlayWindow = ScreenshotSelectionPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlayWindow.level = .statusBar
        overlayWindow.backgroundColor = NSColor.black.withAlphaComponent(0.30)
        overlayWindow.isOpaque = false
        overlayWindow.hasShadow = false
        overlayWindow.sharingType = .none
        overlayWindow.ignoresMouseEvents = false
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlayWindow.onClose = {
            self.selectionWindow = nil
            onCancel()
        }

        let selectionView = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size)) { rect in
            overlayWindow.onClose = nil
            self.selectionWindow = nil
            overlayWindow.close()
            onComplete(rect)
        } onCancel: {
            overlayWindow.onClose = nil
            self.selectionWindow = nil
            overlayWindow.close()
            onCancel()
        }

        overlayWindow.contentView = selectionView
        overlayWindow.orderFrontRegardless()
        selectionWindow = overlayWindow
    }

    private func captureRegion(_ rect: CGRect) async -> NSImage? {
        guard await requestScreenCapturePermissionIfNeeded() else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                captureError = "No display available for screenshot capture."
                return nil
            }

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = rect
            configuration.width = max(1, Int(rect.width * 2))
            configuration.height = max(1, Int(rect.height * 2))
            configuration.capturesAudio = false
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: cgImage, size: rect.size)
        } catch {
            captureError = "截图失败：\(error.localizedDescription)。如果 macOS 拒绝了当前版本，请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中启用 InterviewAssistant，然后完全退出并重新打开应用。"
            return nil
        }
    }

    @discardableResult
    func requestScreenCapturePermissionIfNeeded() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            hasScreenCapturePermission = true
            return true
        }
        let granted = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
        if granted {
            hasScreenCapturePermission = true
            return true
        }
        hasScreenCapturePermission = false
        captureError = "需要屏幕录制权限。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许当前 InterviewAssistant Dev，然后完全退出并重新打开应用。"
        return false
    }

    func recognizeText(from image: NSImage) async -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let imageBox = SendableCGImage(cgImage)

        let result: TextRecognitionResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    let accurate = performTextRecognition(
                        cgImage: imageBox.image,
                        level: .accurate,
                        usesLanguageCorrection: true
                    )
                    if !accurate.text.isEmpty {
                        continuation.resume(returning: accurate)
                        return
                    }

                    // The fast recognizer uses a different Vision path and is a
                    // useful fallback for small text or a damaged accurate-model cache.
                    let fast = performTextRecognition(
                        cgImage: imageBox.image,
                        level: .fast,
                        usesLanguageCorrection: false
                    )
                    continuation.resume(returning: fast.text.isEmpty ? accurate.merging(errorFrom: fast) : fast)
                }
            }
        }

        if let errorDescription = result.errorDescription {
            captureError = "OCR 识别失败：\(errorDescription)"
        }
        return result.text
    }
}

private final class SendableCGImage: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private struct TextRecognitionResult: Sendable {
    let text: String
    let errorDescription: String?

    func merging(errorFrom other: TextRecognitionResult) -> TextRecognitionResult {
        TextRecognitionResult(
            text: text,
            errorDescription: errorDescription ?? other.errorDescription
        )
    }
}

private func performTextRecognition(
    cgImage: CGImage,
    level: VNRequestTextRecognitionLevel,
    usesLanguageCorrection: Bool
) -> TextRecognitionResult {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    request.usesLanguageCorrection = usesLanguageCorrection
    request.minimumTextHeight = 0.008

    // `usesCPUOnly` is deprecated and is no longer reliable on newer macOS
    // releases. Assign a CPU device to every supported Vision compute stage so
    // OCR never tries to load the damaged E5/ANE model cache.
    if let devicesByStage = try? request.supportedComputeStageDevices {
        for (stage, devices) in devicesByStage {
            guard let cpu = devices.first(where: { device in
                if case .cpu = device { return true }
                return false
            }) else { continue }
            request.setComputeDevice(cpu, for: stage)
        }
    }

    do {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        return TextRecognitionResult(text: text, errorDescription: nil)
    } catch {
        return TextRecognitionResult(text: "", errorDescription: error.localizedDescription)
    }
}

private final class ScreenshotSelectionPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        let closeHandler = onClose
        onClose = nil
        super.close()
        closeHandler?()
    }
}

@MainActor
private final class SelectionCompletion {
    private var didFinish = false
    private let onFinish: (CGRect?) -> Void

    init(onFinish: @escaping (CGRect?) -> Void) {
        self.onFinish = onFinish
    }

    func finish(_ rect: CGRect?) {
        guard !didFinish else { return }
        didFinish = true
        onFinish(rect)
    }
}

private final class RegionSelectionView: NSView {
    private var startPoint: CGPoint = .zero
    private var currentRect: CGRect = .zero
    private var isDragging = false
    private let onComplete: (CGRect) -> Void
    private let onCancel: () -> Void

    init(frame: NSRect, onComplete: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isDragging {
            NSColor.white.withAlphaComponent(0.15).setFill()
            NSBezierPath(rect: currentRect).fill()
            NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.40, alpha: 1.0).setStroke()
            let path = NSBezierPath(rect: currentRect)
            path.lineWidth = 2
            path.stroke()
        }

        let text = "拖动选择截图区域  |  ESC 取消" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 16, weight: .medium)
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 60),
            withAttributes: attrs
        )
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(startPoint.x, current.x),
            y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x),
            height: abs(current.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        guard currentRect.width > 20, currentRect.height > 20 else {
            onCancel()
            return
        }

        let screenHeight = NSScreen.main?.frame.height ?? bounds.height
        let screenRect = CGRect(
            x: currentRect.minX,
            y: screenHeight - currentRect.maxY,
            width: currentRect.width,
            height: currentRect.height
        )
        onComplete(screenRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }
}
#endif
