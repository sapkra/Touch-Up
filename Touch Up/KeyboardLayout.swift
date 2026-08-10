//
//  KeyboardLayout.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 10.08.26.
//

import AppKit
import Carbon.HIToolbox


/// One key on the on-screen keyboard.
///
/// A character key is identified by the *position* it occupies on a keyboard rather than by the
/// letter printed on it, because which letter that is depends on the layout the user has chosen.
/// Asking the system what each position currently produces is what lets the same key be `y` on a
/// US layout and `z` on a German one, and it is also what makes ⌘C reach an application as Copy:
/// the key code is the part a shortcut is defined against.
enum KeyCap: Hashable {
    case character(CGKeyCode)
    case control(ControlKey)
    case modifier(ModifierKey)
    case space
    /// Puts the keyboard away. Not a key any hardware has, and the only way back from a keyboard
    /// that has decided to stay open when it should not have.
    case dismiss
    /// Keeps the keyboard open until it is dismissed by hand, whatever the focus does.
    case pin
}


enum ControlKey: Hashable {
    case delete, `return`, tab, escape
    case arrowLeft, arrowRight, arrowUp, arrowDown

    var keyCode: CGKeyCode {
        switch self {
        case .delete:      return CGKeyCode(kVK_Delete)
        case .return:      return CGKeyCode(kVK_Return)
        case .tab:         return CGKeyCode(kVK_Tab)
        case .escape:      return CGKeyCode(kVK_Escape)
        case .arrowLeft:   return CGKeyCode(kVK_LeftArrow)
        case .arrowRight:  return CGKeyCode(kVK_RightArrow)
        case .arrowUp:     return CGKeyCode(kVK_UpArrow)
        case .arrowDown:   return CGKeyCode(kVK_DownArrow)
        }
    }

    var label: String {
        switch self {
        case .delete:     return "⌫"
        case .return:     return "⏎"
        case .tab:        return "⇥"
        case .escape:     return "esc"
        case .arrowLeft:  return "←"
        case .arrowRight: return "→"
        case .arrowUp:    return "↑"
        case .arrowDown:  return "↓"
        }
    }
}


enum ModifierKey: Hashable, CaseIterable {
    case shift, capsLock, control, option, command

    var flag: CGEventFlags {
        switch self {
        case .shift:    return .maskShift
        case .capsLock: return .maskAlphaShift
        case .control:  return .maskControl
        case .option:   return .maskAlternate
        case .command:  return .maskCommand
        }
    }

    var label: String {
        switch self {
        case .shift:    return "⇧"
        case .capsLock: return "⇪"
        case .control:  return "⌃"
        case .option:   return "⌥"
        case .command:  return "⌘"
        }
    }

    /// Whether the modifier stays on until it is pressed again, rather than releasing after the next
    /// key. Caps Lock latches on real hardware too; the others are one-shot so that ⌘ followed by C
    /// is Copy and the key after it is not.
    var latches: Bool {
        self == .capsLock
    }
}


/// The keys, arranged, with each character key's caption resolved from whichever keyboard layout the
/// user currently has selected.
final class KeyboardLayout: ObservableObject {

    static let shared = KeyboardLayout()

    /// What each key position produces, by the modifiers being held.
    ///
    /// Caps Lock is resolved separately from Shift rather than treated as the same thing, because on
    /// every layout it only reaches the letters: with Caps Lock on, the `1` key still types `1`. A
    /// keyboard that captioned it `!` would be telling the user something untrue about that key.
    struct Caption {
        let plain: String
        let shifted: String
        let capsLocked: String
    }

    @Published private(set) var captions: [CGKeyCode: Caption] = [:]

    /// Name of the layout the captions came from, e.g. "German". Reported in the diagnostics,
    /// because "the keys are all wrong" and "the wrong layout is selected" look identical from here.
    @Published private(set) var sourceName: String = "unknown"

