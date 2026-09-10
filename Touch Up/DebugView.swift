//
//  DebugView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 11.02.23.
//

import SwiftUI
import AppKit
import TouchUpCore

struct DebugView: View {
    
    @ObservedObject var model: TouchUp
    
    let locationID: HIDLocationID?
    
    let closeAction: ()->Void
    
    var pixelsPerMM: CGFloat
    
    init(model: TouchUp, locationID: HIDLocationID?, closeAction: @escaping ()->Void) {
        self.model = model
        self.locationID = locationID
        // Sizing the contacts needs the density of the panel actually on show. Asking for location
        // ID 0 asked about whichever screen happened to be connected most recently, so on a machine
        // with two digitizers the dots were drawn at the wrong scale on at least one of them — and
        // the overlay whose job is to tell you whether touches land correctly was itself lying
        // about how big a finger is. When no single digitizer is being shown, the last one touched
        // is the closest thing to an answer.
        let sizingID = locationID ?? model.touchManager.locationIDOfLastTouch
        self.pixelsPerMM = model.touchscreen(forLocationID: sizingID)?.pixelsPerMM() ?? 30
        self.closeAction = closeAction
    }
    
    func colorForPhase(_ phase: NSTouch.Phase) -> Color {
        switch phase {
        case .stationary:
            return Color.yellow
            
        case .began:
            return Color.blue
            
        case .ended:
            return Color.red
            
        case .cancelled:
            return Color.orange
            
        default:
            return Color.green
        }
    }
    
    var allTouches: [TUCTouch] {
        if let locationID = locationID {
            return model.touches.filter {$0.locationID == locationID}
        } else {
            return model.touches
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            
            Rectangle()
                .foregroundColor(Color(white: 0.1))
                .frame(maxWidth:.infinity, maxHeight: .infinity)
                .overlay(GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        ForEach(allTouches, id:\.uuid) { point in
                            Circle()
                                .foregroundColor(colorForPhase(point.phase))
                                // Ringed when the digitizer says this contact is *not* a
                                // fingertip. The test is the way round it is because the flag
                                // now means what HID means by it — so a ring is the unusual
                                // case worth looking at, where before every touch wore one.
                                .border(Color.gray, width: point.isConfidentFinger ? 0 : 5)
                                .opacity(point.isActive() ? 1 : 0.5)
                                .frame(width: 16 * pixelsPerMM, height: 16 * pixelsPerMM)
                                .position(x: geo.size.width * point.location.x,
                                          y: geo.size.height * point.location.y)
                            
                            
                            Text("\(point.contactID)")
                                .font(.system(size: 40))
                                .position(x: geo.size.width * point.location.x,
                                          y: geo.size.height * point.location.y)
                            
                        }
                    }
                })
            
            
            Button(action: {
                closeAction()
            }, label: {
                HStack {
                    Text("Close overlay with ")
                    Label("W", systemImage: "command.square.fill")
                    Text("or by mouse-clicking here")
                }
                .font(.largeTitle)
                .modify {
                    if #available(macOS 13.0, *) {
                        $0.fontDesign(.rounded)
                    } else { $0 }
                }
            })
            .foregroundColor(.gray)
            .buttonStyle(.borderless)
            .keyboardShortcut(KeyEquivalent("w"), modifiers: [.command])
            .padding(.bottom, 140)
        }
        
        
    }
}

struct DebugView_Previews: PreviewProvider {
    static var previews: some View {
        DebugView(model: TouchUp(), locationID: nil, closeAction: {})
    }
}


extension View {
    func modify<T: View>(@ViewBuilder _ modifier: (Self) -> T) -> some View {
        return modifier(self)
    }
}
