//
//  Capture3DScanView.swift
//  Lidar Scan
//
//  Created by Cedan Misquith on 27/04/25.
//

import SwiftUI

struct Capture3DScanView: View {
    @Environment(\.presentationMode) var mode: Binding<PresentationMode>
    @State var submittedExportRequest = false
    @State var submittedName = ""
    @State var pauseSession: Bool = false
    @State var shouldSmoothMesh: Bool = false
    @State var showMeshOverlay: Bool = false
    @State private var ceilingPointCount: Int = 0

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                ARWrapperView(submittedExportRequest: $submittedExportRequest,
                              submittedName: $submittedName,
                              pauseSession: $pauseSession,
                              shouldSmoothMesh: $shouldSmoothMesh,
                              //showMeshOverlay: $showMeshOverlay,
                              ceilingPointCount: $ceilingPointCount)
                .ignoresSafeArea()
                VStack {
                    HStack {
                        Button {
                            self.mode.wrappedValue.dismiss()
                        } label: {
                            Text("Back")
                                .frame(width: 80)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .frame(width: 40, height: 40)
                        Spacer()
                        Text("Ceiling Points: \(ceilingPointCount)")
                            .padding()
                            .background(Color.black.opacity(0.5))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }.padding(.leading, 40)
                    .padding(.trailing, 20)
                    Spacer()
                    Button {
                        pauseSession = true
                        alertView(title: "Save File",
                                  message: "Enter your file name",
                                  hintText: "file name") { text in
                            submittedName = text
                            submittedExportRequest.toggle()
                            self.mode.wrappedValue.dismiss()
                        } secondaryAction: {
                            print("Cancelled")
                            pauseSession = false
                        }
                    } label: {
                        Text("Export")
                            .frame(width: UIScreen.main.bounds.width-120)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    Button {
                        showMeshOverlay.toggle()
                    } label: {
                        Text(showMeshOverlay ? "Hide Overlay" : "Show Overlay")
                            .frame(width: UIScreen.main.bounds.width-120)
                            .padding()
                            .background(Color.blue.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    Button {
                        shouldSmoothMesh.toggle()
                    } label: {
                        Text("Smooth Mesh")
                            .frame(width: UIScreen.main.bounds.width-120)
                            .padding()
                            .background(Color.blue.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
            }
        }
    }
}

#Preview {
    Capture3DScanView()
}
