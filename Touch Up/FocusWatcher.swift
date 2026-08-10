//
//  FocusWatcher.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 10.08.26.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox


/// What the Accessibility API can tell us about the control that currently has keyboard focus,
/// in whichever application is frontmost.
///
/// This is the foundation an on-screen keyboard needs: a keyboard that has to be summoned by hand
/// every time is barely worth having, so something has to notice that a text field was tapped. The
/// only way to learn that about another application is to ask it over the Accessibility API.
///
/// It is a `struct` of plain values rather than a live `AXUIElement` on purpose: everything here is
/// safe to put in a diagnostics report, and nothing here holds a reference into another process.
struct AXFocusProbe {

    /// The result of asking. Anything other than `.success` means the answer below is unknown
    /// rather than negative — see `Verdict.unreadable`.
    let error: AXError

    let role: String?
    let subrole: String?

    /// Whether the element would let a value be written into it. The strongest hint available that
    /// something is a text field when its role is unhelpful, which is common in web content.
    let isValueSettable: Bool

    /// Which application the focused element belongs to. Kept because "it works everywhere except
    /// in one app" is the shape almost every report of this feature failing will take.
    let ownerBundleID: String?

    /// Whether macOS is currently swallowing injected keystrokes. Read here because it belongs to
    /// the same question — "can the user type into this?" — and is otherwise invisible.
    let isSecureInputActive: Bool


    enum Verdict {
        /// A role we recognise as accepting typing.
        case editable
        /// Not a role we recognise, but it accepts a value being written — most likely a text
        /// field in web content or a custom editor.
        case probablyEditable
        /// Read successfully, and it does not take typing.
        case notEditable
        /// The read failed. Distinct from `notEditable`, and the distinction matters: treating a
        /// failed read as "no text field here" would make the keyboard flicker away whenever an
        /// application is merely busy.
        case unreadable
    }

    /// Roles that unambiguously accept typed text.
    ///
    /// `AXComboBox` is included because its text portion is editable in most implementations, and a
    /// keyboard that refuses to open on the one field the user tapped is worse than one that opens
    /// where it is not strictly needed.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        "AXSearchField",        // a role in some applications, a subrole in others
        "AXSecureTextField",    // ditto
    ]

    /// Controls that are unmistakably not typed into.
    ///
    /// This list exists because a settable value is not by itself evidence of a text field: a slider,
    /// a stepper and a checkbox all have one. Without it, tabbing onto a volume slider would raise a
    /// keyboard.
    private static let uneditableRoles: Set<String> = [
        kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXSliderRole, kAXIncrementorRole, kAXColorWellRole, kAXDisclosureTriangleRole,
        kAXScrollBarRole, kAXTableRole, kAXOutlineRole, kAXRowRole, kAXCellRole, kAXImageRole,
        kAXStaticTextRole, kAXMenuRole, kAXMenuItemRole, kAXToolbarRole, kAXTabGroupRole,
        kAXProgressIndicatorRole, kAXSplitterRole,
        // Named rather than taken from a constant: neither of these has one in the SDK headers.
        "AXStepper", "AXLink",
    ]

    var verdict: Verdict {
        switch error {
        case .success:
            break

        // These are answers, not failures. `noValue` in particular is the ordinary case for tapping
        // somewhere with nothing to focus — the desktop, a window's background — and it is the most
        // common way a text field stops being the focus at all. Reading it as "unknown" would mean
        // the keyboard never closed by itself in exactly the situation the user expects it to.
        case .noValue, .attributeUnsupported, .notImplemented:
            return .notEditable

        // Everything else — a timeout, a stale element, permission withheld — leaves the question
        // unanswered.
        default:
            return .unreadable
        }

        guard let role else { return .unreadable }

        if Self.editableRoles.contains(role) { return .editable }
        // Many applications express "search field" and "password field" as subroles of a plain
        // text field, so the subrole has to be consulted separately rather than as a fallback.
        if let subrole, Self.editableRoles.contains(subrole) { return .editable }

        if Self.uneditableRoles.contains(role) { return .notEditable }

        // Left over: roles this does not recognise. A settable value is worth something here, since
        // this is where a text field in web content or a custom editor with an invented role lands.
        if isValueSettable { return .probablyEditable }

        return .notEditable
    }
}


extension AXFocusProbe {

