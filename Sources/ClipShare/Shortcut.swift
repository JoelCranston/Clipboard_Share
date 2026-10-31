import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global keyboard shortcut. Printable keys are stored by the character they type (so they
/// follow the active layout); keys that type nothing useful, such as F-keys and Space, by key code.
struct Shortcut: Codable, Equatable {
    var character: String?
    var keyCode: Int?
    /// Carbon modifier flags (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: Int

    static let showHistoryDefault = Shortcut(character: "v", keyCode: nil, modifiers: cmdKey | optionKey)
    static let pasteLatestDefault = Shortcut(character: "v", keyCode: nil, modifiers: cmdKey | optionKey | controlKey)

    /// The key code to register under the current keyboard layout.
    var resolvedKeyCode: Int? {
        if let character, let first = character.first { return KeyboardLayout.keyCode(for: first) }
        return keyCode
    }

    var displayString: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        if let character { return text + character.uppercased() }
        return text + (keyCode.flatMap { Self.keyNames[$0] } ?? "Key \(keyCode ?? 0)")
    }

    /// Key equivalent and mask for showing this shortcut next to a menu item.
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { mask.insert(.control) }
        if modifiers & optionKey != 0 { mask.insert(.option) }
        if modifiers & shiftKey != 0 { mask.insert(.shift) }
        if modifiers & cmdKey != 0 { mask.insert(.command) }
        if let character { return (character, mask) }
        if let keyCode, let scalar = Self.menuFunctionKeys[keyCode].flatMap(UnicodeScalar.init) {
            return (String(Character(scalar)), mask)
        }
        return ("", [])
    }

    /// Builds a shortcut from a key press, or nil if it isn't usable as a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        let code = Int(event.keyCode)
        if Self.keyNames[code] != nil {
            // Named keys (Space, arrows, …) need a modifier; F-keys may be used alone.
            guard modifiers & (cmdKey | optionKey | controlKey) != 0 || Self.functionKeyCodes.contains(code) else { return nil }
            self.init(character: nil, keyCode: code, modifiers: modifiers)
            return
        }
        // Require ⌘, ⌥ or ⌃ so ordinary typing isn't captured.
        guard modifiers & (cmdKey | optionKey | controlKey) != 0,
              let character = KeyboardLayout.character(for: code), !character.isEmpty
        else { return nil }
        self.init(character: character, keyCode: nil, modifiers: modifiers)
    }

    init(character: String?, keyCode: Int?, modifiers: Int) {
        self.character = character
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in fKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    private static let menuFunctionKeys: [Int: UInt32] = {
        var keys: [Int: UInt32] = [kVK_Space: 0x20]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in fKeys.enumerated() { keys[code] = UInt32(NSF1FunctionKey + index) }
        return keys
    }()
}

/// A button that records a new shortcut when clicked. Esc cancels; Delete restores the default.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let defaultShortcut: Shortcut

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(recording ? "Type shortcut…" : shortcut.displayString)
                    .frame(minWidth: 110)
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if shortcut != defaultShortcut, !recording {
                Button {
                    shortcut = defaultShortcut
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(defaultShortcut.displayString)")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        // Let the current shortcuts reach the recorder instead of firing.
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                switch Int(event.keyCode) {
                case kVK_Escape:
                    stop()
                case kVK_Delete where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:
                    shortcut = defaultShortcut
                    stop()
                default:
                    if let recorded = Shortcut(event: event) {
                        shortcut = recorded
                        stop()
                    } else {
                        NSSound.beep()
                    }
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKeyCenter.shared.resume() }
        recording = false
    }
}
