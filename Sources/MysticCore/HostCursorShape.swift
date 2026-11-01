/// A host cursor shape (control message 0x5541): with shapes on, the host leaves its cursor
/// out of the video, and the app draws it as the local pointer in desktop control.
public enum HostCursorShape: Sendable, Equatable {
    case hide
    /// The Mac's own arrow.
    case standard
    /// The image cached under `id`.
    case show(id: UInt32)
    /// Caches this image under `id` and shows it.
    case image(id: UInt32, image: HostCursorImage)
    /// The host sent a shape that broke the format; the Mac's arrow stands in.
    case rejected
}

public struct HostCursorImage: Sendable, Equatable {
    public let width: Int, height: Int
    public let hotspotX: Int, hotspotY: Int
    /// The host display's scale in percent: 200 draws the image at half its pixel size in points.
    public let scalePercent: Int
    /// Straight-alpha sRGB RGBA, rows top to bottom.
    public let rgba: [UInt8]
    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, scalePercent: Int, rgba: [UInt8]) {
        self.width=width;self.height=height;self.hotspotX=hotspotX;self.hotspotY=hotspotY
        self.scalePercent=scalePercent;self.rgba=rgba
    }
}
