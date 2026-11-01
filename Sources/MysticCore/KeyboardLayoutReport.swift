/// The keyboard layout this Mac types with, for hosts that switch the PC's input language to
/// match (control message 0x553E), as Nightjar's desktop client reports Windows and XKB layouts.
/// Mystic sends physical key positions, so a German Mac keyboard types German on the PC only
/// once the PC uses a German layout too.
public struct KeyboardLayoutReport: Sendable, Equatable {
    public enum Source: UInt8, Sendable { case unknown = 0, windows = 1, bcp47 = 2, xkb = 3 }
    public let source: Source
    /// The Windows layout identifier, such as 0x00000407 for German; 0 when unknown.
    public let klid: UInt32
    /// At most 64 printable ASCII bytes: the KLID in hex, or a BCP-47 language.
    public let tag: String
    public init(source: Source,klid: UInt32,tag: String) { self.source=source;self.klid=klid;self.tag=tag }

    /// A Mac input source as a report: the Windows layout that types the same where there is
    /// one, else the source's first language, which the PC maps to its default layout.
    public static func mac(inputSourceID: String,languages: [String]) -> Self? {
        let name=inputSourceID.hasPrefix(prefix) ? String(inputSourceID.dropFirst(prefix.count)) : inputSourceID
        if let klid=windowsLayouts[name] {
            return Self(source:.windows,klid:klid,tag:hex(klid))
        }
        guard let language=languages.first,valid(language) else { return nil }
        return Self(source:.bcp47,klid:0,tag:language)
    }
    static func hex(_ klid: UInt32) -> String {
        let digits=String(klid,radix:16,uppercase:true)
        return String(repeating:"0",count:max(0,8-digits.count))+digits
    }
    static func valid(_ tag: String) -> Bool {
        !tag.isEmpty && tag.utf8.count <= 64 && tag.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
    private static let prefix="com.apple.keylayout."
    /// Mac keyboard layouts and the Windows layouts their keys match, by physical position.
    static let windowsLayouts: [String:UInt32] = [
        "US":0x0000_0409,"ABC":0x0000_0409,"USExtended":0x0000_0409,"Australian":0x0000_0409,
        "USInternational-PC":0x0002_0409,"Dvorak":0x0001_0409,
        "British":0x0000_0809,"British-PC":0x0000_0809,"Irish":0x0000_1809,
        "German":0x0000_0407,"Austrian":0x0000_0407,"SwissGerman":0x0000_0807,"SwissFrench":0x0000_100C,
        "French":0x0000_040C,"French-PC":0x0000_040C,"Belgian":0x0000_080C,"Canadian-CSA":0x0001_1009,
        "Spanish":0x0000_040A,"Spanish-ISO":0x0000_040A,"Italian":0x0000_0410,"Italian-Pro":0x0000_0410,
        "Portuguese":0x0000_0816,"Brazilian":0x0000_0416,"Brazilian-Pro":0x0000_0416,"Dutch":0x0000_0413,
        "Swedish":0x0000_041D,"Swedish-Pro":0x0000_041D,"Norwegian":0x0000_0414,"Danish":0x0000_0406,
        "Finnish":0x0000_040B,"Icelandic":0x0000_040F,"PolishPro":0x0000_0415,"Czech":0x0000_0405,
        "Czech-QWERTY":0x0001_0405,"Slovak":0x0000_041B,"Hungarian":0x0000_040E,"Russian":0x0000_0419,
        "Russian-PC":0x0000_0419,"Ukrainian-PC":0x0000_0422,"Greek":0x0000_0408,"Turkish-QWERTY-PC":0x0000_041F,
        "Turkish":0x0001_041F,"Hebrew":0x0000_040D,
    ]
}
