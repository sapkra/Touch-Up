//
//  HIDInterpreter.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#ifndef HIDInterpreter_h
#define HIDInterpreter_h

#include <stdio.h>
#include <stdbool.h>

void OpenHIDManager(void *delegate);

void CloseHIDManager(void);

/// Opt-in: when enabled, accepted touch interfaces are opened exclusively (seized) so
/// macOS and other apps stop receiving their events — Touch Up becomes the sole handler.
/// Applies to currently-connected and future devices. Pen interfaces stay shared.
void SetTouchDevicesSeized(bool seize);

/// Everything the interpreter has discovered about the connected devices: the HID element
/// tree, which interface was accepted for each screen and why, and any errors along the way.
/// Owned by the interpreter and valid until the next device event — copy it, don't retain it.
const char *HIDDiagnostics(void);

/// Whether the transcript hit its capacity and is missing its tail.
bool HIDDiagnosticsDidTruncate(void);

/// Drops the transcript so a fresh one can be gathered (e.g. before asking the user to
/// re-plug a device).
void ResetHIDDiagnostics(void);

#endif /* HIDInterpreter_h */
