//
//  ContentView.swift
//  heifify
//
//  Created by Ozawa on 2025/9/9.
//

import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var vm = PhotoLibraryViewModel()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private let spacing: CGFloat = 2
    @State private var selectionMode = false
    @State private var selected: Set<String> = []
    @State private var showBatchConvertSheet = false
    @State private var batchQuality: Double = 0.8
    @State private var batchDepth: ImageBitDepth = .eightBit
    @State private var overlayAsset: PHAsset? = nil
    @Namespace private var heroNS
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            NavigationStack {
                Group {
                    switch vm.authorizationStatus {
                    case .authorized, .limited:
                        GeometryReader { geo in
                            let cellSize = (geo.size.width - spacing*2) / 3
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: spacing) {
                                    ForEach(vm.items, id: \.id) { item in
                                        GridItemView(
                                            item: item,
                                            vm: vm,
                                            cellSize: cellSize,
                                            selectionMode: selectionMode,
                                            isSelected: selected.contains(item.id),
                                            heroNS: heroNS,
                                            onTap: { overlayAsset = item.asset },
                                            onToggleSelect: {
                                                if !selectionMode { selectionMode = true }
                                                toggleSelection(id: item.id)
                                            }
                                        )
                                    }
                                }
                                .padding(.horizontal, 0)
                            }
                            .allowsHitTesting(overlayAsset == nil)
                        }
                    case .notDetermined:
                        VStack(spacing: 12) {
                            Text("需要访问相册以加载照片").foregroundStyle(.secondary)
                            Button("允许访问照片库") { vm.requestPermissionAndLoad() }
                                .buttonStyle(.borderedProminent)
                        }
                    default:
                        VStack(spacing: 12) {
                            Text("没有访问照片库权限。请到设置中开启。")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                            Button("重新请求权限") { vm.requestPermissionAndLoad() }
                        }
                        .padding()
                    }
                }
                .navigationTitle(selectionMode ? "已选 \(selected.count)" : "Heifify")
                .onAppear { vm.requestPermissionAndLoad() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { vm.softReloadIfNeeded() }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if selectionMode {
                            Button(selected.count == vm.items.count ? "取消全选" : "全选") {
                                if selected.count == vm.items.count { selected.removeAll() } else { selected = Set(vm.items.map { $0.id }) }
                            }
                            Button("转换") { showBatchConvertSheet = true }
                            Button("完成") { selectionMode = false; selected.removeAll() }
                        }
                    }
                }
                .sheet(isPresented: $showBatchConvertSheet) {
                    NavigationStack {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("批量转换为 HEIF").font(.headline)
                            HStack { Text("压缩比"); Slider(value: $batchQuality, in: 0.3...1.0, step: 0.05); Text(String(format: "%.2f", batchQuality)) }
                            HStack {
                                Text("色深")
                                Picker("色深", selection: $batchDepth) {
                                    Text("8-bit").tag(ImageBitDepth.eightBit)
                                    Text("10-bit").tag(ImageBitDepth.tenBit)
                                }
                                .pickerStyle(.segmented)
                            }
                            Button("开始转换 (\(selected.count))") {
                                let assets = vm.items.filter { selected.contains($0.id) }.map { $0.asset }
                                vm.batchConvertToHEIF(assets: assets, quality: batchQuality, depth: batchDepth)
                                showBatchConvertSheet = false
                            }
                            .buttonStyle(.borderedProminent)
                            Text("转换过程中会保存到相册。")
                            Spacer()
                        }
                        .padding()
                        .navigationTitle("批量转换")
                    }
                    .presentationDetents([.height(220), .large])
                }
            }
        }
        .overlay {
            if let asset = overlayAsset {
                PhotoDetailView(asset: asset,
                                onClose: { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { overlayAsset = nil } },
                                matchedNamespace: heroNS,
                                matchedID: asset.localIdentifier,
                                onConverted: { vm.loadRecents() })
                .transition(.identity)
                .zIndex(10)
                .ignoresSafeArea()
            }
            if vm.isBatchConverting {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: vm.batchProgress)
                            .progressViewStyle(.circular)
                        Text(String(format: "%.0f%%", vm.batchProgress*100))
                            .font(.headline)
                        Button("取消") { vm.cancelBatchConversion() }
                            .buttonStyle(.bordered)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
    }

    private func toggleSelection(id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

#Preview {
    ContentView()
}
