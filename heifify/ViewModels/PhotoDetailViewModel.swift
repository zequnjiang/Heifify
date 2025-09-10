import SwiftUI
import Photos
import ImageIO
import CoreLocation

enum ImageBitDepth: String, CaseIterable, Identifiable { case eightBit, tenBit; var id: String { rawValue } }

@MainActor
final class PhotoDetailViewModel: ObservableObject {
    @Published var previewImage: UIImage?
    @Published var exif: [String: String] = [:]
    @Published var quality: Double = 0.8
    @Published var depth: ImageBitDepth = .eightBit
    @Published var convertedSizeText: String?
    @Published var errorMessage: String?
    @Published var originalSizeText: String = "—"
    @Published var estimatedSizeText: String?
    @Published var isConverting: Bool = false
    @Published var location: CLLocation?

    private var imageData: Data?
    private var estimateTask: Task<Void, Never>?
    private var currentAsset: PHAsset?

    enum SaveMode { case addNew, overwrite }
    @Published var saveMode: SaveMode = .addNew

    // MARK: - Formatted EXIF helpers
    var cameraDescription: String? {
        let make = exif["TIFF_Make"]
        let model = exif["TIFF_Model"]
        if let make, let model { return "\(make) \(model)" }
        return make ?? model
    }

    var lensDescription: String? { exif["LensModel"] }

    var focalLengthDescription: String? {
        if let str = exif["FocalLenIn35mmFilm"], let num = Double(str) {
            return String(format: "%.0f mm", num)
        }
        if let str = exif["FocalLength"], let num = Double(str) {
            return String(format: "%.0f mm", num)
        }
        return nil
    }

    var apertureDescription: String? {
        if let str = exif["FNumber"], let num = Double(str) {
            return String(format: "f/%.1f", num)
        }
        return nil
    }

    var shutterDescription: String? {
        if let str = exif["ExposureTime"], let num = Double(str) {
            if num >= 1 { return String(format: "%.0f s", num) }
            else { return "1/\(Int(round(1/num))) s" }
        }
        return nil
    }

    var isoDescription: String? {
        if let str = exif["ISOSpeedRatings"], let num = Double(str) {
            return "ISO \(Int(num))"
        }
        return nil
    }

    func load(asset: PHAsset) async {
        self.currentAsset = asset
        self.location = asset.location
        let opts = PHImageRequestOptions()
        opts.isSynchronous = false
        opts.isNetworkAccessAllowed = true
        opts.version = .original
        opts.deliveryMode = .highQualityFormat
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, _ in
                self.imageData = data
                if let data, let img = UIImage(data: data) { self.previewImage = img }
                if let data {
                    self.exif = Self.extractEXIF(from: data)
                    self.originalSizeText = Int64(data.count).humanReadableSize
                    self.updateEstimate()
                }
                cont.resume()
            }
        }
    }

    func convertAndSaveHEIF(completion: @escaping (Bool) -> Void) {
        guard let data = imageData else { errorMessage = "未加载图片数据"; completion(false); return }
        isConverting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let heic = try HEIFConverter.convertToHEIC(data: data, quality: self.quality, depth: self.depth)
                DispatchQueue.main.async { self.convertedSizeText = Int64(heic.count).humanReadableSize }

                switch self.saveMode {
                case .addNew:
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("heic")
                    try heic.write(to: url)
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }) { success, error in
                        DispatchQueue.main.async {
                            self.isConverting = false
                            if let error { self.errorMessage = "保存失败：\(error.localizedDescription)"; completion(false) }
                            else { self.errorMessage = nil; completion(success) }
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                case .overwrite:
                    guard let asset = self.currentAsset else { DispatchQueue.main.async { self.isConverting = false; completion(false) }; return }
                    let requestOptions = PHContentEditingInputRequestOptions(); requestOptions.isNetworkAccessAllowed = true
                    asset.requestContentEditingInput(with: requestOptions) { input, _ in
                        guard let input else { DispatchQueue.main.async { self.isConverting = false; completion(false) }; return }
                        let output = PHContentEditingOutput(contentEditingInput: input)
                        let renderedURL = output.renderedContentURL
                        do { try heic.write(to: renderedURL, options: .atomic) }
                        catch { DispatchQueue.main.async { self.isConverting = false; self.errorMessage = error.localizedDescription; completion(false) }; return }
                        let adjData = PHAdjustmentData(formatIdentifier: "com.zanejiang.heifify", formatVersion: "1.0", data: Data("heifify".utf8))
                        output.adjustmentData = adjData
                        PHPhotoLibrary.shared().performChanges({
                            let req = PHAssetChangeRequest(for: asset)
                            req.contentEditingOutput = output
                        }) { success, error in
                            DispatchQueue.main.async {
                                self.isConverting = false
                                if let error { self.errorMessage = "保存失败：\(error.localizedDescription)"; completion(false) }
                                else { self.errorMessage = nil; completion(success) }
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.isConverting = false; self.errorMessage = "转换失败：\(error.localizedDescription)"; completion(false) }
            }
        }
    }

    func updateEstimate() {
        estimateTask?.cancel()
        guard let data = imageData else { estimatedSizeText = nil; return }
        let q = quality
        let d = depth
        estimateTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let heic = try HEIFConverter.convertToHEIC(data: data, quality: q, depth: d)
                let sizeText = Int64(heic.count).humanReadableSize
                await MainActor.run { self.estimatedSizeText = sizeText }
            } catch {
                await MainActor.run { self.estimatedSizeText = nil }
            }
        }
    }

    static func extractEXIF(from data: Data) -> [String: String] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var dict: [String: String] = [:]
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for (k,v) in exif { dict[String(k)] = String(describing: v) }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for (k,v) in tiff { dict["TIFF_\(k)"] = String(describing: v) }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            for (k,v) in gps { dict["GPS_\(k)"] = String(describing: v) }
        }
        return dict
    }
}
