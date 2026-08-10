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
#include <stdint.h>

void OpenHIDManager(void *delegate);

void CloseHIDManager(void);

/// Opt-in: when enabled, accepted touch interfaces are opened exclusively (seized) so
/// macOS and other apps stop receiving their events — Touch Up becomes the sole handler.
/// Applies to currently-connected and future devices. Pen interfaces stay shared.
void SetTouchDevicesSeized(bool seize);

/// Allows or forbids one matched interface to move the pointer, keyed by location ID. Touch
/// data is read and published either way, so a device can be watched in the test overlay
/// before it is trusted with input. Interfaces that do not declare themselves a TouchScreen
/// start out forbidden, because a device claiming to be a TouchPad may genuinely be one.
void SetTouchDeviceDrivesPointer(uint32_t locationID, bool drivesPointer);

bool TouchDeviceDrivesPointer(uint32_t locationID);

/// Everything the interpreter has discovered about the connected devices: the HID element
/// tree, which interface was accepted for each screen and why, and any errors along the way.
/// Owned by the interpreter and valid until the next device event — copy it, don't retain it.
const char *HIDDiagnostics(void);

/// Whether the transcript hit its capacity and is missing its tail.
bool HIDDiagnosticsDidTruncate(void);

/// Appends a line to the transcript from the layers above, so an observation about a device
/// made while interpreting its touches lands in the same report as its descriptor.
void LogToHIDDiagnostics(const char *message);

/// Drops the transcript so a fresh one can be gathered (e.g. before asking the user to
/// re-plug a device).
void ResetHIDDiagnostics(void);

#endif /* HIDInterpreter_h */
