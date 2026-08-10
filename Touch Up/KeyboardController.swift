//
//  KeyboardController.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 10.08.26.
//

import AppKit
import Carbon.HIToolbox
import Combine
import TouchUpCore


/// Runs the on-screen keyboard: where it is, whether it is showing, which modifiers it is holding,
/// and what each key press turns into.
final class KeyboardController: ObservableObject {

    private unowned let model: TouchUp

    private var panel: KeyboardPanel?

    @Published private(set) var isVisible = false

    /// Modifiers the user has pressed and not yet spent. Held here rather than in the framework,
    /// because whether Shift survives the next key is a question about how a keyboard behaves.
    @Published private(set) var heldModifiers: Set<ModifierKey> = []

    /// Keeps the keyboard up regardless of what the focus does. The escape hatch for applications
    /// that never report losing focus, and the reason the automatic side is allowed to be a heuristic.
    @Published var isPinned = false

    /// Set while macOS is refusing injected keystrokes, so the keys can say so instead of appearing
    /// to work.
    @Published private(set) var isSecureInputBlocking = false


    /// Notices when a text field takes focus in any application. Kept here rather than in the model
    /// because nothing else has a use for it.
    private let focusWatcher = FocusWatcher()

    /// When a key was last pressed. A field that stops reporting focus for a moment while it takes a
    /// keystroke must not be allowed to close the keyboard mid-word.
    private var timeOfLastKeyPress: Date = .distantPast


    private var observers = [AnyCancellable]()


