import SwiftUI
import Photos

@MainActor
final class PhotoLibraryViewModel: NSObject, ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var items: [PhotoItem] = []
    @Published var albums: [PHAssetCollection] = []
    @Published var currentCollection: PHAssetCollection?
    @Published var albumMenu: [AlbumMenuItem] = []

    private let imageManager = PHCachingImageManager()
    private var fileSizeCache: [String: Int64] = [:]
    private var formatCache: [String: String] = [:]
    private var converting = false
    private var fetchResult: PHFetchResult<PHAsset>?
    @Published var isBatchConverting: Bool = false
    @Published var batchProgress: Double = 0
    private var batchCancelRequested: Bool = false
    @Published var toastMessage: String?
    private let albumThumbSide: CGFloat = 28
    private var albumThumbCache: [String: UIImage] = [:]

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
        // Default collection = Recents (User Library)
        let userLib = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject
        currentCollection = userLib
        loadAssets(in: userLib)
        loadAlbumsList()
    }

    func loadAssets(in collection: PHAssetCollection?) {
        let fetchOptions = PHFetchOptions()
        // Sort by modificationDate desc (fall back to creation if modification nil)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false),
                                        NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if let collection {
            fetchResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
        } else {
            fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        }
        refreshItemsFromFetchResult()
        startObservingLibraryChanges()
    }

    func loadAlbumsList() {
        var list: [PHAssetCollection] = []
        if let recents = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject {
            list.append(recents)
        }
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { col, _, _ in list.append(col) }
        let smartFav = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        smartFav.enumerateObjects { col, _, _ in list.append(col) }
        self.albums = list

        // Build menu models with counts + small thumbnail
        var models: [AlbumMenuItem] = []
        let phOpts = PHFetchOptions()
        phOpts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        phOpts.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false),
                                  NSSortDescriptor(key: "creationDate", ascending: false)]
        for col in list {
            let fetch = PHAsset.fetchAssets(in: col, options: phOpts)
            let count = fetch.count
            var thumb: UIImage? = albumThumbCache[col.localIdentifier]
            if thumb == nil, let asset = fetch.firstObject {
                let size = CGSize(width: albumThumbSide * UIScreen.main.scale, height: albumThumbSide * UIScreen.main.scale)
                let reqOpts = PHImageRequestOptions()
                reqOpts.resizeMode = .fast
                reqOpts.deliveryMode = .opportunistic
                reqOpts.isSynchronous = true
                PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: reqOpts) { img, _ in
                    thumb = img
                }
                if let t = thumb { albumThumbCache[col.localIdentifier] = t }
            }
            models.append(AlbumMenuItem(id: col.localIdentifier, title: col.localizedTitle ?? "相册", count: count, collection: col, thumbnail: thumb))
        }
        self.albumMenu = models
    }

    func softReloadIfNeeded() {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        refreshItemsFromFetchResult()
    }

    private func refreshItemsFromFetchResult() {
        guard let fetchResult else { items = []; return }
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        // Ensure strict descending by modificationDate (fallback creationDate)
        assets.sort { a, b in
            let da = a.modificationDate ?? a.creationDate ?? Date.distantPast
            let db = b.modificationDate ?? b.creationDate ?? Date.distantPast
            return da > db
        }
        let result = assets.map { PhotoItem(id: $0.localIdentifier, asset: $0, format: nil, fileSize: nil) }
        withAnimation(.easeInOut(duration: 0.2)) { items = result }
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

    func batchConvertToHEIF(assets: [PHAsset], quality: Double, depth: ImageBitDepth, saveMode: PhotoDetailViewModel.SaveMode) {
        guard !converting, !assets.isEmpty else { return }
        converting = true
        isBatchConverting = true
        batchProgress = 0
        batchCancelRequested = false
        let total = assets.count
        Task { @MainActor in
            for (idx, asset) in assets.enumerated() {
                if batchCancelRequested { break }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let inputOpts = PHContentEditingInputRequestOptions(); inputOpts.isNetworkAccessAllowed = true
                    asset.requestContentEditingInput(with: inputOpts) { input, _ in
                        defer { cont.resume() }
                        guard let input, let inURL = input.fullSizeImageURL else { self.toastMessage = "无法获取原图文件"; return }
                        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("heic")
                        do { _ = try HEIFConverter.convertLikeFinder(inputURL: inURL, outputURL: tmpURL, quality: quality) } catch { self.toastMessage = "转换失败：\(error.localizedDescription)"; return }
                        switch saveMode {
                        case .addNew:
                            PHPhotoLibrary.shared().performChanges({
                                PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: tmpURL)
                            }) { success, err in
                                if !success || err != nil { DispatchQueue.main.async { self.toastMessage = err?.localizedDescription ?? "保存失败" } }
                                try? FileManager.default.removeItem(at: tmpURL)
                            }
                        case .overwrite:
                            let output = PHContentEditingOutput(contentEditingInput: input)
                            do { try FileManager.default.removeItem(at: output.renderedContentURL) } catch { }
                            do { try FileManager.default.copyItem(at: tmpURL, to: output.renderedContentURL) } catch { try? FileManager.default.removeItem(at: tmpURL); DispatchQueue.main.async { self.toastMessage = error.localizedDescription }; return }
                            output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.zanejiang.heifify", formatVersion: "1.0", data: Data("heifify".utf8))
                            PHPhotoLibrary.shared().performChanges({
                                let req = PHAssetChangeRequest(for: asset)
                                req.contentEditingOutput = output
                                if let c = asset.creationDate { req.creationDate = c }
                            }) { success, err in
                                if !success || err != nil { DispatchQueue.main.async { self.toastMessage = err?.localizedDescription ?? "覆盖失败" } }
                                try? FileManager.default.removeItem(at: tmpURL)
                            }
                        }
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
