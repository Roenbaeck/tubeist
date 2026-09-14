import CoreMotion
import SwiftUI

struct HorizonGravity: Sendable {
    let x: Double
    let y: Double
    let z: Double
}

struct HorizonLevelFilter {
    private var smoothedAngle: Double?

    // A horizon is an unoriented line: +90 and -90 degrees are equivalent.
    static func normalized(_ degrees: Double) -> Double {
        let wrapped = (degrees + 90).truncatingRemainder(dividingBy: 180)
        return (wrapped < 0 ? wrapped + 180 : wrapped) - 90
    }

    mutating func update(_ gravity: HorizonGravity) -> Double? {
        guard gravity.x.isFinite, gravity.y.isFinite, gravity.z.isFinite,
              hypot(gravity.x, gravity.y) >= 0.1 else {
            // Looking almost straight up/down gives no reliable projected horizon.
            smoothedAngle = nil
            return nil
        }
        // Tubeist's landscape UI exchanges the portrait sensor's x/y axes.
        // The projected horizon rotates clockwise by atan2(y, x) on screen.
        let angle = Self.normalized(atan2(gravity.y, gravity.x) * 180 / .pi)
        let result: Double
        if let previous = smoothedAngle {
            result = Self.normalized(previous + 0.35 * Self.normalized(angle - previous))
        } else {
            result = angle
        }
        smoothedAngle = result
        return result
    }
}

enum HorizonLevelReading: Equatable {
    case waiting
    case unavailable
    case indeterminate
    case angle(Double)

    var isLevel: Bool {
        if case .angle(let angle) = self { return abs(angle) <= 0.5 }
        return false
    }

    var label: String {
        switch self {
        case .waiting: "Waiting for motion…"
        case .unavailable: "Horizon level unavailable"
        case .indeterminate: "Point camera toward horizon"
        case .angle(let angle): isLevel ? "Level" : String(format: "%.1f°", abs(angle))
        }
    }
}

@MainActor
protocol HorizonMotionSource: AnyObject {
    var isAvailable: Bool { get }
    var gravity: HorizonGravity? { get }
    func start()
    func stop()
}

@MainActor
private final class HorizonDeviceMotion: HorizonMotionSource {
    // SwiftUI may construct unused view values. Create the manager only when
    // the visible level actually starts, never just to construct its model.
    private lazy var manager = CMMotionManager()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var gravity: HorizonGravity? {
        guard let gravity = manager.deviceMotion?.gravity else { return nil }
        return HorizonGravity(x: gravity.x, y: gravity.y, z: gravity.z)
    }

    func start() {
        manager.deviceMotionUpdateInterval = 1.0 / 15.0
        // Gravity needs no compass heading or magnetometer correction.
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

#if DEBUG
@MainActor
private final class HorizonPreviewMotion: HorizonMotionSource {
    let isAvailable = true
    let gravity: HorizonGravity?
    init(angle: Double) {
        let radians = angle * .pi / 180
        gravity = HorizonGravity(x: cos(radians), y: sin(radians), z: 0)
    }
    func start() {}
    func stop() {}
}
#endif

@Observable @MainActor
final class HorizonLevelModel {
    private(set) var reading = HorizonLevelReading.waiting
    @ObservationIgnored private let motion: any HorizonMotionSource
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var filter = HorizonLevelFilter()

    init(motion: (any HorizonMotionSource)? = nil) {
        if let motion {
            self.motion = motion
            return
        }
#if DEBUG
        let arguments = CommandLine.arguments
        if arguments.contains("-ui-testing"),
           let index = arguments.firstIndex(of: "-horizon-test-angle"),
           index + 1 < arguments.count,
           let angle = Double(arguments[index + 1]), angle.isFinite {
            self.motion = HorizonPreviewMotion(angle: angle)
            return
        }
#endif
        self.motion = HorizonDeviceMotion()
    }

    func run() async {
        guard !Task.isCancelled else { return }
        stop()
        reading = .waiting
        guard motion.isAvailable else {
            reading = .unavailable
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        motion.start()
        defer {
            // An old view task finishing must not stop a newly visible level.
            if generation == currentGeneration { stop() }
        }
        var missingSamples = 0
        while !Task.isCancelled, generation == currentGeneration {
            if let gravity = motion.gravity {
                missingSamples = 0
                let next = filter.update(gravity).map(HorizonLevelReading.angle) ?? .indeterminate
                if case .angle(let oldAngle) = reading, case .angle(let newAngle) = next,
                   abs(HorizonLevelFilter.normalized(newAngle - oldAngle)) < 0.15,
                   reading.isLevel == next.isLevel {
                    // Keep sensor jitter from invalidating the UI on a tripod.
                } else if next != reading {
                    reading = next
                }
            } else {
                missingSamples += 1
                if missingSamples >= 30 {
                    reading = .unavailable
                    return
                }
            }
            do {
                try await Task.sleep(for: .seconds(1.0 / 15.0))
            } catch {
                return
            }
        }
    }

    func stop() {
        guard generation != nil else { return }
        generation = nil
        motion.stop()
        filter = HorizonLevelFilter()
    }
}

struct HorizonLevelView: View {
    let width: CGFloat
    @State private var model = HorizonLevelModel()

    var body: some View {
        let reading = model.reading
        let color: Color = reading.isLevel ? .green : .white
        ZStack {
            // Fixed outer marks show the frame's horizontal axis.
            HStack {
                Capsule().frame(width: 28, height: 2)
                Spacer()
                Capsule().frame(width: 28, height: 2)
            }
            .foregroundStyle(color.opacity(0.8))

            if case .angle(let angle) = reading {
                HStack(spacing: 0) {
                    Rectangle().frame(width: 2, height: 10)
                    Rectangle().frame(height: 2)
                    Circle().stroke(lineWidth: 2).frame(width: 10, height: 10)
                    Rectangle().frame(height: 2)
                    Rectangle().frame(width: 2, height: 10)
                }
                .foregroundStyle(color)
                .frame(width: width - 72)
                .rotationEffect(.degrees(angle))
            }

            Text(reading.label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .offset(y: 36)
        }
        .frame(width: width, height: 100)
        .shadow(color: .black.opacity(0.8), radius: 1, y: 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Horizon level")
        .accessibilityValue(reading.label)
        .accessibilityIdentifier("horizon-level")
        .task { await model.run() }
        .onDisappear { model.stop() }
    }
}
