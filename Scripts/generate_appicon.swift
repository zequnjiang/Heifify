#!/usr/bin/env swift
import Foundation
import AppKit

struct IconSpec: Codable {
    let size: String
    let idiom: String
    let filename: String
    let scale: String
    let expectedPixels: Int
}

let specs: [IconSpec] = [
    .init(size: "20x20", idiom: "iphone", filename: "AppIcon-20@2x.png", scale: "2x", expectedPixels: 40),
    .init(size: "20x20", idiom: "iphone", filename: "AppIcon-20@3x.png", scale: "3x", expectedPixels: 60),
    .init(size: "29x29", idiom: "iphone", filename: "AppIcon-29@2x.png", scale: "2x", expectedPixels: 58),
    .init(size: "29x29", idiom: "iphone", filename: "AppIcon-29@3x.png", scale: "3x", expectedPixels: 87),
    .init(size: "40x40", idiom: "iphone", filename: "AppIcon-40@2x.png", scale: "2x", expectedPixels: 80),
    .init(size: "40x40", idiom: "iphone", filename: "AppIcon-40@3x.png", scale: "3x", expectedPixels: 120),
    .init(size: "60x60", idiom: "iphone", filename: "AppIcon-60@2x.png", scale: "2x", expectedPixels: 120),
    .init(size: "60x60", idiom: "iphone", filename: "AppIcon-60@3x.png", scale: "3x", expectedPixels: 180),
    .init(size: "76x76", idiom: "ipad", filename: "AppIcon-76.png", scale: "1x", expectedPixels: 76),
    .init(size: "76x76", idiom: "ipad", filename: "AppIcon-76@2x.png", scale: "2x", expectedPixels: 152),
    .init(size: "83.5x83.5", idiom: "ipad", filename: "AppIcon-83.5@2x.png", scale: "2x", expectedPixels: 167),
    .init(size: "1024x1024", idiom: "ios-marketing", filename: "AppIcon-1024.png", scale: "1x", expectedPixels: 1024)
]

func die(_ msg: String) -> Never {
    let s = "Error: \(msg)\n"
    FileHandle.standardError.write(s.data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count >= 2 else { die("Usage: generate_appicon.swift <1024_png_path> [output_appiconset_dir]\nDefault output: heifify/Assets.xcassets/AppIcon.appiconset") }
let inputPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "heifify/Assets.xcassets/AppIcon.appiconset"

let inputURL = URL(fileURLWithPath: inputPath)
guard let srcImage = NSImage(contentsOf: inputURL) else { die("Cannot open input image at \(inputPath)") }

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true, attributes: nil)

func resize(_ image: NSImage, to pixels: Int) -> Data? {
    let size = NSSize(width: pixels, height: pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

var imagesArray: [[String:String]] = []
for s in specs {
    let outPath = (outDir as NSString).appendingPathComponent(s.filename)
    if let data = resize(srcImage, to: s.expectedPixels) {
        try data.write(to: URL(fileURLWithPath: outPath))
        imagesArray.append(["size": s.size, "idiom": s.idiom, "filename": s.filename, "scale": s.scale])
        print("Generated \(s.filename)")
    } else {
        die("Failed to generate \(s.filename)")
    }
}

let contents: [String:Any] = [
    "images": imagesArray,
    "info": ["version": 1, "author": "xcode"]
]

let jsonURL = URL(fileURLWithPath: (outDir as NSString).appendingPathComponent("Contents.json"))
let jsonData = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try jsonData.write(to: jsonURL)
print("Wrote Contents.json")
