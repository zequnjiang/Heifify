import Foundation

extension Int64 {
    var humanReadableSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

