//
//  Model.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import AppKit
import Combine
import TouchUpCore

class TouchUp: NSObject, ObservableObject {
    
    let touchManager: TUCTouchInputManager
    @Published var touches = [TUCTouch]()
    
    
    var observers = [AnyCancellable]()
    
    @Published var isPublishingMouseEventsEnabled = true
    
    @Published var connectionState: ConnectionState = .disconnected
    
    /// Reduces the glass to pointing and clicking, for a machine left in front of the public.
    /// A deployment decision rather than a preference, which is why it is the one thing about
    /// what a gesture means that is still adjustable.
    @Published var isKioskModeEnabled = false

    /// Take the touchscreen away from macOS, for panels it also tries to handle itself.
    @Published var isExclusiveAccessEnabled = false

    /// Treat a contact that vanishes and reappears close by as the same finger.
    ///
    /// Off does not mean "do nothing": the core keeps observing and counting, because that
    /// costs nothing and is what makes the diagnostics report able to say whether a panel has
    /// this fault at all. Off means it does not act on what it sees.
    @Published var isTouchRepairEnabled = false

    /// Let macOS produce scrolling, pinching and swipes itself, from a trackpad we publish
    /// and feed. One finger is unaffected and still points where it touches.
    @Published var isNativeGesturesEnabled = false

    /// Why native gestures are not running, when they were asked for and could not be had.
    /// Shown under the switch: a setting that silently does nothing is worse than one that
    /// says what happened.
    @Published var nativeGesturesUnavailableReason: String?

    @Published var isOnScreenKeyboardEnabled = false
    @Published var isKeyboardAutoShowEnabled = false

    /// A live readout of what each touch was taken to be, for working out why a gesture went the
    /// wrong way.
    ///
    /// It has a settings row, and it has to. It was briefly a hidden default on the grounds that
    /// the window should only hold things people need — but a view that can be left switched on
    /// with no way to switch it off is a trap, and it caught somebody the first day: their machine
    /// had it enabled, the update took the row away, and the readout became permanent. The obvious
    /// escape does not work either, because the app is sandboxed and `defaults write` on the
    /// bundle identifier edits a file outside the container that nothing reads.
    ///
    /// Anything that can be turned on inside the app can be turned off inside the app.
    @Published var isGestureInspectorEnabled = false


    @Published var connectedScreens = [TUCScreen]()
    @Published var connectedDigitizers = [Digitizer]()

    /// Live config for every currently connected digitizer, keyed by `HIDLocationID`.
    /// Source of truth for the UI and for the delegate resolution.
    @Published var digitizerConfigs: [HIDLocationID: DigitizerConfig] = [:]

    /// All configs ever persisted (also for digitizers that are currently disconnected),
    /// keyed by `HIDLocationID`. Loaded once at launch, re-saved on every `persistMapping`.
    private var persistedConfigs: [HIDLocationID: DigitizerConfig] = [:]

    /// `CGDirectDisplayID` of the screen that connected most recently. Used as the implicit
    /// fallback target when a digitizer has no (matching) stored screen identity.
    var idOfLastAddedScreen: UInt?


    @Published var isAccessibilityAccessGranted = false


    /// The on-screen keyboard, for a machine that has no other one.
    ///
    /// Owned here rather than by the app delegate because the model is what learns that the user has
    /// moved to a different panel, and the keyboard has to follow them.
    private(set) var keyboard: KeyboardController!

    /// The live readout of what gestures are being decided, for working out why one went the way it
    /// did. Nothing depends on it and it is off by default; it only ever reads.
    private(set) var gestureInspector: GestureInspector!


    @objc func screenParametersDidChange() {
        // identify which screen is newly added.
        let oldScreenList = self.connectedScreens
        self.connectedScreens = TUCScreen.allScreens()

        // a new screen appeared — remember it as the implicit fallback target.
        if connectedScreens.count > oldScreenList.count {
            let new = connectedScreens.first { s in
                !(oldScreenList.contains(where: {$0.id == s.id}))
            }
            if let new {
                self.idOfLastAddedScreen = new.id
            }
        }

        // The screen list was rebuilt, so any resolved mapping may have shifted.
        updateConnectionState()

        // A keyboard on a screen that has just been unplugged, resized or rearranged is in the wrong
        // place, and possibly off the desktop entirely.
        keyboard?.repositionIfVisible()
    }

    
    /// A copyable snapshot for bug reports: build and hardware identity, then everything the
    /// core knows about the connected digitizers, the screens, and how they were mapped.
    /// The hardware model is included because it is the first thing asked for in practice —
    /// the tracker is full of "Mac mini M4 + <panel>" reports where neither half was stated.
    var diagnosticsReport: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        var report = "Touch Up \(version) (\(build))\n"
        report += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        report += "Hardware \(Self.hardwareModelIdentifier ?? "unknown")\n"
        report += "Accessibility access: \(isAccessibilityAccessGranted ? "granted" : "NOT GRANTED")\n\n"
        report += touchManager.diagnosticsReport()

