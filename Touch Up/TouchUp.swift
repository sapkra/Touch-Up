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
    
    @Published var holdDuration: TimeInterval = 0.1
    @Published var doubleClickDistance: CGFloat = 3 //mm
    @Published var tapDistance: CGFloat = 2.5 //mm
    @Published var errorResistance: NSInteger = 0 // num of Reports to wait before cancelling a touch
    @Published var ignoreOriginTouches: Bool = false
    
    @Published var isScrollingWithOneFingerEnabled = false
    @Published var isSecondaryClickEnabled = false
    @Published var isMagnificationEnabled = false
    @Published var isClickWindowToFrontEnabled = false
    @Published var isClickOnLiftEnabled = false
    @Published var isDraggingWithOneFingerEnabled = false
    @Published var isLongPressContextMenuEnabled = false
    @Published var isExclusiveAccessEnabled = false
    @Published var isCursorHiddenEnabled = false
    @Published var twoFingerDragAction: TwoFingerDragAction = .drag
    @Published var isSystemSwipeEnabled = true

    @Published var isOnScreenKeyboardEnabled = false
    @Published var isKeyboardAutoShowEnabled = false

    @Published var areAdditionalDigitizerRotationSettingsVisible = false


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

    /// Whether the settings currently add up to the tablet-like combination below. Derived rather
    /// than stored, so changing any one of the individual toggles simply drops out of the preset
    /// instead of leaving a stored flag disagreeing with what the app actually does.
    var isTabletModeActive: Bool {
        isScrollingWithOneFingerEnabled
            && isLongPressContextMenuEnabled
            && isMagnificationEnabled
            && isCursorHiddenEnabled
            && isSystemSwipeEnabled
            && twoFingerDragAction == .drag
            && !isSecondaryClickEnabled
            && !isClickOnLiftEnabled
            && !isDraggingWithOneFingerEnabled
            && isClickWindowToFrontEnabled
            && isOnScreenKeyboardEnabled
            && isKeyboardAutoShowEnabled
            && holdDuration >= Self.tabletModeHoldDuration
            && tapDistance >= Self.tabletModeTapDistance
    }

    /// Long enough that an ordinary tap cannot reach it. iPadOS uses about half a second, but a
    /// tap there is a thumb on a handheld screen; reaching out to a wall-sized panel and lifting
    /// again takes longer, and a tap that overruns becomes a context menu — which on most controls
    /// shows nothing at all, so it reads as the click having been ignored.
    static let tabletModeHoldDuration: TimeInterval = 0.7

    /// How far a finger may slide and still be a tap. Anything past it is a scroll, and a scroll
    /// produces no click. Wide enough to absorb a finger settling on the glass, narrow enough that
    /// scrolling still starts where you expect it to.
    static let tabletModeTapDistance: CGFloat = 3

    /// Two taps this far apart still count as a double click. Generous, because pointing precision
    /// scales with the panel.
    static let tabletModeDoubleClickDistance: CGFloat = 8

    /// Every setting that decides how the glass behaves, put where a tablet would have it.
    ///
    /// The timings and distances are part of the mode, not incidental tuning: whether a touch is a
    /// tap at all is decided by `tapDistance` and `holdDuration`, and a value tuned for a phone
    /// makes an ordinary tap on a wall-sized panel land as a scroll or a long press instead.
    func activateTabletMode() {
        // One finger moves the content, as on a tablet. Never the pointer, never a button.
        isScrollingWithOneFingerEnabled = true
        isClickOnLiftEnabled = false
        isDraggingWithOneFingerEnabled = false

        // Two fingers hold the button down. Not a tablet gesture, but dragging has to live
        // somewhere: it is the only way to pan a map, move a window, work a slider or select text,
        // and one finger is already spoken for.
        twoFingerDragAction = .drag

        // Holding still opens the context menu, which is what a long press does on a tablet.
        isLongPressContextMenuEnabled = true

        // Two-finger tap for a secondary click is a trackpad idiom with no tablet equivalent, and
        // the long press already covers the menu.
        isSecondaryClickEnabled = false

        isMagnificationEnabled = true
        isSystemSwipeEnabled = true
        isCursorHiddenEnabled = true

        // A tablet raises a keyboard when you tap somewhere you can type, and has no other one to
        // fall back on.
        isOnScreenKeyboardEnabled = true
        isKeyboardAutoShowEnabled = true

        // On: tapping an app that is not focused should focus it and act on what you touched, in
        // one tap, which is what a tablet does. It was off while this worked by injecting a second
        // click, which made that tap actuate twice on some controls; it now activates the owning
        // application instead and leaves exactly one click.
        isClickWindowToFrontEnabled = true

        holdDuration = Self.tabletModeHoldDuration
        tapDistance = Self.tabletModeTapDistance
        doubleClickDistance = Self.tabletModeDoubleClickDistance
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
            "holdDuration" : 0.1,
            "doubleClickDistance" : 8,
            "tapDistance" : 2.5,
            "errorResistance" : 4,
            "ignoreOriginTouches" : true,

            "isScrollingWithOneFingerEnabled" : true,
            "isSecondaryClickEnabled" : true,
            "isMagnificationEnabled" : true,
            "isClickWindowToFrontEnabled" : false,
            "isClickOnLiftEnabled" : false,
            "isDraggingWithOneFingerEnabled" : false,
            "isLongPressContextMenuEnabled" : false,
            "isExclusiveAccessEnabled" : false,
            "isCursorHiddenEnabled" : false,
            "twoFingerDragAction" : TwoFingerDragAction.drag.rawValue,
            "isSystemSwipeEnabled" : true,
            "areAdditionalDigitizerRotationSettingsVisible" : false,

            // Off by default. A machine with a keyboard attached does not want a second one taking up
            // the bottom of the screen, and there is no way from here to tell whether one is attached.
            "isOnScreenKeyboardEnabled" : false,
            "isKeyboardAutoShowEnabled" : true
        ])
        
        holdDuration = defaults.double(forKey: "holdDuration")
        // A zero zone means two taps can never be close enough to double click. It used to be
        // selectable while the distance check was broken and therefore inert, so a stored 0 is
        // not a deliberate choice — lift it to the smallest value the slider now offers.
        doubleClickDistance = max(1, defaults.double(forKey: "doubleClickDistance"))
        // Only the unusable floor is corrected here. Widening the default was a guess at why taps
        // were not clicking, and the guess was wrong: the cause was a digitizer emitting spurious
        // reports at the origin, which move the touch to the corner of the screen no matter how
        // wide the zone is. A zone below 2 mm still cannot work, since a finger settling on the
        // glass shifts the contact further than that, so those are lifted.
        // Anything under 2 mm is smaller than the shift a finger makes just settling onto the
        // glass, so every touch becomes a scroll and nothing ever clicks. It used to be selectable,
        // so lift a stored value up rather than leaving someone stuck with a screen that ignores
        // them. 2.5 was the old default and was never a deliberate choice either.
        let storedTapDistance = defaults.double(forKey: "tapDistance")
        tapDistance = (storedTapDistance < 2) ? 2.5 : storedTapDistance
        errorResistance = defaults.integer(forKey: "errorResistance")
        ignoreOriginTouches = defaults.bool(forKey: "ignoreOriginTouches")


        self.observers = [
            $isPublishingMouseEventsEnabled.assign(to: \.postMouseEvents, on: touchManager),
            $holdDuration.assign(to: \.holdDuration, on: touchManager),
            $doubleClickDistance.assign(to: \.doubleClickTolerance, on: touchManager),
            $tapDistance.assign(to: \.tapTolerance, on: touchManager),
            $errorResistance.assign(to: \.errorResistance, on: touchManager),
            $ignoreOriginTouches.assign(to: \.ignoreOriginTouches, on: touchManager),
            $isExclusiveAccessEnabled.sink { [weak self] enabled in
                self?.touchManager.setTouchscreensSeized(enabled)
            },
            $isCursorHiddenEnabled.assign(to: \.hidesCursor, on: touchManager)
        ]
        
        
        
        isScrollingWithOneFingerEnabled = defaults.bool(forKey: "isScrollingWithOneFingerEnabled")
        isSecondaryClickEnabled = defaults.bool(forKey: "isSecondaryClickEnabled")
        isMagnificationEnabled = defaults.bool(forKey: "isMagnificationEnabled")
        isClickWindowToFrontEnabled = defaults.bool(forKey: "isClickWindowToFrontEnabled")
        isClickOnLiftEnabled = defaults.bool(forKey: "isClickOnLiftEnabled")
        isDraggingWithOneFingerEnabled = defaults.bool(forKey: "isDraggingWithOneFingerEnabled")
        isLongPressContextMenuEnabled = defaults.bool(forKey: "isLongPressContextMenuEnabled")
        isExclusiveAccessEnabled = defaults.bool(forKey: "isExclusiveAccessEnabled")
        isCursorHiddenEnabled = defaults.bool(forKey: "isCursorHiddenEnabled")
        twoFingerDragAction = TwoFingerDragAction(rawValue: defaults.integer(forKey: "twoFingerDragAction")) ?? .drag
        isSystemSwipeEnabled = defaults.bool(forKey: "isSystemSwipeEnabled")
        areAdditionalDigitizerRotationSettingsVisible = defaults.bool(forKey: "areAdditionalDigitizerRotationSettingsVisible")
        isOnScreenKeyboardEnabled = defaults.bool(forKey: "isOnScreenKeyboardEnabled")
        isKeyboardAutoShowEnabled = defaults.bool(forKey: "isKeyboardAutoShowEnabled")

        // The watcher costs a read every 0.4 s while it runs, so it only runs when both the keyboard
        // and its automatic side are wanted. Put the keyboard away when the feature is turned off,
        // rather than leaving one on screen that nothing can now close.
        self.observers.append(contentsOf: [
            Publishers.CombineLatest($isOnScreenKeyboardEnabled, $isKeyboardAutoShowEnabled)
                .sink { [weak self] isEnabled, isAutomatic in
                    self?.keyboard.isAutomatic = isEnabled && isAutomatic
                    if !isEnabled { self?.keyboard.hide() }
                }
        ])
    }
    
    
    func savePreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(holdDuration, forKey: "holdDuration")
        defaults.set(doubleClickDistance, forKey: "doubleClickDistance")
        defaults.set(tapDistance, forKey: "tapDistance")
        defaults.set(errorResistance, forKey: "errorResistance")
        defaults.set(ignoreOriginTouches, forKey: "ignoreOriginTouches")

        defaults.set(isScrollingWithOneFingerEnabled, forKey: "isScrollingWithOneFingerEnabled")
        defaults.set(isSecondaryClickEnabled, forKey: "isSecondaryClickEnabled")
        defaults.set(isMagnificationEnabled, forKey: "isMagnificationEnabled")
        defaults.set(isClickWindowToFrontEnabled, forKey: "isClickWindowToFrontEnabled")
        defaults.set(isClickOnLiftEnabled, forKey: "isClickOnLiftEnabled")
        defaults.set(isDraggingWithOneFingerEnabled, forKey: "isDraggingWithOneFingerEnabled")
        defaults.set(isLongPressContextMenuEnabled, forKey: "isLongPressContextMenuEnabled")
        defaults.set(isExclusiveAccessEnabled, forKey: "isExclusiveAccessEnabled")
        defaults.set(isCursorHiddenEnabled, forKey: "isCursorHiddenEnabled")
        defaults.set(twoFingerDragAction.rawValue, forKey: "twoFingerDragAction")
        defaults.set(isSystemSwipeEnabled, forKey: "isSystemSwipeEnabled")
        defaults.set(areAdditionalDigitizerRotationSettingsVisible, forKey: "areAdditionalDigitizerRotationSettingsVisible")
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

    /// The user put a finger on a different panel. Anything showing on the glass should follow them
    /// there rather than stay on a screen they have walked away from.
    @objc func lastTouchedDigitizerDidChange(_ locationID: UInt32) {
        keyboard.lastTouchedScreenDidChange()
    }

    func action(for gesture: TUCCursorGesture) -> TUCCursorAction {
        switch gesture {
        case .TUCCursorGestureTouchDown:
            return isClickWindowToFrontEnabled ? .moveClickIfNeeded : .move
            
        case .TUCCursorGestureTap:
            return .click
            
        case .TUCCursorGestureLongPress:
            // Posted when a finger held still is then lifted without ever moving. On a tablet
            // that is the gesture for a context menu, which is a secondary click here. Holding
            // and then moving is a different thing entirely and arrives as `HoldAndDrag`, so
            // picking something up still works.
            return isLongPressContextMenuEnabled ? .secondaryClick : .none

        case .TUCCursorGestureDrag:
            if isClickOnLiftEnabled { return .pointAndClick }
            if isDraggingWithOneFingerEnabled { return .drag }
            return isScrollingWithOneFingerEnabled ? .scroll : .move
            
        case .TUCCursorGestureHoldAndDrag:
            return .drag
            
        case .TUCCursorGestureTapSecondFinger:
            return isSecondaryClickEnabled ? .secondaryClick : .none
            
        case .TUCCursorGestureTwoFingerDrag:
            switch twoFingerDragAction {
            case .drag:    return .drag
            case .scroll:  return .scroll
            case .nothing: return .none
            }
            
        case .TUCCursorGesturePinch:
            return isMagnificationEnabled ? .magnify : .none

        // Sweeping three fingers, matching the trackpad pane's own directions: the space follows
        // your fingers off the screen, up reveals Mission Control, down reveals the app's windows.
        case .TUCCursorGestureSwipeLeft:
            return isSystemSwipeEnabled ? .spaceNext : .none

        case .TUCCursorGestureSwipeRight:
            return isSystemSwipeEnabled ? .spacePrevious : .none

        case .TUCCursorGestureSwipeUp:
            return isSystemSwipeEnabled ? .missionControl : .none

        case .TUCCursorGestureSwipeDown:
            return isSystemSwipeEnabled ? .applicationWindows : .none
            
        default:
            return .none
        }
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
            
        case \.isScrollingWithOneFingerEnabled:
            return("Scroll with one finger",
                   "Scroll by dragging one finger over the touchscreen. If this option is disabled, you will move the cursor instead.")
            
        case \.isSecondaryClickEnabled:
            return("Secondary Click",
                   "While your pointing finger is resting on the screen, tap another finger in proximity to it to generate a secondary click event at the location of the first finger.")
            
        case \.isMagnificationEnabled:
            return("Magnification",
                   "Pinch two fingers to increase or decrease the size of the content. (EXPERIMENTAL)")
            
        case \.isClickWindowToFrontEnabled:
            return("Bring Windows to Front",
                   "Touching a window that is not in front focuses it and acts on what you touched, in one tap. Without this, the first tap only brings the window forward and you have to tap again.")
            
        case \.isClickOnLiftEnabled:
            return("Point and click",
                   "Very reduced input set for exhibits: Move cursor by dragging, and click by releasing. Overrides scrolling and dragging functionality.")

        case \.isSystemSwipeEnabled:
            return("Swipe Between Desktops",
                   "Sweep three fingers across the screen to move between desktops, up for Mission Control, or down to see the current app's windows — as on a trackpad. Sent as the keyboard shortcuts macOS assigns to those commands, so the desktop switches in one step rather than following your fingers.")

        case \.twoFingerDragAction:
            return("On Two Finger Drag",
                   "Dragging with two fingers holds the mouse button down and moves it, which is what pans a map, moves a window, works a slider or selects text. Nothing can tell those apart from a scrolling area, so they need a gesture of their own.")

        case \.isCursorHiddenEnabled:
            return("Hide the Mouse Pointer",
                   "There is no pointer on a tablet, and one that jumps to wherever you touched is the clearest reminder that you are steering a mouse. Touching hides it; moving a mouse or trackpad brings it straight back, and the next touch hides it again.")

        case \.isExclusiveAccessEnabled:
            return("Exclusive Access",
                   "Take sole control of the touchscreen so macOS stops handling it too. Enable this if your screen still behaves like a trackpad, or if every touch seems to register twice. (EXPERIMENTAL)")

        case \.isOnScreenKeyboardEnabled:
            return("On-Screen Keyboard",
                   "A keyboard along the bottom of the panel you last touched, for a machine with no keyboard attached. Its keys carry whatever your selected input source puts on them. A password field can ask macOS to stop accepting typed-in keystrokes, and no keyboard on screen can get around that — the keyboard says so when it happens.")

        case \.isKeyboardAutoShowEnabled:
            return("Open It When You Tap a Text Field",
                   "Watches which control has focus, in any app, and raises the keyboard when that control accepts typing. Focus is something apps report voluntarily, so some report it late and a few not at all — the menu bar item always works, and the keyboard has a key to put itself away.")

        case \.isLongPressContextMenuEnabled:
            return("Long Press for Menu",
                   "Hold your finger still for a moment and the right-click menu opens under it, the way a long press does on a tablet. Use two fingers to drag things.")
            
        case \.holdDuration:
            return("Hold Duration",
                   "How long do you have to hold finger to initiate hold&drag")
            
        case \.doubleClickDistance:
            return("Double Click Zone",
                   "How many mm can two taps be apart from each other to qualify double click")

        case \.tapDistance:
            return("Tap Zone",
                   "How many mm your finger may slide while touching and still count as a tap instead of a scroll. Raise it if taps sometimes only move the pointer instead of clicking; lower it if scrolling feels like it starts too late.")
            
        case \.ignoreOriginTouches:
            return("Ignore Origin Touches",
                   "If your touchscreen randomly sends coordinate (0,0) in its datastream, toggle this option to make input more stable.")
            
        case \.errorResistance:
            return("Error Resistance",
                   "If your touchscreen is really unreliable at reporting touches, increase this slider to make inputs more stable at the cost of higher latency in detecting liftoffs.")
        
        case \.areAdditionalDigitizerRotationSettingsVisible:
            return("Digitizer Rotation",
                   "Adds rotation and mirroring controls to each touchscreen. Only needed if the digitizer orientation does not match your screen — use mirroring if touches track correctly in the centre but run the wrong way towards the edges.")
            
        default:
            return("\(keyPath)", "")
        }
    }
}


enum ConnectionState: Int {
    case uncertain
    case disconnected
    case connectedHotPlug // connected as result from hot plugging within a few seconds
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
        return self == .connectedPreferred || self == .connectedHotPlug
    }
}


extension TUCScreen: @retroactive Identifiable {}
