//
//  SettingsView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import SwiftUI
import TouchUpCore

/**
 What is left to decide.

 There used to be a section here for gestures, with a picker for what one finger does, another for
 what two do, and eight switches besides. All of it is gone, and none of it was replaced by a
 preference somewhere else: a tap clicks, a finger scrolls what it is on and drags what can be
 dragged, holding opens the menu, two fingers drag, pinching zooms, three sweep between desktops.
 A tablet does not ask, and neither does this.

 What survives is what Touch Up cannot work out for itself — which panel is which display, and how
 the glass is oriented on it — plus two deployment choices and the things you reach for when a
 screen misbehaves.
 */
struct SettingsView: View {

    @ObservedObject var model: TouchUp

    @State private var didCopyDiagnostics = false


    var welcomeBanner: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Touch Up 🐑")
                    .font(.largeTitle)
                Text("Touch Up converts USB HID data from any Windows certified touchscreen to mouse events.\nInjecting mouse events requires access to accessibility APIs. You can allow this by clicking the button below.")
            }

            HStack {
                Spacer()
                Button {
                    model.grantAccessibilityAccess()
                } label: {
                    Text("Grant Accessibility Access")
                }
                .buttonStyle(BorderedProminentButtonStyle())
            }
        }
    }


    var top: some View {
        Toggle(model.uiLabels(for: \.isPublishingMouseEventsEnabled).title, isOn: $model.isPublishingMouseEventsEnabled)
    }


    var keyboardSettings: some View {
        Group {
            Toggle(isOn: $model.isOnScreenKeyboardEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isOnScreenKeyboardEnabled))
            }

            Toggle(isOn: $model.isKeyboardAutoShowEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isKeyboardAutoShowEnabled))
            }
            .disabled(!model.isOnScreenKeyboardEnabled)
        }
    }


    var troubleshootingSettings: some View {
        Group {
            Toggle(isOn: $model.isKioskModeEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isKioskModeEnabled))
            }

            Toggle(isOn: $model.isExclusiveAccessEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isExclusiveAccessEnabled))
            }

            Toggle(isOn: $model.isTouchRepairEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isTouchRepairEnabled))
            }

            Toggle(isOn: $model.isNativeGesturesEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isNativeGesturesEnabled))
            }

            // Shown only when the switch turned itself back off. A setting that fails
            // silently leaves someone flipping it and wondering, which is the whole reason
            // the core reports a reason rather than just refusing.
            if let reason = model.nativeGesturesUnavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $model.isGestureInspectorEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isGestureInspectorEnabled))
            }

            diagnosticsButton
        }
    }


    var diagnosticsButton: some View {
        HStack(alignment: .top) {
            SettingsExplanationLabel(labels: ("Diagnostics",
                                              "Copies a description of your touchscreen, your displays and how they were matched up. Paste it into a GitHub issue when reporting a device that does not work."))

            Spacer(minLength: 8)

            Button {
                model.copyDiagnosticsToClipboard()
                didCopyDiagnostics = true
            } label: {
                Label(didCopyDiagnostics ? "Copied" : "Copy",
                      systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
            }
            .disabled(didCopyDiagnostics)
        }
        // Re-arm as soon as anything about the devices changes, so a second report after
        // re-plugging is one click away.
        .onChange(of: model.connectedDigitizers) { didCopyDiagnostics = false }
        .onChange(of: model.connectedScreens) { didCopyDiagnostics = false }
    }


    var footer: some View {
        HStack {
            Spacer()
            VStack {
                if let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("Touch Up v\(versionString)")
                        .font(.title2)
                }

                Text("Made with 🐑 in Aachen")
                    .font(.footnote)

                Link(destination: URL(string: "https://github.com/shueber/Touch-Up")!, label: {
                    Label("GitHub", systemImage: "link")
                        .foregroundColor(.accentColor)
                })
            }
            .padding(.vertical)
            Spacer()
        }
        .font(.footnote)
        .foregroundColor(.secondary)
    }


    var body: some View {
        Form {
            if !model.isAccessibilityAccessGranted {
                Section {
                    welcomeBanner
                } footer: {
                    Rectangle()
                        .frame(width: 0, height: 0)
                        .foregroundColor(.clear)
                }
            }

            Section {
                top
            }

            Section("Touchscreens") {
                DigitizerMappingView(model: self.model)
            }

            Section("Keyboard") {
                keyboardSettings
            }

            Section {
                troubleshootingSettings
            } header: {
                Text("Troubleshooting")
            } footer: {
                footer
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 660, maxWidth: .infinity,
               minHeight: 400, idealHeight: 620, maxHeight: .infinity)
    }
}


struct SettingsExplanationLabel: View {

    let labels: (title: String, description: String)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(labels.title)
            Text(labels.description)
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
}


struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(model: TouchUp())
    }
}
