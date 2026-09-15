import CoreMedia
import CoreVideo
import Testing
@testable import Tubeist

struct OutputPreviewGateTests {
    @Test func stalledPreviewCoalescesFramesWithoutWaitingForDisplay() throws {
        let gate = OutputPreviewGate()
        gate.setEnabled(true)
        #expect(gate.submit(try sample(0)))
        // The UI has not run at all. Capture can still submit every frame,
        // retaining only the newest one and no additional display tasks.
        for number in 1...1_000 {
            #expect(!gate.submit(try sample(Int64(number))))
        }
        #expect(timestamp(gate.takeLatestFrame()) == CMTime(value: 1_000, timescale: 60))
        #expect(gate.takeLatestFrame() == nil)
        #expect(gate.submit(try sample(1_001)))
    }

    @Test func framesArrivingDuringDrawingUseTheExistingDrain() throws {
        let gate = OutputPreviewGate()
        gate.setEnabled(true)
        #expect(gate.submit(try sample(1)))
        #expect(timestamp(gate.takeLatestFrame()) == CMTime(value: 1, timescale: 60))
        #expect(!gate.submit(try sample(2)))
        #expect(!gate.submit(try sample(3)))
        #expect(timestamp(gate.takeLatestFrame()) == CMTime(value: 3, timescale: 60))
        #expect(gate.takeLatestFrame() == nil)
    }

    @Test func switchingMonitorsClearsOldFramesAndReusesAnyScheduledDrain() throws {
        let gate = OutputPreviewGate()
        #expect(!gate.submit(try sample(0)))
        gate.setEnabled(true)
        #expect(gate.submit(try sample(1)))
        gate.setEnabled(false)
        #expect(!gate.submit(try sample(2)))
        gate.setEnabled(true)
        #expect(!gate.submit(try sample(3)))
        #expect(timestamp(gate.takeLatestFrame()) == CMTime(value: 3, timescale: 60))
        gate.setEnabled(false)
        #expect(gate.takeLatestFrame() == nil)
        gate.setEnabled(true)
        #expect(gate.submit(try sample(4)))
    }

    private func timestamp(_ frame: SendableSampleBuffer?) -> CMTime? {
        frame.map { CMSampleBufferGetPresentationTimeStamp($0.value) }
    }

    private func sample(_ number: Int64) throws -> SendableSampleBuffer {
        var pixels: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        let buffer = try #require(pixels)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: number, timescale: 60), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &result) == noErr)
        return SendableSampleBuffer(value: try #require(result))
    }
}
