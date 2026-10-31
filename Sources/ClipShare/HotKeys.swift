import AppKit
import Carbon.HIToolbox

/// Maps between characters and virtual key codes using the active keyboard layout, so shortcuts
/// and the synthesized ⌘V follow Dvorak, AZERTY, etc. instead of physical QWERTY positions.
///
/// Translation is done with ⌘ held, which also covers layouts such as "Dvorak – QWERTY ⌘"
/// that switch to QWERTY under Command.
enum KeyboardLayout {
    /// The key that types `character` while ⌘ is held.
    static func keyCode(for character: Character) -> Int? {
        let target = String(character).lowercased()
        return withLayout { layout in
            (0..<128).first { translate(layout, keyCode: $0)?.lowercased() == target }
        }
    }

    /// The lowercase character a key types while ⌘ is held, if it types a visible character.
    static func character(for keyCode: Int) -> String? {
        withLayout { layout in
            guard let text = translate(layout, keyCode: keyCode)?.lowercased(),
                  let scalar = text.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar)
            else { return nil }
            return text
        }
    }

    private static func withLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T?) -> T? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let source = source?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            let result: T? = layoutData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                return body(base.assumingMemoryBound(to: UCKeyboardLayout.self))
            }
            if let result { return result }
        }
        return nil
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, keyCode: Int) -> String? {
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState, characters.count, &length, &characters
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

/// Global keyboard shortcuts via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
/// Shortcuts are re-registered whenever they change or the keyboard layout changes.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Binding {
        var shortcut: Shortcut
        let action: () -> Void
    }

    private var bindings: [UInt32: Binding] = [:]
    private var idsByName: [String: UInt32] = [:]
    private var references: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false
    private var suspended = false

    /// Registers (or replaces) the shortcut called `name`.
    func register(_ name: String, shortcut: Shortcut, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = idsByName[name] ?? nextID
        if idsByName[name] == nil {
            idsByName[name] = id
            nextID += 1
        }
        bindings[id] = Binding(shortcut: shortcut, action: action)
        registerAll()
    }

    /// Changes the keys for an already registered shortcut.
    func update(_ name: String, shortcut: Shortcut) {
        guard let id = idsByName[name], bindings[id]?.shortcut != shortcut else { return }
        bindings[id]?.shortcut = shortcut
        registerAll()
    }

    /// Temporarily releases all shortcuts, e.g. while the user records a new one.
    func suspend() {
        suspended = true
        registerAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }

    fileprivate func fire(_ id: UInt32) {
        bindings[id]?.action()
    }

    fileprivate func registerAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        guard !suspended else { return }
        for (id, binding) in bindings.sorted(by: { $0.key < $1.key }) {
            guard let keyCode = binding.shortcut.resolvedKeyCode else {
                NSLog("ClipShare: no key types \(binding.shortcut.displayString) in the current layout")
                continue
            }
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x434C_5348), id: id) // 'CLSH'
            let status = RegisterEventHotKey(UInt32(keyCode), UInt32(binding.shortcut.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references.append(reference)
            } else {
                NSLog("ClipShare: could not register \(binding.shortcut.displayString) (\(status)); another app may own it")
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
