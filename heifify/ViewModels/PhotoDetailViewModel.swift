import SwiftUI
import Photos
import ImageIO
import CoreLocation

enum ImageBitDepth: String, CaseIterable, Identifiable { case eightBit, tenBit; var id: String { rawValue } }

@MainActor
final class PhotoDetailViewModel: ObservableObject {
    @Published var previewImage: UIImage?
    // Raw dictionaries
    @Published var exif: [String: String] = [:]
    @Published var tiff: [String: String] = [:]
    @Published var general: [String: String] = [:]
    @Published var quality: Double = 0.8
    @Published var depth: ImageBitDepth = .eightBit
    @Published var convertedSizeText: String?
    @Published var errorMessage: String?
    @Published var originalSizeText: String = "—"
    @Published var estimatedSizeText: String?
    @Published var isConverting: Bool = false
    @Published var location: CLLocation?
    @Published var toastMessage: String?

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
                    let meta = Self.extractMetadata(from: data)
                    self.exif = meta.exif
                    self.tiff = meta.tiff
                    self.general = meta.general
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

    // Finder/Preview-like: quality 0.8, keep metadata/profile/bit depth, keep original pixels
    func convertLikeFinderAndSave(completion: @escaping (Bool) -> Void) {
        // Ensure authorization
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != .authorized && status != .limited {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] s in
                DispatchQueue.main.async {
                    if s != .authorized && s != .limited {
                        self?.toastMessage = "没有照片写入权限"
                        completion(false)
                    } else {
                        self?.convertLikeFinderAndSave(completion: completion)
                    }
                }
            }
            return
        }

        guard let asset = currentAsset else { self.toastMessage = "无效的照片"; completion(false); return }
        guard asset.canPerform(.content) else { self.toastMessage = "此照片不可编辑"; completion(false); return }

        isConverting = true
        let requestOptions = PHContentEditingInputRequestOptions(); requestOptions.isNetworkAccessAllowed = true
        asset.requestContentEditingInput(with: requestOptions) { input, _ in
            guard let input, let inURL = input.fullSizeImageURL else {
                DispatchQueue.main.async { self.isConverting = false; self.errorMessage = "无法获取原图文件"; self.toastMessage = self.errorMessage; completion(false) }
                return
            }
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("heic")
            do {
                let bytes = try HEIFConverter.convertLikeFinder(inputURL: inURL, outputURL: tmpURL, quality: 0.8)
                DispatchQueue.main.async { self.convertedSizeText = Int64(bytes).humanReadableSize }
            } catch {
                DispatchQueue.main.async { self.isConverting = false; self.errorMessage = "转换失败：\(error.localizedDescription)"; self.toastMessage = self.errorMessage; completion(false) }
                return
            }

            switch self.saveMode {
            case .addNew:
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: tmpURL)
                }) { success, err in
                    DispatchQueue.main.async {
                        self.isConverting = false
                        if let err { self.errorMessage = err.localizedDescription; self.toastMessage = self.errorMessage; completion(false) }
                        else { self.errorMessage = nil; completion(success) }
                        try? FileManager.default.removeItem(at: tmpURL)
                    }
                }
            case .overwrite:
                let output = PHContentEditingOutput(contentEditingInput: input)
                do {
                    try FileManager.default.removeItem(at: output.renderedContentURL)
                } catch { }
                do { try FileManager.default.copyItem(at: tmpURL, to: output.renderedContentURL) } catch {
                    DispatchQueue.main.async { self.isConverting = false; self.errorMessage = error.localizedDescription; self.toastMessage = self.errorMessage; completion(false) }
                    return
                }
                output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.zanejiang.heifify", formatVersion: "1.0", data: Data("heifify".utf8))
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetChangeRequest(for: asset)
                    req.contentEditingOutput = output
                    // Keep timeline consistent: ensure creationDate unchanged
                    if let c = asset.creationDate { req.creationDate = c }
                }) { success, err in
                    DispatchQueue.main.async {
                        self.isConverting = false
                        if let err { self.errorMessage = err.localizedDescription; self.toastMessage = self.errorMessage; completion(false) }
                        else { self.errorMessage = nil; completion(success) }
                        try? FileManager.default.removeItem(at: tmpURL)
                    }
                }
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

    struct Metadata { let general: [String:String]; let exif: [String:String]; let tiff: [String:String] }

    static func extractMetadata(from data: Data) -> Metadata {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return Metadata(general: [:], exif: [:], tiff: [:])
        }
        var general: [String:String] = [:]
        var exif: [String:String] = [:]
        var tiff: [String:String] = [:]

        // General/common
        let map: [(CFString,String)] = [
            (kCGImagePropertyColorModel, "颜色模式"),
            (kCGImagePropertyDepth, "深度"),
            (kCGImagePropertyDPIHeight, "DPI高度"),
            (kCGImagePropertyDPIWidth, "DPI宽度"),
            (kCGImagePropertyOrientation, "方向"),
            (kCGImagePropertyPixelHeight, "像素高度"),
            (kCGImagePropertyPixelWidth, "像素宽度"),
            (kCGImagePropertyProfileName, "描述文件名称")
        ]
        for (key,label) in map {
            if let v = props[key] { general[label] = String(describing: v) }
        }
        // Try to read optional headroom if present under Apple dictionary
        if let apple = props[kCGImagePropertyMakerAppleDictionary] as? [CFString:Any], let headroom = apple["Headroom" as CFString] {
            general["Headroom"] = String(describing: headroom)
        }

        // EXIF
        if let exifDict = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for (k,v) in exifDict { exif[String(k)] = String(describing: v) }
        }
        // TIFF
        if let tiffDict = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for (k,v) in tiffDict { tiff[String(k)] = String(describing: v) }
        }
        return Metadata(general: general, exif: exif, tiff: tiff)
    }

    // Chinese labels for EXIF/TIFF common keys
    static let exifKeyMap: [String:String] = [
        "FNumber":"光圈值",
        "BrightnessValue":"亮度值",
        "ColorSpace":"色彩空间",
        "CompositeImage":"CompositeImage",
        "DateTimeDigitized":"数字化日期时间",
        "DateTimeOriginal":"原始日期时间",
        "ExifVersion":"Exif 版本",
        "ExposureBiasValue":"曝光偏移值",
        "ExposureMode":"曝光模式",
        "ExposureProgram":"曝光程序",
        "ExposureTime":"曝光时间",
        "Flash":"闪光灯",
        "ApertureValue":"光圈系数",
        "FocalLength":"焦距",
        "FocalLenIn35mmFilm":"按35毫米胶卷计算的焦距",
        "ISOSpeedRatings":"照相感光度(ISO)",
        "PhotographicSensitivity":"照相感光度(ISO)",
        "LensMake":"镜头品牌",
        "LensModel":"镜头型号",
        "LensSpecification":"镜头规格",
        "MeteringMode":"测光模式",
        "OffsetTime":"修改日期的时区",
        "OffsetTimeDigitized":"数字化日期的时区",
        "OffsetTimeOriginal":"原始日期的时区",
        "PixelXDimension":"横向像素数",
        "PixelYDimension":"纵向像素数",
        "SceneType":"场景类型",
        "SensingMethod":"感知方法",
        "ShutterSpeedValue":"快门速度值",
        "SubjectArea":"主题区域",
        "SubsecTimeDigitized":"数字化次秒级时间",
        "SubsecTimeOriginal":"原始次秒级时间",
        "WhiteBalance":"白平衡"
    ]

    static let tiffKeyMap: [String:String] = [
        "DateTime":"日期时间",
        "HostComputer":"主机",
        "Make":"品牌",
        "Model":"型号",
        "Orientation":"方向",
        "ResolutionUnit":"分辨率单位",
        "Software":"软件",
        "TileLength":"拼贴长度",
        "TileWidth":"拼贴宽度",
        "XResolution":"X分辨率",
        "YResolution":"Y分辨率"
    ]
}
