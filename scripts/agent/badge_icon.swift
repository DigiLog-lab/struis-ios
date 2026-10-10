// Draws a prototype label onto the 1024 pt app icon so variants are
// distinguishable on the home screen. Usage: badge_icon.swift <png> <label>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: badge_icon.swift <png> <label>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let label = arguments[2]
guard let source = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
    exit(1)
}
let side = 1024
let band = CGFloat(side) * 0.27
// App icons must be opaque, so draw into a context without alpha.
guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
context.interpolationQuality = .high
context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
context.setFillColor(CGColor(srgbRed: 0.84, green: 0.11, blue: 0.24, alpha: 0.94))
context.fill(CGRect(x: 0, y: 0, width: CGFloat(side), height: band))
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
var fontSize = band * 0.62
var text = NSAttributedString()
repeat {
    text = NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor.white,
    ])
    fontSize -= 4
} while text.size().width > CGFloat(side) * 0.9 && fontSize > 24
let size = text.size()
text.draw(at: NSPoint(x: (CGFloat(side) - size.width) / 2, y: (band - size.height) / 2))
NSGraphicsContext.current = nil
guard let output = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: url)