    init(model: TouchUp) {
        self.model = model

        focusWatcher.onChange = { [weak self] focus in
            self?.focusDidChange(to: focus)
        }

        // Switching input source can change how many keys there are, not just what is written on them
        // — the key beside the left Shift exists on an ISO layout and not on an ANSI one. The panel's
        // frame is computed from the arrangement, so it has to be recomputed when the arrangement
        // changes, or the keys and the window it sits in stop agreeing.
        observers.append(
            KeyboardLayout.shared.$captions
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.repositionIfVisible() }
        )
    }


    /// Whether the keyboard should open by itself when something typeable takes focus.
    var isAutomatic: Bool {
        get { focusWatcher.isEnabled }
        set { focusWatcher.isEnabled = newValue }
    }

    private func focusDidChange(to focus: AXFocusProbe?) {
        guard focus != nil else {
            // Pinned means the user has said to leave it alone, whatever the focus does.
            guard !isPinned else { return }

            // Applications commonly report no focused element for a moment while they process a
            // keystroke, and closing the keyboard someone is typing on is the worst thing this could
            // do.
            let sinceKeyPress = Date().timeIntervalSince(timeOfLastKeyPress)
            if sinceKeyPress <= Self.keystrokeGracePeriod {
                // Deferred rather than dropped. The watcher has already recorded that it told us, so
                // it will not say the same thing twice — a hide abandoned here would leave the
                // keyboard up until the focus next changed, which could be never. If the user is
                // genuinely still typing, the next keystroke pushes this out again, which is right.
                //
                // Asked again on the way through, because by then a field may well have taken focus:
                // acting on a report this stale would close a keyboard the user had just been given.
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + (Self.keystrokeGracePeriod - sinceKeyPress)
                ) { [weak self] in
                    guard let self, !self.focusWatcher.isEditableFocused else { return }
                    self.focusDidChange(to: nil)
                }
                return
            }

            hide()
            return
        }

        show()
    }

    private static let keystrokeGracePeriod: TimeInterval = 0.4


    // MARK: - Showing and hiding

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // The setting is what makes the keyboard available at all; without this, both the menu item
        // and a focus change could put one on screen after the user had turned the feature off.
        guard model.isOnScreenKeyboardEnabled else { return }
        guard let target = targetScreen else { return }

        isSecureInputBlocking = TUCKeyboardTyper.sharedInstance().isSecureInputActive

        let metrics = metrics(for: target)
        let panel = self.panel ?? KeyboardPanel.panel(controller: self, metrics: metrics)
        self.panel = panel

        panel.updateContent(controller: self, metrics: metrics)
        panel.place(on: target.system,
                    metrics: metrics,
                    rows: KeyboardLayout.shared.rows,
                    showingNotice: isSecureInputBlocking)
        panel.makeVisible()

        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false

        // A modifier left engaged would apply to the first key of the next thing typed, long after
        // the user pressed it and with no keyboard on screen to show that it is still down.
        heldModifiers.removeAll()
    }

    /// Moves the keyboard to wherever it now belongs, if it is showing. Called when the displays
    /// change and when a finger lands on a different panel.
    func repositionIfVisible() {
        guard isVisible else { return }

        guard let target = targetScreen else {
            // The display it was on has gone and nothing has replaced it.
            hide()
            return
        }

        let metrics = metrics(for: target)
        panel?.updateContent(controller: self, metrics: metrics)
        panel?.place(on: target.system,
                     metrics: metrics,
                     rows: KeyboardLayout.shared.rows,
                     showingNotice: isSecureInputBlocking)
    }

    /// The user put a finger on a different panel.
    ///
    /// Coalesced for two reasons. One stray touch on another screen in the middle of a sentence should
    /// not make the keyboard hop away from the one being typed on — and this arrives from inside the
    /// HID report handler, where rebuilding a window is not work that belongs.
    func lastTouchedScreenDidChange() {
        guard isVisible else { return }

        pendingReposition?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.pendingReposition = nil
            self?.repositionIfVisible()
        }
        pendingReposition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.repositionDelay, execute: work)
    }

    private var pendingReposition: DispatchWorkItem?
    private static let repositionDelay: TimeInterval = 0.25

    private func metrics(for target: (system: NSScreen, pointsPerMillimetre: CGFloat)) -> KeyboardMetrics {
        KeyboardMetrics.fitting(rows: KeyboardLayout.shared.rows,
                                pointsPerMillimetre: target.pointsPerMillimetre,
                                availableSize: KeyboardPanel.availableSize(on: target.system),
                                showingNotice: isSecureInputBlocking)
    }


    // MARK: - Placement

    /// Where the keyboard belongs: the display the user last touched, since that is where their hands
    /// are. Falls back the same way the digitizer mapping does, for a keyboard opened from the menu
    /// bar before anything has been touched.
    ///
    /// Both screens are carried because both are needed and neither substitutes for the other: the
    /// `NSScreen` gives the frame to place the panel in, and only the `TUCScreen` knows how large the
    /// panel is in millimetres, which is what the keys are sized against.
    private var targetScreen: (system: NSScreen, pointsPerMillimetre: CGFloat)? {
        let locationID = model.touchManager.locationIDOfLastTouch

        if locationID != 0,
           let touched = model.resolvedMapping(forLocationID: locationID).screen,
           let system = touched.systemScreen() {
            return (system, touched.pixelsPerMM())
        }

        if let newest = model.newestScreen, let system = newest.systemScreen() {
            return (system, newest.pixelsPerMM())
        }

        // No touchscreen has ever been mapped. The keys land on a sensible size anyway: this is the
        // same figure `TUCScreen` falls back to when a panel reports a nonsense physical size.
        return NSScreen.main.map { ($0, KeyboardMetrics.assumedPointsPerMillimetre) }
    }


    // MARK: - Keys

    var isShiftHeld: Bool {
        heldModifiers.contains(.shift)
    }

    var isCapsLocked: Bool {
        heldModifiers.contains(.capsLock)
    }

    func isEngaged(_ cap: KeyCap) -> Bool {
        switch cap {
        case .modifier(let key): return heldModifiers.contains(key)
        case .pin:               return isPinned
        default:                 return false
        }
    }

    func press(_ cap: KeyCap) {
        switch cap {
        case .modifier(let key):
            // Pressing an engaged modifier lets go of it again, which is the only way to undo a
            // mistaken Command on a keyboard with no physical keys to release.
            if heldModifiers.contains(key) {
                heldModifiers.remove(key)
            } else {
                heldModifiers.insert(key)
            }

        case .pin:
            isPinned.toggle()

        case .dismiss:
            // Putting the keyboard away also lets go of the pin: having asked for it to be gone, being
            // handed a keyboard that then refuses to close itself again would be the wrong surprise.
            isPinned = false
            hide()

        case .space:
            send(keyCode: CGKeyCode(kVK_Space))

        case .control(let key):
            send(keyCode: key.keyCode)

        case .character(let keyCode):
            send(keyCode: keyCode)
        }
    }

    // MARK: - Diagnostics

    /// Roles and state only, never anything that was typed — the report goes on the clipboard.
    var diagnosticsDescription: String {
        var lines = ["───── On-screen keyboard ─────"]

        lines.append("Showing: \(isVisible ? "yes" : "no")\(isPinned ? " (pinned open)" : "")")
        lines.append("Layout: \(KeyboardLayout.shared.sourceName), "
                     + "\(KeyboardLayout.shared.rows.map(\.count).reduce(0, +)) keys")

        if let panel, isVisible {
            let screen = panel.screen?.localizedName ?? "unknown screen"
            lines.append("Placed on: \(screen) at \(NSStringFromRect(panel.frame))")
        }

        // Asked only when something really has been touched: `resolvedMapping` falls back to the
        // newest screen for an unknown digitizer, so passing it 0 would name a panel nobody touched.
        let lastTouched = model.touchManager.locationIDOfLastTouch
        if lastTouched != 0, let touched = model.resolvedMapping(forLocationID: lastTouched).screen {
            lines.append("Last touched panel: \(touched.name)")
        } else {
            lines.append("Last touched panel: none yet")
        }

        if isSecureInputBlocking {
            lines.append("Secure input is ON — macOS is discarding injected keystrokes.")
        }

        return lines.joined(separator: "\n") + "\n" + focusWatcher.diagnosticsDescription + "\n"
    }


    private func send(keyCode: CGKeyCode) {
        timeOfLastKeyPress = Date()

        // Checked per press rather than on a timer: secure input is switched on by a field taking
        // focus, so a press is exactly when the answer can have changed.
        let wasBlocking = isSecureInputBlocking
        isSecureInputBlocking = TUCKeyboardTyper.sharedInstance().isSecureInputActive

        // The notice takes up room the panel has to be given, so a change in it changes the frame.
        if isSecureInputBlocking != wasBlocking {
            repositionIfVisible()
        }

        let flags = heldModifiers.reduce(CGEventFlags()) { $0.union($1.flag) }
        TUCKeyboardTyper.sharedInstance().press(keyCode: keyCode, modifiers: flags)

        // Shift and the rest apply to one key and then let go, the way holding a key on hardware
        // does. Caps Lock latches, as it does there too.
        heldModifiers = heldModifiers.filter { $0.latches }
    }
}
