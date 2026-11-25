import Testing
@testable import GIFMachineCore

struct SketchTests {
    @Test func theUsualWayGetsAboutTwiceTheTimeOfGIFMachine() {
        let without = Sketch.rewindStart
        let with = Sketch.duration - Sketch.rewindEnd
        #expect(without / with >= 1.8)
    }

    @Test func messagesArriveInOrder() {
        for list in [Sketch.withoutMessages, Sketch.withMessages] {
            #expect(list.map(\.at) == list.map(\.at).sorted())
        }
    }

    @Test func itOpensOnTheChatAloneThenSafariOpensAfterYourReply() {
        #expect(Sketch.frame(at: 1).browser == 0)
        #expect(Sketch.frame(at: 1).messages.map(\.body) == [.text("is checkout broken on staging?")])
        let replied = Sketch.frame(at: Sketch.browserOpens)
        #expect(replied.messages.last?.body == .text("I'll check it out"))
        #expect(Sketch.frame(at: Sketch.browserOpens + Sketch.browserOpening).browser == 1)
        #expect(Sketch.sincePayClick(at: 6.5) != nil)
        #expect(Sketch.frame(at: 7.8).messages.last?.body == .text("can someone show me what you're seeing"))
    }

    @Test func typingShowsALetterAtATimeThenSends() {
        let typing = Sketch.withoutTyping[1]
        #expect(Sketch.frame(at: typing.start + 0.25).composer == "on ")
        let sent = Sketch.frame(at: typing.sent + 0.01)
        #expect(sent.composer.isEmpty)
        #expect(sent.messages.last?.body == .text(typing.text))
    }

    @Test func theRewindEndsOnJaysQuestion() {
        let end = Sketch.frame(at: Sketch.rewindEnd - 0.001)
        #expect(end.rewind != nil)
        #expect(end.messages.last?.body == .text("can someone show me what you're seeing"))
        #expect(Sketch.frame(at: Sketch.rewindEnd).half == .with)
    }

    @Test func theTimeLapseRunsTheClockFortyMinutesUntilTheRewind() {
        #expect(Sketch.frame(at: Sketch.skipStart - 0.01).clock == "4:31 PM")
        #expect(Sketch.frame(at: Sketch.skipStart + Sketch.skipLength / 2).clock == "4:51 PM")
        #expect(Sketch.frame(at: 30).clock == "5:11 PM")
        #expect(Sketch.frame(at: Sketch.rewindEnd + 1).clock == "4:31 PM")
    }

    @Test func theTimeLapseAndConfettiRunOnlyInTheirWindows() {
        #expect(Sketch.frame(at: Sketch.skipStart - 0.01).skip == nil)
        #expect(Sketch.frame(at: Sketch.skipStart + 0.7).skip != nil)
        #expect(Sketch.frame(at: Sketch.skipStart + Sketch.skipLength).skip == nil)
        #expect(Sketch.frame(at: Sketch.confettiStart + 1).confetti != nil)
        #expect(Sketch.frame(at: Sketch.duration).confetti == nil)
    }

    @Test func withGIFMachineTheCursorClicksTheMenuBarIconThenSectionAndRecordsThreeSeconds() {
        #expect(Sketch.frame(at: 36.2).cursor?.to == .menuIcon)
        #expect(Sketch.frame(at: 36.8).mac == .dropDown(chosen: false))
        #expect(Sketch.frame(at: 37.2).mac == .dropDown(chosen: true))
        #expect(Sketch.frame(at: 37.85).cursor?.pressed == true)
        #expect(Sketch.frame(at: 37.85).cursor?.progress == 0)
        #expect(Sketch.frame(at: 40.14).mac == .recording(seconds: 3))
        #expect(Sketch.frame(at: 39.9).cursor?.to == .menuIcon)
    }

    @Test func theSelectionGrowsInStepWithTheCursorDraggingIt() {
        for t in stride(from: 37.95, through: 38.35, by: 0.1) {
            let frame = Sketch.frame(at: t)
            guard case .selecting(let progress) = frame.mac else { Issue.record("not selecting at \(t)"); continue }
            #expect(frame.cursor?.to == .selectionEnd)
            #expect(abs((frame.cursor?.progress ?? -1) - progress) < 0.0001)
        }
    }

    @Test func theRecordingIsCarriedIntoTheChatThenRefused() {
        let carrying = Sketch.frame(at: 16.4)
        #expect(carrying.cursor?.carrying == true)
        #expect(carrying.cursor?.to == .chatDrop)
        #expect(Sketch.frame(at: 16.95).cursor?.carrying == false)
        #expect(Sketch.frame(at: 16.95).messages.last.map { if case .file = $0.body { true } else { false } } == true)
    }

    @Test func theCursorIsHiddenBetweenGesturesAndInTheRewind() {
        #expect(Sketch.frame(at: 0.2).cursor == nil)
        #expect(Sketch.frame(at: 8.5).cursor == nil)
        #expect(Sketch.frame(at: 25).cursor == nil)
        #expect(Sketch.frame(at: 34.0).cursor == nil)
        #expect(Sketch.frame(at: 11.5).cursor != nil)
    }

    @Test func theCursorClicksPayOnceInEachRecordingAndNotOnALoop() {
        let clicks = Sketch.gestures.flatMap { $0 }.filter { $0.to == .pay }.map(\.end)
        #expect(clicks.count == 3)
        #expect(!clicks.contains { if case .quickTimeRecording = Sketch.mac(at: $0) { true } else { false } })
        #expect(clicks.contains { if case .recording = Sketch.mac(at: $0) { true } else { false } })
        #expect(Sketch.sincePayClick(at: 4.5) == nil)
        #expect(Sketch.sincePayClick(at: 10.0) != nil)
        #expect(Sketch.sincePayClick(at: 38.6) == nil)
        #expect(Sketch.sincePayClick(at: 25)! > 11)
    }

    @Test func itFinishesAtTheEndAndStaysThere() {
        #expect(!Sketch.frame(at: Sketch.duration - 0.1).finished)
        let end = Sketch.frame(at: Sketch.duration + 5)
        #expect(end.finished)
        #expect(end.channel == "hall-of-fame")
        #expect(end.mac == .fixed)
    }
}
