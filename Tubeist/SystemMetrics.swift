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
    @Environment(\.scenePhase) private var scenePhase
    var onBandwidthWarning: () -> Void = {}
    private let processInfo = ProcessInfo()
    @State private var cpuUsage: Float = 0
    @State private var batteryLevel: Float = -1
    @State private var thermalLevel: String = "Low"
    @State private var networkMbps: Int = 0
    @State private var networkUtilization: Int = 0
    @State private var fragmentBufferCount: Int = 0
    @State private var videoBitrate: Int?
    @State private var belowQualityFloor = false
    @State private var outputFailed = false
    private let cpuSampler = SystemCPUSampler()

    private var batteryPercentage: String? {
        batteryLevel >= 0 ? String(format: "%.0f", batteryLevel) : nil
    }
            
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
        .foregroundColor(appState.isBatterySavingOn ? .white.opacity(0.7) : BRIGHTER_THAN_WHITE)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            (appState.isBatterySavingOn ? "" : "CPU \(String(format: "%.1f", cpuUsage)) percent, ")
            + "battery \(batteryPercentage.map { "\($0) percent" } ?? "unavailable"), temperature \(thermalLevel), network \(networkMbps) megabits per second at \(networkUtilization) percent utilization, \(fragmentBufferCount) fragments buffered"
        )
        .task(id: scenePhase == .active, priority: .utility) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await updateSystemMetrics()
                // While streaming, refresh often enough to show each bitrate step.
                let interval = appState.isStreamSessionRunning && !appState.isBatterySavingOn ? 1.0 : 3.0
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
            }
        }
        // Health needs the capture state, which queues behind captured frames on
        // the pipeline actor; a separate loop keeps that wait from freezing the line.
        .task(id: scenePhase == .active, priority: .utility) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await updateStreamHealth()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
    }

    @ViewBuilder
    private var metricLabels: some View {
        if !appState.isBatterySavingOn {
            Text("CPU: \(String(format: "%.1f", cpuUsage))%")
        }
        Text("Battery: \(batteryPercentage.map { "\($0)%" } ?? "—")")
        Text("Temp: \(thermalLevel)")
        Text("\(networkMbps) Mbps | \(networkUtilization)% utilization | \(fragmentBufferCount) buffered")
        if let videoBitrate {
            Text("Target: \(Double(videoBitrate) / 1_000_000, specifier: "%.1f") Mbps")
                .foregroundStyle(videoBitrate < Settings.selectedPreset.videoBitrate
                    ? (appState.isBatterySavingOn ? .yellow : ULTRAYELLOW)
                    : (appState.isBatterySavingOn ? .white.opacity(0.7) : BRIGHTER_THAN_WHITE))
        }
    }
    
    private func updateSystemMetrics() async {
        let started = ContinuousClock.now
        let cpuUsage = appState.isBatterySavingOn ? self.cpuUsage : getCPUUsage()
        let batteryLevel = getBatteryLevel()
        let thermalLevel = getThermalLevel()
        let outputMetrics = await EncodedOutputRouter.shared.metrics()
        let networkMbps = outputMetrics.networkMbps
        let networkUtilization = outputMetrics.networkUtilization
        let fragmentBufferCount = outputMetrics.bufferedFragments
        await MainActor.run {
            self.cpuUsage = cpuUsage
            self.batteryLevel = batteryLevel
            self.thermalLevel = thermalLevel
            self.networkMbps = networkMbps
            self.networkUtilization = networkUtilization
            self.fragmentBufferCount = fragmentBufferCount
            if let target = outputMetrics.videoBitrate, target != self.videoBitrate {
                let waited = started.duration(to: .now).components
                let seconds = Double(waited.seconds) + Double(waited.attoseconds) / 1e18
                LOG("Status line shows target \(target) bps; refresh took \(String(format: "%.2f", seconds)) s",
                    level: .debug)
            }
            self.videoBitrate = outputMetrics.videoBitrate
            if outputMetrics.belowQualityFloor && !belowQualityFloor {
                onBandwidthWarning()
            }
            self.belowQualityFloor = outputMetrics.belowQualityFloor
            self.outputFailed = outputMetrics.hasFailure
        }
    }

    private func updateStreamHealth() async {
        let captureState = await ContentPackager.shared.captureState()
        let streaming = await Streamer.shared.isStreaming()
        await MainActor.run {
            appState.streamHealth = Self.streamHealth(
                streaming: streaming, outputFailed: outputFailed, captureState: captureState,
                networkUtilization: networkUtilization, bufferedFragments: fragmentBufferCount,
                belowQualityFloor: belowQualityFloor, current: appState.streamHealth)
        }
    }

    static func streamHealth(streaming: Bool, outputFailed: Bool, captureState: CaptureLiveness.State?,
                             networkUtilization: Int, bufferedFragments: Int, belowQualityFloor: Bool,
                             current: StreamHealth) -> StreamHealth {
        guard streaming else { return bufferedFragments == 0 ? .silenced : current }
        if outputFailed || captureState == .failed || captureState == .recovering { return .unusable }
        if networkUtilization >= 100 || bufferedFragments > 1 || belowQualityFloor || captureState == .concealing {
            return .degraded
        }
        return .pristine
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
