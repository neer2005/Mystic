import Testing
@testable import MysticCore

@Suite("Keyboard layout report")
struct KeyboardLayoutReportTests {
    @Test func macLayoutsBecomeTheWindowsLayoutsThatTypeTheSame() {
        #expect(KeyboardLayoutReport.mac(inputSourceID:"com.apple.keylayout.German",languages:["de"])
            == KeyboardLayoutReport(source:.windows,klid:0x0000_0407,tag:"00000407"))
        #expect(KeyboardLayoutReport.mac(inputSourceID:"com.apple.keylayout.SwissFrench",languages:["fr"])?.tag == "0000100C")
        #expect(KeyboardLayoutReport.mac(inputSourceID:"com.apple.keylayout.Dvorak",languages:["en"])?.klid == 0x0001_0409)
        #expect(KeyboardLayoutReport.mac(inputSourceID:"com.apple.keylayout.ABC",languages:["en"])?.klid == 0x0409)
    }
    @Test func otherLayoutsFallBackToTheirLanguage() {
        #expect(KeyboardLayoutReport.mac(inputSourceID:"com.apple.keylayout.Colemak",languages:["en","de"])
            == KeyboardLayoutReport(source:.bcp47,klid:0,tag:"en"))
        #expect(KeyboardLayoutReport.mac(inputSourceID:"com.apple.keylayout.Lithuanian",languages:["lt"])?.tag == "lt")
        #expect(KeyboardLayoutReport.mac(inputSourceID:"com.apple.keylayout.Unknown",languages:[]) == nil)
        #expect(KeyboardLayoutReport.mac(inputSourceID:"x",languages:["zh Hans"]) == nil,"not a tag the wire carries")
    }
    @Test func everyMappedLayoutHasAValidTag() {
        for (name,klid) in KeyboardLayoutReport.windowsLayouts {
            let report=KeyboardLayoutReport.mac(inputSourceID:"com.apple.keylayout."+name,languages:[])
            #expect(report?.tag.count == 8 && report?.klid == klid,"\(name)")
        }
    }
}