        // Whether we can see the focused control at all, which is what an on-screen keyboard has to
        // know to open by itself. Included unconditionally: whether this read works from inside the
        // sandbox, and in which applications, is the first question every report about the keyboard
        // failing to appear will need answered.
        report += "\n" + AXFocusProbe.probeFocusedElement().diagnosticsDescription
        report += keyboard.diagnosticsDescription

        return report
    }

    /// e.g. "Mac16,8". `sysctlbyname` is the only way to get this; there is no AppKit API.
    private static var hardwareModelIdentifier: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }

        return String(cString: bytes)
    }

    func copyDiagnosticsToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport, forType: .string)
    }


    func checkAccessibilityAccessGranted() {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        self.isAccessibilityAccessGranted = AXIsProcessTrustedWithOptions([checkOptPrompt: true] as CFDictionary?)
    }
    
    func grantAccessibilityAccess() {
        self.touchManager.triggerSystemAccessibilityAccessAlert()
        (NSApp.delegate as? AppDelegate)?.settingsWindow.close()
        self.isAccessibilityAccessGranted = true
    }
    
    
    override init() {
        self.touchManager = TUCTouchInputManager()

        super.init()

        self.keyboard = KeyboardController(model: self)
        self.gestureInspector = GestureInspector(model: self)

        self.loadDigitizerConfigs()
        self.screenParametersDidChange()

        self.touchManager.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(TouchUp.screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        
        initPreferences()
        
        checkAccessibilityAccessGranted()
    }
    
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}


// MARK: - Loading, Saving and Syncing Settings with Framework
extension TouchUp {
    
    func initPreferences() {
        let defaults = UserDefaults.standard

        defaults.register(defaults: [
            "isKioskModeEnabled" : false,
            "isExclusiveAccessEnabled" : false,
            "isNativeGesturesEnabled" : false,
            "isTouchRepairEnabled" : false,
            "isGestureInspectorEnabled" : false,

            // Off by default. A machine with a keyboard attached does not want a second one taking
            // up the bottom of the screen.
            "isOnScreenKeyboardEnabled" : false,
            "isKeyboardAutoShowEnabled" : true
        ])

        isKioskModeEnabled = defaults.bool(forKey: "isKioskModeEnabled")
        isExclusiveAccessEnabled = defaults.bool(forKey: "isExclusiveAccessEnabled")
        isNativeGesturesEnabled = defaults.bool(forKey: "isNativeGesturesEnabled")
        isTouchRepairEnabled = defaults.bool(forKey: "isTouchRepairEnabled")
        isGestureInspectorEnabled = defaults.bool(forKey: "isGestureInspectorEnabled")
        isOnScreenKeyboardEnabled = defaults.bool(forKey: "isOnScreenKeyboardEnabled")
        isKeyboardAutoShowEnabled = defaults.bool(forKey: "isKeyboardAutoShowEnabled")

        // Everything that decides what a gesture *means* now lives in the core and cannot be
        // changed from here, so what is left to push is only the handful of switches that are
        // about the machine rather than about the behaviour.
        self.observers = [
            $isPublishingMouseEventsEnabled.assign(to: \.postMouseEvents, on: touchManager),
            $isKioskModeEnabled.assign(to: \.kioskMode, on: touchManager),
            $isExclusiveAccessEnabled.sink { [weak self] enabled in
                self?.touchManager.setTouchscreensSeized(enabled)
            },

            // Observing rather than off, so the diagnostics can still answer "does this panel
            // drop contacts?" for somebody who has never turned the repair on.
            $isTouchRepairEnabled.sink { [weak self] enabled in
                self?.touchManager.contactIdentityRepair = enabled ? .on : .observe
            },

            $isNativeGesturesEnabled.sink { [weak self] enabled in
                if enabled { self?.nativeGesturesUnavailableReason = nil }
                self?.touchManager.usesNativeGestures = enabled
            },

            // The watcher costs a read every 0.4 s while it runs, so it only runs when both the
            // keyboard and its automatic side are wanted. Put the keyboard away when the feature
            // is turned off, rather than leaving one on screen that nothing can now close.
            Publishers.CombineLatest($isOnScreenKeyboardEnabled, $isKeyboardAutoShowEnabled)
                .sink { [weak self] isEnabled, isAutomatic in
                    self?.keyboard.isAutomatic = isEnabled && isAutomatic
                    if !isEnabled { self?.keyboard.hide() }
                },

            $isGestureInspectorEnabled.sink { [weak self] isEnabled in
                self?.gestureInspector.isEnabled = isEnabled
            }
        ]
    }


