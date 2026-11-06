import AppKit

// Renders a 1024x1024 app icon: rounded-rect gradient + drive symbol + sparkles.

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Rounded-rect path with macOS-style corner radius (~22%)
let inset: CGFloat = 32
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = CGPath(roundedRect: rect, cornerWidth: 210, cornerHeight: 210, transform: nil)

// Gradient fill: deep indigo -> teal
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [
    CGColor(red: 0.15, green: 0.30, blue: 0.95, alpha: 1),
    CGColor(red: 0.05, green: 0.75, blue: 0.80, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])

// Subtle top highlight
ctx.addPath(path)
ctx.clip()
let highlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(gray: 1, alpha: 0.25), CGColor(gray: 1, alpha: 0)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(highlight, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: size * 0.55), options: [])
ctx.restoreGState()

image.unlockFocus()

// Draw SF Symbol centered, white
let symbolName = "externaldrive.fill"
if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 460, weight: .regular)
    let configured = symbol.withSymbolConfiguration(config) ?? symbol
    // Tint white by drawing through a tint color
    let tinted = NSImage(size: configured.size, flipped: false) { r in
        configured.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let target = CGRect(x: (size - tinted.size.width) / 2,
                        y: (size - tinted.size.height) / 2 - 10,
                        width: tinted.size.width,
                        height: tinted.size.height)
    image.lockFocus()
    tinted.draw(in: target)
    image.unlockFocus()
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render png")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
