import Testing
@testable import MysticCore

struct FramePacingTests {
    @Test func lowLatencyIsImmediateAndBalancedBuffersOneFrameAtBothRates() {
        for fps:UInt32 in [60,120] {
            let interval=(1_000_000 + Int64(fps)/2)/Int64(fps)
            for mode:FramePacingMode in [.lowLatency,.balanced] {
                var pacer=FramePacer(mode:mode)
                let delay=mode == .balanced ? interval : 0
                #expect(pacer.plan(sourcePTS:9_000_000,rendererNow:50_000,ageMicros:0,frameRate:fps).action == .enqueue(timeMicros:50_000+delay,late:false,resynchronize:false))
                pacer.accepted(sourcePTS:9_000_000,rendererNow:50_000)
                #expect(pacer.plan(sourcePTS:9_000_000+interval,rendererNow:50_000+interval,ageMicros:100,frameRate:fps).action == .enqueue(timeMicros:50_000+interval+delay,late:false,resynchronize:false))
            }
        }
    }
    @Test func earlyFramesWaitWithoutCommittingAndNeverQueueBeyondOneFrame() {
        var pacer=FramePacer(mode:.balanced)
        _=pacer.plan(sourcePTS:0,rendererNow:0,ageMicros:0,frameRate:60)
        pacer.accepted(sourcePTS:0,rendererNow:0)
        #expect(pacer.plan(sourcePTS:16667,rendererNow:100,ageMicros:0,frameRate:60).action == .wait(microseconds:16567))
        #expect(pacer.plan(sourcePTS:16667,rendererNow:16667,ageMicros:16567,frameRate:60).action == .enqueue(timeMicros:33334,late:false,resynchronize:false))
    }
    @Test func badFramesDoNotPoisonOrderingAndRepeatedTimestampJumpsRecover() {
        for mode in FramePacingMode.allCases {
            var pacer=FramePacer(mode:mode)
            _=pacer.plan(sourcePTS:0,rendererNow:0,ageMicros:0,frameRate:60);pacer.accepted(sourcePTS:0,rendererNow:0)
            #expect(pacer.plan(sourcePTS:0,rendererNow:10,ageMicros:0,frameRate:60).action == .drop(.outOfOrder))
            #expect(pacer.plan(sourcePTS:Int64.max,rendererNow:10,ageMicros:0,frameRate:60).action == .drop(.invalidTimestamp))
            if case .enqueue = pacer.plan(sourcePTS:16667,rendererNow:16667,ageMicros:0,frameRate:60).action {} else { Issue.record("Valid frame must recover after one corrupt PTS") }
            pacer.accepted(sourcePTS:16667,rendererNow:16667)
            #expect(pacer.plan(sourcePTS:1_000_000,rendererNow:17000,ageMicros:0,frameRate:60).action == .drop(.invalidTimestamp))
            #expect(pacer.plan(sourcePTS:1_016_667,rendererNow:33000,ageMicros:0,frameRate:60).action == .recoverTimestamp)
            pacer.reset()
            if case .enqueue = pacer.plan(sourcePTS:0,rendererNow:0,ageMicros:0,frameRate:120).action {} else { Issue.record("New generation must accept a fresh origin") }
        }
    }
    @Test func staleImagesAndInvalidRatesDoNotChangeTheTimeline() {
        var pacer=FramePacer()
        _=pacer.plan(sourcePTS:0,rendererNow:0,ageMicros:0,frameRate:60);pacer.accepted(sourcePTS:0,rendererNow:0)
        #expect(pacer.plan(sourcePTS:1000,rendererNow:1000,ageMicros:100_001,frameRate:120).action == .drop(.late))
        #expect(pacer.frameRate == 60)
        #expect(pacer.plan(sourcePTS:1000,rendererNow:1000,ageMicros:0,frameRate:0).action == .drop(.invalidTimestamp))
        #expect(pacer.plan(sourcePTS:-1,rendererNow:1000,ageMicros:0,frameRate:60).action == .drop(.invalidTimestamp))
        #expect(pacer.plan(sourcePTS:1000,rendererNow:1000,ageMicros:0,frameRate:60).action == .enqueue(timeMicros:1000,late:false,resynchronize:false))
    }
    @Test func aStallReanchorsBalancedPlaybackAndRateChangesRecomputeTheBuffer() {
        var pacer=FramePacer(mode:.balanced)
        _=pacer.plan(sourcePTS:0,rendererNow:0,ageMicros:0,frameRate:60);pacer.accepted(sourcePTS:0,rendererNow:0)
        #expect(pacer.plan(sourcePTS:16667,rendererNow:200000,ageMicros:0,frameRate:60).action == .enqueue(timeMicros:216667,late:true,resynchronize:true))
        pacer.accepted(sourcePTS:16667,rendererNow:200000)
        #expect(pacer.plan(sourcePTS:25000,rendererNow:208333,ageMicros:0,frameRate:120).action == .enqueue(timeMicros:216666,late:false,resynchronize:true))
        #expect(pacer.frameIntervalMicros == 8333)
    }
    @Test func timestampArithmeticCannotOverflow() {
        var pacer=FramePacer(mode:.balanced)
        #expect(pacer.plan(sourcePTS:0,rendererNow:Int64.max,ageMicros:nil,frameRate:60).action == .drop(.invalidTimestamp))
        #expect(pacer.plan(sourcePTS:0,rendererNow:0,ageMicros:nil,frameRate:60).action == .enqueue(timeMicros:16667,late:false,resynchronize:false))
    }
    @Test func aJitteredStreamKeepsItsCadenceAt60And120() {
        for fps:UInt32 in [60,120] {
            var pacer=FramePacer(mode:.balanced)
            let interval=(1_000_000+Int64(fps)/2)/Int64(fps)
            for frame in 0..<240 {
                let source=Int64(frame)*interval
                var now=50_000+source+[Int64(0),-2000,2000,0][frame%4]
                var action=pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:100,frameRate:fps).action
                if case let .wait(delay)=action {
                    now+=Int64(delay)
                    action=pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:100+delay,frameRate:fps).action
                }
                #expect(action == .enqueue(timeMicros:50_000+source+interval,late:false,resynchronize:false))
                pacer.accepted(sourcePTS:source,rendererNow:now)
            }
        }
    }
    @Test func theFPSLimitSpacesEarlyFramesByAFrameAndNeverHoldsLonger() {
        var pacer=FramePacer(mode:.fpsLimit)
        func step(_ source:Int64,_ now:Int64) -> FramePacingPlan.Action {
            let action=pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:0,frameRate:60).action
            pacer.accepted(sourcePTS:source,rendererNow:now)
            return action
        }
        #expect(step(0,1000) == .enqueue(timeMicros:1000,late:false,resynchronize:false))
        // A burst: each frame takes the next slot, at most one frame ahead of now.
        #expect(step(16667,2000) == .enqueue(timeMicros:17667,late:false,resynchronize:false))
        #expect(step(33334,3000) == .enqueue(timeMicros:19667,late:false,resynchronize:false))
        // A late frame starts the slots again.
        #expect(step(50001,80000) == .enqueue(timeMicros:80000,late:false,resynchronize:false))
        #expect(step(66668,96667) == .enqueue(timeMicros:96667,late:false,resynchronize:false))
    }
    @Test func aPlannedSlotIsNotTakenUntilTheFrameIsAccepted() {
        var pacer=FramePacer(mode:.fpsLimit)
        _=pacer.plan(sourcePTS:0,rendererNow:1000,ageMicros:0,frameRate:60);pacer.accepted(sourcePTS:0,rendererNow:1000)
        #expect(pacer.plan(sourcePTS:16667,rendererNow:2000,ageMicros:0,frameRate:60).action == .enqueue(timeMicros:17667,late:false,resynchronize:false))
        #expect(pacer.plan(sourcePTS:16667,rendererNow:2000,ageMicros:0,frameRate:60).action == .enqueue(timeMicros:17667,late:false,resynchronize:false))
    }
    @Test func smoothestFollowsThePCsTimingBehindATwoFrameBuffer() {
        for fps:UInt32 in [60,120] {
            var pacer=FramePacer(mode:.smoothest)
            let interval=(1_000_000+Int64(fps)/2)/Int64(fps)
            for frame in 0..<240 {
                let source=Int64(frame)*interval
                var now=50_000+source+[Int64(0),-2000,2000,0][frame%4]
                var action=pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:100,frameRate:fps).action
                if case let .wait(delay)=action {
                    now+=Int64(delay)
                    action=pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:100+delay,frameRate:fps).action
                }
                #expect(action == .enqueue(timeMicros:50_000+source+interval*2,late:false,resynchronize:false))
                pacer.accepted(sourcePTS:source,rendererNow:now)
            }
        }
        // Its buffer is not a future timestamp, however low the rate.
        var slow=FramePacer(mode:.smoothest)
        #expect(slow.plan(sourcePTS:0,rendererNow:0,ageMicros:0,frameRate:10).action == .enqueue(timeMicros:200_000,late:false,resynchronize:false))
    }
    @Test func onlyTheInOrderPacingsKeepAFreshFrameWhenANewerWaits() {
        for mode in FramePacingMode.allCases {
            let pacer=FramePacer(mode:mode)
            #expect(pacer.isSuperseded(ageMicros:0,frameRate:60) == !mode.keepsOrder)
            #expect(pacer.isSuperseded(ageMicros:nil,frameRate:60) == !mode.keepsOrder)
            #expect(pacer.isSuperseded(ageMicros:16668,frameRate:60))
        }
    }
    @Test func pcFrameTimesFollowThePCAndHoldForTheJitter() {
        var pacer=FramePacer(mode:.pcFrameTimes)
        var previous:Int64?
        for frame in 0..<600 {
            let source=Int64(frame)*16667
            let now=50_000+source+[Int64(0),4000,1000,3000][frame%4]
            guard case let .enqueue(time,_,_)=pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:0,frameRate:60).action else {
                Issue.record("Every frame is scheduled");return
            }
            pacer.accepted(sourcePTS:source,rendererNow:now)
            #expect(time >= now)
            if frame > 300,let previous { #expect(abs(time-previous-16667) <= 30) }
            previous=time
        }
        #expect(pacer.holdMicros != nil)
    }
    @Test func pcFrameTimesTakeAFrameAgeAsItsReadyTime() {
        var pacer=FramePacer(mode:.pcFrameTimes)
        #expect(pacer.plan(sourcePTS:0,rendererNow:10_000,ageMicros:2000,frameRate:60).action == .enqueue(timeMicros:10_000,late:false,resynchronize:false))
        #expect(pacer.holdMicros == 500)
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
    @Test func aRestartedVideoClockStartsTheClockAgain() {
        var clock=PresentClock()
        for frame in 0..<60 { _=clock.schedule(hostMicros:Int64(frame)*16667,readyMicros:Int64(frame)*16667+5000) }
        #expect(clock.delayMicros != nil)
        _=clock.schedule(hostMicros:20_000_000,readyMicros:1_000_000)
        #expect(clock.delayMicros == nil)
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
