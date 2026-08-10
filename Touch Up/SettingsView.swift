//
//  SettingsView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import SwiftUI
import TouchUpCore

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

    
    var tabletModeRow: some View {
        HStack(alignment: .top) {
            SettingsExplanationLabel(labels: ("iPad Mode",
                                              "One finger scrolls, a tap clicks, holding opens the right-click menu, two fingers drag, and pinch zooms — with no mouse pointer. Sets the options below; you can still change any of them afterwards."))

            Spacer(minLength: 8)

            if model.isTabletModeActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            } else {
                Button("Use iPad Mode") { model.activateTabletMode() }
                    .font(.caption)
            }
        }
    }


    var gestureSettings: some View {
        Group {
            tabletModeRow

            
            let mode_ = Binding {
                if model.isClickOnLiftEnabled { return 2 }
                if model.isDraggingWithOneFingerEnabled { return 3 }
                return model.isScrollingWithOneFingerEnabled ? 0 : 1
            } set: { value in
                model.isScrollingWithOneFingerEnabled = value == 0
                model.isClickOnLiftEnabled = value == 2
                model.isDraggingWithOneFingerEnabled = value == 3
            }

            Picker(selection: mode_) {
                Text("Scroll").tag(0)
                Text("Move Cursor").tag(1)
                Text("Point and Click").tag(2)
                Text("Drag").tag(3)
            } label: {
                SettingsExplanationLabel(labels: ("On Finger Drag", "Specify which action should occur when dragging one finger on the touch screen. If you set this to \"Drag\", set Two Finger Drag to \"Scroll\" so that scrolling is still reachable."))
            }

            
            Picker(selection: $model.twoFingerDragAction) {
                Text("Drag").tag(TwoFingerDragAction.drag)
                Text("Scroll").tag(TwoFingerDragAction.scroll)
                Text("Nothing").tag(TwoFingerDragAction.nothing)
            } label: {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.twoFingerDragAction))
            }


            Toggle(isOn: $model.isSecondaryClickEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isSecondaryClickEnabled))
            }
            
            Toggle(isOn: $model.isMagnificationEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isMagnificationEnabled))
            }
            
            Toggle(isOn: $model.isLongPressContextMenuEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isLongPressContextMenuEnabled))
            }

            Toggle(isOn: $model.isCursorHiddenEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isCursorHiddenEnabled))
            }

            Toggle(isOn: $model.isClickWindowToFrontEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isClickWindowToFrontEnabled))
            }
        }
    }
    
    
    var parameterSettings: some View {
        Group {
            // Reaches 0.8 s so a genuine long press is selectable at all: iPadOS uses about
            // 0.5 s, and the old 0.16 s ceiling meant any unhurried tap counted as a hold.
            Slider(value: $model.holdDuration, in: 0.0...0.8, step: 0.05){
                SettingsExplanationLabel(labels: model.uiLabels(for: \.holdDuration))
            }
            
            // Range starts at 1: a zero zone can never be satisfied. It reaches well past the
            // default of 8 because the distance check used to be inert, so this is the first
            // release where the ceiling actually binds — imprecise taps on a large panel need
            // the headroom to keep double clicking.
            Slider(value: $model.doubleClickDistance, in: 1...16, step: 1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.doubleClickDistance))
            }

            // Reaches 16 mm because pointing precision scales with the panel: a tap on a 32"
            // display is nothing like a tap on a 7" one.
            Slider(value: $model.tapDistance, in: 0.5...16, step: 0.5) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.tapDistance))
            }
        }
    }
    
    
    var troubleshootingSettings: some View {
        Group {
            let errorResistance_ = Binding {Double(model.errorResistance)} set: {
                model.errorResistance = NSInteger(Int($0)) }
            
            Slider(value: errorResistance_ , in: 0...10, step: 1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.errorResistance))
            }
            
            Toggle(isOn: $model.ignoreOriginTouches) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.ignoreOriginTouches))
            }

            Toggle(isOn: $model.areAdditionalDigitizerRotationSettingsVisible) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.areAdditionalDigitizerRotationSettingsVisible))
            }

            Toggle(isOn: $model.isExclusiveAccessEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isExclusiveAccessEnabled))
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
        .onChange(of: model.connectedDigitizers) { _ in didCopyDiagnostics = false }
        .onChange(of: model.connectedScreens) { _ in didCopyDiagnostics = false }
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
    
    var container: some View {
        if #available(macOS 13.0, *) {
            return Form {
                if !model.isAccessibilityAccessGranted {
                    Section {
                        welcomeBanner
                    } footer: {
                        Rectangle()
                            .frame(width:0, height:0)
                            .foregroundColor(.clear)
                    }

                }
                
                Section {
                    top
                }

                Section("Touchscreens") {
                    DigitizerMappingView(model: self.model)
                }

                Section("Gestures") {
                    gestureSettings
                }
                
                Section("Parameters") {
                    parameterSettings
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

        } else {
            return List {
                LegacySection {
                    top
                }

                LegacySection(title: "Touchscreens") {
                    DigitizerMappingView(model: self.model)
                }

                LegacySection(title: "Gestures") {
                    gestureSettings
                }
                
                LegacySection(title: "Parameters") {
                    parameterSettings
                }
                
                LegacySection(title: "Troubleshooting") {
                    troubleshootingSettings
                }
                
                footer
                
            }
            .toggleStyle(.switch)
            
        }
    }
    
    
    
    var body: some View {
        container
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 350,  maxHeight: .infinity)
        
    }
}


struct LegacySection<Content: View>: View {
    var title: String? = nil
    var content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading) {
            if let title = title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .foregroundColor(.secondary.opacity(0.1))
                    .shadow(radius: 1)
                    
                    
                
                VStack(alignment: .leading, spacing: 16, content: content)
                    .padding(12)
            }
            
        }
        .padding(.bottom)
    }
}


struct SettingsExplanationLabel: View {
    
    let labels: (title:String, description:String)
    
    var body: some View {
        VStack(alignment:.leading, spacing: 4) {
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