    func savePreferences() {
        let defaults = UserDefaults.standard

        defaults.set(isKioskModeEnabled, forKey: "isKioskModeEnabled")
        defaults.set(isExclusiveAccessEnabled, forKey: "isExclusiveAccessEnabled")
        defaults.set(isNativeGesturesEnabled, forKey: "isNativeGesturesEnabled")
        defaults.set(isTouchRepairEnabled, forKey: "isTouchRepairEnabled")
        defaults.set(isGestureInspectorEnabled, forKey: "isGestureInspectorEnabled")
        defaults.set(isOnScreenKeyboardEnabled, forKey: "isOnScreenKeyboardEnabled")
        defaults.set(isKeyboardAutoShowEnabled, forKey: "isKeyboardAutoShowEnabled")
    }

}


// MARK: - Per-Digitizer Screen Mapping
extension TouchUp {

    private static let digitizerConfigsKey = "digitizerConfigs"

    /// The screen a freshly connected (or unmatched) digitizer maps to by default: the one
    /// that connected most recently, falling back to the last screen in the arrangement.
    var newestScreen: TUCScreen? {
        if let id = idOfLastAddedScreen, let screen = connectedScreens.first(where: { $0.id == id }) {
            return screen
        }
        return connectedScreens.last
    }

    /// Resolves the stored screen identity of a digitizer against the currently connected
    /// screens. Priority: UUID (exact) → display ID (fallback) → most recent screen (implicit).
    func resolvedMapping(forLocationID locationID: HIDLocationID) -> (screen: TUCScreen?, match: ScreenMatch) {
        let config = digitizerConfigs[locationID]

        if let uuid = config?.screenUUID,
           let screen = connectedScreens.first(where: { $0.uuid == uuid }) {
            return (screen, .exact)
        }

        if let id = config?.screenID,
           let screen = connectedScreens.first(where: { $0.id == id }) {
            return (screen, .idFallback)
        }

        if let screen = newestScreen {
            return (screen, .implicit)
        }

        return (nil, .unmapped)
    }

    /// Explicitly assigns a screen to a digitizer (user action) and persists it immediately.
    /// Storing the UUID makes the mapping confirmed, so it survives rearrange/rotate/mirror.
    func assignScreen(_ screen: TUCScreen?, toDigitizer locationID: HIDLocationID) {
        guard var config = digitizerConfigs[locationID] else { return }
        config.screenUUID = screen?.uuid
        config.screenID = screen.map { UInt($0.id) }
        digitizerConfigs[locationID] = config
        persistMapping(forLocationID: locationID)
    }

    /// Sets the additional digitizer rotation (user action) and persists it immediately.
    func setRotation(_ rotation: CGFloat, forDigitizer locationID: HIDLocationID) {
        guard var config = digitizerConfigs[locationID] else { return }
        config.additionalRotation = rotation
        digitizerConfigs[locationID] = config
        persistMapping(forLocationID: locationID)
    }

    /// Mirrors one of the digitizer's axes (user action) and persists it immediately.
    func setFlipped(_ isFlipped: Bool, axis: DigitizerAxis, forDigitizer locationID: HIDLocationID) {
        guard var config = digitizerConfigs[locationID] else { return }
        switch axis {
        case .horizontal: config.isFlippedHorizontally = isFlipped
        case .vertical:   config.isFlippedVertically = isFlipped
        }
        digitizerConfigs[locationID] = config
        persistMapping(forLocationID: locationID)
    }

    /// Lets a digitizer move the pointer, or stops it. Persisted as an explicit user override.
    func setDrivesPointer(_ drivesPointer: Bool, forDigitizer locationID: HIDLocationID) {
        guard var config = digitizerConfigs[locationID] else { return }
        config.drivesPointer = drivesPointer
        digitizerConfigs[locationID] = config
        touchManager.setDigitizerDrivesPointer(drivesPointer, forLocationID: locationID)
        persistMapping(forLocationID: locationID)
    }

    func drivesPointer(forDigitizer locationID: HIDLocationID) -> Bool {
        touchManager.digitizerDrivesPointer(forLocationID: locationID)
    }

