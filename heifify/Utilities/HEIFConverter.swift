import AVFoundation
import ImageIO
import UIKit

enum HEIFError: Error { case cgImageCreateFailed, destinationCreateFailed }

struct HEIFConverter {
    static func convertToHEIC(data: Data, quality: Double, depth: ImageBitDepth) throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw HEIFError.cgImageCreateFailed }

        // Create destination buffer
        let destData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(destData as CFMutableData, AVFileType.heic as CFString, 1, nil) else { throw HEIFError.destinationCreateFailed }

        // Start from original metadata; this preserves EXIF/GPS/TIFF etc.
        var properties: [CFString: Any] = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        properties[kCGImagePropertyDepth] = (depth == .tenBit ? 10 : 8)

        // Add the image from source so metadata is retained
        CGImageDestinationAddImageFromSource(dest, src, 0, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return destData as Data
    }
}
