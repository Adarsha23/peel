import AppKit

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }

    static func dyn(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

enum Theme {
    struct Palette {
        let name: String
        let title: String
        let background: NSColor
        let accent: NSColor
    }

    /// Muted, paper-like palettes; each dark variant keeps the hue family of its
    /// light counterpart so auto dark-mode switches feel intentional.
    static let palettes: [Palette] = [
        Palette(name: "yellow", title: "Warm Yellow",
                background: .dyn(light: 0xF7F0DC, dark: 0x2C2616), accent: .dyn(light: 0xB07D3A, dark: 0xC89D5A)),
        Palette(name: "cream", title: "Cream",
                background: .dyn(light: 0xF5F0E8, dark: 0x252018), accent: .dyn(light: 0x8C7B5E, dark: 0x9C8B6E)),
        Palette(name: "blue", title: "Soft Blue",
                background: .dyn(light: 0xE8EEF5, dark: 0x1A2130), accent: .dyn(light: 0x4A7FA5, dark: 0x6A9FC5)),
        Palette(name: "green", title: "Soft Green",
                background: .dyn(light: 0xE8F0E8, dark: 0x1A2420), accent: .dyn(light: 0x4A8060, dark: 0x6AA080)),
        Palette(name: "lavender", title: "Lavender",
                background: .dyn(light: 0xEDE8F5, dark: 0x1E1A28), accent: .dyn(light: 0x7B6BA8, dark: 0x9B8BC8)),
        Palette(name: "pink", title: "Pink",
                background: .dyn(light: 0xF5E8EC, dark: 0x281820), accent: .dyn(light: 0xA05870, dark: 0xC07890)),
        Palette(name: "graphite", title: "Graphite",
                background: .dyn(light: 0xEBEBEB, dark: 0x1C1C1E), accent: .dyn(light: 0x636366, dark: 0x8E8E93)),
    ]

    static func palette(_ name: String) -> Palette {
        palettes.first { $0.name == name } ?? palettes[0]
    }

    static func rounded(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }

    static let bodyFont = rounded(13)
    static let boldFont = rounded(13, weight: .semibold)
    static let headingFont = rounded(15, weight: .semibold)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static let cornerRadius: CGFloat = 12

    static func swatch(_ palette: Palette, diameter: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            palette.accent.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
