import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
  "LectureRecorder.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int, name: String) throws {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(size)
  let bounds = CGRect(x: 0, y: 0, width: s, height: s)
  NSColor.clear.setFill()
  bounds.fill()
  let bg = NSBezierPath(
    roundedRect: bounds.insetBy(dx: s * 0.04, dy: s * 0.04), xRadius: s * 0.22, yRadius: s * 0.22)
  NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.58, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.17, green: 0.30, blue: 0.78, alpha: 1),
  ])!.draw(in: bg, angle: -45)

  let book = NSBezierPath(
    roundedRect: CGRect(x: s * 0.20, y: s * 0.20, width: s * 0.60, height: s * 0.53),
    xRadius: s * 0.045, yRadius: s * 0.045)
  NSColor.white.withAlphaComponent(0.97).setFill()
  book.fill()
  let spine = NSBezierPath()
  spine.move(to: CGPoint(x: s * 0.50, y: s * 0.22))
  spine.line(to: CGPoint(x: s * 0.50, y: s * 0.70))
  NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
  spine.lineWidth = max(1, s * 0.018)
  spine.stroke()

  let wave = NSBezierPath()
  let heights: [CGFloat] = [0.05, 0.12, 0.21, 0.12, 0.07, 0.18, 0.11, 0.05]
  for (i, h) in heights.enumerated() {
    let x = s * (0.27 + CGFloat(i) * 0.066)
    wave.move(to: CGPoint(x: x, y: s * (0.45 - h)))
    wave.line(to: CGPoint(x: x, y: s * (0.45 + h)))
  }
  NSColor(calibratedRed: 0.12, green: 0.43, blue: 0.88, alpha: 1).setStroke()
  wave.lineWidth = max(2, s * 0.025)
  wave.lineCapStyle = .round
  wave.stroke()

  let lines = NSBezierPath()
  for y in [0.29, 0.22] as [CGFloat] {
    lines.move(to: CGPoint(x: s * 0.30, y: s * y))
    lines.line(to: CGPoint(x: s * 0.44, y: s * y))
    lines.move(to: CGPoint(x: s * 0.56, y: s * y))
    lines.line(to: CGPoint(x: s * 0.70, y: s * y))
  }
  NSColor(calibratedRed: 0.48, green: 0.62, blue: 0.80, alpha: 1).setStroke()
  lines.lineWidth = max(1, s * 0.012)
  lines.stroke()
  NSGraphicsContext.restoreGraphicsState()
  let url = iconset.appendingPathComponent(name)
  try rep.representation(using: .png, properties: [:])!.write(to: url)
}

for (pixels, name) in [
  (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"),
  (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
  (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"),
  (1024, "icon_512x512@2x.png"),
] {
  try render(size: pixels, name: name)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
