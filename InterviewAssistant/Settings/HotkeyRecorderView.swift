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
            hotkey = recorded
            UserDefaults.standard.set(recorded, forKey: preferenceKey)
            HotkeyManager.shared.register(key: recorded, id: hotkeyID) {
                NotificationCenter.default.post(name: notificationName, object: nil)
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
    private var screenshotMonitor: Any?

    func register(key: String, id: UInt32 = manualTriggerID, action: @escaping () -> Void) {
        if id == Self.screenshotID {
            registerScreenshotHotkey(hotkey: key, action: action)
            return
        }

        actions[id] = action
        unregister(id: id)

        let parsed = Self.parse(key)
        let hotKeyID = EventHotKeyID(signature: Self.signature("IAHK"), id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return }
        eventHotKeyRefs[id] = newRef
        installHandlerIfNeeded()
    }

    func unregister(id: UInt32) {
        if id == Self.screenshotID {
            if let screenshotMonitor {
                NSEvent.removeMonitor(screenshotMonitor)
            }
            screenshotMonitor = nil
            actions[id] = nil
            return
        }

        if let eventHotKeyRef = eventHotKeyRefs[id] {
            UnregisterEventHotKey(eventHotKeyRef)
        }
        eventHotKeyRefs[id] = nil
    }

    func registerScreenshotHotkey(hotkey: String, action: @escaping () -> Void) {
        actions[Self.screenshotID] = action
        unregister(id: Self.screenshotID)
        actions[Self.screenshotID] = action

        let parsed = Self.parse(hotkey)
        let expectedModifiers = Self.eventModifierFlags(fromCarbonFlags: parsed.modifiers)
        screenshotMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let activeModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard activeModifiers == expectedModifiers else { return }
            guard UInt32(event.keyCode) == parsed.keyCode else { return }
            DispatchQueue.main.async {
                action()
            }
        }
    }

    func registerScreenshotHotkey(
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command, .shift],
        action: @escaping () -> Void
    ) {
        if let screenshotMonitor {
            NSEvent.removeMonitor(screenshotMonitor)
        }
        let expectedModifiers = modifiers.intersection([.command, .option, .control, .shift])
        screenshotMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let activeModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard activeModifiers == expectedModifiers else { return }
            guard event.charactersIgnoringModifiers?.uppercased() == key.uppercased() else { return }
            DispatchQueue.main.async {
                action()
            }
        }
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

    private static func eventModifierFlags(fromCarbonFlags flags: UInt32) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags & UInt32(cmdKey) != 0 { result.insert(.command) }
        if flags & UInt32(optionKey) != 0 { result.insert(.option) }
        if flags & UInt32(controlKey) != 0 { result.insert(.control) }
        if flags & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
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
