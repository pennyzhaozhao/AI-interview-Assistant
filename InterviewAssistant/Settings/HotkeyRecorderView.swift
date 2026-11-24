#if os(macOS)
import Carbon
import AppKit
import SwiftUI

struct HotkeyRecorderView: View {
    @Binding var hotkey: String
    var preferenceKey = AppPreferenceKey.manualTriggerHotkey
    var notificationName = Notification.Name.manualTriggerHotkey
    var hotkeyID: UInt32 = HotkeyManager.manualTriggerID
    var defaultHotkey = HotkeyManager.defaultHotkey
    @State private var isRecording = false
    @State private var keyMonitor: Any?

    var body: some View {
        Button {
            startRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                Text(isRecording ? L.t("Press any key...") : displayText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isRecording ? Color.appYellow : Color.appText)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(isRecording ? Color.appYellow.opacity(0.16) : Color.appField)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isRecording ? Color.appYellow.opacity(0.6) : Color.appBorder)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            if hotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hotkey = defaultHotkey
            }
            // The screenshot hotkey is only held while a prompter is open (see PrompterOverlayView),
            // so it does not take Cmd+Shift+S ("Save As") away from other apps the rest of the time.
            guard hotkeyID != HotkeyManager.screenshotID else { return }
            HotkeyManager.shared.register(key: hotkey, id: hotkeyID) {
                NotificationCenter.default.post(name: notificationName, object: nil)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var displayText: String {
        hotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L.t("Click to set") : hotkey
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let recorded = HotkeyManager.hotkeyString(from: event) else { return nil }
            guard HotkeyManager.isValidHotkey(recorded) else { NSSound.beep(); return nil }
            guard HotkeyManager.shared.isAvailable(recorded, ignoring: hotkeyID) else {
                NSSound.beep()
                return nil
            }
            let previousHotkey = hotkey
            hotkey = recorded
            UserDefaults.standard.set(recorded, forKey: preferenceKey)
            // Screenshot registration follows board presence, not the previous registration result:
            // after an initial conflict there is no ref yet, but choosing a new available key while
            // the board is open still needs to take effect immediately.
            if hotkeyID != HotkeyManager.screenshotID || InterviewWindowPresence.hasOpenBoards {
                let registered = HotkeyManager.shared.register(key: recorded, id: hotkeyID) {
                    NotificationCenter.default.post(name: notificationName, object: nil)
                }
                guard registered else {
                    // Availability can change between the probe and the real registration. Keep the
                    // previous working preference in that race instead of displaying a dead shortcut.
                    hotkey = previousHotkey
                    UserDefaults.standard.set(previousHotkey, forKey: preferenceKey)
                    NSSound.beep()
                    return nil
                }
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        isRecording = false
    }
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()
    nonisolated static let defaultHotkey = "Cmd+Shift+Space"
    nonisolated static let screenshotDefaultHotkey = "Cmd+Shift+S"
    nonisolated static let manualTriggerID: UInt32 = 1
    nonisolated static let screenshotID: UInt32 = 2

    private var eventHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private var registeredKeys: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
    nonisolated private static let hotKeySignature = signature("IAHK")

    /// Registers a system-wide hotkey through Carbon. Unlike an NSEvent global monitor this needs no
    /// Accessibility permission and also fires while this app is frontmost. Returns false when the
    /// combination could not be registered (for example, another app already owns it).
    @discardableResult
    func register(key: String, id: UInt32 = manualTriggerID, action: @escaping () -> Void) -> Bool {
        let parsed = Self.parse(key)
        guard Self.isValidHotkey(key) else {
            NSLog("[HotkeyManager] register rejected invalid hotkey key=%@ id=%u", key, id)
            return false
        }
        guard installHandlerIfNeeded() else {
            NSLog("[HotkeyManager] register aborted because InstallEventHandler failed key=%@ id=%u", key, id)
            return false
        }

        // Both PrompterOverlayView layouts can appear during a size-class transition. Treat their
        // repeated registration as an action refresh instead of briefly releasing the global key.
        if let current = registeredKeys[id],
           current.keyCode == parsed.keyCode,
           current.modifiers == parsed.modifiers,
           eventHotKeyRefs[id] != nil {
            actions[id] = action
            NSLog("[HotkeyManager] register reused key=%@ id=%u", key, id)
            return true
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        NSLog(
            "[HotkeyManager] RegisterEventHotKey key=%@ keyCode=%u modifiers=%u signature=%u id=%u status=%d%@",
            key,
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID.signature,
            hotKeyID.id,
            status,
            status == eventHotKeyExistsErr ? " (eventHotKeyExistsErr; shortcut is owned elsewhere)" : ""
        )
        guard status == noErr, let newRef else { return false }

        // Register the replacement before releasing the old key. A failed replacement therefore
        // leaves the previously working shortcut intact.
        let oldRef = eventHotKeyRefs[id]
        eventHotKeyRefs[id] = newRef
        registeredKeys[id] = parsed
        actions[id] = action
        if let oldRef {
            let unregisterStatus = UnregisterEventHotKey(oldRef)
            NSLog("[HotkeyManager] replaced previous hotkey id=%u unregisterStatus=%d", id, unregisterStatus)
        }
        return true
    }

    func unregister(id: UInt32) {
        if let eventHotKeyRef = eventHotKeyRefs[id] {
            let status = UnregisterEventHotKey(eventHotKeyRef)
            NSLog("[HotkeyManager] UnregisterEventHotKey id=%u status=%d", id, status)
        }
        eventHotKeyRefs[id] = nil
        registeredKeys[id] = nil
        actions[id] = nil
    }

    func isRegistered(id: UInt32) -> Bool {
        eventHotKeyRefs[id] != nil
    }

    /// True when `key` can be registered: not used by this app's other hotkey and not owned by another app.
    func isAvailable(_ key: String, ignoring id: UInt32) -> Bool {
        let parsed = Self.parse(key)
        guard Self.isValidHotkey(key) else { return false }
        for (otherID, other) in registeredKeys where otherID != id {
            if other.keyCode == parsed.keyCode && other.modifiers == parsed.modifiers { return false }
        }
        if let current = registeredKeys[id], current.keyCode == parsed.keyCode, current.modifiers == parsed.modifiers {
            return true
        }
        var probeRef: EventHotKeyRef?
        let probeID = EventHotKeyID(signature: Self.signature("IAPR"), id: 99)
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, probeID, GetApplicationEventTarget(), 0, &probeRef)
        if let probeRef { UnregisterEventHotKey(probeRef) }
        NSLog(
            "[HotkeyManager] availability key=%@ ignoringID=%u status=%d%@",
            key,
            id,
            status,
            status == eventHotKeyExistsErr ? " (eventHotKeyExistsErr)" : ""
        )
        return status == noErr
    }

    /// A hotkey needs a modifier, except the function keys F1–F12, which are safe on their own.
    static func isValidHotkey(_ key: String) -> Bool {
        let parsed = parse(key)
        if parsed.modifiers != 0 { return true }
        let functionKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        return functionKeyCodes.contains(parsed.keyCode)
    }

    private func installHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let managerPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else {
                    NSLog("[HotkeyManager] GetEventParameter failed status=%d", status)
                    return status
                }
                let signatureMatches = hotKeyID.signature == HotkeyManager.hotKeySignature
                NSLog(
                    "[HotkeyManager] callback signature=%u expected=%u id=%u signatureMatches=%@",
                    hotKeyID.signature,
                    HotkeyManager.hotKeySignature,
                    hotKeyID.id,
                    signatureMatches ? "true" : "false"
                )
                guard signatureMatches else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in
                    guard let action = manager.actions[hotKeyID.id] else {
                        NSLog("[HotkeyManager] callback has no action id=%u", hotKeyID.id)
                        return
                    }
                    NSLog("[HotkeyManager] invoking action id=%u", hotKeyID.id)
                    action()
                }
                return noErr
            },
            1,
            &eventType,
            managerPointer,
            &eventHandlerRef
        )
        NSLog("[HotkeyManager] InstallEventHandler status=%d", status)
        if status != noErr {
            eventHandlerRef = nil
        }
        return status == noErr && eventHandlerRef != nil
    }

    /// “Cmd+Shift+S” → “⌘ + ⇧ + S”, “Cmd+Up” → “⌘ + ↑”, “Cmd+Return” → “⌘ + Enter”.
    static func displayString(_ key: String) -> String {
        let symbols: [String: String] = [
            "cmd": "⌘", "command": "⌘", "option": "⌥", "opt": "⌥", "alt": "⌥",
            "control": "⌃", "ctrl": "⌃", "shift": "⇧",
            "up": "↑", "down": "↓", "left": "←", "right": "→",
            "delete": "⌫", "return": "Enter", "escape": "Esc", "space": "Space", "tab": "Tab"
        ]
        return key.split(separator: "+")
            .map { part -> String in
                let value = part.trimmingCharacters(in: .whitespaces)
                return symbols[value.lowercased()] ?? value
            }
            .joined(separator: " + ")
    }

    static func hotkeyString(from event: NSEvent) -> String? {
        guard let key = keyName(from: event) else { return nil }
        var parts = [String]()
        if event.modifierFlags.contains(.command) { parts.append("Cmd") }
        if event.modifierFlags.contains(.option) { parts.append("Option") }
        if event.modifierFlags.contains(.control) { parts.append("Control") }
        if event.modifierFlags.contains(.shift) { parts.append("Shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static func keyName(from event: NSEvent) -> String? {
        let specialMap: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            123: "Left", 124: "Right", 125: "Down", 126: "Up",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1"
        ]
        if let special = specialMap[event.keyCode] { return special }
        let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chars, !chars.isEmpty else { return nil }
        return normalizedKeyName(chars.uppercased())
    }

    private static func parse(_ value: String) -> (keyCode: UInt32, modifiers: UInt32) {
        let parts = value.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let key = parts.last ?? "Space"
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "option", "opt", "alt": modifiers |= UInt32(optionKey)
            case "control", "ctrl": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: break
            }
        }
        return (keyCodeForString(key), modifiers)
    }

    private static func normalizedKeyName(_ key: String) -> String {
        switch key {
        case " ": return "Space"
        case "\r", "\n": return "Return"
        default: return key
        }
    }

    private static func keyCodeForString(_ key: String) -> UInt32 {
        let map: [String: UInt32] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
            "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "RETURN": 36, "TAB": 48, "DELETE": 51,
            "L": 37, "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "N": 45,
            "M": 46, ".": 47, "`": 50, "SPACE": 49, "F1": 122, "F2": 120, "F3": 99, "F4": 118,
            "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
            "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126
        ]
        return map[normalizedKeyName(key).uppercased()] ?? 49
    }

    nonisolated private static func signature(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

extension Notification.Name {
    static let manualTriggerHotkey = Notification.Name("manualTriggerHotkey")
    static let screenshotHotkey = Notification.Name("screenshotHotkey")
}

// MARK: - Prompter shortcuts

/// The prompter's keyboard shortcuts (Settings › Keyboard Shortcuts). They are system-wide Carbon
/// hotkeys, because the prompter panel never takes keyboard focus during an interview, and so they
/// are only held while they can do something: scrolling while a prompter is open, “answer the new
/// question” while that bar is shown, and delete / submit while screenshots are being collected.
/// The rest of the time the key combinations stay with the other apps.
enum PrompterHotkey: String, CaseIterable, Identifiable {
    case scrollUp
    case scrollDown
    case answerNewQuestion
    case screenshot
    case deleteLastScreenshot
    case submitScreenshots

    enum Scope { case prompterOpen, pendingQuestion, screenshotSession }

    var id: String { rawValue }

    var hotkeyID: UInt32 {
        switch self {
        case .screenshot: HotkeyManager.screenshotID
        case .scrollUp: 3
        case .scrollDown: 4
        case .answerNewQuestion: 5
        case .deleteLastScreenshot: 6
        case .submitScreenshots: 7
        }
    }

    var preferenceKey: String {
        self == .screenshot ? AppPreferenceKey.screenshotHotkey : "prompter_hotkey_\(rawValue)"
    }

    var defaultKey: String {
        switch self {
        case .scrollUp: "Cmd+Up"
        case .scrollDown: "Cmd+Down"
        case .answerNewQuestion: "Cmd+N"
        case .screenshot: HotkeyManager.screenshotDefaultHotkey
        case .deleteLastScreenshot: "Cmd+Delete"
        case .submitScreenshots: "Cmd+Return"
        }
    }

    var title: String {
        switch self {
        case .scrollUp: L.t("Scroll Text Up")
        case .scrollDown: L.t("Scroll Text Down")
        case .answerNewQuestion: L.t("Answer New Question")
        case .screenshot: L.t("Screenshot Shortcut")
        case .deleteLastScreenshot: L.t("Delete Previous Screenshot")
        case .submitScreenshots: L.t("Submit Screenshots")
        }
    }

    var icon: String {
        switch self {
        case .scrollUp: "arrow.up"
        case .scrollDown: "arrow.down"
        case .answerNewQuestion: "arrow.left.arrow.right"
        case .screenshot: "camera.viewfinder"
        case .deleteLastScreenshot: "trash"
        case .submitScreenshots: "paperplane"
        }
    }

    var scope: Scope {
        switch self {
        case .scrollUp, .scrollDown, .screenshot: .prompterOpen
        case .answerNewQuestion: .pendingQuestion
        case .deleteLastScreenshot, .submitScreenshots: .screenshotSession
        }
    }

    var notification: Notification.Name {
        self == .screenshot ? .screenshotHotkey : Notification.Name("prompterHotkey.\(rawValue)")
    }

    var currentKey: String {
        let stored = UserDefaults.standard.string(forKey: preferenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.flatMap { $0.isEmpty ? nil : $0 } ?? defaultKey
    }
}

/// Registers each prompter shortcut only while its scope applies. The screenshot shortcut keeps its
/// own lifecycle in InterviewWindowPresence / PrompterOverlayView.
@MainActor
enum PrompterHotkeyRegistry {
    private static var isPrompterOpen = false
    private static var hasPendingQuestion = false
    private static var isScreenshotSession = false

    static func setPrompterOpen(_ value: Bool) {
        isPrompterOpen = value
        if !value {
            hasPendingQuestion = false
            isScreenshotSession = false
        }
        refresh()
    }

    static func setPendingQuestion(_ value: Bool) {
        guard value != hasPendingQuestion else { return }
        hasPendingQuestion = value
        refresh()
    }

    static func setScreenshotSession(_ value: Bool) {
        guard value != isScreenshotSession else { return }
        isScreenshotSession = value
        refresh()
    }

    /// Re-applies registrations, e.g. after a shortcut was changed in Settings.
    static func refresh() {
        for hotkey in PrompterHotkey.allCases where hotkey != .screenshot {
            let active: Bool
            switch hotkey.scope {
            case .prompterOpen: active = isPrompterOpen
            case .pendingQuestion: active = isPrompterOpen && hasPendingQuestion
            case .screenshotSession: active = isPrompterOpen && isScreenshotSession
            }
            if active {
                let name = hotkey.notification
                HotkeyManager.shared.register(key: hotkey.currentKey, id: hotkey.hotkeyID) {
                    NotificationCenter.default.post(name: name, object: nil)
                }
            } else {
                HotkeyManager.shared.unregister(id: hotkey.hotkeyID)
            }
        }
    }
}

/// Settings › Keyboard Shortcuts.
struct HotkeySettingsView: View {
    @State private var keys: [PrompterHotkey: String] = [:]
    @State private var recording: PrompterHotkey?
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsBackButton()
                HStack(spacing: 16) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 64, height: 64)
                        .background(Color.appPrimary.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.t("Keyboard Shortcuts"))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Color.appText)
                        Text(L.t("Set shortcuts for common actions. Select one, then press the new key combination."))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appMuted)
                    }
                }

                VStack(spacing: 0) {
                    HStack {
                        Text(L.t("Action"))
                        Spacer()
                        Text(L.t("Shortcut")).frame(width: 240, alignment: .leading)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appMuted)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    Divider().padding(.horizontal, 12)
                    ForEach(Array(PrompterHotkey.allCases.enumerated()), id: \.element) { index, hotkey in
                        row(hotkey)
                        if index < PrompterHotkey.allCases.count - 1 {
                            Divider().padding(.leading, 76).padding(.trailing, 12)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(cardBackground(radius: 20))

                Text(L.t("Shortcuts work while the prompter is open. Answer New Question only works while the new-question bar is shown, and Delete / Submit only while you are taking screenshots; otherwise the key combinations stay with other apps. Press Esc to cancel recording."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if let message {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appDanger)
                }

                Button {
                    restoreDefaults()
                } label: {
                    Label(L.t("Restore Defaults"), systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AppButtonStyle())
                .disabled(PrompterHotkey.allCases.allSatisfy { (keys[$0] ?? $0.currentKey) == $0.defaultKey })
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBG.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        // Switching to another app also cancels a recording in progress.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onAppear {
            keys = Dictionary(uniqueKeysWithValues: PrompterHotkey.allCases.map { ($0, $0.currentKey) })
        }
        .onDisappear { stopRecording() }
    }

    private func row(_ hotkey: PrompterHotkey) -> some View {
        let isRecording = recording == hotkey
        return HStack(spacing: 14) {
            iconTile(hotkey.icon, tint: Color.appPrimary)
            Text(hotkey.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appText)
            Spacer()
            Button {
                isRecording ? stopRecording() : startRecording(hotkey)
            } label: {
                Text(isRecording ? L.t("Press the new shortcut…") : HotkeyManager.displayString(keys[hotkey] ?? hotkey.currentKey))
                    .font(.system(size: isRecording ? 14 : 17, weight: isRecording ? .medium : .regular))
                    .foregroundStyle(isRecording ? Color.appPrimary : Color.appText)
                    .padding(.horizontal, 14)
                    .frame(width: 240, height: 38, alignment: .leading)
                    .background(isRecording ? Color.appPrimary.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isRecording ? Color.appPrimary.opacity(0.06) : Color.clear)
    }

    private func startRecording(_ hotkey: PrompterHotkey) {
        stopRecording()
        message = nil
        recording = hotkey
        // Clicking anywhere else, or leaving the app, cancels: the shortcut keeps its previous value
        // (a new value is only saved when a key combination is pressed).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            stopRecording()
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let recorded = HotkeyManager.hotkeyString(from: event) else { return nil }
            guard HotkeyManager.isValidHotkey(recorded) else {
                NSSound.beep()
                message = L.t("Use a combination with ⌘, ⌥, ⌃ or ⇧ (or a function key).")
                return nil
            }
            if let clash = PrompterHotkey.allCases.first(where: { $0 != hotkey && (keys[$0] ?? $0.currentKey) == recorded }) {
                NSSound.beep()
                message = String(format: L.t("Already used by “%@”."), clash.title)
                return nil
            }
            guard HotkeyManager.shared.isAvailable(recorded, ignoring: hotkey.hotkeyID) else {
                NSSound.beep()
                message = L.t("This shortcut is taken by another app.")
                return nil
            }
            keys[hotkey] = recorded
            UserDefaults.standard.set(recorded, forKey: hotkey.preferenceKey)
            if hotkey == .screenshot {
                if InterviewWindowPresence.hasOpenBoards {
                    HotkeyManager.shared.register(key: recorded, id: hotkey.hotkeyID) {
                        NotificationCenter.default.post(name: .screenshotHotkey, object: nil)
                    }
                }
            } else {
                PrompterHotkeyRegistry.refresh()
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        recording = nil
    }

    private func restoreDefaults() {
        stopRecording()
        message = nil
        for hotkey in PrompterHotkey.allCases {
            UserDefaults.standard.removeObject(forKey: hotkey.preferenceKey)
            keys[hotkey] = hotkey.defaultKey
        }
        if InterviewWindowPresence.hasOpenBoards {
            HotkeyManager.shared.register(key: PrompterHotkey.screenshot.defaultKey, id: PrompterHotkey.screenshot.hotkeyID) {
                NotificationCenter.default.post(name: .screenshotHotkey, object: nil)
            }
        }
        PrompterHotkeyRegistry.refresh()
    }
}
#endif
