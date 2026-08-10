//
//  KeyboardPanel.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 10.08.26.
//

import Cocoa
import SwiftUI


/// The window the on-screen keyboard lives in.
///
/// Everything unusual about it serves one requirement: typing must not disturb the application being
/// typed into. A window that takes key status resigns the target application's, and most applications
/// visibly drop the insertion point when that happens — so the keyboard would clear the very field it
/// exists to fill in.
///
/// Unlike the settings and debug windows, this must never call `NSApp.activate(ignoringOtherApps:)`.
final class KeyboardPanel: NSPanel {

    /// `.nonactivatingPanel` already stops a click here from activating Touch Up. These stop the
    /// panel taking key status even when something inside it would accept text, which nothing does:
    /// the keys are pressed, never typed into.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }


    static func panel(controller: KeyboardController, metrics: KeyboardMetrics) -> KeyboardPanel {
        let panel = KeyboardPanel(contentRect: .zero,
                                  styleMask: [.nonactivatingPanel, .borderless],
                                  backing: .buffered,
                                  defer: true)

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        // Touch Up is never the active application, so a panel that hid on deactivation would never
        // be visible at all.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Usable over another application's modal sheet, which is exactly where a password or a file
        // name has to be typed.
        panel.worksWhenModal = true

        // Above the Dock, which sits at level 20 and would otherwise cover the bottom row of keys —
        // the keyboard is pinned to the same edge the Dock slides out of. Deliberately not
        // `.screenSaver`, which the settings and debug windows use: that level would put the keyboard
        // over an open menu, so a context menu would appear behind it.
        panel.level = .popUpMenu

        // Stay put when the user switches Spaces, and remain over a full-screen application.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // A finger that slides while pressing a key must not carry the keyboard off the screen.
        panel.isMovableByWindowBackground = false
        panel.isMovable = false

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .utilityWindow
        panel.acceptsMouseMovedEvents = false

        panel.contentView = FirstMouseHostingView(
            rootView: KeyboardView(layout: .shared, controller: controller, metrics: metrics))

        return panel
    }


    /// Puts the keyboard along the bottom edge of `screen`, centred.
    ///
    /// `visibleFrame` rather than `frame`, so the keyboard clears a Dock that is showing instead of
    /// sitting underneath it.
    func place(on screen: NSScreen, metrics: KeyboardMetrics, rows: [[KeyCap]], showingNotice: Bool) {
        let size = metrics.size(of: rows, showingNotice: showingNotice)
        let available = screen.visibleFrame

        let width = min(size.width, available.width - 2 * Self.screenMargin)
        let height = min(size.height, available.height * Self.maximumHeightFraction)

        setFrame(CGRect(x: available.midX - width / 2,
                        y: available.minY + Self.screenMargin,
                        width: width,
                        height: height),
                 display: true,
                 animate: false)
    }

    static let screenMargin: CGFloat = 8

    /// A keyboard is worth covering some of the screen for, but not most of it.
    static let maximumHeightFraction: CGFloat = 0.45

    /// The room the keyboard has to fit into on a given display. The metrics size the keys against
    /// this, so the two must agree — hence one definition, used by both.
    static func availableSize(on screen: NSScreen) -> CGSize {
        CGSize(width: max(0, screen.visibleFrame.width - 2 * screenMargin),
               height: max(0, screen.visibleFrame.height * maximumHeightFraction))
    }


    func makeVisible() {
        // Not `makeKeyAndOrderFront:` — see the class comment. `orderFrontRegardless` shows the panel
        // without asking to be activated, which is what an inactive application has to do.
        orderFrontRegardless()
    }


    /// Rebuilds the hosted view, for when the metrics change with the display the keyboard is on.
    func updateContent(controller: KeyboardController, metrics: KeyboardMetrics) {
        if let host = contentView as? FirstMouseHostingView<KeyboardView> {
            host.rootView = KeyboardView(layout: .shared, controller: controller, metrics: metrics)
        }
    }
}


/// Hosts the keys and, crucially, accepts the click that arrives while Touch Up is not the active
/// application. `NSHostingView` says no to that by default, which would cost the user the first key
/// of everything they type.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
