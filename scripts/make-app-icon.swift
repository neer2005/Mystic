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
    let pad=CGMutablePath()
    pad.move(to:CGPoint(x:356,y:712));pad.addLine(to:CGPoint(x:668,y:712))
    pad.addCurve(to:CGPoint(x:806,y:598),control1:CGPoint(x:744,y:712),control2:CGPoint(x:788,y:668))
    pad.addLine(to:CGPoint(x:852,y:408))
    pad.addCurve(to:CGPoint(x:782,y:298),control1:CGPoint(x:872,y:326),control2:CGPoint(x:830,y:288))
    pad.addCurve(to:CGPoint(x:690,y:402),control1:CGPoint(x:746,y:306),control2:CGPoint(x:718,y:346))
    pad.addCurve(to:CGPoint(x:620,y:456),control1:CGPoint(x:674,y:436),control2:CGPoint(x:652,y:456))
    pad.addLine(to:CGPoint(x:404,y:456))
    pad.addCurve(to:CGPoint(x:334,y:402),control1:CGPoint(x:372,y:456),control2:CGPoint(x:350,y:436))
    pad.addCurve(to:CGPoint(x:242,y:298),control1:CGPoint(x:306,y:346),control2:CGPoint(x:278,y:306))
    pad.addCurve(to:CGPoint(x:172,y:408),control1:CGPoint(x:194,y:288),control2:CGPoint(x:152,y:326))
    pad.addLine(to:CGPoint(x:218,y:598))
    pad.addCurve(to:CGPoint(x:356,y:712),control1:CGPoint(x:236,y:668),control2:CGPoint(x:280,y:712))
    pad.closeSubpath()
    // The D-pad and the four buttons, cut out.
    let (dx,dy,arm,half): (CGFloat,CGFloat,CGFloat,CGFloat)=(372,590,66,23)
    pad.addLines(between:[CGPoint(x:dx-half,y:dy+arm),CGPoint(x:dx+half,y:dy+arm),CGPoint(x:dx+half,y:dy+half),CGPoint(x:dx+arm,y:dy+half),
                          CGPoint(x:dx+arm,y:dy-half),CGPoint(x:dx+half,y:dy-half),CGPoint(x:dx+half,y:dy-arm),CGPoint(x:dx-half,y:dy-arm),
                          CGPoint(x:dx-half,y:dy-half),CGPoint(x:dx-arm,y:dy-half),CGPoint(x:dx-arm,y:dy+half),CGPoint(x:dx-half,y:dy+half)])
    pad.closeSubpath()
    for (x,y) in [(652.0,644.0),(652.0,536.0),(598.0,590.0),(706.0,590.0)] as [(CGFloat,CGFloat)] {
        pad.addEllipse(in:CGRect(x:x-27,y:y-27,width:54,height:54))
    }
    c.saveGState();c.addPath(pad);c.clip(using:.evenOdd)
    c.drawLinearGradient(CGGradient(colorsSpace:space,colors:[color(1,1,1),color(0.8,0.8,0.82)] as CFArray,locations:[0,1])!,
                         start:CGPoint(x:512,y:712),end:CGPoint(x:512,y:298),options:[])
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
