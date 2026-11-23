#if os(macOS)
import AppKit
import SwiftUI

/// Visual docking state shared with the SwiftUI content of a prompter panel.
/// `isDocked` drives the notch-island ⇄ floating-card morph; `isInSnapZone`
/// previews the island shape while a floating panel is dragged near the top.
@MainActor
@Observable
final class PrompterDockState {
    var isDocked = true
    var isInSnapZone = false

    /// The island shape is shown when docked or about to dock.
    var showsIslandShape: Bool { isDocked || isInSnapZone }
}

final class PrompterPanel: NSPanel {
    static weak var latestPanel: PrompterPanel?
    /// Distance from the screen top at which a dragged panel snaps back into the notch.
    private static let snapDistance: CGFloat = 36
    private static let dragThreshold: CGFloat = 3

    let dockState = PrompterDockState()
    private weak var notchScreen: NSScreen?
    private var isApplyingNotchFrame = false
    /// True while the panel floats freely; false while it is fused into the notch.
    private(set) var hasUserMoved = false
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDraggingPanel = false
    private var dockGeneration = 0

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit normally constrains windows to `visibleFrame`, whose top edge is
    /// below the menu bar/notch. This panel intentionally occupies that area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func installNotchProtection(on screen: NSScreen) {
        notchScreen = screen
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: self
        )
        anchorToNotch(on: screen)
    }

    func setHiddenFromScreenCapture(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: AppPreferenceKey.hiddenFromScreenCapture)
        sharingType = hidden ? .none : .readOnly
    }

    func setPinned(_ pinned: Bool) {
        level = pinned ? .screenSaver : .normal
        isFloatingPanel = pinned
        if pinned && !hasUserMoved {
            anchorToNotch()
        }
    }

    // MARK: - Interactive drag (top, side and bottom edges)

    func beginInteractiveDrag() {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = frame.origin
        isDraggingPanel = false
    }

    func continueInteractiveDrag() {
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        if !isDraggingPanel {
            guard hypot(dx, dy) >= Self.dragThreshold else { return }
            isDraggingPanel = true
            NSCursor.closedHand.push()
            undock()
        }

        let targetScreen = screen(containing: mouse)
        var origin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        // The floating card may tuck under the menu bar, but never past the screen top.
        origin.y = min(origin.y, targetScreen.frame.maxY - frame.height)
        super.setFrameOrigin(origin)

        let inSnapZone = isInSnapZone(on: targetScreen)
        if inSnapZone != dockState.isInSnapZone {
            withAnimation(.easeInOut(duration: 0.2)) {
                dockState.isInSnapZone = inSnapZone
            }
        }
    }

    func endInteractiveDrag() {
        defer {
            dragStartMouse = nil
            dragStartOrigin = nil
        }
        guard isDraggingPanel else { return }
        isDraggingPanel = false
        NSCursor.pop()
        let targetScreen = screen(containing: NSEvent.mouseLocation)
        if isInSnapZone(on: targetScreen) {
            dock(on: targetScreen)
        } else if dockState.isInSnapZone {
            withAnimation(.easeInOut(duration: 0.2)) {
                dockState.isInSnapZone = false
            }
        }
    }

    /// Detach from the notch: the frame stops being re-anchored and the
    /// SwiftUI content morphs into an all-round rounded card.
    private func undock() {
        dockGeneration += 1
        hasUserMoved = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            dockState.isDocked = false
            dockState.isInSnapZone = false
        }
    }

    /// Slide back to the top centre of `screen` and fuse with the notch.
    func dock(on targetScreen: NSScreen) {
        dockGeneration += 1
        let generation = dockGeneration
        notchScreen = targetScreen
        let target = NSRect(
            x: targetScreen.frame.midX - frame.width / 2,
            y: targetScreen.frame.maxY - frame.height,
            width: frame.width,
            height: frame.height
        )
        let duration = 0.32
        withAnimation(.spring(response: duration + 0.06, dampingFraction: 0.82)) {
            dockState.isDocked = true
            dockState.isInSnapZone = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            animator().setFrame(target, display: true)
        }
        // Re-enable notch anchoring once the slide has finished, unless the user
        // grabbed the panel again in the meantime.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((duration + 0.02) * 1_000)))
            guard let self, self.dockGeneration == generation else { return }
            self.hasUserMoved = false
            self.anchorToNotch(on: targetScreen)
        }
    }

    private func isInSnapZone(on targetScreen: NSScreen) -> Bool {
        frame.maxY >= targetScreen.frame.maxY - Self.snapDistance
    }

    private func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func resizeIsland(to size: NSSize, animated: Bool = false) {
        guard let targetScreen = notchScreen ?? screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let clampedSize = NSSize(
            width: max(64, min(size.width, targetScreen.frame.width)),
            height: max(48, min(size.height, targetScreen.frame.height))
        )
        let targetFrame: NSRect
        if hasUserMoved {
            // Preserve the panel's top-left corner while its expanded height changes.
            targetFrame = NSRect(
                x: frame.minX,
                y: frame.maxY - clampedSize.height,
                width: clampedSize.width,
                height: clampedSize.height
            )
        } else {
            targetFrame = NSRect(
                x: targetScreen.frame.midX - clampedSize.width / 2,
                y: targetScreen.frame.maxY - clampedSize.height,
                width: clampedSize.width,
                height: clampedSize.height
            )
        }
        if animated {
            setFrame(targetFrame, display: true, animate: true)
        } else {
            // Interactive resizing can fire dozens of times per second. Bypass
            // the normal re-anchoring observer because this frame is already
            // calculated against the screen top.
            isApplyingNotchFrame = true
            super.setFrame(targetFrame, display: true)
            isApplyingNotchFrame = false
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(isApplyingNotchFrame ? frameRect : notchAnchoredFrame(for: frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(
            isApplyingNotchFrame ? frameRect : notchAnchoredFrame(for: frameRect),
            display: flag,
            animate: animateFlag
        )
    }

    override func setFrameOrigin(_ point: NSPoint) {
        let proposedFrame = NSRect(origin: point, size: frame.size)
        let origin = isApplyingNotchFrame ? point : notchAnchoredFrame(for: proposedFrame).origin
        super.setFrameOrigin(origin)
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(size)
        anchorToNotch()
    }

    override func orderFrontRegardless() {
        Self.latestPanel = self
        if !hasUserMoved { anchorToNotch() }
        sharingType = Self.persistedSharingType
        super.orderFrontRegardless()
        if !hasUserMoved { anchorToNotch() }
        sharingType = Self.persistedSharingType
    }

    override func orderFront(_ sender: Any?) {
        orderFrontRegardless()
    }

    func anchorToNotch(on screen: NSScreen? = nil) {
        guard !hasUserMoved,
              !isApplyingNotchFrame,
              let targetScreen = screen ?? notchScreen ?? self.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        notchScreen = targetScreen
        isApplyingNotchFrame = true
        defer { isApplyingNotchFrame = false }

        let anchoredFrame = notchAnchoredFrame(for: frame, on: targetScreen)
        super.setFrame(anchoredFrame, display: false)

        #if DEBUG
        let topError = abs(self.frame.maxY - targetScreen.frame.maxY)
        print("[PrompterPanel] frame=\(self.frame) screenTop=\(targetScreen.frame.maxY) topError=\(topError)")
        assert(topError < 0.5, "PrompterPanel must stay flush with the screen top")
        #endif
    }

    #if DEBUG
    func logNotchGeometry(_ event: String) {
        guard let targetScreen = notchScreen ?? self.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let topError = self.frame.maxY - targetScreen.frame.maxY
        let contentFrame = contentView?.frame ?? .zero
        let safeAreaInsets = contentView?.safeAreaInsets ?? .init()
        print(
            "[PrompterPanel] \(event) frame=\(self.frame) " +
            "screenTop=\(targetScreen.frame.maxY) topError=\(topError) " +
            "contentFrame=\(contentFrame) safeAreaInsets=\(safeAreaInsets)"
        )
    }
    #endif

    @objc private func handleWindowDidResize(_ notification: Notification) {
        guard notification.object as? PrompterPanel === self else { return }
        anchorToNotch()
    }

    private func notchAnchoredFrame(for proposedFrame: NSRect, on explicitScreen: NSScreen? = nil) -> NSRect {
        if hasUserMoved { return proposedFrame }
        guard let targetScreen = explicitScreen ?? notchScreen ?? self.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return proposedFrame
        }
        notchScreen = targetScreen
        return NSRect(
            x: targetScreen.frame.midX - proposedFrame.width / 2,
            y: targetScreen.frame.maxY - proposedFrame.height,
            width: proposedFrame.width,
            height: proposedFrame.height
        )
    }

    private static var persistedSharingType: NSWindow.SharingType {
        UserDefaults.standard.bool(forKey: AppPreferenceKey.hiddenFromScreenCapture) ? .none : .readOnly
    }
}

/// A transparent AppKit hit region that moves the prompter panel. It is placed
/// behind the title row and along the top, side and bottom edges of the
/// expanded island. Dragging a docked panel detaches it into a floating card;
/// releasing it near the top of a screen fuses it back into the notch.
/// Compact (minimized) mode remains a click-to-restore control and is not draggable.
struct PrompterTitleBarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .openHand)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }

        override func mouseDown(with event: NSEvent) {
            (window as? PrompterPanel)?.beginInteractiveDrag()
        }

        override func mouseDragged(with event: NSEvent) {
            (window as? PrompterPanel)?.continueInteractiveDrag()
        }

        override func mouseUp(with event: NSEvent) {
            (window as? PrompterPanel)?.endInteractiveDrag()
        }
    }
}

