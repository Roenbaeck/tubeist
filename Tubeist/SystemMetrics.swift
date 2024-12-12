//
//  SystemMetrics.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-08.
//
import SwiftUI
import Foundation
@preconcurrency import Darwin

struct SystemMetricsView: View {
    @Environment(AppState.self) var appState
    private let processInfo = ProcessInfo()
    @State private var cpuUsage: Float = 0
    @State private var batteryLevel: Float = 0
    @State private var thermalLevel: String = "Low"
    @State private var networkMbps: Int = 0
    @State private var networkUtilization: Int = 0
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 10) {
            Text("CPU: \(String(format: "%.1f", cpuUsage))%")
            Text("Battery: \(String(format: "%.0f", batteryLevel))%")
            Text("Temp: \(thermalLevel)")
            Text("UL: \(networkMbps) Mbps")
            Text("(\(networkUtilization)% utilization)")
        }
        .font(.system(size: 13))
        .lineLimit(1) // Ensure text stays on a single line
        .foregroundColor(.white)
        .onReceive(timer) { _ in
            updateSystemMetrics()
        }
        .onAppear {
            updateSystemMetrics()
        }
        .onTapGesture {
            appState.isAudioLevelRunning.toggle()
        }
    }
    
    private func updateSystemMetrics() {
        Task {
            self.cpuUsage = self.getCPUUsage()
            self.batteryLevel = self.getBatteryLevel()
            self.thermalLevel = self.getThermalLevel()
            (self.networkMbps, self.networkUtilization) = await FragmentPusher.shared.networkPerformance()
        }
    }
    
    public func getCPUUsage() -> Float {
        var result: Int32
        var threadList = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        var threadCount = UInt32(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        var threadInfo = thread_basic_info()
        
        result = withUnsafeMutablePointer(to: &threadList) {
            $0.withMemoryRebound(to: thread_act_array_t?.self, capacity: 1) {
                task_threads(mach_task_self_, $0, &threadCount)
            }
        }
        
        if result != KERN_SUCCESS { return 0 }
        
        return (0 ..< Int(threadCount))
            .compactMap { index -> Float? in
                var threadInfoCount = UInt32(THREAD_INFO_MAX)
                result = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        thread_info(threadList[index], UInt32(THREAD_BASIC_INFO), $0, &threadInfoCount)
                    }
                }
                if result != KERN_SUCCESS { return nil }
                let isIdle = threadInfo.flags == TH_FLAGS_IDLE
                
                return !isIdle ? (Float(threadInfo.cpu_usage) / Float(TH_USAGE_SCALE)) * 100 : nil
            }
            .reduce(0, +)
    }
    
    private func getBatteryLevel() -> Float {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryLevel * 100
    }
    private func getThermalLevel() -> String {
        switch processInfo.thermalState {
        case .nominal: return "Low"
        case .fair: return "Medium"
        case .serious: return "High"
        case .critical: return "Critical"
        default: return "Unknown"
        }
    }
    
}



