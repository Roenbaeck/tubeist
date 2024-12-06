//
//  ContentView.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

import SwiftUI

struct ContentView: View {
    @State private var isRecording = false
    @State private var showSettings = false
    private let streamer = Streamer.shared
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = height * (16.0/9.0)
            
            ZStack {
                // Camera, web overlay, and controls contained within 16:9 area
                ZStack {
                    CameraMonitorView()
                    .onAppear {
                        streamer.startCamera()
                        print("Camera started")
                    }
                    
                    WebOverlayView()
                    
                    // Controls now positioned relative to 16:9 frame
                    HStack {
                        Spacer()
                        VStack {
                            Button(action: {
                                showSettings = true
                            }) {
                                Image(systemName: "gear")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                            }
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(25)
                            .sheet(isPresented: $showSettings) {
                                SettingsView()
                            }
                            .padding(.top)
                            
                            Spacer()
                            /*
                            AudioLevelMeter(audioLevel: $audioLevel)
                                .frame(width: 30)
                            */
                            Spacer()
                            
                            Button(action: {
                                if isRecording {
                                    Task {
                                        isRecording = false
                                        streamer.endStream()
                                        print("Stopped recording")
                                    }
                                } else {
                                    Task {
                                        streamer.startStream()
                                        isRecording = true
                                        print("Started recording")
                                    }
                                }
                            }) {
                                Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                                    .font(.system(size: 24))
                                    .foregroundColor(isRecording ? .red : .white)
                                    .frame(width: 50, height: 50)
                            }
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(25)
                            
                            Spacer()
                        }
                        .padding()
                        .offset(x: -10)
                    }
                }
                .frame(width: width, height: height)
                .position(x: geometry.size.width/2, y: geometry.size.height/2)
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}