final class FloatingWindowController<Content: View>: NSWindowController {
    init(rootView: Content) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        // Keep the expanded island at the requested 600 x 240 pt size. The
        // SwiftUI content accounts for the menu-bar/notch inset internally.
        let panelSize = NSSize(width: 600, height: 240)
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - panelSize.height
        )

        let panel = PrompterPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        PrompterPanel.latestPanel = panel
        panel.setContentSize(panelSize)
        panel.becomesKeyOnlyIfNeeded = true
        panel.setHiddenFromScreenCapture(UserDefaults.standard.bool(forKey: AppPreferenceKey.hiddenFromScreenCapture))

        let hostingView = NSHostingView(rootView: rootView.environment(panel.dockState))
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        panel.setPinned(true)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.installNotchProtection(on: screen)
        super.init(window: panel)
        // Interview prompt board or Director Mode host board: move the main window aside.
        InterviewWindowPresence.track(panel)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// While a prompt board is open the main window steps aside (same as Windows):
/// minimized to the Dock, or — with "Hide Dock During Interview" — hidden completely
/// (no Dock icon, not in ⌘Tab). Closing the last board brings it back.
@MainActor
enum InterviewWindowPresence {
    private static var boards: [ObjectIdentifier: NSObjectProtocol] = [:]
    private static var hiddenWindows: [NSWindow] = []
    private static var minimizedWindows: [NSWindow] = []
    private static var lifecycleGeneration: UInt64 = 0

