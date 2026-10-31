import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = root.appendingPathComponent("UIUIIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        NSColor(calibratedRed:0.11, green:0.13, blue:0.12, alpha:1).setFill()
        NSBezierPath(roundedRect: NSRect(x:32,y:32,width:960,height:960), xRadius:220,yRadius:220).fill()
        NSColor(calibratedRed:0.78,green:0.94,blue:0.44,alpha:1).setStroke()
        for x in [CGFloat(300),CGFloat(650)] {
            let eye=NSBezierPath(); eye.lineWidth=65;eye.lineCapStyle = .round
            eye.move(to:NSPoint(x:x-75,y:600));eye.line(to:NSPoint(x:x-75,y:460));eye.curve(to:NSPoint(x:x+75,y:460),controlPoint1:NSPoint(x:x-75,y:340),controlPoint2:NSPoint(x:x+75,y:340));eye.line(to:NSPoint(x:x+75,y:600));eye.stroke()
        }
        NSColor(calibratedWhite:0.95,alpha:0.92).setFill()
        for x in [CGFloat(320),CGFloat(670)] { NSBezierPath(ovalIn:NSRect(x:x-19,y:480,width:38,height:54)).fill() }
        NSGraphicsContext.restoreGraphicsState()
        guard let png=bitmap.representation(using:.png,properties:[:]) else { fatalError("Icon render failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to:directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
