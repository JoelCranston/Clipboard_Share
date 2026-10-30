import Foundation
import Security
import ServiceManagement

/// User settings, persisted in UserDefaults. The passphrase lives in the Keychain.
@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var autoCopyRemote: Bool { didSet { defaults.set(autoCopyRemote, forKey: "autoCopyRemote") } }
    @Published var pasteAfterChoosing: Bool { didSet { defaults.set(pasteAfterChoosing, forKey: "pasteAfterChoosing") } }
    @Published var syncPort: Int { didSet { defaults.set(syncPort, forKey: "syncPort") } }
    @Published var manualPeers: String { didSet { defaults.set(manualPeers, forKey: "manualPeers") } }
    @Published var maxHistory: Int { didSet { defaults.set(maxHistory, forKey: "maxHistory") } }
    @Published var sharedCount: Int { didSet { defaults.set(sharedCount, forKey: "sharedCount") } }
    @Published var showHistoryShortcut: Shortcut { didSet { save(showHistoryShortcut, forKey: "showHistoryShortcut") } }
    @Published var pasteLatestShortcut: Shortcut { didSet { save(pasteLatestShortcut, forKey: "pasteLatestShortcut") } }

    init() {
        defaults.register(defaults: [
            "autoCopyRemote": false,
            "pasteAfterChoosing": true,
            "syncPort": 0,
            "manualPeers": "",
            "maxHistory": 50,
            "sharedCount": 5,
        ])
        autoCopyRemote = defaults.bool(forKey: "autoCopyRemote")
        pasteAfterChoosing = defaults.bool(forKey: "pasteAfterChoosing")
        syncPort = defaults.integer(forKey: "syncPort")
        manualPeers = defaults.string(forKey: "manualPeers") ?? ""
        maxHistory = defaults.integer(forKey: "maxHistory")
        sharedCount = defaults.integer(forKey: "sharedCount")
        showHistoryShortcut = Self.load(Shortcut.self, from: defaults, forKey: "showHistoryShortcut") ?? .showHistoryDefault
        pasteLatestShortcut = Self.load(Shortcut.self, from: defaults, forKey: "pasteLatestShortcut") ?? .pasteLatestDefault
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("ClipShare: launch at login change failed: \(error)")
            }
        }
    }

    // MARK: Passphrase (Keychain)

    private static let keychainService = "ClipShare"
    private static let keychainAccount = "omaclip-passphrase"

    var passphrase: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setPassphrase(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "ClipShare omaclip passphrase"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("ClipShare: saving passphrase failed (\(status))") }
        objectWillChange.send()
    }

    /// The passphrase from an existing omaclip install (`~/.config/omaclip/config.json`), if any.
    static func omaclipConfigPassphrase() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/omaclip/config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let passphrase = object["passphrase"] as? String, !passphrase.isEmpty
        else { return nil }
        return passphrase
    }
}
