//
//  KeyboardView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 10.08.26.
//

import SwiftUI


/// How big the keys are, in points.
///
/// Keys are sized in millimetres and then converted, rather than as a fraction of the display: a
/// fingertip is the same size on a 7 inch panel as on a 32 inch one, and a key scaled to the screen
/// would be uselessly small on the first and absurd on the second.
struct KeyboardMetrics {

    /// Centre-to-centre spacing of an ordinary key.
    let keyPitch: CGFloat

    /// Roughly the width of a fingertip with somewhere to miss. Apple's own hardware keys are close
    /// to 16 mm apart; a little under that is comfortable and keeps the whole keyboard in reach.
    static let preferredKeyPitchInMillimetres: CGFloat = 14

    /// Below this a key is smaller than the finger pressing it. Above it the keyboard stops reading
    /// as a keyboard and starts reading as a grid of tiles.
    static let keyPitchRange: ClosedRange<CGFloat> = 34...92

    /// Never let a key be smaller than this, even to make the keyboard fit. Past here it stops being
    /// operable by finger at all, and a keyboard running off the edge of a tiny display is the lesser
    /// of the two failures.
    static let absoluteMinimumKeyPitch: CGFloat = 20

    private init(keyPitch: CGFloat) {
        self.keyPitch = keyPitch
    }

    /// The largest keys that both suit a fingertip and fit on the panel.
    ///
    /// Fitting is not optional. A 7 inch 800 × 480 touchscreen — squarely what this app exists for —
    /// works out at around 5 points per millimetre, which would ask for 70 point keys and a keyboard
    /// half again as wide as the screen. Sized from the finger alone, the right-hand keys would simply
    /// be cut off, and nothing on screen would explain why.
    static func fitting(rows: [[KeyCap]],
                        pointsPerMillimetre: CGFloat,
                        availableSize: CGSize,
                        showingNotice: Bool) -> KeyboardMetrics {
        // A screen that reports a nonsense physical size can produce a non-finite figure here. Left
        // alone it would propagate into the panel's frame, and AppKit raises on a frame that is not a
        // number rather than ignoring it.
        let density = pointsPerMillimetre.isFinite && pointsPerMillimetre > 0
            ? pointsPerMillimetre
            : assumedPointsPerMillimetre

        let fromFinger = preferredKeyPitchInMillimetres * density
        let preferred = min(max(fromFinger, keyPitchRange.lowerBound), keyPitchRange.upperBound)

        // Every length in here is a fixed multiple of the pitch, so the whole keyboard scales linearly
        // with it and the pitch that exactly fills a given extent can be divided out.
        let unfitted = KeyboardMetrics(keyPitch: 1)
        let size = unfitted.size(of: rows, showingNotice: showingNotice)

        let toFitWidth = size.width > 0 ? availableSize.width / size.width : preferred
        let toFitHeight = size.height > 0 ? availableSize.height / size.height : preferred

        let fitted = min(preferred, toFitWidth, toFitHeight)
        return KeyboardMetrics(keyPitch: max(fitted, absoluteMinimumKeyPitch))
    }

    /// The density `TUCScreen` itself assumes when a panel reports no usable physical size — about
    /// 100 dpi, an ordinary non-Retina desktop display.
    static let assumedPointsPerMillimetre: CGFloat = 4

    var gap: CGFloat { keyPitch * 0.08 }
    var padding: CGFloat { keyPitch * 0.22 }
    var keyHeight: CGFloat { keyPitch * 0.86 }
    var cornerRadius: CGFloat { keyPitch * 0.16 }
    var fontSize: CGFloat { keyPitch * 0.36 }

    func width(of cap: KeyCap) -> CGFloat {
        keyPitch * Self.widthInKeys(of: cap) + gap * (Self.widthInKeys(of: cap) - 1)
    }

    /// How many ordinary keys wide a cap is. The proportions are the ones a hardware keyboard uses,
    /// which is what makes the rows line up into something recognisable rather than a grid.
    private static func widthInKeys(of cap: KeyCap) -> CGFloat {
        switch cap {
        // Narrower than a hardware space bar, so the bottom row — which carries the modifiers, the
        // arrows and the two keys for the keyboard itself — does not end up wider than the letter
        // rows. The widest row sets the size of every key, so a sprawling bottom row would shrink
        // the letters for nothing.
        case .space:                return 4
        case .control(.return):     return 1.75
        case .modifier(.capsLock):  return 1.75
        case .control(.delete):     return 1.5
        case .control(.tab):        return 1.5
        case .modifier(.shift):     return 1.5
        case .modifier:             return 1.25
        case .pin, .dismiss:        return 1.25
        default:                    return 1
        }
    }

    /// Two lines of explanation, when there is any to give. Counted into the panel's height rather
    /// than laid over the keys, so the notice cannot end up cropped off the bottom of the screen.
    var noticeHeight: CGFloat { fontSize * 0.8 * 2.6 + gap }

