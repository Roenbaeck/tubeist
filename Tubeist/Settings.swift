//
//  Settings.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//
import SwiftUI

struct SettingsView: View {
    @AppStorage("HLSServer") private var hlsServer: String = ""
    @AppStorage("Username") private var username: String = ""
    @AppStorage("Password") private var password: String = ""
    @AppStorage("SaveFragmentsLocally") private var saveFragmentsLocally: Bool = false
    @AppStorage("SelectedBitrate") private var selectedBitrate: Int = 1_000_000
    @AppStorage("OverlayURL") private var overlayURL: String = ""
    @Environment(\.presentationMode) private var presentationMode

    var bitrates: [Int] = [1_000_000, 2_000_000, 3_000_000, 4_000_000, 6_000_000, 10_000_000, 20_000_000]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("HLS Server"), footer: Text("Enter the URI of the HLS streaming server.")) {
                    TextField("HLS Server URI", text: $hlsServer)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Authentication"), footer: Text("Provide your streaming server login details.")) {
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.username)
                    
                    SecureField("Password", text: $password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.password)
                }
                
                Section(header: Text("Bitrate"), footer: Text("Choose the desired bitrate for video streaming.")) {
                    Picker("Select Bitrate", selection: $selectedBitrate) {
                        ForEach(bitrates, id: \.self) { bitrate in
                            Text("\(bitrate / 1_000_000) Mbps").tag(bitrate)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                Section(header: Text("Overlay"), footer: Text("Optional: Add a web overlay URL for your stream.")) {
                    TextField("Web Overlay URL", text: $overlayURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section {
                    Toggle("Save Fragments Locally", isOn: $saveFragmentsLocally)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Save") {
                presentationMode.wrappedValue.dismiss()
            }
            .buttonStyle(.borderedProminent))
        }
    }
}
