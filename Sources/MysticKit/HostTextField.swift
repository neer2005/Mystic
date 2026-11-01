import CMystic
import MysticCore

/// The host's focused text field, from its newest notice (control message 0x553B).
public struct HostTextField: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case text, number, decimal, phone, email, url, password, search, multiline }
    /// nil when no field has focus.
    public let kind: Kind?
    public let sensitive: Bool
    /// The host sends notices for this stream; without them nothing is known about its fields.
    public let notices: Bool
    public init(kind: Kind?,sensitive: Bool,notices: Bool) { self.kind=kind;self.sensitive=sensitive;self.notices=notices }
    /// Text without a key may go: a field has focus, or the host says nothing about fields.
    public var takesText: Bool { !notices || kind != nil }
    init(_ c: MysticTextField) {
        self.init(kind:Kind(rawValue:c.input_type),sensitive:c.sensitive,notices:c.notices)
    }
}
