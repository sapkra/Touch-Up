//
//  AppDelegate.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import Cocoa
import SwiftUI
import Combine
import TouchUpCore


@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    let model = TouchUp()
    
    
    var statusItem: NSStatusItem!
    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var activationMenuItem: NSMenuItem!
    @IBOutlet weak var keyboardMenuItem: NSMenuItem!

    var observers = [AnyCancellable]()
    
    
    
    lazy var settingsWindow: SettingsWindow = {
        return SettingsWindow.window(model: self.model)
    }()
    
    lazy var debugOverlay: DebugOverlay = {
        return DebugOverlay.overlay(model: self.model)
    }()
    
    @IBAction func toggleActivationMenu(_ sender: Any) {
        self.model.isPublishingMouseEventsEnabled.toggle()
    }

    /// The way to the keyboard that always works, however well the automatic side manages to guess
    /// whether a text field has focus.
    @IBAction func toggleKeyboardMenu(_ sender: Any) {
        self.model.keyboard.toggle()
    }

    /// Greys the keyboard item out rather than letting it silently do nothing while the feature is
    /// switched off, so the settings are discoverable as the way in. Automatic menu enabling would
    /// otherwise enable it purely because the action exists.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem == self.keyboardMenuItem {
            return self.model.isOnScreenKeyboardEnabled
        }
        return true
    }
    
    
    
    //MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem.menu = self.statusMenu
        
        self.observers.append(
            self.model.$connectionState
                .receive(on: DispatchQueue.main)
                .sink{status in
                    DispatchQueue.main.async {
                        self.statusItem.button?.image = status.image
                    }
                    
                }
        )
        
        self.observers.append(
            self.model.$isPublishingMouseEventsEnabled
                .receive(on: DispatchQueue.main)
                .sink{
                    self.activationMenuItem.state = $0 ? .on : .off
                }
        )

        self.observers.append(
            self.model.keyboard.$isVisible
                .receive(on: DispatchQueue.main)
                .sink{
                    self.keyboardMenuItem?.state = $0 ? .on : .off
                }
        )

        
        self.model.touchManager.start()
        
        
        if !model.isAccessibilityAccessGranted {
            self.showPreferences(nil)
        }
        
        #if DEBUG
//        self.showPreferences(nil)
//        self.showDebugOverlay()
        #endif
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        self.model.persistAllDigitizerMappings()

        // Before anything else: a hidden pointer is process state, so quitting while it is hidden
        // would leave the user with no visible pointer and nothing left running to bring it back.
        self.model.touchManager.hidesCursor = false
        self.model.touchManager.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    
    @IBAction func showPreferences(_ sender: Any?) {
        self.settingsWindow.makeVisible()
    }
    
    func showDebugOverlay(on screen: TUCScreen? = nil, digitizer locationID: HIDLocationID? = nil) {
        let preState = self.model.isPublishingMouseEventsEnabled
        self.model.isPublishingMouseEventsEnabled = false
        DebugOverlay.completion = {[unowned self] in
            self.debugOverlay.close()
            self.model.isPublishingMouseEventsEnabled = preState
        }
        
        if let screen = screen ?? TUCScreen.allScreens().first {
            self.debugOverlay.makeVisible(onScreen: screen, digitizerLocationID: locationID)
        }
    }
}



class SettingsWindow: NSWindow {
    
    var model: TouchUp?

    /// Roomy enough that the explanation next to each setting stays on one or two lines
    /// and a whole section is readable without scrolling.
    private static let preferredContentSize = NSSize(width: 660, height: 760)

    static func window(model: TouchUp) -> SettingsWindow {
        let vc = NSHostingController(rootView: SettingsView(model:model))
        let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: preferredContentSize),
                                    styleMask: [.closable, .titled, .fullSizeContentView, .resizable],
                                    backing: .buffered,
                                    defer: true,
                                    screen: nil)

        window.title = "Touch Up Settings"
        window.tabbingMode = .disallowed
        window.model = model
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .transient]

        let windowController = NSWindowController(window: window)

        // Adopting the content view controller resizes the window to the hosting
        // controller's fitting size, so the preferred size has to be applied afterwards.
        windowController.contentViewController = vc
        window.setContentSize(window.contentSizeFittingScreen(preferredContentSize))
        window.center()
        return window
    }

    /// The preferred size, shrunk to whatever the screen can actually show.
    private func contentSizeFittingScreen(_ preferred: NSSize) -> NSSize {
        guard let visible = (self.screen ?? NSScreen.main)?.visibleFrame else { return preferred }
        let available = self.contentRect(forFrameRect: visible).size
        return NSSize(width: min(preferred.width, available.width),
                      height: min(preferred.height, available.height))
    }
    
    override func close() {
        self.model?.savePreferences()
//        self.model?.persistAllDigitizerMappings()
        NSApp.stopModal()
        super.close()
    }
    
    func makeVisible() {
        let alreadyOnScreen = self.isVisible
        
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !alreadyOnScreen {
            self.center()
        }
    }
}
