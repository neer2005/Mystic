import Foundation
import Testing
@testable import MysticCore

struct AWDLHoldTests {
    @Test func itHoldsOnlyWhenOnAndStreamingOverWiFiOrAnUnknownRoute() {
        #expect(AWDLHold.shouldHold(enabled:true,streaming:true,routeWireless:true))
        #expect(AWDLHold.shouldHold(enabled:true,streaming:true,routeWireless:nil))
        #expect(!AWDLHold.shouldHold(enabled:true,streaming:true,routeWireless:false))
        #expect(!AWDLHold.shouldHold(enabled:true,streaming:false,routeWireless:true))
        #expect(!AWDLHold.shouldHold(enabled:false,streaming:true,routeWireless:true))
    }
    @Test func onlyTheUpFlagChangesAndOnlyWhenItMust() {
        #expect(AWDLHold.flags(current:0x8843,held:true) == 0x8842)
        #expect(AWDLHold.flags(current:0x8842,held:true) == nil)
        #expect(AWDLHold.flags(current:0x8842,held:false) == 0x8843)
        #expect(AWDLHold.flags(current:0x8843,held:false) == nil)
    }
    @Test func theRequirementNamesTheAppAndItsTeam() {
        let requirement=AWDLHold.clientRequirement(team:"ABC123")
        #expect(requirement.contains("identifier \"com.mystic.streaming\"") && requirement.contains("\"ABC123\""))
    }
}

