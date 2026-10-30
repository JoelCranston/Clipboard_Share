import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Search text, source filter and selection for the history panel; driven by the key monitor below.
@MainActor
final class HistoryState: ObservableObject {
    enum Filter: Hashable {
        case all
        case local
        case remote
    }

    @Published var query = ""
    @Published var filter: Filter = .all
    @Published var selection = 0
}

/// A floating, non-activating panel (Spotlight-style), so the app you were typing in stays frontmost
/// and can receive the paste.
final class HistoryPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let state = HistoryState()
    private var panel: HistoryPanel?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        state.query = ""
        state.selection = 0
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        panel?.orderOut(nil)
        removeKeyMonitor()
    }

    private func makePanel() -> HistoryPanel {
        let view = HistoryView(model: model, state: state, onChoose: { [weak self] item in self?.choose(item) })
        let hosting = NSHostingView(rootView: view)
        let panel = HistoryPanel(contentView: hosting)
        panel.delegate = self
        return panel
    }

    /// Centers the panel on the screen that has the mouse pointer.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.1))
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func visibleItems() -> [ClipItem] {
        HistoryView.filtered(model.allItems, state: state)
    }

    private func choose(_ item: ClipItem) {
        model.copyToPasteboard(item)
        close()
        if model.preferences.pasteAfterChoosing {
            if Paster.isTrusted { Paster.pasteToFrontApp() } else { Paster.requestAccess() }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return event }
                return self.handle(event) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let items = visibleItems()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
            return true
        case kVK_DownArrow:
            state.selection = min(state.selection + 1, max(items.count - 1, 0))
            return true
        case kVK_UpArrow:
            state.selection = max(state.selection - 1, 0)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if items.indices.contains(state.selection) { choose(items[state.selection]) }
            return true
        case kVK_Tab:
            let order: [HistoryState.Filter] = [.all, .local, .remote]
            let index = order.firstIndex(of: state.filter) ?? 0
            let step = flags.contains(.shift) ? order.count - 1 : 1
            state.filter = order[(index + step) % order.count]
            state.selection = 0
            return true
        default:
            break
        }
        // ⌘1 … ⌘9 picks the nth visible item.
        if flags == .command, let characters = event.charactersIgnoringModifiers, let digit = Int(characters), (1...9).contains(digit) {
            if items.indices.contains(digit - 1) { choose(items[digit - 1]) }
            return true
        }
        return false
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: HistoryState
    var onChoose: (ClipItem) -> Void
    @FocusState private var searchFocused: Bool

    static func filtered(_ items: [ClipItem], state: HistoryState) -> [ClipItem] {
        items.filter { item in
            switch state.filter {
            case .all: break
            case .local: if item.isRemote { return false }
            case .remote: if !item.isRemote { return false }
            }
            guard !state.query.isEmpty else { return true }
            return (item.text ?? "").localizedCaseInsensitiveContains(state.query)
                || item.sourceName.localizedCaseInsensitiveContains(state.query)
        }
    }

    var body: some View {
        let items = Self.filtered(model.allItems, state: state)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onChange(of: state.query) { state.selection = 0 }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Picker("", selection: $state.filter) {
                Text("All").tag(HistoryState.Filter.all)
                Text("This Mac").tag(HistoryState.Filter.local)
                Text("Peers").tag(HistoryState.Filter.remote)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .onChange(of: state.filter) { state.selection = 0 }

            Divider()

            if items.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "clipboard").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(state.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, index: index, selected: index == state.selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onChoose(item) }
                                    .onHover { if $0 { state.selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: state.selection) {
                        if items.indices.contains(state.selection) {
                            proxy.scrollTo(items[state.selection].id)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("↩ copy\(model.preferences.pasteAfterChoosing ? " & paste" : "")  ⌘1–9 quick pick  ⇥ filter  esc close")
                Spacer()
                Text(model.peerStatuses.isEmpty ? "No peers" : model.peerStatuses.map(\.peer.displayName).joined(separator: ", "))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 360, minHeight: 320)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
    }
}

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                content
                HStack(spacing: 6) {
                    Label(item.sourceName, systemImage: item.isRemote ? "network" : "laptopcomputer")
                    Text(Self.relative.localizedString(for: item.date, relativeTo: Date()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if index < 9 {
                Text("⌘\(index + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .lineLimit(3)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            if let image = NSImage(data: item.payload) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 90, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("Image").italic()
            }
        }
    }
}