    /// Asks the system what has focus, right now.
    ///
    /// Nothing here is expensive — a handful of interprocess reads — but every one of them is a
    /// synchronous round trip into another application, which is why the timeout below is not
    /// optional.
    ///
    /// `coaxing` is called with the frontmost application's process when nothing could be read from
    /// it, giving the caller a chance to ask that application to expose an accessibility tree at all.
    static func probeFocusedElement(coaxing: ((pid_t) -> Void)? = nil) -> AXFocusProbe {
        let secureInput = IsSecureEventInputEnabled()

        let systemWide = AXUIElementCreateSystemWide()

        // Touch Up is a driver: if a hung application can hold up a reply, it holds up the run loop
        // that the HID reports arrive on, and the touchscreen stops responding. That is a far worse
        // failure than not knowing where the focus is, so cap the wait.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide,
                                                  kAXFocusedUIElementAttribute as CFString,
                                                  &focused)

        // Checked by type rather than force-cast. The attribute is documented to hold an element, but
        // this reads whatever an arbitrary third-party application chose to put there, and a forced
        // cast on a bad answer would take the whole driver down with it.
        guard error == .success,
              let value = focused,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            // An application that answers nothing may simply not have built an accessibility tree
            // yet — the usual case for anything built on Electron — so give the caller its chance to
            // ask for one before concluding there is nothing here.
            if let coaxing, let frontmost = NSWorkspace.shared.frontmostApplication {
                coaxing(frontmost.processIdentifier)
            }

