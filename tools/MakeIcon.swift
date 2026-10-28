// Generates the Mac Display Fixer app icon (a display with a green checkmark).
// Usage: swift tools/MakeIcon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import Foundation
import AppKit

let outputDirectory = "build/AppIcon.iconset"

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(size: CGFloat) -> CGImage? {
    let width = Int(size.rounded())
    let height = width
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = size
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    // MARK: Background (rounded square with a blue gradient)

    let inset = s * 0.10
    let backgroundRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let backgroundRadius = backgroundRect.width * 0.225

    context.saveGState()
    context.addPath(roundedPath(backgroundRect, radius: backgroundRadius))
    context.clip()

    let backgroundColors = [
        CGColor(red: 0.31, green: 0.62, blue: 0.99, alpha: 1),
        CGColor(red: 0.10, green: 0.36, blue: 0.90, alpha: 1)
    ]
    let backgroundGradient = CGGradient(colorsSpace: nil, colors: backgroundColors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        backgroundGradient,
        start: CGPoint(x: 0, y: backgroundRect.maxY),
        end: CGPoint(x: 0, y: backgroundRect.minY),
        options: []
    )

    // MARK: Monitor bezel

    let bezelWidth = s * 0.58
    let bezelHeight = s * 0.43
    let bezelRect = CGRect(x: (s - bezelWidth) / 2, y: s * 0.40, width: bezelWidth, height: bezelHeight)
    let bezelRadius = bezelHeight * 0.10

    let bezelColors = [
        CGColor(red: 0.24, green: 0.26, blue: 0.30, alpha: 1),
        CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1)
    ]
    let bezelGradient = CGGradient(colorsSpace: nil, colors: bezelColors as CFArray, locations: [0, 1])!
    context.saveGState()
    context.addPath(roundedPath(bezelRect, radius: bezelRadius))
    context.clip()
    context.drawLinearGradient(bezelGradient, start: CGPoint(x: 0, y: bezelRect.maxY), end: CGPoint(x: 0, y: bezelRect.minY), options: [])
    context.restoreGState()

    // MARK: Screen

    let screenRect = bezelRect.insetBy(dx: bezelWidth * 0.045, dy: bezelHeight * 0.075)
    let screenRadius = bezelRadius * 0.65
    let screenColors = [
        CGColor(red: 0.10, green: 0.19, blue: 0.33, alpha: 1),
        CGColor(red: 0.17, green: 0.31, blue: 0.51, alpha: 1)
    ]
    let screenGradient = CGGradient(colorsSpace: nil, colors: screenColors as CFArray, locations: [0, 1])!
    context.saveGState()
    context.addPath(roundedPath(screenRect, radius: screenRadius))
    context.clip()
    context.drawLinearGradient(screenGradient, start: CGPoint(x: 0, y: screenRect.maxY), end: CGPoint(x: 0, y: screenRect.minY), options: [])

    // MARK: Checkmark

    let point = { (fx: CGFloat, fy: CGFloat) -> CGPoint in
        CGPoint(x: screenRect.minX + screenRect.width * fx,
                y: screenRect.minY + screenRect.height * fy)
    }
    let checkPath = CGMutablePath()
    checkPath.move(to: point(0.20, 0.50))
    checkPath.addLine(to: point(0.43, 0.24))
    checkPath.addLine(to: point(0.82, 0.78))

    // Soft dark-green underlay for a hint of depth
    context.saveGState()
    context.addPath(checkPath)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(screenRect.height * 0.185)
    context.setStrokeColor(CGColor(red: 0.08, green: 0.45, blue: 0.17, alpha: 1))
    context.translateBy(x: 0, y: -screenRect.height * 0.03)
    context.strokePath()
    context.restoreGState()

    // Main checkmark
    context.saveGState()
    context.addPath(checkPath)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(screenRect.height * 0.17)
    context.setStrokeColor(CGColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1))
    context.strokePath()
    context.restoreGState()

    context.restoreGState() // background clip

    // MARK: Stand (neck + base)

    context.setFillColor(CGColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1))
    let neckRect = CGRect(x: s / 2 - bezelWidth * 0.07, y: s * 0.345, width: bezelWidth * 0.14, height: s * 0.06)
    context.addPath(roundedPath(neckRect, radius: neckRect.width * 0.35))
    context.fillPath()

    let baseWidth = bezelWidth * 0.46
    let baseRect = CGRect(x: (s - baseWidth) / 2, y: s * 0.312, width: baseWidth, height: s * 0.035)
    context.addPath(roundedPath(baseRect, radius: baseRect.height / 2))
    context.setFillColor(CGColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1))
    context.fillPath()

    return context.makeImage()
}

// MARK: - Write the iconset

try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in entries {
    guard let image = render(size: CGFloat(entry.pixels)),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("не удалось сгенерировать \(entry.name)")
    }
    try data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(entry.name)"))
    print("\(entry.name) (\(entry.pixels)px)")
}
print("Готово: \(outputDirectory)")
