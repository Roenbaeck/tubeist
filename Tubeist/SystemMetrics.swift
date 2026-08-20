//
//  SystemMetrics.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-08.
//
import SwiftUI
import Foundation
@preconcurrency import Darwin

struct SystemCPUSampler: Sendable {
    func usage() -> Float {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let listResult = task_threads(mach_task_self_, &threadList, &threadCount)
        guard listResult == KERN_SUCCESS, let threadList else {
            return 0
        }

        defer {
            for index in 0 ..< Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threadList[index])
            }
            let byteCount = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                byteCount
            )
        }

        var total: Float = 0
        for index in 0 ..< Int(threadCount) {
            var info = thread_basic_info_data_t()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let infoResult = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(
                        threadList[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        $0,
                        &infoCount
                    )
                }
            }
            guard infoResult == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else {
                continue
            }
            total += (Float(info.cpu_usage) / Float(TH_USAGE_SCALE)) * 100
        }
        return total
    }
}

struct SystemMetricsView: View {
    @Environment(AppState.self) var appState
    private let processInfo = ProcessInfo()
    @State private var cpuUsage: Float = 0
    @State private var batteryLevel: Float = 0
    @State private var thermalLevel: String = "Low"
    @State private var networkMbps: Int = 0
    @State private var networkUtilization: Int = 0
    @State private var fragmentBufferCount: Int = 0
    @State private var updateSystemMetricsTask: Task<Void, Never>?
    private let cpuSampler = SystemCPUSampler()
            
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                metricLabels
            }
            VStack(alignment: .leading, spacing: 2) {
                metricLabels
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundColor(BRIGHTER_THAN_WHITE)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "CPU \(String(format: "%.1f", cpuUsage)) percent, battery \(String(format: "%.0f", batteryLevel)) percent, temperature \(thermalLevel), network \(networkMbps) megabits per second at \(networkUtilization) percent utilization, \(fragmentBufferCount) fragments buffered"
        )
        .onAppear {
            updateSystemMetricsTask = Task(priority: .utility) {
                while !Task.isCancelled {
                    await updateSystemMetrics()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        .onDisappear {
            updateSystemMetricsTask?.cancel()
        }
    }

    @ViewBuilder
    private var metricLabels: some View {
        Text("CPU: \(String(format: "%.1f", cpuUsage))%")
        Text("Battery: \(String(format: "%.0f", batteryLevel))%")
        Text("Temp: \(thermalLevel)")
        Text("\(networkMbps) Mbps | \(networkUtilization)% utilization | \(fragmentBufferCount) buffered")
    }
    
    private func updateSystemMetrics() async {
        let cpuUsage = getCPUUsage()
        let batteryLevel = getBatteryLevel()
        let thermalLevel = getThermalLevel()
        let outputMetrics = await EncodedOutputRouter.shared.metrics()
        let networkMbps = outputMetrics.networkMbps
        let networkUtilization = outputMetrics.networkUtilization
        let fragmentBufferCount = outputMetrics.bufferedFragments
        let streamHealth: StreamHealth = await {
            if await Streamer.shared.isStreaming() {
                if outputMetrics.hasFailure {
                    return .unusable
                }
                if networkUtilization >= 100 || fragmentBufferCount > 1 {
                    return .degraded
                }
                else {
                    return .pristine
                }
            }
            else if (fragmentBufferCount == 0) {
                return .silenced
            }
            else {
                return appState.streamHealth
            }
        }()
        
        await MainActor.run {
            self.cpuUsage = cpuUsage
            self.batteryLevel = batteryLevel
            self.thermalLevel = thermalLevel
            self.networkMbps = networkMbps
            self.networkUtilization = networkUtilization
            self.fragmentBufferCount = fragmentBufferCount
            self.appState.streamHealth = streamHealth
        }
    }
    
    public func getCPUUsage() -> Float {
        cpuSampler.usage()
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