    static var hasOpenBoards: Bool { !boards.isEmpty }

    static func track(_ board: NSWindow) {
        let id = ObjectIdentifier(board)
        guard boards[id] == nil else { return }
        lifecycleGeneration &+= 1
        boards[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: board,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { boardClosed(id) }
        }
        NSLog(
            "[InterviewWindowPresence] track board=%@ boards=%d generation=%llu",
            String(describing: id),
            boards.count,
            lifecycleGeneration
        )
        if boards.count == 1 {
            registerScreenshotHotkey()
        }
        moveMainWindowsAside()
    }

    /// Opened from a board while it stays open (e.g. to edit the knowledge base).
    static func revealMainWindow() {
        restoreMainWindows()
    }

    private static func boardClosed(_ id: ObjectIdentifier) {
        if let observer = boards.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
        lifecycleGeneration &+= 1
        let closeGeneration = lifecycleGeneration
        NSLog(
            "[InterviewWindowPresence] close board=%@ boards=%d generation=%llu",
            String(describing: id),
            boards.count,
            closeGeneration
        )
        // A board that is being replaced closes just before the new one opens: wait a moment
        // so the main window does not flash back in between.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                let isCurrentClose = lifecycleGeneration == closeGeneration
                NSLog(
                    "[InterviewWindowPresence] delayed close boards=%d scheduledGeneration=%llu currentGeneration=%llu current=%@",
                    boards.count,
                    closeGeneration,
                    lifecycleGeneration,
                    isCurrentClose ? "true" : "false"
                )
                if isCurrentClose, boards.isEmpty {
                    restoreMainWindows()
                    // The screenshot hotkey is only held while a board is open, so the shortcut
                    // (Cmd+Shift+S by default, "Save As" in many apps) goes back to other apps.
                    HotkeyManager.shared.unregister(id: HotkeyManager.screenshotID)
                }
            }
        }
    }

    private static func registerScreenshotHotkey() {
        let storedKey = UserDefaults.standard.string(forKey: AppPreferenceKey.screenshotHotkey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = storedKey.flatMap { $0.isEmpty ? nil : $0 } ?? HotkeyManager.screenshotDefaultHotkey
        let registered = HotkeyManager.shared.register(key: key, id: HotkeyManager.screenshotID) {
            NSLog("[ScreenshotHotkey] board lifecycle action posting .screenshotHotkey")
            NotificationCenter.default.post(name: .screenshotHotkey, object: nil)
        }
        NSLog(
            "[ScreenshotHotkey] board lifecycle registration key=%@ result=%@",
            key,
            registered ? "true" : "false"
        )
    }

    private static var mainWindows: [NSWindow] {
        NSApp.windows.filter { window in
            !(window is NSPanel) && window.canBecomeMain && window.level == .normal
        }
    }

    private static func moveMainWindowsAside() {
        if UserDefaults.standard.bool(forKey: AppPreferenceKey.hideDockIcon) {
            for window in mainWindows where window.isVisible || window.isMiniaturized {
                if !hiddenWindows.contains(where: { $0 === window }) { hiddenWindows.append(window) }
                window.orderOut(nil)
            }
            NSApp.setActivationPolicy(.accessory)
        } else {
            for window in mainWindows where window.isVisible && !window.isMiniaturized {
                if !minimizedWindows.contains(where: { $0 === window }) { minimizedWindows.append(window) }
                window.miniaturize(nil)
            }
        }
    }

    private static func restoreMainWindows() {
        NSApp.setActivationPolicy(.regular)
        for window in minimizedWindows where window.isMiniaturized { window.deminiaturize(nil) }
        for window in hiddenWindows { window.makeKeyAndOrderFront(nil) }
        minimizedWindows.removeAll()
        hiddenWindows.removeAll()
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
