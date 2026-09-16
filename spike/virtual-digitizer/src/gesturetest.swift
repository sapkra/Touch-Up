// Oracle 2: does a gesture recognizer actually receive direct touches?
//
// TN3212: gesture recognizers are the only path for Sidecar-style direct touch —
// not the responder chain, not event monitors. So this logs both: what the
// recognizers see, and (to confirm the documented behaviour) that touchesBegan
// does not fire.
import AppKit

final class TouchView: NSView {
    var log: (String) -> Void = { _ in }

    override func touchesBegan(with event: NSEvent) {
        // Expected never to fire for direct touches. If it does, that is a finding.
        log("touchesBegan (responder chain) — \(event.allTouches().count) touches")
        super.touchesBegan(with: event)
    }

    /// Which kind of event drove a recognizer callback.
    ///
    /// This matters more than it looks: NSClickGestureRecognizer fires for an ordinary
    /// mouse click too, so without this a stray click on the window reads as "native
    /// touch works". NSEventTypeDirectTouch is 37.
    private func source() -> String {
        guard let event = NSApp.currentEvent else { return "SOURCE=unknown" }
        if event.type.rawValue == 37 { return "SOURCE=directTouch" }
        return "SOURCE=mouse(type=\(event.type.rawValue))"
    }

    @objc func handleClick(_ g: NSClickGestureRecognizer) {
        log("CLICK recognizer fired at \(g.location(in: self)) \(source())")
    }

    @objc func handlePan(_ g: NSPanGestureRecognizer) {
        log("PAN recognizer \(g.state.rawValue) at \(g.location(in: self)) translation \(g.translation(in: self)) \(source())")
    }

    override func mouseDown(with event: NSEvent) {
        // AppKit's automatic mouse emulation shows up here for non-touch-native views.
        log("mouseDown (emulated?) at \(event.locationInWindow)")
    }

    override func scrollWheel(with event: NSEvent) {
        log("scrollWheel phase=\(event.phase.rawValue) dy=\(event.scrollingDeltaY)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                      styleMask: [.titled, .closable, .resizable],
                      backing: .buffered, defer: false)
window.title = "Touch Up — gesture oracle"

let view = TouchView(frame: window.contentLayoutRect)
view.autoresizingMask = [.width, .height]
view.log = { message in
    print("[gesture] \(message)")
    fflush(stdout)
}

let click = NSClickGestureRecognizer(target: view, action: #selector(TouchView.handleClick(_:)))
let pan = NSPanGestureRecognizer(target: view, action: #selector(TouchView.handlePan(_:)))
pan.minimumNumberOfTouches = 1
pan.maximumNumberOfTouches = 3
view.addGestureRecognizer(click)
view.addGestureRecognizer(pan)

window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

print("[gesture] window up; recognizers installed (click, pan). allowedTouchTypes: click=\(click.allowedTouchTypes.rawValue) pan=\(pan.allowedTouchTypes.rawValue)")
fflush(stdout)

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60
Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
    print("[gesture] done")
    fflush(stdout)
    app.terminate(nil)
}
app.run()
