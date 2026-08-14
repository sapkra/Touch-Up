//
//  GestureInspector.swift
//  Touch Up
//

import Cocoa
import SwiftUI
import TouchUpCore


/// What the readout is currently showing.
///
/// Its own observable object rather than a field on `TouchUp`, and that separation is load-bearing.
/// The settings window observes the model too, so publishing this there redrew the whole of Settings
/// ten times a second — including while a slider was being dragged, which is a change published
/// straight into the middle of a view update.
final class GestureInspectorState: ObservableObject {
    @Published var lines: [String] = []
}


/// A small always-visible readout of what the gesture machinery is deciding, and why.
///
/// Deliberately not the same thing as `DebugOverlay`, which takes over a whole panel to draw the raw
/// contact points and answers "is this screen reporting touches at all, and in the right places". This
/// answers the question after that one: given that the touch arrived, what was it taken to be on, and
/// what did that turn it into. The two are used together — the overlay to check the hardware, this to
/// check the interpretation — so neither replaces the other.
///
/// Everything unusual here has the same cause as in `KeyboardPanel`: this must never take focus, and
/// must never intercept a touch. A debugging aid that changes what it is showing you is worse than no
/// aid at all.
final class GestureInspectorPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func panel(state: GestureInspectorState) -> GestureInspectorPanel {
        let panel = GestureInspectorPanel(contentRect: CGRect(origin: .zero, size: GestureInspectorView.size),
                                          styleMask: [.nonactivatingPanel, .borderless],
                                          backing: .buffered,
                                          defer: true)

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true

        // **The point of the whole thing.** Every touch passes straight through to whatever is
        // underneath, so watching a gesture cannot change it. Without this, the one place you would
        // most want to read — the corner the readout sits in — would be the one place that behaves
        // differently, and the instrument would be measuring itself.
        panel.ignoresMouseEvents = true

        // Above ordinary windows so it stays readable, below `.screenSaver` so it never covers the
        // touch test overlay, which is the other half of debugging this and is often up at the same
        // time.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .none

        panel.contentView = NSHostingView(rootView: GestureInspectorView(state: state))

        return panel
    }
}


/// Owns the panel and the clock that drives it.
///
/// Polled rather than pushed, and that is a deliberate refusal. The obvious wiring — have the core
/// tell us whenever it decides something — puts this readout on the run loop the HID reports arrive
/// on, which is the one place this project has repeatedly paid for putting work. A debugging aid must
/// not be able to change the timing of the thing it is debugging, and a timer cannot.
///
/// Ten times a second is faster than anyone can read and far slower than reports arrive.
final class GestureInspector {

    private weak var model: TouchUp?
    private let state = GestureInspectorState()
    private var panel: GestureInspectorPanel?
    private var timer: Timer?

    /// Which screen the panel is currently on, so it is moved only when that actually changes.
    private var placedScreenNumber: NSNumber?

    init(model: TouchUp) {
        self.model = model
    }

    deinit {
        timer?.invalidate()
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    private func start() {
        let panel = GestureInspectorPanel.panel(state: state)
        self.panel = panel

        refresh()
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = Self.refreshInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        placedScreenNumber = nil
    }

    private static let refreshInterval: TimeInterval = 0.1

    private func refresh() {
        guard let model else { return }
        state.lines = model.touchManager.gestureDebugLines()
        reposition()
    }

    /// Top-trailing corner of whichever screen was touched last, clear of the menu bar.
    ///
    /// The panel has a fixed size, so this moves it only when the user starts touching a different
    /// panel — never because the text inside changed. Sizing it to its contents meant its frame
    /// changed with every log entry, which is to say on every press and every lift: the two moments
    /// at which an unexplained flicker is most likely to be blamed on the gesture rather than on the
    /// thing that was supposed to be reporting it.
    private func reposition() {
        guard let panel, let model else { return }

        let screen = model.touchscreen(forLocationID: model.touchManager.locationIDOfLastTouch)?
            .systemScreen() ?? NSScreen.main
        guard let screen else { return }

        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard number != placedScreenNumber else { return }
        placedScreenNumber = number

        let area = screen.visibleFrame
        let size = GestureInspectorView.size

        panel.setFrame(CGRect(x: area.maxX - size.width - Self.margin,
                              y: area.maxY - size.height - Self.margin,
                              width: size.width,
                              height: size.height),
                       display: true,
                       animate: false)
    }

    private static let margin: CGFloat = 12
}


private struct GestureInspectorView: View {

    @ObservedObject var state: GestureInspectorState

    /// Fixed, so the panel never changes shape while it is being read. Wide enough for a whole
    /// "touch ended" line at this type size, tall enough for the state block plus the eight log
    /// entries the core hands over.
    static let size = CGSize(width: 560, height: 190)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(state.lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 10, weight: isHeading(line) ? .semibold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(isHeading(line) ? Color.white : Color.white.opacity(0.7))
                    .lineLimit(1)
                    // Both ends of a line matter: the gesture is named at the start and the surface
                    // it was decided on at the end, so anything dropped comes out of the middle.
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // Dark and translucent whatever the desktop behind it, so it stays legible over a
                // light document without hiding what it is sitting on top of.
                .fill(Color.black.opacity(0.75))
        )
    }

    /// The state block at the top, as opposed to the gesture log below it. Told apart by indentation,
    /// which is how the log already marks its own continuation lines.
    private func isHeading(_ line: String) -> Bool {
        !line.hasPrefix(" ") && !line.isEmpty
    }
}
