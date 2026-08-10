//
//  TUCKeyboardTyper.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 10.08.26.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Sends key presses on behalf of an on-screen keyboard.

 This exists as its own class only to be reachable from outside the framework: the pointer synthesis
 in `TUCCursorUtilities` is deliberately not published, so this is the thin surface a keyboard needs
 without exposing the rest. Every event still goes out through the one place in `TUCCursorUtilities`
 that stamps injected events as ours.
 */
@interface TUCKeyboardTyper : NSObject

+ (instancetype)sharedInstance;

/**
 Taps a key, exactly as a real keyboard would report it.

 Keys are sent by virtual key code with modifier flags rather than as literal text, which is what
 makes them behave: the key code is what the active keyboard layout, a dead key, an input method and
 an application's own shortcut table are all defined against. Typing `c` with Command held has to be
 the *key* C for an application to see Copy, and on a German layout the key at `kVK_ANSI_LeftBracket`
 has to be allowed to mean `ü`.

 Pass the modifiers the keyboard is holding — the caller owns that state, since whether Shift stays
 down for one key or latches is a question about a keyboard's behaviour, not about events.
 */
- (void)pressKeyCode:(CGKeyCode)keyCode modifiers:(CGEventFlags)modifiers
NS_SWIFT_NAME(press(keyCode:modifiers:));

/**
 Whether macOS is currently accepting keystrokes from software at all.

 A password field, or a terminal with secure keyboard entry, can ask the system to stop delivering
 injected input. Nothing an application can do gets around it, so the only honest response is to
 tell the user that this particular field cannot be typed into rather than let their keypresses
 disappear.
 */
@property (readonly) BOOL isSecureInputActive;

@end

NS_ASSUME_NONNULL_END
