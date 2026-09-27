import SwiftUI
import UIKit
@preconcurrency import SwiftTerm

/// Rendering settings shared by every tab on the terminal screen.
struct OpenCodeTerminalAppearance: Equatable {
    var fontSize: CGFloat
    var isDark: Bool
    var increasedContrast: Bool

    static let defaultFontSize: CGFloat = 12
    static let fontSizes: ClosedRange<CGFloat> = 8...28

    /// Follows Dynamic Type from a compact 12 pt base, capped so a phone keeps a usable
    /// number of columns; `adjustment` is the reader's own larger/smaller choice.
    static func fontSize(for dynamicTypeSize: DynamicTypeSize, adjustment: Double) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let scaled = UIFontMetrics(forTextStyle: .footnote).scaledValue(for: defaultFontSize, compatibleWith: traits)
        let base = min(scaled, 20)
        return min(max(base + adjustment, fontSizes.lowerBound), fontSizes.upperBound).rounded()
    }
}

/// ANSI palettes tuned for the app canvas: the dark set follows common terminal
/// defaults, the light set darkens yellow, green, cyan and white so output stays
/// legible on the light canvas (plain xterm white is invisible there).
enum OpenCodeTerminalPalette {
    static let dark: [UInt32] = [
        0x1E1E1E, 0xF14C4C, 0x23D18B, 0xE5E510, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xCCCCCC,
        0x767676, 0xFF6E6E, 0x5AF7A6, 0xF5F543, 0x6EB4FF, 0xF08CF0, 0x5CDCF5, 0xFFFFFF,
    ]
    static let light: [UInt32] = [
        0x24292F, 0xC72E2E, 0x1A7F37, 0x8A6D00, 0x0451A5, 0xA626A4, 0x0E7490, 0x6E7781,
        0x57606A, 0xD1242F, 0x1F883D, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x8C959F,
    ]
    /// Increase Contrast pushes the light set darker and the dark set brighter.
    static let lightHighContrast: [UInt32] = [
        0x000000, 0xA40E26, 0x055D20, 0x6B4E00, 0x023B95, 0x7D1F85, 0x07556B, 0x4A4F55,
        0x32383F, 0xA40E26, 0x055D20, 0x6B4E00, 0x023B95, 0x7D1F85, 0x07556B, 0x4A4F55,
    ]

    static func colors(for appearance: OpenCodeTerminalAppearance) -> [SwiftTerm.Color] {
        let hexes = appearance.isDark ? dark : (appearance.increasedContrast ? lightHighContrast : light)
        return hexes.map { hex in
            SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257,
                            green: UInt16((hex >> 8) & 0xFF) * 257,
                            blue: UInt16(hex & 0xFF) * 257)
        }
    }
}

/// SwiftTerm's view with VoiceOver support: it reads as one element whose value is the
/// visible screen, and double-tapping focuses it for typing.
final class OpenCodeTerminalEmulatorView: TerminalView {
    var terminalTitle = "Terminal"

    override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }

    override var accessibilityLabel: String? {
        get { "\(terminalTitle) output" }
        set {}
    }

    override var accessibilityValue: String? {
        get { Self.visibleText(getTerminal()) }
        set {}
    }

    override var accessibilityHint: String? {
        get { "Double-tap to type." }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { [.staticText, .updatesFrequently] }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        becomeFirstResponder()
    }

    /// A blinking caret is an endless animation; keep it steady under Reduce Motion.
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        super.cursorStyleChanged(source: source, newStyle: UIAccessibility.isReduceMotionEnabled ? newStyle.steady : newStyle)
    }

    /// The screen's rows, trimmed, without the blank rows below the prompt.
    static func visibleText(_ terminal: Terminal) -> String {
        var lines = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? "Empty" : lines.joined(separator: "\n")
    }
}

private extension CursorStyle {
    var steady: CursorStyle {
        switch self {
        case .blinkBlock, .steadyBlock: .steadyBlock
        case .blinkUnderline, .steadyUnderline: .steadyUnderline
        case .blinkBar, .steadyBar: .steadyBar
        }
    }
}

/// Connects one emulator view to its session: keystrokes and size go to the server,
/// output comes back, and OSC titles, links, bells and clipboard requests are handled natively.
@MainActor
final class OpenCodeTerminalBridge: NSObject, OpenCodeTerminalOutput {
    weak var session: OpenCodeTerminalSession?
    weak var view: OpenCodeTerminalEmulatorView?

    func write(_ text: String) {
        view?.feed(text: text)
    }
}

extension OpenCodeTerminalBridge: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        session?.processTitle = title.trimmedNonEmpty
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        UIPasteboard.general.string = text
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Keeps one emulator per tab for the life of the screen, so switching tabs keeps
/// scrollback and costs no replay.
@MainActor
final class OpenCodeTerminalViewCache {
    private struct Entry {
        let view: OpenCodeTerminalEmulatorView
        let bridge: OpenCodeTerminalBridge
        var appearance: OpenCodeTerminalAppearance
    }

    private var entries: [String: Entry] = [:]
    private(set) var currentID: String?

    static let scrollback = 5_000

