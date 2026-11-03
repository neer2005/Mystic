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
    c.saveGState();c.addPath(shape);c.clip()
    c.drawLinearGradient(CGGradient(colorsSpace:space,colors:[color(0.27,0.14,0.62),color(0.07,0.05,0.22)] as CFArray,locations:[0,1])!,
                         start:CGPoint(x:512,y:924),end:CGPoint(x:512,y:100),options:[])
    // The glow of the orb on the tile.
    c.drawRadialGradient(CGGradient(colorsSpace:space,colors:[color(0.45,0.55,1,0.45),color(0.45,0.55,1,0)] as CFArray,locations:[0,1])!,
                         startCenter:CGPoint(x:512,y:520),startRadius:0,endCenter:CGPoint(x:512,y:520),endRadius:430,options:[])
    c.restoreGState()
    // The orb.
    let orb=CGRect(x:252,y:260,width:520,height:520)
    c.saveGState();c.addEllipse(in:orb);c.clip()
    c.drawRadialGradient(CGGradient(colorsSpace:space,colors:[color(0.62,0.82,1),color(0.36,0.32,0.95),color(0.16,0.08,0.5)] as CFArray,locations:[0,0.55,1])!,
                         startCenter:CGPoint(x:440,y:640),startRadius:10,endCenter:CGPoint(x:512,y:520),endRadius:270,options:[])
    c.restoreGState()
    c.setStrokeColor(color(1,1,1,0.28));c.setLineWidth(6);c.strokeEllipse(in:orb)
    // Play, inside the orb.
    let play=CGMutablePath()
    play.move(to:CGPoint(x:448,y:412));play.addLine(to:CGPoint(x:448,y:628));play.addLine(to:CGPoint(x:632,y:520));play.closeSubpath()
    c.setLineJoin(.round);c.setLineWidth(34)
    c.setFillColor(color(1,1,1));c.setStrokeColor(color(1,1,1))
    c.addPath(play);c.drawPath(using:.fillStroke)
    // The orb's stand.
    let base=CGPath(roundedRect:CGRect(x:372,y:186,width:280,height:58),cornerWidth:29,cornerHeight:29,transform:nil)
    c.addPath(base);c.setFillColor(color(0.78,0.74,1));c.fillPath()
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
