//
//  AudioMonitor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-03.
//
import SwiftUI
@preconcurrency import AVFoundation

struct AudioMonitorView: UIViewRepresentable {
    @Environment(AppState.self) var appState
    var width: CGFloat
    var height: CGFloat

    func makeUIView(context: Context) -> AudioMeter {
        let meterView = AudioMeter(width: width, height: height)
        return meterView
    }
    
    func updateUIView(_ uiView: AudioMeter, context: Context) {
        if appState.isAudioLevelRunning, !appState.soonGoingToBackground {
            uiView.startTimer()
        } else {
            uiView.stopTimer()
        }
        uiView.setNeedsDisplay() // Trigger redraw
    }
}

class AudioMeter: UIView {
    var width: CGFloat
    var height: CGFloat
    private var leftAverageLevel: Float = 0 { didSet { setNeedsDisplay() } }
    private var leftPeakLevel: Float = 0 { didSet { setNeedsDisplay() } }
    private var rightAverageLevel: Float = 0 { didSet { setNeedsDisplay() } }
    private var rightPeakLevel: Float = 0 { didSet { setNeedsDisplay() } }
    private var timer: Timer?

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
        super.init(frame: .zero)
        self.backgroundColor = UIColor.black.withAlphaComponent(0)
        startTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func startTimer() {
        guard let timer = self.timer else {
            self.timer = Timer.scheduledTimer(timeInterval: 0.04, target: self, selector: #selector(updateLevels), userInfo: nil, repeats: true)
            return
        }
        if !timer.isValid {
            self.timer = Timer.scheduledTimer(timeInterval: 0.04, target: self, selector: #selector(updateLevels), userInfo: nil, repeats: true)
        }
    }
    
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func updateLevels() {
        Task { @MainActor in // Ensure UI updates on main thread
            let channels = await CaptureDirector.shared.getAudioChannels()
            if channels.count == 2 {
                leftAverageLevel = channels[0].averagePowerLevel
                leftPeakLevel = channels[0].peakHoldLevel
                rightAverageLevel = channels[1].averagePowerLevel
                rightPeakLevel = channels[1].peakHoldLevel
            } else if channels.count == 1 {
                leftAverageLevel = channels[0].averagePowerLevel
                leftPeakLevel = channels[0].peakHoldLevel
                rightAverageLevel = channels[0].averagePowerLevel
                rightPeakLevel = channels[0].peakHoldLevel
            }
        }
    }

    // Normalization function (adjust scaling as desired)
    private func normalizeLevel(_ level: Float) -> CGFloat {
        let normalizedLevel = max(0, level + 160) / 160  // Ensure level is in the 0-1 range
        let sigmoid = 1 / (1 + exp(-10 * (normalizedLevel - 0.95)))
        return CGFloat(sigmoid)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let meterHeight = rect.height
        let halfWidth = rect.width / 2

        // Left Channel
        let leftPeakWidth = normalizeLevel(leftPeakLevel) * halfWidth
        let leftAverageWidth = normalizeLevel(leftAverageLevel) * halfWidth

        // Yellow (Peak) - Draw from right to left
        context.setFillColor(UIColor.green.withAlphaComponent(0.3).cgColor)
        context.fill(CGRect(x: halfWidth - leftPeakWidth, y: 0, width: leftPeakWidth, height: meterHeight))

        // Green (Average) - Draw from right to left
        context.setFillColor(UIColor.green.cgColor)
        context.fill(CGRect(x: halfWidth - leftAverageWidth, y: 0, width: leftAverageWidth, height: meterHeight))

        // Right Channel
        let rightPeakWidth = normalizeLevel(rightPeakLevel) * halfWidth
        let rightAverageWidth = normalizeLevel(rightAverageLevel) * halfWidth

        // Yellow (Peak) - Draw from left to right
        context.setFillColor(UIColor.green.withAlphaComponent(0.3).cgColor)
        context.fill(CGRect(x: halfWidth, y: 0, width: rightPeakWidth, height: meterHeight))

        // Green (Average) - Draw from left to right
        context.setFillColor(UIColor.green.cgColor)
        context.fill(CGRect(x: halfWidth, y: 0, width: rightAverageWidth, height: meterHeight))

        // Middle Line
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: halfWidth - 1, y: 0, width: 2, height: meterHeight))
    }
}
