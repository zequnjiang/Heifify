import SwiftUI
import Photos

@MainActor
final class PhotoLibraryViewModel: NSObject, ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var items: [PhotoItem] = []

    private let imageManager = PHCachingImageManager()
    private var fileSizeCache: [String: Int64] = [:]
    private var formatCache: [String: String] = [:]
    private var converting = false
    private var fetchResult: PHFetchResult<PHAsset>?
    @Published var isBatchConverting: Bool = false
    @Published var batchProgress: Double = 0
    private var batchCancelRequested: Bool = false

    func requestPermissionAndLoad() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            authorizationStatus = current
            loadRecents(); return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.authorizationStatus = status
                if status == .authorized || status == .limited { self?.loadRecents() }
            }
        }
    }

    func loadRecents() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject {
            fetchResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            refreshItemsFromFetchResult()
            startObservingLibraryChanges()
        }
    }

    func softReloadIfNeeded() {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        refreshItemsFromFetchResult()
    }

    private func refreshItemsFromFetchResult() {
        guard let fetchResult else { items = []; return }
        var result: [PhotoItem] = []
        result.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            result.append(PhotoItem(id: asset.localIdentifier, asset: asset, format: nil, fileSize: nil))
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            items = result
        }
        prefetchFormats(for: result)
    }

    private func startObservingLibraryChanges() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func thumbnail(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isSynchronous = false
        imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
            completion(image)
        }
    }

    func format(for asset: PHAsset) -> String {
        if let cached = formatCache[asset.localIdentifier] { return cached }
        let resources = PHAssetResource.assetResources(for: asset)
        if let res = resources.first(where: { $0.type == .photo }) ?? resources.first {
            let uti = res.uniformTypeIdentifier
            let pretty = prettyFormat(fromUTI: uti)
            formatCache[asset.localIdentifier] = pretty
            return pretty
        }
        return "—"
    }

    private func prefetchFormats(for items: [PhotoItem]) {
        for item in items.prefix(60) { _ = self.format(for: item.asset) }
    }

    func fileSize(for asset: PHAsset, completion: @escaping (Int64?) -> Void) {
        if let cached = fileSizeCache[asset.localIdentifier] { completion(cached); return }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        asset.requestContentEditingInput(with: options) { [weak self] input, _ in
            guard let self else { completion(nil); return }
            if let url = input?.fullSizeImageURL {
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    let s = Int64(size)
                    self.fileSizeCache[asset.localIdentifier] = s
                    completion(s); return
                }
            }
            guard let res = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) ?? PHAssetResource.assetResources(for: asset).first else { completion(nil); return }
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
            let ro = PHAssetResourceRequestOptions(); ro.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: res, toFile: tmpURL, options: ro) { error in
                if let error { print("writeData error: \(error)"); completion(nil); return }
                let size = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path)[.size] as? NSNumber)?.int64Value
                if let s = size { self.fileSizeCache[asset.localIdentifier] = s }
                completion(size ?? nil)
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }
    }

    func prettyFormat(fromUTI uti: String) -> String {
        let u = uti.lowercased()
        if u.contains("heic") || u.contains("heif") { return "HEIF" }
        if u.contains("jpeg") || u.contains("jpg") { return "JPG" }
        if u.contains("png") { return "PNG" }
        if u.contains("raw") || u.contains("dng") { return "RAW" }
        return uti.uppercased()
    }

    func cancelBatchConversion() { batchCancelRequested = true }

    func batchConvertToHEIF(assets: [PHAsset], quality: Double, depth: ImageBitDepth) {
        guard !converting, !assets.isEmpty else { return }
        converting = true
        isBatchConverting = true
        batchProgress = 0
        batchCancelRequested = false
        let total = assets.count
        Task { @MainActor in
            for (idx, asset) in assets.enumerated() {
                if batchCancelRequested { break }
                let opts = PHImageRequestOptions()
                opts.isNetworkAccessAllowed = true
                opts.version = .original
                opts.deliveryMode = .highQualityFormat
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, _ in
                        defer { cont.resume() }
                        guard let data else { return }
                        do {
                            let heic = try HEIFConverter.convertToHEIC(data: data, quality: quality, depth: depth)
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("heic")
                            try heic.write(to: url)
                            PHPhotoLibrary.shared().performChanges({
                                PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                            }) { _, _ in try? FileManager.default.removeItem(at: url) }
                        } catch { }
                    }
                }
                batchProgress = Double(idx + 1) / Double(total)
            }
            isBatchConverting = false
            converting = false
            if !batchCancelRequested { self.softReloadIfNeeded() }
        }
    }
}

extension PhotoLibraryViewModel: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let fetchResult = self.fetchResult,
              let changes = changeInstance.changeDetails(for: fetchResult) else { return }
        let after = changes.fetchResultAfterChanges
        Task { @MainActor in
            self.fetchResult = after
            self.refreshItemsFromFetchResult()
        }
    }
}
