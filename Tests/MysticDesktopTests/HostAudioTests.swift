import XCTest
import MysticKit
@testable import MysticDesktop

final class HostAudioDecodingTests: XCTestCase {
    func testASwitchDecodesWithItsNote() throws {
        let json=#"{"id":"audio.night_mode","label":"Night Mode","on":true,"enabled":false,"note":"Applies next stream"}"#
        XCTAssertEqual(try JSONDecoder().decode(HostAudioSwitch.self,from:Data(json.utf8)),HostAudioSwitch(id:"audio.night_mode",label:"Night Mode",on:true,enabled:false,note:"Applies next stream"))
    }
}
