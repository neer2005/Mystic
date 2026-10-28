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
    @Test func supportedDefaultsRoundTripWithoutCredentials() throws {
        var preferences=StreamPreferences()
        preferences.resolution="3840x2160";preferences.fps=120;preferences.codec="hevc";preferences.hdr=true
        preferences.audioLayout="7.1";preferences.volume=0.5;preferences.muted=true;preferences.showLatencyHUD=true
        preferences.libraryLayout="list";preferences.librarySort="host";preferences.discoveryEnabled=false
        let data=try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(StreamPreferences.self,from:data).validated() == preferences)
    }
}
