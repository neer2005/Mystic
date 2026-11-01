import AppKit
import MysticCore

/// The host's cursor as the Mac pointer over the video, from the shapes the host sends while
/// desktop control has them on, as Nightjar's desktop client draws them (`stream/cursor.rs`).
/// The pointer then moves without the video's delay.
@MainActor
final class HostCursor {
    /// Windows hides its cursor for a moment while it changes it; hiding at once flickered.
    /// Nightjar's delay, from Moonlight V+ (`REMOTE_CURSOR_HIDE_DEBOUNCE_MS`).
    static let hideDelay: Duration = .milliseconds(150)
    /// Images both sides keep at least.
    static let cacheEntries = 32
    private(set) var current: NSCursor = .arrow
    private var cache: [(id: UInt32, cursor: NSCursor)] = []
    private var pendingHide: Task<Void, Never>?
    private let delay: Duration
    /// The pointer to draw changed.
    var changed: () -> Void = {}
    /// The host referred to an image it never sent, or sent one that broke the format.
    var failure: (String) -> Void = { _ in }
    init(hideDelay: Duration = HostCursor.hideDelay) { delay=hideDelay }
    isolated deinit { pendingHide?.cancel() }

    func apply(_ shapes: [HostCursorShape]) { for shape in shapes { apply(shape) } }
    func apply(_ shape: HostCursorShape) {
        if shape != .hide { pendingHide?.cancel();pendingHide=nil }
        switch shape {
        case .hide:
            // A second hide does not put off the first.
            guard pendingHide == nil,current !== Self.hidden else { return }
            pendingHide=Task { [weak self,delay] in
                guard (try? await Task.sleep(for:delay)) != nil,let self else { return }
                self.pendingHide=nil;self.show(Self.hidden)
            }
        case .standard: show(.arrow)
        case .show(let id):
            guard let index=cache.firstIndex(where: { $0.id == id }) else {
                show(.arrow);failure("The host referred to a cursor it never sent; using the Mac pointer.");return
            }
            let entry=cache.remove(at:index);cache.append(entry);show(entry.cursor)
        case .image(let id,let image):
            guard let cursor=Self.cursor(image) else {
                show(.arrow);failure("The host's cursor could not be drawn; using the Mac pointer.");return
            }
            cache.removeAll { $0.id == id };cache.append((id,cursor))
            if cache.count > Self.cacheEntries { cache.removeFirst() }
            show(cursor)
        case .rejected:
            show(.arrow);failure("The host sent a malformed cursor; using the Mac pointer.")
        }
    }
    /// Forgets every image: the host starts its cache again when shapes are turned back on.
    func reset() {
        pendingHide?.cancel();pendingHide=nil;cache.removeAll();show(.arrow)
    }
    private func show(_ cursor: NSCursor) {
        guard cursor !== current else { return }
        current=cursor;changed()
    }

    /// A transparent pointer: hiding by cursor rect needs no balanced `NSCursor.hide` calls.
    static let hidden = NSCursor(image:NSImage(size:NSSize(width:1,height:1)),hotSpot:.zero)
    /// The image at the host's scale: a 64-pixel cursor from a 200% display is 32 points, drawn
    /// from all 64 pixels on a Retina screen.
    static func cursor(_ image: HostCursorImage) -> NSCursor? {
        guard image.width > 0,image.height > 0,image.rgba.count == image.width*image.height*4,
              (100...400).contains(image.scalePercent),
              let provider=CGDataProvider(data:Data(image.rgba) as CFData),
              let picture=CGImage(width:image.width,height:image.height,bitsPerComponent:8,bitsPerPixel:32,
                                  bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                  bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
                                  provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
        else { return nil }
        let scale=CGFloat(image.scalePercent)/100
        let size=NSSize(width:max(1,CGFloat(image.width)/scale),height:max(1,CGFloat(image.height)/scale))
        let hotspot=NSPoint(x:min(CGFloat(image.hotspotX)/scale,size.width-1),y:min(CGFloat(image.hotspotY)/scale,size.height-1))
        return NSCursor(image:NSImage(cgImage:picture,size:size),hotSpot:hotspot)
    }
}