    func view(for session: OpenCodeTerminalSession, appearance: OpenCodeTerminalAppearance) -> OpenCodeTerminalEmulatorView {
        currentID = session.id
        if var entry = entries[session.id] {
            if entry.appearance != appearance {
                Self.apply(appearance, to: entry.view, previous: entry.appearance)
                entry.appearance = appearance
                entries[session.id] = entry
            }
            entry.view.terminalTitle = session.pty.title
            // Reconnects a tab that was suspended while the app was in the background.
            session.attach(entry.bridge)
            return entry.view
        }
        // A non-zero frame keeps the first column count sane before layout.
        let view = OpenCodeTerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 390, height: 560),
                                                font: UIFont.monospacedSystemFont(ofSize: appearance.fontSize, weight: .regular))
        view.terminalTitle = session.pty.title
        // The screen draws its own key row above the keyboard.
        view.inputAccessoryView = nil
        view.optionAsMetaKey = true
        view.getTerminal().changeHistorySize(Self.scrollback)
        // Like the system insertion point in a text view, the caret starts steady;
        // programs can still ask for a blinking one.
        view.getTerminal().setCursorStyle(.steadyBlock)
        Self.apply(appearance, to: view, previous: nil)
        let bridge = OpenCodeTerminalBridge()
        bridge.session = session
        bridge.view = view
        view.terminalDelegate = bridge
        view.accessibilityIdentifier = "terminal-emulator"
        entries[session.id] = Entry(view: view, bridge: bridge, appearance: appearance)
        session.attach(bridge)
        return view
    }

    var current: OpenCodeTerminalEmulatorView? {
        currentID.flatMap { entries[$0]?.view }
    }

    /// Posted when SwiftTerm consumes the control latch on the next typed key.
    static let controlLatchConsumed = Notification.Name.terminalViewControlModifierReset

    /// Sends an accessory key through the emulator, which also scrolls to the prompt.
    func press(_ key: OpenCodeTerminalKey, control: Bool) {
        guard let view = current else { return }
        if key == .control {
            view.controlModifier = control
            return
        }
        let bytes = key.bytes(applicationCursor: view.getTerminal().applicationCursor, control: control)
        view.controlModifier = false
        view.send(bytes)
    }

    func setFocused(_ focused: Bool) {
        guard let view = current else { return }
        if focused { _ = view.becomeFirstResponder() } else { _ = view.resignFirstResponder() }
    }

    /// Pastes the clipboard, bracketed when the running program asked for it.
    func paste() {
        current?.paste(nil)
    }

    /// Drops closed tabs. A closed tab's emulator may still be on screen with the keyboard
    /// up; the container takes it down after the update that shows the next tab.
    func remove(keeping ids: Set<String>) {
        for id in entries.keys where !ids.contains(id) {
            entries[id] = nil
        }
    }

    private static func apply(_ appearance: OpenCodeTerminalAppearance, to view: TerminalView,
                              previous: OpenCodeTerminalAppearance?) {
        if previous?.fontSize != appearance.fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: appearance.fontSize, weight: .regular)
        }
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = appearance.isDark ? .dark : .light
            traits.accessibilityContrast = appearance.increasedContrast ? .high : .normal
        }
        let background = UIColor.systemBackground.resolvedColor(with: traits)
        let foreground = UIColor.label.resolvedColor(with: traits)
        let interaction = UIColor.systemBlue.resolvedColor(with: traits)
        view.backgroundColor = background
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = interaction
        view.selectedTextBackgroundColor = interaction.withAlphaComponent(appearance.isDark ? 0.45 : 0.25)
        view.selectionHandleColor = interaction
        view.indicatorStyle = appearance.isDark ? .white : .black
        view.keyboardAppearance = appearance.isDark ? .dark : .light
        view.installColors(OpenCodeTerminalPalette.colors(for: appearance))
    }
}

/// Hosts the selected tab's emulator; swapping tabs swaps the subview.
final class OpenCodeTerminalContainerView: UIView {
    private weak var hosted: UIView?

    /// Called from `updateUIView`. Moving focus or removing a focused emulator resizes the
    /// keyboard, which lays SwiftUI out again at once; inside an update that is a graph
    /// cycle that hangs the app. So the new tab goes on top now, and focus moves and the
    /// old tab leaves once the update is over.
    func show(_ view: UIView) {
        guard hosted !== view else { return }
        let wasFocused = hosted?.isFirstResponder == true
        if view.superview === self {
            bringSubviewToFront(view)
        } else {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        hosted = view
        DispatchQueue.main.async { [weak self] in
            guard let self, let hosted = self.hosted else { return }
            if wasFocused && !hosted.isFirstResponder { hosted.becomeFirstResponder() }
            for subview in self.subviews where subview !== hosted { subview.removeFromSuperview() }
        }
    }
}

struct OpenCodeTerminalSurface: UIViewRepresentable {
    let session: OpenCodeTerminalSession
    let cache: OpenCodeTerminalViewCache
    let appearance: OpenCodeTerminalAppearance

    func makeUIView(context: Context) -> OpenCodeTerminalContainerView {
        let container = OpenCodeTerminalContainerView()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: OpenCodeTerminalContainerView, context: Context) {
        let view = cache.view(for: session, appearance: appearance)
        container.backgroundColor = view.backgroundColor
        container.show(view)
    }
}
