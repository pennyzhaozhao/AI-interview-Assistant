#if os(macOS)
import AppKit
import SwiftUI

final class PrompterPanel: NSPanel {
    static weak var latestPanel: PrompterPanel?
    private weak var notchScreen: NSScreen?
    private var isApplyingNotchFrame = false

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
        if pinned {
            anchorToNotch()
        }
    }

    func resizeIsland(to size: NSSize, animated: Bool = false) {
        guard let targetScreen = notchScreen ?? screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let clampedSize = NSSize(
            width: max(64, min(size.width, targetScreen.frame.width)),
            height: max(48, min(size.height, targetScreen.frame.height))
        )
        let targetFrame = NSRect(
            x: targetScreen.frame.midX - clampedSize.width / 2,
            y: targetScreen.frame.maxY - clampedSize.height,
            width: clampedSize.width,
            height: clampedSize.height
        )
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
        anchorToNotch()
        sharingType = Self.persistedSharingType
        super.orderFrontRegardless()
        anchorToNotch()
        sharingType = Self.persistedSharingType
    }

    override func orderFront(_ sender: Any?) {
        orderFrontRegardless()
    }

    func anchorToNotch(on screen: NSScreen? = nil) {
        guard !isApplyingNotchFrame,
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

        let hostingView = NSHostingView(rootView: rootView)
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
    }

    required init?(coder: NSCoder) {
        nil
    }
}
#endif
