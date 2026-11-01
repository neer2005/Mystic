import Foundation
import Testing
@testable import MysticCore

/// After Nightjar's `config.rs` profiles test, with Mystic's route-based kinds.
@Suite("Network profiles")
struct NetworkProfilesTests {
    @Test func rulesPickByNetworkAndTheHandChoiceFillsIn() throws {
        var profiles=NetworkProfiles()
        let home=try profiles.create(name:"Home",overrides:VideoOverrides(fps:120))
        let travel=try profiles.create(name:"Travel",overrides:VideoOverrides(resolution:"1920x1080",bitrateMbps:15))
        profiles.active=home;profiles.rules=[.metered:travel,.remote:travel]
        #expect(profiles.selected(.metered)?.id == home,"automatic choice is off")
        profiles.automatic=true
        #expect(profiles.selected(.metered)?.id == travel && profiles.selected(.remote)?.id == travel)
        #expect(profiles.selected(.wifi)?.id == home && profiles.selected(nil)?.id == home,"no rule: the hand choice")
        #expect(throws:NetworkProfiles.Failure.self) { try profiles.create(name:" travel ",overrides:VideoOverrides()) }
        #expect(throws:NetworkProfiles.Failure.self) { try profiles.create(name:"",overrides:VideoOverrides()) }
        let restored=try JSONDecoder().decode(NetworkProfiles.self,from:JSONEncoder().encode(profiles))
        #expect(restored == profiles)
        profiles.delete(id:travel)
        #expect(profiles.rules.isEmpty && profiles.selected(.metered)?.id == home)
        profiles.active=999;#expect(profiles.selected(.wifi) == nil,"a missing profile changes nothing")
    }
    @Test func overridesApplyOnlyWhatTheyNameAndValidate() {
        var video=StreamVideoSettings();video.resolution="3840x2160";video.fps=120;video.bitrateMbps=80;video.hdr=true
        let travel=VideoOverrides(resolution:"1920x1080",bitrateMbps:15)
        let applied=travel.apply(to:video)
        #expect(applied.resolution == "1920x1080" && applied.bitrateMbps == 15 && applied.fps == 120 && applied.hdr)
        #expect(VideoOverrides(bitrateMbps:9000).apply(to:video).bitrateMbps == 2000,"clamped as any setting")
        #expect(travel.summary == "1920 × 1080 · 15 Mbps" && VideoOverrides().summary == "no changes")
    }
    @Test func theRouteDecidesTheKind() {
        #expect(NetworkKind.of(metered:true,vpn:true,localHost:false,wireless:true) == .metered)
        #expect(NetworkKind.of(metered:false,vpn:true,localHost:true,wireless:false) == .remote)
        #expect(NetworkKind.of(metered:false,vpn:false,localHost:false,wireless:true) == .remote)
        #expect(NetworkKind.of(metered:false,vpn:false,localHost:true,wireless:true) == .wifi)
        #expect(NetworkKind.of(metered:false,vpn:false,localHost:true,wireless:false) == .wired)
        #expect(NetworkKind.of(metered:false,vpn:false,localHost:true,wireless:nil) == nil)
        for local in ["192.168.1.20","10.0.0.5","172.20.1.1","169.254.3.4","fe80::1","fd12::3","[fd12::3]","gaming-pc.local","gaming-pc","127.0.0.1"] {
            #expect(NetworkKind.isLocal(local),"\(local)")
        }
        for remote in ["100.101.102.103","8.8.8.8","172.32.0.1","pc.example.com","2001:db8::1"] { #expect(!NetworkKind.isLocal(remote),"\(remote)") }
    }
    @Test func quitOnLeaveIsPerHostAndGame() throws {
        var quits=QuitOnLeave()
        quits.set(true,host:"id:a",game:"uuid:g")
        #expect(quits.quits(host:"id:a",game:"uuid:g") && !quits.quits(host:"id:b",game:"uuid:g"))
        #expect(try JSONDecoder().decode(QuitOnLeave.self,from:JSONEncoder().encode(quits)) == quits)
        quits.set(false,host:"id:a",game:"uuid:g");#expect(!quits.quits(host:"id:a",game:"uuid:g"))
    }
}
