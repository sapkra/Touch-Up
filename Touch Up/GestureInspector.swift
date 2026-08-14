//
//  GestureInspector.swift
//  Touch Up
//

import Cocoa
import SwiftUI
import TouchUpCore


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

    static func panel(model: TouchUp) -> GestureInspectorPanel {
        let panel = GestureInspectorPanel(contentRect: .zero,
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

        panel.contentView = NSHostingView(rootView: GestureInspectorView(model: model))

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
    private var panel: GestureInspectorPanel?
    private var timer: Timer?

    init(model: TouchUp) {
        self.model = model
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    private func start() {
        guard let model else { return }

        let panel = GestureInspectorPanel.panel(model: model)
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = Self.refreshInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refresh()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static let refreshInterval: TimeInterval = 0.1

    private func refresh() {
        guard let model else { return }
        model.gestureDebugLines = model.touchManager.gestureDebugLines()

        // Follows the glass being used. On a machine with more than one panel a readout stranded on
        // the display you are not standing in front of is no readout at all — the same reason the
        // on-screen keyboard moves.
        reposition()
    }

    /// Top-trailing corner of whichever screen was touched last, clear of the menu bar.
    private func reposition() {
        guard let panel, let model else { return }

        let screen = model.touchscreen(forLocationID: model.touchManager.locationIDOfLastTouch)?
            .systemScreen() ?? NSScreen.main
        guard let screen else { return }

        let area = screen.visibleFrame
        let height = max(panel.contentView?.fittingSize.height ?? 200, 1)
        let width = GestureInspectorView.width

        let frame = CGRect(x: area.maxX - width - Self.margin,
                           y: area.maxY - height - Self.margin,
                           width: width,
                           height: height)

        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    private static let margin: CGFloat = 12
}


private struct GestureInspectorView: View {

    @ObservedObject var model: TouchUp

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.gestureDebugLines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 10, weight: isHeading(line) ? .semibold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(isHeading(line) ? .primary : .secondary)
                    .lineLimit(1)
                    // Both ends of a line matter: the gesture is named at the start and the surface
                    // it was decided on at the end, so anything dropped has to come out of the
                    // middle.
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        // A fixed width, not one that fits the content. The lines change on every touch, and a panel
        // that resized to each of them would twitch continuously in the corner of your eye while you
        // are trying to watch the screen.
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // Dark and translucent whatever the desktop behind it, so it stays legible over a
                // light document without hiding what it is sitting on top of.
                .fill(Color.black.opacity(0.75))
        )
    }

    /// Wide enough for a whole "touch ended" line at this size, which is the longest thing the log
    /// produces.
    static let width: CGFloat = 560

    /// The state block at the top, as opposed to the gesture log below it. Told apart by indentation,
    /// which is how the log already marks its own continuation lines.
    private func isHeading(_ line: String) -> Bool {
        !line.hasPrefix(" ") && !line.isEmpty
    }
}
