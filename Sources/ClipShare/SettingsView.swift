import AppKit
import OmaclipKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences

    @State private var passphraseDraft = ""
    @State private var passphraseMessage: String?
    @State private var portDraft = ""
    @State private var peersDraft = ""
    @State private var accessibilityGranted = Paster.isTrusted

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    var body: some View {
        Form {
            Section {
                SecureField("Passphrase", text: $passphraseDraft, prompt: Text(model.hasPassphrase ? "•••••••• (saved)" : "Same as on your Linux machines"))
                HStack {
                    Button("Save Passphrase") { savePassphrase(passphraseDraft) }
                        .disabled(passphraseDraft.isEmpty)
                    if let imported = Preferences.omaclipConfigPassphrase() {
                        Button("Use omaclip's Passphrase") { savePassphrase(imported) }
                    }
                }
                if let passphraseMessage {
                    Text(passphraseMessage).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Sync passphrase")
            } footer: {
                Text("Every machine in the mesh must use the same passphrase. It is stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status", value: model.networkStatus)
                if let port = model.listeningPort {
                    LabeledContent("This Mac", value: IPv4.localAddresses().filter { $0 != "127.0.0.1" }.map { "\($0):\(port)" }.joined(separator: "  "))
                        .textSelection(.enabled)
                }
                if let fingerprint = model.keyFingerprint {
                    LabeledContent("Key fingerprint", value: fingerprint).textSelection(.enabled)
                }
                ForEach(model.peerStatuses) { status in
                    LabeledContent(status.peer.displayName) {
                        Text(peerDescription(status)).foregroundStyle(status.lastError == nil ? Color.secondary : Color.red)
                    }
                }
            } header: {
                Text("Status")
            }

            Section {
                TextField("Sync port (0 = random)", text: $portDraft)
                TextField("Manual peers", text: $peersDraft, prompt: Text("omarchy@100.101.102.103:36742; laptop@192.168.1.20:36742"))
                Button("Apply Network Settings") { applyNetwork() }
            } header: {
                Text("Network")
            } footer: {
                Text("Leave manual peers empty to discover omaclip on the local network with Bonjour. For Tailscale or other VPNs, set a fixed port here and on Linux (--sync-server-port), and list each machine as name@ip:port (omaclip's --peers-list format).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically copy new peer clipboard entries to this Mac", isOn: $preferences.autoCopyRemote)
                Toggle("Paste into the front app after choosing an entry", isOn: $preferences.pasteAfterChoosing)
                if !accessibilityGranted {
                    HStack {
                        Text("Pasting needs Accessibility access.").font(.caption).foregroundStyle(.secondary)
                        Button("Grant…") {
                            Paster.requestAccess()
                        }
                    }
                }
                Stepper("Keep \(preferences.maxHistory) local entries", value: $preferences.maxHistory, in: 5...500, step: 5)
                Stepper("Share the newest \(preferences.sharedCount) entries with peers", value: $preferences.sharedCount, in: 0...50)
                    .onChange(of: preferences.sharedCount) { model.publishShared() }
                Toggle("Launch at login", isOn: Binding(get: { preferences.launchAtLogin }, set: { preferences.launchAtLogin = $0 }))
                Button("Clear Local History", role: .destructive) { model.clearLocalHistory() }
            } header: {
                Text("Behavior")
            }

            Section {
                LabeledContent("Show clipboard history", value: "⌥⌘V")
                LabeledContent("Paste latest peer entry", value: "⌃⌥⌘V")
            } header: {
                Text("Shortcuts")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 560)
        .onAppear {
            portDraft = String(preferences.syncPort)
            peersDraft = preferences.manualPeers
            accessibilityGranted = Paster.isTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = Paster.isTrusted
        }
    }

    private func peerDescription(_ status: PeerStatus) -> String {
        let address = "\(status.peer.host):\(status.peer.port)"
        if let error = status.lastError { return "\(address) — \(error)" }
        if let date = status.lastSync { return "\(address) — synced \(date.formatted(date: .omitted, time: .standard))" }
        return "\(address) — connecting…"
    }

    private func savePassphrase(_ value: String) {
        do {
            try SyncKey.validate(value)
            preferences.setPassphrase(value)
            passphraseDraft = ""
            passphraseMessage = nil
            model.restartNetworking()
        } catch {
            passphraseMessage = error.localizedDescription
        }
    }

    private func applyNetwork() {
        let port = Int(portDraft.trimmingCharacters(in: .whitespaces)) ?? 0
        preferences.syncPort = (0...65535).contains(port) ? port : 0
        portDraft = String(preferences.syncPort)
        preferences.manualPeers = peersDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.restartNetworking()
    }
}