    func isFlipped(axis: DigitizerAxis, forDigitizer locationID: HIDLocationID) -> Bool {
        switch axis {
        case .horizontal: return digitizerConfigs[locationID]?.isFlippedHorizontally ?? false
        case .vertical:   return digitizerConfigs[locationID]?.isFlippedVertically ?? false
        }
    }

    /// Freezes the currently resolved screen (id + uuid) and rotation of one digitizer into
    /// persistent storage. Covers both cases: an explicit user edit, and an implicit mapping
    /// that worked fine and should stick (called for all digitizers before the window closes).
    func persistMapping(forLocationID locationID: HIDLocationID) {
        guard var config = digitizerConfigs[locationID] else { return }

        // Promote an as-yet-unconfirmed mapping (no stored UUID) to its currently resolved
        // screen — this is the "implicit mapping was fine, freeze it" case. A config that
        // already carries a UUID is a confirmed preference and is never overwritten here: if
        // its panel is merely absent right now (`.idFallback` / `.unmapped`) the stored UUID
        // must survive and reassert via an exact match once the panel returns.
        if config.screenUUID == nil, let screen = resolvedMapping(forLocationID: locationID).screen {
            config.screenID = UInt(screen.id)
            config.screenUUID = screen.uuid
        }

        digitizerConfigs[locationID] = config
        persistedConfigs[locationID] = config
        saveDigitizerConfigs()
    }

    /// Persists the mapping of every currently connected digitizer. Call before the settings
    /// window closes / on termination so implicit mappings become explicit next launch.
    func persistAllDigitizerMappings() {
        for locationID in digitizerConfigs.keys {
            persistMapping(forLocationID: locationID)
        }
    }

    /// Recomputes `connectionState` from the connected digitizers and their resolvable screens.
    func updateConnectionState() {
        guard !connectedDigitizers.isEmpty else {
            connectionState = .disconnected
            return
        }
        let anyResolved = connectedDigitizers.contains {
            resolvedMapping(forLocationID: $0.locationID).screen != nil
        }
        connectionState = anyResolved ? .connectedPreferred : .uncertain
    }

    func loadDigitizerConfigs() {
        guard let data = UserDefaults.standard.data(forKey: Self.digitizerConfigsKey),
              let decoded = try? JSONDecoder().decode([String: DigitizerConfig].self, from: data)
        else { return }

        // JSON object keys are strings; map them back to numeric location IDs.
        persistedConfigs = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            HIDLocationID(key).map { ($0, value) }
        })
    }

    private func saveDigitizerConfigs() {
        let encodable = Dictionary(uniqueKeysWithValues: persistedConfigs.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: Self.digitizerConfigsKey)
        }
    }
}



extension TouchUp: TUCTouchDelegate {
    
    func touchesDidChange() {
        self.touches = self.touchManager.touchSet.allObjects as! [TUCTouch]
    }
    
    
    func touchscreen(forLocationID locationID: UInt32) -> TUCScreen? {
        resolvedMapping(forLocationID: locationID).screen
    }

    func digitizerRotation(forLocationID locationID: UInt32) -> CGFloat {
        digitizerConfigs[locationID]?.additionalRotation ?? 0
    }

    func digitizerIsFlippedHorizontally(forLocationID locationID: UInt32) -> Bool {
        digitizerConfigs[locationID]?.isFlippedHorizontally ?? false
    }

    func digitizerIsFlippedVertically(forLocationID locationID: UInt32) -> Bool {
        digitizerConfigs[locationID]?.isFlippedVertically ?? false
    }

