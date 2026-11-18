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
            hotkey = recorded
            UserDefaults.standard.set(recorded, forKey: preferenceKey)
            if hotkeyID != HotkeyManager.screenshotID || HotkeyManager.shared.isRegistered(id: hotkeyID) {
                HotkeyManager.shared.register(key: recorded, id: hotkeyID) {
                    NotificationCenter.default.post(name: notificationName, object: nil)
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

    /// Registers a system-wide hotkey through Carbon. Unlike an NSEvent global monitor this needs no
    /// Accessibility permission and also fires while this app is frontmost. Returns false when the
    /// combination could not be registered (for example, another app already owns it).
    @discardableResult
    func register(key: String, id: UInt32 = manualTriggerID, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        actions[id] = action

        let parsed = Self.parse(key)
        guard Self.isValidHotkey(key) else { return false }
        let hotKeyID = EventHotKeyID(signature: Self.signature("IAHK"), id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        eventHotKeyRefs[id] = newRef
        registeredKeys[id] = parsed
        installHandlerIfNeeded()
        return true
    }

    func unregister(id: UInt32) {
        if let eventHotKeyRef = eventHotKeyRefs[id] {
            UnregisterEventHotKey(eventHotKeyRef)
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
        return status == noErr
    }

    /// A hotkey needs a modifier, except the function keys F1–F12, which are safe on their own.
    static func isValidHotkey(_ key: String) -> Bool {
        let parsed = parse(key)
        if parsed.modifiers != 0 { return true }
        let functionKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        return functionKeyCodes.contains(parsed.keyCode)
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
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
                guard status == noErr else { return noErr }
                Task { @MainActor in manager.actions[hotKeyID.id]?() }
                return noErr
            },
            1,
            &eventType,
            managerPointer,
            &eventHandlerRef
        )
        if status != noErr {
            eventHandlerRef = nil
        }
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
            "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111
        ]
        return map[normalizedKeyName(key).uppercased()] ?? 49
    }

    private static func signature(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

extension Notification.Name {
    static let manualTriggerHotkey = Notification.Name("manualTriggerHotkey")
    static let screenshotHotkey = Notification.Name("screenshotHotkey")
}
#endif
