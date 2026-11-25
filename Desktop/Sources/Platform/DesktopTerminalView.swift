import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

/// Native AppKit `SwiftTerm.TerminalView` bridge wired directly to BYOT's shared
/// `OpenCodeTerminalSession` / `OpenCodeTerminalStore`.
@MainActor
final class DesktopTerminalBridge: NSObject, OpenCodeTerminalOutput {
    weak var session: OpenCodeTerminalSession?
    weak var view: TerminalView?

    func write(_ text: String) {
        view?.feed(text: text)
    }
}

extension DesktopTerminalBridge: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        session?.processTitle = trimmed.isEmpty ? nil : trimmed
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        DesktopBrand.copyToClipboard(text)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class DesktopTerminalViewCache {
    private struct Entry {
        let view: TerminalView
        let bridge: DesktopTerminalBridge
        var isDark: Bool
    }

    private var entries: [String: Entry] = [:]

    func view(for session: OpenCodeTerminalSession, isDark: Bool) -> TerminalView {
        if var existing = entries[session.id] {
            if existing.isDark != isDark {
                Self.applyTheme(isDark: isDark, to: existing.view)
                existing.isDark = isDark
                entries[session.id] = existing
            }
            session.attach(existing.bridge)
            return existing.view
        }

        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 260))
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        terminalView.optionAsMetaKey = true
        terminalView.getTerminal().changeHistorySize(5_000)
        Self.applyTheme(isDark: isDark, to: terminalView)

        let bridge = DesktopTerminalBridge()
        bridge.session = session
        bridge.view = terminalView
        terminalView.terminalDelegate = bridge

        entries[session.id] = Entry(view: terminalView, bridge: bridge, isDark: isDark)
        session.attach(bridge)
        return terminalView
    }

    func retain(keeping ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    private static func applyTheme(isDark: Bool, to view: TerminalView) {
        let palette: [UInt32] = isDark
            ? [
                0x1E1E1E, 0xF14C4C, 0x23D18B, 0xE5E510, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xCCCCCC,
                0x767676, 0xFF6E6E, 0x5AF7A6, 0xF5F543, 0x6EB4FF, 0xF08CF0, 0x5CDCF5, 0xFFFFFF,
            ]
            : [
                0x24292F, 0xC72E2E, 0x1A7F37, 0x8A6D00, 0x0451A5, 0xA626A4, 0x0E7490, 0x6E7781,
                0x57606A, 0xD1242F, 0x1F883D, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x8C959F,
            ]
        view.nativeBackgroundColor = isDark ? NSColor(calibratedWhite: 0.11, alpha: 1) : .textBackgroundColor
        view.nativeForegroundColor = isDark ? NSColor(calibratedWhite: 0.92, alpha: 1) : .labelColor
        view.installColors(palette.map { hex in
            SwiftTerm.Color(
                red: UInt16((hex >> 16) & 0xFF) * 257,
                green: UInt16((hex >> 8) & 0xFF) * 257,
                blue: UInt16(hex & 0xFF) * 257
            )
        })
    }
}

private struct DesktopTerminalHostView: NSViewRepresentable {
    let session: OpenCodeTerminalSession
    let cache: DesktopTerminalViewCache
    let isDark: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        attachTerminal(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attachTerminal(into: container)
    }

    private func attachTerminal(into container: NSView) {
        let term = cache.view(for: session, isDark: isDark)
        if term.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            term.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                term.topAnchor.constraint(equalTo: container.topAnchor),
                term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }
}

struct DesktopTerminalDrawerView: View {
    let route: OpenCodeTerminalRoute
    let onClose: () -> Void

    @StateObject private var store: OpenCodeTerminalStore
    @State private var cache = DesktopTerminalViewCache()
    @Environment(\.colorScheme) private var colorScheme

    init(client: OpenCodeClient, route: OpenCodeTerminalRoute, onClose: @escaping () -> Void) {
        self.route = route
        self.onClose = onClose
        _store = StateObject(wrappedValue: OpenCodeTerminalStore(service: OpenCodeTerminalService(client: client, route: route)))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesktopBrand.elevatedSurface)
        .task { await store.load() }
        .onAppear { store.resume() }
        .onDisappear { store.suspend() }
        .onChange(of: store.terminals.map(\.id)) { _, ids in
            cache.retain(keeping: Set(ids))
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Label("Terminal · \(route.projectName)", systemImage: "apple.terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.terminals) { terminal in
                        let isSelected = terminal.id == store.selectedID
                        HStack(spacing: 5) {
                            Text(terminal.processTitle ?? (terminal.pty.title.isEmpty ? "Shell" : terminal.pty.title))
                                .lineLimit(1)
                            Button {
                                Task { await store.close(terminal) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isSelected ? DesktopBrand.selectedSurface : DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isSelected ? DesktopBrand.strongHairline : DesktopBrand.hairline, lineWidth: 1)
                        )
                        .onTapGesture { store.select(terminal) }
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                Task { await store.newTerminal() }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New terminal tab")
            .disabled(store.isCreating)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide terminal drawer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(DesktopBrand.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView("Connecting to remote PTY…")
                .controlSize(.small)
        case .unavailable(let reason):
            ContentUnavailableView("Terminal unavailable", systemImage: "apple.terminal", description: Text(reason))
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await store.load() } }
            }
        case .ready:
            if let selected = store.selected {
                DesktopTerminalHostView(session: selected, cache: cache, isDark: colorScheme == .dark)
                    .padding(6)
            } else {
                VStack(spacing: 8) {
                    Text("No open PTY sessions for \(route.projectName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Shell") {
                        Task { await store.newTerminal() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }
}
