import Testing
import Foundation
@testable import MysticCore

struct StreamPreferencesTests {
    @Test func clampsInvalidStoredValues() {
        var preferences=StreamPreferences()
        preferences.resolution="999999x1";preferences.fps=501;preferences.bitrateMbps = .max
        preferences.codec="software";preferences.audioLayout="unknown";preferences.volume = .nan
        preferences.libraryLayout="custom";preferences.librarySort="random";preferences.settingsPane="unsupported"
        let validated=preferences.validated()
        #expect(validated.resolution == "native" && validated.fps == 0 && validated.bitrateMbps == 2000)
        #expect(validated.codec == "auto" && validated.audioLayout == "stereo" && validated.volume == 0.8)
        #expect(validated.libraryLayout == "grid" && validated.librarySort == "name" && validated.settingsPane == "general")
        preferences.volume = -1;preferences.bitrateMbps = -1
        #expect(preferences.validated().volume == 0 && preferences.validated().bitrateMbps == 0)
    }
    @Test func customSizesAndRatesAreKeptWithinNightjarsBounds() {
        var preferences=StreamPreferences()
        preferences.resolution="1234x567";preferences.fps=75;preferences.bitrateMbps=1500
        var validated=preferences.validated()
        #expect(validated.resolution == "1234x567" && validated.fps == 75 && validated.bitrateMbps == 1500)
        for size in ["319x240","320x239","7681x1080","1920x4321","1920","x","1920x","-1x-1"] {
            preferences.resolution=size
            #expect(preferences.validated().resolution == "native",Comment(rawValue:size))
        }
        preferences.resolution="320x240";preferences.fps=9;preferences.qualityMinShortEdge=1;preferences.qualityMinFps=999
        validated=preferences.validated()
        #expect(validated.resolution == "320x240" && validated.fps == 0)
        #expect(validated.qualityMinShortEdge == 256 && validated.qualityMinFps == 240)
    }
    @Test func nativeDisplayAndRecommendedSettleFromTheScreen() {
        let video=StreamVideoSettings()
        #expect(video.resolution == "native" && video.fps == 0 && video.bitrateMbps == 0)
        let laptop=video.mode(displayPixels:(3024,1964),displayHertz:119.88)
        #expect(laptop.width == 3024 && laptop.height == 1964 && laptop.fps == 120)
        #expect(laptop.bitrateKbps == StreamMode.recommendedKbps(width:3024,height:1964,fps:120))
        let unknown=video.mode(displayPixels:nil,displayHertz:nil)
        #expect(unknown.width == 1920 && unknown.height == 1080 && unknown.fps == 60 && unknown.bitrateKbps == 20_000)
        let huge=video.mode(displayPixels:(10240,4320),displayHertz:1000)
        #expect(huge.width == 7680 && huge.height == 3240 && huge.fps == 500)
        var fixed=video;fixed.resolution="1280x720";fixed.fps=90;fixed.bitrateMbps=33
        let chosen=fixed.mode(displayPixels:(3024,1964),displayHertz:120)
        #expect(chosen.width == 1280 && chosen.height == 720 && chosen.fps == 90 && chosen.bitrateKbps == 33_000)
    }
    @Test func recommendedBitrateFollowsNightjarsCurve() {
        #expect(StreamMode.recommendedKbps(width:1920,height:1080,fps:60) == 20_000)
        #expect(StreamMode.recommendedKbps(width:1920,height:1080,fps:30) == 10_000)
        #expect(StreamMode.recommendedKbps(width:1920,height:1080,fps:240) == 40_000)
        #expect(StreamMode.recommendedKbps(width:640,height:360,fps:30) == 2_000)
        #expect(StreamMode.recommendedKbps(width:7680,height:4320,fps:240) == 150_000)
    }
    @Test func videoSizingPlacesThePicture() {
        let view=CGRect(x:0,y:0,width:1000,height:1000),video=CGSize(width:2000,height:1000)
        #expect(VideoSizing.fit.rect(video:video,in:view) == CGRect(x:0,y:250,width:1000,height:500))
        #expect(VideoSizing.fit.rect(video:video,in:view,alignTop:true) == CGRect(x:0,y:500,width:1000,height:500))
        #expect(VideoSizing.fill.rect(video:video,in:view,alignTop:true) == CGRect(x:-500,y:0,width:2000,height:1000))
        #expect(VideoSizing.stretch.rect(video:video,in:view) == view)
        #expect(VideoSizing.native.rect(video:video,in:view,pixelsPerPoint:2) == CGRect(x:0,y:250,width:1000,height:500))
        #expect(VideoSizing.native.rect(video:video,in:view,pixelsPerPoint:1,alignTop:true) == CGRect(x:-500,y:0,width:2000,height:1000))
        #expect(VideoSizing.fit.rect(video:.zero,in:view).isEmpty)
    }
    @Test func pcDisplayChoicesDefaultMigrateAndClamp() throws {
        let video=StreamVideoSettings()
        #expect(!video.virtualDisplay && video.hostDisplay == .hostDefault && video.renderScalePercent == 100 && video.displayScalePercent == 0)
        var preferences=StreamPreferences()
        preferences.hostDisplay="mirror";preferences.renderScalePercent=999;preferences.displayScalePercent=110
        let validated=preferences.validated()
        #expect(validated.hostDisplay == nil && validated.renderScalePercent == 200 && validated.displayScalePercent == nil)
        var chosen=video;chosen.virtualDisplay=true;chosen.hostDisplay = .extendedPrimary;chosen.renderScalePercent=150;chosen.displayScalePercent=175
        let restored=try JSONDecoder().decode(StreamVideoSettings.self,from:JSONEncoder().encode(chosen))
        #expect(restored == chosen)
        preferences=StreamPreferences();preferences.videoSettings=chosen
        #expect(preferences.videoSettings == chosen)
        preferences.videoSettings=video
        #expect(preferences.virtualDisplay == nil && preferences.hostDisplay == nil,"defaults stay out of the document")
    }
    @Test func arrangementsDecideTheVirtualDisplay() {
        #expect(HostDisplayMode.hostDefault.requestsVirtualDisplay(setting:true) && !HostDisplayMode.hostDefault.requestsVirtualDisplay(setting:false))
        #expect(HostDisplayMode.exclusive.requestsVirtualDisplay(setting:false) && !HostDisplayMode.physical.requestsVirtualDisplay(setting:true))
        #expect(HostFeatureAvailability.off.note != nil && !HostFeatureAvailability.off.usable)
        #expect(HostFeatureAvailability.unknown.usable && HostFeatureAvailability.never.note == nil)
    }
    @Test func rendererDefaultsToTheSystemLayer() {
        var preferences=StreamPreferences()
        #expect(preferences.videoRenderer == nil)
        preferences.videoRenderer="vulkan"
        #expect(preferences.validated().videoRenderer == nil)
        preferences.videoRenderer="metal"
        #expect(preferences.validated().videoRenderer == "metal")
    }
    @Test func inputPreferencesDefaultAndClamp() throws {
        var input=try JSONDecoder().decode(InputPreferences.self,from:Data("{}".utf8))
        #expect(input == InputPreferences() && input.mouseScale == 1 && input.stickDeadZone == 0.12)
        input.mouseSpeedPercent=1;input.stickDeadZonePercent=99
        #expect(input.validated().mouseSpeedPercent == 25 && input.validated().stickDeadZonePercent == 50)
        var preferences=StreamPreferences();preferences.input=input
        #expect(preferences.validated().input?.mouseSpeedPercent == 25)
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
        for resolution in ["3024x1890","3024x1964","3456x2160","3456x2234"] {
            var preferences=StreamPreferences();preferences.resolution=resolution
            let loaded=try JSONDecoder().decode(StreamPreferences.self,from:JSONEncoder().encode(preferences))
            #expect(loaded.validated().resolution == resolution)
        }
    }
    @Test func metalStreamsSDRBelowTheCameraAndKeepsTheSavedChoice() {
        var video=StreamVideoSettings();video.hdr=true;video.resolution="3024x1964"
        #expect(video.limited(to:.displayLayer) == video,"the System renderer streams what was chosen")
        let metal=video.limited(to:.metal)
        #expect(!metal.hdr && metal.resolution == "3024x1890")
        #expect(video.hdr && video.resolution == "3024x1964","the saved choice is untouched")
        video.resolution="3456x2234";#expect(video.limited(to:.metal).resolution == "3456x2160")
        for kept in [StreamPreferences.nativeResolution,"1920x1080","3024x1890","3456x2160"] {
            video.resolution=kept;#expect(video.limited(to:.metal).resolution == kept)
        }
        for (full,below) in StreamPreferences.belowCamera {
            #expect(StreamPreferences.resolutions.contains(full) && StreamPreferences.resolutions.contains(below))
            #expect(StreamPreferences.belowCamera[below] == nil,"a size below the camera is final")
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
