import AppKit
import CoreGraphics

/// The refresh rate the host is told at launch. A 59.94 Hz display otherwise launches at 60
/// and drops or repeats a frame every 16 seconds; hosts that read fractional rates take the
/// exact one when it rounds to the stream's frame rate, as Nightjar's desktop client sends it.
enum DisplayRefresh {
    /// The screen's current mode rate, which CoreGraphics reports exactly (59.94). Some
    /// built-in panels report 0 there, so their nominal maximum stands in.
    static func hertz(_ screen: NSScreen) -> Double {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let id = number.map({ CGDirectDisplayID($0.uint32Value) }),
           let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 {
            return mode.refreshRate
        }
        return Double(screen.maximumFramesPerSecond)
    }
    /// x100 for the launch request and stream configuration; 0 when unknown or implausible.
    static func x100(_ hertz: Double?) -> UInt32 {
        guard let hertz, hertz.isFinite, (1...1000).contains(hertz) else { return 0 }
        return UInt32((hertz * 100).rounded())
    }
}
