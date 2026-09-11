#!/usr/bin/env swift
// Reproduce the app icon with the exact bundled font used by BYOTWordmark.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fontURL = root.appendingPathComponent("Sources/Resources/Fonts/OpenRunde-Bold.otf")
let fontData = try Data(contentsOf: fontURL)
let graphicsFont = CGFont(CGDataProvider(data: fontData as CFData)!)!
let catalog = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog.appendingPathComponent("Contents.json"))) as! [String: Any]
var written = Set<String>()
for item in json["images"] as! [[String: String]] {
    guard let filename = item["filename"], written.insert(filename).inserted else { continue }
    let points = Double(item["size"]!.split(separator: "x")[0])!
    let scale = Double(item["scale"]!.dropLast())!
    let pixels = Int(points * scale)
    let size = CGFloat(pixels)
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let font = CTFontCreateWithGraphicsFont(graphicsFont, size * 0.26, nil, nil)
    let label = NSAttributedString(string: "byot", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
    ])
    let line = CTLineCreateWithAttributedString(label)
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    context.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX,
                                   y: (size - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, context)
    let output = CGImageDestinationCreateWithURL(catalog.appendingPathComponent(filename) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
}
print("Generated \(written.count) lowercase Open Runde app icons.")
