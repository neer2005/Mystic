import Testing
import Foundation
@testable import MysticCore

struct StreamPreferencesTests {
    @Test func clampsInvalidStoredValues() {
        var preferences=StreamPreferences()
        preferences.resolution="999999x1";preferences.fps=0;preferences.bitrateMbps = .max
        preferences.codec="software";preferences.audioLayout="unknown";preferences.volume = .nan
        preferences.libraryLayout="custom";preferences.librarySort="random";preferences.settingsPane="unsupported"
        let validated=preferences.validated()
        #expect(validated.resolution == "1920x1080" && validated.fps == 60 && validated.bitrateMbps == 150)
        #expect(validated.codec == "auto" && validated.audioLayout == "stereo" && validated.volume == 0.8)
        #expect(validated.libraryLayout == "grid" && validated.librarySort == "name" && validated.settingsPane == "general")
        preferences.volume = -1;preferences.bitrateMbps = -1
        #expect(preferences.validated().volume == 0 && preferences.validated().bitrateMbps == 5)
    }
    @Test func networkSettingsDefaultAndRejectUnknownValues() throws {
        let old=try JSONDecoder().decode(StreamPreferences.self,from:Data(#"{"resolution":"1920x1080","fps":60,"bitrateMbps":20,"codec":"auto","hdr":false,"audioLayout":"stereo","volume":0.8,"muted":false,"showLatencyHUD":false,"libraryLayout":"grid","librarySort":"name","discoveryEnabled":true,"settingsPane":"general"}"#.utf8))
        #expect(old.networkGraceSeconds == nil && old.errorCorrection == nil && old.tellHostWireless == nil && old.tellHostLinkSpeed == nil)
        var preferences=StreamPreferences();preferences.networkGraceSeconds=45;preferences.errorCorrection="75"
        #expect(preferences.validated().networkGraceSeconds == nil && preferences.validated().errorCorrection == nil)
        preferences.networkGraceSeconds=30;preferences.errorCorrection="auto"
        #expect(preferences.validated().networkGraceSeconds == 30 && preferences.validated().errorCorrection == "auto")
        #expect(NetworkGrace.off.milliseconds == 3000 && NetworkGrace.sixtySeconds.milliseconds == 60_000)
        #expect(ErrorCorrection.host.engineValue == -1 && ErrorCorrection.automatic.engineValue == -2 && ErrorCorrection.fifty.engineValue == 50)
    }
    @Test func nativeMacBookResolutionsSurviveValidationAndStorage() throws {
        for resolution in ["3024x1890","3024x1964","3456x2234"] {
            var preferences=StreamPreferences();preferences.resolution=resolution
            let loaded=try JSONDecoder().decode(StreamPreferences.self,from:JSONEncoder().encode(preferences))
            #expect(loaded.validated().resolution == resolution)
        }
    }
    @Test func supportedDefaultsRoundTripWithoutCredentials() throws {
        var preferences=StreamPreferences()
        preferences.resolution="3840x2160";preferences.fps=120;preferences.codec="hevc";preferences.hdr=true
        preferences.audioLayout="7.1";preferences.volume=0.5;preferences.muted=true;preferences.showLatencyHUD=true
        preferences.libraryLayout="list";preferences.librarySort="host";preferences.discoveryEnabled=false
        let data=try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(StreamPreferences.self,from:data).validated() == preferences)
    }
}
