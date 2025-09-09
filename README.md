Heifify (iOS 18+)

AppID: `com.zanejiang.heifify`
Version: `1.0.0`
Language: Swift (SwiftUI)
Minimum iOS: 18.0

Features
- Photo grid (3 columns) from Recents album
- Each photo shows its format (HEIF/JPG/PNG/RAW) and file size
- Detail view shows preview and EXIF metadata
- Convert to HEIF with adjustable quality and 8/10-bit hint, save to Photos

Permissions
- NSPhotoLibraryUsageDescription: Heifify needs access to browse and convert photos
- NSPhotoLibraryAddUsageDescription: Heifify saves converted HEIF images to your library

Notes
- File sizes are loaded lazily and cached to keep scrolling smooth.
- 10-bit depth is a best-effort hint; actual bit depth depends on device/codecs and may fall back to 8-bit.

Run
- Open `heifify.xcodeproj` in Xcode 16+, select an iOS 18+ device/simulator, build and run.