            return AXFocusProbe(error: error,
                                role: nil,
                                subrole: nil,
                                isValueSettable: false,
                                ownerBundleID: nil,
                                isSecureInputActive: secureInput)
        }

        let element = value as! AXUIElement   // safe: the type was just checked

        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable)

        return AXFocusProbe(error: .success,
                            role: element.stringAttribute(kAXRoleAttribute),
                            subrole: element.stringAttribute(kAXSubroleAttribute),
                            isValueSettable: isSettable.boolValue,
                            ownerBundleID: element.owningBundleIdentifier,
                            isSecureInputActive: secureInput)
    }


    /// A block for the diagnostics report. Roles and identifiers only — never the value of the
    /// field, which is the user's text and in a password field is their password.
    var diagnosticsDescription: String {
        var lines = ["───── Focused element ─────"]

        switch error {
        case .success:
            lines.append("AX read: ok")
        case .apiDisabled:
            lines.append("AX read: FAILED — Accessibility is not granted to this build of Touch Up. "
                         + "The permission is remembered per app signature, so a rebuild can lose it.")
        default:
            lines.append("AX read: FAILED — \(Self.name(for: error))")
        }

        if error == .success {
            lines.append("Owner: \(ownerBundleID ?? "unknown")")
            lines.append("Role: \(role ?? "none")\(subrole.map { " / \($0)" } ?? "")")
            lines.append("Value settable: \(isValueSettable ? "yes" : "no")")
        }

        lines.append("Verdict: \(Self.name(for: verdict))")

        if isSecureInputActive {
            lines.append("Secure input is ON — macOS discards injected keystrokes while it is.")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func name(for verdict: Verdict) -> String {
        switch verdict {
        case .editable:         return "takes typing"
        case .probablyEditable: return "probably takes typing (no matching role, but accepts a value)"
        case .notEditable:      return "does not take typing"
        case .unreadable:       return "unknown — nothing could be read"
        }
    }

    private static func name(for error: AXError) -> String {
        switch error {
        case .success:                return "success (0)"
        case .failure:                return "failure (-25200)"
        case .illegalArgument:        return "illegalArgument (-25201)"
        case .invalidUIElement:       return "invalidUIElement (-25202)"
        case .invalidUIElementObserver: return "invalidUIElementObserver (-25203)"
        case .cannotComplete:         return "cannotComplete (-25204) — the app did not answer in time, or is not reachable"
        case .attributeUnsupported:   return "attributeUnsupported (-25205)"
        case .actionUnsupported:      return "actionUnsupported (-25206)"
        case .notificationUnsupported: return "notificationUnsupported (-25207)"
        case .notImplemented:         return "notImplemented (-25208) — the app has no accessibility support"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered (-25209)"
        case .notificationNotRegistered: return "notificationNotRegistered (-25210)"
        case .apiDisabled:            return "apiDisabled (-25211) — Accessibility not granted"
        case .noValue:                return "noValue (-25212) — nothing has focus"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported (-25213)"
        case .notEnoughPrecision:     return "notEnoughPrecision (-25214)"
        @unknown default:             return "unrecognised AXError \(error.rawValue)"
        }
    }
}


/// Watches which control has keyboard focus, across every application, and says when that becomes
/// something the user could type into.
///
/// Two things about this are worth knowing before changing it.
///
/// The first is that applications report focus voluntarily. Some never send the notification at all,
/// and — the more awkward case — many never report focus *leaving* a text field: click from a field
/// onto the empty part of a window and the field usually stays focused as far as the Accessibility
/// API is concerned. So the polling below is not a fallback for exotic applications, it is the
/// mechanism; notifications only make the common case quicker. And no amount of care here removes the
/// need for a way to put the keyboard away by hand.
///
/// The second is that every read is a synchronous call into another process. A messaging timeout is
/// set on each one, because this app is a driver: a hung application that could block a reply here
/// would block the run loop the touch reports arrive on, and the screen would stop responding.
final class FocusWatcher {

    /// Called after the state has held still long enough to be worth acting on. `nil` means nothing
    /// typeable has focus.
    var onChange: ((AXFocusProbe?) -> Void)?

    /// Whether the last thing reported was something typeable. For a caller that put off acting on a
    /// report and needs to know whether it still holds.
    var isEditableFocused: Bool { reportedState != nil }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    /// Counts for the diagnostics: how the state was learned, and how often the API refused.
    private(set) var notificationCount = 0
    private(set) var pollDetectionCount = 0
    private(set) var errorCount = 0
    private(set) var lastVerdict: AXFocusProbe.Verdict = .unreadable


    // MARK: - Lifecycle

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var pollTimer: Timer?

    /// Applications already asked to build an accessibility tree. Tracked per process so the request
    /// is made once rather than on every failed read.
    private var coaxedPIDs = Set<pid_t>()

    deinit {
        if isEnabled { stop() }
    }

    /// Deliberately not conditional on `AXIsProcessTrusted()`.
    ///
    /// Permission is usually granted after the app is already running, and the polling below starts
    /// working the moment it is — the reads simply fail until then, which is what `.unreadable` is
    /// for. Only the notifications need an observer, and that is retried rather than given up on.
    private func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)

        retargetObserver()

        // Notifications are treated as an optimisation and this as the mechanism, which is what makes
        // the feature behave the same in applications with careful accessibility support and in those
        // with none. One focused-element read plus a couple of attribute reads costs well under a
        // millisecond, so the cost of asking regularly is far smaller than the cost of guessing which
        // applications need to be asked.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Retried here because an observer cannot be created before the app is trusted, and that
            // usually happens minutes after launch, in System Settings. Without this the notifications
            // would stay off until the next launch.
            if self.observer == nil { self.retargetObserver() }

            self.read(source: .poll)
        }
        timer.tolerance = Self.pollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        read(source: .poll)
    }

    private func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollTimer?.invalidate()
        pollTimer = nil
        tearDownObserver()

        pending?.work.cancel()
        pending = nil

        reportedState = nil
    }

    static let pollInterval: TimeInterval = 0.4

    @objc private func frontmostApplicationDidChange() {
        retargetObserver()
        read(source: .notification)
    }

    /// An `AXObserver` is bound to one process, so it has to be rebuilt whenever the user switches
    /// application.
    private func retargetObserver() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        tearDownObserver()

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.notificationCount += 1
            watcher.read(source: .notification)
        }

        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            errorCount += 1
            return
        }

        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Float(Self.messagingTimeout))

        let context = Unmanaged.passUnretained(self).toOpaque()
        let registered = Self.observedNotifications.filter {
            AXObserverAddNotification(created, element, $0 as CFString, context) == .success
        }

        // An observer that accepted no notifications will never call back. Discarded rather than kept,
        // both so the retry keeps trying and so the diagnostics do not claim notifications are working
        // in an application that refused every one of them.
        guard !registered.isEmpty else {
            errorCount += 1
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        observedPID = pid
        registeredNotificationCount = registered.count
    }

    /// How many of the notifications the current application accepted. Fewer than all is normal and
    /// worth seeing: it is the difference between an application that reports focus and one that only
    /// reports selection changes.
    private(set) var registeredNotificationCount = 0

    private func tearDownObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
        registeredNotificationCount = 0
    }

    private static let observedNotifications = [
        kAXFocusedUIElementChangedNotification,
        // Sent by web content and by a good number of Electron applications that never send the one
        // above, which makes it the difference between the keyboard working in a browser and not.
        kAXSelectedTextChangedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    private static let messagingTimeout: TimeInterval = 0.25


    // MARK: - Reading

    private enum Source { case notification, poll }

    private func read(source: Source) {
        guard isEnabled else { return }

        let probe = AXFocusProbe.probeFocusedElement(coaxing: { [weak self] pid in
            self?.coaxIfNeeded(pid: pid)
        })

        lastVerdict = probe.verdict

        switch probe.verdict {
        case .unreadable:
            // Emphatically not the same as "no text field here". An application that is merely busy
            // reports nothing for a moment, and taking that as a reason to hide would pull the
            // keyboard away mid-sentence.
            errorCount += 1
            return

        case .editable, .probablyEditable:
            if source == .poll, reportedState == nil { pollDetectionCount += 1 }
            settle(on: probe)

        case .notEditable:
            settle(on: nil)
        }
    }

    /// Chrome and most Electron applications expose nothing until asked to build a tree. Deliberately
    /// only this flag: `AXEnhancedUserInterface`, the older one, makes some applications rebuild their
    /// entire hierarchy and is known to break window resizing in others.
    private func coaxIfNeeded(pid: pid_t) {
        guard !coaxedPIDs.contains(pid) else { return }
        coaxedPIDs.insert(pid)

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(Self.messagingTimeout))
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }


    // MARK: - Settling

    /// What was last handed to `onChange`, so the same answer is not reported twice.
    ///
    /// This is also what makes the dismiss key stick: a keyboard the user put away by hand while a
    /// text field still has focus is not reopened, because from here nothing has changed and there is
    /// nothing to report. It comes back when the focus genuinely moves.
    private var reportedState: AXFocusProbe?

    /// A report that has been scheduled but not delivered yet, with the state it will deliver.
    ///
    /// The state has to be carried alongside the work, not just the work: a reading has to be compared
    /// against where things are *heading*, not only where they have been. Otherwise a momentary "not
    /// editable" schedules a hide, the very next reading says the same field is still focused, that
    /// reading matches what was last reported and is discarded as uninteresting — and the hide it
    /// should have cancelled goes ahead anyway, closing the keyboard under the user.
    private var pending: (state: AXFocusProbe?, work: DispatchWorkItem)?

    /// Waits for the state to hold still before acting on it.
    ///
    /// The two delays are deliberately different. Appearing late reads as the keyboard being broken,
    /// so showing is nearly immediate — just long enough to swallow the burst of notifications an
    /// application switch produces. Disappearing late merely reads as unhurried, and the extra time
    /// covers the moment several applications spend reporting no focus at all while they handle a
    /// keystroke.
    private func settle(on probe: AXFocusProbe?) {
        if let pending {
            // Already on its way to this. Leave it alone rather than restarting its clock, or a
            // stream of readings saying the same thing would postpone it indefinitely.
            if Self.isSameState(probe, pending.state) { return }
            pending.work.cancel()
            self.pending = nil
        } else if Self.isSameState(probe, reportedState) {
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled else { return }
            self.pending = nil
            self.reportedState = probe
            self.onChange?(probe)
        }
        pending = (probe, work)

        let delay = probe == nil ? Self.hideDelay : Self.showDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether two readings say the same thing. Moving between two fields of the same application
    /// counts as the same: the keyboard is already up and where it belongs, and re-reporting would
    /// only give it a reason to flicker.
    private static func isSameState(_ a: AXFocusProbe?, _ b: AXFocusProbe?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case (let a?, let b?):
            return a.ownerBundleID == b.ownerBundleID && a.isSecureInputActive == b.isSecureInputActive
        default:
            return false
        }
    }

    private static let showDelay: TimeInterval = 0.12
    private static let hideDelay: TimeInterval = 0.7


    // MARK: - Diagnostics

    var diagnosticsDescription: String {
        """
        Focus watching: \(isEnabled ? "on" : "off")\
        \(isEnabled && observer == nil
            ? " (polling only — this app accepted no focus notifications)"
            : " (\(registeredNotificationCount) of \(Self.observedNotifications.count) notifications accepted)")
        Focus changes seen: \(notificationCount) reported, \(pollDetectionCount) found by polling
        Focus reads refused: \(errorCount)
        Last verdict: \(AXFocusProbe.name(for: lastVerdict))
        """
    }
}


private extension AXUIElement {

    /// Reads a string attribute, or nil if it is absent, of another type, or unreadable. The three
    /// are deliberately not distinguished: no caller can act differently on them.
    func stringAttribute(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    var owningBundleIdentifier: String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(self, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
