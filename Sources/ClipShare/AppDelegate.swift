import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private lazy var historyPanel = HistoryPanelController(model: model)
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipShare")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let preferences = model.preferences
        HotKeyCenter.shared.register("showHistory", shortcut: preferences.showHistoryShortcut) { [weak self] in
            self?.historyPanel.toggle()
        }
        HotKeyCenter.shared.register("pasteLatest", shortcut: preferences.pasteLatestShortcut) { [weak self] in
            self?.model.pasteLatestRemote()
        }
        preferences.$showHistoryShortcut
            .sink { HotKeyCenter.shared.update("showHistory", shortcut: $0) }
            .store(in: &cancellables)
        preferences.$pasteLatestShortcut
            .sink { HotKeyCenter.shared.update("pasteLatest", shortcut: $0) }
            .store(in: &cancellables)

        // Dim the menu bar icon while no peer is reachable.
        model.$peerStatuses
            .map { statuses in statuses.contains { $0.lastError == nil && $0.lastSync != nil } }
            .removeDuplicates()
            .sink { [weak self] connected in self?.statusItem.button?.appearsDisabled = !connected }
            .store(in: &cancellables)

        model.start()
        if !model.hasPassphrase { showSettings() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let showKeys = model.preferences.showHistoryShortcut.menuKeyEquivalent
        let show = NSMenuItem(title: "Show Clipboard History", action: #selector(showHistory), keyEquivalent: showKeys.key)
        show.keyEquivalentModifierMask = showKeys.mask
        show.target = self
        menu.addItem(show)

        let latest = model.latestRemoteItem
        let pasteTitle = latest.map { "Paste Latest from \($0.sourceName)" } ?? "Paste Latest Peer Entry"
        let pasteKeys = model.preferences.pasteLatestShortcut.menuKeyEquivalent
        let paste = NSMenuItem(title: pasteTitle, action: latest == nil ? nil : #selector(pasteLatest), keyEquivalent: pasteKeys.key)
        paste.keyEquivalentModifierMask = pasteKeys.mask
        paste.target = self
        menu.addItem(paste)
        if let latest {
            let preview = NSMenuItem(title: "    " + Self.preview(latest), action: nil, keyEquivalent: "")
            preview.isEnabled = false
            menu.addItem(preview)
        }

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Peers", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if model.peerStatuses.isEmpty {
            let none = NSMenuItem(title: model.hasPassphrase ? "    None found yet" : "    Set a passphrase in Settings", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for status in model.peerStatuses {
            let state = status.lastError != nil ? "⚠︎ \(status.lastError!)" : (status.lastSync == nil ? "connecting…" : "connected")
            let item = NSMenuItem(title: "    \(status.peer.displayName) — \(state)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let autoCopy = NSMenuItem(title: "Auto-Copy from Peers", action: #selector(toggleAutoCopy), keyEquivalent: "")
        autoCopy.state = model.preferences.autoCopyRemote ? .on : .off
        autoCopy.target = self
        menu.addItem(autoCopy)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClipShare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static func preview(_ item: ClipItem) -> String {
        guard let text = item.text else { return "Image" }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    @objc private func showHistory() {
        historyPanel.show()
    }

    @objc private func pasteLatest() {
        model.pasteLatestRemote()
    }

    @objc private func toggleAutoCopy() {
        model.preferences.autoCopyRemote.toggle()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "ClipShare Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopNetworking()
    }
}
