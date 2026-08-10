//
//  TUCKeyboardTyper.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 10.08.26.
//

#import "TUCKeyboardTyper.h"
#import "TUCCursorUtilities.h"
#import <Carbon/Carbon.h> // IsSecureEventInputEnabled

@implementation TUCKeyboardTyper

+ (instancetype)sharedInstance {
    static TUCKeyboardTyper *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[TUCKeyboardTyper alloc] init];
    });
    return sharedInstance;
}


- (void)pressKeyCode:(CGKeyCode)keyCode modifiers:(CGEventFlags)modifiers {
    // Deliberately not a second implementation of the same two lines: `-pressKey:modifiers:` also
    // carries the flags an arrow key is expected to arrive with, and posting through it keeps every
    // injected event going out of the same funnel with the same stamp.
    [[TUCCursorUtilities sharedInstance] pressKey:keyCode modifiers:modifiers];
}


- (BOOL)isSecureInputActive {
    return IsSecureEventInputEnabled();
}

@end
