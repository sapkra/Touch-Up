# Touch-Up
**Universal user-level driver to support touchscreens on macOS**
<hr/>

Most current touchscreens work with Microsoft Windows out-of-the-box as they implement a standardized communication via USB HID. However, nothing happens when connecting these screens to a Mac.
The goal of Touch Up was to provide a simple, general-purpose driver that enables plug-and-play support for touchscreens on macOS. 
The code in this repository provides a user-space driver that reads and processes the HID data into a set of touches and different utilities to inject mouse events into the system.

## What can you do with this App?
The Touch Up **utility app** lets you control your Mac with any connected touchscreen. It behaves
the way an iPad does, and there is nothing to configure to get that — the gestures are fixed:

- **Tap** to click. Tap a window that is not in front and it comes forward *and* acts on what you
  touched, in one tap.
- **Drag one finger** to scroll. Touch Up asks what is under your finger first, so the same flick
  scrolls a web page, moves a window by its title bar, slides a slider, and drags an icon around
  the desktop.
- **Hold still** to open the right-click menu. Hold in a text field and you start selecting text
  instead.
- **Drag two fingers** to drag anything, for the places where nothing can be read well enough to
  tell.
- **Pinch two fingers** to zoom.
- **Sweep three fingers** to move between desktops, up for Mission Control, down for the app's
  windows.
- There is **no mouse pointer**. Touching hides it; moving a mouse or trackpad brings it straight
  back.
- An **on-screen keyboard** can rise by itself when you tap somewhere you can type, for a machine
  with no keyboard attached.

The settings window is for the things Touch Up cannot work out on its own: which panel maps to
which display, and how the glass is oriented on it.

### Requirements
macOS 26 or later.

### Installing the App
- Compile the app or [download the latest notarized build here](https://github.com/shueber/Touch-Up/releases).
- If you wish, move the app into your Applications folder and add it as a Login item.
- Launch it and allow Accessibility access.
- Plug in your touchscreen and start touching.


### Compatibility
Touch Up requires **macOS 27 or later**. Older releases of macOS are supported by Touch Up 1.x.

Touch Up should work with any touchscreen that also works with Windows.
We used the following screens for testing:

- Iiyama TF3222MC and T2336MSC-B2
- 3M C4667PW




## The *TouchUpCore* Framework
Game developers, researchers, and others who need access to all touch data can also benefit from this project by integrating the TouchUpCore **framework** themselves. It provides simple access to all touches recognized on the touch surface, simplifying multitouch prototype development in macOS.

The Touch Up app itself is an example of integrating the TouchUpCore framework. You can have a look at the *DebugView* to see how you can visualize the different touch points. Remember that your app needs an Entitlement to access USB if running in the Sandbox.