    /// Native gestures were asked for and could not be had. The core has already turned the
    /// setting off by the time this arrives, so the switch is brought back into line and the
    /// reason is put where the person who flipped it will see it.
    ///
    /// Deferred to the next turn of the run loop, and it has to be. The common failure —
    /// the app not being entitled to publish a device — happens synchronously inside the
    /// sink observing this very property, and `@Published` announces a change *before*
    /// storing it. Setting it to false from in there means the original assignment lands
    /// afterwards and wins: the switch reads on, saves as on, and controls nothing.
    @objc func nativeGesturesDidBecomeUnavailable(_ reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.isNativeGesturesEnabled = false
            self?.nativeGesturesUnavailableReason = reason
        }
    }


    /// The user put a finger on a different panel. Anything showing on the glass should follow them
    /// there rather than stay on a screen they have walked away from.
    @objc func lastTouchedDigitizerDidChange(_ locationID: UInt32) {
        keyboard.lastTouchedScreenDidChange()
    }

    func touchscreenDidConnect(withLocationID locationID: UInt32, drivesPointer: Bool) {
        self.connectedDigitizers.append(Digitizer(locationID: locationID))

        // Restore a previously persisted config for this digitizer, or start a blank one
        // (which resolves implicitly to the most recently added screen).
        if digitizerConfigs[locationID] == nil {
            digitizerConfigs[locationID] = persistedConfigs[locationID] ?? DigitizerConfig()
        }

        // The core decided whether this device may drive the pointer from what it declares
        // itself to be. A stored value is the user overriding that, either way.
        //
        // Deliberately not written back into the config: leaving it nil keeps the difference
        // between "the user chose this" and "nobody has decided yet". Writing the guess through
        // would let `persistAllDigitizerMappings` freeze it on window close, pinning a device
        // off forever even after a later release learns to recognise it properly.
        let effective = digitizerConfigs[locationID]?.drivesPointer ?? drivesPointer
        touchManager.setDigitizerDrivesPointer(effective, forLocationID: locationID)

        updateConnectionState()
    }

    func touchscreenDidDisconnect(withLocationID locationID: UInt32) {
        if let index = self.connectedDigitizers.firstIndex(where: {$0.locationID == locationID}) {
            self.connectedDigitizers.remove(at: index)
        }
        // Drop the live config; the persisted copy in `persistedConfigs` survives for reconnect.
        digitizerConfigs[locationID] = nil

        updateConnectionState()
    }
    
}


extension TouchUp {
    func uiLabels<T>(for keyPath: KeyPath<TouchUp, T>) -> (title:String, description:String) {
        switch keyPath {
        case \.isPublishingMouseEventsEnabled:
            return("Control Mouse with Touch",
                   "Turns the driver on or off.")

        case \.isKioskModeEnabled:
            return("Kiosk Mode",
                   "Reduces the screen to pointing and clicking: nothing can be scrolled, dragged, zoomed or held. For a machine left in front of the public, where a visitor who scrolls a window away leaves it broken for the next person.")

        case \.isExclusiveAccessEnabled:
            return("Exclusive Access",
                   "Take sole control of the touchscreen so macOS stops handling it too. Enable this if your screen still behaves like a trackpad, or if every touch seems to register twice. (EXPERIMENTAL)")

        case \.isTouchRepairEnabled:
            return("Repair Dropped Touches",
                   "Some panels lose a finger for a moment while it is moving and report it again as a new one, which makes drags let go and gestures restart. This treats a contact that reappears in the same place a few milliseconds later as the finger it was. Leave it off if your screen behaves \u{2014} the diagnostics report says whether yours has this fault.")

        case \.isNativeGesturesEnabled:
            return("Let macOS Handle Gestures",
                   "Scrolling, pinching and swipes are produced by macOS itself rather than imitated, so they carry the same momentum and behave the way they do in each app for a real trackpad. Pointing, tapping and dragging with one finger are unchanged. Needs permission from Apple that this build may not have — if it does not take, the switch turns itself off and says so. (EXPERIMENTAL)")

        case \.isGestureInspectorEnabled:
            return("Show What Touch Up Decides",
                   "A small readout in the corner of the screen you are touching, showing what each touch was taken to be on and what that turned it into. For working out why a gesture did the wrong thing — it ignores touches entirely, so watching one cannot change it.")

        case \.isOnScreenKeyboardEnabled:
            return("On-Screen Keyboard",
                   "A keyboard along the bottom of the panel you last touched, for a machine with no keyboard attached. Its keys carry whatever your selected input source puts on them. A password field can ask macOS to stop accepting typed-in keystrokes, and no keyboard on screen can get around that — the keyboard says so when it happens.")

        case \.isKeyboardAutoShowEnabled:
            return("Open It When You Tap a Text Field",
                   "Watches which control has focus, in any app, and raises the keyboard when that control accepts typing. Focus is something apps report voluntarily, so some report it late and a few not at all — the menu bar item always works, and the keyboard has a key to put itself away.")

        default:
            return("\(keyPath)", "")
        }
    }
}


enum ConnectionState: Int {
    case uncertain
    case disconnected
    case connectedPreferred // connected with stored cues matching perfectly
    
    var image: NSImage? {
        let image: NSImage?
        
        switch self {
        case .uncertain:
            image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        case .disconnected:
            image = NSImage(systemSymbolName: "rectangle.badge.xmark", accessibilityDescription: nil)
        default:
            image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        }
        
        image?.isTemplate = true
        
        return image
    }
    
    var isConnected: Bool {
        return self == .connectedPreferred
    }
}


extension TUCScreen: @retroactive Identifiable {}
