import Photos

struct PhotoItem: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    var format: String?
    var fileSize: Int64?
}

