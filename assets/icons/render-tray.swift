import AppKit
let output = CommandLine.arguments[1]
for state in ["stored", "empty", "unknown"] {
for scale in [1, 2] {
  let size = 18 * scale
  let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let context = NSGraphicsContext(bitmapImageRep: image)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  context.cgContext.translateBy(x: 0, y: 18)
  context.cgContext.scaleBy(x: 1, y: -1)
  context.cgContext.setShouldAntialias(true)
  NSColor.black.setStroke()
  let p = NSBezierPath()
  p.lineWidth = 1.35
  p.lineCapStyle = .round
  p.lineJoinStyle = .round
  p.move(to: NSPoint(x: 7, y: 1.75)); p.line(to: NSPoint(x: 11, y: 1.75)); p.line(to: NSPoint(x: 11, y: 3.75)); p.line(to: NSPoint(x: 7, y: 3.75)); p.close()
  p.move(to: NSPoint(x: 6.5, y: 4.25)); p.line(to: NSPoint(x: 11.5, y: 4.25))
  p.move(to: NSPoint(x: 7, y: 4.5)); p.line(to: NSPoint(x: 7, y: 6.5)); p.line(to: NSPoint(x: 4.75, y: 9)); p.line(to: NSPoint(x: 4.75, y: 14.25)); p.curve(to: NSPoint(x: 6.75, y: 16.25), controlPoint1: NSPoint(x: 4.75, y: 15.35), controlPoint2: NSPoint(x: 5.65, y: 16.25)); p.line(to: NSPoint(x: 11.25, y: 16.25)); p.curve(to: NSPoint(x: 13.25, y: 14.25), controlPoint1: NSPoint(x: 12.35, y: 16.25), controlPoint2: NSPoint(x: 13.25, y: 15.35)); p.line(to: NSPoint(x: 13.25, y: 9)); p.line(to: NSPoint(x: 11, y: 6.5)); p.line(to: NSPoint(x: 11, y: 4.5))
  if state == "stored" {
    p.move(to: NSPoint(x: 8.5, y: 13.75))
    p.curve(to: NSPoint(x: 9.5, y: 10.1), controlPoint1: NSPoint(x: 10.5, y: 12.25), controlPoint2: NSPoint(x: 11.1, y: 10.5))
    p.curve(to: NSPoint(x: 8.4, y: 11.4), controlPoint1: NSPoint(x: 8.3, y: 9.8), controlPoint2: NSPoint(x: 7.75, y: 10.85))
  } else if state == "unknown" {
    p.move(to: NSPoint(x: 7.5, y: 11.75))
    p.line(to: NSPoint(x: 10.5, y: 11.75))
  }
  p.stroke()
  NSGraphicsContext.restoreGraphicsState()
  let basename = state == "stored" ? "trayTemplate" : state == "empty" ? "trayEmptyTemplate" : "trayUnknownTemplate"
  let filename = scale == 1 ? "\(basename).png" : "\(basename)@2x.png"
  try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(filename))
}
}