    private init() {
        refresh()

        // The user can change layout at any time, including from the input menu while the keyboard
        // is open, and a keyboard showing the previous layout's captions would be lying about what
        // its keys do.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }


    // MARK: - Arrangement

    /// The rows, shaped like a tablet's keyboard rather than a full desktop one: no function row, no
    /// numeric pad, and the modifiers that only exist to be held gathered into the bottom row.
    ///
    /// A character key whose position produces nothing on the current layout is dropped, which is
    /// what quietly reconciles ANSI and ISO keyboards: the extra key beside the left Shift is only
    /// there when the selected layout has something to put on it.
    var rows: [[KeyCap]] {
        let arrangement: [[KeyCap]] = [
            Self.digitRow.map { .character($0) } + [.control(.delete)],

            [.control(.tab)] + Self.upperRow.map { .character($0) },

            [.modifier(.capsLock)] + Self.homeRow.map { .character($0) } + [.control(.return)],

            [.modifier(.shift)] + Self.lowerRow.map { .character($0) } + [.modifier(.shift)],

            [.control(.escape), .modifier(.control), .modifier(.option), .modifier(.command),
             .space,
             .control(.arrowLeft), .control(.arrowUp), .control(.arrowDown), .control(.arrowRight),
             .pin, .dismiss],
        ]

        return arrangement.map { row in
            row.filter { cap in
                guard case let .character(keyCode) = cap else { return true }
                return !(captions[keyCode]?.plain ?? "").isEmpty
            }
        }
    }

    private static let digitRow: [CGKeyCode] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0,
        kVK_ANSI_Minus, kVK_ANSI_Equal,
    ].map(CGKeyCode.init)

    private static let upperRow: [CGKeyCode] = [
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T,
        kVK_ANSI_Y, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
    ].map(CGKeyCode.init)

    private static let homeRow: [CGKeyCode] = [
        kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G,
        kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
        kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Backslash,
    ].map(CGKeyCode.init)

    /// `kVK_ISO_Section` leads, and drops out by itself on an ANSI layout that puts nothing there.
    private static let lowerRow: [CGKeyCode] = [
        kVK_ISO_Section,
        kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B,
        kVK_ANSI_N, kVK_ANSI_M,
        kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash, kVK_ANSI_Grave,
    ].map(CGKeyCode.init)

    private static var allCharacterKeyCodes: [CGKeyCode] {
        digitRow + upperRow + homeRow + lowerRow
    }


    // MARK: - Captions

    func caption(for keyCode: CGKeyCode, shifted: Bool, capsLocked: Bool) -> String {
        guard let caption = captions[keyCode] else { return "" }
        if shifted { return caption.shifted }
        if capsLocked { return caption.capsLocked }
        return caption.plain
    }

    @objc func refresh() {
        // The ASCII-capable source is the fallback rather than a hardcoded layout of our own. An input
        // source that is an input method — Pinyin, Kotoeri — carries no key data to translate against,
        // and without something to translate every character key would come back blank and be dropped,
        // leaving a keyboard of nothing but Shift and Return.
        let candidates = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]

        guard let (source, dataRef) = candidates.lazy.compactMap({ source -> (TISInputSource, UnsafeMutableRawPointer)? in
            guard let source,
                  let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            return (source, data)
        }).first else {
            return
        }

        if let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            sourceName = Unmanaged<CFString>.fromOpaque(name).takeUnretainedValue() as String
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue() as Data

        var resolved: [CGKeyCode: Caption] = [:]

        layoutData.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }

            for keyCode in Self.allCharacterKeyCodes {
                let plain = Self.translate(keyCode: keyCode, carbonModifiers: 0, layout: layout)
                let shifted = Self.translate(keyCode: keyCode, carbonModifiers: shiftKey, layout: layout)
                let capsLocked = Self.translate(keyCode: keyCode, carbonModifiers: alphaLock, layout: layout)

                // A key position that is not on this layout at all produces nothing under any of
                // them, and `rows` takes an empty caption as its cue to drop the key.
                resolved[keyCode] = Caption(plain: plain,
                                            shifted: shifted.isEmpty ? plain : shifted,
                                            capsLocked: capsLocked.isEmpty ? plain : capsLocked)
            }
        }

        captions = resolved
    }

    private static func translate(keyCode: CGKeyCode,
                                 carbonModifiers: Int,
                                 layout: UnsafePointer<UCKeyboardLayout>) -> String {
        // UCKeyTranslate wants the modifiers in the packed form the old Event Manager used, which is
        // the high byte of the Carbon modifier constants.
        let modifiers = UInt32((carbonModifiers >> 8) & 0xFF)

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = UCKeyTranslate(layout,
                                    UInt16(keyCode),
                                    UInt16(kUCKeyActionDisplay),
                                    modifiers,
                                    UInt32(LMGetKbdType()),
                                    // A dead key should caption itself — `´` rather than nothing at
                                    // all — even though pressing it really does start a sequence.
                                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                    &deadKeyState,
                                    characters.count,
                                    &length,
                                    &characters)

        guard status == noErr, length > 0 else { return "" }

        let text = String(utf16CodeUnits: characters, count: length)

        // Control characters have no caption worth drawing, and a key position that reports one is
        // not a key this keyboard should be offering.
        return text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } ? text : ""
    }
}
