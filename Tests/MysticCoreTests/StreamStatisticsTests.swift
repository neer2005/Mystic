import Testing
@testable import MysticCore

@Suite("Stream statistics")
struct StreamStatisticsTests {
    @Test func rowsUseNightjarsColumnsAndKeepTheLastHour() {
        var statistics=StreamStatistics()
        statistics.add(.init(elapsedMs:1000,receivedFps:120,decodedFps:119.5,shownFps:119.25,lossPercent:0.5,rttMs:8.25,
                             decodeMs:1.5,renderMs:nil,bitrateKbps:30000))
        statistics.add(.init(elapsedMs:2000,receivedFps:nil,decodedFps:nil,shownFps:nil,lossPercent:nil,rttMs:nil,decodeMs:nil,renderMs:nil,bitrateKbps:30000))
        #expect(statistics.csv == StreamStatistics.header
            + "1000,120.000,119.500,119.250,0.500,8.250,1.500,,,,30000\n"
            + "2000,0.000,0.000,0.000,0.000,,,,,,30000\n")
        for second in 0..<StreamStatistics.maxRows+5 {
            statistics.add(.init(elapsedMs:UInt64(second),receivedFps:nil,decodedFps:nil,shownFps:nil,lossPercent:nil,rttMs:nil,decodeMs:nil,renderMs:nil,bitrateKbps:1))
        }
        #expect(statistics.rows.count == StreamStatistics.maxRows && statistics.rows.first?.elapsedMs == 5)
        #expect(StreamStatistics.header.split(separator:",").count == 11)
    }
    @Test func preferencesKeepTheKeyboardPaneAndOverlayMode() {
        var preferences=StreamPreferences()
        preferences.settingsPane="keyboard";preferences.overlayMode="debug"
        #expect(preferences.validated().settingsPane == "keyboard" && preferences.validated().overlayMode == "debug")
        preferences.overlayMode="loud";#expect(preferences.validated().overlayMode == nil)
        preferences.overlayMode="compact";#expect(preferences.validated().overlayMode == nil,"the default is stored as absent")
    }
}
