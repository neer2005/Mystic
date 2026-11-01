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
    /// A network spike anchors the timeline late; the frames after it are then early against it.
    @Test func framesBackOnTimeAfterASpikeRealignWithoutAResetOrAFreeze() {
        for mode:FramePacingMode in [.balanced,.smoothest] {
            for fps:UInt32 in [60,120] {
                var pacer=FramePacer(mode:mode)
                let interval=(1_000_000+Int64(fps)/2)/Int64(fps)
                var longest:UInt64=0,clock:Int64=0
                for frame in 0..<120 {
                    let source=Int64(frame)*interval
                    // Twenty frames arrive 130 ms late, then all are on time again.
                    let now=max(clock,50_000+source+((40..<60).contains(frame) ? 130_000 : 0));clock=now
                    switch pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:0,frameRate:fps).action {
                    case .enqueue: pacer.accepted(sourcePTS:source,rendererNow:now)
                    case let .wait(delay): longest=max(longest,delay)
                    case let other: Issue.record("Frame \(frame) at \(fps) fps: \(other)")
                    }
                }
                #expect(longest <= UInt64(mode == .smoothest ? interval*2 : interval),"A longer wait in Balanced is replaced by the next frame, and so on")
            }
        }
    }
    /// Plays frames arriving at `arrival(frame)` after their PC time; returns the realignments after the first second.
    private func realignments(mode:FramePacingMode,frames:Int,sourceInterval:Int64,streamFPS:UInt32,arrival:(Int)->Int64) -> Int {
        var pacer=FramePacer(mode:mode),clock:Int64=0,count=0
        for frame in 0..<frames {
            let source=Int64(frame)*sourceInterval
            clock=max(clock,50_000+source+arrival(frame))
            var now=clock
            var action=pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:0,frameRate:streamFPS).action
            if case let .wait(delay)=action {
                now+=Int64(delay)
                action=pacer.plan(sourcePTS:source,rendererNow:now,ageMicros:UInt64(delay),frameRate:streamFPS).action
            }
            guard case let .enqueue(_,_,resynchronize)=action else { Issue.record("Frame \(frame): \(action)");continue }
            pacer.accepted(sourcePTS:source,rendererNow:now)
            if resynchronize,Int64(frame)*sourceInterval > 1_000_000 { count+=1 }
        }
        return count
    }
    @Test func jitterOnASlowerGameRealignsLessWithoutALongerBuffer() {
        // Balanced keeps the stream's own short buffer, since a longer one is added delay: this
        // jitter still crosses it. One frame out of line no longer realigns, which was 75 here.
        let jitter:(Int)->Int64={ Int64($0*2654435761%35_000) }
        #expect(realignments(mode:.balanced,frames:1200,sourceInterval:16667,streamFPS:120,arrival:jitter) <= 50)
        #expect(realignments(mode:.smoothest,frames:1200,sourceInterval:16667,streamFPS:120,arrival:jitter) == 0)
    }
    @Test func aLastingShiftStillRealigns() {
        let count=realignments(mode:.balanced,frames:600,sourceInterval:16667,streamFPS:60) { $0 > 300 ? 90_000 : 0 }
        #expect(count >= 1 && count <= 2,"\(count) realignments")
    }
    @Test func slowContentIsNotAStall() {
        // An idle desktop: two frames a second, each on time.
        #expect(realignments(mode:.balanced,frames:60,sourceInterval:500_000,streamFPS:60) { _ in 0 } <= 1)
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
    /// Nightjar's `run_grid`: the grid as a display reports it, from the latest refresh with noise.
    private func runGrid(fps:Int64,hz:Int64,frames:Int,slack:Int64,jitter:(Int)->Int64) -> [(ready:Int64,schedule:PresentClock.GridSchedule)] {
        var clock=PresentClock()
        let interval=1_000_000/hz,period=1_000_000/fps
        return (0..<frames).map { index in
            let host=Int64(index+1)*period
            let ready=host+20_000+jitter(index)+5_000_000
            let anchor=(ready-3333)/interval*interval+3333+Int64(index*7%21)-10
            let grid=PresentClock.Grid(anchorMicros:anchor,intervalMicros:interval,leadMicros:interval/4,slackMicros:slack)
            let schedule=clock.schedule(hostMicros:host,readyMicros:ready,grid:grid)
            #expect(schedule.releaseMicros >= ready)
            #expect(schedule.refreshMicros >= ready)
            return (ready,schedule)
        }
    }
    private func refreshSteps(_ shown:ArraySlice<(ready:Int64,schedule:PresentClock.GridSchedule)>,_ interval:Int64) -> [Int64] {
        zip(shown,shown.dropFirst()).map { ($1.schedule.refreshMicros-$0.schedule.refreshMicros+interval/2)/interval }
    }
    @Test func anEvenGameLandsOneRefreshApartOnAMatchingPanel() {
        let shown=runGrid(fps:60,hz:60,frames:1200,slack:8333) { Int64($0*2654435761%6000) }
        let settled=shown[120...]
        let steps=refreshSteps(settled,16666)
        #expect(steps.filter { $0 == 1 }.count*100 >= steps.count*96)
        #expect(settled.allSatisfy { !$0.schedule.sharesRefresh || $0.schedule.late })
    }
    @Test func ninetyOnA120PanelFollowsTheFourThreePattern() {
        let steps=refreshSteps(runGrid(fps:90,hz:120,frames:900,slack:0) { _ in 0 }[200...],8333)
        #expect(steps.allSatisfy { (1...2).contains($0) })
        #expect(abs(steps.filter { $0 == 2 }.count-steps.count/3) <= 2)
    }
    @Test func contentFasterThanThePanelSharesRefreshesWithoutRunningBehind() {
        let settled=runGrid(fps:90,hz:60,frames:900,slack:0) { _ in 0 }[200...]
        #expect(abs(settled.filter { $0.schedule.sharesRefresh }.count-settled.count/3) <= settled.count/20)
        #expect(settled.allSatisfy { $0.schedule.refreshMicros-$0.ready <= 2*16667 })
    }
    @Test func aFrameIsNeverHeldMoreThanOneRefreshPastItsFirst() {
        for (fps,hz):(Int64,Int64) in [(60,60),(90,90),(90,120),(72,120),(120,120),(45,90),(30,60)] {
            let interval=1_000_000/hz
            for (ready,schedule) in runGrid(fps:fps,hz:hz,frames:1500,slack:interval/2,jitter:{ Int64($0*2654435761%8000) })[150...] {
                #expect(schedule.refreshMicros-ready < interval*2+30,"\(fps) on \(hz)")
            }
        }
    }
    @Test func aFrameInsideTheLeadIsReleasedAtOnce() {
        var clock=PresentClock()
        let grid=PresentClock.Grid(anchorMicros:1_000_000,intervalMicros:16667,leadMicros:4000,slackMicros:0)
        let first=clock.schedule(hostMicros:0,readyMicros:1_015_667,grid:grid)
        #expect(first.refreshMicros == 1_016_667 && first.releaseMicros == 1_015_667 && first.holdMicros == 0)
        let second=clock.schedule(hostMicros:11,readyMicros:1_023_000,grid:.init(anchorMicros:1_016_667,intervalMicros:16667,leadMicros:4000,slackMicros:0))
        #expect(second.refreshMicros == 1_033_334 && second.releaseMicros == 1_029_334)
    }
    @Test func aGridLearnsTheDelayOfALowerPercentile() {
        var plain=PresentClock(),gridded=PresentClock()
        for index in 0..<1500 {
            let host=Int64(index)*11111,ready=host+20_000+Int64(index*2654435761%8000)+7_000_000
            _=plain.schedule(hostMicros:host,readyMicros:ready)
            _=gridded.schedule(hostMicros:host,readyMicros:ready,grid:.init(anchorMicros:1000,intervalMicros:16667))
        }
        #expect((plain.delayMicros ?? 0)-(gridded.delayMicros ?? 0) > 1000)
    }
    @Test func thePacerGoesOnTheGridOnceGivenOne() {
        var pacer=FramePacer(mode:.pcFrameTimes)
        pacer.refreshGrid = .init(anchorMicros:0,intervalMicros:16000)
        #expect(pacer.plan(sourcePTS:0,rendererNow:1000,ageMicros:0,frameRate:60).action == .enqueue(timeMicros:12000,late:false,resynchronize:false))
        #expect(pacer.holdMicros == 11000)
        pacer.reset();#expect(pacer.refreshGrid != nil,"a new generation keeps the display")
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
