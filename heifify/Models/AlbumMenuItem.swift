import Photos
import UIKit

struct AlbumMenuItem: Identifiable {
    let id: String
    let title: String
    let count: Int
    let collection: PHAssetCollection
    let thumbnail: UIImage?
}

