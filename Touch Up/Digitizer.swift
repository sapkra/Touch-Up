//
//  Digitizer.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 22.05.26.
//

import Foundation
import CoreGraphics

/// Per-digitizer settings, keyed by `HIDLocationID` and persisted to `UserDefaults`.
///
/// Only the screen identity (`screenID` + `screenUUID`) and `additionalRotation` are stored.
/// The actually resolved `TUCScreen` is *not* kept here: the screen list is rebuilt from
/// scratch on every display reconfiguration, so any held reference would go stale. The screen
/// is therefore resolved lazily from this identity (see `TouchUp.resolvedMapping(forLocationID:)`).
struct DigitizerConfig: Codable, Hashable {
    /// `CGDirectDisplayID` — effectively the index in the screen arrangement. Weaker match.
    var screenID: UInt?
    /// Stable per physical panel across launches/rearrangements. Stronger match.
    var screenUUID: String?
    var additionalRotation: CGFloat = 0

    /// Mirrors the digitizer's own axes, applied before any rotation. A glass wired backwards
    /// on one axis cannot be corrected by rotation alone: 0/90/180/270 are the four rotations
    /// of the panel, and every one of them preserves handedness, while this needs it reversed.
    var isFlippedHorizontally: Bool = false
    var isFlippedVertically: Bool = false

    /// Whether this digitizer may move the pointer. `nil` means "not decided by the user", in
    /// which case the core's own judgement from the device's declared HID usage applies.
    /// Storing the override rather than the effective value keeps a device that is later
    /// recognised properly from being pinned to an old guess.
    var drivesPointer: Bool?

    init() {}

    /// Decoded key by key with `decodeIfPresent` instead of relying on the synthesized
    /// initialiser, which throws on any key it cannot find — *including* one that has a default
    /// value. Since `TouchUp.loadDigitizerConfigs()` swallows a decode failure and returns
    /// early, one missing key silently discards every stored digitizer→screen mapping.
    ///
    /// That has already happened once: `additionalRotation` was added to this struct without a
    /// tolerant decoder, so upgrading from a build that predates it drops all mappings. Every
    /// field added from here on must decode as absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        screenID   = try container.decodeIfPresent(UInt.self, forKey: .screenID)
        screenUUID = try container.decodeIfPresent(String.self, forKey: .screenUUID)

        additionalRotation    = try container.decodeIfPresent(CGFloat.self, forKey: .additionalRotation) ?? 0
        isFlippedHorizontally = try container.decodeIfPresent(Bool.self, forKey: .isFlippedHorizontally) ?? false
        isFlippedVertically   = try container.decodeIfPresent(Bool.self, forKey: .isFlippedVertically) ?? false
        drivesPointer         = try container.decodeIfPresent(Bool.self, forKey: .drivesPointer)
    }
}

/// What dragging two fingers does. Kept separate from the one-finger setting rather than derived
/// from it: the two are a genuine pair of choices, and deriving one silently meant the more useful
/// half of the gesture set was never visible in the settings at all.
enum TwoFingerDragAction: Int, CaseIterable {
    /// Holds the mouse button and moves it — pans a map, moves a window, works a slider, selects
    /// text. None of that is reachable any other way while one finger is scrolling.
    case drag = 0
    case scroll = 1
    case nothing = 2
}


enum DigitizerAxis {
    case horizontal
    case vertical
}

/// How confidently a digitizer's stored screen identity could be resolved against the
/// currently connected screens. Transient (computed on every resolution), never persisted.
/// Intended purely as a UI hint to flag potentially wrong mappings.
enum ScreenMatch {
    case exact       // UUID hit — safe
    case idFallback  // only the display ID matched; UUID gone/changed (e.g. after a rearrange)
    case implicit    // no stored match; fell back to the most recently added screen
    case unmapped    // no screen could be resolved at all
}

struct Digitizer: Codable, Hashable, Identifiable {

    let locationID: HIDLocationID
    let name: String?
    let vendorID: UInt16?
    let productID: UInt16?
    let bcdDevice: UInt16?
    let serialNumber: String?

    init(locationID: HIDLocationID) {
        let properties = locationID.properties
        self.locationID = locationID
        self.name = properties?.name
        self.vendorID = properties?.vendorID
        self.productID = properties?.productID
        self.bcdDevice = properties?.bcdDevice
        self.serialNumber = properties?.serialNumber
    }
    
    var deviceName: String {
        self.name ?? "Touch Digitizer"
    }
    
    var locationIDString: String {
        "0x\(String(format: "%08x", locationID))"
    }

    var id: HIDLocationID {
        locationID
    }
}
