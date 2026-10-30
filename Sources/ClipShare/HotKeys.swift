import AppKit
import Carbon.HIToolbox

/// Maps characters to virtual key codes using the active keyboard layout, so shortcuts and the
/// synthesized ⌘V follow Dvorak, AZERTY, etc. instead of physical QWERTY positions.
enum KeyboardLayout {
    /// The key that types `character` while ⌘ is held (which also covers layouts such as
    /// "Dvorak – QWERTY ⌘" that switch to QWERTY under Command).
    static func keyCode(for character: Character) -> Int? {
        let target = String(character).lowercased()
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let source = source?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            let found: Int? = layoutData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                for code in 0..<128 {
                    var deadKeyState: UInt32 = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(
                        layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState, characters.count, &length, &characters
                    )
                    if status == noErr, length > 0,
                       String(utf16CodeUnits: characters, count: length).lowercased() == target {
                        return code
                    }
                }
                return nil
            }
            if let found { return found }
        }
        return nil
    }
}

/// Global keyboard shortcuts via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
/// Shortcuts are defined by character and re-registered whenever the keyboard layout changes.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Binding {
        let character: Character
        let fallbackKeyCode: Int
        let modifiers: Int
        let action: () -> Void
    }

    private var bindings: [UInt32: Binding] = [:]
    private var references: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    /// Registers `modifiers` (Carbon flags such as `cmdKey | optionKey`) + the key that types `character`.
    func register(character: Character, fallbackKeyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        bindings[nextID] = Binding(character: character, fallbackKeyCode: fallbackKeyCode, modifiers: modifiers, action: action)
        nextID += 1
        registerAll()
    }

    fileprivate func fire(_ id: UInt32) {
        bindings[id]?.action()
    }

    private func registerAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        for (id, binding) in bindings.sorted(by: { $0.key < $1.key }) {
            let keyCode = KeyboardLayout.keyCode(for: binding.character) ?? binding.fallbackKeyCode
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x434C_5348), id: id) // 'CLSH'
            let status = RegisterEventHotKey(UInt32(keyCode), UInt32(binding.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references.append(reference)
            } else {
                NSLog("ClipShare: could not register hot key for \(binding.character) (\(status)); another app may own it")
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.registerAll() }
        }
    }
}

/// Sends ⌘V to the frontmost app. Requires the Accessibility permission.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security › Accessibility.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Posts ⌘V once the user has let go of the shortcut's modifier keys (up to half a second),
    /// so apps don't see e.g. ⌃⌥⌘V instead of a plain paste.
    static func pasteToFrontApp(after delay: TimeInterval = 0.05) {
        guard isTrusted else { return }
        let deadline = Date().addingTimeInterval(0.5)
        func attempt() {
            let held = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            if !held.isEmpty, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: attempt)
                return
            }
            let keyCode = CGKeyCode(KeyboardLayout.keyCode(for: "v") ?? kVK_ANSI_V)
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: attempt)
    }
}
