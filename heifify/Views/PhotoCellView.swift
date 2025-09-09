import SwiftUI
import Photos

struct PhotoCellView: View {
    let asset: PHAsset
    @ObservedObject var vm: PhotoLibraryViewModel
    let cellSize: CGFloat
    @State private var image: UIImage?
    @State private var sizeText: String = ""
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var matchedNamespace: Namespace.ID? = nil
    var matchedID: String? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(.secondarySystemBackground))
            if let image {
                let base = Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cellSize, height: cellSize)
                    .clipped()
                // Avoid moving grid cell's bitmap with hero effect to prevent blank states after multiple opens
                base
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.format(for: asset))
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                if !sizeText.isEmpty {
                    Text(sizeText)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 6)
            .padding(.bottom, 6)

            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: cellSize, height: cellSize)
        .onAppear {
            if image == nil {
                let scale = UIScreen.main.scale
                let ts = CGSize(width: cellSize * scale, height: cellSize * scale)
                vm.thumbnail(for: asset, targetSize: ts) { img in self.image = img }
            }
            if sizeText.isEmpty {
                vm.fileSize(for: asset) { size in
                    if let size { self.sizeText = size.humanReadableSize }
                }
            }
        }
    }
}
