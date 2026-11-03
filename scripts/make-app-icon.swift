#!/usr/bin/env swift
// Draws Mystic's app icon and writes Resources/AppIcon.icns: run from the repository root.
import AppKit

func draw(_ pixels: Int) -> Data {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,
                             hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    let s=CGFloat(pixels)/1024
    let c=NSGraphicsContext.current!.cgContext
    c.scaleBy(x:s,y:s)
    // macOS's icon grid: an 824 point rounded square centred on the canvas.
    let tile=CGRect(x:100,y:100,width:824,height:824)
    let shape=CGPath(roundedRect:tile,cornerWidth:185,cornerHeight:185,transform:nil)
    let space=CGColorSpaceCreateDeviceRGB()
    func color(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat = 1) -> CGColor { CGColor(colorSpace:space,components:[r,g,b,a])! }
    // Near black, a little lighter at the top, with a fine light edge.
    c.saveGState();c.addPath(shape);c.clip()
    c.drawLinearGradient(CGGradient(colorsSpace:space,colors:[color(0.17,0.17,0.18),color(0.03,0.03,0.04)] as CFArray,locations:[0,1])!,
                         start:CGPoint(x:512,y:924),end:CGPoint(x:512,y:100),options:[])
    c.restoreGState()
    c.addPath(CGPath(roundedRect:tile.insetBy(dx:2,dy:2),cornerWidth:183,cornerHeight:183,transform:nil))
    c.setStrokeColor(color(1,1,1,0.14));c.setLineWidth(4);c.strokePath()
    // A white controller, drawn here: Apple's symbols may not be used in app icons.
    // Shaped like an Xbox One controller: a flatter top, grips that taper, staggered sticks.
    let pad=CGMutablePath()
    let right: [(CGPoint,CGPoint,CGPoint)]=[
        (CGPoint(x:580,y:688),CGPoint(x:640,y:702),CGPoint(x:690,y:704)),
        (CGPoint(x:760,y:708),CGPoint(x:810,y:690),CGPoint(x:832,y:630)),
        (CGPoint(x:856,y:560),CGPoint(x:874,y:460),CGPoint(x:864,y:380)),
        (CGPoint(x:856,y:314),CGPoint(x:800,y:294),CGPoint(x:760,y:326)),
        (CGPoint(x:726,y:354),CGPoint(x:700,y:404),CGPoint(x:656,y:426)),
        (CGPoint(x:612,y:448),CGPoint(x:560,y:452),CGPoint(x:512,y:452))]
    func mirrored(_ point: CGPoint) -> CGPoint { CGPoint(x:1024-point.x,y:point.y) }
    pad.move(to:CGPoint(x:512,y:688))
    for curve in right { pad.addCurve(to:curve.2,control1:curve.0,control2:curve.1) }
    // Back up the left side, the same curves in reverse.
    var ends=[CGPoint(x:512,y:688)]+right.map(\.2)
    ends.removeLast()
    for (curve,end) in zip(right,ends).reversed() {
        pad.addCurve(to:mirrored(end),control1:mirrored(curve.1),control2:mirrored(curve.0))
    }
    pad.closeSubpath()
    // Cut out: a ring for each stick, the D-pad, the four buttons, the guide button and View and Menu.
    func circle(_ x: CGFloat,_ y: CGFloat,_ radius: CGFloat) { pad.addEllipse(in:CGRect(x:x-radius,y:y-radius,width:radius*2,height:radius*2)) }
    circle(334,590,54);circle(334,590,30)
    circle(610,500,46);circle(610,500,25)
    let (dx,dy,arm,half): (CGFloat,CGFloat,CGFloat,CGFloat)=(414,500,44,16)
    pad.addLines(between:[CGPoint(x:dx-half,y:dy+arm),CGPoint(x:dx+half,y:dy+arm),CGPoint(x:dx+half,y:dy+half),CGPoint(x:dx+arm,y:dy+half),
                          CGPoint(x:dx+arm,y:dy-half),CGPoint(x:dx+half,y:dy-half),CGPoint(x:dx+half,y:dy-arm),CGPoint(x:dx-half,y:dy-arm),
                          CGPoint(x:dx-half,y:dy-half),CGPoint(x:dx-arm,y:dy-half),CGPoint(x:dx-arm,y:dy+half),CGPoint(x:dx-half,y:dy+half)])
    pad.closeSubpath()
    for (x,y) in [(694.0,630.0),(694.0,550.0),(654.0,590.0),(734.0,590.0)] as [(CGFloat,CGFloat)] { circle(x,y,20) }
    circle(512,642,26);circle(470,586,10);circle(554,586,10)
    c.saveGState();c.addPath(pad);c.clip(using:.evenOdd)
    c.drawLinearGradient(CGGradient(colorsSpace:space,colors:[color(1,1,1),color(0.8,0.8,0.82)] as CFArray,locations:[0,1])!,
                         start:CGPoint(x:512,y:712),end:CGPoint(x:512,y:290),options:[])
    c.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using:.png,properties:[:])!
}
let set=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("Mystic-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at:set,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    try draw(size).write(to:set.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size*2).write(to:set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let tool=Process();tool.executableURL=URL(fileURLWithPath:"/usr/bin/iconutil")
tool.arguments=["-c","icns",set.path,"-o","Resources/AppIcon.icns"]
try tool.run();tool.waitUntilExit()
try? FileManager.default.removeItem(at:set)
exit(tool.terminationStatus)
