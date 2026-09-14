// One-off icon generator: swift Support/make-icon.swift <out.png>
// Draws the Peel icon — a warm sticky with a folded corner and three text strokes.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let canvas: CGFloat = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

let inset: CGFloat = 116
let rect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let radius: CGFloat = 92
let fold: CGFloat = 210

// soft drop shadow
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.shadowBlurRadius = 40
NSGraphicsContext.current?.saveGraphicsState()
shadow.set()

// paper: rounded except the bottom-right corner, which is cut for the fold
let paper = NSBezierPath()
paper.move(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
paper.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
paper.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
paper.line(to: NSPoint(x: rect.maxX, y: rect.minY + fold))
paper.line(to: NSPoint(x: rect.maxX - fold, y: rect.minY))
paper.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
paper.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                radius: radius, startAngle: 270, endAngle: 180, clockwise: true)
paper.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
paper.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
paper.close()

NSGradient(starting: hex(0xFAF2D6), ending: hex(0xEFE0AC))!.draw(in: paper, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

// folded-back flap
let flap = NSBezierPath()
flap.move(to: NSPoint(x: rect.maxX - fold, y: rect.minY))
flap.line(to: NSPoint(x: rect.maxX, y: rect.minY + fold))
flap.line(to: NSPoint(x: rect.maxX - fold, y: rect.minY + fold))
flap.close()
hex(0xD9C382).setFill()
flap.fill()

// three text strokes, title in amber
let strokes: [(CGFloat, CGFloat, NSColor)] = [
    (0.46, 0, hex(0xB07D3A)),
    (0.60, 1, hex(0x6B5A33, 0.55)),
    (0.36, 2, hex(0x6B5A33, 0.55)),
]
for (widthFactor, row, color) in strokes {
    let strokeHeight: CGFloat = 52
    let y = rect.maxY - 190 - row * 132
    let stroke = NSBezierPath(roundedRect: NSRect(x: rect.minX + 108, y: y,
                                                  width: rect.width * widthFactor, height: strokeHeight),
                              xRadius: strokeHeight / 2, yRadius: strokeHeight / 2)
    color.setFill()
    stroke.fill()
}

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