/// Nightjar's `present.rs` and `present_clock` tests, in microseconds.
struct FramePacingTests {
    private func pacer(_ mode: PresentationPacing,_ pacing: FramePacingMode,fps: UInt32 = 60) -> PresentationPacer<Int64> {
        PresentationPacer(mode:mode,framePacing:pacing,frameRate:fps)
    }
    @Test func theModeFollowsNightjarsRules() {
        func choose(vrr: Bool = false,host: Bool = false,vsync: Bool,_ pacing: FramePacingMode,tearing: Bool = false) -> PresentationPacing {
            .choose(vrr:vrr,presentAtHostTimes:host,vsync:vsync,framePacing:pacing,tearingSupported:tearing)
        }
        #expect(choose(vsync:true,.lowLatency) == .vsync)
        #expect(choose(vsync:false,.lowLatency) == .immediate)
        for pacing:FramePacingMode in [.balanced,.fpsLimit,.smoothest] { #expect(choose(vsync:false,pacing) == .vsync) }
        #expect(choose(vrr:true,host:true,vsync:true,.smoothest,tearing:true) == .hostTimes)
        #expect(choose(vrr:true,vsync:true,.smoothest,tearing:true) == .immediate)
        #expect(choose(vrr:true,host:true,vsync:true,.lowLatency) == .vsync,"VRR needs a display that can tear")
    }
    @Test func aFrameIsAtMost250Milliseconds() {
        #expect(PresentationPacer<Int64>.frameMicros(60) == 16_666)
        #expect(PresentationPacer<Int64>.frameMicros(0) == 250_000)
    }
    @Test func immediateShowsTheNewestDuePicture() {
        var pacer=pacer(.immediate,.lowLatency)
        for ready:Int64 in [10,20,30] { pacer.accept(ready,readyMicros:ready,hostMicros:ready) }
        let (picture,dropped)=pacer.takeDue(now:25)
        #expect(picture?.picture == 20 && dropped == 1)
        #expect(pacer.takeDue(now:30).picture?.picture == 30)
    }
    @Test func lowestAndBalancedPacingShowTheNewestDuePicture() {
        for mode:FramePacingMode in [.lowLatency,.balanced] {
            var pacer=pacer(.vsync,mode)
            for ready:Int64 in [1000,9000,17000] { pacer.accept(ready,readyMicros:ready,hostMicros:ready) }
            let (picture,dropped)=pacer.takeDue(now:17000)
            #expect(picture?.readyMicros == 17000 && dropped == 2)
        }
    }
    @Test func smoothestShowsEachPictureInTurnAndSkipsOnlyStaleOnes() {
        var pacer=pacer(.vsync,.smoothest)
        for ready:Int64 in [1000,9000,17000] { pacer.accept(ready,readyMicros:ready,hostMicros:ready) }
        var taken=pacer.takeDue(now:17000)
        #expect(taken.picture?.readyMicros == 1000 && taken.dropped == 0,"16 ms old: still within a frame")
        taken=pacer.takeDue(now:26000)
        #expect(taken.picture?.readyMicros == 17000 && taken.dropped == 1,"17 ms old with a newer one due")
        #expect(pacer.nextDueMicros == nil)
        pacer.accept(30000,readyMicros:30000,hostMicros:30000)
        taken=pacer.takeDue(now:60000)
        #expect(taken.picture?.readyMicros == 30000 && taken.dropped == 0,"A lone late picture still shows")
        var immediate=self.pacer(.immediate,.smoothest)
        immediate.accept(1000,readyMicros:1000,hostMicros:1000);immediate.accept(2000,readyMicros:2000,hostMicros:2000)
        #expect(immediate.takeDue(now:2000).dropped == 1,"Without V-Sync the setting does not apply")
    }
    @Test func theFPSLimitGivesEachPictureItsOwnSlotHoldingItAtMostAFrame() {
        var pacer=pacer(.vsync,.fpsLimit)
        for ready:Int64 in [10000,12000,60000] { pacer.accept(ready,readyMicros:ready,hostMicros:ready) }
        var taken=pacer.takeDue(now:12000)
        #expect(taken.picture?.readyMicros == 10000 && taken.picture?.presentMicros == 10000 && taken.picture?.holdMicros == 0 && taken.dropped == 0)
        #expect(pacer.nextDueMicros == 26666,"The early one waits for the next slot")
        #expect(pacer.takeDue(now:20000).picture == nil)
        taken=pacer.takeDue(now:26666)
        #expect(taken.picture?.readyMicros == 12000 && taken.picture?.holdMicros == 14666 && taken.dropped == 0)
        #expect(pacer.nextDueMicros == 60000,"A late picture starts the slots again")
        pacer.accept(60500,readyMicros:60500,hostMicros:60500);pacer.accept(61000,readyMicros:61000,hostMicros:61000)
        #expect(pacer.takeDue(now:100000).dropped == 2,"Pictures over a frame old give way to the newest due one")
    }
    @Test func hostTimesFollowThePCBehindADelay() {
        var pacer=pacer(.hostTimes,.lowLatency)
        for frame in 0..<600 {
            let host=Int64(frame)*16667,ready=50_000+host+[Int64(0),4000,1000,3000][frame%4]
            pacer.accept(host,readyMicros:ready,hostMicros:host)
            guard let due=pacer.nextDueMicros else { Issue.record("Scheduled");return }
            #expect(due >= ready)
            if frame > 300 { #expect(abs(due-(host+54_500)) <= 30) }
            _=pacer.takeDue(now:due)
        }
    }
    @Test func thePresentClockWarmsUpBeforeLearning() {
        var clock=PresentClock()
        #expect(clock.schedule(hostMicros:0,readyMicros:90_000) == .init(presentMicros:90_500,late:false,holdMicros:500))
        #expect(clock.delayMicros == nil)
        _=clock.schedule(hostMicros:250_000,readyMicros:270_000)
        #expect(clock.delayMicros == 20_500)
    }
    @Test func thePresentClockRisesAtOnceFallsInSecondsAndCapsItsHold() {
        var clock=PresentClock()
        var host:Int64=0
        func run(_ frames:Int,lateBy:Int64) -> PresentClock.Schedule {
            var last=clock.schedule(hostMicros:host,readyMicros:host+lateBy)
            for _ in 1..<frames { host+=8333;last=clock.schedule(hostMicros:host,readyMicros:host+lateBy) }
            return last
        }
        _=run(200,lateBy:20_000)
        #expect(clock.delayMicros == 20_500)
        host+=8333
        #expect(clock.schedule(hostMicros:host,readyMicros:host+300_000).late,"A stalled frame is shown at once")
        #expect((clock.delayMicros ?? 0) <= 20_000+50_000)
        let settled=run(600,lateBy:20_000)
        #expect(clock.delayMicros == 20_500);#expect(settled.holdMicros == 500)
    }
    @Test func presentsAreNeverCloserThanTheDisplaysRefresh() {
        var clock=PresentClock();clock.minIntervalMicros=8333
        let first=clock.schedule(hostMicros:0,readyMicros:1000)
        #expect(clock.schedule(hostMicros:1,readyMicros:1001).presentMicros >= first.presentMicros+8333)
    }
    @Test func aRestartedVideoClockStartsTheClockAgain() {
        var clock=PresentClock()
        for frame in 0..<60 { _=clock.schedule(hostMicros:Int64(frame)*16667,readyMicros:Int64(frame)*16667+5000) }
        #expect(clock.delayMicros != nil)
        _=clock.schedule(hostMicros:20_000_000,readyMicros:1_000_000)
        #expect(clock.delayMicros == nil)
    }
    @Test func anOldStoredChoiceBecomesTheDefault() throws {
        #expect(try JSONDecoder().decode([FramePacingMode].self,from:Data(#"["pcFrameTimes","balanced"]"#.utf8)) == [.lowLatency,.balanced])
    }
    @Test func theCadenceKeepsPCToScreenTimes() {
        var cadence=ShownCadence()
        #expect(cadence.pcToShownSummary == nil)
        for value in [10,20,30] as [Int64] { cadence.record(pcToReceivedMicros:value,pcToShownMicros:value*10) }
        #expect(cadence.pcToReceivedSummary?.p50 == 20 && cadence.pcToShownSummary?.p95 == 200)
    }
    @Test func theShownCadenceSummarisesEachStage() {
        var cadence=ShownCadence()
        #expect(cadence.stageSummary.isEmpty)
        for value in [1,2,3] as [Int64] { cadence.record(stages:.init(toEnqueue:value,forDrawable:value*10,encode:0,gpu:0,toScreen:value*100)) }
        #expect(cadence.stageSummary.map(\.name) == ["to enqueue","for drawable","encode","GPU","to screen"])
        #expect(cadence.stageSummary[0].p50 == 2 && cadence.stageSummary[4].p95 == 200)
    }
    @Test func theShownCadenceMeasuresRealPresents() {
        var cadence=ShownCadence()
        #expect(cadence.summary == nil)
        for present in [0,8333,16666,33333,41666,50000] as [Int64] { cadence.record(presentedMicros:present) }
        #expect(cadence.shown == 6)
        #expect(cadence.summary?.p50 == 8333 && cadence.summary?.p99 == 8334)
        #expect(cadence.unevenShare == 0.2)
        #expect(cadence.readyToShown?.p50 == nil)
        cadence.record(presentedMicros:58333,readyToShownMicros:9000)
        #expect(cadence.readyToShown?.p50 == 9000)
    }
    @Test func presenterDropsQueueAndRendererMetricsRemainSeparate() {
        var recorder=VideoTelemetryAccumulator()
        recorder.presentationQueue(depth:2);recorder.presentationDrop(.superseded,count:10)
        recorder.presentationDrop(.late,count:2);recorder.presentationLate();recorder.presentationResynchronize()
        recorder.rendererMetrics(dropped:7,corrupted:1);recorder.presentationQueue(depth:0)
        let metrics=recorder.snapshot(nowMicros:1).presentation
        #expect(metrics.droppedFrames == 12 && metrics.lateFrames == 3)
        #expect(metrics.queueDepth == 0 && metrics.peakQueueDepth == 2)
        #expect(metrics.rendererDroppedFrames == 7 && metrics.rendererCorruptedFrames == 1)
        #expect(metrics.resynchronizations == 1)
    }
}
