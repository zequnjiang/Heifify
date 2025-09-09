import SwiftUI
import Photos

struct GridItemView: View {
    let item: PhotoItem
    @ObservedObject var vm: PhotoLibraryViewModel
    let cellSize: CGFloat
    let selectionMode: Bool
    let isSelected: Bool
    let heroNS: Namespace.ID
    let onTap: () -> Void
    let onToggleSelect: () -> Void

    var body: some View {
        Group {
            if selectionMode {
                Button(action: onToggleSelect) {
                    PhotoCellView(asset: item.asset,
                                  vm: vm,
                                  cellSize: cellSize,
                                  selectionMode: true,
                                  isSelected: isSelected,
                                  matchedNamespace: heroNS,
                                  matchedID: item.id)
                }
            } else {
                PhotoCellView(asset: item.asset,
                              vm: vm,
                              cellSize: cellSize,
                              matchedNamespace: heroNS,
                              matchedID: item.id)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .onLongPressGesture(perform: onToggleSelect)
            }
        }
    }
}
