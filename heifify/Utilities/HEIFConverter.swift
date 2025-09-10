import AVFoundation
import ImageIO
import UIKit

enum HEIFError: Error { case cgImageCreateFailed, destinationCreateFailed, finalizeFailed }

struct HEIFConverter {
    static func convertToHEIC(data: Data, quality: Double, depth: ImageBitDepth) throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw HEIFError.cgImageCreateFailed }

        // Create destination buffer
        let destData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(destData as CFMutableData, AVFileType.heic as CFString, 1, nil) else { throw HEIFError.destinationCreateFailed }

        // Start from original metadata; this preserves EXIF/GPS/TIFF etc.
        var properties: [CFString: Any] = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        // Add the image from source so metadata is retained
        CGImageDestinationAddImageFromSource(dest, src, 0, properties as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw HEIFError.finalizeFailed }
        return destData as Data
    }

    // Finder/Preview-like conversion: HEIF (HEVC), keep pixels, keep all metadata, inherit profile/bit depth, quality ~0.8
    static func convertLikeFinder(inputURL: URL, outputURL: URL, quality: Double = 0.8) throws -> Int64 {
        guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else { throw HEIFError.cgImageCreateFailed }
        guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, AVFileType.heic as CFString, 1, nil) else { throw HEIFError.destinationCreateFailed }

        var props: [CFString: Any] = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw HEIFError.finalizeFailed }

        let values = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        if let size = values[.size] as? NSNumber { return size.int64Value }
        return (try? Data(contentsOf: outputURL)).map { Int64($0.count) } ?? 0
    }
}
