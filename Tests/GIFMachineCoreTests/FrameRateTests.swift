import Testing
@testable import GIFMachineCore

@Test func smallRecordingsGetTheDisplaysFullRate() {
    #expect(FrameRate.forRecording(displayMaximum: 120, pixelWidth: 1200, pixelHeight: 800) == 120)
    #expect(FrameRate.forRecording(displayMaximum: 60, pixelWidth: 1200, pixelHeight: 800) == 60)
}

@Test func theThresholdItselfStillGets120() {
    #expect(FrameRate.forRecording(displayMaximum: 120, pixelWidth: 2500, pixelHeight: 1400) == 120)
    #expect(FrameRate.forRecording(displayMaximum: 120, pixelWidth: 2502, pixelHeight: 1400) == 60)
}

@Test func aFullBuiltInRetinaScreenGets60() {
    #expect(FrameRate.forRecording(displayMaximum: 120, pixelWidth: 3456, pixelHeight: 2234) == 60)
}

@Test func fastDisplaysAreCappedAt120() {
    #expect(FrameRate.forRecording(displayMaximum: 144, pixelWidth: 800, pixelHeight: 600) == 120)
    #expect(FrameRate.forRecording(displayMaximum: 240, pixelWidth: 5120, pixelHeight: 2880) == 60)
}

@Test func slowAndUnknownDisplaysKeepTheirRate() {
    #expect(FrameRate.forRecording(displayMaximum: 30, pixelWidth: 5120, pixelHeight: 2880) == 30)
    #expect(FrameRate.forRecording(displayMaximum: 0, pixelWidth: 800, pixelHeight: 600) == 1)
}
