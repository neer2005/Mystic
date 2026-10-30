import Testing
import Foundation
import MysticCore

struct StreamProfilesTests {
    @Test func inheritanceTracksDefaultsWhileCustomSnapshotsStayFixed() throws {
        var catalog=StreamProfileCatalog(),defaults=StreamVideoSettings(),host=StreamVideoSettings(),game=StreamVideoSettings()
        host.resolution="3840x2160";host.hdr=true;game.resolution="2560x1440";game.fps=120
        #expect(catalog.video(defaults:defaults,host:"PC",game:"A") == defaults)
        try catalog.setHost(host,host:"PC")
        #expect(catalog.video(defaults:defaults,host:"PC",game:"A") == host)
        try catalog.setGame(source:.custom,video:game,host:"PC",game:"A")
        try catalog.setGame(source:.global,video:nil,host:"PC",game:"B")
        defaults.bitrateMbps=45
        #expect(catalog.video(defaults:defaults,host:"PC",game:"A") == game)
        #expect(catalog.video(defaults:defaults,host:"PC",game:"B") == defaults)
        #expect(catalog.video(defaults:defaults,host:"PC",game:"C") == host)
        #expect(catalog.video(defaults:defaults,host:"Other PC",game:"A") == defaults)
        try catalog.setHost(nil,host:"PC")
        #expect(catalog.video(defaults:defaults,host:"PC",game:"C") == defaults)
        #expect(catalog.video(defaults:defaults,host:"PC",game:"A") == game)
        try catalog.setGame(source:.host,video:nil,host:"PC",game:"A")
        #expect(catalog.source(host:"PC",game:"A") == .host)
        #expect(catalog.video(defaults:defaults,host:"PC",game:"A") == defaults)
    }
    @Test func roundTripValidatesValuesAndKeepsScopesSeparate() throws {
        var catalog=StreamProfileCatalog(),video=StreamVideoSettings()
        video.resolution="unsupported";video.fps=500;video.bitrateMbps=1000;video.codec="invalid"
        video.hdr=true;video.framePacing = .balanced;video.adaptiveBitrate=true
        try catalog.setHost(video,host:"PC")
        try catalog.setGame(source:.custom,video:video,host:"PC",game:"Game")
        try catalog.setGame(source:.global,video:nil,host:"PC",game:"Global game")
        let restored=try StreamProfileCatalog(data:catalog.encoded())
        #expect(restored == catalog)
        let result=restored.video(defaults:StreamVideoSettings(),host:"PC",game:"Game")
        #expect(result.resolution == "1920x1080");#expect(result.fps == 60)
        #expect(result.bitrateMbps == 150);#expect(result.codec == "auto")
        #expect(result.hdr);#expect(result.framePacing == .balanced);#expect(result.adaptiveBitrate)
        #expect(restored.source(host:"PC",game:"Global game") == .global)
    }
    @Test func videoProjectionPreservesUnrelatedPreferences() {
        var preferences=StreamPreferences(),video=StreamVideoSettings()
        preferences.microphoneEnabled=true;preferences.clipboardSync=true;preferences.audioLayout="7.1"
        preferences.volume=0.3;preferences.automaticReconnect=false;preferences.libraryLayout="list"
        video.resolution="3840x2160";video.codec="hevc";video.hdr=true;video.framePacing = .balanced
        preferences.videoSettings=video
        #expect(preferences.videoSettings == video)
        #expect(preferences.microphoneEnabled == true);#expect(preferences.clipboardSync == true)
        #expect(preferences.audioLayout == "7.1");#expect(preferences.volume == 0.3)
        #expect(preferences.automaticReconnect == false);#expect(preferences.libraryLayout == "list")
    }
    @Test func capacityRejectsNewProfilesWithoutEvictingExistingOnesAndResetFreesSpace() throws {
        var catalog=StreamProfileCatalog()
        let video=StreamVideoSettings()
        for n in 0..<StreamProfileCatalog.hostCapacity { try catalog.setHost(video,host:"host-\(n)") }
        #expect(throws:StreamProfileCatalog.ProfileError.self) { try catalog.setHost(video,host:"overflow") }
        try catalog.setHost(video,host:"host-0") // Updating a full catalog is allowed.
        try catalog.setHost(nil,host:"host-0");try catalog.setHost(video,host:"overflow")
        for n in 0..<StreamProfileCatalog.gameCapacity { try catalog.setGame(source:.global,video:nil,host:"PC",game:"game-\(n)") }
        #expect(throws:StreamProfileCatalog.ProfileError.self) { try catalog.setGame(source:.global,video:nil,host:"Other PC",game:"overflow") }
        try catalog.setGame(source:.host,video:nil,host:"PC",game:"game-0")
        try catalog.setGame(source:.custom,video:video,host:"Other PC",game:"overflow")
        #expect(try StreamProfileCatalog(data:catalog.encoded()) == catalog)
    }
    @Test func malformedFutureOversizedAndIncompleteProfilesAreRejected() throws {
        let documents=["not JSON","{\"version\":99,\"hosts\":{},\"games\":{}}",
            "{\"version\":1,\"hosts\":{},\"games\":{\"PC\":{\"Game\":{\"source\":\"custom\"}}}}",
            "{\"version\":1,\"hosts\":{},\"games\":{\"PC\":{\"Game\":{\"source\":\"unknown\"}}}}"]
        for document in documents {
            #expect(throws:(any Error).self) { try StreamProfileCatalog(data:Data(document.utf8)) }
        }
        #expect(throws:(any Error).self) { try StreamProfileCatalog(data:Data(repeating:0,count:1_048_577)) }
        var catalog=StreamProfileCatalog()
        #expect(throws:(any Error).self) { try catalog.setHost(StreamVideoSettings(),host:"") }
        #expect(throws:(any Error).self) { try catalog.setGame(source:.custom,video:nil,host:"PC",game:"A") }
        #expect(throws:(any Error).self) { try catalog.setHost(StreamVideoSettings(),host:String(repeating:"a",count:513)) }
    }
}
