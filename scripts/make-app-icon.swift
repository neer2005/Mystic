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
    // Traced from a photo of an Xbox Series controller, 700 points wide: the outline's right half from
    // the top centre, then the controls, mapped onto the icon and drawn as a smooth curve.
    // About two thirds of the tile wide, raised a little so it looks centred.
    func mapped(_ x: CGFloat,_ y: CGFloat) -> CGPoint { CGPoint(x:512+(x-350),y:528-(y-352)) }
    let half: [(CGFloat,CGFloat)]=[(350,176),(430,176),(480,180),(520,190),(554,208),(578,238),(596,288),(608,350),
        (618,420),(626,478),(628,514),(614,538),(588,546),(560,536),(528,508),(500,472),(470,448),(430,436),(390,432)]
    let outline=half.map { mapped($0.0,$0.1) }+[mapped(350,430)]+half.dropFirst().reversed().map { mapped(700-$0.0,$0.1) }
    let pad=CGMutablePath()
    // Catmull-Rom through every point, closed.
    pad.move(to:outline[0])
    for i in outline.indices {
        let p0=outline[(i+outline.count-1)%outline.count],p1=outline[i],p2=outline[(i+1)%outline.count],p3=outline[(i+2)%outline.count]
        pad.addCurve(to:p2,control1:CGPoint(x:p1.x+(p2.x-p0.x)/6,y:p1.y+(p2.y-p0.y)/6),
                     control2:CGPoint(x:p2.x-(p3.x-p1.x)/6,y:p2.y-(p3.y-p1.y)/6))
    }
    pad.closeSubpath()
    // Cut out: only the D-pad and the four buttons, level and large enough to read at Dock size.
    func circle(_ x: CGFloat,_ y: CGFloat,_ radius: CGFloat) {
        let centre=mapped(x,y);pad.addEllipse(in:CGRect(x:centre.x-radius,y:centre.y-radius,width:radius*2,height:radius*2))
    }
    let d=mapped(232,300),(arm,width): (CGFloat,CGFloat)=(62,22)
    pad.addLines(between:[CGPoint(x:d.x-width,y:d.y+arm),CGPoint(x:d.x+width,y:d.y+arm),CGPoint(x:d.x+width,y:d.y+width),CGPoint(x:d.x+arm,y:d.y+width),
                          CGPoint(x:d.x+arm,y:d.y-width),CGPoint(x:d.x+width,y:d.y-width),CGPoint(x:d.x+width,y:d.y-arm),CGPoint(x:d.x-width,y:d.y-arm),
                          CGPoint(x:d.x-width,y:d.y-width),CGPoint(x:d.x-arm,y:d.y-width),CGPoint(x:d.x-arm,y:d.y+width),CGPoint(x:d.x-width,y:d.y+width)])
    pad.closeSubpath()
    for (x,y) in [(468.0,248.0),(468.0,352.0),(416.0,300.0),(520.0,300.0)] as [(CGFloat,CGFloat)] { circle(x,y,27) }
    c.saveGState();c.addPath(pad);c.clip(using:.evenOdd)
    c.drawLinearGradient(CGGradient(colorsSpace:space,colors:[color(1,1,1),color(0.8,0.8,0.82)] as CFArray,locations:[0,1])!,
                         start:CGPoint(x:512,y:730),end:CGPoint(x:512,y:280),options:[])
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
