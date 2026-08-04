//
//  DigitizerMappingView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 04.06.26.
//

import SwiftUI

struct DigitizerMappingView: View {
    
    @ObservedObject var model: TouchUp
    
    var body: some View {
        if model.connectedDigitizers.isEmpty {
            noDigitizersPlaceholder
        } else {
            ForEach(model.connectedDigitizers) { digitizer in
                digitizerControls(for: digitizer)
            }
        }
    }
    
    
    var noDigitizersPlaceholder: some View {
        VStack(alignment: .center) {
            Image(systemName: "rectangle.slash")
                .font(.largeTitle)
            Text("Upon connecting a touchscreen, it will appear here.")
                .font(.caption)
                
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
    }
    
    
    @ViewBuilder
    private func digitizerControls(for digitizer: Digitizer) -> some View {
        VStack(alignment: .leading) {
            HStack(spacing: 4) {
                Text(digitizer.locationIDString)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    let screen = model.resolvedMapping(forLocationID: digitizer.locationID).screen
                    (NSApp.delegate as? AppDelegate)?.showDebugOverlay(on: screen, digitizer: digitizer.locationID)
                }, label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.forward.app.fill")
                        Text("Test")
                    }
                    .font(.caption)
                })
                .foregroundColor(.accentColor)
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                let current = model.digitizerConfigs[digitizer.locationID]?.additionalRotation ?? 0

                Text(digitizer.deviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if model.areAdditionalDigitizerRotationSettingsVisible || current != 0 || isMirrored(digitizer) {
                    rotationPicker(for: digitizer)
                    flipButtons(for: digitizer)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrowshape.forward.fill")
                    .foregroundColor(.secondary)

                Spacer(minLength: 8)

                screenPicker(for: digitizer)
            }
        }
    }

    @ViewBuilder
    private func screenPicker(for digitizer: Digitizer) -> some View {
        let selection = Binding {
            model.resolvedMapping(forLocationID: digitizer.locationID).screen?.uuid ?? ""
        } set: { uuid in
            model.assignScreen(model.connectedScreens.first { $0.uuid == uuid }, toDigitizer: digitizer.locationID)
        }

        Picker(selection: selection) {
            ForEach(model.connectedScreens) { screen in
                Text(screen.name).tag(screen.uuid)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }


    private func isMirrored(_ digitizer: Digitizer) -> Bool {
        model.isFlipped(axis: .horizontal, forDigitizer: digitizer.locationID)
            || model.isFlipped(axis: .vertical, forDigitizer: digitizer.locationID)
    }


    /// Mirror toggles for a glass wired backwards on one axis — the case where touches track
    /// correctly through the centre but run the wrong way towards the edges. No rotation can
    /// correct it, so without these the screen is simply unusable.
    @ViewBuilder
    private func flipButtons(for digitizer: Digitizer) -> some View {
        HStack(spacing: 2) {
            flipButton(for: digitizer, axis: .horizontal,
                       symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                       help: "Mirror horizontally")

            flipButton(for: digitizer, axis: .vertical,
                       symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                       help: "Mirror vertically")
        }
    }

    @ViewBuilder
    private func flipButton(for digitizer: Digitizer, axis: DigitizerAxis,
                            symbol: String, help: String) -> some View {
        let isOn = model.isFlipped(axis: axis, forDigitizer: digitizer.locationID)

        Button {
            model.setFlipped(!isOn, axis: axis, forDigitizer: digitizer.locationID)
        } label: {
            Image(systemName: symbol)
                .foregroundColor(isOn ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }


    @ViewBuilder
    private func rotationPicker(for digitizer: Digitizer) -> some View {
        let selection = Binding {
            model.digitizerConfigs[digitizer.locationID]?.additionalRotation ?? 0
        } set: { rotation in
            model.setRotation(rotation, forDigitizer: digitizer.locationID)
        }

        Picker(selection: selection) {
            let rotations: [CGFloat] = [0, 90, 180, 270]
            ForEach(rotations, id: \.self) {
                Text("\(Int($0))°").tag($0)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

}

#Preview {
    DigitizerMappingView(model: TouchUp())
}