    func size(of rows: [[KeyCap]], showingNotice: Bool = false) -> CGSize {
        let widest = rows.map { row in
            row.reduce(0) { $0 + width(of: $1) } + gap * CGFloat(max(0, row.count - 1))
        }.max() ?? 0

        return CGSize(width: widest + 2 * padding,
                      height: CGFloat(rows.count) * keyHeight
                            + gap * CGFloat(max(0, rows.count - 1))
                            + (showingNotice ? noticeHeight : 0)
                            + 2 * padding)
    }
}


struct KeyboardView: View {

    @ObservedObject var layout: KeyboardLayout
    @ObservedObject var controller: KeyboardController

    let metrics: KeyboardMetrics

    var body: some View {
        VStack(spacing: metrics.gap) {
            if controller.isSecureInputBlocking {
                secureInputNotice
            }

            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: metrics.gap) {
                    // Indexed rather than keyed by the key itself: a row can hold the same cap twice
                    // — Shift sits at both ends of one — and identical identities would collapse them.
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cap in
                        KeyCapView(cap: cap,
                                   caption: caption(for: cap),
                                   isEngaged: controller.isEngaged(cap),
                                   metrics: metrics,
                                   action: { controller.press(cap) })
                    }
                }
            }
        }
        .padding(metrics.padding)
        .background(
            RoundedRectangle(cornerRadius: metrics.cornerRadius * 1.6, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        )
    }

    /// Said plainly, because the alternative is a user pressing keys into a field that will never
    /// receive them and concluding the app is broken.
    ///
    /// Given exactly the height the panel was sized for, and allowed to shrink its text to stay
    /// inside it. The panel's frame is computed rather than measured, so anything here that could
    /// grow taller than expected would be clipped instead of scrolled.
    private var secureInputNotice: some View {
        Text("macOS will not let an on-screen keyboard type into this field.")
            .font(.system(size: metrics.fontSize * 0.8))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .frame(height: metrics.noticeHeight - metrics.gap)
    }

    private func caption(for cap: KeyCap) -> String {
        switch cap {
        case .character(let keyCode):
            return layout.caption(for: keyCode,
                                  shifted: controller.isShiftHeld,
                                  capsLocked: controller.isCapsLocked)
        case .control(let key):
            return key.label
        case .modifier(let key):
            return key.label
        case .space, .dismiss, .pin:
            // Drawn as symbols rather than captions.
            return ""
        }
    }
}


private struct KeyCapView: View {

    let cap: KeyCap
    let caption: String
    let isEngaged: Bool
    let metrics: KeyboardMetrics
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(fill)

            if case .pin = cap {
                Image(systemName: isEngaged ? "pin.fill" : "pin")
                    .font(.system(size: metrics.fontSize))
            } else if case .dismiss = cap {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: metrics.fontSize))
            } else {
                Text(caption)
                    .font(.system(size: metrics.fontSize, weight: .regular, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundColor(isEngaged ? Color(nsColor: .selectedMenuItemTextColor) : Color(nsColor: .labelColor))
        .frame(width: metrics.width(of: cap), height: metrics.keyHeight)
        .overlay(
            KeyPressCatcher(onPress: {
                action()
                flashPressed()
            })
        )
    }

    /// Shows the press for a fixed moment rather than following the mouse button down and up.
    ///
    /// The release cannot be relied on. A key fires on the press — including on a right press, which
    /// is how a slow finger arrives — and the matching release may be a different button, or may never
    /// come at all if the digitizer drops the touch. Tying the highlight to it would leave keys stuck
    /// looking held down with no way back.
    private func flashPressed() {
        isPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressFlashDuration) {
            isPressed = false
        }
    }

    private static let pressFlashDuration: TimeInterval = 0.12

    private var fill: Color {
        if isPressed { return Color(nsColor: .controlAccentColor).opacity(0.6) }
        if isEngaged { return Color(nsColor: .controlAccentColor) }
        return Color(nsColor: .controlColor)
    }
}


/// Catches the tap on a key.
///
/// Three things make this a plain `NSView` rather than a `Button`:
///
/// - A key has to fire when the finger lands, not when it lifts. Touch Up decides what a touch was
///   only once it ends, and a touch held still long enough turns into a long press — which is a
///   secondary click, and never produces a click at all. A key that waited for the click would
///   silently do nothing every time somebody pressed it slowly.
/// - That same long press is why `rightMouseDown` types too. It costs one line and rescues every
///   unhurried press.
/// - `acceptsFirstMouse` has to be YES. Touch Up is never the active application — that is the whole
///   point of the panel this sits in — and AppKit swallows the first click into an inactive app's
///   window unless the view asks for it. Without this, the first key pressed after touching anything
///   else does nothing.
private struct KeyPressCatcher: NSViewRepresentable {

    let onPress: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onPress = onPress
    }

    final class CatcherView: NSView {
        var onPress: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // No `super`, and no tracking loop: a tracking loop would park the main run loop waiting for
        // the matching mouse-up, and the HID reports that drive the whole app arrive on that loop.
        override func mouseDown(with event: NSEvent) {
            onPress?()
        }

        override func rightMouseDown(with event: NSEvent) {
            onPress?()
        }

        // Swallowed so they are not passed up the responder chain, but nothing is done with them: a
        // key has already fired by the time the finger lifts.
        override func mouseUp(with event: NSEvent) {}
        override func rightMouseUp(with event: NSEvent) {}
    }
}
