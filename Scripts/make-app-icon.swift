#!/usr/bin/env swift
import AppKit

// Makes a macOS iconset from a square 1024 px master by applying a
// superellipse (squircle) mask, so the icon has the transparent corners macOS
// expects. Usage: swift make-app-icon.swift <master.png> <output.iconset>

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <master.png> <output.iconset>\n".utf8))
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let masterSize = 1024

guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("cannot read \(sourceURL.path)\n".utf8))
    exit(1)
}

/// A superellipse with exponent 5, close to the macOS app icon silhouette.
func squircle(in rect: NSRect, exponent: CGFloat = 5.0) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(angle)
        let s = sin(angle)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / exponent), s)
        if i == 0 {
            path.move(to: NSPoint(x: x, y: y))
        } else {
            path.line(to: NSPoint(x: x, y: y))
        }
    }
    path.close()
    return path
}

func makeBitmap(size: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep
}

/// The masked 1024 px master.
guard let master = makeBitmap(size: masterSize),
      let masterContext = NSGraphicsContext(bitmapImageRep: master)
else {
    FileHandle.standardError.write(Data("cannot create master bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = masterContext
masterContext.shouldAntialias = true
masterContext.imageInterpolation = .high
let masterRect = NSRect(x: 0, y: 0, width: masterSize, height: masterSize)
NSColor.clear.setFill()
masterRect.fill()
squircle(in: masterRect).addClip()
source.draw(in: masterRect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

let masterImage = NSImage(size: NSSize(width: masterSize, height: masterSize))
masterImage.addRepresentation(master)

// Find the dark mark so 16/32 px can be cropped and enlarged instead of
// shrinking the whole composition. Tiny sizes only need the silhouette.
var minX = masterSize
var minY = masterSize
var maxX = 0
var maxY = 0
for y in stride(from: 0, to: masterSize, by: 2) {
    for x in stride(from: 0, to: masterSize, by: 2) {
        guard let colour = master.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              colour.alphaComponent > 0.9
        else { continue }
        let luminance = 0.2126 * colour.redComponent
            + 0.7152 * colour.greenComponent
            + 0.0722 * colour.blueComponent
        guard luminance < 0.18 else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}
let hasMark = maxX > minX && maxY > minY
// NSBitmapImageRep uses a top-left origin; NSImage.draw(from:) expects the
// image's bottom-left coordinate space.
let markInImageSpace = hasMark
    ? NSRect(
        x: CGFloat(minX),
        y: CGFloat(masterSize - maxY),
        width: CGFloat(maxX - minX),
        height: CGFloat(maxY - minY)
    )
    : .zero
let enlargedCrop = markInImageSpace.insetBy(
    dx: -markInImageSpace.width * 0.08,
    dy: -markInImageSpace.height * 0.10
)

let cream = NSColor(srgbRed: 0.92, green: 0.88, blue: 0.79, alpha: 1)

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

func write(size: Int, name: String, simplified: Bool) throws {
    guard let rep = makeBitmap(size: size),
          let context = NSGraphicsContext(bitmapImageRep: rep)
    else { throw NSError(domain: "make-app-icon", code: 1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    context.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    if simplified, hasMark {
        cream.setFill()
        squircle(in: rect).fill()

        // Scale the cropped mark to fit the canvas while leaving a margin. The
        // crop carries the cream field with it, so it blends into the
        // background. The mark is wide, so width is usually the limiting edge.
        let maxWidth = CGFloat(size) * 0.86
        let maxHeight = CGFloat(size) * 0.68
        let scale = min(maxWidth / enlargedCrop.width, maxHeight / enlargedCrop.height)
        let targetWidth = enlargedCrop.width * scale
        let targetHeight = enlargedCrop.height * scale
        let target = NSRect(
            x: (CGFloat(size) - targetWidth) / 2,
            y: (CGFloat(size) - targetHeight) / 2,
            width: targetWidth,
            height: targetHeight
        )
        masterImage.draw(in: target, from: enlargedCrop, operation: .sourceOver, fraction: 1)
    } else {
        masterImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-app-icon", code: 2)
    }
    try data.write(to: outputURL.appendingPathComponent(name))
}

let entries: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in entries {
    try write(size: size, name: name, simplified: size <= 32)
}

print(outputURL.path)
